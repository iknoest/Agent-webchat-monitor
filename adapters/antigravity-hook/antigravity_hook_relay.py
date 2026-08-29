#!/usr/bin/env python3
import sys
import json
import os
import time
import urllib.request

TRACE_FILE = "/private/tmp/agy_native_hook_trace.jsonl"
SERVER_URL = "http://127.0.0.1:18888/hooks/antigravity"

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

    conversation_id = data.get("conversationId") or data.get("conversation_id") or os.environ.get("ANTIGRAVITY_SESSION_ID", "unknown_session")
    tool_call = data.get("toolCall") or {}
    tool_name = tool_call.get("name") if isinstance(tool_call, dict) else None
    step_idx = data.get("stepIdx") or data.get("step_index")

    # Safe structured diagnostic trace (NO prompt text, NO sensitive arguments)
    top_keys = list(data.keys()) if isinstance(data, dict) else []
    tool_call_keys = list(tool_call.keys()) if isinstance(tool_call, dict) else []

    record = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "event": event_arg,
        "conversationId": conversation_id,
        "toolName": tool_name,
        "stepIdx": step_idx,
        "topKeys": top_keys,
        "toolCallKeys": tool_call_keys,
        "raw_payload_summary": {
            "has_error": "error" in data,
            "decision": data.get("decision"),
            "reason": data.get("reason"),
            "fully_idle": data.get("fullyIdle"),
            "termination_reason": data.get("terminationReason"),
            "execution_num": data.get("executionNum")
        }
    }

    # Always append to trace file BEFORE HTTP attempt
    try:
        with open(TRACE_FILE, "a", encoding="utf-8") as f:
            f.write(json.dumps(record) + "\n")
    except Exception as e:
        sys.stderr.write(f"Trace write error: {e}\n")

    # Forward to AgentSignalBar HTTP Server
    ws_paths = data.get("workspacePaths") or []
    payload = {
        "event": event_arg,
        "session_id": conversation_id,
        "cwd": ws_paths[0] if ws_paths else os.getcwd(),
        "workspace_paths": ws_paths,
        "timestamp": record["timestamp"],
        "tool_name": tool_name,
        "tool_call": tool_call,
        "step_idx": step_idx,
        "reason": data.get("reason"),
        "error": data.get("error"),
        "termination_reason": data.get("terminationReason"),
        "fully_idle": data.get("fullyIdle")
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

    # Documented hook output contract: return JSON object on stdout
    sys.stdout.write("{\"decision\": \"allow\"}\n")
    sys.stdout.flush()
    sys.exit(0)

if __name__ == "__main__":
    main()
