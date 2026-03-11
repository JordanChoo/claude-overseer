#!/usr/bin/env bash
#
# pane-watchdog.sh — Detect frozen LLM panes in a tmux session and restart them.
#
# Uses NTM's robot API for agent detection and pane interaction.
# Designed to be called repeatedly via Claude Code's /loop command.
#
# Usage: ./pane-watchdog.sh --session <name> [OPTIONS]
#
# Exit codes: 0 = all healthy, 1 = warning (restarts occurred), 2 = critical error

set -uo pipefail

SESSION=""
FROZEN_THRESHOLD=120  # seconds of no output change before considered frozen
SNAPSHOT_INTERVAL=10  # seconds between snapshots
SNAPSHOT_CHECKS=3     # number of snapshots to take
SKIP_PANE=0           # pane index 0 is the NTM user pane
LOG_DIR="$HOME/.ntm/logs"
NOTES_DIR=""

# --- Helpers ---

timestamp() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") --session <name> [OPTIONS]

Options:
  --session NAME           Tmux session name (required)
  --frozen-threshold SEC   Seconds of inactivity before frozen (default: 120)
  --snapshot-interval SEC  Seconds between content snapshots (default: 10)
  --snapshot-checks N      Number of snapshots to compare (default: 3)
  --notes-dir DIR          Directory to write findings (default: none)
  -h, --help               Show this help

Examples:
  $(basename "$0") --session myproject
  $(basename "$0") --session myproject --frozen-threshold 180 --notes-dir ./loop-notes
EOF
  exit 0
}

# --- Parse arguments ---

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session)            SESSION="$2"; shift 2 ;;
    --frozen-threshold)   FROZEN_THRESHOLD="$2"; shift 2 ;;
    --snapshot-interval)  SNAPSHOT_INTERVAL="$2"; shift 2 ;;
    --snapshot-checks)    SNAPSHOT_CHECKS="$2"; shift 2 ;;
    --notes-dir)          NOTES_DIR="$2"; shift 2 ;;
    -h|--help)            usage ;;
    *)                    echo "Unknown option: $1" >&2; usage ;;
  esac
done

if [[ -z "$SESSION" ]]; then
  echo "Error: --session is required" >&2
  exit 2
fi

# --- Verify dependencies ---

TMUX_BIN=$(command -v tmux 2>/dev/null || echo "")
if [[ -z "$TMUX_BIN" ]]; then
  for candidate in /usr/bin/tmux /usr/local/bin/tmux /opt/homebrew/bin/tmux; do
    if [[ -x "$candidate" ]]; then
      TMUX_BIN="$candidate"
      break
    fi
  done
fi
if [[ -z "$TMUX_BIN" ]]; then
  echo "Error: tmux not found" >&2
  exit 2
fi

if ! command -v ntm &>/dev/null; then
  echo "Error: ntm not found" >&2
  exit 2
fi

if ! command -v jq &>/dev/null; then
  echo "Error: jq not found" >&2
  exit 2
fi

# --- Verify session exists ---

if ! "$TMUX_BIN" has-session -t "$SESSION" 2>/dev/null; then
  echo "Error: tmux session '$SESSION' not found" >&2
  exit 2
fi

# --- State directory for tracking idle timestamps ---

STATE_DIR="$HOME/.ntm/watchdog-state/$SESSION"
mkdir -p "$STATE_DIR"

# --- Get pane list (skip pane 0 which is the NTM user pane) ---

mapfile -t PANE_INDICES < <("$TMUX_BIN" list-panes -t "$SESSION" -F "#{pane_index}" 2>/dev/null)

if [[ ${#PANE_INDICES[@]} -eq 0 ]]; then
  echo "Error: no panes found in session '$SESSION'" >&2
  exit 2
fi

log "=== Pane Watchdog ==="
log "Session: $SESSION"
log "Panes: ${#PANE_INDICES[@]} total (skipping pane $SKIP_PANE)"
log "Frozen threshold: ${FROZEN_THRESHOLD}s"
log "Snapshots: ${SNAPSHOT_CHECKS} checks, ${SNAPSHOT_INTERVAL}s apart"
log ""

# --- Take content snapshots to detect output changes ---

declare -A content_hashes_first
declare -A content_hashes_last
declare -A content_changed

for pane_idx in "${PANE_INDICES[@]}"; do
  content_changed[$pane_idx]=false
done

for (( c = 0; c < SNAPSHOT_CHECKS; c++ )); do
  [[ $c -gt 0 ]] && sleep "$SNAPSHOT_INTERVAL"

  for pane_idx in "${PANE_INDICES[@]}"; do
    [[ "$pane_idx" -eq "$SKIP_PANE" ]] && continue

    hash=$("$TMUX_BIN" capture-pane -t "$SESSION:0.$pane_idx" -p 2>/dev/null | md5 -q 2>/dev/null || \
           "$TMUX_BIN" capture-pane -t "$SESSION:0.$pane_idx" -p 2>/dev/null | md5sum 2>/dev/null | awk '{print $1}')

    if [[ $c -eq 0 ]]; then
      content_hashes_first[$pane_idx]="$hash"
    fi
    content_hashes_last[$pane_idx]="$hash"

    # Check if content changed from previous snapshot
    if [[ $c -gt 0 && "${content_hashes_last[$pane_idx]}" != "${content_hashes_first[$pane_idx]}" ]]; then
      content_changed[$pane_idx]=true
    fi
  done

  log "Snapshot $((c + 1))/$SNAPSHOT_CHECKS taken"
done

log ""

# --- Analyze each pane using NTM + snapshot data ---

STATUS=0
RESTARTS=0
FINDINGS=""

for pane_idx in "${PANE_INDICES[@]}"; do
  [[ "$pane_idx" -eq "$SKIP_PANE" ]] && continue

  pane_target="$SESSION:0.$pane_idx"
  pane_label="pane-$pane_idx"

  # --- Layer 1: Content change detection (from snapshots) ---

  output_changed="${content_changed[$pane_idx]}"

  # --- Layer 2: NTM health/status check for agent type and state ---

  # Get pane content for NTM-style analysis
  pane_content=$("$TMUX_BIN" capture-pane -t "$pane_target" -p 2>/dev/null || echo "")
  pane_last_lines=$(echo "$pane_content" | tail -10)

  # Detect agent type from pane content
  agent_type="unknown"
  if echo "$pane_content" | grep -qiE '\b(opus|claude|sonnet|haiku)\b'; then
    agent_type="cc"
  elif echo "$pane_content" | grep -qiE '\b(codex|openai|gpt-[0-9])\b'; then
    agent_type="cod"
  fi

  # Check for healthy prompt indicators (agent is idle but responsive)
  has_healthy_prompt=false
  case "$agent_type" in
    cc)
      if echo "$pane_last_lines" | grep -qE '>\s*$|❯\s*$|╰─>\s*$|Human:\s*$'; then
        has_healthy_prompt=true
      fi
      # Check for spinner/working indicators
      if echo "$pane_last_lines" | grep -qE '\S+…\s+\(|·\s*thinking|Running…'; then
        has_healthy_prompt=true  # actively working, not frozen
      fi
      ;;
    cod)
      if echo "$pane_last_lines" | grep -qiE 'codex>\s*$|›\s*$|>\s*$|\?\s*for\s*shortcuts'; then
        has_healthy_prompt=true
      fi
      ;;
    *)
      # Unknown agent — check for generic prompt
      if echo "$pane_last_lines" | grep -qE '>\s*$|\$\s*$'; then
        has_healthy_prompt=true
      fi
      ;;
  esac

  # Check for error indicators
  has_error=false
  if echo "$pane_last_lines" | grep -qiE 'panic:|fatal:|abort:|permission denied|connection refused'; then
    has_error=true
  fi

  # Check for rate limit indicators
  is_rate_limited=false
  if echo "$pane_content" | grep -qiE "you've hit your limit|rate limit|too many requests|usage limit|quota exceeded"; then
    is_rate_limited=true
  fi

  # --- Determine frozen status ---

  # Track how long this pane has been idle (no content changes)
  idle_since_file="$STATE_DIR/idle_since_$pane_idx"

  if [[ "$output_changed" == "true" ]]; then
    # Content is changing — pane is active, reset idle timer
    rm -f "$idle_since_file"
    log "$pane_label [$agent_type]: Active (output changing)"
    continue
  fi

  # Content hasn't changed across snapshots
  if [[ "$has_healthy_prompt" == "true" && "$has_error" == "false" ]]; then
    # Idle at a prompt but responsive — not frozen, just waiting
    # Still track idle time in case it persists too long
    if [[ ! -f "$idle_since_file" ]]; then
      date +%s > "$idle_since_file"
    fi
    idle_since=$(cat "$idle_since_file")
    idle_duration=$(( $(date +%s) - idle_since ))

    if [[ $idle_duration -lt $FROZEN_THRESHOLD ]]; then
      log "$pane_label [$agent_type]: Idle at prompt (${idle_duration}s) — OK"
      continue
    fi
    # If idle at prompt beyond threshold, fall through to frozen check
  fi

  if [[ "$is_rate_limited" == "true" ]]; then
    log "$pane_label [$agent_type]: Rate limited — skipping (will recover)"
    FINDINGS+="[INFO] $pane_label ($agent_type): Rate limited, waiting for reset\n"
    continue
  fi

  # --- Pane is potentially frozen ---

  # Set idle timestamp if not already set
  if [[ ! -f "$idle_since_file" ]]; then
    date +%s > "$idle_since_file"
    log "$pane_label [$agent_type]: No output change detected — starting idle timer"
    FINDINGS+="[WARN] $pane_label ($agent_type): No output change, monitoring\n"
    STATUS=1
    continue
  fi

  idle_since=$(cat "$idle_since_file")
  idle_duration=$(( $(date +%s) - idle_since ))

  if [[ $idle_duration -lt $FROZEN_THRESHOLD ]]; then
    log "$pane_label [$agent_type]: Idle for ${idle_duration}s (threshold: ${FROZEN_THRESHOLD}s) — waiting"
    continue
  fi

  # --- FROZEN: Idle beyond threshold with no healthy prompt ---

  log ""
  log "[CRIT] $pane_label [$agent_type]: FROZEN — idle for ${idle_duration}s, no healthy prompt"

  if [[ "$has_error" == "true" ]]; then
    log "  Error state detected in pane output"
  fi

  # --- Kill entire process tree in this pane ---

  pane_pid=$("$TMUX_BIN" display-message -t "$pane_target" -p '#{pane_pid}' 2>/dev/null)

  if [[ -n "$pane_pid" ]]; then
    log "  Killing process tree rooted at PID $pane_pid"

    # Kill all child processes first, then the shell
    pkill -TERM -P "$pane_pid" 2>/dev/null || true
    sleep 1
    pkill -KILL -P "$pane_pid" 2>/dev/null || true

    # Kill the shell process itself
    kill -KILL "$pane_pid" 2>/dev/null || true
    sleep 1
  fi

  # --- Restart: send a new shell and launch the LLM ---

  # Respawn the pane with a fresh shell
  "$TMUX_BIN" respawn-pane -t "$pane_target" -k 2>/dev/null || true
  sleep 2

  # Determine restart command based on detected agent type
  restart_cmd=""
  case "$agent_type" in
    cc)  restart_cmd="cc" ;;
    cod) restart_cmd="cod" ;;
    *)
      log "  WARNING: Unknown agent type, defaulting to cc"
      restart_cmd="cc"
      ;;
  esac

  log "  Restarting with: $restart_cmd"
  "$TMUX_BIN" send-keys -t "$pane_target" "$restart_cmd" Enter
  sleep 5  # Wait for LLM to initialize

  # Send register_agent as the first prompt via NTM
  log "  Sending register_agent via NTM"
  ntm --robot-send="$SESSION" --panes="$pane_idx" --msg="register_agent" 2>/dev/null || \
    "$TMUX_BIN" send-keys -t "$pane_target" "register_agent" Enter

  # Clear idle state
  rm -f "$idle_since_file"

  RESTARTS=$(( RESTARTS + 1 ))
  STATUS=1
  FINDINGS+="[CRIT] $pane_label ($agent_type): FROZEN after ${idle_duration}s — killed and restarted with $restart_cmd\n"

  log "  Restart complete"
  log ""
done

# --- Write findings to daily notes ---

if [[ -n "$NOTES_DIR" && -n "$FINDINGS" ]]; then
  mkdir -p "$NOTES_DIR"
  NOTES_FILE="$NOTES_DIR/watchdog-$(date +%Y-%m-%d).md"

  # Append to daily log
  {
    echo ""
    echo "## $(timestamp)"
    echo ""
    echo -e "$FINDINGS"
  } >> "$NOTES_FILE"
fi

# --- Summary ---

log "=== Watchdog Complete ==="
log "Restarts: $RESTARTS"

if [[ $RESTARTS -gt 0 ]]; then
  echo ""
  echo -e "$FINDINGS"
fi

exit $STATUS
