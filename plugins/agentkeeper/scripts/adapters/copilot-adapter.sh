#!/usr/bin/env bash
# copilot-adapter.sh — VS Code Copilot hook adapter for AgentKeeper
#
# Copilot hooks use lower-case event names in hooks.json and pass toolName /
# toolArgs in the current GitHub schema. Older local harnesses may still pass
# hookEventName/tool_name/tool_input, so this adapter accepts both shapes.
# Dedup key: tool_use_id.
#
# Usage (in VS Code Copilot hook config):
#   bash: "bash /path/to/copilot-adapter.sh"
#
# Environment:
#   Reads JSON from stdin, writes hook response to stdout.
#   ALWAYS fail-open: any error -> output {} and exit 0.

set -euo pipefail

# ── Environment setup ──────────────────────────────────────────────────────
export AGENTKEEPER_IDE="copilot"
export AGENTKEEPER_SKIP_CONFLICT_CHECK=1
export CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA:-$HOME/.agentkeeper}"

ADAPTER_DIR="$(cd "$(dirname "$0")" && pwd)"
# AGENTKEEPER_SCRIPTS_DIR must point to the plugin root (parent of scripts/)
# so that shared hook scripts resolve their own PLUGIN_ROOT correctly.
export AGENTKEEPER_SCRIPTS_DIR="${AGENTKEEPER_SCRIPTS_DIR:-$(cd "$ADAPTER_DIR/../.." && pwd)}"
PLUGIN_ROOT="$AGENTKEEPER_SCRIPTS_DIR"

# Source shared libraries
source "${PLUGIN_ROOT}/scripts/lib/json-helpers.sh" 2>/dev/null || \
  source "${PLUGIN_ROOT}/lib/json-helpers.sh" 2>/dev/null || true
source "${PLUGIN_ROOT}/scripts/lib/key-resolver.sh" 2>/dev/null || \
  source "${PLUGIN_ROOT}/lib/key-resolver.sh" 2>/dev/null || true
source "${PLUGIN_ROOT}/scripts/lib/dedup.sh" 2>/dev/null || \
  source "${PLUGIN_ROOT}/lib/dedup.sh" 2>/dev/null || true
source "${PLUGIN_ROOT}/scripts/lib/debug-log.sh" 2>/dev/null || \
  source "${PLUGIN_ROOT}/lib/debug-log.sh" 2>/dev/null || true
source "${PLUGIN_ROOT}/scripts/lib/machine-id.sh" 2>/dev/null || \
  source "${PLUGIN_ROOT}/lib/machine-id.sh" 2>/dev/null || true

# ── Fail-open trap ─────────────────────────────────────────────────────────
trap 'emit_allow; exit 0' ERR

# ── Read stdin ─────────────────────────────────────────────────────────────
INPUT=$(cat 2>/dev/null) || true

if [ -z "$INPUT" ]; then
  emit_allow
  exit 0
fi

# ── Extract event name and tool name ───────────────────────────────────────
HOOK_EVENT=$(printf '%s' "$INPUT" | grep -oE '"hookEventName"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/') || true
if [ -z "$HOOK_EVENT" ]; then
  HOOK_EVENT=$(printf '%s' "$INPUT" | grep -oE '"hook_event_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/') || true
fi
if [ -z "$HOOK_EVENT" ]; then
  HOOK_EVENT="PreToolUse"
fi

COPILOT_TOOL=$(printf '%s' "$INPUT" | grep -oE '"toolName"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/') || true
if [ -z "$COPILOT_TOOL" ]; then
  COPILOT_TOOL=$(printf '%s' "$INPUT" | grep -oE '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/') || true
fi

# Extract tool_use_id for dedup
TOOL_USE_ID=$(printf '%s' "$INPUT" | grep -oE '"tool_use_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/') || true

# ── Deduplication ──────────────────────────────────────────────────────────
if [ -n "$TOOL_USE_ID" ] && [ -n "$HOOK_EVENT" ]; then
  DEDUP_KEY="copilot:${HOOK_EVENT}:${TOOL_USE_ID}"
  if is_duplicate "$DEDUP_KEY"; then
    emit_allow
    exit 0
  fi
fi

# ── Map Copilot tool names to Claude Code tool names ───────────────────────
map_tool_name() {
  local copilot_name="$1"
  case "$copilot_name" in
    runTerminalCommand|bash) printf 'Bash' ;;
    applyEdit|editFiles|edit) printf 'Edit' ;;
    writeFile|createFile|deleteFile|create) printf 'Write' ;;
    readFile|view)      printf 'Read' ;;
    searchFiles|glob)   printf 'Glob' ;;
    searchCode|grep)    printf 'Grep' ;;
    mcp__*)             printf '%s' "$copilot_name" ;;
    *)                  printf '%s' "$copilot_name" ;;
  esac
}

MAPPED_TOOL=""
if [ -n "$COPILOT_TOOL" ]; then
  MAPPED_TOOL=$(map_tool_name "$COPILOT_TOOL")
fi

# ── Translate input JSON to Claude Code format ─────────────────────────────
# Uses python3 for reliable JSON manipulation (camelCase -> snake_case).
# Falls back to grep-based extraction if python3 is unavailable.
translate_input() {
  local raw="$1"
  local mapped_tool="$2"

  if command -v python3 >/dev/null 2>&1; then
    export AGENTKEEPER_MAPPED_TOOL="$mapped_tool"
    printf '%s' "$raw" | python3 -c "
import json, sys, os

try:
    d = json.load(sys.stdin)
except:
    print('{}')
    sys.exit(0)

mapped_tool = os.environ.get('AGENTKEEPER_MAPPED_TOOL', '')
hook_event = d.get('hookEventName') or d.get('hook_event_name') or 'PreToolUse'

# Build normalized tool_input with snake_case properties
tool_input = d.get('tool_input') or {}
if not tool_input and 'toolArgs' in d:
    raw_args = d.get('toolArgs')
    if isinstance(raw_args, str):
        try:
            tool_input = json.loads(raw_args)
        except Exception:
            tool_input = {'raw': raw_args}
    elif isinstance(raw_args, dict):
        tool_input = raw_args
normalized_input = {}

# Map camelCase -> snake_case for known properties
key_map = {
    'filePath': 'file_path',
    'content': 'content',
    'command': 'command',
    'oldString': 'old_string',
    'newString': 'new_string',
    'pattern': 'pattern',
    'path': 'path',
    'replaceAll': 'replace_all',
}

for k, v in tool_input.items():
    mapped_key = key_map.get(k, k)
    normalized_input[mapped_key] = v

out = {
    'tool_name': mapped_tool if mapped_tool else d.get('tool_name') or d.get('toolName', ''),
    'tool_input': normalized_input,
    'hook_event_name': hook_event,
}

# Preserve tool_use_id if present
if 'tool_use_id' in d:
    out['tool_use_id'] = d['tool_use_id']

# Preserve prompt if present (UserPromptSubmit)
if 'prompt' in d:
    out['prompt'] = d['prompt']

# Preserve session_id if present (SessionStart)
if 'session_id' in d:
    out['session_id'] = d['session_id']

# Preserve cwd if present
if 'cwd' in d:
    out['cwd'] = d['cwd']

print(json.dumps(out))
" 2>/dev/null
  else
    # Fallback: crude grep-based translation for essential fields
    printf '{"tool_name":"%s","tool_input":%s,"hook_event_name":"%s"}' \
      "$mapped_tool" \
      "$(printf '%s' "$raw" | grep -oE '"tool_input"[[:space:]]*:[[:space:]]*\{[^}]*\}' | head -1 | sed 's/"tool_input"[[:space:]]*:[[:space:]]*//')" \
      "$HOOK_EVENT"
  fi
}

# ── Route to shared hook scripts ──────────────────────────────────────────
START_MS=$(($(date +%s%N 2>/dev/null || printf '0') / 1000000))

NORMALIZED=""
case "$HOOK_EVENT" in
  PreToolUse)
    if [ -z "$MAPPED_TOOL" ]; then
      emit_allow
      exit 0
    fi
    NORMALIZED=$(translate_input "$INPUT" "$MAPPED_TOOL")
    RESPONSE=$(printf '%s' "$NORMALIZED" | "${PLUGIN_ROOT}/scripts/pre-tool-hook.sh" 2>/dev/null) || true
    ;;
  PostToolUse)
    if [ -z "$MAPPED_TOOL" ]; then
      emit_allow
      exit 0
    fi
    NORMALIZED=$(translate_input "$INPUT" "$MAPPED_TOOL")
    RESPONSE=$(printf '%s' "$NORMALIZED" | "${PLUGIN_ROOT}/scripts/post-tool-hook.sh" 2>/dev/null) || true
    ;;
  UserPromptSubmit)
    NORMALIZED=$(translate_input "$INPUT" "")
    RESPONSE=$(printf '%s' "$NORMALIZED" | "${PLUGIN_ROOT}/scripts/prompt-hook.sh" 2>/dev/null) || true
    ;;
  SessionStart)
    NORMALIZED=$(translate_input "$INPUT" "")
    RESPONSE=$(printf '%s' "$NORMALIZED" | "${PLUGIN_ROOT}/scripts/session-start.sh" 2>/dev/null) || true
    ;;
  *)
    # Unknown event — fail-open
    emit_allow
    exit 0
    ;;
esac

END_MS=$(($(date +%s%N 2>/dev/null || printf '0') / 1000000))
DETECT_MS=0
if [ "$START_MS" -gt 0 ] && [ "$END_MS" -gt 0 ]; then
  DETECT_MS=$((END_MS - START_MS))
fi

translate_response() {
  local response="$1"
  if [ "$response" = "{}" ] || [ -z "$response" ]; then
    emit_allow
    return
  fi

  printf '%s\n' "$response"
}

if [ -n "$RESPONSE" ]; then
  translate_response "$RESPONSE"
else
  emit_allow
fi

# ── Background: debug log + API enrichment ────────────────────────────────
{
  # Determine verdict from response
  VERDICT="allow"
  ENFORCEMENT="allow"
  if printf '%s' "$RESPONSE" | grep -q '"permissionDecision":"deny"' 2>/dev/null; then
    VERDICT="deny"
    ENFORCEMENT="blocked"
  elif printf '%s' "$RESPONSE" | grep -q '"additionalContext"' 2>/dev/null; then
    VERDICT="warn"
    ENFORCEMENT="warned"
  fi

  debug_log "copilot" "${HOOK_EVENT:-unknown}" "1.0.0" "$DETECT_MS" "0" "$VERDICT" "$ENFORCEMENT" "0" 2>/dev/null || true

  # Fire-and-forget: post the raw Copilot hook payload to the unified evaluate
  # endpoint. The server normalizes Copilot format itself, re-runs detection
  # with the full pattern library + org shield policy, and writes events to
  # shield_events tagged with detection_layer=copilot. Sends every call so the
  # server's log_all_tool_calls policy decides what to persist (was: only
  # non-allow, which masked benign activity on the timeline).
  API_KEY=$(resolve_api_key 2>/dev/null) || true
  if [ -n "$API_KEY" ]; then
    HOSTNAME_VAL=$(scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || printf 'unknown')
    MACHINE_ID=$(get_machine_id)
    printf '%s' "$INPUT" | curl -s --max-time 4 -X POST "https://www.agentkeeper.dev/api/v1/evaluate?tool=copilot" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${API_KEY}" \
      -H "X-Hostname: ${HOSTNAME_VAL}" \
      -H "X-Machine-Id: ${MACHINE_ID}" \
      -d @- >/dev/null 2>&1 || true
  fi
} &

exit 0
