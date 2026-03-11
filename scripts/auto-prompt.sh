#!/usr/bin/env bash
#
# auto-prompt.sh — Send random prompts to idle agent panes in a tmux session.
#
# Detects idle panes using NTM-style content pattern matching, selects a random
# prompt from a configurable mix of NTM palette and custom prompt files, and
# sends it via NTM. Tracks prompted panes to avoid spamming — a pane must
# become Active again before receiving another prompt.
#
# Usage: ./auto-prompt.sh --session <name> [OPTIONS]
#
# Exit codes: 0 = success, 1 = prompts sent, 2 = critical error

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SESSION=""
NTM_PALETTE_DIR="$HOME/.config/ntm/palettes"
CUSTOM_PROMPTS_FILE="$REPO_DIR/custom-prompts.md"
PROMPTS_CONF="$REPO_DIR/prompts.conf"
SNAPSHOT_INTERVAL=10
SNAPSHOT_CHECKS=3
SEND_DELAY_MIN=2
SEND_DELAY_MAX=5
SKIP_PANES="0"        # comma-separated pane indices to skip (default: 0 = NTM user pane)
AGENT_TYPE_FILTER=""  # empty = all types

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
  --prompts-conf FILE      Path to prompts.conf (default: <repo>/prompts.conf)
  --ntm-palette-dir DIR    NTM palette directory (default: ~/.config/ntm/palettes)
  --custom-prompts FILE    Custom prompts markdown file (default: <repo>/custom-prompts.md)
  --snapshot-interval SEC  Seconds between content snapshots (default: 10)
  --snapshot-checks N      Number of snapshots to compare (default: 3)
  --skip-panes LIST        Comma-separated pane indices to skip (default: 0)
  --send-delay MIN,MAX     Random delay range between sends (default: 2,5)
  --agent-type TYPE        Only prompt agents of this type: cc, cod (default: all)
  --notes-dir DIR          Directory to write findings (default: none)
  -h, --help               Show this help

Examples:
  $(basename "$0") --session myproject
  $(basename "$0") --session myproject --agent-type cc
  $(basename "$0") --session myproject --send-delay 3,8
  $(basename "$0") --session myproject --skip-panes "0,2"
EOF
  exit 0
}

NOTES_DIR=""

# --- Parse arguments ---

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session)            SESSION="$2"; shift 2 ;;
    --prompts-conf)       PROMPTS_CONF="$2"; shift 2 ;;
    --ntm-palette-dir)    NTM_PALETTE_DIR="$2"; shift 2 ;;
    --custom-prompts)     CUSTOM_PROMPTS_FILE="$2"; shift 2 ;;
    --snapshot-interval)  SNAPSHOT_INTERVAL="$2"; shift 2 ;;
    --snapshot-checks)    SNAPSHOT_CHECKS="$2"; shift 2 ;;
    --send-delay)
      IFS=',' read -r SEND_DELAY_MIN SEND_DELAY_MAX <<< "$2"
      shift 2
      ;;
    --skip-panes)         SKIP_PANES="$2"; shift 2 ;;
    --agent-type)         AGENT_TYPE_FILTER="$2"; shift 2 ;;
    --notes-dir)          NOTES_DIR="$2"; shift 2 ;;
    -h|--help)            usage ;;
    *)                    echo "Unknown option: $1" >&2; usage ;;
  esac
done

if [[ -z "$SESSION" ]]; then
  echo "Error: --session is required" >&2
  exit 2
fi

# --- Parse skip panes into array ---

IFS=',' read -ra SKIP_PANES_ARR <<< "$SKIP_PANES"

should_skip_pane() {
  local pane="$1"
  for skip in "${SKIP_PANES_ARR[@]}"; do
    [[ "$pane" -eq "$skip" ]] && return 0
  done
  return 1
}

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

# --- Verify session exists ---

if ! "$TMUX_BIN" has-session -t "$SESSION" 2>/dev/null; then
  echo "Error: tmux session '$SESSION' not found" >&2
  exit 2
fi

# --- Parse custom-prompts.md into associative array ---
# Format: # heading = name, text until next # heading or --- or EOF = prompt body

declare -A CUSTOM_PROMPTS

if [[ -f "$CUSTOM_PROMPTS_FILE" ]]; then
  current_name=""
  current_body=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^#[[:space:]]+(.+)$ ]]; then
      # Save previous prompt if exists
      if [[ -n "$current_name" && -n "$current_body" ]]; then
        CUSTOM_PROMPTS["$current_name"]="$(echo "$current_body" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      fi
      current_name="${BASH_REMATCH[1]}"
      current_name=$(echo "$current_name" | xargs)  # trim
      current_body=""
    elif [[ "$line" == "---" ]]; then
      # Separator — save current and reset
      if [[ -n "$current_name" && -n "$current_body" ]]; then
        CUSTOM_PROMPTS["$current_name"]="$(echo "$current_body" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      fi
      current_name=""
      current_body=""
    else
      current_body+="$line"$'\n'
    fi
  done < "$CUSTOM_PROMPTS_FILE"

  # Save last prompt
  if [[ -n "$current_name" && -n "$current_body" ]]; then
    CUSTOM_PROMPTS["$current_name"]="$(echo "$current_body" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  fi
fi

# --- Load prompt list from config ---

if [[ ! -f "$PROMPTS_CONF" ]]; then
  echo "Error: prompts config not found at $PROMPTS_CONF" >&2
  exit 2
fi

# Each entry is "type:name" — we store them and resolve at send time
declare -a PROMPT_NAMES
declare -a PROMPT_TYPES

while IFS= read -r line; do
  # Skip comments and blank lines
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
  line=$(echo "$line" | xargs)  # trim whitespace
  [[ -z "$line" ]] && continue

  if [[ "$line" == ntm:* ]]; then
    palette_name="${line#ntm:}"
    palette_file="$NTM_PALETTE_DIR/$palette_name.md"
    if [[ ! -f "$palette_file" ]]; then
      log "WARNING: NTM palette file not found: $palette_file — skipping"
      continue
    fi
    PROMPT_TYPES+=("ntm")
    PROMPT_NAMES+=("$palette_name")
  elif [[ "$line" == custom:* ]]; then
    prompt_name="${line#custom:}"
    if [[ -z "${CUSTOM_PROMPTS[$prompt_name]+x}" ]]; then
      log "WARNING: Custom prompt '$prompt_name' not found in $CUSTOM_PROMPTS_FILE — skipping"
      continue
    fi
    PROMPT_TYPES+=("custom")
    PROMPT_NAMES+=("$prompt_name")
  else
    log "WARNING: Unknown prompt entry format: $line — skipping"
  fi
done < "$PROMPTS_CONF"

PROMPT_COUNT=${#PROMPT_NAMES[@]}

if [[ $PROMPT_COUNT -eq 0 ]]; then
  echo "Error: no valid prompts found in $PROMPTS_CONF" >&2
  exit 2
fi

log "=== Auto-Prompter ==="
log "Session: $SESSION"
log "Prompts loaded: $PROMPT_COUNT"
log "Agent type filter: ${AGENT_TYPE_FILTER:-all}"
log "Send delay: ${SEND_DELAY_MIN}-${SEND_DELAY_MAX}s"
log ""

# --- State directory for tracking prompted panes ---

STATE_DIR="$HOME/.ntm/auto-prompt-state/$SESSION"
mkdir -p "$STATE_DIR"

# --- Get pane list ---

mapfile -t PANE_INDICES < <("$TMUX_BIN" list-panes -t "$SESSION" -F "#{pane_index}" 2>/dev/null)

if [[ ${#PANE_INDICES[@]} -eq 0 ]]; then
  echo "Error: no panes found in session '$SESSION'" >&2
  exit 2
fi

# --- Take content snapshots ---

declare -A content_hashes
declare -A content_changed

for (( c = 0; c < SNAPSHOT_CHECKS; c++ )); do
  [[ $c -gt 0 ]] && sleep "$SNAPSHOT_INTERVAL"

  for pane_idx in "${PANE_INDICES[@]}"; do
    should_skip_pane "$pane_idx" && continue

    hash=$("$TMUX_BIN" capture-pane -t "$SESSION:0.$pane_idx" -p 2>/dev/null | md5 -q 2>/dev/null || \
           "$TMUX_BIN" capture-pane -t "$SESSION:0.$pane_idx" -p 2>/dev/null | md5sum 2>/dev/null | awk '{print $1}')

    key="${pane_idx}_${c}"
    content_hashes[$key]="$hash"

    if [[ $c -gt 0 ]]; then
      prev_key="${pane_idx}_$(( c - 1 ))"
      if [[ "${content_hashes[$key]}" != "${content_hashes[$prev_key]}" ]]; then
        content_changed[$pane_idx]="true"
      fi
    fi
  done

  log "Snapshot $((c + 1))/$SNAPSHOT_CHECKS taken"
done

log ""

# --- Helpers for prompt selection and delay ---

pick_random_prompt_index() {
  echo $(( $(od -An -tu4 -N4 /dev/urandom | tr -d ' ') % PROMPT_COUNT ))
}

random_delay() {
  local range=$(( SEND_DELAY_MAX - SEND_DELAY_MIN + 1 ))
  local delay=$(( ($(od -An -tu4 -N4 /dev/urandom | tr -d ' ') % range) + SEND_DELAY_MIN ))
  sleep "$delay"
}

# --- Analyze each pane ---

STATUS=0
SENDS=0
FINDINGS=""

for pane_idx in "${PANE_INDICES[@]}"; do
  should_skip_pane "$pane_idx" && continue

  pane_target="$SESSION:0.$pane_idx"
  pane_label="pane-$pane_idx"
  prompted_file="$STATE_DIR/prompted_$pane_idx"

  # --- Detect agent type ---

  pane_content=$("$TMUX_BIN" capture-pane -t "$pane_target" -p 2>/dev/null || echo "")
  pane_last_lines=$(echo "$pane_content" | tail -10)

  agent_type="unknown"
  if echo "$pane_content" | grep -qiE '\b(opus|claude|sonnet|haiku)\b'; then
    agent_type="cc"
  elif echo "$pane_content" | grep -qiE '\b(codex|openai|gpt-[0-9])\b'; then
    agent_type="cod"
  fi

  # --- Apply agent type filter ---

  if [[ -n "$AGENT_TYPE_FILTER" && "$agent_type" != "$AGENT_TYPE_FILTER" ]]; then
    continue
  fi

  # --- Check if pane is active (content changing) ---

  is_active="${content_changed[$pane_idx]:-false}"

  if [[ "$is_active" == "true" ]]; then
    # Pane is active — clear prompted flag so it can receive a new prompt when idle
    if [[ -f "$prompted_file" ]]; then
      log "$pane_label [$agent_type]: Active — clearing prompted flag"
      rm -f "$prompted_file"
    else
      log "$pane_label [$agent_type]: Active"
    fi
    continue
  fi

  # --- Check for working indicators (spinners, tool use) ---

  is_working=false
  case "$agent_type" in
    cc)
      if echo "$pane_last_lines" | grep -qE '\S+…\s+\(|·\s*thinking|·\s*thought\s+for|Running…'; then
        is_working=true
      fi
      if echo "$pane_last_lines" | grep -qE 'writing to |reading |searching |running |executing |installing '; then
        is_working=true
      fi
      ;;
    cod)
      if echo "$pane_last_lines" | grep -qE 'editing |creating |writing |reading |running |applying |patching '; then
        is_working=true
      fi
      ;;
  esac

  if [[ "$is_working" == "true" ]]; then
    log "$pane_label [$agent_type]: Working (tool/spinner detected)"
    continue
  fi

  # --- Check for idle prompt indicators ---

  is_idle=false
  case "$agent_type" in
    cc)
      if echo "$pane_last_lines" | grep -qE '>\s*$|❯\s*$|╰─>\s*$|Human:\s*$'; then
        is_idle=true
      fi
      # Welcome screen / fresh start
      if echo "$pane_last_lines" | grep -qiE 'claude\s+code\s+v[0-9]|welcome\s+back'; then
        is_idle=true
      fi
      ;;
    cod)
      if echo "$pane_last_lines" | grep -qiE 'codex>\s*$|›\s*$|>\s*$|\?\s*for\s*shortcuts'; then
        is_idle=true
      fi
      ;;
    *)
      if echo "$pane_last_lines" | grep -qE '>\s*$|\$\s*$'; then
        is_idle=true
      fi
      ;;
  esac

  if [[ "$is_idle" != "true" ]]; then
    log "$pane_label [$agent_type]: Not idle, not active — skipping"
    continue
  fi

  # --- Check for rate limiting ---

  if echo "$pane_content" | grep -qiE "you've hit your limit|rate limit|too many requests|usage limit|quota exceeded"; then
    log "$pane_label [$agent_type]: Rate limited — skipping"
    continue
  fi

  # --- Check if already prompted ---

  if [[ -f "$prompted_file" ]]; then
    log "$pane_label [$agent_type]: Idle but already prompted — waiting for activity"
    continue
  fi

  # --- Send a random prompt ---

  # Stagger sends
  if [[ $SENDS -gt 0 ]]; then
    random_delay
  fi

  chosen_idx=$(pick_random_prompt_index)
  chosen_type="${PROMPT_TYPES[$chosen_idx]}"
  chosen_name="${PROMPT_NAMES[$chosen_idx]}"
  send_success=false

  log "$pane_label [$agent_type]: Idle — sending '$chosen_name' ($chosen_type)"

  if [[ "$chosen_type" == "ntm" ]]; then
    # NTM palette prompt — send via NTM with file path
    palette_file="$NTM_PALETTE_DIR/$chosen_name.md"
    if ntm --robot-send="$SESSION" --panes="$pane_idx" --file="$palette_file" 2>/dev/null; then
      send_success=true
      log "  Sent via NTM"
    else
      # Fallback: read palette file and send via tmux
      prompt_content=$(cat "$palette_file" 2>/dev/null || echo "")
      if [[ -n "$prompt_content" ]]; then
        "$TMUX_BIN" send-keys -t "$pane_target" "$prompt_content" Enter 2>/dev/null
        send_success=true
        log "  Sent via tmux fallback"
      fi
    fi
  elif [[ "$chosen_type" == "custom" ]]; then
    # Custom inline prompt — send text via NTM message flag
    prompt_text="${CUSTOM_PROMPTS[$chosen_name]}"
    if ntm --robot-send="$SESSION" --panes="$pane_idx" --msg="$prompt_text" 2>/dev/null; then
      send_success=true
      log "  Sent via NTM"
    else
      # Fallback: send via tmux
      "$TMUX_BIN" send-keys -t "$pane_target" "$prompt_text" Enter 2>/dev/null
      send_success=true
      log "  Sent via tmux fallback"
    fi
  fi

  if [[ "$send_success" == "true" ]]; then
    touch "$prompted_file"
    SENDS=$(( SENDS + 1 ))
    STATUS=1
    FINDINGS+="[INFO] $pane_label ($agent_type): Sent prompt '$chosen_name'\n"
  else
    log "  WARNING: Failed to send prompt"
    FINDINGS+="[WARN] $pane_label ($agent_type): Failed to send prompt '$chosen_name'\n"
  fi
done

# --- Write findings to daily notes ---

if [[ -n "$NOTES_DIR" && -n "$FINDINGS" ]]; then
  mkdir -p "$NOTES_DIR"
  NOTES_FILE="$NOTES_DIR/auto-prompt-$(date +%Y-%m-%d).md"

  {
    echo ""
    echo "## $(timestamp)"
    echo ""
    echo -e "$FINDINGS"
  } >> "$NOTES_FILE"
fi

# --- Summary ---

log ""
log "=== Auto-Prompter Complete ==="
log "Prompts sent: $SENDS"

if [[ $SENDS -gt 0 ]]; then
  echo ""
  echo -e "$FINDINGS"
fi

exit $STATUS
