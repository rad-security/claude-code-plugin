#!/usr/bin/env bash
# conflict-check.sh — Detect HTTP-based AgentKeeper hooks to avoid double-evaluation
# Sourced by hook dispatcher scripts. No top-level execution.

# Check whether .claude/settings.json or .claude/settings.local.json contain
# HTTP hooks pointing to AgentKeeper. If so, the push-hooks flow is active
# and this plugin should defer to avoid double-evaluation.
#
# Returns 0 (true) if agentkeeper HTTP hooks are detected.
# Returns 1 (false) if no conflict found.
#
# Usage:
#   if has_agentkeeper_http_hooks; then
#     emit_allow  # defer to HTTP hooks
#     exit 0
#   fi
has_agentkeeper_http_hooks() {
  local file
  for file in ".claude/settings.json" ".claude/settings.local.json" "$HOME/.claude/settings.json"; do
    if [ ! -f "$file" ]; then
      continue
    fi

    # Both conditions must be true in the same file:
    # 1. Contains "type": "http" (with flexible whitespace)
    # 2. Contains an AgentKeeper API URL
    local has_http_type=false
    local has_agentkeeper_url=false

    if grep -Eq '"type"[[:space:]]*:[[:space:]]*"http"' "$file" 2>/dev/null; then
      has_http_type=true
    fi

    if grep -Eq '(agentkeeper\.dev|127\.0\.0\.1:3000|www.agentkeeper.dev|/api/v1/(claude-code/)?(evaluate|audit|checkin))' "$file" 2>/dev/null; then
      has_agentkeeper_url=true
    fi

    if [ "$has_http_type" = true ] && [ "$has_agentkeeper_url" = true ]; then
      return 0
    fi
  done

  return 1
}
