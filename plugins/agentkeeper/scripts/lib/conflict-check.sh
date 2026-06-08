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

# Resolve the AgentKeeper API origin from existing HTTP hook settings.
# This lets command hooks inherit sandbox/prod/local routing from the same
# settings file that runtime HTTP hooks use.
agentkeeper_api_base_from_http_hooks() {
  local file
  for file in ".claude/settings.json" ".claude/settings.local.json" "$HOME/.claude/settings.json"; do
    if [ ! -f "$file" ]; then
      continue
    fi

    if command -v python3 >/dev/null 2>&1; then
      python3 - "$file" <<'PY' 2>/dev/null && return 0 || true
import json
import sys
from urllib.parse import urlparse

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as handle:
        settings = json.load(handle)
except Exception:
    sys.exit(1)

hooks = settings.get("hooks")
if not isinstance(hooks, dict):
    sys.exit(1)

preferred_events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse"]
for event in preferred_events:
    for group in hooks.get(event) or []:
        if not isinstance(group, dict):
            continue
        for hook in group.get("hooks") or []:
            if not isinstance(hook, dict) or hook.get("type") != "http":
                continue
            url = str(hook.get("url") or "")
            if "agentkeeper" not in url and "/api/v1/claude-code/" not in url:
                continue
            parsed = urlparse(url)
            if parsed.scheme and parsed.netloc:
                print(f"{parsed.scheme}://{parsed.netloc}", end="")
                sys.exit(0)
sys.exit(1)
PY
    fi

    sed -nE 's/.*"url"[[:space:]]*:[[:space:]]*"((https?:\/\/[^"\/]+)(\/api\/v1\/claude-code\/[^"]*)?)".*/\2/p' "$file" 2>/dev/null |
      grep -E 'agentkeeper|127\.0\.0\.1|localhost' |
      head -1 &&
      return 0
  done

  return 1
}
