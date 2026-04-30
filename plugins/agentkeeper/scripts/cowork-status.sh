#!/usr/bin/env bash
# Show install state for the AgentKeeper Claude Cowork hook.

set -u

case "$(uname -s)" in
  Darwin) CLAUDE_DATA="$HOME/Library/Application Support/Claude" ;;
  Linux)  CLAUDE_DATA="${XDG_CONFIG_HOME:-$HOME/.config}/Claude" ;;
  *)      CLAUDE_DATA="" ;;
esac

HOOK_SCRIPT="${HOME}/.agentkeeper/scripts/pre-tool-hook.sh"
PLUGIN_KEY_FILE="${HOME}/.agentkeeper-plugin/api_key"
SHARED_KEY_FILE="${HOME}/.agentkeeper/config/api_key"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m[ok]\033[0m %s\n' "$*"; }
miss() { printf '  \033[31m[missing]\033[0m %s\n' "$*"; }
note() { printf '     %s\n' "$*"; }
plugin_enabled() {
  settings_file="$(dirname "$1")/cowork_settings.json"
  [ -f "$settings_file" ] || return 1
  python3 - "$settings_file" <<'PY_EOF'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(1)

sys.exit(0 if data.get("enabledPlugins", {}).get("cowork-guardrail@agentkeeper") is True else 1)
PY_EOF
}

bold "AgentKeeper Cowork Hook - status"
echo

if [ -x "$HOOK_SCRIPT" ]; then ok "hook script: ${HOOK_SCRIPT}"
else miss "hook script missing: ${HOOK_SCRIPT}"; fi

if [ -s "$PLUGIN_KEY_FILE" ]; then
  ok "API key: present at ${PLUGIN_KEY_FILE}"
elif [ -s "$SHARED_KEY_FILE" ]; then
  ok "API key: present at ${SHARED_KEY_FILE}"
else
  miss "API key missing"
  note "run the installer with AGENTKEEPER_API_KEY=ak_live_..."
fi

echo
bold "Per-workspace install"
echo

if [ -z "$CLAUDE_DATA" ] || [ ! -d "$CLAUDE_DATA/local-agent-mode-sessions" ]; then
  miss "No Cowork session directory found."
else
  FOUND=0
  COWORK_DIRS="$(find "$CLAUDE_DATA/local-agent-mode-sessions" -maxdepth 4 -type d -name cowork_plugins 2>/dev/null | sort || true)"
  while IFS= read -r cw; do
    [ -d "$cw" ] || continue
    FOUND=$((FOUND + 1))
    workspace_dir="$(dirname "$cw")"
    workspace_id="${workspace_dir##*/}"

    hooks_file="${cw}/marketplaces/agentkeeper/cowork-guardrail/hooks/hooks.json"
    if [ -f "$hooks_file" ] && grep -q "AGENTKEEPER_API_TOOL=cowork" "$hooks_file"; then
      ok "workspace ${workspace_id}: marketplace hook installed"
    else
      miss "workspace ${workspace_id}: marketplace hook missing"
    fi

    cache_match="$(find "${cw}/cache/agentkeeper/cowork-guardrail" -maxdepth 4 -type f -name hooks.json -print -quit 2>/dev/null || true)"
    if [ -n "$cache_match" ] && grep -q "AGENTKEEPER_API_TOOL=cowork" "$cache_match"; then
      ok "workspace ${workspace_id}: cache hook installed"
    else
      miss "workspace ${workspace_id}: cache hook missing"
    fi

    if plugin_enabled "$cw"; then
      ok "workspace ${workspace_id}: Cowork plugin enabled"
    else
      miss "workspace ${workspace_id}: Cowork plugin disabled"
      note "re-run the installer, then quit and relaunch Claude Desktop"
    fi
  done <<EOF_DIRS
${COWORK_DIRS}
EOF_DIRS
  [ "$FOUND" -eq 0 ] && miss "No Cowork workspaces found."
fi

echo
note "Quit and relaunch Claude Desktop after install or uninstall."
