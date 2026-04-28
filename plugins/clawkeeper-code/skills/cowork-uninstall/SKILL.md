---
name: cowork-uninstall
description: Remove the Clawkeeper Cowork PreToolUse hook from every Cowork workspace on this machine. Leaves ~/.clawkeeper/ alone (Claude Code may still use it). Use when the user wants to disable, uninstall, or temporarily turn off Clawkeeper's Cowork hook.
---

# Uninstall Clawkeeper Cowork Hook

## Step 1: Run the uninstaller

```bash
SCRIPT="${CLAUDE_PLUGIN_ROOT}/scripts/cowork-uninstall.sh"
[ -x "$SCRIPT" ] || SCRIPT="$(find "$HOME/.claude" -maxdepth 8 -path '*/clawkeeper*/scripts/cowork-uninstall.sh' -type f 2>/dev/null | head -1)"
[ -z "$SCRIPT" ] && SCRIPT="$(find "$HOME/Library/Application Support/Claude" -maxdepth 10 -path '*/clawkeeper*/scripts/cowork-uninstall.sh' -type f 2>/dev/null | head -1)"
"$SCRIPT"
```

## Step 2: Tell the user

Show the script's output verbatim, then add:

```
Quit and relaunch Claude Desktop. The hook will no longer run on Cowork tool calls.
~/.clawkeeper/scripts/ is left in place — Claude Code may still use it.
```
