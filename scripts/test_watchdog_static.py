#!/usr/bin/env python3
"""
Static Validation Test Suite for watchdog.py
============================================
Statically validates watchdog logic on dummy processes (e.g., sleep, python threads, memory allocators)
without launching AgentSignalBar or triggering actual Chrome extension updates.
"""

import sys
import os
import time
import subprocess
import tempfile
import shutil
import importlib.util

WATCHDOG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "watchdog.py")

def load_watchdog_module():
    spec = importlib.util.spec_from_file_location("watchdog_mod", WATCHDOG_PATH)
    wd_mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(wd_mod)
    return wd_mod

def test_help_and_defaults():
    print("Test 1: Testing help and argument defaults...", end=" ", flush=True)
    out = subprocess.check_output([sys.executable, WATCHDOG_PATH, "--help"]).decode()
    assert "--cpu-kill" in out
    assert "--mem-kill-mb" in out
    assert "--threads-kill" in out
    assert "--max-duration" in out
    assert "--max-telemetry-failures" in out
    assert "--sqlite-kill-samples" in out
    assert "--sqlite-max-age-seconds" in out
    print("PASSED")

def test_launch_timeout_nonexistent_app():
    print("Test 2: Testing launch timeout for non-existent app...", end=" ", flush=True)
    tmp_log = tempfile.NamedTemporaryFile(suffix=".log", delete=False).name
    try:
        t0 = time.time()
        res = subprocess.run([
            sys.executable, WATCHDOG_PATH,
            "--app-name", "NonExistentApp9999",
            "--launch-timeout", "1.5",
            "--log-file", tmp_log
        ], capture_output=True, text=True)
        elapsed = time.time() - t0
        assert res.returncode == 1, f"Expected returncode 1, got {res.returncode}"
        assert elapsed >= 1.4 and elapsed <= 3.0, f"Expected ~1.5s elapsed, got {elapsed:.2f}s"

        with open(tmp_log) as f:
            content = f.read()
        assert "Waiting up to 1.5s" in content
        assert "was not detected within launch timeout" in content
        print("PASSED")
    finally:
        if os.path.exists(tmp_log):
            os.remove(tmp_log)

def test_normal_completion_with_dummy_process():
    print("Test 3: Testing monitoring and normal exit with dummy sleep process...", end=" ", flush=True)
    tmp_log = tempfile.NamedTemporaryFile(suffix=".log", delete=False).name
    proc = subprocess.Popen(["sleep", "3"])
    try:
        res = subprocess.run([
            sys.executable, WATCHDOG_PATH,
            "--pid", str(proc.pid),
            "--max-duration", "10.0",
            "--interval", "0.2",
            "--log-file", tmp_log
        ], capture_output=True, text=True)

        assert res.returncode == 0, f"Expected returncode 0, got {res.returncode}"

        with open(tmp_log) as f:
            content = f.read()
        assert f"PID={proc.pid}" in content, f"Expected PID={proc.pid} in log content:\n{content}"
        assert "EXITED NORMALLY" in content or "TARGET_EXITED_NORMALLY" in content or "NORMAL_COMPLETION" in content, f"Expected normal exit in log content:\n{content}"
        print("PASSED")

    finally:
        proc.poll()
        if proc.returncode is None:
            proc.kill()
        if os.path.exists(tmp_log):
            os.remove(tmp_log)

def test_hard_duration_kill():
    print("Test 4: Testing hard wall-clock duration kill on dummy long-running sleep process...", end=" ", flush=True)
    tmp_log = tempfile.NamedTemporaryFile(suffix=".log", delete=False).name
    proc = subprocess.Popen(["sleep", "60"])
    try:
        t0 = time.time()
        res = subprocess.run([
            sys.executable, WATCHDOG_PATH,
            "--pid", str(proc.pid),
            "--max-duration", "1.0",
            "--interval", "0.2",
            "--log-file", tmp_log
        ], capture_output=True, text=True)
        elapsed = time.time() - t0

        proc.poll()
        assert proc.returncode is not None, "Dummy process should have been terminated by watchdog!"
        assert res.returncode == 0, f"Expected returncode 0 on duration timeout, got {res.returncode}"
        assert elapsed < 3.0, f"Watchdog took too long: {elapsed:.2f}s"

        with open(tmp_log) as f:
            content = f.read()
        assert "MAX_DURATION_EXCEEDED" in content
        assert "KILL SEQUENCE COMPLETED" in content
        print("PASSED")
    finally:
        if os.path.exists(tmp_log):
            os.remove(tmp_log)

def test_thread_count_exceeded_kill():
    print("Test 5: Testing thread count threshold kill on dummy multi-threaded python process...", end=" ", flush=True)
    tmp_log = tempfile.NamedTemporaryFile(suffix=".log", delete=False).name
    script = "import threading, time; [threading.Thread(target=lambda: time.sleep(10)).start() for _ in range(15)]; time.sleep(10)"
    proc = subprocess.Popen([sys.executable, "-c", script])
    try:
        res = subprocess.run([
            sys.executable, WATCHDOG_PATH,
            "--pid", str(proc.pid),
            "--threads-warning", "5",
            "--threads-kill", "10",
            "--threads-kill-samples", "2",
            "--interval", "0.2",
            "--log-file", tmp_log
        ], capture_output=True, text=True)

        proc.poll()
        assert proc.returncode is not None, "Dummy process should have been killed by watchdog due to thread count!"
        assert res.returncode == 4, f"Expected returncode 4 (threads exceeded), got {res.returncode}"

        with open(tmp_log) as f:
            content = f.read()
        assert "THREADS_EXCEEDED" in content
        print("PASSED")
    finally:
        if os.path.exists(tmp_log):
            os.remove(tmp_log)

def test_cpu_exceeded_kill():
    print("Test 6: Testing CPU threshold kill on dummy cpu-heavy python process...", end=" ", flush=True)
    tmp_log = tempfile.NamedTemporaryFile(suffix=".log", delete=False).name
    script = "import time; t0=time.time();\nwhile time.time()-t0 < 10: pass"
    proc = subprocess.Popen([sys.executable, "-c", script])
    try:
        res = subprocess.run([
            sys.executable, WATCHDOG_PATH,
            "--pid", str(proc.pid),
            "--cpu-warning", "20.0",
            "--cpu-kill", "50.0",
            "--cpu-kill-samples", "2",
            "--interval", "0.2",
            "--log-file", tmp_log
        ], capture_output=True, text=True)

        proc.poll()
        assert proc.returncode is not None, "Dummy CPU process should have been killed by watchdog!"
        assert res.returncode == 2, f"Expected returncode 2 (CPU exceeded), got {res.returncode}"

        with open(tmp_log) as f:
            content = f.read()
        assert "CPU_EXCEEDED" in content
        print("PASSED")
    finally:
        if os.path.exists(tmp_log):
            os.remove(tmp_log)

def test_memory_rss_exceeded_kill():
    print("Test 7: Testing RSS memory threshold kill on dummy memory-heavy python process...", end=" ", flush=True)
    tmp_log = tempfile.NamedTemporaryFile(suffix=".log", delete=False).name
    script = "import time; x = bytearray(50*1024*1024); time.sleep(10)"
    proc = subprocess.Popen([sys.executable, "-c", script])
    try:
        res = subprocess.run([
            sys.executable, WATCHDOG_PATH,
            "--pid", str(proc.pid),
            "--mem-warning-mb", "5.0",
            "--mem-kill-mb", "20.0",
            "--mem-kill-samples", "2",
            "--interval", "0.2",
            "--log-file", tmp_log
        ], capture_output=True, text=True)

        proc.poll()
        assert proc.returncode is not None, "Dummy memory process should have been killed by watchdog!"
        assert res.returncode == 3, f"Expected returncode 3 (MEM exceeded), got {res.returncode}"

        with open(tmp_log) as f:
            content = f.read()
        assert "MEM_EXCEEDED" in content
        print("PASSED")
    finally:
        if os.path.exists(tmp_log):
            os.remove(tmp_log)

def test_same_pid_sqlite_under_age_threshold_no_kill():
    print("Test 8: Testing same-PID sqlite child under age threshold does NOT trigger kill...", end=" ", flush=True)
    tmp_log = tempfile.NamedTemporaryFile(suffix=".log", delete=False).name
    parent_script = "import subprocess, sys, time; p = subprocess.Popen([sys.executable, '-c', 'import time; tag = \"sqlite3_stuck\"; time.sleep(0.3)']); time.sleep(0.4)"
    proc = subprocess.Popen([sys.executable, "-c", parent_script])
    try:
        # 2 samples taken at 0.1s interval (age ~0.2s < sqlite-max-age 2.0s)
        res = subprocess.run([
            sys.executable, WATCHDOG_PATH,
            "--pid", str(proc.pid),
            "--sqlite-kill-samples", "2",
            "--sqlite-max-age-seconds", "2.0",
            "--interval", "0.1",
            "--log-file", tmp_log
        ], capture_output=True, text=True)

        assert res.returncode == 0, f"Expected returncode 0 (normal exit), got {res.returncode}"

        with open(tmp_log) as f:
            content = f.read()
        assert "STUCK_SQLITE_SUBPROCESS" not in content, "Should NOT kill when age is below age threshold!"
        print("PASSED")
    finally:
        if os.path.exists(tmp_log):
            os.remove(tmp_log)

def test_same_pid_sqlite_exceeding_both_samples_and_age_triggers_kill():
    print("Test 9: Testing same-PID sqlite child exceeding BOTH samples and age DOES trigger kill...", end=" ", flush=True)
    tmp_log = tempfile.NamedTemporaryFile(suffix=".log", delete=False).name
    parent_script = "import subprocess, sys, time; p = subprocess.Popen([sys.executable, '-c', 'import time; tag = \"sqlite3_stuck\"; time.sleep(10)']); time.sleep(10)"
    proc = subprocess.Popen([sys.executable, "-c", parent_script])
    try:
        res = subprocess.run([
            sys.executable, WATCHDOG_PATH,
            "--pid", str(proc.pid),
            "--sqlite-kill-samples", "2",
            "--sqlite-max-age-seconds", "0.3",
            "--interval", "0.2",
            "--log-file", tmp_log
        ], capture_output=True, text=True)

        proc.poll()
        assert proc.returncode is not None, "Dummy parent process should have been killed due to stuck sqlite child!"
        assert res.returncode == 5, f"Expected returncode 5 (stuck sqlite), got {res.returncode}"

        with open(tmp_log) as f:
            content = f.read()
        assert "STUCK_SQLITE_SUBPROCESS" in content
        print("PASSED")
    finally:
        if os.path.exists(tmp_log):
            os.remove(tmp_log)

def test_different_short_lived_sqlite_pids_no_false_trigger():
    print("Test 10: Testing different short-lived sqlite PIDs do not falsely trigger stuck rule...", end=" ", flush=True)
    tmp_log = tempfile.NamedTemporaryFile(suffix=".log", delete=False).name
    parent_script = "import subprocess, sys, time; [subprocess.run([sys.executable, '-c', 'import time; tag = \"sqlite3_short\"; time.sleep(0.05)']) for _ in range(5)]; time.sleep(0.1)"
    proc = subprocess.Popen([sys.executable, "-c", parent_script])
    try:
        res = subprocess.run([
            sys.executable, WATCHDOG_PATH,
            "--pid", str(proc.pid),
            "--sqlite-kill-samples", "3",
            "--sqlite-max-age-seconds", "0.2",
            "--interval", "0.2",
            "--log-file", tmp_log
        ], capture_output=True, text=True)

        assert res.returncode == 0, f"Expected returncode 0 (normal exit), got {res.returncode}"

        with open(tmp_log) as f:
            content = f.read()
        assert "STUCK_SQLITE_SUBPROCESS" not in content, "Short-lived sqlite processes should NOT trigger stuck rule!"
        assert "TARGET_EXITED_NORMALLY" in content or "NORMAL_COMPLETION" in content
        print("PASSED")
    finally:
        if os.path.exists(tmp_log):
            os.remove(tmp_log)

def test_telemetry_failure_not_reported_as_normal_exit():
    print("Test 11: Testing main PID status telemetry failure fails closed without claiming normal exit...", end=" ", flush=True)
    tmp_log = tempfile.NamedTemporaryFile(suffix=".log", delete=False).name
    proc = subprocess.Popen(["sleep", "10"])
    try:
        wd_mod = load_watchdog_module()

        class Args:
            pid = proc.pid
            app_name = "AgentSignalBar"
            launch_timeout = 5.0
            max_duration = 10.0
            interval = 0.1
            cpu_warning = 30.0
            cpu_kill = 100.0
            cpu_kill_samples = 3
            mem_warning_mb = 150.0
            mem_kill_mb = 300.0
            mem_kill_samples = 2
            threads_warning = 25
            threads_kill = 40
            threads_kill_samples = 2
            sqlite_kill_samples = 3
            sqlite_max_age_seconds = 2.0
            max_telemetry_failures = 3
            log_file = tmp_log

        wd = wd_mod.Watchdog(Args())
        wd.check_process_status = lambda pid: ("TELEMETRY_FAILURE", None)

        exit_code = wd.run()
        proc.poll()
        assert proc.returncode is not None, "Target process should be killed on telemetry failure limit!"
        assert exit_code == 6, f"Expected exit code 6 for telemetry failure, got {exit_code}"

        with open(tmp_log) as f:
            content = f.read()
        assert "TELEMETRY_FAILURE_EXCEEDED" in content
        assert "WARNING: Telemetry read failure" in content
        assert "TARGET_EXITED_NORMALLY" not in content
        print("PASSED")
    finally:
        proc.poll()
        if proc.returncode is None:
            proc.kill()
        if os.path.exists(tmp_log):
            os.remove(tmp_log)

def test_thread_telemetry_failure_not_masquerading_as_zero():
    print("Test 12: Testing thread telemetry failure cannot masquerade as zero healthy threads...", end=" ", flush=True)
    tmp_log = tempfile.NamedTemporaryFile(suffix=".log", delete=False).name
    proc = subprocess.Popen(["sleep", "10"])
    try:
        wd_mod = load_watchdog_module()

        class Args:
            pid = proc.pid
            app_name = "AgentSignalBar"
            launch_timeout = 5.0
            max_duration = 10.0
            interval = 0.1
            cpu_warning = 30.0
            cpu_kill = 100.0
            cpu_kill_samples = 3
            mem_warning_mb = 150.0
            mem_kill_mb = 300.0
            mem_kill_samples = 2
            threads_warning = 25
            threads_kill = 40
            threads_kill_samples = 2
            sqlite_kill_samples = 3
            sqlite_max_age_seconds = 2.0
            max_telemetry_failures = 3
            log_file = tmp_log

        wd = wd_mod.Watchdog(Args())
        # Thread count returns None (telemetry read failure)
        wd.get_thread_count = lambda pid: None

        exit_code = wd.run()
        proc.poll()
        assert proc.returncode is not None, "Target process should be killed when thread telemetry fails repeatedly!"
        assert exit_code == 6, f"Expected exit code 6 for telemetry failure, got {exit_code}"

        with open(tmp_log) as f:
            content = f.read()
        assert "TELEMETRY_FAILURE_EXCEEDED" in content
        assert "threads" in content
        print("PASSED")
    finally:
        proc.poll()
        if proc.returncode is None:
            proc.kill()
        if os.path.exists(tmp_log):
            os.remove(tmp_log)

def test_child_telemetry_failure_not_masquerading_as_no_children():
    print("Test 13: Testing child telemetry failure cannot masquerade as no children/no SQLite...", end=" ", flush=True)
    tmp_log = tempfile.NamedTemporaryFile(suffix=".log", delete=False).name
    proc = subprocess.Popen(["sleep", "10"])
    try:
        wd_mod = load_watchdog_module()

        class Args:
            pid = proc.pid
            app_name = "AgentSignalBar"
            launch_timeout = 5.0
            max_duration = 10.0
            interval = 0.1
            cpu_warning = 30.0
            cpu_kill = 100.0
            cpu_kill_samples = 3
            mem_warning_mb = 150.0
            mem_kill_mb = 300.0
            mem_kill_samples = 2
            threads_warning = 25
            threads_kill = 40
            threads_kill_samples = 2
            sqlite_kill_samples = 3
            sqlite_max_age_seconds = 2.0
            max_telemetry_failures = 3
            log_file = tmp_log

        wd = wd_mod.Watchdog(Args())
        # Child processes returns None (telemetry read failure)
        wd.get_child_processes = lambda pid: None

        exit_code = wd.run()
        proc.poll()
        assert proc.returncode is not None, "Target process should be killed when child telemetry fails repeatedly!"
        assert exit_code == 6, f"Expected exit code 6 for telemetry failure, got {exit_code}"

        with open(tmp_log) as f:
            content = f.read()
        assert "TELEMETRY_FAILURE_EXCEEDED" in content
        assert "children" in content
        print("PASSED")
    finally:
        proc.poll()
        if proc.returncode is None:
            proc.kill()
        if os.path.exists(tmp_log):
            os.remove(tmp_log)

def test_transient_telemetry_failure_recovers_without_kill():
    print("Test 14: Testing transient telemetry failure recovers without unnecessary kill...", end=" ", flush=True)
    tmp_log = tempfile.NamedTemporaryFile(suffix=".log", delete=False).name
    proc = subprocess.Popen(["sleep", "2"])
    try:
        wd_mod = load_watchdog_module()

        class Args:
            pid = proc.pid
            app_name = "AgentSignalBar"
            launch_timeout = 5.0
            max_duration = 10.0
            interval = 0.1
            cpu_warning = 30.0
            cpu_kill = 100.0
            cpu_kill_samples = 3
            mem_warning_mb = 150.0
            mem_kill_mb = 300.0
            mem_kill_samples = 2
            threads_warning = 25
            threads_kill = 40
            threads_kill_samples = 2
            sqlite_kill_samples = 3
            sqlite_max_age_seconds = 2.0
            max_telemetry_failures = 3
            log_file = tmp_log

        wd = wd_mod.Watchdog(Args())
        real_get_threads = wd.get_thread_count
        attempts = 0

        def flaky_get_threads(pid):
            nonlocal attempts
            attempts += 1
            if attempts == 1:
                return None # Fail first sample
            return real_get_threads(pid) # Recover on sample 2+

        wd.get_thread_count = flaky_get_threads

        exit_code = wd.run()
        assert exit_code == 0, f"Expected exit code 0 on transient recovery, got {exit_code}"

        with open(tmp_log) as f:
            content = f.read()
        assert "WARNING: Telemetry read failure" in content
        assert "TARGET_EXITED_NORMALLY" in content or "NORMAL_COMPLETION" in content
        print("PASSED")
    finally:
        proc.poll()
        if proc.returncode is None:
            proc.kill()
        if os.path.exists(tmp_log):
            os.remove(tmp_log)

def test_descendant_process_tree_cleanup():
    print("Test 15: Testing descendant process tree cleanup on watchdog kill...", end=" ", flush=True)
    tmp_log = tempfile.NamedTemporaryFile(suffix=".log", delete=False).name
    pid_file = tempfile.NamedTemporaryFile(suffix=".txt", delete=False).name
    try:
        script = f"""
import subprocess, sys, time
c = subprocess.Popen([sys.executable, '-c', 'import subprocess, sys, time; g = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"]); time.sleep(30)'])
time.sleep(0.5)
out = subprocess.check_output(['ps', '-ax', '-o', 'pid=,ppid=']).decode()
gc_pid = None
for line in out.splitlines():
    parts = line.strip().split()
    if len(parts) >= 2 and int(parts[1]) == c.pid:
        gc_pid = int(parts[0])
        break
with open('{pid_file}', 'w') as f:
    f.write(f"{{c.pid}},{{gc_pid}}\\n")
    f.flush()
time.sleep(30)
"""
        parent = subprocess.Popen([sys.executable, "-c", script])
        parent_pid = parent.pid

        # Wait for pid_file to be written
        for _ in range(50):
            if os.path.exists(pid_file) and os.path.getsize(pid_file) > 0:
                break
            time.sleep(0.1)

        with open(pid_file) as f:
            line = f.read().strip()
        parts = line.split(",")
        child_pid = int(parts[0])
        gc_pid = int(parts[1]) if parts[1] != 'None' else None

        res = subprocess.run([
            sys.executable, WATCHDOG_PATH,
            "--pid", str(parent_pid),
            "--max-duration", "0.8",
            "--interval", "0.2",
            "--log-file", tmp_log
        ], capture_output=True, text=True)

        time.sleep(0.5)

        parent.poll()
        assert parent.returncode is not None, f"Parent process PID {parent_pid} should be dead!"

        def is_alive(p):
            if not p:
                return False
            try:
                os.kill(p, 0)
                return True
            except OSError:
                return False

        assert not is_alive(child_pid), f"Child PID {child_pid} should be dead!"
        if gc_pid:
            assert not is_alive(gc_pid), f"Grandchild PID {gc_pid} should be dead!"
        print("PASSED")
    finally:
        if parent.poll() is None:
            parent.kill()
        if os.path.exists(pid_file):
            os.remove(pid_file)
        if os.path.exists(tmp_log):
            os.remove(tmp_log)

def test_unrelated_sqlite_processes_not_killed():
    print("Test 16: Testing watchdog NEVER kills unrelated system sqlite processes...", end=" ", flush=True)
    tmp_log = tempfile.NamedTemporaryFile(suffix=".log", delete=False).name
    unrelated_script = "import sys, time; tag = 'sqlite3_unrelated_test'; time.sleep(20)"
    unrelated_proc = subprocess.Popen([sys.executable, "-c", unrelated_script])
    target_proc = subprocess.Popen(["sleep", "60"])

    try:
        res = subprocess.run([
            sys.executable, WATCHDOG_PATH,
            "--pid", str(target_proc.pid),
            "--max-duration", "0.8",
            "--interval", "0.2",
            "--log-file", tmp_log
        ], capture_output=True, text=True)

        target_proc.poll()
        assert target_proc.returncode is not None, "Target process should have been terminated by watchdog!"

        unrelated_proc.poll()
        assert unrelated_proc.returncode is None, "Unrelated sqlite process MUST NOT be killed by watchdog!"
        print("PASSED")
    finally:
        unrelated_proc.kill()
        target_proc.poll()
        if target_proc.returncode is None:
            target_proc.kill()
        if os.path.exists(tmp_log):
            os.remove(tmp_log)

def run_all_tests():
    print("=" * 60)
    print("RUNNING FULL WATCHDOG CLOSEOUT STATIC VALIDATION SUITE")
    print("=" * 60)
    test_help_and_defaults()
    test_launch_timeout_nonexistent_app()
    test_normal_completion_with_dummy_process()
    test_hard_duration_kill()
    test_thread_count_exceeded_kill()
    test_cpu_exceeded_kill()
    test_memory_rss_exceeded_kill()
    test_same_pid_sqlite_under_age_threshold_no_kill()
    test_same_pid_sqlite_exceeding_both_samples_and_age_triggers_kill()
    test_different_short_lived_sqlite_pids_no_false_trigger()
    test_telemetry_failure_not_reported_as_normal_exit()
    test_thread_telemetry_failure_not_masquerading_as_zero()
    test_child_telemetry_failure_not_masquerading_as_no_children()
    test_transient_telemetry_failure_recovers_without_kill()
    test_descendant_process_tree_cleanup()
    test_unrelated_sqlite_processes_not_killed()
    print("=" * 60)
    print("ALL 16 WATCHDOG CLOSEOUT STATIC VALIDATION TESTS PASSED CLEANLY!")
    print("=" * 60)

if __name__ == "__main__":
    run_all_tests()
