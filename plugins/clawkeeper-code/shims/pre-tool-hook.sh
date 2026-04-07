#!/usr/bin/env bash
# Shim: finds the cached plugin and execs the real script.
# Installed to ~/.clawkeeper-plugin/hooks/ by the connect/setup skill.
set -euo pipefail
SCRIPT_NAME="pre-tool-hook.sh"
PLUGIN_DIR="$(ls -d "$HOME/.claude/plugins/cache/clawkeeper/clawkeeper-code"/*/scripts 2>/dev/null | tail -1)"
if [ -n "$PLUGIN_DIR" ] && [ -f "$PLUGIN_DIR/$SCRIPT_NAME" ]; then
  exec bash "$PLUGIN_DIR/$SCRIPT_NAME"
fi
echo '{}'
