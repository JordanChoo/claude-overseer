#!/usr/bin/env bash
# health-check.sh — Deterministic deployment health checks
# Exit codes: 0 = healthy, 1 = warning, 2 = critical

set -euo pipefail

STATUS=0

echo "=== Deployment Health Check ==="
echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

# --- Customize these checks for your environment ---

# Example: Check if a service endpoint is responding
# Uncomment and modify for your setup:
#
# SERVICE_URL="${SERVICE_URL:-http://localhost:3000/health}"
# HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$SERVICE_URL" 2>/dev/null || echo "000")
# if [ "$HTTP_CODE" = "200" ]; then
#     echo "[OK] Service responding (HTTP $HTTP_CODE)"
# elif [ "$HTTP_CODE" = "000" ]; then
#     echo "[CRIT] Service unreachable"
#     STATUS=2
# else
#     echo "[WARN] Service returned HTTP $HTTP_CODE"
#     STATUS=1
# fi

# Example: Check disk usage
DISK_USAGE=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
if [ "$DISK_USAGE" -gt 90 ]; then
    echo "[CRIT] Disk usage at ${DISK_USAGE}%"
    STATUS=2
elif [ "$DISK_USAGE" -gt 75 ]; then
    echo "[WARN] Disk usage at ${DISK_USAGE}%"
    [ "$STATUS" -lt 1 ] && STATUS=1
else
    echo "[OK] Disk usage at ${DISK_USAGE}%"
fi

# Example: Check memory usage
if command -v vm_stat &>/dev/null; then
    # macOS
    FREE_PAGES=$(vm_stat | awk '/Pages free/ {gsub(/\./,"",$3); print $3}')
    INACTIVE_PAGES=$(vm_stat | awk '/Pages inactive/ {gsub(/\./,"",$3); print $3}')
    TOTAL_FREE=$(( (FREE_PAGES + INACTIVE_PAGES) * 4096 / 1048576 ))
    echo "[INFO] Available memory: ~${TOTAL_FREE}MB"
else
    # Linux
    MEM_AVAIL=$(awk '/MemAvailable/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo "unknown")
    echo "[INFO] Available memory: ${MEM_AVAIL}MB"
fi

echo ""
echo "=== Health Check Complete (exit: $STATUS) ==="
exit $STATUS
