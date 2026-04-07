---
name: setup
description: Guided onboarding for Clawkeeper. Run when the user wants to configure Clawkeeper, check their current mode (local/connected/push-hooks), enable or disable blocking mode, or get started with the plugin.
---

# Clawkeeper Setup

You are running the Clawkeeper setup wizard. Determine the user's current mode and guide them accordingly.

## Step 1: Determine Current Mode

Check these in order:

### Check for push-hooks (security team deployment)
Read `.claude/settings.json` in the current project directory. Look for any hooks with URLs containing `clawkeeper.dev`. If found, the user is in **push-hooks mode** — their security team has already deployed Clawkeeper.

### Check for API key (connected mode)
Check if the file `${CLAUDE_PLUGIN_DATA:-$HOME/.clawkeeper-plugin}/api_key` exists and is non-empty. Use Bash:
```
cat "${CLAUDE_PLUGIN_DATA:-$HOME/.clawkeeper-plugin}/api_key" 2>/dev/null
```
If it contains a key, the user is in **connected mode**.

### Otherwise: local mode
If neither push-hooks nor an API key are found, the user is in **local-only mode**.

## Step 2: Show Status Based on Mode

### If push-hooks mode:
Display:
```
Clawkeeper Setup

Mode: Push-Hooks (managed by your security team)
Hooks: Active — configured in .claude/settings.json
Source: Your security team deployed these hooks to this repository.

You're already covered. Clawkeeper hooks are evaluating tool calls
via your organization's API. No additional setup needed.

Run /clawkeeper:status to see your shield status.
Run /clawkeeper:audit to check your Claude Code configuration.
```

### If connected mode:
Validate the key by running:
```bash
curl -s --max-time 5 "https://clawkeeper.dev/api/v1/claude-code/health" \
  -H "Authorization: Bearer $(cat "${CLAUDE_PLUGIN_DATA:-$HOME/.clawkeeper-plugin}/api_key")"
```

If the request succeeds, parse the JSON response and display the org name, plan, and workstation count. Format:
```
Clawkeeper Setup

Mode: Connected
Organization: [org_name from response]
Plan: [plan from response]
Workstations: [count from response]

Your hooks are API-powered. Threats are logged to your dashboard
at https://clawkeeper.dev/dashboard.

Run /clawkeeper:status for detailed shield status.
Run /clawkeeper:audit to check your Claude Code configuration.
```

If the request fails, note the key may be invalid and suggest running `/clawkeeper:connect` again.

### If local mode:
Display:
```
Clawkeeper Setup

Mode: Local (no account)
Hooks: Active — using bundled threat detection

What you get right now (no account needed):
  - Threat detection for dangerous commands (warn mode)
  - /clawkeeper:audit — grade your Claude Code security setup
  - /clawkeeper:secrets — scan for exposed secrets
  - /clawkeeper:inspect — audit installed plugins for threats
  - /clawkeeper:recap — session activity summary
  - /clawkeeper:scan — run a full host security scan

Want more? Connect your free account for:
  - Dashboard with full threat feed
  - Scan history and trend tracking
  - Setup audit tracking over time

Run /clawkeeper:connect to link your free account.
```

## Step 3: Blocking Mode Configuration

After showing the status, check the current blocking mode. Read the config file:
```bash
cat "${CLAUDE_PLUGIN_DATA:-$HOME/.clawkeeper-plugin}/config.json" 2>/dev/null
```

If the file exists, parse the `mode` field. If it doesn't exist, the default is `warn`.

Display the current mode and ask if they want to change it:
```
Current detection mode: [warn|block]
  - warn: Threats are flagged but execution continues (default)
  - block: Threats are blocked and execution is prevented

Would you like to switch to [the other mode]?
```

If the user wants to change modes, write the config file:
```bash
mkdir -p "${CLAUDE_PLUGIN_DATA:-$HOME/.clawkeeper-plugin}"
```
Then use Bash to write the JSON:
```bash
printf '{"mode":"%s","updated_at":"%s"}\n' "[warn|block]" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${CLAUDE_PLUGIN_DATA:-$HOME/.clawkeeper-plugin}/config.json"
```

Confirm the change:
```
Detection mode updated to [warn|block].
[If block]: Dangerous commands will now be blocked before execution.
[If warn]: Dangerous commands will generate warnings but still execute.
```

## Important Notes
- Never make network calls in local mode except to validate an existing key in connected mode
- Keep the output concise and actionable
- Always suggest next steps (relevant slash commands)
