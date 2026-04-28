---
name: cowork-install
description: Install the Clawkeeper Cowork PreToolUse guardrail. Drops a hook into every Cowork workspace on this machine that evaluates each tool call against a local policy before Claude Desktop runs it. Use when the user wants to apply Clawkeeper to Cowork (Claude Desktop), block file/tool access to PHI, secrets, or other restricted paths, or asks how to make Cowork safer.
---

# Install Clawkeeper Cowork Guardrail

You are installing the Clawkeeper PreToolUse hook for Cowork. Run the bundled installer, then summarize what happened and tell the user the exact next step.

## Step 1: Run the installer

Use Bash:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/cowork-install.sh"
```

If `CLAUDE_PLUGIN_ROOT` is not set in the environment, fall back to:

```bash
SCRIPT="$(find "$HOME/.claude" -maxdepth 8 -path '*/clawkeeper*/scripts/cowork-install.sh' -type f 2>/dev/null | head -1)"
[ -z "$SCRIPT" ] && SCRIPT="$(find "$HOME/Library/Application Support/Claude" -maxdepth 10 -path '*/clawkeeper*/scripts/cowork-install.sh' -type f 2>/dev/null | head -1)"
"$SCRIPT"
```

If the installer exits non-zero, show the user the error verbatim and stop. Do not retry.

## Step 2: Confirm and tell the user what to do next

After a successful install, display:

```
Clawkeeper Cowork guardrail installed.

Next step (required for the hook to take effect):
  1. Quit Claude Desktop completely (⌘Q).
  2. Relaunch Claude Desktop.
  3. Open a Cowork chat. Try a path covered by the default policy:
     "what files are in my ~/Documents/PHI folder?"
     The model should refuse with a Clawkeeper-attributed message.

Useful commands:
  /clawkeeper-code:cowork-status      → install state + recent events
  /clawkeeper-code:cowork-uninstall   → remove the hook

Policy file: ~/.clawkeeper/cowork/policy.json
Audit log:   ~/.clawkeeper/cowork/events.log
```

## Notes

- The installer is idempotent. Running it again preserves a customized `policy.json`. The default policy is always refreshed at `~/.clawkeeper/cowork/policy.default.json` for diffing.
- The default policy blocks PHI / HIPAA / PII / secrets paths, `.env` files, `.ssh` / `.gnupg` directories, and cloud credential files. Everything else is allowed.
- The hook fails OPEN by default (a misconfigured guardrail must not brick Cowork). Customers who need fail-closed behavior set `enforcement_mode: "strict"` in policy.json — note this is honored at v0.1 as a logged signal but not yet enforced; flag this to the user if asked.
