#!/usr/bin/env bash
# cursor-adapter.sh — Cursor IDE hook adapter
# Normalizes Cursor's hook JSON to Claude Code format, calls shared scripts,
# translates response back to Cursor format.
# ALWAYS fail-open: any error → output {} and exit 0.

set -euo pipefail

ADAPTER_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$(cd "${ADAPTER_DIR}/.." && pwd)"

# Export for shared scripts
export CLAWKEEPER_IDE="cursor"
export CLAWKEEPER_SKIP_CONFLICT_CHECK="1"
export CLAWKEEPER_SCRIPTS_DIR="$SCRIPTS_DIR"
export CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA:-$HOME/.clawkeeper}"

# Source shared libraries with fallback paths
source "${SCRIPTS_DIR}/lib/json-helpers.sh" 2>/dev/null || true
source "${SCRIPTS_DIR}/lib/key-resolver.sh" 2>/dev/null || true
source "${SCRIPTS_DIR}/lib/dedup.sh" 2>/dev/null || true
source "${SCRIPTS_DIR}/lib/debug-log.sh" 2>/dev/null || true
source "${SCRIPTS_DIR}/lib/machine-id.sh" 2>/dev/null || true

# Cursor-specific fail-open: output {} on any error
_cursor_fail_open() {
  printf '{}\n'
  exit 0
}
trap '_cursor_fail_open' ERR

# Ensure data dir exists
mkdir -p "$HOME/.clawkeeper" 2>/dev/null || true

# Read stdin
INPUT=$(cat 2>/dev/null) || true
if [ -z "$INPUT" ]; then
  printf '{}\n'
  exit 0
fi

# Extract Cursor's hook_event_name
EVENT=$(printf '%s' "$INPUT" | grep -oE '"hook_event_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:.*"\([^"]*\)".*/\1/') || true

# Extract dedup key (generation_id)
GEN_ID=$(printf '%s' "$INPUT" | grep -oE '"generation_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:.*"\([^"]*\)".*/\1/') || true

# Dedup check
if [ -n "$GEN_ID" ] && type is_duplicate &>/dev/null; then
  if is_duplicate "cursor:${EVENT}:${GEN_ID}" 2>/dev/null; then
    printf '{}\n'
    exit 0
  fi
fi

# Timing — macOS date does not support %N, so use portable fallback
_now_ms() {
  if command -v gdate &>/dev/null; then
    gdate +%s%3N
  elif command -v python3 &>/dev/null; then
    python3 -c 'import time; print(int(time.time()*1000))'
  else
    printf '%s000' "$(date +%s)"
  fi
}
START_MS=$(_now_ms)

# ── Normalize Cursor JSON → Claude Code format ──

NORMALIZED=""
SHARED_SCRIPT=""
CAN_BLOCK=false
IS_POST=false

case "$EVENT" in
  beforeShellExecution)
    # Cursor: {"command":"...","cwd":"..."} → Claude: {"tool_name":"Bash","tool_input":{"command":"..."}}
    CMD=$(printf '%s' "$INPUT" | grep -oE '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:.*"\([^"]*\)".*/\1/') || true
    NORMALIZED=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$(_json_escape "$CMD")")
    SHARED_SCRIPT="${SCRIPTS_DIR}/pre-tool-hook.sh"
    CAN_BLOCK=true
    ;;

  beforeReadFile)
    # Cursor: {"file_path":"...","content":"..."} → Claude: {"tool_name":"Read","tool_input":{"file_path":"..."}}
    FPATH=$(printf '%s' "$INPUT" | grep -oE '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:.*"\([^"]*\)".*/\1/') || true
    NORMALIZED=$(printf '{"tool_name":"Read","tool_input":{"file_path":"%s"}}' "$(_json_escape "$FPATH")")
    SHARED_SCRIPT="${SCRIPTS_DIR}/pre-tool-hook.sh"
    CAN_BLOCK=true
    ;;

  afterFileEdit)
    # Cursor: {"file_path":"...","edits":[...]} → Claude: {"tool_name":"Edit","tool_input":{"file_path":"..."}}
    FPATH=$(printf '%s' "$INPUT" | grep -oE '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:.*"\([^"]*\)".*/\1/') || true
    NORMALIZED=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$(_json_escape "$FPATH")")
    SHARED_SCRIPT="${SCRIPTS_DIR}/post-tool-hook.sh"
    IS_POST=true
    ;;

  beforeMCPExecution)
    # Cursor: {"server":"...","tool_name":"...","tool_input":"<json string>"} → Claude: {"tool_name":"mcp__server__tool","tool_input":{...}}
    MCP_SERVER=$(printf '%s' "$INPUT" | grep -oE '"server"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:.*"\([^"]*\)".*/\1/') || true
    MCP_TOOL=$(printf '%s' "$INPUT" | grep -oE '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:.*"\([^"]*\)".*/\1/') || true
    # tool_input is a JSON STRING in Cursor — parse it
    # Extract the string value, then use it as raw JSON
    MCP_ARGS=""
    if command -v python3 &>/dev/null; then
      MCP_ARGS=$(printf '%s' "$INPUT" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    ti = d.get('tool_input', '{}')
    if isinstance(ti, str):
        parsed = json.loads(ti)
        print(json.dumps(parsed))
    else:
        print(json.dumps(ti))
except:
    print('{}')
" 2>/dev/null) || true
    fi
    [ -z "$MCP_ARGS" ] && MCP_ARGS="{}"
    NORMALIZED=$(printf '{"tool_name":"mcp__%s__%s","tool_input":%s}' \
      "$(_json_escape "$MCP_SERVER")" "$(_json_escape "$MCP_TOOL")" "$MCP_ARGS")
    SHARED_SCRIPT="${SCRIPTS_DIR}/pre-tool-hook.sh"
    CAN_BLOCK=true
    ;;

  beforeSubmitPrompt)
    # Cursor: {"prompt":"..."} → Claude: {"tool_name":"UserPromptSubmit","tool_input":{"prompt":"..."}}
    # Note: Cursor ignores stdout for this event — record-only
    PROMPT_TEXT=$(printf '%s' "$INPUT" | grep -oE '"prompt"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:.*"\([^"]*\)".*/\1/') || true
    NORMALIZED=$(printf '{"tool_name":"UserPromptSubmit","tool_input":{"prompt":"%s"}}' "$(_json_escape "$PROMPT_TEXT")")
    SHARED_SCRIPT="${SCRIPTS_DIR}/prompt-hook.sh"
    IS_POST=true  # treat as non-blocking (Cursor ignores stdout)
    ;;

  stop)
    # Just log — no detection needed
    printf '{}\n'
    exit 0
    ;;

  *)
    # Unknown event — allow
    printf '{}\n'
    exit 0
    ;;
esac

# ── Call shared script ──

if [ -z "$SHARED_SCRIPT" ] || [ ! -x "$SHARED_SCRIPT" ]; then
  printf '{}\n'
  exit 0
fi

# Run detection via shared script
SHARED_RESPONSE=$(printf '%s' "$NORMALIZED" | "$SHARED_SCRIPT" 2>/dev/null) || true

END_MS=$(_now_ms)
DETECT_MS=$(( END_MS - START_MS ))

# ── Translate Claude Code response → Cursor format ──

if [ "$IS_POST" = true ] || [ -z "$SHARED_RESPONSE" ] || [ "$SHARED_RESPONSE" = "{}" ]; then
  # Allow (or post-hook: always allow regardless)
  debug_log "cursor" "$EVENT" "1.0.0" "$DETECT_MS" "0" "pass" "n/a" "0" 2>/dev/null || true
  printf '{}\n'
  exit 0
fi

# Check if response contains a deny
DECISION=$(printf '%s' "$SHARED_RESPONSE" | grep -oE '"permissionDecision"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:.*"\([^"]*\)".*/\1/') || true
REASON=$(printf '%s' "$SHARED_RESPONSE" | grep -oE '"permissionDecisionReason"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:.*"\([^"]*\)".*/\1/') || true
CONTEXT=$(printf '%s' "$SHARED_RESPONSE" | grep -oE '"additionalContext"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:.*"\([^"]*\)".*/\1/') || true

# Also check for UserPromptSubmit block format
BLOCK_DECISION=$(printf '%s' "$SHARED_RESPONSE" | grep -oE '"decision"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:.*"\([^"]*\)".*/\1/') || true

if [ "$DECISION" = "deny" ] || [ "$BLOCK_DECISION" = "block" ]; then
  # Deny → Cursor format
  DENY_MSG="${REASON:-${CONTEXT:-Blocked by Clawkeeper}}"
  ENFORCEMENT="attempted"  # Cursor may not honor deny (known bug)
  debug_log "cursor" "$EVENT" "1.0.0" "$DETECT_MS" "0" "block" "$ENFORCEMENT" "0" 2>/dev/null || true
  printf '{"permission":"deny","userMessage":"%s","agentMessage":"Clawkeeper security policy blocked this action: %s. Try an alternative approach."}\n' \
    "$(_json_escape "$DENY_MSG")" "$(_json_escape "$DENY_MSG")"
elif [ -n "$CONTEXT" ]; then
  # Warn → Cursor format (allow with agent message)
  debug_log "cursor" "$EVENT" "1.0.0" "$DETECT_MS" "0" "warn" "warned" "0" 2>/dev/null || true
  printf '{"permission":"allow","agentMessage":"%s"}\n' "$(_json_escape "$CONTEXT")"
else
  # Allow
  debug_log "cursor" "$EVENT" "1.0.0" "$DETECT_MS" "0" "pass" "n/a" "0" 2>/dev/null || true
  printf '{}\n'
fi

# Fire-and-forget API reporting in background
if [ -n "${CLAWKEEPER_API_KEY:-}" ] || [ -n "$(resolve_api_key 2>/dev/null)" ]; then
  (
    API_KEY="${CLAWKEEPER_API_KEY:-$(resolve_api_key 2>/dev/null)}"
    HOSTNAME_VAL=$(scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || printf 'unknown')
    MACHINE_ID=$(get_machine_id)
    printf '%s' "$NORMALIZED" | curl -s --max-time 4 \
      -X POST "https://clawkeeper.dev/api/v1/evaluate?tool=cursor" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${API_KEY}" \
      -H "X-Hostname: ${HOSTNAME_VAL}" \
      -H "X-Machine-Id: ${MACHINE_ID}" \
      -d @- >/dev/null 2>&1
  ) &
fi

exit 0
