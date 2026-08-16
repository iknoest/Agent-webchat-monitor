#!/usr/bin/env python3
import sys
import json
import os
import time
import urllib.request

SERVER_URL = "http://127.0.0.1:18888/hooks/claude"

def main():
    event_arg = sys.argv[1] if len(sys.argv) > 1 else "Unknown"
    raw_input = ""
    try:
        raw_input = sys.stdin.read()
    except Exception:
        pass

    data = {}
    if raw_input.strip():
        try:
            data = json.loads(raw_input)
        except Exception:
            data = {}

    session_id = data.get("session_id") or data.get("sessionId") or os.environ.get("CLAUDE_SESSION_ID", "unknown_session")
    cwd = data.get("cwd") or data.get("workspace_dir") or os.getcwd()
    timestamp = time.strftime("%Y-%m-%dT%H:%M:%S%z")

    payload = {
        "event": event_arg,
        "session_id": session_id,
        "cwd": cwd,
        "timestamp": timestamp,
        "tool_name": data.get("tool_name") or data.get("tool"),
        "prompt_id": data.get("prompt_id"),
        "reason": data.get("reason"),
        "error": data.get("error")
    }

    try:
        req_data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            SERVER_URL,
            data=req_data,
            headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req, timeout=1.0) as resp:
            _ = resp.read()
    except Exception:
        pass

    sys.exit(0)

if __name__ == "__main__":
    main()
