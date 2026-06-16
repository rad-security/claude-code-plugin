#!/usr/bin/env bash
# json-helpers.sh — JSON response builders for Claude Code hook responses
# Sourced by hook dispatcher scripts. No top-level execution.

# Escape a string for safe embedding in JSON values.
# Handles backslashes, double quotes, newlines, carriage returns, tabs,
# and other control characters.
# Usage: escaped=$(_json_escape "$raw_string")
_json_escape() {
  local str="$1"
  # Order matters: backslash first, then other chars
  str="${str//\\/\\\\}"
  str="${str//\"/\\\"}"
  # Replace literal newlines, carriage returns, tabs
  str="${str//$'\n'/\\n}"
  str="${str//$'\r'/\\r}"
  str="${str//$'\t'/\\t}"
  printf '%s' "$str"
}

# Emit an allow/passthrough response (empty JSON object).
# Usage: emit_allow
emit_allow() {
  printf '{}\n'
}

# Emit a deny/block response. Format varies by hook event type.
# Usage: emit_deny "PreToolUse" "reason text"
#        emit_deny "UserPromptSubmit" "reason text"
emit_deny() {
  local hook_event="$1"
  local reason="$2"
  local escaped_reason
  escaped_reason=$(_json_escape "$reason")

  case "$hook_event" in
    PreToolUse)
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' \
        "$escaped_reason"
      ;;
    UserPromptSubmit)
      printf '{"decision":"block","reason":"%s"}\n' \
        "$escaped_reason"
      ;;
    *)
      # Unknown hook event — emit allow as safe fallback
      emit_allow
      ;;
  esac
}

# Emit a warn response (allow with advisory context).
# Usage: emit_warn "PreToolUse" "pattern_name" "description text"
#        emit_warn "UserPromptSubmit" "pattern_name" "description text"
emit_warn() {
  local hook_event="$1"
  local pattern="$2"
  local description="$3"
  local escaped_pattern escaped_description context_msg

  escaped_pattern=$(_json_escape "$pattern")
  escaped_description=$(_json_escape "$description")
  context_msg="AgentKeeper warning: ${escaped_pattern} — ${escaped_description}"

  case "$hook_event" in
    PreToolUse)
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","additionalContext":"%s"}}\n' \
        "$context_msg"
      ;;
    UserPromptSubmit)
      printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"%s"}}\n' \
        "$context_msg"
      ;;
    *)
      # Unknown hook event — emit allow as safe fallback
      emit_allow
      ;;
  esac
}

# --- Grok Build (xAI CLI) support -------------------------------------------
# Grok Build runs the Claude Code harness and inherits these hooks, but sends a
# camelCase payload (hookEventName/toolName) the server's claude-code normalizer
# can't read, and enforces blocks ONLY via the hook exit code (2) — it ignores
# the JSON response body. These helpers let the shared dispatchers detect Grok,
# route it to ?tool=grok, and translate a deny verdict into exit 2.

# True (0) when the stdin payload is a Grok hook event. Keys off the camelCase
# event key paired with a snake_case event value, which neither Claude Code
# (snake key) nor file content is likely to produce.
# Usage: if is_grok_payload "$INPUT"; then ...
is_grok_payload() {
  printf '%s' "$1" | grep -Eq '"hookEventName"[[:space:]]*:[[:space:]]*"(pre_tool_use|post_tool_use|user_prompt_submit)"'
}

# Translate an AgentKeeper evaluate response into Grok's exit-code contract and
# exit: deny -> reason on stderr + exit 2; anything else -> exit 0.
# Call last in the dispatcher; this function exits the process.
# Usage: grok_emit_response "$RESPONSE"
grok_emit_response() {
  local response="$1" reason
  if printf '%s' "$response" | grep -Eq '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"|"decision"[[:space:]]*:[[:space:]]*"block"'; then
    reason=$(printf '%s' "$response" | grep -oE '"(permissionDecisionReason|reason)"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/^[^:]*:[[:space:]]*"\(.*\)"$/\1/') || true
    printf '%s\n' "${reason:-Blocked by AgentKeeper security policy}" >&2
    exit 2
  fi
  exit 0
}
