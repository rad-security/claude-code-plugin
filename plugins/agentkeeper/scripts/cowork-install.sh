#!/usr/bin/env bash
# Install the AgentKeeper PreToolUse hook into Claude Cowork workspaces.
#
# The hook uses the same AgentKeeper policy engine as Claude Code, but marks
# events as source_tool=cowork so dashboard activity and investigations can
# distinguish Claude Desktop/Cowork from Claude Code.

set -eu

VERSION="0.3.0"
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="${AGENTKEEPER_INSTALL_DIR:-$HOME/.agentkeeper}"
SCRIPTS_DIR="${INSTALL_DIR}/scripts"
HOOK_SCRIPT="${SCRIPTS_DIR}/pre-tool-hook.sh"
API_URL="${AGENTKEEPER_API_URL:-https://www.agentkeeper.dev}"
API_URL="${API_URL%/}"

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

SESSIONS_DIR="${CLAUDE_DATA}/local-agent-mode-sessions"
if [ ! -d "$SESSIONS_DIR" ]; then
  err "No Cowork session directory found at:"
  err "  ${SESSIONS_DIR}"
  err "Open Claude Desktop, start Cowork once, then re-run this installer."
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  err "python3 is required to merge Cowork plugin registry JSON."
  err "Install Xcode Command Line Tools: xcode-select --install"
  exit 1
fi

echo "Installing AgentKeeper Cowork hook v${VERSION}..."
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
  err "pre-tool-hook.sh did not deploy to ${HOOK_SCRIPT}."
  exit 1
fi
log "Hook scripts deployed to ${SCRIPTS_DIR} (${DEPLOYED} top-level scripts)"

discover_cowork_dirs() {
  find "${SESSIONS_DIR}" -maxdepth 4 -type d -name cowork_plugins 2>/dev/null | sort
}

COWORK_DIRS="$(discover_cowork_dirs)"

if [ -z "${COWORK_DIRS}" ]; then
  log "No cowork_plugins directory found; creating one for each Cowork account/workspace."
  CANDIDATES="$(find "${SESSIONS_DIR}" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | grep -Ev '/(skills-plugin|cowork_plugins|cache|marketplaces)$' | sort | head -10 || true)"
  if [ -z "${CANDIDATES}" ]; then
    err "No account directories under ${SESSIONS_DIR}."
    err "Open Claude Desktop, send any message in Cowork mode, then re-run."
    exit 1
  fi

  while IFS= read -r account_dir; do
    [ -d "$account_dir" ] || continue
    INNER_DIRS="$(find "$account_dir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | grep -Ev '/(\\.claude-plugin|skills-plugin|cowork_plugins|cache|marketplaces)$' || true)"
    if [ -n "$INNER_DIRS" ]; then
      while IFS= read -r workspace_dir; do
        [ -d "$workspace_dir" ] || continue
        target="${workspace_dir}/cowork_plugins"
        mkdir -p "$target"
        log "Created ${target}"
      done <<EOF_INNER
${INNER_DIRS}
EOF_INNER
    else
      target="${account_dir}/cowork_plugins"
      mkdir -p "$target"
      log "Created ${target}"
    fi
  done <<EOF_CANDIDATES
${CANDIDATES}
EOF_CANDIDATES

  COWORK_DIRS="$(discover_cowork_dirs)"
fi

WORKSPACE_COUNT=0
while IFS= read -r cw; do
  [ -d "$cw" ] || continue
  WORKSPACE_COUNT=$((WORKSPACE_COUNT + 1))
  workspace_dir="$(dirname "$cw")"
  log "Workspace: ${workspace_dir##*/}"

  MP_ROOT="${cw}/marketplaces/agentkeeper"
  PLUGIN_ROOT="${MP_ROOT}/cowork-guardrail"
  CACHE_ROOT="${cw}/cache/agentkeeper/cowork-guardrail/${VERSION}"

  mkdir -p "${MP_ROOT}/.claude-plugin" \
           "${PLUGIN_ROOT}/.claude-plugin" \
           "${PLUGIN_ROOT}/hooks" \
           "${CACHE_ROOT}/.claude-plugin" \
           "${CACHE_ROOT}/hooks"

  python3 - "$cw" "$MP_ROOT" "$PLUGIN_ROOT" "$CACHE_ROOT" "$VERSION" "$HOOK_SCRIPT" "$API_URL" <<'PY_EOF'
import datetime
import json
import os
import shlex
import sys

cw_dir, mp_root, plugin_root, cache_root, version, hook_script, api_url = sys.argv[1:8]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
hook_inner = f'AGENTKEEPER_SKIP_CONFLICT_CHECK=1 AGENTKEEPER_API_TOOL=cowork AGENTKEEPER_API_URL={shlex.quote(api_url)} exec "{hook_script}"'
hook_cmd = f"/bin/sh -c {shlex.quote(hook_inner)}"

def load(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default

def save(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)

marketplace = {
    "name": "agentkeeper",
    "owner": {"name": "AgentKeeper", "email": "support@rad.security"},
    "plugins": [{
        "name": "cowork-guardrail",
        "source": "./cowork-guardrail",
        "description": "PreToolUse hook for Claude Cowork. Calls AgentKeeper's policy engine with source_tool=cowork."
    }],
}
save(os.path.join(mp_root, ".claude-plugin", "marketplace.json"), marketplace)

plugin = {
    "name": "cowork-guardrail",
    "version": version,
    "description": "AgentKeeper PreToolUse hook for Claude Cowork. Dashboard rules apply to Claude Code and Cowork.",
    "author": {"name": "AgentKeeper", "email": "support@rad.security"},
    "homepage": "https://www.agentkeeper.dev/docs/cowork-plugin",
}
save(os.path.join(plugin_root, ".claude-plugin", "plugin.json"), plugin)
save(os.path.join(cache_root, ".claude-plugin", "plugin.json"), plugin)

readme = """# AgentKeeper Cowork Guardrail

PreToolUse hook for Claude Cowork that evaluates each tool envelope against
AgentKeeper dashboard policy and records activity with source_tool=cowork.

- Policy: authored in the AgentKeeper dashboard
- API key: ~/.agentkeeper-plugin/api_key or ~/.agentkeeper/config/api_key
- Fails open if the API is unreachable
"""
for root in (plugin_root, cache_root):
    with open(os.path.join(root, "README.md"), "w", encoding="utf-8") as f:
        f.write(readme)

hooks = {
    "hooks": {
        "PreToolUse": [{
            "matcher": "*",
            "hooks": [{
                "type": "command",
                "command": hook_cmd,
                "timeout": 5,
                "_agentkeeper": True,
            }],
        }],
    },
}
save(os.path.join(plugin_root, "hooks", "hooks.json"), hooks)
save(os.path.join(cache_root, "hooks", "hooks.json"), hooks)

km_path = os.path.join(cw_dir, "known_marketplaces.json")
known = load(km_path, {})
if not isinstance(known, dict):
    known = {}
known["agentkeeper"] = {
    "source": {"source": "local", "path": mp_root},
    "installLocation": mp_root,
    "lastUpdated": now,
}
save(km_path, known)

settings_path = os.path.join(os.path.dirname(cw_dir), "cowork_settings.json")
settings = load(settings_path, {})
if not isinstance(settings, dict):
    settings = {}
if not isinstance(settings.get("enabledPlugins"), dict):
    settings["enabledPlugins"] = {}
settings["enabledPlugins"]["cowork-guardrail@agentkeeper"] = True
if not isinstance(settings.get("extraKnownMarketplaces"), dict):
    settings["extraKnownMarketplaces"] = {}
settings["extraKnownMarketplaces"]["agentkeeper"] = {
    "source": {"source": "local", "path": mp_root},
}
save(settings_path, settings)

ip_path = os.path.join(cw_dir, "installed_plugins.json")
installed = load(ip_path, {"version": 2, "plugins": {}})
if not isinstance(installed, dict):
    installed = {"version": 2, "plugins": {}}
installed.setdefault("version", 2)
if not isinstance(installed.get("plugins"), dict):
    installed["plugins"] = {}
installed["plugins"]["cowork-guardrail@agentkeeper"] = [{
    "scope": "user",
    "installPath": cache_root,
    "version": version,
    "installedAt": now,
    "lastUpdated": now,
}]
save(ip_path, installed)
PY_EOF

  log "  -> ${MP_ROOT}"
  log "  -> ${CACHE_ROOT}"
done <<EOF_DIRS
${COWORK_DIRS}
EOF_DIRS

if [ "${WORKSPACE_COUNT}" -eq 0 ]; then
  err "No readable Cowork workspaces found under ${SESSIONS_DIR}."
  exit 1
fi

KEY_STATE="missing"
if [ -s "${HOME}/.agentkeeper-plugin/api_key" ]; then
  KEY_STATE="present at ${HOME}/.agentkeeper-plugin/api_key"
elif [ -s "${HOME}/.agentkeeper/config/api_key" ]; then
  KEY_STATE="present at ${HOME}/.agentkeeper/config/api_key"
fi

echo
echo "AgentKeeper Cowork hook installed."
echo
echo "  Workspaces:  ${WORKSPACE_COUNT}"
echo "  Hook:        ${HOOK_SCRIPT}"
echo "  API URL:     ${API_URL}"
echo "  API key:     ${KEY_STATE}"
echo "  Policy:      dashboard Runtime Shield policy, source_tool=cowork"
echo
echo "Next: Quit Claude Desktop fully (Cmd-Q), relaunch, open a new Cowork chat,"
echo "      and try a tool call your dashboard policy blocks."
