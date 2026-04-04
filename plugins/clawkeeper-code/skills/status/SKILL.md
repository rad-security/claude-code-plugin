---
name: status
description: Show Clawkeeper shield status including connection mode, threat statistics, and workstation info. Run when the user wants to see if Clawkeeper is active, check their connection, or view threat stats.
allowed-tools: Bash,Read
---

# Clawkeeper Status

You are showing the current Clawkeeper shield status. Determine the mode and display the appropriate information.

## Step 1: Determine Mode

### Check for API key
```bash
cat "${CLAUDE_PLUGIN_DATA:-$HOME/.clawkeeper-plugin}/api_key" 2>/dev/null
```

If a key is found and non-empty, the user is in **connected mode**. Otherwise, **local mode**.

## Step 2: Display Status

### Local Mode

Read local stats:
```bash
cat "${CLAUDE_PLUGIN_DATA:-$HOME/.clawkeeper-plugin}/nudge_state.json" 2>/dev/null
```

If the nudge state file exists, parse `total_blocks`, `nudges_shown`, and any session counters. If it does not exist, use defaults (0 blocks, no sessions recorded).

Also read the config for detection mode:
```bash
cat "${CLAUDE_PLUGIN_DATA:-$HOME/.clawkeeper-plugin}/config.json" 2>/dev/null
```

Display:
```
Clawkeeper Shield Status

Mode: Local (no account connected)
Detection: [warn|block] mode
Shield: Active — using bundled threat patterns

Session Stats:
  Total threats detected: [total_blocks or 0]
  Sessions tracked: [count or "current session"]
  Nudges shown: [nudges_shown or 0]

Local mode includes:
  - 12 critical/high threat patterns
  - Credential exfiltration detection
  - Reverse shell detection
  - System file write protection

Connect a free account for:
  - Full 24+ pattern detection engine
  - Dashboard with threat feed and history
  - Scan result tracking
  - Setup audit trends

Run /clawkeeper:connect to link your free account.
```

### Connected Mode

Validate the key and fetch status from the API:
```bash
curl -s --max-time 5 "https://clawkeeper.dev/api/v1/claude-code/health" \
  -H "Authorization: Bearer $(cat "${CLAUDE_PLUGIN_DATA:-$HOME/.clawkeeper-plugin}/api_key")"
```

If the request succeeds, parse the JSON response and display:
```
Clawkeeper Shield Status

Mode: Connected
Organization: [org_name]
Plan: [plan]
Shield: Active — API-powered detection

Workstations: [online_count] online / [total_count] total
Recent Events: [event_count] in last 24h
Detection Mode: [from response or config.json]

Dashboard: https://clawkeeper.dev/dashboard

[If plan is "free"]:
Upgrade to Pro for fleet-wide visibility, custom policies,
and compliance reporting: https://clawkeeper.dev/pricing

Run /clawkeeper:audit to check your Claude Code configuration.
Run /clawkeeper:policies to view your organization's policies.
```

If the API request fails:
```
Clawkeeper Shield Status

Mode: Connected (API unreachable)
Detection: Falling back to local patterns

The Clawkeeper API did not respond. Hooks will use local detection
until connectivity is restored. Your API key is still stored.

Possible causes:
  - Network connectivity issue
  - API key may have been revoked
  - Service temporarily unavailable

Try again later, or run /clawkeeper:connect to re-authenticate.
```

Also read and display the local stats from `nudge_state.json` as supplementary info even in connected mode if available.

## Important Notes
- Only make network calls if an API key is present (connected mode)
- Never print the API key value in the output
- If nudge_state.json or config.json don't exist, use sensible defaults — don't show errors
- Keep the output concise and scannable
