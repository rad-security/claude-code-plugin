# AgentKeeper Claude Code Plugin

AgentKeeper provides real-time security scanning, threat detection, and compliance auditing for Claude Code. It works immediately on install — **no account, API key, or configuration required**. Built by [RAD Security](https://rad.security).

## Install

```
/plugin marketplace add rad-security/claude-code-plugin
/plugin install agentkeeper
/reload-plugins
```

To update later (third-party marketplaces do not auto-update):

```
/plugin marketplace update agentkeeper
```

## What it does

[agentkeeper](./plugins/agentkeeper) hooks into Claude Code at four points — `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, and `SessionStart` — to flag threats before they execute:

- **Real-time threat detection** — credential exfiltration, reverse shells, prompt injection, and 24+ patterns.
- **`/agentkeeper:audit`** — grades your Claude Code setup for misconfigurations.
- **`/agentkeeper:inspect`** — audits installed plugins and skills for malicious behavior.
- **`/agentkeeper:secrets`** — scans your project for exposed keys and credentials.
- **`/agentkeeper:recap`** / **`/agentkeeper:scan`** — session summary and full host security scan.

Default mode is **warn** — threats are flagged, not blocked. Switch to blocking with `/agentkeeper:setup`.

## Security & Privacy

This plugin installs PreToolUse hooks that run local shell scripts. We treat transparency about what they do as a first-class concern:

- **Local-first, fail-open.** In local-only mode (no account connected) the plugin makes **zero network calls and sends zero telemetry** — all detection runs on your machine using a bundled engine. Every hook fails *open*: any error in a hook allows the tool call to proceed, so AgentKeeper can never block your work by failing.
- **What runs.** Hooks inspect the prompt and tool input (command text, file paths, URLs) in-process to match threat patterns. Session data stays in `~/.agentkeeper-plugin/`.
- **What is sent, and where — only when connected.** Running `/agentkeeper:connect` links a free account. From then on, hooks call the AgentKeeper API (`agentkeeper.dev`) to use the full pattern engine, org policies, and fleet visibility. Decision metadata for matched tool calls is sent to your dashboard; it is never shared with third parties.
- **Credential handling.** Connecting provisions a per-device key stored locally under your home directory (`~/.agentkeeper/` / `~/.agentkeeper-plugin/`); it is the only credential the plugin holds and is used solely to authenticate to your own dashboard. Disconnect and remove all hooks/keys any time with `/agentkeeper:disconnect`.
- **No secret values leave your machine.** The secret scanner reports *locations and types* of exposed credentials — it never transmits or prints the secret values themselves.
- **License.** MIT — source is fully auditable in this repo.

## Organization Deployment

Admins can deploy to an entire org via Claude Desktop:

1. Organization settings → Plugins → Connect this GitHub repo
2. Set AgentKeeper to "Required" for automatic deployment
3. Manage policies centrally at [agentkeeper.dev](https://www.agentkeeper.dev)

## License

MIT — by [RAD Security](https://rad.security)
