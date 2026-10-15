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

# SessionStart is allowed to run alongside HTTP UserPromptSubmit/PreToolUse/
# PostToolUse hooks. Runtime HTTP hooks do not collect local inventory; only an
# HTTP SessionStart hook conflicts with the command-based inventory collector.
has_agentkeeper_http_sessionstart_hooks() {
  local file
  for file in ".claude/settings.json" ".claude/settings.local.json" "$HOME/.claude/settings.json"; do
    if [ ! -f "$file" ]; then
      continue
    fi

    if command -v python3 >/dev/null 2>&1; then
      if python3 - "$file" <<'PYEOF' 2>/dev/null
import json, sys

try:
    with open(sys.argv[1], encoding="utf-8") as f:
        settings = json.load(f)
except Exception:
    sys.exit(1)

for group in (settings.get("hooks") or {}).get("SessionStart") or []:
    for hook in group.get("hooks") or []:
        if hook.get("type") != "http":
            continue
        url = str(hook.get("url") or "")
        if "agentkeeper.dev" in url or "/api/v1/claude-code/checkin" in url:
            sys.exit(0)
sys.exit(1)
PYEOF
      then
        return 0
      fi
    else
      if grep -Eq '"SessionStart"' "$file" 2>/dev/null &&
        grep -Eq '"type"[[:space:]]*:[[:space:]]*"http"' "$file" 2>/dev/null &&
        grep -Eq '(agentkeeper\.dev|/api/v1/claude-code/checkin)' "$file" 2>/dev/null; then
        return 0
      fi
    fi
  done

  return 1
}

# Return the API origin from configured AgentKeeper HTTP hooks, preferring
# SessionStart and falling back to runtime hooks. This keeps command hooks on
# the same environment (sandbox/prod/local) as the user's existing HTTP hooks.
agentkeeper_api_base_from_http_hooks() {
  local file
  for file in ".claude/settings.json" ".claude/settings.local.json" "$HOME/.claude/settings.json"; do
    if [ ! -f "$file" ]; then
      continue
    fi

    if command -v python3 >/dev/null 2>&1; then
      python3 - "$file" <<'PYEOF' 2>/dev/null && return 0
import json, sys
from urllib.parse import urlparse

try:
    with open(sys.argv[1], encoding="utf-8") as f:
        settings = json.load(f)
except Exception:
    sys.exit(1)

hooks = settings.get("hooks") or {}
events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse"]
for event in events:
    for group in hooks.get(event) or []:
        for hook in group.get("hooks") or []:
            if hook.get("type") != "http":
                continue
            url = str(hook.get("url") or "")
            if "agentkeeper.dev" not in url and "/api/v1/claude-code/" not in url:
                continue
            parsed = urlparse(url)
            if parsed.scheme and parsed.netloc:
                print(f"{parsed.scheme}://{parsed.netloc}", end="")
                sys.exit(0)
sys.exit(1)
PYEOF
    fi

    grep -Eo 'https?://[^"]+/api/v1/(claude-code/)?(evaluate|audit|checkin)' "$file" 2>/dev/null |
      sed -E 's#(https?://[^/]+).*#\1#' |
      head -1 &&
      return 0
  done

  return 1
}
