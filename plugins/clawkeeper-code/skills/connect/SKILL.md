---
name: connect
description: Connect Clawkeeper to a free account for dashboard visibility. Run when the user wants to authenticate, link their account, set up an API key, or connect to clawkeeper.dev.
---

# Clawkeeper Connect

You are helping the user connect their Clawkeeper plugin to their clawkeeper.dev account using device authorization.

## Step 1: Check Existing Connection

First check if an API key already exists:
```bash
cat "${CLAUDE_PLUGIN_DATA:-$HOME/.clawkeeper-plugin}/api_key" 2>/dev/null
```

If a key exists, validate it:
```bash
curl -s --max-time 5 "https://clawkeeper.dev/api/v1/claude-code/health" \
  -H "Authorization: Bearer $(cat "${CLAUDE_PLUGIN_DATA:-$HOME/.clawkeeper-plugin}/api_key")"
```

If valid, install hook shims (in case they're missing) and checkin:
```bash
DATA_DIR="${CLAUDE_PLUGIN_DATA:-$HOME/.clawkeeper-plugin}"
HOOKS_DIR="$DATA_DIR/hooks"
mkdir -p "$HOOKS_DIR"

PLUGIN_DIR="$(ls -d "$HOME/.claude/plugins/cache/clawkeeper/clawkeeper-code"/*/shims 2>/dev/null | tail -1)"
if [ -n "$PLUGIN_DIR" ] && [ -d "$PLUGIN_DIR" ]; then
  cp "$PLUGIN_DIR"/*.sh "$HOOKS_DIR/" 2>/dev/null
  chmod +x "$HOOKS_DIR"/*.sh 2>/dev/null
fi

HOSTNAME_VAL=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "unknown")
OS_VAL=$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "unknown")
CC_VERSION=$(claude --version 2>/dev/null | head -1 | awk '{print $1}' || echo "unknown")
CWD_VAL=$(pwd)

curl -s --max-time 10 -X POST "https://clawkeeper.dev/api/v1/claude-code/checkin" \
  -H "Authorization: Bearer $(cat "$DATA_DIR/api_key")" \
  -H "Content-Type: application/json" \
  -d "{\"hostname\":\"$HOSTNAME_VAL\",\"os\":\"$OS_VAL\",\"claude_version\":\"$CC_VERSION\",\"cwd\":\"$CWD_VAL\"}" 2>/dev/null
```

Then display:
```
Already connected!

Organization: [org_name]
Plan: [plan]
Workstation: [hostname] registered

Your hooks are API-powered. Run /clawkeeper:status for details.
```

Then ask if they want to reconnect with a different account. If not, stop here.

## Step 2: Register a Device Code

Request a device code from the API:
```bash
REGISTER_RESPONSE=$(curl -s --max-time 10 -X POST "https://clawkeeper.dev/api/v1/device/register" -H "Content-Type: application/json" 2>&1)
CURL_EXIT=$?
echo "$REGISTER_RESPONSE"
```

If the curl command fails (non-zero exit code, empty response, or no `code` field in JSON), display:
```
Could not reach clawkeeper.dev. Check your network connection and try again.

Having trouble? You can also paste an API key manually from:
  https://clawkeeper.dev/settings#api-keys
```
Then stop.

Parse the response to extract `code`, `verify_url`, and `poll_url`.

## Step 3: Open Browser and Display Code

Open the verify URL in the user's browser:
```bash
URL="[verify_url from response]"
if [[ "$OSTYPE" == "darwin"* ]]; then
  open "$URL"
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$URL"
elif command -v wslview >/dev/null 2>&1; then
  wslview "$URL"
else
  echo "Open this URL: $URL"
fi
```

Display to the user:
```
Opening your browser to approve this device...

Device code: [CODE]

If the browser didn't open:
  https://clawkeeper.dev/auth/device?code=[CODE]

Waiting for approval...
```

## Step 4: Poll for Approval

Poll every 3 seconds for up to 100 seconds (~33 attempts):
```bash
CODE="[code from register response]"
DATA_DIR="${CLAUDE_PLUGIN_DATA:-$HOME/.clawkeeper-plugin}"
ATTEMPTS=0
MAX_ATTEMPTS=33

while [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; do
  POLL_RESPONSE=$(curl -s --max-time 5 "https://clawkeeper.dev/api/v1/device/poll?code=$CODE")
  STATUS=$(echo "$POLL_RESPONSE" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)

  if [ "$STATUS" = "approved" ]; then
    API_KEY=$(echo "$POLL_RESPONSE" | grep -o '"api_key":"[^"]*"' | head -1 | cut -d'"' -f4)
    ORG_NAME=$(echo "$POLL_RESPONSE" | grep -o '"org_name":"[^"]*"' | head -1 | cut -d'"' -f4)
    PLAN=$(echo "$POLL_RESPONSE" | grep -o '"plan":"[^"]*"' | head -1 | cut -d'"' -f4)

    mkdir -p "$DATA_DIR"
    printf '%s' "$API_KEY" > "$DATA_DIR/api_key"
    chmod 600 "$DATA_DIR/api_key"

    echo "APPROVED|$ORG_NAME|$PLAN"
    exit 0
  elif [ "$STATUS" = "expired" ]; then
    echo "EXPIRED"
    exit 1
  fi

  ATTEMPTS=$((ATTEMPTS + 1))
  sleep 3
done

echo "TIMEOUT"
exit 1
```

**CRITICAL: Never echo or log the raw API key in any output shown to the user. The script above stores it directly to file without displaying it.**

## Step 5: Install Hook Shims and Register Workstation

After the key is stored, install hook shim scripts and register the workstation. This is CRITICAL — without the shims, hooks won't fire. Run:
```bash
DATA_DIR="${CLAUDE_PLUGIN_DATA:-$HOME/.clawkeeper-plugin}"
HOOKS_DIR="$DATA_DIR/hooks"
mkdir -p "$HOOKS_DIR"

# Find the plugin's shims directory
PLUGIN_DIR="$(ls -d "$HOME/.claude/plugins/cache/clawkeeper/clawkeeper-code"/*/shims 2>/dev/null | tail -1)"

if [ -n "$PLUGIN_DIR" ] && [ -d "$PLUGIN_DIR" ]; then
  cp "$PLUGIN_DIR"/*.sh "$HOOKS_DIR/" 2>/dev/null
  chmod +x "$HOOKS_DIR"/*.sh 2>/dev/null
  echo "SHIMS_INSTALLED"
else
  # Fallback: create shims inline if plugin cache structure is unexpected
  for SCRIPT in pre-tool-hook.sh post-tool-hook.sh session-start.sh prompt-hook.sh; do
    cat > "$HOOKS_DIR/$SCRIPT" << 'SHIM'
#!/usr/bin/env bash
set -euo pipefail
P="$(ls -d "$HOME/.claude/plugins/cache/clawkeeper/clawkeeper-code"/*/scripts 2>/dev/null | tail -1)"
[ -n "$P" ] && [ -f "$P/SCRIPT_NAME" ] && exec bash "$P/SCRIPT_NAME"
echo '{}'
SHIM
    sed -i.bak "s/SCRIPT_NAME/$SCRIPT/g" "$HOOKS_DIR/$SCRIPT" 2>/dev/null || sed "s/SCRIPT_NAME/$SCRIPT/g" "$HOOKS_DIR/$SCRIPT" > "$HOOKS_DIR/$SCRIPT.tmp" && mv "$HOOKS_DIR/$SCRIPT.tmp" "$HOOKS_DIR/$SCRIPT"
    rm -f "$HOOKS_DIR/$SCRIPT.bak" 2>/dev/null
    chmod +x "$HOOKS_DIR/$SCRIPT"
  done
  echo "SHIMS_CREATED_INLINE"
fi

# Register workstation
API_KEY=$(cat "$DATA_DIR/api_key" 2>/dev/null)
HOSTNAME_VAL=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "unknown")
OS_VAL=$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "unknown")
CC_VERSION=$(claude --version 2>/dev/null | head -1 | awk '{print $1}' || echo "unknown")
CWD_VAL=$(pwd)

curl -s --max-time 10 -X POST "https://clawkeeper.dev/api/v1/claude-code/checkin" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"hostname\":\"$HOSTNAME_VAL\",\"os\":\"$OS_VAL\",\"claude_version\":\"$CC_VERSION\",\"cwd\":\"$CWD_VAL\"}" 2>/dev/null
echo "CHECKIN_DONE"
```

This installs hook shims at a stable path (`~/.clawkeeper-plugin/hooks/`) and registers the workstation. The shims dynamically find the cached plugin scripts, bypassing the broken `$CLAUDE_PLUGIN_ROOT` variable. **The user must restart Claude Code after this step for hooks to activate.**

### Handle poll results:

**If approved** (output starts with `APPROVED`), run Step 5 (the checkin), then display:
```
Connected!

Organization: [org_name]
Plan: [plan]
Workstation: [hostname] registered

Your Clawkeeper hooks are now API-powered.
Dashboard: https://clawkeeper.dev/dashboard
```

**If expired** (output is `EXPIRED`), display:
```
Code expired. Run /clawkeeper:connect again.

Having trouble? You can also paste an API key manually from:
  https://clawkeeper.dev/settings#api-keys
```

**If timed out** (output is `TIMEOUT`), display:
```
Timed out waiting for approval. Run /clawkeeper:connect to try again.

Having trouble? You can also paste an API key manually from:
  https://clawkeeper.dev/settings#api-keys
```

## Important Notes
- NEVER print, echo, or display the raw API key value in any output
- NEVER store the key if validation fails
- Set file permissions to 600 (owner read/write only) on the key file
- The device code (e.g. A1B2-C3D4) is safe to display — it is NOT the API key
- The polling loop runs as a single bash command to avoid multiple tool calls
- If the register endpoint is unreachable, always offer the manual key paste fallback
- This is the only skill that makes network calls by design
