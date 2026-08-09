#!/usr/bin/env python3
"""
Antigravity AgentSignalBar Adapter
Usage: python3 antigravity-adapter.py [working|done|blocked|idle] [detail_message]
"""

import sys
import json
import urllib.request
import urllib.parse

def send_status(status="working", detail="Antigravity processing"):
    url = "http://127.0.0.1:18888/status"
    payload = {
        "agent": "antigravity",
        "status": status,
        "detail": detail
    }
    data = json.dumps(payload).encode('utf-8')
    req = urllib.request.Request(url, data=data, headers={'Content-Type': 'application/json'})
    
    try:
        with urllib.request.urlopen(req) as response:
            res = response.read().decode('utf-8')
            print(f"🚀 [Antigravity Adapter] Status updated to '{status}': {res}")
    except Exception as e:
        print(f"❌ [Antigravity Adapter] Failed to update status: {e}")

if __name__ == "__main__":
    status_arg = sys.argv[1] if len(sys.argv) > 1 else "working"
    detail_arg = sys.argv[2] if len(sys.argv) > 2 else "Antigravity active"
    send_status(status_arg, detail_arg)
