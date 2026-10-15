---
name: cowork-uninstall
description: Remove AgentKeeper Claude Cowork hook entries from local Cowork workspaces and any lingering MCP server entries from Claude settings.
---

# AgentKeeper Cowork Uninstall

Run the bundled uninstall script:

```bash
"$CLAUDE_PLUGIN_ROOT/scripts/cowork-uninstall.sh"
```

If `$CLAUDE_PLUGIN_ROOT` is not available, resolve the plugin root from the
current skill directory and run `scripts/cowork-uninstall.sh`.

The script removes Cowork plugin registrations from all workspaces and also
cleans any `agentkeeper` MCP server entries from `~/.claude/settings.json`,
`~/.mcp.json`, and `~/.claude/.mcp.json`.

After uninstalling, tell the user to quit and relaunch Claude Desktop.
