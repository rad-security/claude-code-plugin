---
name: cowork-install
description: Install AgentKeeper PreToolUse hooks into Claude Cowork (Claude Desktop). Run when the user wants to protect Cowork or install AgentKeeper for Cowork.
---

# AgentKeeper Cowork Install

Install the AgentKeeper Cowork hook from the bundled plugin scripts:

```bash
"$CLAUDE_PLUGIN_ROOT/scripts/cowork-install.sh"
```

If `$CLAUDE_PLUGIN_ROOT` is not available, resolve the plugin root from the
current skill directory and run `scripts/cowork-install.sh`.

After the script completes, tell the user:

```text
AgentKeeper Cowork hooks are installed. Quit Claude Desktop fully (Cmd-Q),
relaunch it, then start a new Cowork chat. Run /agentkeeper:cowork-status to
check the install state.
```
