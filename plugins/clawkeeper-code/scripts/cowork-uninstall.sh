#!/usr/bin/env bash
# cowork-uninstall.sh — Remove the Clawkeeper Cowork hook from every Cowork
# workspace on this machine. Leaves ~/.clawkeeper/ alone (Claude Code may
# still be using it).
#
# Idempotent. Safe to run when nothing is installed.

set -euo pipefail

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

echo "Uninstalling Clawkeeper Cowork hook..."
echo

REMOVED=0
for cw in "${SESSIONS_DIR}"/*/*/cowork_plugins; do
  [ -d "$cw" ] || continue
  workspace_dir="$(dirname "$cw")"
  TOUCHED=0

  if [ -d "${cw}/marketplaces/clawkeeper" ]; then
    rm -rf "${cw}/marketplaces/clawkeeper"
    TOUCHED=1
  fi
  if [ -d "${cw}/cache/clawkeeper" ]; then
    rm -rf "${cw}/cache/clawkeeper"
    TOUCHED=1
  fi

  python3 - "$cw" <<'PY_EOF'
import json, os, sys

cw_dir = sys.argv[1]

def load(path):
    try:
        with open(path) as f: return json.load(f)
    except (FileNotFoundError, Exception):
        return None

def save(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)

km_path = os.path.join(cw_dir, "known_marketplaces.json")
km = load(km_path)
if isinstance(km, dict) and "clawkeeper" in km:
    del km["clawkeeper"]
    save(km_path, km)

ip_path = os.path.join(cw_dir, "installed_plugins.json")
ip = load(ip_path)
if isinstance(ip, dict) and isinstance(ip.get("plugins"), dict):
    if "cowork-guardrail@clawkeeper" in ip["plugins"]:
        del ip["plugins"]["cowork-guardrail@clawkeeper"]
        save(ip_path, ip)
PY_EOF

  if [ "$TOUCHED" = "1" ]; then
    log "Cleaned: ${workspace_dir##*/}"
    REMOVED=$((REMOVED + 1))
  fi
done

if [ "$REMOVED" -eq 0 ]; then
  log "No Clawkeeper Cowork install found in any workspace."
fi

echo
echo "Clawkeeper Cowork hook uninstalled."
echo "Quit and relaunch Claude Desktop for the change to take effect."
echo "Note: ~/.clawkeeper/scripts/ is left in place (Claude Code may still use it)."
