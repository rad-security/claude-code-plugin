---
name: status
description: Show AgentKeeper shield status including connection mode, threat statistics, and workstation info. Run when the user wants to see if AgentKeeper is active, check their connection, or view threat stats.
---

# AgentKeeper Status

You are showing the current AgentKeeper shield status. Determine the mode and display the appropriate information.

## Step 1: Determine Mode

### Check for API key
```bash
AGENTKEEPER_DIR="$HOME/.agentkeeper-plugin"
[ -n "$CLAUDE_PLUGIN_DATA" ] && AGENTKEEPER_DIR="$CLAUDE_PLUGIN_DATA"
cat "$AGENTKEEPER_DIR/api_key" 2>/dev/null
```

If a key is found and non-empty, the user is in **connected mode**. Otherwise, **local mode**.

### Determine hook delivery method
Run:
```bash
HOOK_SOURCE="plugin"
if grep -q 'agentkeeper\.dev' "$HOME/.claude/settings.json" 2>/dev/null; then
  HOOK_SOURCE="user_http"
fi
for f in ".claude/settings.json" ".claude/settings.local.json"; do
  if [ -f "$f" ] && grep -q 'agentkeeper\.dev' "$f" 2>/dev/null; then
    HOOK_SOURCE="repo_http"
    break
  fi
done
echo "HOOK_SOURCE:$HOOK_SOURCE"
```

Capture the value after `HOOK_SOURCE:` for use in the status output.

## Step 2: Display Status

### Local Mode

Read local stats:
```bash
AGENTKEEPER_DIR="$HOME/.agentkeeper-plugin"
[ -n "$CLAUDE_PLUGIN_DATA" ] && AGENTKEEPER_DIR="$CLAUDE_PLUGIN_DATA"
cat "$AGENTKEEPER_DIR/nudge_state.json" 2>/dev/null
```

If the nudge state file exists, parse `total_blocks`, `nudges_shown`, and any session counters. If it does not exist, use defaults (0 blocks, no sessions recorded).

Also read the config for detection mode:
```bash
AGENTKEEPER_DIR="$HOME/.agentkeeper-plugin"
[ -n "$CLAUDE_PLUGIN_DATA" ] && AGENTKEEPER_DIR="$CLAUDE_PLUGIN_DATA"
cat "$AGENTKEEPER_DIR/config.json" 2>/dev/null
```

Display:
```
AgentKeeper Shield Status

Mode: Local (no account connected)
Detection: [warn|block] mode
Shield: Active — using bundled threat patterns
Hooks: [if user_http: "User-level HTTP hooks (full coverage)" | if repo_http: "Repo-level HTTP hooks (full coverage)" | if plugin: "Plugin hooks only (limited — run /agentkeeper:connect to upgrade)"]

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

Run /agentkeeper:connect to link your free account.
```

### Connected Mode

Validate the key and fetch status from the API:
```bash
AGENTKEEPER_DIR="$HOME/.agentkeeper-plugin"
[ -n "$CLAUDE_PLUGIN_DATA" ] && AGENTKEEPER_DIR="$CLAUDE_PLUGIN_DATA"
API_KEY=$(cat "$AGENTKEEPER_DIR/api_key")
curl -s --max-time 5 "https://www.agentkeeper.dev/api/v1/claude-code/health" \
  -H "Authorization: Bearer $API_KEY"
```

If the request succeeds, parse the JSON response and display:
```
AgentKeeper Shield Status

Mode: Connected
Organization: [org_name]
Plan: [plan]
Shield: Active — API-powered detection
Hooks: [if user_http: "User-level HTTP hooks (full coverage)" | if repo_http: "Repo-level HTTP hooks (full coverage)" | if plugin: "Plugin hooks only (limited — run /agentkeeper:connect to upgrade)"]

Workstations: [online_count] online / [total_count] total
Recent Events: [event_count] in last 24h
Detection Mode: [from response or config.json]

Dashboard: https://www.agentkeeper.dev/dashboard

[If plan is "free"]:
Upgrade to Pro for fleet-wide visibility, custom policies,
and compliance reporting: https://www.agentkeeper.dev/pricing

Run /agentkeeper:audit to check your Claude Code configuration.
Run /agentkeeper:policies to view your organization's policies.
```

If the API request fails:
```
AgentKeeper Shield Status

Mode: Connected (API unreachable)
Detection: Falling back to local patterns

The AgentKeeper API did not respond. Hooks will use local detection
until connectivity is restored. Your API key is still stored.

Possible causes:
  - Network connectivity issue
  - API key may have been revoked
  - Service temporarily unavailable

Try again later, or run /agentkeeper:connect to re-authenticate.
```

Also read and display the local stats from `nudge_state.json` as supplementary info even in connected mode if available.

## Important Notes
- Only make network calls if an API key is present (connected mode)
- Never print the API key value in the output
- If nudge_state.json or config.json don't exist, use sensible defaults — don't show errors
- Keep the output concise and scannable
