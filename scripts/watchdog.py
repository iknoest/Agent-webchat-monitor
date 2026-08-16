#!/usr/bin/env python3
"""
External Watchdog for AgentSignalBar Controlled Runtime Smoke Test
===================================================================
Monitors AgentSignalBar and related child processes during runtime smoke tests.
Enforces hard safety containment boundaries (CPU, Memory/RSS, Threads, Stuck SQLite, Wall-Clock Duration).

Threshold Derivations (18-Core Apple Silicon Mac, 64 GB RAM):
- Max CPU: 100.0% (1 core, 5.5% of sys CPU) sustained for 3 samples (1.5s). [Previous runaway: ~980%-1170%]
- Max RSS: 300.0 MB sustained for 2 samples (1.0s). [Baseline: 30-60 MB, Previous runaway: 26-27 GB]
- Max Threads: 40 threads sustained for 2 samples (1.0s). [Baseline: 8-15 threads, Previous runaway: 98 threads]
- Max SQLite Subprocess Runtime: > 1.0s (3 samples). [AutoMonitor timeout: 1.0s]
- Hard Wall-Clock Limit: 60.0s total runtime.
"""

import sys
import os
import time
import signal
import subprocess
import argparse
from datetime import datetime, timezone

def timestamp():
    return datetime.now().astimezone().strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"

class ProcessMetrics:
    def __init__(self, pid, ppid, cpu, rss_mb, comm, command):
        self.pid = pid
        self.ppid = ppid
        self.cpu = cpu
        self.rss_mb = rss_mb
        self.comm = comm
        self.command = command

class Watchdog:
    def __init__(self, args):
        self.args = args
        self.target_pid = args.pid
        self.app_name = args.app_name
        self.max_duration = args.max_duration
        self.interval = args.interval
        self.log_file_path = args.log_file

        # Thresholds
        self.cpu_warning = args.cpu_warning
        self.cpu_kill = args.cpu_kill
        self.cpu_kill_samples = args.cpu_kill_samples

        self.mem_warning_mb = args.mem_warning_mb
        self.mem_kill_mb = args.mem_kill_mb
        self.mem_kill_samples = args.mem_kill_samples

        self.threads_warning = args.threads_warning
        self.threads_kill = args.threads_kill
        self.threads_kill_samples = args.threads_kill_samples

        self.sqlite_kill_samples = args.sqlite_kill_samples
        self.sqlite_max_age_seconds = args.sqlite_max_age_seconds
        self.max_telemetry_failures = args.max_telemetry_failures

        # Counters for consecutive violations
        self.cpu_violations = 0
        self.mem_violations = 0
        self.threads_violations = 0
        self.sqlite_violations = 0
        self.telemetry_violations = 0

        # Tracked sqlite children {pid: {'samples': int, 'first_seen': float, 'cmd': str}}
        self.tracked_sqlite = {}

        # Stats tracking
        self.peak_cpu = 0.0
        self.peak_rss_mb = 0.0
        self.peak_threads = 0
        self.total_samples = 0
        self.start_time = None
        self.log_handle = None

    def log(self, msg, console=True):
        entry = f"[{timestamp()}] {msg}"
        if console:
            print(entry, flush=True)
        if self.log_handle:
            self.log_handle.write(entry + "\n")
            self.log_handle.flush()

    def find_target_pid(self):
        if self.target_pid is not None:
            if self.is_pid_alive(self.target_pid):
                return self.target_pid
            return None

        # Search by process name
        try:
            out = subprocess.check_output(["pgrep", "-x", self.app_name]).decode().strip()
            pids = [int(p) for p in out.splitlines() if p.strip().isdigit()]
            if pids:
                return pids[0]
        except subprocess.CalledProcessError:
            pass

        # Search by ps matching
        try:
            out = subprocess.check_output(["ps", "-ax", "-o", "pid=,comm=,command="]).decode()
            for line in out.splitlines():
                parts = line.strip().split(None, 2)
                if len(parts) >= 2:
                    pid_str = parts[0]
                    comm = parts[1]
                    cmd = parts[2] if len(parts) > 2 else comm
                    if self.app_name in comm or self.app_name in cmd:
                        if "watchdog" not in cmd:
                            return int(pid_str)
        except Exception:
            pass

        return None

    def is_pid_alive(self, pid):
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False

    def check_process_status(self, pid):
        """
        Checks PID status and returns (status, metrics) tuple.
        Status can be:
        - "SUCCESS": metrics is a valid ProcessMetrics object
        - "TARGET_EXITED": process is confirmed dead or zombie
        - "TELEMETRY_FAILURE": process is alive according to os.kill(pid,0), but ps/parsing failed
        """
        if not self.is_pid_alive(pid):
            return ("TARGET_EXITED", None)

        try:
            out = subprocess.check_output(
                ["ps", "-p", str(pid), "-o", "pid=,ppid=,%cpu=,rss=,state=,comm=,command="],
                stderr=subprocess.DEVNULL
            ).decode().strip()
            if not out:
                return ("TELEMETRY_FAILURE", None)

            parts = out.split(None, 6)
            if len(parts) < 7:
                return ("TELEMETRY_FAILURE", None)

            p_pid = int(parts[0])
            p_ppid = int(parts[1])
            cpu = float(parts[2])
            rss_mb = float(parts[3]) / 1024.0
            state = parts[4]
            comm = parts[5]
            cmd = parts[6]

            if state.startswith("Z") or "defunct" in cmd.lower() or "defunct" in comm.lower():
                return ("TARGET_EXITED", None)

            return ("SUCCESS", ProcessMetrics(p_pid, p_ppid, cpu, rss_mb, comm, cmd))
        except Exception:
            if self.is_pid_alive(pid):
                return ("TELEMETRY_FAILURE", None)
            return ("TARGET_EXITED", None)

    def get_process_metrics(self, pid):
        """Returns ProcessMetrics for a specific PID, or None if exited/zombie/errored."""
        status, metrics = self.check_process_status(pid)
        return metrics if status == "SUCCESS" else None

    def get_thread_count(self, pid):
        """Counts threads on macOS via ps -M -p <pid>. Returns int count or None on telemetry failure."""
        try:
            out = subprocess.check_output(["ps", "-M", "-p", str(pid)], stderr=subprocess.DEVNULL).decode().strip()
            lines = out.splitlines()
            if not lines:
                return None
            return max(0, len(lines) - 1)
        except Exception:
            return None

    def get_child_processes(self, target_pid):
        """Returns list of ProcessMetrics for child processes, or None on telemetry failure."""
        children = []
        try:
            out = subprocess.check_output(["ps", "-ax", "-o", "pid=,ppid=,%cpu=,rss=,comm=,command="], stderr=subprocess.DEVNULL).decode().strip()
            if not out:
                return None
            all_procs = {}
            for line in out.splitlines():
                parts = line.strip().split(None, 5)
                if len(parts) >= 6:
                    p = int(parts[0])
                    pp = int(parts[1])
                    c = float(parts[2])
                    r = float(parts[3]) / 1024.0
                    cm = parts[4]
                    cmd = parts[5]
                    all_procs[p] = ProcessMetrics(p, pp, c, r, cm, cmd)

            # Traversal for descendants
            def collect_children(parent_pid):
                for p, m in all_procs.items():
                    if m.ppid == parent_pid:
                        children.append(m)
                        collect_children(p)

            collect_children(target_pid)
            return children
        except Exception:
            return None

    def kill_target_tree(self, target_pid, reason):
        self.log(f"!!! TRIGGERING EMERGENCY KILL: {reason} !!!")

        # Gather children before killing main process
        children = self.get_child_processes(target_pid) or []
        descendant_pids = set([c.pid for c in children])
        target_tree_pids = list(descendant_pids | {target_pid} | set(self.tracked_sqlite.keys()))

        self.log(f"Terminating target PID={target_pid} and {len(target_tree_pids)-1} descendant/tracked process(es): {target_tree_pids}")

        # Step 1: SIGTERM
        for p in target_tree_pids:
            try:
                os.kill(p, signal.SIGTERM)
            except OSError:
                pass

        time.sleep(0.5)

        # Step 2: SIGKILL for survivors
        for p in target_tree_pids:
            if self.is_pid_alive(p):
                self.log(f"Process PID={p} still alive after SIGTERM -> Sending SIGKILL (-9)")
                try:
                    os.kill(p, signal.SIGKILL)
                except OSError:
                    pass

        # Step 3: Sweep ONLY surviving orphan processes that were descendants of target_tree_pids
        # NEVER sweep unrelated system sqlite processes!
        try:
            out = subprocess.check_output(["ps", "-ax", "-o", "pid=,ppid=,comm=,command="], stderr=subprocess.DEVNULL).decode().strip()
            for line in out.splitlines():
                parts = line.strip().split(None, 3)
                if len(parts) >= 3:
                    p = int(parts[0])
                    pp = int(parts[1])
                    if pp in target_tree_pids or p in target_tree_pids:
                        if self.is_pid_alive(p):
                            self.log(f"Killing surviving orphan child process PID={p}")
                            try:
                                os.kill(p, signal.SIGKILL)
                            except OSError:
                                pass
        except Exception:
            pass

        self.log(f"KILL SEQUENCE COMPLETED FOR REASON: {reason}")

    def run(self):
        self.log_handle = open(self.log_file_path, "a")
        self.log("=" * 70)
        self.log("AGENT SIGNAL BAR RUNTIME WATCHDOG INITIALIZED")
        self.log(f"App Target: {self.app_name} | PID: {self.target_pid if self.target_pid else 'Auto-Discover'}")
        self.log(f"Hard Max Duration: {self.max_duration}s | Sample Interval: {self.interval}s")
        self.log(f"CPU Limits: Warn > {self.cpu_warning}% | Kill > {self.cpu_kill}% ({self.cpu_kill_samples} samples)")
        self.log(f"RAM Limits: Warn > {self.mem_warning_mb} MB | Kill > {self.mem_kill_mb} MB ({self.mem_kill_samples} samples)")
        self.log(f"Thread Limits: Warn > {self.threads_warning} | Kill > {self.threads_kill} ({self.threads_kill_samples} samples)")
        self.log(f"SQLite Subprocess Kill Limits: {self.sqlite_kill_samples} samples & >{self.sqlite_max_age_seconds:.1f}s age")
        self.log(f"Telemetry Fail Limit: {self.max_telemetry_failures} consecutive samples")
        self.log("=" * 70)

        # Wait for PID if not currently running
        if self.target_pid is None or not self.is_pid_alive(self.target_pid):
            self.log(f"Waiting up to {self.args.launch_timeout}s for {self.app_name} process to launch...")
            wait_start = time.time()
            while time.time() - wait_start < self.args.launch_timeout:
                found_pid = self.find_target_pid()
                if found_pid:
                    self.target_pid = found_pid
                    self.log(f"TARGET DETECTED: {self.app_name} launched with PID={self.target_pid}")
                    break
                time.sleep(0.2)

        if not self.target_pid or not self.is_pid_alive(self.target_pid):
            self.log(f"ERROR: Target process {self.app_name} was not detected within launch timeout. Exiting watchdog.")
            self.log_handle.close()
            return 1

        self.start_time = time.time()
        self.log(f"SMOKE TEST MONITORING STARTED for PID={self.target_pid}")

        exit_code = 0
        termination_reason = "NORMAL_COMPLETION"

        try:
            while True:
                now = time.time()
                elapsed = now - self.start_time

                # Check Wall-Clock Hard Limit
                if elapsed >= self.max_duration:
                    termination_reason = f"MAX_DURATION_EXCEEDED ({elapsed:.1f}s >= {self.max_duration}s)"
                    self.kill_target_tree(self.target_pid, termination_reason)
                    break

                # Check PID status, thread telemetry, and child telemetry
                status, metrics = self.check_process_status(self.target_pid)
                threads = self.get_thread_count(self.target_pid) if status == "SUCCESS" else None
                children = self.get_child_processes(self.target_pid) if status == "SUCCESS" else None

                if status == "TELEMETRY_FAILURE" or threads is None or children is None:
                    if status != "TARGET_EXITED":
                        self.telemetry_violations += 1
                        failed_comp = "main PID" if status == "TELEMETRY_FAILURE" else ("threads" if threads is None else "children")
                        self.log(f"WARNING: Telemetry read failure ({failed_comp}) for PID={self.target_pid} ({self.telemetry_violations}/{self.max_telemetry_failures} consecutive failures)")
                        if self.telemetry_violations >= self.max_telemetry_failures:
                            termination_reason = f"TELEMETRY_FAILURE_EXCEEDED ({self.telemetry_violations} consecutive failures)"
                            self.kill_target_tree(self.target_pid, termination_reason)
                            exit_code = 6
                            break
                        time.sleep(self.interval)
                        continue

                if status == "TARGET_EXITED":
                    self.log(f"TARGET PROCESS PID={self.target_pid} EXITED NORMALLY at t={elapsed:.1f}s")
                    termination_reason = "TARGET_EXITED_NORMALLY"
                    break

                # Reset telemetry failures on successful read of ALL components
                self.telemetry_violations = 0

                # Total CPU & RSS including child processes
                total_cpu = metrics.cpu + sum(c.cpu for c in children)
                total_rss = metrics.rss_mb + sum(c.rss_mb for c in children)
                sqlite_children = [c for c in children if "sqlite3" in c.comm or "sqlite3" in c.command]

                # Update per-PID stuck sqlite tracking
                current_sqlite_pids = {c.pid: c for c in sqlite_children}

                for pid, c in current_sqlite_pids.items():
                    if pid in self.tracked_sqlite:
                        self.tracked_sqlite[pid]['samples'] += 1
                    else:
                        self.tracked_sqlite[pid] = {
                            'samples': 1,
                            'first_seen': now,
                            'cmd': c.command
                        }

                dead_sqlite_pids = [pid for pid in self.tracked_sqlite if pid not in current_sqlite_pids]
                for pid in dead_sqlite_pids:
                    del self.tracked_sqlite[pid]

                # Both sample count AND elapsed age must exceed limits
                stuck_sqlite = [
                    (pid, info) for pid, info in self.tracked_sqlite.items()
                    if info['samples'] >= self.sqlite_kill_samples and (now - info['first_seen']) >= self.sqlite_max_age_seconds
                ]

                # Peak tracking
                self.total_samples += 1
                if total_cpu > self.peak_cpu:
                    self.peak_cpu = total_cpu
                if total_rss > self.peak_rss_mb:
                    self.peak_rss_mb = total_rss
                if threads > self.peak_threads:
                    self.peak_threads = threads

                # Format status string
                status_flags = []
                if total_cpu > self.cpu_warning:
                    status_flags.append("CPU_WARN")
                if total_rss > self.mem_warning_mb:
                    status_flags.append("MEM_WARN")
                if threads > self.threads_warning:
                    status_flags.append("THREAD_WARN")
                if sqlite_children:
                    max_sqlite_samples = max((info['samples'] for info in self.tracked_sqlite.values()), default=0)
                    max_sqlite_age = max((now - info['first_seen'] for info in self.tracked_sqlite.values()), default=0.0)
                    status_flags.append(f"SQLITE({len(sqlite_children)}:max_{max_sqlite_samples}smp/{max_sqlite_age:.1f}s)")

                status_str = ",".join(status_flags) if status_flags else "OK"

                self.log(
                    f"t={elapsed:4.1f}s | PID={self.target_pid} | CPU={total_cpu:5.1f}% | "
                    f"RSS={total_rss:6.1f}MB | Threads={threads:2d} | Children={len(children):d} | "
                    f"Status={status_str}"
                )

                # Check CPU Threshold
                if total_cpu >= self.cpu_kill:
                    self.cpu_violations += 1
                    self.log(f"WARNING: CPU {total_cpu:.1f}% >= kill threshold {self.cpu_kill}% ({self.cpu_violations}/{self.cpu_kill_samples} samples)")
                    if self.cpu_violations >= self.cpu_kill_samples:
                        termination_reason = f"CPU_EXCEEDED ({total_cpu:.1f}% >= {self.cpu_kill}%)"
                        self.kill_target_tree(self.target_pid, termination_reason)
                        exit_code = 2
                        break
                else:
                    self.cpu_violations = 0

                # Check Memory Threshold
                if total_rss >= self.mem_kill_mb:
                    self.mem_violations += 1
                    self.log(f"WARNING: RSS {total_rss:.1f}MB >= kill threshold {self.mem_kill_mb}MB ({self.mem_violations}/{self.mem_kill_samples} samples)")
                    if self.mem_violations >= self.mem_kill_samples:
                        termination_reason = f"MEM_EXCEEDED ({total_rss:.1f}MB >= {self.mem_kill_mb}MB)"
                        self.kill_target_tree(self.target_pid, termination_reason)
                        exit_code = 3
                        break
                else:
                    self.mem_violations = 0

                # Check Thread Count Threshold
                if threads >= self.threads_kill:
                    self.threads_violations += 1
                    self.log(f"WARNING: Threads {threads} >= kill threshold {self.threads_kill} ({self.threads_violations}/{self.threads_kill_samples} samples)")
                    if self.threads_violations >= self.threads_kill_samples:
                        termination_reason = f"THREADS_EXCEEDED ({threads} >= {self.threads_kill})"
                        self.kill_target_tree(self.target_pid, termination_reason)
                        exit_code = 4
                        break
                else:
                    self.threads_violations = 0

                # Check SQLite Child Subprocesses Threshold (Requires BOTH samples AND elapsed age)
                if stuck_sqlite:
                    stuck_pid, stuck_info = stuck_sqlite[0]
                    stuck_duration = now - stuck_info['first_seen']
                    self.sqlite_violations = stuck_info['samples']
                    termination_reason = f"STUCK_SQLITE_SUBPROCESS (PID={stuck_pid} stuck for {stuck_info['samples']} samples / {stuck_duration:.1f}s >= {self.sqlite_max_age_seconds:.1f}s)"
                    self.kill_target_tree(self.target_pid, termination_reason)
                    exit_code = 5
                    break
                else:
                    self.sqlite_violations = max((info['samples'] for info in self.tracked_sqlite.values()), default=0)

                time.sleep(self.interval)

        except KeyboardInterrupt:
            self.log("Watchdog interrupted by user (Ctrl+C). Terminating monitored process...")
            if self.target_pid and self.is_pid_alive(self.target_pid):
                self.kill_target_tree(self.target_pid, "USER_KEYBOARD_INTERRUPT")
            termination_reason = "KEYBOARD_INTERRUPT"
            exit_code = 130

        self.log("=" * 70)
        self.log("WATCHDOG SMOKE TEST SUMMARY")
        self.log(f"Termination Reason : {termination_reason}")
        self.log(f"Total Samples Taken: {self.total_samples}")
        self.log(f"Peak CPU Recorded  : {self.peak_cpu:.1f}%")
        self.log(f"Peak RSS Recorded  : {self.peak_rss_mb:.1f} MB")
        self.log(f"Peak Thread Count  : {self.peak_threads}")
        self.log("=" * 70)

        self.log_handle.close()
        return exit_code

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="AgentSignalBar Watchdog Monitor")
    parser.add_argument("--pid", type=int, default=None, help="Target process PID")
    parser.add_argument("--app-name", type=str, default="AgentSignalBar", help="App process name")
    parser.add_argument("--launch-timeout", type=float, default=30.0, help="Max wait for app launch (s)")
    parser.add_argument("--max-duration", type=float, default=60.0, help="Hard wall-clock test duration (s)")
    parser.add_argument("--interval", type=float, default=0.5, help="Sampling interval (s)")
    parser.add_argument("--cpu-warning", type=float, default=30.0, help="CPU warning threshold (%%)")
    parser.add_argument("--cpu-kill", type=float, default=100.0, help="CPU kill threshold (%%)")
    parser.add_argument("--cpu-kill-samples", type=int, default=3, help="Samples above CPU limit before kill")

    parser.add_argument("--mem-warning-mb", type=float, default=150.0, help="RAM warning threshold (MB)")
    parser.add_argument("--mem-kill-mb", type=float, default=300.0, help="RAM kill threshold (MB)")
    parser.add_argument("--mem-kill-samples", type=int, default=2, help="Samples above RAM limit before kill")
    parser.add_argument("--threads-warning", type=int, default=25, help="Threads warning threshold")
    parser.add_argument("--threads-kill", type=int, default=40, help="Threads kill threshold")
    parser.add_argument("--threads-kill-samples", type=int, default=2, help="Samples above thread limit before kill")
    parser.add_argument("--sqlite-kill-samples", type=int, default=3, help="Samples with stuck sqlite child before kill")
    parser.add_argument("--sqlite-max-age-seconds", type=float, default=2.0, help="Min elapsed age (s) for stuck sqlite child before kill")
    parser.add_argument("--max-telemetry-failures", type=int, default=3, help="Max consecutive telemetry read failures before emergency kill")
    parser.add_argument("--log-file", type=str, default="watchdog_smoketest.log", help="Path to watchdog log file")

    args = parser.parse_args()
    watchdog = Watchdog(args)
    sys.exit(watchdog.run())


