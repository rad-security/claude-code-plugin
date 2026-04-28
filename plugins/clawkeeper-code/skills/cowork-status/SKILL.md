---
name: cowork-status
description: Show install state of the Clawkeeper Cowork PreToolUse hook — hook script, API key, and per-workspace install. Use when the user wants to verify Cowork hook is active or check whether the install ran cleanly.
---

# Cowork Hook Status

```bash
SCRIPT="${CLAUDE_PLUGIN_ROOT}/scripts/cowork-status.sh"
[ -x "$SCRIPT" ] || SCRIPT="$(find "$HOME/.claude" -maxdepth 8 -path '*/clawkeeper*/scripts/cowork-status.sh' -type f 2>/dev/null | head -1)"
[ -z "$SCRIPT" ] && SCRIPT="$(find "$HOME/Library/Application Support/Claude" -maxdepth 10 -path '*/clawkeeper*/scripts/cowork-status.sh' -type f 2>/dev/null | head -1)"
"$SCRIPT"
```

Show output verbatim. Then:

- If the hook script is missing → suggest `/clawkeeper-code:cowork-install`.
- If the API key is missing → suggest `/clawkeeper-code:connect`.
- If install looks clean but no events have been observed → remind the user to Quit + relaunch Claude Desktop, and that recent events live on the dashboard at `https://clawkeeper.dev/dashboard`.
- Tool-call events do not appear in this status output; they stream to the dashboard. Direct the user there for activity.
