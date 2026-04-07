# Clawkeeper — Security for Claude Code

Threat detection, compliance auditing, and secret scanning for Claude Code sessions. Works immediately on install — no account, no API key, no configuration.

## Install

```
/plugin install clawkeeper
```

Or from source during development:

```
claude --plugin-dir /path/to/clawkeeper/plugin
```

## What You Get (Free, No Account)

- **Real-time threat detection** — warns on credential exfiltration, reverse shells, prompt injection, and 24+ threat patterns before they execute
- **`/clawkeeper:audit`** — grades your Claude Code setup (sandbox mode, root execution, secret exposure, git signing, hook coverage, and more)
- **`/clawkeeper:inspect`** — audits installed plugins and skills for malicious hooks, prompt injection, and data exfiltration
- **`/clawkeeper:secrets`** — scans your project for exposed API keys, private keys, and hardcoded credentials
- **`/clawkeeper:recap`** — security summary of your session (tools called, files changed, threats caught)
- **`/clawkeeper:scan`** — runs a full host security scan

Everything runs locally. No network calls, no telemetry.

## Connect for More

Connect a free account to unlock your dashboard — one workstation, full threat feed, scan history.

```
/clawkeeper:connect
```

Teams use Clawkeeper Pro for fleet-wide visibility, custom policies, and compliance reporting. Learn more at [clawkeeper.dev/claude-code](https://clawkeeper.dev/claude-code).

## Slash Commands

| Command | Description |
|---|---|
| `/clawkeeper:setup` | Check status, configure warn/block mode |
| `/clawkeeper:connect` | Connect your Clawkeeper account |
| `/clawkeeper:audit` | Claude Code setup compliance audit |
| `/clawkeeper:inspect` | Audit installed plugins for threats |
| `/clawkeeper:secrets` | Scan for exposed secrets |
| `/clawkeeper:recap` | Session activity summary |
| `/clawkeeper:scan` | Run host security scanner |
| `/clawkeeper:status` | Shield status and stats |
| `/clawkeeper:policies` | View org security policies |

## How It Works

The plugin hooks into Claude Code at four points:

1. **UserPromptSubmit** — scans prompts for jailbreak and injection attempts
2. **PreToolUse** — detects dangerous commands, file writes, and web requests
3. **PostToolUse** — logs tool activity for session summaries
4. **SessionStart** — initializes session tracking

Default mode is **warn** — threats are flagged but not blocked. Enable blocking mode with `/clawkeeper:setup`.

When connected to a Clawkeeper account, hooks call the API for the full 24+ pattern engine, org policies, and fleet visibility. Without an account, a bundled detection engine runs locally with the most critical patterns.

## Privacy

In local-only mode (no account connected):
- Zero network calls
- Zero telemetry
- All detection runs on your machine
- Session data stays in `~/.clawkeeper-plugin/`

## Development

Run tests:

```bash
cd plugin && bash tests/run-all.sh
```

Test with Claude Code:

```bash
claude --plugin-dir ./plugin
```

## License

MIT — by [RAD Security](https://rad.security)
