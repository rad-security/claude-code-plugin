#!/usr/bin/env bash
# cowork-status.sh — Show install state of the Clawkeeper Cowork hook.

set -u

case "$(uname -s)" in
  Darwin) CLAUDE_DATA="$HOME/Library/Application Support/Claude" ;;
  Linux)  CLAUDE_DATA="${XDG_CONFIG_HOME:-$HOME/.config}/Claude" ;;
  *)      CLAUDE_DATA="" ;;
esac

HOOK_CMD="${HOME}/.clawkeeper/scripts/pre-tool-hook.sh"
KEY_FILE="${HOME}/.clawkeeper-plugin/api_key"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m  %s\n' "$*"; }
miss() { printf '  \033[31m✗\033[0m  %s\n' "$*"; }
note() { printf '     %s\n' "$*"; }

bold "Clawkeeper Cowork Hook — status"
echo

if [ -x "$HOOK_CMD" ]; then ok "hook script: ${HOOK_CMD}"
else miss "hook script missing: ${HOOK_CMD} (run /clawkeeper-code:cowork-install)"; fi

if [ -s "$KEY_FILE" ]; then
  ok "API key: present"
  note "rules are fetched from https://clawkeeper.dev/policies"
else
  miss "API key missing: ${KEY_FILE}"
  note "run /clawkeeper-code:connect to link your account, otherwise the hook"
  note "will fail open and dashboard rules will not apply"
fi

echo
bold "Per-workspace install"
echo

if [ -z "$CLAUDE_DATA" ] || [ ! -d "$CLAUDE_DATA/local-agent-mode-sessions" ]; then
  miss "No Cowork session directory found."
else
  FOUND=0
  for cw in "$CLAUDE_DATA"/local-agent-mode-sessions/*/*/cowork_plugins; do
    [ -d "$cw" ] || continue
    FOUND=$((FOUND + 1))
    workspace_dir="$(dirname "$cw")"
    workspace_id="${workspace_dir##*/}"

    HOOKS_FILE_MP="${cw}/marketplaces/clawkeeper/cowork-guardrail/hooks/hooks.json"
    if [ -f "$HOOKS_FILE_MP" ]; then
      ok "workspace ${workspace_id:0:8}: marketplace hook installed"
    else
      miss "workspace ${workspace_id:0:8}: marketplace hook missing"
    fi

    cache_match=$(find "${cw}/cache/clawkeeper/cowork-guardrail" \
      -maxdepth 3 -type f -name hooks.json -print -quit 2>/dev/null)
    if [ -n "$cache_match" ]; then
      ok "workspace ${workspace_id:0:8}: cache hook installed"
    else
      miss "workspace ${workspace_id:0:8}: cache hook missing"
    fi
  done
  [ "$FOUND" -eq 0 ] && miss "No Cowork workspaces found."
fi

echo
bold "Recent activity"
echo
if [ -s "$KEY_FILE" ]; then
  note "events stream to your dashboard at https://clawkeeper.dev/dashboard"
  note "(this command does not pull recent events; check the dashboard)"
else
  note "(no API key — events are not being recorded)"
fi
echo
