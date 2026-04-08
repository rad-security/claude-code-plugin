#!/usr/bin/env bash
# session-start.sh — SessionStart hook dispatcher
# Initializes session state and optionally checks in with the API.
# ALWAYS fail-open: any error → output {} and exit 0.

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Source shared libraries
source "${PLUGIN_ROOT}/scripts/lib/json-helpers.sh"
source "${PLUGIN_ROOT}/scripts/lib/key-resolver.sh"
source "${PLUGIN_ROOT}/scripts/lib/conflict-check.sh"
source "${PLUGIN_ROOT}/scripts/lib/nudge.sh"

# Fail-open trap
trap 'emit_allow; exit 0' ERR

# Read all of stdin (SessionStart provides session info)
INPUT=$(cat 2>/dev/null) || true

# If HTTP-based Clawkeeper hooks are already active, defer
if has_clawkeeper_http_hooks; then
  emit_allow
  exit 0
fi

# ---- Initialize session ----
DATA_DIR=$(get_data_dir)
SESSION_DIR="${DATA_DIR}/sessions"

# Create sessions directory if needed
if [ ! -d "$SESSION_DIR" ]; then
  mkdir -p "$SESSION_DIR" 2>/dev/null || true
fi

# Truncate (reset) the current session log
: > "${SESSION_DIR}/current.jsonl" 2>/dev/null || true

# Reset session_nudged flag by ensuring state file exists with fresh session
_ensure_state

# Resolve API key
API_KEY=$(resolve_api_key) || true

if [ -n "$API_KEY" ]; then
  # ---- API mode: check in with the server ----
  HOSTNAME_VAL=$(scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || printf 'unknown')
  OS_VAL=$(uname -s 2>/dev/null || printf 'unknown')
  CLAUDE_VERSION="${CLAUDE_CODE_VERSION:-unknown}"

  # Extract session_id and cwd from Claude Code's native payload so the
  # server can link subsequent HTTP hook events back to this host.
  # Uses python3 for reliable JSON parsing with grep as fallback.
  SESSION_ID=""
  CWD_VAL=""
  if [ -n "$INPUT" ]; then
    if command -v python3 &>/dev/null; then
      eval "$(printf '%s' "$INPUT" | python3 -c "
import json, sys, re
try:
    d = json.load(sys.stdin)
    sid = d.get('session_id', '')
    cwd = d.get('cwd', '')
    if sid and re.fullmatch(r'[a-zA-Z0-9_-]+', str(sid)):
        print(f'SESSION_ID={sid}')
    if cwd and re.fullmatch(r'[a-zA-Z0-9_./ -]+', str(cwd)):
        print(f'CWD_VAL=\"{cwd}\"')
except:
    pass
" 2>/dev/null)" || true
    fi
    if [ -z "$SESSION_ID" ]; then
      SESSION_ID=$(printf '%s' "$INPUT" | grep -Eo '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | grep -Eo '"[^"]*"$' | tr -d '"') || true
    fi
    if [ -z "$CWD_VAL" ]; then
      CWD_VAL=$(printf '%s' "$INPUT" | grep -Eo '"cwd"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | grep -Eo '"[^"]*"$' | tr -d '"') || true
    fi
  fi

  EXTRA_FIELDS=""
  if [ -n "$SESSION_ID" ]; then
    EXTRA_FIELDS=$(printf '%s,"session_id":"%s"' "$EXTRA_FIELDS" "$(_json_escape "$SESSION_ID")")
  fi
  if [ -n "$CWD_VAL" ]; then
    EXTRA_FIELDS=$(printf '%s,"cwd":"%s"' "$EXTRA_FIELDS" "$(_json_escape "$CWD_VAL")")
  fi

  CHECKIN_BODY=$(printf '{"hostname":"%s","os":"%s","claude_version":"%s"%s}' \
    "$(_json_escape "$HOSTNAME_VAL")" \
    "$(_json_escape "$OS_VAL")" \
    "$(_json_escape "$CLAUDE_VERSION")" \
    "$EXTRA_FIELDS")

  RESPONSE=$(printf '%s' "$CHECKIN_BODY" | curl -s --max-time 10 --fail-with-body \
    -X POST "https://clawkeeper.dev/api/v1/claude-code/checkin" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${API_KEY}" \
    -d @- 2>/dev/null) || true

  # If the API returned context, pass it through; otherwise allow
  if [ -n "$RESPONSE" ]; then
    printf '%s\n' "$RESPONSE"
  else
    emit_allow
  fi
  exit 0
fi

# ---- Local mode: session start context ----
CONTEXT_PARTS=""

# Check if we should show a weekly nudge
if should_nudge; then
  WEEKLY_NUDGE=$(get_nudge_text "session_start" "")
  if [ -n "$WEEKLY_NUDGE" ]; then
    CONTEXT_PARTS="$WEEKLY_NUDGE"
    record_nudge
  fi
fi

if [ -n "$CONTEXT_PARTS" ]; then
  ESCAPED_CONTEXT=$(_json_escape "$CONTEXT_PARTS")
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' \
    "$ESCAPED_CONTEXT"
else
  emit_allow
fi

exit 0
