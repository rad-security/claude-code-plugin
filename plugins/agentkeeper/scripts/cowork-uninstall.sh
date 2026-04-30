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

  python3 - "$cw" <<'PY_EOF'
import json
import os
import sys

cw_dir = sys.argv[1]

def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None

def save(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)

known_path = os.path.join(cw_dir, "known_marketplaces.json")
known = load(known_path)
if isinstance(known, dict) and "agentkeeper" in known:
    del known["agentkeeper"]
    save(known_path, known)

installed_path = os.path.join(cw_dir, "installed_plugins.json")
installed = load(installed_path)
if isinstance(installed, dict) and isinstance(installed.get("plugins"), dict):
    if "cowork-guardrail@agentkeeper" in installed["plugins"]:
        del installed["plugins"]["cowork-guardrail@agentkeeper"]
        save(installed_path, installed)

settings_path = os.path.join(os.path.dirname(cw_dir), "cowork_settings.json")
settings = load(settings_path)
if isinstance(settings, dict):
    changed = False
    if isinstance(settings.get("enabledPlugins"), dict) and "cowork-guardrail@agentkeeper" in settings["enabledPlugins"]:
        del settings["enabledPlugins"]["cowork-guardrail@agentkeeper"]
        changed = True
    if isinstance(settings.get("extraKnownMarketplaces"), dict) and "agentkeeper" in settings["extraKnownMarketplaces"]:
        del settings["extraKnownMarketplaces"]["agentkeeper"]
        changed = True
    if changed:
        save(settings_path, settings)
PY_EOF

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

echo
echo "AgentKeeper Cowork hook uninstalled."
echo "Quit and relaunch Claude Desktop for the change to take effect."
