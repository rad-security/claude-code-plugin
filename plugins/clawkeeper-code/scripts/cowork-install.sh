#!/usr/bin/env bash
# cowork-install.sh -- Install the Clawkeeper PreToolUse hook into Cowork
# (Claude Desktop), reusing the same hook script, key resolver, and policy
# delivery that already power Claude Code.
#
# Architecture: identical to Claude Code. The hook script reads stdin,
# resolves the API key from ~/.clawkeeper-plugin/, POSTs the envelope to
# https://clawkeeper.dev/api/v1/claude-code/evaluate, and returns the
# server verdict. Org policy is authored in the dashboard at /policies
# and applies to both surfaces.
#
# Idempotent. Re-running is safe; never overwrites the API key.
#
# Compatible with bash 3.2 (default macOS) and bash 5+.

set -eu

VERSION="0.2.2"
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/.clawkeeper"
SCRIPTS_DIR="${INSTALL_DIR}/scripts"
HOOK_SCRIPT="${SCRIPTS_DIR}/pre-tool-hook.sh"
HOOK_CMD="/bin/sh -c 'CLAWKEEPER_SKIP_CONFLICT_CHECK=1 exec ${HOOK_SCRIPT}'"

err() { printf 'Error: %s\n' "$*" >&2; }
log() { printf '  %s\n' "$*"; }

case "$(uname -s)" in
  Darwin)
    CLAUDE_DATA="$HOME/Library/Application Support/Claude"
    ;;
  Linux)
    CLAUDE_DATA="${XDG_CONFIG_HOME:-$HOME/.config}/Claude"
    log "Note: Linux support is best-effort in this version."
    ;;
  *)
    err "Unsupported OS: $(uname -s). macOS and Linux only."
    exit 1
    ;;
esac

if [ ! -d "${CLAUDE_DATA}/local-agent-mode-sessions" ]; then
  err "No Cowork session directory found at:"
  err "  ${CLAUDE_DATA}/local-agent-mode-sessions"
  err "Has Cowork ever been launched on this machine?"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  err "python3 is required (used by the registry merger)."
  err "Install Xcode Command Line Tools: xcode-select --install"
  exit 1
fi

echo "Installing Clawkeeper Cowork hook v${VERSION}..."
echo

mkdir -p "${SCRIPTS_DIR}/lib"
DEPLOYED=0
for f in pre-tool-hook.sh local-detect.sh; do
  if [ -f "${SOURCE_DIR}/${f}" ]; then
    cp "${SOURCE_DIR}/${f}" "${SCRIPTS_DIR}/${f}"
    chmod +x "${SCRIPTS_DIR}/${f}"
    DEPLOYED=$((DEPLOYED + 1))
  fi
done
for libfile in "${SOURCE_DIR}"/lib/*.sh; do
  [ -f "$libfile" ] || continue
  cp "$libfile" "${SCRIPTS_DIR}/lib/"
done

if [ ! -x "${HOOK_SCRIPT}" ]; then
  err "pre-tool-hook.sh did not deploy to ${HOOK_SCRIPT}. Bailing."
  exit 1
fi
log "Hook scripts deployed to ${SCRIPTS_DIR} (${DEPLOYED} top-level scripts)"

SESSIONS_DIR="${CLAUDE_DATA}/local-agent-mode-sessions"
WORKSPACE_COUNT=0

# Cowork layout has shifted across versions. Older builds nest as
# <sessions>/<owner>/<workspace>/cowork_plugins/; newer builds flatten to
# <sessions>/<account>/cowork_plugins/. Discover via find so we work on both.
COWORK_DIRS=$(find "${SESSIONS_DIR}" -maxdepth 4 -type d -name cowork_plugins 2>/dev/null)

if [ -z "${COWORK_DIRS}" ]; then
  err "No cowork_plugins directories found under ${SESSIONS_DIR}."
  err "Open Claude Desktop, send any message in a Cowork chat, then re-run this installer."
  exit 1
fi

while IFS= read -r cw; do
  [ -d "$cw" ] || continue
  WORKSPACE_COUNT=$((WORKSPACE_COUNT + 1))

  workspace_dir="$(dirname "$cw")"
  log "Workspace: ${workspace_dir##*/}"

  MP_ROOT="${cw}/marketplaces/clawkeeper"
  PLUGIN_ROOT="${MP_ROOT}/cowork-guardrail"
  CACHE_ROOT="${cw}/cache/clawkeeper/cowork-guardrail/${VERSION}"

  mkdir -p "${MP_ROOT}/.claude-plugin" \
           "${PLUGIN_ROOT}/.claude-plugin" \
           "${PLUGIN_ROOT}/hooks" \
           "${CACHE_ROOT}/.claude-plugin" \
           "${CACHE_ROOT}/hooks"

  cat > "${MP_ROOT}/.claude-plugin/marketplace.json" <<MP_EOF
{
  "name": "clawkeeper",
  "owner": { "name": "Clawkeeper", "email": "support@clawkeeper.dev" },
  "plugins": [
    {
      "name": "cowork-guardrail",
      "source": "./cowork-guardrail",
      "description": "PreToolUse hook for Cowork. Calls the same Clawkeeper evaluate endpoint as Claude Code; org policy is authored at clawkeeper.dev/policies."
    }
  ]
}
MP_EOF

  cat > "${PLUGIN_ROOT}/.claude-plugin/plugin.json" <<PJ_EOF
{
  "name": "cowork-guardrail",
  "version": "${VERSION}",
  "description": "Clawkeeper PreToolUse hook for Cowork. Same policy engine as Claude Code; rules authored in the dashboard at clawkeeper.dev/policies apply to both surfaces.",
  "author": { "name": "Clawkeeper", "email": "support@clawkeeper.dev" },
  "homepage": "https://clawkeeper.dev/cowork"
}
PJ_EOF
  cp "${PLUGIN_ROOT}/.claude-plugin/plugin.json" "${CACHE_ROOT}/.claude-plugin/plugin.json"

  cat > "${PLUGIN_ROOT}/README.md" <<RM_EOF
# Clawkeeper Cowork Guardrail

PreToolUse hook for Cowork that POSTs every tool envelope to the
Clawkeeper evaluate endpoint and returns the server verdict.

- Policy: authored in the dashboard at https://clawkeeper.dev/policies
- API key: same one used for Claude Code (~/.clawkeeper-plugin/api_key)
- Status: /clawkeeper-code:cowork-status
- Uninstall: /clawkeeper-code:cowork-uninstall

Org rules apply to both Claude Code and Cowork. There is no separate
Cowork policy file. The hook fails open if the API is unreachable.
RM_EOF
  cp "${PLUGIN_ROOT}/README.md" "${CACHE_ROOT}/README.md"

  cat > "${PLUGIN_ROOT}/hooks/hooks.json" <<HK_EOF
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "${HOOK_CMD}",
            "timeout": 5,
            "_clawkeeper": true
          }
        ]
      }
    ]
  }
}
HK_EOF
  cp "${PLUGIN_ROOT}/hooks/hooks.json" "${CACHE_ROOT}/hooks/hooks.json"

  python3 - "$cw" "$MP_ROOT" "$CACHE_ROOT" "$VERSION" <<'PY_EOF'
import json, os, sys, datetime

cw_dir, mp_root, cache_root, version = sys.argv[1:5]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")

def load(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return default
    except Exception:
        return default

def save(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)

km_path = os.path.join(cw_dir, "known_marketplaces.json")
km = load(km_path, {})
km["clawkeeper"] = {
    "source": {"source": "local", "path": mp_root},
    "installLocation": mp_root,
    "lastUpdated": now,
}
save(km_path, km)

ip_path = os.path.join(cw_dir, "installed_plugins.json")
ip = load(ip_path, {"version": 2, "plugins": {}})
if "plugins" not in ip:
    ip["plugins"] = {}
ip["plugins"]["cowork-guardrail@clawkeeper"] = [{
    "scope": "user",
    "installPath": cache_root,
    "version": version,
    "installedAt": now,
    "lastUpdated": now,
}]
save(ip_path, ip)
PY_EOF

  log "  -> ${MP_ROOT}"
  log "  -> ${CACHE_ROOT}"
done <<EOF_DIRS
${COWORK_DIRS}
EOF_DIRS

if [ "${WORKSPACE_COUNT}" -eq 0 ]; then
  err "No Cowork workspaces matched. ${SESSIONS_DIR} contained no readable cowork_plugins directories."
  exit 1
fi

KEY_FILE="${HOME}/.clawkeeper-plugin/api_key"
if [ -s "${KEY_FILE}" ]; then
  KEY_STATE="present at ${KEY_FILE}"
else
  KEY_STATE="MISSING. Run /clawkeeper-code:connect first or rules from your dashboard will not apply."
fi

echo
echo "Clawkeeper Cowork hook installed."
echo
echo "  Workspaces:  ${WORKSPACE_COUNT}"
echo "  Hook:        ${HOOK_SCRIPT}"
echo "  API key:     ${KEY_STATE}"
echo "  Policy:      authored at https://clawkeeper.dev/policies (same rules apply to Claude Code and Cowork)"
echo
echo "Next: Quit Claude Desktop fully (Cmd-Q), relaunch, open a new Cowork chat,"
echo "      and try a path your dashboard policy blocks."
echo "      Status: /clawkeeper-code:cowork-status"
