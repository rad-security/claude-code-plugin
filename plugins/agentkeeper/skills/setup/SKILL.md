---
name: setup
description: Guided onboarding for AgentKeeper. Run when the user wants to configure AgentKeeper, check their current mode (local/connected/push-hooks), enable or disable blocking mode, or get started with the plugin.
---

# AgentKeeper Setup

You are running the AgentKeeper setup wizard. Determine the user's current mode and guide them accordingly.

## Step 0: Parse Arguments

Check the user's slash command invocation for flags:

- If the invocation includes `--local` (either `/agentkeeper:setup --local` or `--local` anywhere in the args): the user has explicitly opted into local-only mode. Set `OPTED_LOCAL=true` and remember this for Step 2.
- Otherwise: `OPTED_LOCAL=false`.

## Step 1: Determine Current Mode

Check these in order:

### Check for push-hooks (security team deployment)
Read `.claude/settings.json` in the current project directory. Look for any hooks with URLs containing `www.agentkeeper.dev`. If found, the user is in **push-hooks mode** — their security team has already deployed AgentKeeper.

### Check for user-level HTTP hooks (connected via plugin)
Run:
```bash
grep -q 'agentkeeper\.dev' "$HOME/.claude/settings.json" 2>/dev/null && echo "USER_HOOKS" || echo "NO_USER_HOOKS"
```

If `USER_HOOKS`, the user is in **user-level hooks mode**. This is the best state.

### Check for API key (connected mode)
Check if the API key file exists and is non-empty. Use Bash:
```bash
AGENTKEEPER_DIR="$HOME/.agentkeeper-plugin"
[ -n "$CLAUDE_PLUGIN_DATA" ] && AGENTKEEPER_DIR="$CLAUDE_PLUGIN_DATA"
cat "$AGENTKEEPER_DIR/api_key" 2>/dev/null
```
If it contains a key, the user is in **connected mode**.

### Otherwise: disconnected OR local mode
If none of the above matched, branch on the `OPTED_LOCAL` flag from Step 0:

- `OPTED_LOCAL=true` → the user is in **local-only mode** (explicit opt-in). Proceed to the Local Mode display in Step 2.
- `OPTED_LOCAL=false` → the user is in **disconnected mode** — hooks are not active and there is no account linked. Do NOT treat this as a success state. Proceed to the Disconnected Mode display in Step 2 and stop before Step 3.

## Step 2: Show Status Based on Mode

### If push-hooks mode:
Display:
```
AgentKeeper Setup

Mode: Push-Hooks (managed by your security team)
Hooks: Active — configured in .claude/settings.json
Source: Your security team deployed these hooks to this repository.

You're already covered. AgentKeeper hooks are evaluating tool calls
via your organization's API. No additional setup needed.

Run /agentkeeper:status to see your shield status.
Run /agentkeeper:audit to check your Claude Code configuration.
```

### If user-level hooks mode:
Validate the key by running:
```bash
AGENTKEEPER_DIR="$HOME/.agentkeeper-plugin"
[ -n "$CLAUDE_PLUGIN_DATA" ] && AGENTKEEPER_DIR="$CLAUDE_PLUGIN_DATA"
API_KEY=$(cat "$AGENTKEEPER_DIR/api_key")
curl -s --max-time 5 "https://www.agentkeeper.dev/api/v1/claude-code/health" \
  -H "Authorization: Bearer $API_KEY"
```

If the request succeeds, display:
```
AgentKeeper Setup

Mode: Connected (user-level hooks)
Hooks: Active — installed in ~/.claude/settings.json
Source: Installed via /agentkeeper:connect
Coverage: Prompts, tool calls, and sessions

Organization: [org_name from response]
Plan: [plan from response]

Dashboard: https://www.agentkeeper.dev/dashboard

Run /agentkeeper:status for detailed shield stats.
Run /agentkeeper:audit to check your Claude Code setup.
Run /agentkeeper:disconnect to remove hooks and unlink.
```

### If connected mode:
Validate the key by running:
```bash
AGENTKEEPER_DIR="$HOME/.agentkeeper-plugin"
[ -n "$CLAUDE_PLUGIN_DATA" ] && AGENTKEEPER_DIR="$CLAUDE_PLUGIN_DATA"
API_KEY=$(cat "$AGENTKEEPER_DIR/api_key")
curl -s --max-time 5 "https://www.agentkeeper.dev/api/v1/claude-code/health" \
  -H "Authorization: Bearer $API_KEY"
```

If the request succeeds, parse the JSON response and display the org name, plan, and workstation count. Format:
```
AgentKeeper Setup

Mode: Connected
Organization: [org_name from response]
Plan: [plan from response]
Workstations: [count from response]

Your hooks are API-powered. Threats are logged to your dashboard
at https://www.agentkeeper.dev/dashboard.

Run /agentkeeper:status for detailed shield status.
Run /agentkeeper:audit to check your Claude Code configuration.
```

If the request fails, note the key may be invalid and suggest running `/agentkeeper:connect` again.

### If disconnected mode (default when no hooks and no API key, and --local was NOT passed):
Display exactly this block and then **stop**. Do not continue to Step 3. Do not list the six sub-commands — listing them implies "you're done", which is the bug this gate is closing.

```
AgentKeeper Setup

Status: Not connected

No hooks are active and no account is linked, so nothing is being
monitored yet. Setup is not complete.

  Connect now:   /agentkeeper:connect
  Local only:    /agentkeeper:setup --local   (bundled detection, no dashboard)

Without connecting, threats won't surface in your dashboard at
https://www.agentkeeper.dev/dashboard and the plugin won't contribute to
fleet visibility. Local-only is a valid choice, but it's a deliberate
opt-in, not the default.
```

### If local mode (the user explicitly passed --local):
Display:
```
AgentKeeper Setup

Mode: Local-only (opted in via --local)
Hooks: Bundled threat detection, no network calls
Account: Not linked

What's active:
  - Threat detection for dangerous commands (warn mode)
  - /agentkeeper:audit — grade your Claude Code security setup
  - /agentkeeper:secrets — scan for exposed secrets
  - /agentkeeper:inspect — audit installed plugins for threats
  - /agentkeeper:recap — session activity summary
  - /agentkeeper:scan — run a full host security scan

You're running without a dashboard. If you change your mind later,
run /agentkeeper:connect to link a free account — no reinstall
needed.
```

## Step 3: Blocking Mode Configuration

**Skip this step entirely if the user is in disconnected mode** (Step 1's "disconnected OR local" branch with `OPTED_LOCAL=false`). There is no plugin activity to configure, and nudging warn-vs-block would imply the user is set up when they are not.

After showing the status (for push-hooks, user-level-hooks, connected, or `--local` opted-in modes), check the current blocking mode. Read the config file:
```bash
AGENTKEEPER_DIR="$HOME/.agentkeeper-plugin"
[ -n "$CLAUDE_PLUGIN_DATA" ] && AGENTKEEPER_DIR="$CLAUDE_PLUGIN_DATA"
cat "$AGENTKEEPER_DIR/config.json" 2>/dev/null
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
AGENTKEEPER_DIR="$HOME/.agentkeeper-plugin"
[ -n "$CLAUDE_PLUGIN_DATA" ] && AGENTKEEPER_DIR="$CLAUDE_PLUGIN_DATA"
mkdir -p "$AGENTKEEPER_DIR"
```
Then use Bash to write the JSON:
```bash
AGENTKEEPER_DIR="$HOME/.agentkeeper-plugin"
[ -n "$CLAUDE_PLUGIN_DATA" ] && AGENTKEEPER_DIR="$CLAUDE_PLUGIN_DATA"
printf '{"mode":"%s","updated_at":"%s"}\n' "[warn|block]" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$AGENTKEEPER_DIR/config.json"
```

Confirm the change:
```
Detection mode updated to [warn|block].
[If block]: Dangerous commands will now be blocked before execution.
[If warn]: Dangerous commands will generate warnings but still execute.
```

## Important Notes
- Never make network calls in local mode or disconnected mode. The only network call this skill makes is to validate an existing API key in connected / user-level-hooks mode.
- Disconnected mode is NOT a success state. Never list sub-commands or walk the user through warn/block config when they are disconnected — doing so implied completeness in the old version of this skill and caused users to assume they were set up when they weren't.
- `--local` is an explicit opt-in. Do not infer it from context. If the user has neither connected nor passed `--local`, they are disconnected.
- Keep the output concise and actionable.
- Always suggest next steps (relevant slash commands) when in an active mode.
