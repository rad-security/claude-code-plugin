#!/usr/bin/env bash
# Remove the AgentKeeper Claude Cowork hook from every Cowork workspace.

set -eu

case "$(uname -s)" in
  Darwin) CLAUDE_DATA="$HOME/Library/Application Support/Claude" ;;
  Linux)  CLAUDE_DATA="${XDG_CONFIG_HOME:-$HOME/.config}/Claude" ;;
  *)      echo "Error: unsupported OS." >&2; exit 1 ;;
esac

SESSIONS_DIR="${CLAUDE_DATA}/local-agent-mode-sessions"
log() { printf '  %s\n' "$*"; }

# shellcheck disable=SC1090
source "$(cd "$(dirname "$0")" && pwd)/lib/cowork-json.sh" 2>/dev/null || true

if [ ! -d "${SESSIONS_DIR}" ]; then
  echo "No Cowork session directory found. Nothing to uninstall."
  exit 0
fi

echo "Uninstalling AgentKeeper Cowork hook..."
echo

REMOVED=0
COWORK_DIRS="$(find "${SESSIONS_DIR}" -maxdepth 4 -type d -name cowork_plugins 2>/dev/null | sort || true)"
while IFS= read -r cw; do
  [ -d "$cw" ] || continue
  workspace_dir="$(dirname "$cw")"
  TOUCHED=0

  if [ -d "${cw}/marketplaces/agentkeeper" ]; then
    rm -rf "${cw}/marketplaces/agentkeeper"
    TOUCHED=1
  fi
  if [ -d "${cw}/cache/agentkeeper" ]; then
    rm -rf "${cw}/cache/agentkeeper"
    TOUCHED=1
  fi

  if command -v plutil >/dev/null 2>&1; then
    if cowork_json_begin "${cw}/known_marketplaces.json"; then
      cowork_json_remove "agentkeeper"
      cowork_json_commit || true
    fi
    if cowork_json_begin "${cw}/installed_plugins.json"; then
      cowork_json_remove "plugins.cowork-guardrail@agentkeeper"
      cowork_json_commit || true
    fi
    if cowork_json_begin "$(dirname "$cw")/cowork_settings.json"; then
      cowork_json_remove "enabledPlugins.cowork-guardrail@agentkeeper"
      cowork_json_remove "extraKnownMarketplaces.agentkeeper"
      cowork_json_commit || true
    fi
  fi

  if [ "$TOUCHED" = "1" ]; then
    log "Cleaned: ${workspace_dir##*/}"
    REMOVED=$((REMOVED + 1))
  fi
done <<EOF_DIRS
${COWORK_DIRS}
EOF_DIRS

if [ "$REMOVED" -eq 0 ]; then
  log "No AgentKeeper Cowork install found in any workspace."
fi

# Remove any AgentKeeper MCP server entries left by the MCP gateway installer.
if command -v plutil >/dev/null 2>&1; then
  for path in "$HOME/.claude/settings.json" "$HOME/.mcp.json" "$HOME/.claude/.mcp.json"; do
    [ -f "$path" ] || continue
    keys="$(plutil -extract mcpServers raw "$path" 2>/dev/null || true)"
    [ -n "$keys" ] || continue
    removed=""
    if cowork_json_begin "$path"; then
      while IFS= read -r key; do
        [ -n "$key" ] || continue
        lower="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
        case "$lower" in
          *agentkeeper*)
            cowork_json_remove "mcpServers.${key}"
            removed="${removed}${removed:+, }${key}"
            ;;
        esac
      done <<EOF_KEYS
${keys}
EOF_KEYS
      cowork_json_commit || true
    fi
    [ -n "$removed" ] && log "Removed MCP entries from $(basename "$path"): ${removed}"
  done
fi

echo
echo "AgentKeeper Cowork hook uninstalled."
echo "Quit and relaunch Claude Desktop for the change to take effect."
