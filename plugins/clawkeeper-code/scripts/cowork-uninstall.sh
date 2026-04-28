#!/usr/bin/env bash
# cowork-uninstall.sh — Remove the Clawkeeper Cowork PreToolUse guardrail.
#
# What this does:
#   1. Removes our marketplace + plugin trees under cowork_plugins/
#   2. De-registers from installed_plugins.json and known_marketplaces.json
#   3. Leaves ~/.clawkeeper/cowork/policy.json and events.log in place
#      (so reinstall preserves customer policy + audit history)
#
# To purge everything including policy and audit log: pass --purge.
#
# Idempotent: safe to run when nothing is installed.

set -euo pipefail

PURGE=0
for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=1 ;;
    -h|--help)
      echo "Usage: cowork-uninstall.sh [--purge]"
      echo "  --purge  Also delete ~/.clawkeeper/cowork/ (policy + audit log)"
      exit 0
      ;;
    *) echo "Error: unknown argument: $arg" >&2; exit 1 ;;
  esac
done

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

echo "Uninstalling Clawkeeper Cowork guardrail..."
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

def load(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return None
    except Exception:
        return default

def save(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)

# known_marketplaces.json
km_path = os.path.join(cw_dir, "known_marketplaces.json")
km = load(km_path, {})
if isinstance(km, dict) and "clawkeeper" in km:
    del km["clawkeeper"]
    save(km_path, km)
    print("  unregistered marketplace")

# installed_plugins.json
ip_path = os.path.join(cw_dir, "installed_plugins.json")
ip = load(ip_path, None)
if isinstance(ip, dict) and isinstance(ip.get("plugins"), dict):
    if "cowork-guardrail@clawkeeper" in ip["plugins"]:
        del ip["plugins"]["cowork-guardrail@clawkeeper"]
        save(ip_path, ip)
        print("  unregistered plugin")
PY_EOF

  if [ "$TOUCHED" = "1" ]; then
    log "Cleaned: ${workspace_dir##*/}"
    REMOVED=$((REMOVED + 1))
  fi
done

if [ "$REMOVED" -eq 0 ]; then
  log "No Clawkeeper guardrail install found in any workspace."
fi

if [ "$PURGE" = "1" ]; then
  echo
  log "Purging ${HOME}/.clawkeeper/cowork/"
  rm -rf "${HOME}/.clawkeeper/cowork"
fi

echo
echo "Clawkeeper Cowork guardrail uninstalled."
echo
echo "Quit and relaunch Claude Desktop for the change to take effect."
if [ "$PURGE" != "1" ]; then
  echo "Policy and audit log preserved at: ${HOME}/.clawkeeper/cowork/"
  echo "Run again with --purge to delete them."
fi
