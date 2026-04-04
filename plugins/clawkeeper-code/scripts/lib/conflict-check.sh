#!/usr/bin/env bash
# conflict-check.sh — Detect HTTP-based Clawkeeper hooks to avoid double-evaluation
# Sourced by hook dispatcher scripts. No top-level execution.

# Check whether .claude/settings.json or .claude/settings.local.json contain
# HTTP hooks pointing to clawkeeper.dev. If so, the push-hooks flow is active
# and this plugin should defer to avoid double-evaluation.
#
# Returns 0 (true) if clawkeeper HTTP hooks are detected.
# Returns 1 (false) if no conflict found.
#
# Usage:
#   if has_clawkeeper_http_hooks; then
#     emit_allow  # defer to HTTP hooks
#     exit 0
#   fi
has_clawkeeper_http_hooks() {
  local file
  for file in ".claude/settings.json" ".claude/settings.local.json"; do
    if [ ! -f "$file" ]; then
      continue
    fi

    # Both conditions must be true in the same file:
    # 1. Contains "type": "http" (with flexible whitespace)
    # 2. Contains clawkeeper.dev
    local has_http_type=false
    local has_clawkeeper_url=false

    if grep -Eq '"type"[[:space:]]*:[[:space:]]*"http"' "$file" 2>/dev/null; then
      has_http_type=true
    fi

    if grep -q 'clawkeeper\.dev' "$file" 2>/dev/null; then
      has_clawkeeper_url=true
    fi

    if [ "$has_http_type" = true ] && [ "$has_clawkeeper_url" = true ]; then
      return 0
    fi
  done

  return 1
}
