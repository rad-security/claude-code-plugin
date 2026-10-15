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

agentkeeper_bypass_prevention_guidance() {
  printf '%s' 'Do not disable, remove, or bypass AgentKeeper. If this is authorized security testing, request a scoped Security Testing Exception from your AgentKeeper admin.'
}

prompt_block_message() {
  local reason="$1"
  local guidance base detail message
  guidance="$(agentkeeper_bypass_prevention_guidance)"
  reason="${reason//$guidance/}"
  reason="${reason//Prompt hidden from terminal output./}"
  case "$reason" in
    *"AgentKeeper blocked this request."*|*"Next step:"*|*"Prompt:"*)
      message="$(printf '%s' "$reason" | sed 's/[[:space:]]*$//')"
      ;;
    *)
      base="$(printf '%s' "${reason:-Blocked by AgentKeeper}" | tr '\r\n\t' '   ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^[[:space:]]*//; s/[[:space:]]*$//; s/[. ][. ]*$//')"
      [ -n "$base" ] || base="Blocked by AgentKeeper"
      detail="$base"
      case "$detail" in
        "Blocked by AgentKeeper:"*) detail="${detail#Blocked by AgentKeeper:}" ;;
        "AgentKeeper:"*) detail="${detail#AgentKeeper:}" ;;
      esac
      detail="$(printf '%s' "$detail" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[. ][. ]*$//')"
      if [ "$detail" = "Blocked by AgentKeeper" ] || [ -z "$detail" ]; then
        message="AgentKeeper blocked this request."
      else
        message="AgentKeeper blocked this request.

Reason:
${detail}"
      fi
      message="${message}

Next step:
Ask your AgentKeeper admin for a scoped exception.

Prompt:
Prompt text is omitted from this AgentKeeper block reason."
      ;;
  esac
  if [ "${#message}" -gt 1200 ]; then
    message="${message:0:1197}..."
  fi
  printf '%s' "$message"
}

with_bypass_prevention_guidance() {
  local reason="$1"
  local guidance
  guidance="$(agentkeeper_bypass_prevention_guidance)"
  case "$reason" in
    *"$guidance"*) printf '%s' "$reason" ;;
    *) printf '%s\n\n%s' "$reason" "$guidance" ;;
  esac
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
  reason="$(with_bypass_prevention_guidance "$reason")"
  escaped_reason=$(_json_escape "$reason")

  case "$hook_event" in
    PreToolUse)
      printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' \
        "$escaped_reason" "$escaped_reason"
      ;;
    UserPromptSubmit)
      escaped_reason=$(_json_escape "$(prompt_block_message "$reason")")
      printf '{"decision":"block","reason":"%s","systemMessage":"%s","suppressOriginalPrompt":true,"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","suppressOriginalPrompt":true}}\n' \
        "$escaped_reason" "$escaped_reason"
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
      printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","additionalContext":"%s"}}\n' \
        "$context_msg" "$context_msg"
      ;;
    UserPromptSubmit)
      printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"%s"}}\n' \
        "$context_msg" "$context_msg"
      ;;
    *)
      # Unknown hook event — emit allow as safe fallback
      emit_allow
      ;;
  esac
}
