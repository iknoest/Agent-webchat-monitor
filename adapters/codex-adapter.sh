#!/bin/bash
# Codex Desktop AgentSignalBar Adapter
# Usage: ./codex-adapter.sh [working|done|blocked|idle] [detail_message]

STATUS="${1:-working}"
DETAIL="${2:-Codex Desktop active}"
URL="http://127.0.0.1:18888/status"

curl -s -X POST "$URL" \
  -H "Content-Type: application/json" \
  -d "{\"agent\":\"codex\",\"status\":\"$STATUS\",\"detail\":\"$DETAIL\"}"
