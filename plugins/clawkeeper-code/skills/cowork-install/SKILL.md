---
name: cowork-install
description: Install the Clawkeeper PreToolUse hook into Cowork (Claude Desktop). Same hook script and same dashboard policy as Claude Code — rules authored at clawkeeper.dev/policies apply to both surfaces. Use when the user wants to extend Clawkeeper coverage to Cowork, block Cowork tool calls per their org policy, or asks how to make Cowork safer.
---

# Install Clawkeeper Cowork Hook

You are installing the Clawkeeper hook for Cowork. Same script, same key, same dashboard policy as Claude Code.

## Step 1: Run the installer

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/cowork-install.sh"
```

If `CLAUDE_PLUGIN_ROOT` is not set:

```bash
SCRIPT="$(find "$HOME/.claude" -maxdepth 8 -path '*/clawkeeper*/scripts/cowork-install.sh' -type f 2>/dev/null | head -1)"
[ -z "$SCRIPT" ] && SCRIPT="$(find "$HOME/Library/Application Support/Claude" -maxdepth 10 -path '*/clawkeeper*/scripts/cowork-install.sh' -type f 2>/dev/null | head -1)"
"$SCRIPT"
```

If the installer exits non-zero, show the error verbatim and stop.

## Step 2: Confirm next steps

After a successful install:

```
Clawkeeper Cowork hook installed.

Required next step:
  1. Quit Claude Desktop fully (⌘Q).
  2. Relaunch Claude Desktop.
  3. Open a new Cowork chat. Tool calls now go through your dashboard policy.

If you haven't connected an account yet, run /clawkeeper-code:connect — without
an API key the hook fails open and dashboard rules won't apply.

Manage rules: https://clawkeeper.dev/policies
Status:       /clawkeeper-code:cowork-status
Uninstall:    /clawkeeper-code:cowork-uninstall
```

## Notes

- Idempotent — re-running is safe.
- Same `~/.clawkeeper-plugin/api_key` Claude Code uses; no separate auth.
- Org rules live in the dashboard at `/policies`. Cowork and Claude Code share them — there is no Cowork-specific policy file.
- Hook fails open by design: API down, no key, hook script error → allow + log. A misconfigured guardrail must not brick Cowork.
