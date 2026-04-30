---
name: cowork-status
description: Check AgentKeeper Claude Cowork hook installation status across local Cowork workspaces.
---

# AgentKeeper Cowork Status

Run the bundled status script:

```bash
"$CLAUDE_PLUGIN_ROOT/scripts/cowork-status.sh"
```

If `$CLAUDE_PLUGIN_ROOT` is not available, resolve the plugin root from the
current skill directory and run `scripts/cowork-status.sh`.

Report the hook script state, API key state, and any missing per-workspace
marketplace/cache hook entries.
