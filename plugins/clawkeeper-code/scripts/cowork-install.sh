#!/usr/bin/env bash
# cowork-install.sh — Install the Clawkeeper Cowork PreToolUse guardrail.
#
# What this does:
#   1. Copies the hook scripts and default policy to ~/.clawkeeper/
#   2. For every Cowork workspace on this machine, creates a self-contained
#      "clawkeeper" marketplace + "cowork-guardrail" plugin under
#      cowork_plugins/marketplaces/ and mirrors it into cowork_plugins/cache/
#   3. Registers the marketplace in known_marketplaces.json and the plugin
#      in installed_plugins.json so Cowork loads it on next launch
#
# After install, the user must Quit + relaunch Claude Desktop for the hook to
# take effect.
#
# Idempotent: safe to re-run; never overwrites a customized policy.json once
# the user has edited it (we leave a .default copy for diffing).
#
# Exit codes:
#   0 = success
#   1 = error (missing python3, no Cowork install detected, etc.)

set -euo pipefail

VERSION="0.1.0"
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/.clawkeeper"
COWORK_DATA_DIR="${INSTALL_DIR}/cowork"
SCRIPTS_DIR="${INSTALL_DIR}/scripts"
HOOK_CMD="${SCRIPTS_DIR}/cowork-pre-tool.sh"
POLICY_FILE="${COWORK_DATA_DIR}/policy.json"

err() { printf 'Error: %s\n' "$*" >&2; }
log() { printf '  %s\n' "$*"; }

# ── Preflight ─────────────────────────────────────────────────────────────
if ! command -v python3 >/dev/null 2>&1; then
  err "python3 is required (used by the hook evaluator and JSON merger)."
  err "Install Xcode Command Line Tools (\`xcode-select --install\`) or Homebrew Python."
  exit 1
fi

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

# ── Step 1: install scripts + default policy under ~/.clawkeeper ──────────
echo "Installing Clawkeeper Cowork guardrail v${VERSION}..."
echo

mkdir -p "${SCRIPTS_DIR}" "${COWORK_DATA_DIR}"

cp "${SOURCE_DIR}/cowork-pre-tool.sh" "${SCRIPTS_DIR}/cowork-pre-tool.sh"
cp "${SOURCE_DIR}/cowork-pre-tool.py" "${SCRIPTS_DIR}/cowork-pre-tool.py"
chmod +x "${SCRIPTS_DIR}/cowork-pre-tool.sh" "${SCRIPTS_DIR}/cowork-pre-tool.py"
log "Installed hook scripts → ${SCRIPTS_DIR}"

# Always refresh the canonical default copy.
cp "${SOURCE_DIR}/cowork-policy-default.json" "${COWORK_DATA_DIR}/policy.default.json"

# Only seed policy.json if the user hasn't customized it. We never overwrite a
# user-edited policy on reinstall.
if [ ! -f "${POLICY_FILE}" ]; then
  cp "${SOURCE_DIR}/cowork-policy-default.json" "${POLICY_FILE}"
  log "Seeded default policy → ${POLICY_FILE}"
else
  log "Existing policy preserved → ${POLICY_FILE}"
  log "  (compare against policy.default.json to see new defaults)"
fi

touch "${COWORK_DATA_DIR}/events.log"

# ── Step 2: walk every Cowork workspace and register our plugin ───────────
SESSIONS_DIR="${CLAUDE_DATA}/local-agent-mode-sessions"

WORKSPACE_COUNT=0
INSTALL_COUNT=0

# Glob: */*/cowork_plugins matches <ownerAccount>/<workspace>/cowork_plugins.
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

  # marketplace.json
  cat > "${MP_ROOT}/.claude-plugin/marketplace.json" <<MP_EOF
{
  "name": "clawkeeper",
  "owner": { "name": "Clawkeeper", "email": "support@clawkeeper.dev" },
  "plugins": [
    {
      "name": "cowork-guardrail",
      "source": "./cowork-guardrail",
      "description": "PreToolUse policy guardrail for Cowork. Blocks tool calls that touch PHI, secrets, or other paths your org has flagged as off-limits."
    }
  ]
}
MP_EOF

  # plugin.json (twice — under marketplaces/ and cache/)
  PLUGIN_MANIFEST=$(cat <<PJ_EOF
{
  "name": "cowork-guardrail",
  "version": "${VERSION}",
  "description": "Clawkeeper PreToolUse guardrail. Blocks Cowork tool calls that violate your local policy (PHI paths, secrets, restricted directories).",
  "author": { "name": "Clawkeeper", "email": "support@clawkeeper.dev" },
  "homepage": "https://clawkeeper.dev/cowork"
}
PJ_EOF
  )
  printf '%s\n' "${PLUGIN_MANIFEST}" > "${PLUGIN_ROOT}/.claude-plugin/plugin.json"
  printf '%s\n' "${PLUGIN_MANIFEST}" > "${CACHE_ROOT}/.claude-plugin/plugin.json"

  # README.md (Cowork's plugin UI displays this)
  README_TEXT=$(cat <<RM_EOF
# Clawkeeper Cowork Guardrail

PreToolUse hook that evaluates every Cowork tool call against your local
Clawkeeper policy. Blocked calls are refused with a Clawkeeper-attributed
message; warns and allows are logged.

- Policy file: \`~/.clawkeeper/cowork/policy.json\`
- Audit log:   \`~/.clawkeeper/cowork/events.log\`
- Status:      \`/clawkeeper-code:cowork-status\`
- Uninstall:   \`/clawkeeper-code:cowork-uninstall\`

This plugin runs entirely on your machine. No tool-call data leaves your host
unless you opt into telemetry (default: off).
RM_EOF
  )
  printf '%s\n' "${README_TEXT}" > "${PLUGIN_ROOT}/README.md"
  printf '%s\n' "${README_TEXT}" > "${CACHE_ROOT}/README.md"

  # hooks.json (twice — marketplaces/ and cache/, validated as required by demo)
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

  # Register marketplace + plugin in the registry files.
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

# known_marketplaces.json
km_path = os.path.join(cw_dir, "known_marketplaces.json")
km = load(km_path, {})
km["clawkeeper"] = {
    "source": {"source": "local", "path": mp_root},
    "installLocation": mp_root,
    "lastUpdated": now,
}
save(km_path, km)

# installed_plugins.json
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
  INSTALL_COUNT=$((INSTALL_COUNT + 1))
done

if [ "${WORKSPACE_COUNT}" -eq 0 ]; then
  err "No Cowork workspaces found under ${SESSIONS_DIR}."
  err "Open Cowork once, then re-run this installer."
  exit 1
fi

echo
echo "Clawkeeper Cowork guardrail installed."
echo
echo "  Workspaces:  ${INSTALL_COUNT}"
echo "  Hook script: ${HOOK_CMD}"
echo "  Policy:      ${POLICY_FILE}"
echo "  Audit log:   ${COWORK_DATA_DIR}/events.log"
echo
echo "Next: Quit Claude Desktop fully, then relaunch."
echo "      Open a Cowork chat and try a path the policy blocks (e.g. \"list ~/Documents/PHI\")."
echo "      To check status: /clawkeeper-code:cowork-status"
