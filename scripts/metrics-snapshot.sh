#!/usr/bin/env bash
# metrics-snapshot.sh — Capture key system/application metrics
# Exit codes: 0 = normal, 1 = degraded

set -euo pipefail

STATUS=0

echo "=== Metrics Snapshot ==="
echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

# --- System Metrics ---

echo "--- System ---"

# CPU load
LOAD=$(uptime | awk -F'load averages?:' '{print $2}' | awk '{print $1}' | tr -d ',')
echo "Load (1m): $LOAD"

# Disk
DISK_USED=$(df -h / | awk 'NR==2 {print $5}')
echo "Disk used: $DISK_USED"

# Memory (macOS)
if command -v vm_stat &>/dev/null; then
    FREE_PAGES=$(vm_stat | awk '/Pages free/ {gsub(/\./,"",$3); print $3}')
    ACTIVE_PAGES=$(vm_stat | awk '/Pages active/ {gsub(/\./,"",$3); print $3}')
    echo "Memory active pages: $ACTIVE_PAGES"
    echo "Memory free pages: $FREE_PAGES"
fi

# Process count
PROC_COUNT=$(ps aux | wc -l | tr -d ' ')
echo "Process count: $PROC_COUNT"

echo ""

# --- Application Metrics (customize) ---

echo "--- Application ---"

# Example: Check if key processes are running
# Uncomment and modify:
#
# for PROC in "node" "postgres" "redis"; do
#     if pgrep -x "$PROC" > /dev/null 2>&1; then
#         echo "[OK] $PROC is running"
#     else
#         echo "[WARN] $PROC is NOT running"
#         STATUS=1
#     fi
# done

# Example: HTTP endpoint latency
# SERVICE_URL="${SERVICE_URL:-http://localhost:3000/health}"
# LATENCY=$(curl -s -o /dev/null -w "%{time_total}" --max-time 10 "$SERVICE_URL" 2>/dev/null || echo "timeout")
# echo "Endpoint latency: ${LATENCY}s"
# if [ "$LATENCY" = "timeout" ]; then
#     STATUS=1
# fi

echo "(configure application-specific metrics in this script)"

echo ""

# --- Git/Repo Status ---

echo "--- Repository ---"
if command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null; then
    BRANCH=$(git branch --show-current 2>/dev/null || echo "detached")
    COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    echo "Branch: $BRANCH"
    echo "Commit: $COMMIT"
else
    echo "(not in a git repository)"
fi

echo ""
echo "=== Metrics Snapshot Complete (exit: $STATUS) ==="
exit $STATUS
