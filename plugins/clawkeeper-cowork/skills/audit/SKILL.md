---
name: audit
description: Run a Clawkeeper security audit of the current working directory. Scans for sensitive files, PII exposure, secret leaks, and policy violations. Use when the user wants to check security posture or run a security audit.
---

# Clawkeeper Cowork Audit

You are running a security audit of the current working directory using Clawkeeper's MCP tools and local file scanning. This audit covers three areas:

1. **File Sensitivity** — classify files in the project for sensitivity levels
2. **Secret Exposure** — scan for exposed credentials and API keys
3. **PII Detection** — identify personal information in source and data files

Run all checks below, then produce a graded report.

---

## Section 1: File Sensitivity Scan

Identify files that may contain sensitive data and classify them using the MCP tool.

### 1.1 Find Sensitive File Types
```bash
find . -maxdepth 3 \( -name ".env" -o -name ".env.*" -o -name "*.pem" -o -name "*.key" -o -name "*.p12" -o -name "*.pfx" -o -name "id_rsa" -o -name "id_ed25519" -o -name "credentials.json" -o -name "service-account*.json" \) ! -path '*/node_modules/*' 2>/dev/null | head -20
```

### 1.2 Classify Each Found File
For each sensitive file found, call `clawkeeper_check_sensitivity` with the file path and operation "read".

- **FAIL**: Any file classified as "restricted" or "confidential" and accessible
- **WARN**: Files classified as "internal"
- **PASS**: No sensitive files found, or all are properly protected

### 1.3 Gitignore Coverage
For each sensitive file, check if it is git-tracked:
```bash
git ls-files --error-unmatch <file> 2>/dev/null && echo "TRACKED" || echo "ignored"
```
- **FAIL**: Sensitive file is git-tracked
- **WARN**: Sensitive file exists but is gitignored
- **PASS**: No sensitive files in repository

---

## Section 2: Secret Exposure

Scan tracked source files for hardcoded secrets. **NEVER print actual secret values.**

### 2.1 Hardcoded API Keys
Scan git-tracked source files for common key patterns:
```bash
git ls-files -- '*.ts' '*.js' '*.py' '*.sh' '*.json' '*.yml' '*.yaml' '*.jsx' '*.tsx' '*.go' '*.rb' 2>/dev/null | head -200
```

Use Grep to search tracked files for:
- AWS keys: `AKIA[0-9A-Z]{16}`
- Stripe: `sk_live_`
- GitHub tokens: `ghp_`, `gho_`, `ghu_`
- Generic live keys: `ck_live_`, `sk-[a-zA-Z0-9]{20,}`
- Private key headers: `BEGIN.*PRIVATE KEY`

For each match, call `clawkeeper_classify_data` with the surrounding line (masked) and context "hardcoded secret in source code".

Report file path, line number, and pattern type only. Mask values: show first 4 chars + `****`.

- **FAIL**: Secrets found in git-tracked files
- **PASS**: No hardcoded secrets detected

### 2.2 Environment File Review
For any `.env` files found, count populated values without displaying them:
```bash
grep -c '=' <file> 2>/dev/null
```
Report count per file. Use `sed 's/=.*/=****/'` to show key names only.

---

## Section 3: PII Detection

### 3.1 Scan for PII Patterns
Search tracked files for common PII indicators:
```bash
git ls-files -- '*.csv' '*.json' '*.txt' '*.md' '*.yml' '*.yaml' '*.ts' '*.js' 2>/dev/null | head -100
```

For files that may contain data (CSV, JSON, text files), read the first 50 lines and call `clawkeeper_classify_data` with the content and context "PII scan of project file".

- **FAIL**: PII found in git-tracked data files (emails, phone numbers, SSNs)
- **WARN**: Possible PII patterns detected (needs human review)
- **PASS**: No PII detected in scanned files

### 3.2 Log Audit Completion
Call `clawkeeper_log_action` with action "security audit completed" and list all files that had findings.

---

## Grading

Starting from **10 points**:

- Each **FAIL** on a Critical check (secrets, restricted files): **-2 points**
- Each **FAIL** on a High check (PII, tracked sensitive files): **-1.5 points**
- Each **WARN**: **-0.5 points**

Grade scale:
- **A**: 9 - 10
- **B**: 7 - 8.5
- **C**: 5 - 6.5
- **D**: 3 - 4.5
- **F**: 0 - 2.5

---

## Output Format

```
Clawkeeper Cowork Audit — Grade: [LETTER]

FILE SENSITIVITY
  [PASS|FAIL|WARN]  [Finding description]
  ...

SECRETS
  [PASS|FAIL|WARN]  [Finding description]
  ...

PII DETECTION
  [PASS|FAIL|WARN]  [Finding description]
  ...

Score: [X]/10 — [N] failure(s), [N] warning(s) — Grade [LETTER]

[If any FAIL or WARN]:
Recommendations:
  - [Actionable fix, grouped by priority]
  - ...
```

## Important Notes
- Never print actual secret values or PII — only file paths, pattern types, and masked previews
- Use Clawkeeper MCP tools for classification — they apply org policy if connected
- If a check cannot be determined, default to WARN rather than false PASS
- Batch bash commands where possible to minimize tool calls
