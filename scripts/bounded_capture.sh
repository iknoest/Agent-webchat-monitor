#!/bin/sh
# Bounded POSIX-compliant macOS Status Capture Runner for AgentSignalBar

CAPTURE_FILE="/tmp/stage1_bounded_capture.log"
ENDPOINT="http://127.0.0.1:18888/status"
MAX_SAMPLES=20
SLEEP_INTERVAL=0.5

echo "=== STAGE 1 BOUNDED CAPTURE STARTED ===" > "$CAPTURE_FILE"
echo "Target Endpoint: $ENDPOINT" >> "$CAPTURE_FILE"

# 1. Wait for endpoint to become ready (up to 10 attempts)
READY=0
for attempt in $(seq 1 10); do
    if curl -s -f "$ENDPOINT" >/dev/null 2>&1; then
        READY=1
        break
    fi
    sleep 0.5
done

if [ "$READY" -ne 1 ]; then
    echo "ERROR_ENDPOINT_NOT_READY: Endpoint 127.0.0.1:18888 was unreachable after 5s" >> "$CAPTURE_FILE"
    echo "❌ Capture failed: Endpoint unreachable"
    exit 1
fi

VALID_SAMPLES=0
ERROR_SAMPLES=0
PREV_STATUS=""
TRANSITION_COUNT=0

# 2. Run Bounded Sample Loop (20 iterations)
for i in $(seq 1 "$MAX_SAMPLES"); do
    TS=$(date +%H:%M:%S)
    RAW=$(curl -s "$ENDPOINT" 2>/dev/null)
    
    if [ -z "$RAW" ]; then
        ERROR_SAMPLES=$((ERROR_SAMPLES + 1))
        echo "[$TS] ERROR_CONNECT_FAILED" >> "$CAPTURE_FILE"
    else
        VALID_SAMPLES=$((VALID_SAMPLES + 1))
        echo "[$TS] $RAW" >> "$CAPTURE_FILE"

        # Track transitions
        CURR_STATUS=$(echo "$RAW" | grep -o '"status" : "[^"]*"' | head -n 1 | cut -d'"' -f4)
        if [ -n "$PREV_STATUS" ] && [ "$CURR_STATUS" != "$PREV_STATUS" ]; then
            TRANSITION_COUNT=$((TRANSITION_COUNT + 1))
        fi
        PREV_STATUS="$CURR_STATUS"
    fi
    
    sleep "$SLEEP_INTERVAL"
done

echo "" >> "$CAPTURE_FILE"
echo "=== CAPTURE SUMMARY ===" >> "$CAPTURE_FILE"
echo "Valid Samples: $VALID_SAMPLES" >> "$CAPTURE_FILE"
echo "Error Samples: $ERROR_SAMPLES" >> "$CAPTURE_FILE"
echo "Observed Transitions: $TRANSITION_COUNT" >> "$CAPTURE_FILE"

echo "✅ Bounded Capture Complete! Valid Samples: $VALID_SAMPLES | Errors: $ERROR_SAMPLES | Transitions: $TRANSITION_COUNT"
exit 0
