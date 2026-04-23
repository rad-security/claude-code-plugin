#!/usr/bin/env bash
# install-hooks.sh — Install Clawkeeper IDE hooks for Cursor, Copilot, or Windsurf
#
# Usage: install-hooks.sh --ide <cursor|copilot|windsurf> [--project /path/to/project]
#
# Copies shared detection scripts + IDE adapter to ~/.clawkeeper/,
# generates the correct hooks.json for the target IDE at the project path.
#
# Exit codes:
#   0 = success
#   1 = argument error or install failure

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────
IDE=""
PROJECT_DIR=""
INSTALL_DIR="$HOME/.clawkeeper"
VERSION="1.0.0"

# Resolve the plugin source directory (where this script lives)
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Argument parsing ─────────────────────────────────────────────────────
usage() {
  echo "Usage: install-hooks.sh --ide <cursor|copilot|windsurf> [--project /path/to/project]"
  echo ""
  echo "Options:"
  echo "  --ide       Target IDE (required): cursor, copilot, or windsurf"
  echo "  --project   Project directory (default: current directory)"
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --ide)
      shift
      IDE="${1:-}"
      ;;
    --project)
      shift
      PROJECT_DIR="${1:-}"
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Error: Unknown argument '$1'"
      usage
      ;;
  esac
  shift
done

if [ -z "$IDE" ]; then
  echo "Error: --ide is required"
  usage
fi

case "$IDE" in
  cursor|copilot|windsurf) ;;
  *)
    echo "Error: --ide must be cursor, copilot, or windsurf (got: $IDE)"
    exit 1
    ;;
esac

# Default project to current directory
if [ -z "$PROJECT_DIR" ]; then
  PROJECT_DIR="$(pwd)"
fi

# Create project dir if it doesn't exist, then resolve to absolute path
mkdir -p "$PROJECT_DIR" 2>/dev/null || true
PROJECT_DIR="$(cd "$PROJECT_DIR" 2>/dev/null && pwd)"

# ── Verify source files exist ────────────────────────────────────────────
ADAPTER_SRC="${SOURCE_DIR}/adapters/${IDE}-adapter.sh"
if [ ! -f "$ADAPTER_SRC" ]; then
  echo "Error: Adapter not found: $ADAPTER_SRC"
  exit 1
fi

if [ ! -f "${SOURCE_DIR}/pre-tool-hook.sh" ]; then
  echo "Error: Shared scripts not found in $SOURCE_DIR"
  exit 1
fi

# ── Step 1: Create directory structure ───────────────────────────────────
echo "Installing Clawkeeper hooks for ${IDE}..."
echo ""

mkdir -p "${INSTALL_DIR}/scripts/lib"
mkdir -p "${INSTALL_DIR}/scripts/adapters"

# Handle legacy: ~/.clawkeeper/config may be a file (agent config), not a directory
if [ -f "${INSTALL_DIR}/config" ] && [ ! -d "${INSTALL_DIR}/config" ]; then
  mv "${INSTALL_DIR}/config" "${INSTALL_DIR}/config.bak"
  echo "  Backed up existing ${INSTALL_DIR}/config → config.bak"
fi
mkdir -p "${INSTALL_DIR}/config"

# Restore legacy config file contents into the config directory if needed
if [ -f "${INSTALL_DIR}/config.bak" ] && [ ! -f "${INSTALL_DIR}/config/agent.conf" ]; then
  mv "${INSTALL_DIR}/config.bak" "${INSTALL_DIR}/config/agent.conf"
fi

# ── Step 2: Copy shared scripts ──────────────────────────────────────────
# Copy lib/*.sh → ~/.clawkeeper/scripts/lib/
LIBS_COPIED=0
for libfile in "${SOURCE_DIR}"/lib/*.sh; do
  if [ -f "$libfile" ]; then
    cp "$libfile" "${INSTALL_DIR}/scripts/lib/"
    LIBS_COPIED=$((LIBS_COPIED + 1))
  fi
done

# Copy shared hook scripts → ~/.clawkeeper/scripts/
SCRIPTS_COPIED=0
for script in local-detect.sh pre-tool-hook.sh post-tool-hook.sh prompt-hook.sh session-start.sh; do
  if [ -f "${SOURCE_DIR}/${script}" ]; then
    cp "${SOURCE_DIR}/${script}" "${INSTALL_DIR}/scripts/"
    SCRIPTS_COPIED=$((SCRIPTS_COPIED + 1))
  fi
done

# ── Step 3: Copy target IDE adapter ──────────────────────────────────────
cp "$ADAPTER_SRC" "${INSTALL_DIR}/scripts/adapters/"

# ── Step 4: chmod +x all scripts ─────────────────────────────────────────
find "${INSTALL_DIR}/scripts" -name '*.sh' -type f -exec chmod +x {} \;

# ── Step 5: Generate integrity manifest ──────────────────────────────────
# Source key-resolver (for get_data_dir) and integrity (for generate_manifest)
export CLAUDE_PLUGIN_DATA="$INSTALL_DIR"
source "${INSTALL_DIR}/scripts/lib/key-resolver.sh" 2>/dev/null || true
source "${INSTALL_DIR}/scripts/lib/integrity.sh" 2>/dev/null || true

if type generate_manifest &>/dev/null; then
  generate_manifest "${INSTALL_DIR}/scripts" "$VERSION" 2>/dev/null || true
fi

# ── Step 6: Write version file ───────────────────────────────────────────
echo "$VERSION" > "${INSTALL_DIR}/config/version"

# ── Step 7: Migrate API key from legacy location ────────────────────────
LEGACY_KEY="$HOME/.clawkeeper-plugin/api_key"
NEW_KEY="${INSTALL_DIR}/config/api_key"
if [ -f "$LEGACY_KEY" ] && [ ! -f "$NEW_KEY" ]; then
  cp "$LEGACY_KEY" "$NEW_KEY"
  echo "  Migrated API key from ${LEGACY_KEY}"
fi

# ── Step 8: Generate IDE-specific hooks.json ─────────────────────────────
ADAPTER_PATH="${INSTALL_DIR}/scripts/adapters/${IDE}-adapter.sh"

generate_cursor_hooks() {
  local project="$1"
  local hooks_dir="${project}/.cursor"
  local hooks_file="${hooks_dir}/hooks.json"

  mkdir -p "$hooks_dir"

  cat > "$hooks_file" <<HOOKS_EOF
{
  "version": 1,
  "hooks": {
    "beforeShellExecution": [{"command": "${ADAPTER_PATH}", "timeout": 5, "failClosed": false, "_clawkeeper": true}],
    "beforeReadFile": [{"command": "${ADAPTER_PATH}", "timeout": 5, "failClosed": false, "_clawkeeper": true}],
    "afterFileEdit": [{"command": "${ADAPTER_PATH}", "timeout": 5, "failClosed": false, "_clawkeeper": true}],
    "beforeMCPExecution": [{"command": "${ADAPTER_PATH}", "timeout": 5, "failClosed": false, "_clawkeeper": true}],
    "beforeSubmitPrompt": [{"command": "${ADAPTER_PATH}", "timeout": 5, "failClosed": false, "_clawkeeper": true}]
  }
}
HOOKS_EOF

  echo "  Wrote ${hooks_file}"
}

generate_copilot_hooks() {
  local project="$1"
  local hooks_dir="${project}/.github/hooks"
  local hooks_file="${hooks_dir}/clawkeeper.json"

  mkdir -p "$hooks_dir"

  cat > "$hooks_file" <<HOOKS_EOF
{
  "hooks": {
    "PreToolUse": [{"type": "command", "command": "${ADAPTER_PATH}", "timeout": 5, "_clawkeeper": true}],
    "PostToolUse": [{"type": "command", "command": "${ADAPTER_PATH}", "timeout": 5, "_clawkeeper": true}],
    "UserPromptSubmit": [{"type": "command", "command": "${ADAPTER_PATH}", "timeout": 5, "_clawkeeper": true}],
    "SessionStart": [{"type": "command", "command": "${ADAPTER_PATH}", "timeout": 10, "_clawkeeper": true}]
  }
}
HOOKS_EOF

  echo "  Wrote ${hooks_file}"
}

generate_windsurf_hooks() {
  local project="$1"
  local hooks_dir="${project}/.windsurf"
  local hooks_file="${hooks_dir}/hooks.json"

  mkdir -p "$hooks_dir"

  cat > "$hooks_file" <<HOOKS_EOF
{
  "hooks": {
    "pre_run_command": [{"command": "${ADAPTER_PATH}", "_clawkeeper": true}],
    "pre_write_code": [{"command": "${ADAPTER_PATH}", "_clawkeeper": true}],
    "pre_read_code": [{"command": "${ADAPTER_PATH}", "_clawkeeper": true}],
    "pre_mcp_tool_use": [{"command": "${ADAPTER_PATH}", "_clawkeeper": true}],
    "pre_user_prompt": [{"command": "${ADAPTER_PATH}", "_clawkeeper": true}],
    "post_write_code": [{"command": "${ADAPTER_PATH}", "_clawkeeper": true}],
    "post_run_command": [{"command": "${ADAPTER_PATH}", "_clawkeeper": true}],
    "post_mcp_tool_use": [{"command": "${ADAPTER_PATH}", "_clawkeeper": true}]
  }
}
HOOKS_EOF

  echo "  Wrote ${hooks_file}"
}

case "$IDE" in
  cursor)   generate_cursor_hooks "$PROJECT_DIR" ;;
  copilot)  generate_copilot_hooks "$PROJECT_DIR" ;;
  windsurf) generate_windsurf_hooks "$PROJECT_DIR" ;;
esac

# ── Step 9: Print summary ───────────────────────────────────────────────
echo ""
echo "Clawkeeper installed successfully!"
echo ""
echo "  IDE:          ${IDE}"
echo "  Project:      ${PROJECT_DIR}"
echo "  Install dir:  ${INSTALL_DIR}"
echo "  Adapter:      ${ADAPTER_PATH}"
echo "  Libs copied:  ${LIBS_COPIED}"
echo "  Scripts:      ${SCRIPTS_COPIED}"
echo "  Version:      ${VERSION}"
echo ""
echo "Run 'cat ${INSTALL_DIR}/config/version' to verify."
