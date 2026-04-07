---
name: secrets
description: Scan the current working directory for exposed secrets, API keys, private keys, database credentials, and hardcoded tokens. Run when the user wants to find leaked credentials or check for secret exposure in their project. Never prints actual secret values.
---

# Clawkeeper Secret Scanner

You are scanning the current working directory for exposed secrets. This runs entirely locally — no network calls.

**CRITICAL: NEVER print, display, or echo actual secret values. Show only the file path, line number, pattern type, and a masked preview.**

## Step 1: Find Secret Files

Use Glob and Bash to locate files that commonly contain secrets:

### Environment files
```bash
find . -maxdepth 5 -type f \( -name ".env" -o -name ".env.*" -o -name ".env.local" -o -name ".env.production" -o -name ".env.development" \) ! -path "*/node_modules/*" ! -path "*/.git/*" 2>/dev/null
```

### Private key files
```bash
find . -maxdepth 5 -type f \( -name "*.pem" -o -name "*.key" -o -name "*.p12" -o -name "*.pfx" -o -name "id_rsa" -o -name "id_ed25519" -o -name "id_ecdsa" -o -name "*.keystore" \) ! -path "*/node_modules/*" ! -path "*/.git/*" 2>/dev/null
```

### Cloud credential files
```bash
find . -maxdepth 5 -type f \( -name "credentials" -o -name "credentials.json" -o -name "service-account*.json" -o -name "application_default_credentials.json" \) ! -path "*/node_modules/*" ! -path "*/.git/*" 2>/dev/null
```

## Step 2: Scan Source Files for Secret Patterns

Use Grep to search for secret patterns in source code files. Search in common source file extensions only (to avoid binaries). For each pattern, collect file path, line number, and the pattern type.

### AWS Access Keys
```
AKIA[0-9A-Z]{16}
```

### AWS Secret Keys
```
(?i)(aws_secret_access_key|aws_secret_key)\s*[=:]\s*\S+
```

### Stripe Keys
```
(sk_live_|rk_live_|sk_test_|rk_test_)[a-zA-Z0-9]{20,}
```

### GitHub Tokens
```
(ghp_|gho_|ghu_|ghs_|ghr_)[a-zA-Z0-9]{36,}
```

### Generic API Key Patterns
```
(?i)(api[_-]?key|apikey|api[_-]?secret)\s*[=:]\s*['"][a-zA-Z0-9_\-]{20,}['"]
```

### Private Key Headers
```
-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----
```

### Database Connection Strings
```
(?i)(mongodb|postgres|postgresql|mysql|redis|amqp):\/\/[^\s'"]+:[^\s'"]+@
```

### JWT Tokens (hardcoded)
```
eyJ[a-zA-Z0-9_-]{10,}\.eyJ[a-zA-Z0-9_-]{10,}\.[a-zA-Z0-9_-]+
```

### Slack Tokens
```
xox[bporas]-[a-zA-Z0-9-]{10,}
```

### Twilio / SendGrid
```
(?i)(twilio|sendgrid)[_-]?(api[_-]?key|auth[_-]?token|sid)\s*[=:]\s*\S+
```

### Google API Keys
```
AIza[0-9A-Za-z_-]{35}
```

### Heroku API Key
```
(?i)heroku[_-]?(api[_-]?key)\s*[=:]\s*[a-f0-9-]{36}
```

Run Grep for each pattern against the working directory. Exclude `node_modules/`, `.git/`, `vendor/`, `dist/`, `build/`, `__pycache__/`, and binary files. Limit search depth to avoid extremely large repos.

Use Grep with the appropriate pattern and glob filters like `*.{js,ts,py,rb,go,java,php,yaml,yml,json,toml,xml,sh,env,cfg,conf,ini,tf,tfvars}`.

## Step 3: Check .gitignore Coverage

For each secret file found, check if it's covered by `.gitignore`:
```bash
git check-ignore [file_path] 2>/dev/null && echo "IGNORED" || echo "TRACKED"
```

Files that contain secrets and are NOT gitignored are **critical findings**.

## Step 4: Format the Report

### Masking Rules
When showing a preview of a matched line:
- Replace the secret value with asterisks, keeping only the first 4 and last 2 characters
- Example: `AKIA1234567890ABCDEF` becomes `AKIA**************EF`
- Example: `sk_live_abc123xyz789` becomes `sk_l***************89`
- For private keys: just show `[PRIVATE KEY CONTENT]`
- For connection strings: mask the password portion only
- For .env values: show the key name but mask the value: `DATABASE_URL=****`

### Output Format

```
Clawkeeper Secret Scan

Directory: [working directory path]
Files scanned: [count of files checked]
Findings: [total count]

CRITICAL FINDINGS (secrets in git-tracked files):

  [FILE_PATH]:[LINE_NUMBER]
  Type: [pattern_type]
  Preview: [masked preview]
  Status: Tracked by git — this secret may be in your commit history!

WARNINGS (secrets in gitignored files):

  [FILE_PATH]:[LINE_NUMBER]
  Type: [pattern_type]
  Preview: [masked preview]
  Status: Gitignored (not committed, but accessible locally)

---
[N] critical finding(s), [N] warning(s)

[If critical findings exist]:
Recommendations:
  - Add secret files to .gitignore immediately
  - Rotate any secrets found in git-tracked files
  - Consider using a secrets manager (Vault, 1Password CLI, doppler)
  - Run `git log --all -p -- [file]` to check if secrets are in commit history

[If no findings]:
No exposed secrets detected. Good hygiene!
Consider running /clawkeeper:audit for a full setup compliance check.
```

## Important Notes
- NEVER print actual secret values — always mask them
- Skip `node_modules/`, `.git/`, `vendor/`, `dist/`, `build/` directories
- If the working directory is very large, warn the user and limit depth
- This runs entirely locally — no network calls
- If no source files are found, report that and suggest checking the directory
