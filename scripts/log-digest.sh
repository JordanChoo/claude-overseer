#!/usr/bin/env bash
# log-digest.sh — Filter and summarize recent logs
# Usage: ./log-digest.sh [minutes_back] [log_path]

set -euo pipefail

MINUTES_BACK="${1:-30}"
LOG_PATH="${2:-}"

echo "=== Log Digest ==="
echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Window: last ${MINUTES_BACK} minutes"
echo ""

# --- Customize for your log sources ---

# Option 1: Scan a log file
if [ -n "$LOG_PATH" ] && [ -f "$LOG_PATH" ]; then
    CUTOFF=$(date -u -v-${MINUTES_BACK}M +%Y-%m-%dT%H:%M:%S 2>/dev/null || \
             date -u -d "${MINUTES_BACK} minutes ago" +%Y-%m-%dT%H:%M:%S 2>/dev/null || \
             echo "")

    echo "--- Errors ---"
    grep -i "error\|exception\|fatal\|panic" "$LOG_PATH" | tail -20 || echo "(none)"

    echo ""
    echo "--- Warnings ---"
    grep -i "warn" "$LOG_PATH" | tail -10 || echo "(none)"

    echo ""
    echo "--- Summary ---"
    TOTAL=$(wc -l < "$LOG_PATH" | tr -d ' ')
    ERRORS=$(grep -ci "error\|exception\|fatal\|panic" "$LOG_PATH" || echo "0")
    WARNINGS=$(grep -ci "warn" "$LOG_PATH" || echo "0")
    echo "Total lines: $TOTAL"
    echo "Errors: $ERRORS"
    echo "Warnings: $WARNINGS"

# Option 2: Check system logs (macOS)
elif command -v log &>/dev/null; then
    echo "--- Recent System Errors (last ${MINUTES_BACK}m) ---"
    log show --last "${MINUTES_BACK}m" --predicate 'eventMessage contains "error" OR eventMessage contains "fatal"' --style compact 2>/dev/null | tail -20 || echo "(no system log errors)"

# Option 3: Check journalctl (Linux)
elif command -v journalctl &>/dev/null; then
    echo "--- Recent Journal Errors (last ${MINUTES_BACK}m) ---"
    journalctl --since "${MINUTES_BACK} minutes ago" -p err --no-pager -q 2>/dev/null | tail -20 || echo "(no journal errors)"

else
    echo "[INFO] No log source configured. Set LOG_PATH or customize this script."
    echo "Usage: $0 [minutes_back] [/path/to/logfile]"
fi

echo ""
echo "=== Log Digest Complete ==="
