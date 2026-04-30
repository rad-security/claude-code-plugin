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
