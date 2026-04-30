# AgentKeeper Claude Code Plugin

AgentKeeper provides security scanning, threat detection, and compliance auditing for Claude Code. Built by [RAD Security](https://rad.security).

## Install

```
/plugin marketplace add rad-security/claude-code-plugin
/plugin install agentkeeper
/reload-plugins
```

## Plugin

[agentkeeper](./plugins/agentkeeper) adds real-time threat detection for Claude Code sessions. It warns on credential exfiltration, reverse shells, prompt injection, and 24+ patterns. It also includes setup auditing, secret scanning, and plugin supply chain inspection.

AgentKeeper works immediately on install with no account, API key, or setup required. Connect an account at [agentkeeper.dev](https://www.agentkeeper.dev) for dashboard visibility, policy sync, and fleet inventory.

## Organization Deployment

Admins can deploy to their entire org via Claude Desktop:

1. Organization settings → Plugins → Connect this GitHub repo
2. Set AgentKeeper to "Required" for automatic deployment
3. Manage policies centrally at [agentkeeper.dev](https://www.agentkeeper.dev)

## License

MIT
