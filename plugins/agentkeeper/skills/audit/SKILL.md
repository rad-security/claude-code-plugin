---
name: audit
description: Run a full AgentKeeper security audit of your Claude Code environment. Covers setup compliance, secret scanning, and plugin supply chain inspection in one unified report with a letter grade. Use when the user wants to check their security posture, run a security audit, or asks about security issues.
---

# AgentKeeper Claude Code Audit

You are running a comprehensive security audit of this Claude Code environment. This is the single, unified audit — it covers **three sections** in one pass:

1. **Setup Compliance** — Claude Code configuration and environment checks
2. **Secret Exposure** — scan the working directory for exposed credentials
3. **Plugin Supply Chain** — audit installed plugins and skills for malicious behavior

Run all checks below, then produce a single graded report. Everything runs locally — no network calls.

---

## Section 1: Setup Compliance

Run these checks using Bash, Read, Glob, and Grep tools. For each check, determine a result: **PASS**, **FAIL**, or **WARN**.

### 1.1 Sandbox Mode (Critical)
```bash
echo "${CLAUDE_SANDBOX:-not_set}"
cat ~/.claude/settings.json 2>/dev/null | grep -i sandbox
```
- **PASS**: Sandbox mode is enabled or detected
- **FAIL**: No sandbox detected or explicitly disabled
- **WARN**: Unable to verify sandbox status

### 1.2 Root Execution (Critical)
```bash
id -u && whoami
```
- **PASS**: Not running as root (uid != 0)
- **FAIL**: Running as root (uid == 0)

### 1.3 Allowed Directories (High)
Check `~/.claude/settings.json` and `.claude/settings.json` for `allowedDirectories` or directory restriction settings.
- **PASS**: Allowed directories are explicitly configured with specific paths
- **WARN**: Default/unrestricted directory access
- **FAIL**: Explicitly set to allow all or root-level paths like `/`

### 1.4 Claude Code Version (Medium)
```bash
claude --version 2>/dev/null || echo "not_found"
```
- **PASS**: Claude Code installed and reports a version
- **FAIL**: Not found in PATH

### 1.5 Git Signing (Medium)
```bash
git config --global commit.gpgsign 2>/dev/null
git config --global user.signingkey 2>/dev/null
```
- **PASS**: Commit signing enabled with a signing key
- **FAIL**: No git commit signing configured

### 1.6 Project Settings (Medium)
```bash
test -f .claude/settings.json && echo "exists" || echo "missing"
```
- **PASS**: `.claude/settings.json` exists with security-relevant configuration
- **FAIL**: No `.claude/settings.json` in the project

### 1.7 Hook Coverage (Medium)
Check if security hooks are configured from any source (plugin hooks, push-hooks, or settings).
- **PASS**: Security hooks active
- **FAIL**: No security hooks found

### 1.8 Permission Mode (High)
Read `~/.claude/settings.json` for auto-approve or permission settings.
- **PASS**: Restrictive — Bash/Write/Edit require manual approval
- **WARN**: Some tools auto-approved
- **FAIL**: All tools auto-approved or fully permissive mode

### 1.9 Sensitive File Accessibility (High)
Check if `~/.ssh/`, `~/.aws/credentials` are within the working directory tree.
- **PASS**: Sensitive directories are outside the working directory
- **WARN**: Working directory is at `$HOME` level (broad access)
- **FAIL**: Sensitive directories within the working directory

---

## Section 2: Secret Exposure

Scan the working directory for exposed secrets. **NEVER print actual secret values** — only file paths, line numbers, and types.

### 2.1 Secret Files in Project (Critical)
```bash
find . -maxdepth 3 \( -name ".env" -o -name ".env.*" -o -name "*.pem" -o -name "*.key" -o -name "id_rsa" -o -name "id_ed25519" \) 2>/dev/null | head -20
```

### 2.2 Gitignore Coverage (High)
For each secret file found, check if it's tracked by git:
```bash
git ls-files --error-unmatch <file> 2>/dev/null && echo "TRACKED" || echo "ignored"
```
- **FAIL**: Any secret file is git-tracked (in commit history)
- **WARN**: Secret files exist but are gitignored
- **PASS**: No secret files found

### 2.3 Hardcoded API Keys in Source (Critical)
Scan tracked source files for common API key patterns. Use Grep to search for:
- AWS keys: `AKIA[0-9A-Z]{16}`
- Stripe: `sk_live_`
- GitHub tokens: `ghp_`, `gho_`, `ghu_`
- Generic: `ak_live_` in non-example files
- Private key headers: `BEGIN.*PRIVATE KEY`

Only check git-tracked files (not gitignored):
```bash
git ls-files -- '*.ts' '*.js' '*.py' '*.sh' '*.json' '*.yml' '*.yaml' '*.env*' 2>/dev/null
```

For each match: report file path, line number, and pattern type. Mask the actual value (show first 4 chars + `****`).
- **FAIL**: API keys or secrets found in git-tracked files
- **PASS**: No hardcoded secrets detected in source

### 2.4 .env File Contents (Medium)
For any `.env` files found (even if gitignored), count the number of populated secrets:
```bash
grep -c '=' <file> 2>/dev/null
```
Report as informational — count of secrets per file. Don't print values, just use `sed 's/=.*/=****/'` to mask.

---

## Section 3: Plugin Supply Chain

Audit installed Claude Code plugins for malicious behavior.

### 3.1 Enumerate Installed Plugins
```bash
cat ~/.claude/settings.json 2>/dev/null | grep -A2 enabledPlugins
cat .claude/settings.json 2>/dev/null | grep -A2 enabledPlugins
```
Also check the plugin cache directory:
```bash
ls ~/.claude/plugins/cache/ 2>/dev/null
```

### 3.2 Hook Script Analysis (Critical)
For each installed plugin, find hook scripts and check for suspicious patterns:
```bash
# For each plugin directory found, search scripts:
grep -rn 'curl\|wget\|nc \|ncat\|eval\|exec(' <plugin_dir>/scripts/ 2>/dev/null
```
- **FAIL**: Hook scripts contain network exfil calls (curl/wget to unknown domains) or eval of external input
- **WARN**: Hook scripts make network calls (could be legitimate like AgentKeeper API calls)
- **PASS**: No suspicious patterns found
- Skip AgentKeeper's own scripts (they're expected to call www.agentkeeper.dev)

### 3.3 Skill Prompt Injection (Critical)
For each installed plugin, scan SKILL.md files:
```bash
grep -rin 'ignore all previous\|disregard.*instructions\|you are now\|forget.*instructions\|override.*system' <plugin_dir>/skills/ 2>/dev/null
```
- **FAIL**: Prompt injection patterns found in skill files
- **PASS**: No injection patterns detected

### 3.4 Overly Broad Permissions (High)
Check skill frontmatter for `allowed-tools`:
```bash
grep -r 'allowed-tools:' <plugin_dir>/skills/ 2>/dev/null
```
- **WARN**: Any skill has `allowed-tools: *` or includes all tools
- **PASS**: Skills use scoped permissions

### 3.5 MCP Server Audit (High)
Check for MCP server configurations:
```bash
cat <plugin_dir>/.mcp.json 2>/dev/null
grep -r 'mcpServers' <plugin_dir>/.claude-plugin/plugin.json 2>/dev/null
```
- **WARN**: MCP servers connect to unrecognized external endpoints
- **PASS**: No MCP servers or servers point to known/local endpoints

---

## Grading

Count results across ALL three sections:

Starting from **15 points** (roughly 5 per section):

- Each **FAIL** on a **Critical** check: **-2 points**
- Each **FAIL** on a **High** check: **-1.5 points**
- Each **FAIL** on a **Medium** check: **-1 point**
- Each **WARN**: **-0.5 points**

Minimum score: 0. Grade scale:
- **A**: 13 - 15
- **B**: 10 - 12.5
- **C**: 7 - 9.5
- **D**: 4 - 6.5
- **F**: 0 - 3.5

---

## Output Format

Format the report with clear section separation:

```
AgentKeeper Claude Code Audit — Grade: [LETTER]

SETUP
  [PASS|FAIL|WARN]  [Finding description]
  [PASS|FAIL|WARN]  [Finding description]
  ...

SECRETS
  [PASS|FAIL|WARN]  [Finding description]
  [PASS|FAIL|WARN]  [Finding description]
  ...

PLUGINS
  [PASS|FAIL|WARN]  [Finding description]
  [PASS|FAIL|WARN]  [Finding description]
  ...

Score: [X]/15 — [N] failure(s), [N] warning(s) — Grade [LETTER]

[If any FAIL or WARN]:
Recommendations:
  - [Actionable fix, grouped by priority]
  - ...

For deeper dives: /agentkeeper:secrets (detailed credential scan) | /agentkeeper:inspect (detailed plugin analysis)
```

## Important Notes
- This audit runs entirely locally — no network calls
- Never print actual secret values — only file paths, pattern types, and masked previews
- If a check cannot be determined, default to WARN rather than false PASS
- Batch bash commands where possible to minimize tool calls
- The three sections should run as one continuous audit, not separate passes
