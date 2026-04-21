---
name: policies
description: View organization security policies for Clawkeeper. Shows detection mode, blocked tools, blocked commands, path restrictions, and custom blocklists. Run when the user wants to see what policies are enforced, check security settings, or view org configuration.
---

# Clawkeeper Policies

You are displaying the organization's Clawkeeper security policies.

## Step 1: Check Connection Mode

```bash
CK_DIR="$HOME/.clawkeeper-plugin"
[ -n "$CLAUDE_PLUGIN_DATA" ] && CK_DIR="$CLAUDE_PLUGIN_DATA"
cat "$CK_DIR/api_key" 2>/dev/null
```

### If no API key (local mode):

Display:
```
Clawkeeper Policies

Mode: Local (no account connected)

Running with default detection patterns. In local mode, Clawkeeper uses
a bundled set of 12 critical/high threat patterns:

  - credential_exfil — SSH keys, AWS creds, env files sent to network
  - reverse_shell — bash/python/nc reverse shell patterns
  - recursive_delete_root — rm -rf / and system directory wipes
  - dns_exfil — data exfiltration via DNS
  - system_file_write — writing to /etc, /usr, /System
  - ssh_config_write — modifying authorized_keys, SSH config
  - cryptominer — cryptocurrency mining patterns
  - startup_injection — modifying .bashrc, .zshrc, LaunchAgents
  - cicd_tampering — modifying GitHub Actions, GitLab CI
  - suid_manipulation — setting SUID bits
  - prompt_injection — common injection patterns in prompts
  - token_theft — stealing auth tokens and session data

Default behavior: warn (detect and flag, but allow execution)

To view and manage organization policies, connect an account:
  /clawkeeper:connect

Pro plan adds:
  - Custom blocked tool lists
  - Custom blocked command patterns
  - Path restriction policies
  - Custom blocklists (words, domains, patterns)
  - Policy enforcement across all team workstations
```

Stop here if local mode.

### If API key exists (connected mode):

Proceed to Step 2.

## Step 2: Fetch Policies

### Fetch shield policy
```bash
CK_DIR="$HOME/.clawkeeper-plugin"
[ -n "$CLAUDE_PLUGIN_DATA" ] && CK_DIR="$CLAUDE_PLUGIN_DATA"
API_KEY=$(cat "$CK_DIR/api_key")
curl -s --max-time 5 "https://clawkeeper.dev/api/v1/claude-code/policies" \
  -H "Authorization: Bearer $API_KEY"
```

If the endpoint returns an error or is not found, try the shield policies endpoint:
```bash
CK_DIR="$HOME/.clawkeeper-plugin"
[ -n "$CLAUDE_PLUGIN_DATA" ] && CK_DIR="$CLAUDE_PLUGIN_DATA"
API_KEY=$(cat "$CK_DIR/api_key")
curl -s --max-time 5 "https://clawkeeper.dev/api/v1/shield/policies" \
  -H "Authorization: Bearer $API_KEY"
```

### Fetch Claude Code specific policies
```bash
CK_DIR="$HOME/.clawkeeper-plugin"
[ -n "$CLAUDE_PLUGIN_DATA" ] && CK_DIR="$CLAUDE_PLUGIN_DATA"
API_KEY=$(cat "$CK_DIR/api_key")
curl -s --max-time 5 "https://clawkeeper.dev/api/v1/claude-code/config" \
  -H "Authorization: Bearer $API_KEY"
```

## Step 3: Display Policies

Parse the JSON responses and display:

```
Clawkeeper Policies

Organization: [org_name]
Plan: [plan]

Shield Policy:
  Security Level: [strict|moderate|permissive]
  Auto-Block: [enabled|disabled]
  Detection Mode: [warn|block]

[If blocked tools are configured]:
Blocked Tools:
  - [tool_name] — [reason if available]
  ...

[If blocked commands are configured]:
Blocked Command Patterns:
  - [pattern] — [description]
  ...

[If path restrictions are configured]:
Path Restrictions:
  Allowed: [list of allowed paths]
  Denied: [list of denied paths]

[If custom blocklist exists]:
Custom Blocklist:
  Words: [count] entries
  Domains: [count] entries
  Patterns: [count] entries

Detection Patterns: [count] active patterns
  Includes default patterns plus [count] custom patterns

[If plan is "free"]:
---
Upgrade to Pro to configure custom policies:
https://clawkeeper.dev/pricing

[If plan is "pro" or "enterprise"]:
---
Manage policies at: https://clawkeeper.dev/dashboard/policies
```

### If the API request fails:

```
Clawkeeper Policies

Unable to fetch policies. The API did not respond.

Possible causes:
  - Network connectivity issue
  - API key may be invalid or revoked
  - Service temporarily unavailable

Falling back to local detection patterns (12 bundled patterns).
Run /clawkeeper:connect to re-authenticate.
```

## Important Notes
- Only make network calls if an API key is present
- Never print the API key in output
- If policy fields are missing from the response, skip those sections rather than showing empty
- Keep the output scannable — use consistent formatting
- If the user is on the free plan, mention what Pro adds without being pushy
