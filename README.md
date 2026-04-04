# Clawkeeper — Security for the Claude Ecosystem

Clawkeeper provides security scanning, threat detection, and compliance auditing for Claude Code and Cowork. Built by [RAD Security](https://rad.security).

## Plugins

### [clawkeeper-code](./plugins/clawkeeper-code) — Claude Code Security

Real-time threat detection for Claude Code sessions. Warns on credential exfiltration, reverse shells, prompt injection, and 24+ patterns. Includes setup auditing, secret scanning, and plugin supply chain inspection.

**Install:**
```
/plugin marketplace add rad-security/claude-code-plugin
/plugin install clawkeeper-code@clawkeeper
```

### [clawkeeper-cowork](./plugins/clawkeeper-cowork) — Cowork Data Governance

Data classification, PII detection, and compliance auditing for Cowork. Checks file sensitivity before access, classifies data, verifies external recipients, and maintains a structured audit trail.

**Install:**
```
/plugin marketplace add rad-security/claude-code-plugin
/plugin install clawkeeper-cowork@clawkeeper
```

## Zero Configuration

Both plugins work immediately on install — no account, no API key, no setup. Connect a free account at [clawkeeper.dev](https://clawkeeper.dev) for your dashboard, threat feed, and fleet visibility.

## Organization Deployment

Admins can deploy to their entire org via Claude Desktop:

1. Organization settings → Plugins → Connect this GitHub repo
2. Set plugins to "Required" for automatic deployment
3. Policies managed centrally at [clawkeeper.dev](https://clawkeeper.dev)

## License

MIT
