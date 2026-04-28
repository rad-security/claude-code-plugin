---
name: cowork-status
description: Show the install state of the Clawkeeper Cowork PreToolUse guardrail — hook script, policy file, audit log, per-workspace install, and the last 5 events. Use when the user wants to verify Cowork guardrail is active, check whether the hook is firing, or see what's been blocked recently.
---

# Cowork Guardrail Status

Run the status script and display its output.

## Step 1: Run the status script

```bash
SCRIPT="${CLAUDE_PLUGIN_ROOT}/scripts/cowork-status.sh"
[ -x "$SCRIPT" ] || SCRIPT="$(find "$HOME/.claude" -maxdepth 8 -path '*/clawkeeper*/scripts/cowork-status.sh' -type f 2>/dev/null | head -1)"
[ -z "$SCRIPT" ] && SCRIPT="$(find "$HOME/Library/Application Support/Claude" -maxdepth 10 -path '*/clawkeeper*/scripts/cowork-status.sh' -type f 2>/dev/null | head -1)"
"$SCRIPT"
```

## Step 2: Surface output as-is

Show the script's output verbatim. Don't paraphrase. Users running this command want the literal status, not a summary.

## Step 3: Offer follow-ups based on what's shown

- If the hook script or policy is missing → suggest `/clawkeeper-code:cowork-install`.
- If "events log: 0 entries" and the install looks correct → remind the user to Quit + relaunch Claude Desktop, then trigger the hook by trying a blocked path in Cowork (e.g. `list ~/Documents/PHI`).
- If recent events are visible → call out any `block` verdicts as a sanity check that the policy is firing.
- If the user asks how to edit the policy → it lives at `~/.clawkeeper/cowork/policy.json`. Default rules are at `~/.clawkeeper/cowork/policy.default.json` for reference.
