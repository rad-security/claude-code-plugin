# clawkeeper-cowork — Data Governance for Cowork

Data classification, PII detection, and compliance auditing for Cowork. Provides MCP tools that Claude calls before accessing files, processing sensitive data, or sharing externally. Works immediately — no account required.

## What You Get

Four MCP security tools that Claude calls automatically:

| Tool | When Claude Calls It | What It Does |
|---|---|---|
| `clawkeeper_check_sensitivity` | Before reading/writing any file | Classifies sensitivity, detects PII, evaluates org policy |
| `clawkeeper_classify_data` | Before processing data with PII | Detects SSNs, credit cards, emails, phone numbers, API keys |
| `clawkeeper_verify_recipient` | Before sending externally | Checks recipient against allowed domains |
| `clawkeeper_log_action` | At each major task step | Structured audit trail entry |

Plus skills:
- **`/clawkeeper-cowork:audit`** — file sensitivity scan + PII detection across your working directory
- **`/clawkeeper-cowork:connect`** — link to your Clawkeeper dashboard

## Install

```
/plugin marketplace add rad-security/claude-code-plugin
/plugin install clawkeeper-cowork@clawkeeper
```

## How It Works

The plugin bundles a local MCP server and a security advisor agent. The agent's system instructions tell Claude to call the security tools before file access, data processing, and external communication.

Each tool call is logged locally. When connected to a Clawkeeper account, events also appear in your dashboard.

## PII Detection

Detects 17+ patterns including:
- Social Security Numbers, credit cards, tax IDs
- Email addresses, phone numbers, dates of birth
- AWS keys, Stripe keys, GitHub tokens
- Private key markers, database credentials

## Connect

Connect a free account for your compliance dashboard:

```
/clawkeeper-cowork:connect
```

Teams use [Clawkeeper](https://clawkeeper.dev) for fleet-wide audit trails, custom data classification policies, and compliance reporting.

## Organization Deployment

Admins can deploy via Claude Desktop:
1. Organization settings → Plugins → Connect GitHub repo `rad-security/claude-code-plugin`
2. Set `clawkeeper-cowork` to "Required"
3. All org members get the plugin automatically on next session
