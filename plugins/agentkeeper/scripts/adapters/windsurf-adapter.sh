#!/usr/bin/env bash
# windsurf-adapter.sh — Windsurf (Codeium Cascade) hook adapter for AgentKeeper
#
# Windsurf hooks communicate via EXIT CODES, not stdout JSON:
#   exit 0 = allow
#   exit 2 = block (stderr message shown to Cascade agent)
#
# Windsurf event names (snake_case via agent_action_name):
#   pre_run_command, pre_write_code, pre_read_code, pre_mcp_tool_use,
#   pre_user_prompt, post_write_code, post_run_command, post_mcp_tool_use
#
# All event-specific fields are wrapped in tool_info:
#   tool_info.command_line, tool_info.file_path, tool_info.edits[],
#   tool_info.mcp_server_name, tool_info.mcp_tool_name,
#   tool_info.mcp_tool_arguments (parsed object), tool_info.user_prompt
#
# Dedup key: execution_id
#
# ALWAYS fail-open: any error → exit 0 (NOT exit 2).

set -euo pipefail

PLUGIN_ROOT="${AGENTKEEPER_SCRIPTS_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"

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
# On ANY unexpected error, exit 0 (allow). Never exit 2 on error.
trap 'exit 0' ERR

# Set IDE environment for downstream scripts
export AGENTKEEPER_IDE="windsurf"
export AGENTKEEPER_SKIP_CONFLICT_CHECK=1

# ── Read stdin ─────────────────────────────────────────────────────────────
INPUT=$(cat 2>/dev/null) || true

if [ -z "$INPUT" ]; then
  exit 0
fi

# ── Extract event name and execution_id ────────────────────────────────────
# Windsurf uses agent_action_name (snake_case)
extract_ws_field() {
  local field="$1"
  printf '%s' "$INPUT" | grep -oE "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/'
}

EVENT=$(extract_ws_field "agent_action_name")
EXEC_ID=$(extract_ws_field "execution_id")

if [ -z "$EVENT" ]; then
  exit 0
fi

# ── Deduplication ──────────────────────────────────────────────────────────
if [ -n "$EXEC_ID" ]; then
  if is_duplicate "windsurf:${EVENT}:${EXEC_ID}" 2>/dev/null; then
    exit 0
  fi
fi

# ── Determine if this is a pre or post hook ────────────────────────────────
IS_PRE=true
case "$EVENT" in
  post_*) IS_PRE=false ;;
esac

# ── Post-hooks: audit only, always exit 0 ──────────────────────────────────
if [ "$IS_PRE" = false ]; then
  # Fire-and-forget audit via post-tool-hook.sh
  # Normalize to Claude Code format for the shared post-hook
  NORMALIZED=$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    ti = d.get('tool_info', {})
    event = d.get('agent_action_name', '')
    out = {'tool_name': 'WindsurfPost', 'tool_input': {}}
    if 'command_line' in ti:
        out['tool_name'] = 'Bash'
        out['tool_input'] = {'command': ti['command_line']}
    elif 'file_path' in ti:
        out['tool_name'] = 'Write'
        out['tool_input'] = {'file_path': ti['file_path']}
    print(json.dumps(out))
except:
    print('{}')
" 2>/dev/null) || true

  if [ -n "$NORMALIZED" ] && [ "$NORMALIZED" != "{}" ]; then
    POST_HOOK="${PLUGIN_ROOT}/scripts/post-tool-hook.sh"
    if [ -x "$POST_HOOK" ]; then
      printf '%s' "$NORMALIZED" | "$POST_HOOK" >/dev/null 2>&1 &
    fi
  fi

  exit 0
fi

# ── Pre-hooks: normalize Windsurf JSON → Claude Code format ───────────────
# Uses python3 because Windsurf JSON has nested tool_info (grep/sed too fragile)
NORMALIZED=$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    event = d.get('agent_action_name', '')
    ti = d.get('tool_info', {})
    out = {}

    if event == 'pre_run_command':
        out = {
            'tool_name': 'Bash',
            'tool_input': {'command': ti.get('command_line', '')}
        }
    elif event == 'pre_write_code':
        fp = ti.get('file_path', '')
        edits = ti.get('edits', [])
        content = '\\n'.join(e.get('new_string', '') for e in edits if e.get('new_string'))
        out = {
            'tool_name': 'Write',
            'tool_input': {'file_path': fp, 'content': content}
        }
    elif event == 'pre_read_code':
        out = {
            'tool_name': 'Read',
            'tool_input': {'file_path': ti.get('file_path', '')}
        }
    elif event == 'pre_mcp_tool_use':
        server = ti.get('mcp_server_name', '')
        tool = ti.get('mcp_tool_name', '')
        args = ti.get('mcp_tool_arguments', {})
        out = {
            'tool_name': 'mcp__' + server + '__' + tool,
            'tool_input': args if isinstance(args, dict) else {}
        }
    elif event == 'pre_user_prompt':
        out = {
            'tool_name': 'UserPromptSubmit',
            'tool_input': {'prompt': ti.get('user_prompt', '')}
        }
    else:
        out = {}

    print(json.dumps(out))
except:
    print('{}')
" 2>/dev/null) || true

if [ -z "$NORMALIZED" ] || [ "$NORMALIZED" = "{}" ]; then
  exit 0
fi

# ── Timing start ───────────────────────────────────────────────────────────
DETECT_START=$(date -u +%s 2>/dev/null) || true

# ── Route to detection (pre-tool-hook.sh or prompt-hook.sh) ────────────────
TOOL_NAME=$(printf '%s' "$NORMALIZED" | grep -oE '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/') || true

if [ "$TOOL_NAME" = "UserPromptSubmit" ]; then
  HOOK_SCRIPT="${PLUGIN_ROOT}/scripts/prompt-hook.sh"
else
  HOOK_SCRIPT="${PLUGIN_ROOT}/scripts/pre-tool-hook.sh"
fi

if [ ! -x "$HOOK_SCRIPT" ]; then
  exit 0
fi

RESPONSE=$(printf '%s' "$NORMALIZED" | "$HOOK_SCRIPT" 2>/dev/null) || true

# ── Fire-and-forget: mirror the raw Windsurf hook payload to the unified
# evaluate endpoint so events land in shield_events tagged with
# detection_layer=windsurf. The server normalizes Windsurf shape itself,
# re-runs detection with the full pattern library + org shield policy,
# and logs per the org's log_all_tool_calls setting. Non-blocking.
{
  API_KEY=$(resolve_api_key 2>/dev/null) || true
  if [ -n "$API_KEY" ]; then
    HOSTNAME_VAL=$(scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || printf 'unknown')
    MACHINE_ID=$(get_machine_id 2>/dev/null || printf '')
    printf '%s' "$INPUT" | curl -s --max-time 4 -X POST "https://www.agentkeeper.dev/api/v1/evaluate?tool=windsurf" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${API_KEY}" \
      -H "X-Hostname: ${HOSTNAME_VAL}" \
      -H "X-Machine-Id: ${MACHINE_ID}" \
      -d @- >/dev/null 2>&1 || true
  fi
} &

# ── Timing end ─────────────────────────────────────────────────────────────
DETECT_END=$(date -u +%s 2>/dev/null) || true
DETECT_MS=0
if [ -n "$DETECT_START" ] && [ -n "$DETECT_END" ]; then
  DETECT_MS=$(( (DETECT_END - DETECT_START) * 1000 ))
fi

# ── Parse Claude Code response → Windsurf exit code ───────────────────────
# Claude Code responses:
#   deny:  {"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"..."}}
#   block: {"decision":"block","reason":"..."}
#   allow: {} or {"hookSpecificOutput":{"permissionDecision":"allow",...}}

if [ -z "$RESPONSE" ] || [ "$RESPONSE" = "{}" ]; then
  debug_log "windsurf" "$EVENT" "1.0.0" "$DETECT_MS" "0" "allow" "allowed" "0" 2>/dev/null || true
  exit 0
fi

# Check for deny (PreToolUse)
if printf '%s' "$RESPONSE" | grep -q '"permissionDecision":"deny"'; then
  REASON=$(printf '%s' "$RESPONSE" | grep -oE '"permissionDecisionReason"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/') || true
  debug_log "windsurf" "$EVENT" "1.0.0" "$DETECT_MS" "0" "deny" "blocked" "2" 2>/dev/null || true
  printf '%s\n' "${REASON:-Blocked by AgentKeeper}" >&2
  exit 2
fi

# Check for block (UserPromptSubmit)
if printf '%s' "$RESPONSE" | grep -q '"decision":"block"'; then
  REASON=$(printf '%s' "$RESPONSE" | grep -oE '"reason"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/') || true
  debug_log "windsurf" "$EVENT" "1.0.0" "$DETECT_MS" "0" "block" "blocked" "2" 2>/dev/null || true
  printf '%s\n' "${REASON:-Blocked by AgentKeeper}" >&2
  exit 2
fi

# Everything else (allow, warn) → exit 0
# Warn mode: no feedback mechanism in Windsurf, so just log and allow
VERDICT="allow"
if printf '%s' "$RESPONSE" | grep -q '"additionalContext"'; then
  VERDICT="warn"
fi
debug_log "windsurf" "$EVENT" "1.0.0" "$DETECT_MS" "0" "$VERDICT" "allowed" "0" 2>/dev/null || true
exit 0
