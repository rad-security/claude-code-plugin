---
name: cowork-uninstall
description: Remove AgentKeeper Claude Cowork hook entries from local Cowork workspaces.
---

# AgentKeeper Cowork Uninstall

Run the bundled uninstall script:

```bash
"$CLAUDE_PLUGIN_ROOT/scripts/cowork-uninstall.sh"
```

If `$CLAUDE_PLUGIN_ROOT` is not available, resolve the plugin root from the
current skill directory and run `scripts/cowork-uninstall.sh`.

After uninstalling, tell the user to quit and relaunch Claude Desktop.
