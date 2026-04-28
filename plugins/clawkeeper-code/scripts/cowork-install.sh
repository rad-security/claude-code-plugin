#!/usr/bin/env bash
# cowork-install.sh — Install the Clawkeeper PreToolUse hook into Cowork
# (Claude Desktop), reusing the same hook script, key resolver, and policy
# delivery that already power Claude Code.
#
# Architecture: identical to Claude Code. The hook script reads stdin,
# resolves the API key from ~/.clawkeeper-plugin/, POSTs the envelope to
# https://clawkeeper.dev/api/v1/claude-code/evaluate, and returns the
# server's verdict. Org policy is authored in the dashboard at /policies
# and applies to both surfaces.
#
# What this script does:
#   1. Deploys pre-tool-hook.sh + lib + local-detect.sh to ~/.clawkeeper/
#      (only if not already there from a previous /clawkeeper-code:setup)
#   2. For every Cowork workspace, writes a self-contained "clawkeeper"
#      marketplace + "cowork-guardrail" plugin pointing at the hook
#   3. Registers the marketplace + plugin in Cowork's index files
#
# Idempotent. Re-running is safe; never overwrites the API key.

set -euo pipefail

VERSION="0.2.0"
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/.clawkeeper"
SCRIPTS_DIR="${INSTALL_DIR}/scripts"
HOOK_CMD="${SCRIPTS_DIR}/pre-tool-hook.sh"

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
  err "Install Xcode Command Line Tools (\`xcode-select --install\`) or Homebrew Python."
  exit 1
fi

echo "Installing Clawkeeper Cowork hook v${VERSION}..."
echo

# ── Step 1: deploy the standard Clawkeeper hook scripts ──────────────────
# These are the SAME scripts Claude Code uses. If the user has already run
# /clawkeeper-code:setup or installed for an IDE, they're already in place.
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

if [ ! -x "${HOOK_CMD}" ]; then
  err "pre-tool-hook.sh did not deploy to ${HOOK_CMD}. Bailing."
  exit 1
fi
log "Hook scripts deployed → ${SCRIPTS_DIR} (${DEPLOYED} top-level scripts)"

# ── Step 2: walk every Cowork workspace and install our plugin tree ──────
SESSIONS_DIR="${CLAUDE_DATA}/local-agent-mode-sessions"
WORKSPACE_COUNT=0

for cw in "${SESSIONS_DIR}"/*/*/cowork_plugins; do
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
      "description": "PreToolUse hook for Cowork. Calls the same Clawkeeper evaluate endpoint as Claude Code; org policy is authored in the dashboard at clawkeeper.dev/policies."
    }
  ]
}
MP_EOF

  PLUGIN_MANIFEST=$(cat <<PJ_EOF
{
  "name": "cowork-guardrail",
  "version": "${VERSION}",
  "description": "Clawkeeper PreToolUse hook for Cowork. Same policy engine as Claude Code — rules authored in the dashboard at clawkeeper.dev/policies apply to both surfaces.",
  "author": { "name": "Clawkeeper", "email": "support@clawkeeper.dev" },
  "homepage": "https://clawkeeper.dev/cowork"
}
PJ_EOF
  )
  printf '%s\n' "${PLUGIN_MANIFEST}" > "${PLUGIN_ROOT}/.claude-plugin/plugin.json"
  printf '%s\n' "${PLUGIN_MANIFEST}" > "${CACHE_ROOT}/.claude-plugin/plugin.json"

  README_TEXT=$(cat <<RM_EOF
# Clawkeeper Cowork Guardrail

PreToolUse hook for Cowork that POSTs every tool envelope to the
Clawkeeper evaluate endpoint and returns the server's verdict.

- Policy: authored in the dashboard at https://clawkeeper.dev/policies
- API key: same one used for Claude Code (\`~/.clawkeeper-plugin/api_key\`)
- Status: \`/clawkeeper-code:cowork-status\`
- Uninstall: \`/clawkeeper-code:cowork-uninstall\`

Org rules apply to both Claude Code and Cowork — there is no separate
Cowork policy file. The hook fails open if the API is unreachable.
RM_EOF
  )
  printf '%s\n' "${README_TEXT}" > "${PLUGIN_ROOT}/README.md"
  printf '%s\n' "${README_TEXT}" > "${CACHE_ROOT}/README.md"

  HOOKS_JSON=$(cat <<HK_EOF
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
  )
  printf '%s\n' "${HOOKS_JSON}" > "${PLUGIN_ROOT}/hooks/hooks.json"
  printf '%s\n' "${HOOKS_JSON}" > "${CACHE_ROOT}/hooks/hooks.json"

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

  log "  → ${MP_ROOT}"
  log "  → ${CACHE_ROOT}"
done

if [ "${WORKSPACE_COUNT}" -eq 0 ]; then
  err "No Cowork workspaces found under ${SESSIONS_DIR}."
  err "Open Cowork once, then re-run this installer."
  exit 1
fi

# ── Step 3: API key check ────────────────────────────────────────────────
KEY_FILE="${HOME}/.clawkeeper-plugin/api_key"
if [ -s "${KEY_FILE}" ]; then
  KEY_STATE="present at ${KEY_FILE}"
else
  KEY_STATE="MISSING — run /clawkeeper-code:connect first or rules from your dashboard won't apply"
fi

echo
echo "Clawkeeper Cowork hook installed."
echo
echo "  Workspaces:  ${WORKSPACE_COUNT}"
echo "  Hook:        ${HOOK_CMD}"
echo "  API key:     ${KEY_STATE}"
echo "  Policy:      authored at https://clawkeeper.dev/policies (same rules apply to Claude Code and Cowork)"
echo
echo "Next: Quit Claude Desktop fully (⌘Q), relaunch, open a new Cowork chat,"
echo "      and try a path your dashboard policy blocks. Status: /clawkeeper-code:cowork-status"
