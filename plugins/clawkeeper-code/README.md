# clawkeeper-code — Security for Claude Code

Real-time threat detection, setup auditing, and secret scanning for Claude Code sessions. Works immediately on install — no account, no API key, no configuration.

## What You Get

- **Threat detection** — warns on credential exfiltration, reverse shells, prompt injection, DNS exfiltration, SUID manipulation, and 24+ patterns before they execute
- **`/clawkeeper-code:audit`** — grades your Claude Code setup (sandbox mode, root execution, secret exposure, git signing, hook coverage, permission mode, and more)
- **`/clawkeeper-code:inspect`** — audits installed plugins and skills for malicious hooks, prompt injection, and data exfiltration
- **`/clawkeeper-code:secrets`** — scans your project for exposed API keys, private keys, and hardcoded credentials
- **`/clawkeeper-code:recap`** — session activity summary from hook data
- **`/clawkeeper-code:scan`** — runs a full host security scan

Everything runs locally. No network calls, no telemetry.

## Install

```
/plugin marketplace add rad-security/claude-code-plugin
/plugin install clawkeeper-code@clawkeeper
```

## How It Works

Hooks into Claude Code at four points:

1. **UserPromptSubmit** — scans prompts for jailbreak and injection attempts
2. **PreToolUse** — detects dangerous commands, file writes, and web requests
3. **PostToolUse** — logs tool activity for session summaries
4. **SessionStart** — initializes session tracking

Default mode is **warn** — threats are flagged but not blocked. Enable blocking with `/clawkeeper-code:setup`.

## Connect

Connect a free account for your dashboard, threat feed, and scan history:

```
/clawkeeper-code:connect
```

Teams use [Clawkeeper Pro](https://clawkeeper.dev/claude-code) for fleet-wide visibility, custom policies, and compliance reporting.

## All Commands

| Command | Description |
|---|---|
| `/clawkeeper-code:setup` | Check status, configure warn/block mode |
| `/clawkeeper-code:connect` | Connect your Clawkeeper account |
| `/clawkeeper-code:audit` | Claude Code setup compliance audit |
| `/clawkeeper-code:inspect` | Audit installed plugins for threats |
| `/clawkeeper-code:secrets` | Scan for exposed secrets |
| `/clawkeeper-code:recap` | Session activity summary |
| `/clawkeeper-code:scan` | Run host security scanner |
| `/clawkeeper-code:status` | Shield status and stats |
| `/clawkeeper-code:policies` | View org security policies |
