#!/bin/bash
# Claude Code AgentSignalBar Adapter
# Usage: ./claude-adapter.sh [working|done|blocked|idle] [detail_message]

STATUS="${1:-working}"
DETAIL="${2:-Claude Code active}"
URL="http://127.0.0.1:18888/status"

curl -s -X POST "$URL" \
  -H "Content-Type: application/json" \
  -d "{\"agent\":\"claude\",\"status\":\"$STATUS\",\"detail\":\"$DETAIL\"}"
