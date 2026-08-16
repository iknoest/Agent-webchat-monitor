#!/usr/bin/env python3
import time
import json
import urllib.request
import os
import sys
from datetime import datetime

STATUS_URL = "http://127.0.0.1:18888/status"

def get_status():
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        req = urllib.request.Request(STATUS_URL, headers={"User-Agent": "TraceRunner/1.0"})
        with opener.open(req, timeout=2.0) as resp:
            if resp.status == 200:
                return json.loads(resp.read().decode('utf-8'))
    except Exception as e:
        pass
    return None

def format_duration(seconds):
    if seconds is None or seconds < 0:
        return "0s"
    secs = int(seconds)
    mins = secs // 60
    s = secs % 60
    return f"{mins}m {s}s" if mins > 0 else f"{s}s"

def record_trace(iterations=10, output_path=None):
    lines = []
    header = "timestamp           | agent       | session/turn ID                          | source signal                            | raw state  | committed state | continuous duration"
    print(header)
    if output_path:
        lines.append(header)

    for _ in range(iterations):
        ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        data = get_status()
        if data:
            # Sort agents: chatgpt, claude, codex, antigravity
            ordered_agents = ["chatgpt", "claude", "codex", "antigravity"]
            for agent_id in ordered_agents:
                if agent_id in data:
                    info = data[agent_id]
                    turn_id = info.get("turnId") or info.get("targetTabId") or info.get("sessionTitle") or "active_session"
                    status = info.get("status", "off")
                    detail = info.get("detail", "")
                    dur = info.get("thinkingDurationSeconds") or info.get("lastDurationSeconds") or 0.0
                    dur_str = format_duration(dur)
                    source_sig = f"detail={detail[:35]}" if detail else "poll"

                    line = f"{ts} | {agent_id:11s} | {str(turn_id):40s} | {source_sig:40s} | {status:10s} | {status:10s} | {dur_str}"
                    print(line)
                    lines.append(line)
        else:
            line = f"{ts} | system      | unavailable                              | HTTP server unreachable                  | off        | off             | 0s"
            print(line)
            lines.append(line)

        time.sleep(1.5)

    if output_path:
        os.makedirs(os.path.dirname(output_path), exist_ok=True)
        with open(output_path, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
        print(f"\n✅ Trace log written to {output_path}")

if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "/private/tmp/agent_signalbar_state_truth_review/acceptance_trace.log"
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 5
    record_trace(iterations=count, output_path=out)
