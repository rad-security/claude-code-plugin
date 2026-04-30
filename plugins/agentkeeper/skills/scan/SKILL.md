---
name: scan
description: Run the AgentKeeper security scanner on the current host. Checks for macOS/Linux security misconfigurations, network settings, and prerequisites. Run when the user wants a full host security scan.
---

# AgentKeeper Host Security Scan

You are running the AgentKeeper CLI security scanner on the user's machine.

## Step 1: Check if AgentKeeper CLI is Installed

```bash
which agentkeeper 2>/dev/null || command -v agentkeeper 2>/dev/null
```

### If installed:

Proceed to Step 2.

### If not installed:

Display:
```
AgentKeeper CLI not found.

The AgentKeeper CLI runs 39 security checks across your host configuration,
network settings, and development environment.

Would you like to install it? It takes about 10 seconds:

    curl -fsSL https://www.agentkeeper.dev/install.sh | bash

This installs the `agentkeeper` command to /usr/local/bin.
```

Ask the user if they want to install. If yes, run:
```bash
curl -fsSL https://www.agentkeeper.dev/install.sh | bash
```

If the install fails, show the error output and suggest:
```
Installation failed. You can also:
  - Download manually: https://www.agentkeeper.dev/install.sh
  - Or run directly without installing:
    curl -fsSL https://www.agentkeeper.dev/install.sh | bash -s -- --run-only
```

After successful install, proceed to Step 2.

If the user declines installation, display:
```
No problem. You can still use these local checks:
  /agentkeeper:audit — audit your Claude Code configuration
  /agentkeeper:secrets — scan for exposed secrets
```
Stop here.

## Step 2: Run the Scanner

Run the AgentKeeper scanner:
```bash
agentkeeper scan 2>&1
```

If the command takes too long (>30 seconds), it may be running interactive prompts. Use:
```bash
agentkeeper scan --non-interactive 2>&1
```

If the scan command is not recognized, try the alternative:
```bash
agentkeeper agent run 2>&1
```

## Step 3: Display Results

The scanner outputs a JSON report or formatted text. Display the results inline.

If the output is JSON, parse it and format it as a readable report:
```
AgentKeeper Host Security Scan

Grade: [letter_grade]
Score: [score]/[total]

Phase 1: macOS Host Security
  [PASS|FAIL|SKIP]  [check_name] — [detail]
  ...

Phase 2: Network Configuration
  [PASS|FAIL|SKIP]  [check_name] — [detail]
  ...

Phase 3: Prerequisites
  [PASS|FAIL|SKIP]  [check_name] — [detail]
  ...

Phase 4: Security Audit
  [PASS|FAIL|SKIP]  [check_name] — [detail]
  ...

[summary line with pass/fail/skip counts]
```

If the output is already formatted text, display it as-is.

## Step 4: Upload Results (Connected Mode)

Check if an API key exists:
```bash
AGENTKEEPER_DIR="$HOME/.agentkeeper-plugin"
[ -n "$CLAUDE_PLUGIN_DATA" ] && AGENTKEEPER_DIR="$CLAUDE_PLUGIN_DATA"
cat "$AGENTKEEPER_DIR/api_key" 2>/dev/null
```

If connected, mention that results are uploaded to the dashboard:
```
Scan results are synced to your dashboard: https://www.agentkeeper.dev/dashboard
```

If local mode:
```
Connect your free account to track scan results over time: /agentkeeper:connect
```

## Important Notes
- The scanner requires Bash and common system utilities (it's a shell script)
- On Linux, some checks require different flags than macOS — the scanner handles this
- Never run the scanner with sudo/root unless the user explicitly requests it
- If the scan produces errors about missing tools, report them but don't fail the whole skill
- The scan output can be long — present it clearly but don't truncate the findings
