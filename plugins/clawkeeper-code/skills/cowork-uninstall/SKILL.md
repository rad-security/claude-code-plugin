---
name: cowork-uninstall
description: Remove the Clawkeeper Cowork PreToolUse guardrail from every Cowork workspace on this machine. Use when the user wants to disable, uninstall, or temporarily turn off Clawkeeper's Cowork guardrail. Add `--purge` to also delete the local policy file and audit log.
---

# Uninstall Clawkeeper Cowork Guardrail

You are removing the Clawkeeper PreToolUse hook from Cowork.

## Step 1: Parse arguments

Check the user's invocation. If `--purge` appears anywhere in the args, set `PURGE=1`. Otherwise `PURGE=0`.

## Step 2: Run the uninstaller

```bash
SCRIPT="${CLAUDE_PLUGIN_ROOT}/scripts/cowork-uninstall.sh"
[ -x "$SCRIPT" ] || SCRIPT="$(find "$HOME/.claude" -maxdepth 8 -path '*/clawkeeper*/scripts/cowork-uninstall.sh' -type f 2>/dev/null | head -1)"
[ -z "$SCRIPT" ] && SCRIPT="$(find "$HOME/Library/Application Support/Claude" -maxdepth 10 -path '*/clawkeeper*/scripts/cowork-uninstall.sh' -type f 2>/dev/null | head -1)"

if [ "$PURGE" = "1" ]; then
  "$SCRIPT" --purge
else
  "$SCRIPT"
fi
```

## Step 3: Tell the user what to do next

After a successful uninstall, display the script's output verbatim, then add:

```
Quit and relaunch Claude Desktop. The hook will no longer run on tool calls.
```

If `--purge` was NOT used, mention that the policy file and audit log were preserved at `~/.clawkeeper/cowork/`, and that running again with `--purge` will delete them.
