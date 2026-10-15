#!/usr/bin/env bash
# Install the AgentKeeper PreToolUse hook into Claude Cowork workspaces.
#
# The hook uses the same AgentKeeper policy engine as Claude Code, but marks
# events as source_tool=cowork so dashboard activity and investigations can
# distinguish Claude Desktop/Cowork from Claude Code.

set -eu

VERSION="0.3.11"
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="${AGENTKEEPER_INSTALL_DIR:-$HOME/.agentkeeper}"
SCRIPTS_DIR="${INSTALL_DIR}/scripts"
HOOK_SCRIPT="${SCRIPTS_DIR}/pre-tool-hook.sh"
API_URL="${AGENTKEEPER_API_URL:-https://www.agentkeeper.dev}"
API_URL="${API_URL%/}"

err() { printf 'Error: %s\n' "$*" >&2; }
log() { printf '  %s\n' "$*"; }

# shellcheck disable=SC1090
source "${SOURCE_DIR}/lib/json-helpers.sh" 2>/dev/null || true
# shellcheck disable=SC1090
source "${SOURCE_DIR}/lib/cowork-json.sh" 2>/dev/null || true

OS_NAME="$(uname -s)"
case "$OS_NAME" in
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

HAS_PLUTIL=0
if command -v plutil >/dev/null 2>&1; then
  HAS_PLUTIL=1
elif [ "$OS_NAME" = "Darwin" ]; then
  err "macOS plutil is required to merge Cowork plugin registry JSON."
  exit 1
else
  log "macOS plutil is not available; using best-effort Linux registry writes."
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
           "${PLUGIN_ROOT}/claude-plugin" \
           "${PLUGIN_ROOT}/hooks" \
           "${CACHE_ROOT}/.claude-plugin" \
           "${CACHE_ROOT}/claude-plugin" \
           "${CACHE_ROOT}/hooks"

  now="$(cowork_iso_now)"
  hook_cmd="/bin/sh -c 'AGENTKEEPER_SKIP_CONFLICT_CHECK=1 AGENTKEEPER_API_TOOL=cowork AGENTKEEPER_API_URL=${API_URL} exec \"\${CLAUDE_PLUGIN_ROOT}/scripts/pre-tool-hook.sh\"'"
  hook_cmd_json="$(cowork_json_escape "$hook_cmd")"
  mp_root_json="$(cowork_json_escape "$MP_ROOT")"
  cache_root_json="$(cowork_json_escape "$CACHE_ROOT")"

  for path in \
    "${MP_ROOT}/.claude-plugin/marketplace.json" \
    "${PLUGIN_ROOT}/.claude-plugin/plugin.json" \
    "${CACHE_ROOT}/.claude-plugin/plugin.json" \
    "${PLUGIN_ROOT}/claude-plugin/plugin.json" \
    "${CACHE_ROOT}/claude-plugin/plugin.json" \
    "${PLUGIN_ROOT}/hooks/hooks.json" \
    "${CACHE_ROOT}/hooks/hooks.json"
  do
    mkdir -p "$(dirname "$path")"
  done

  cat > "${MP_ROOT}/.claude-plugin/marketplace.json" <<EOF_JSON
{
  "name": "agentkeeper",
  "owner": { "name": "AgentKeeper", "email": "support@rad.security" },
  "plugins": [
    {
      "name": "cowork-guardrail",
      "source": "./cowork-guardrail",
      "description": "UserPromptSubmit and PreToolUse hooks for Claude Cowork. Calls AgentKeeper's policy engine with source_tool=cowork."
    }
  ]
}
EOF_JSON

  plugin_json="$(cat <<EOF_JSON
{
  "name": "cowork-guardrail",
  "version": "${VERSION}",
  "installationPreference": "required",
  "description": "AgentKeeper UserPromptSubmit and PreToolUse hooks for Claude Cowork. Dashboard rules apply to Claude Code and Cowork.",
  "author": { "name": "AgentKeeper", "email": "support@rad.security" },
  "homepage": "https://docs.agentkeeper.dev/connect/agents/cowork-plugin",
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "${hook_cmd_json}", "timeout": 5, "_agentkeeper": true }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "${hook_cmd_json}", "timeout": 5, "_agentkeeper": true }
        ]
      }
    ]
  }
}
EOF_JSON
)"
  hooks_json="$(cat <<EOF_JSON
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "${hook_cmd_json}", "timeout": 5, "_agentkeeper": true }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "${hook_cmd_json}", "timeout": 5, "_agentkeeper": true }
        ]
      }
    ]
  }
}
EOF_JSON
)"
  for path in \
    "${PLUGIN_ROOT}/.claude-plugin/plugin.json" \
    "${CACHE_ROOT}/.claude-plugin/plugin.json" \
    "${PLUGIN_ROOT}/claude-plugin/plugin.json" \
    "${CACHE_ROOT}/claude-plugin/plugin.json"
  do
    printf '%s\n' "$plugin_json" > "$path"
  done
  printf '{ "version": "%s" }\n' "$VERSION" > "${PLUGIN_ROOT}/version.json"
  printf '{ "version": "%s" }\n' "$VERSION" > "${CACHE_ROOT}/version.json"
  printf '{ "version": "%s" }\n' "$VERSION" > "${PLUGIN_ROOT}/claude-plugin/version.json"
  printf '{ "version": "%s" }\n' "$VERSION" > "${CACHE_ROOT}/claude-plugin/version.json"
  printf '%s\n' "$hooks_json" > "${PLUGIN_ROOT}/hooks/hooks.json"
  printf '%s\n' "$hooks_json" > "${CACHE_ROOT}/hooks/hooks.json"

  for root in "${PLUGIN_ROOT}" "${CACHE_ROOT}"; do
    cat > "${root}/README.md" <<'EOF_README'
# AgentKeeper Cowork Guardrail

UserPromptSubmit and PreToolUse hooks for Claude Cowork that evaluate prompts
and tool envelopes against AgentKeeper dashboard policy and record activity
with source_tool=cowork.

- Policy: authored in the AgentKeeper dashboard
- API key: ~/.agentkeeper-plugin/api_key or ~/.agentkeeper/config/api_key
- Fails open if the API is unreachable
EOF_README
  done

  settings_path="$(dirname "$cw")/cowork_settings.json"
  if [ "$HAS_PLUTIL" -eq 1 ]; then
    if cowork_json_begin "${cw}/known_marketplaces.json"; then
      cowork_json_set_json "agentkeeper" "{ \"source\": { \"source\": \"local\", \"path\": \"${mp_root_json}\" }, \"installLocation\": \"${mp_root_json}\", \"lastUpdated\": \"${now}\" }" || true
      cowork_json_commit || true
    fi

    if cowork_json_begin "$settings_path"; then
      cowork_json_ensure_dict "enabledPlugins" || true
      cowork_json_set_bool "enabledPlugins.cowork-guardrail@agentkeeper" "true" || true
      cowork_json_ensure_dict "extraKnownMarketplaces" || true
      cowork_json_set_json "extraKnownMarketplaces.agentkeeper" "{ \"source\": { \"source\": \"local\", \"path\": \"${mp_root_json}\" } }" || true
      cowork_json_commit || true
    fi

    if cowork_json_begin "${cw}/installed_plugins.json"; then
      cowork_json_set_json "version" "2" || true
      cowork_json_ensure_dict "plugins" || true
      cowork_json_set_json "plugins.cowork-guardrail@agentkeeper" "[{ \"scope\": \"user\", \"installPath\": \"${cache_root_json}\", \"version\": \"${VERSION}\", \"installedAt\": \"${now}\", \"lastUpdated\": \"${now}\" }]" || true
      cowork_json_commit || true
    fi
  else
    if [ -f "${cw}/known_marketplaces.json" ]; then
      log "Preserving existing ${cw}/known_marketplaces.json because plutil is unavailable."
    else
      cat > "${cw}/known_marketplaces.json" <<EOF_JSON
{
  "agentkeeper": {
    "source": { "source": "local", "path": "${mp_root_json}" },
    "installLocation": "${mp_root_json}",
    "lastUpdated": "${now}"
  }
}
EOF_JSON
    fi

    if [ -f "$settings_path" ]; then
      log "Preserving existing ${settings_path} because plutil is unavailable."
    else
      cat > "$settings_path" <<EOF_JSON
{
  "enabledPlugins": {
    "cowork-guardrail@agentkeeper": true
  },
  "extraKnownMarketplaces": {
    "agentkeeper": {
      "source": { "source": "local", "path": "${mp_root_json}" }
    }
  }
}
EOF_JSON
    fi

    if [ -f "${cw}/installed_plugins.json" ]; then
      log "Preserving existing ${cw}/installed_plugins.json because plutil is unavailable."
    else
      cat > "${cw}/installed_plugins.json" <<EOF_JSON
{
  "version": 2,
  "plugins": {
    "cowork-guardrail@agentkeeper": [
      {
        "scope": "user",
        "installPath": "${cache_root_json}",
        "version": "${VERSION}",
        "installedAt": "${now}",
        "lastUpdated": "${now}"
      }
    ]
  }
}
EOF_JSON
    fi
  fi

  for root in "${PLUGIN_ROOT}" "${CACHE_ROOT}"; do
    mkdir -p "${root}/scripts/lib"
    cp "${SCRIPTS_DIR}/pre-tool-hook.sh" "${root}/scripts/pre-tool-hook.sh"
    cp "${SCRIPTS_DIR}/local-detect.sh" "${root}/scripts/local-detect.sh"
    cp "${SCRIPTS_DIR}/lib/"*.sh "${root}/scripts/lib/" 2>/dev/null || true
    chmod +x "${root}/scripts/pre-tool-hook.sh" "${root}/scripts/local-detect.sh" 2>/dev/null || true
  done

  log "  -> ${MP_ROOT}"
  log "  -> ${CACHE_ROOT}"
  log "  -> self-contained hook scripts embedded"
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
echo "Important:"
echo "  This filesystem install is a compatibility path. It proves AgentKeeper"
echo "  hook files and credentials are present, but live Cowork protection is"
echo "  confirmed only after a real Cowork tool call updates cowork-status.sh."
echo "  Standard Claude Cowork Team/Enterprise may require a Claude org owner"
echo "  to distribute the plugin through Organization settings > Plugins."
echo
echo "Next: Quit Claude Desktop fully (Cmd-Q), relaunch, open a new Cowork chat,"
echo "      and try a tool call your dashboard policy blocks."
echo
echo "Self-test after relaunch:"
echo "  AGENTKEEPER_API_URL=\"${API_URL}\" bash <(curl -fsSL ${API_URL}/cowork-status.sh) --self-test"
