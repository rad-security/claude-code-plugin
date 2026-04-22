---
name: connect
description: Connect Clawkeeper to your account for dashboard visibility. Run when the user wants to authenticate, link their account, set up an API key, or connect to clawkeeper.dev.
---

# Clawkeeper Connect

You are helping the user connect their Clawkeeper plugin to their clawkeeper.dev account using device authorization. After authentication, you install HTTP hooks into `~/.claude/settings.json` so Claude Code natively sends hook events to the Clawkeeper API.

## Step 1: Check Existing Connection

First check if an API key already exists:
```bash
CK_DIR="$HOME/.clawkeeper-plugin"
[ -n "$CLAUDE_PLUGIN_DATA" ] && CK_DIR="$CLAUDE_PLUGIN_DATA"
cat "$CK_DIR/api_key" 2>/dev/null
```

If a key exists, validate it:
```bash
CK_DIR="$HOME/.clawkeeper-plugin"
[ -n "$CLAUDE_PLUGIN_DATA" ] && CK_DIR="$CLAUDE_PLUGIN_DATA"
API_KEY=$(cat "$CK_DIR/api_key")
curl -s --max-time 5 "https://clawkeeper.dev/api/v1/claude-code/health" \
  -H "Authorization: Bearer $API_KEY"
```

If valid, check if HTTP hooks are already installed:
```bash
grep -q 'clawkeeper\.dev' "$HOME/.claude/settings.json" 2>/dev/null && echo "HOOKS_EXIST" || echo "NO_HOOKS"
```

- If `HOOKS_EXIST`: run Step 5 (refresh hooks) then Step 6 (checkin), then display:
```
Already connected! Hooks refreshed.

Organization: [org_name]
Plan: [plan]
Workstation: [hostname] registered

Dashboard: https://clawkeeper.dev/dashboard
```

- If `NO_HOOKS`: run Step 5 (install hooks) then Step 6 (checkin), then display:
```
Connected! Hooks installed.

Organization: [org_name]
Plan: [plan]
Workstation: [hostname] registered

Restart Claude Code to activate hooks.
Dashboard: https://clawkeeper.dev/dashboard
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
If the user pastes a key manually, store it:
```bash
DATA_DIR="$HOME/.clawkeeper-plugin"
[ -n "$CLAUDE_PLUGIN_DATA" ] && DATA_DIR="$CLAUDE_PLUGIN_DATA"
mkdir -p "$DATA_DIR"
printf '%s' "PASTED_KEY_HERE" > "$DATA_DIR/api_key"
chmod 600 "$DATA_DIR/api_key"
```
Then skip to Step 5.

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
DATA_DIR="$HOME/.clawkeeper-plugin"
[ -n "$CLAUDE_PLUGIN_DATA" ] && DATA_DIR="$CLAUDE_PLUGIN_DATA"
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

## Step 5: Install HTTP Hooks (and persist a stable machine_id)

After the key is stored, install HTTP hooks into `~/.claude/settings.json` and ensure a stable `machine_id` exists alongside the API key. The machine_id is a client-generated UUID that lets the Clawkeeper server recognize the same laptop across hostname changes, OS renames, and hook payloads that report different `hostname` values (common on Windows / MINGW64). Without it, two checkins from the same machine with different hostnames produce two duplicate workstation rows.

This is CRITICAL — without the hooks AND the machine_id, Clawkeeper cannot reliably track a workstation. Run this single command:

```bash
python3 << 'PYEOF'
import json, os, sys, uuid

data_dir = os.environ.get("CLAUDE_PLUGIN_DATA") or os.path.expanduser("~/.clawkeeper-plugin")
api_key_path = os.path.join(data_dir, "api_key")
machine_id_path = os.path.join(data_dir, "machine_id")
settings_path = os.path.expanduser("~/.claude/settings.json")

try:
    with open(api_key_path) as f:
        api_key = f.read().strip()
except FileNotFoundError:
    print("ERROR_NO_KEY")
    sys.exit(1)
if not api_key:
    print("ERROR_EMPTY_KEY")
    sys.exit(1)

# Generate + persist machine_id on first run. Keep it stable forever after.
if os.path.isfile(machine_id_path):
    with open(machine_id_path) as f:
        machine_id = f.read().strip()
else:
    machine_id = str(uuid.uuid4())
    os.makedirs(data_dir, exist_ok=True)
    with open(machine_id_path, "w") as f:
        f.write(machine_id)
    try:
        os.chmod(machine_id_path, 0o600)
    except OSError:
        pass
if not machine_id:
    # Corrupt file — regenerate
    machine_id = str(uuid.uuid4())
    with open(machine_id_path, "w") as f:
        f.write(machine_id)

os.makedirs(os.path.dirname(settings_path), exist_ok=True)
try:
    with open(settings_path) as f:
        settings = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    settings = {}

hooks = settings.setdefault("hooks", {})

# Every hook sends the machine_id as an HTTP header so the server can
# resolve the host by stable ID instead of fuzzy hostname matching.
hook_headers = {"Authorization": "Bearer " + api_key, "X-Machine-Id": machine_id}

ck_hooks = {
    "UserPromptSubmit": [{"matcher": "*", "hooks": [{"type": "http", "url": "https://clawkeeper.dev/api/v1/claude-code/evaluate", "headers": hook_headers}]}],
    "PreToolUse": [{"matcher": "Bash|Edit|Write|Read|Glob|Grep|WebFetch|WebSearch", "hooks": [{"type": "http", "url": "https://clawkeeper.dev/api/v1/claude-code/evaluate", "headers": hook_headers}]}],
    "PostToolUse": [{"matcher": "Bash|Edit|Write|Read|Glob|Grep|WebFetch|WebSearch", "hooks": [{"type": "http", "url": "https://clawkeeper.dev/api/v1/claude-code/audit", "headers": hook_headers}]}],
    "SessionStart": [{"matcher": "*", "hooks": [{"type": "http", "url": "https://clawkeeper.dev/api/v1/claude-code/checkin", "headers": hook_headers}]}],
}

for event_name, new_entries in ck_hooks.items():
    existing = hooks.get(event_name, [])
    cleaned = [g for g in existing if not any("clawkeeper.dev" in (h.get("url") or "") for h in g.get("hooks", []))]
    cleaned.extend(new_entries)
    hooks[event_name] = cleaned

settings["hooks"] = hooks
with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

print("HOOKS_WRITTEN")

for repo_file in [".claude/settings.json", ".claude/settings.local.json"]:
    if os.path.isfile(repo_file):
        try:
            content = open(repo_file).read()
            if '"http"' in content and "clawkeeper.dev" in content:
                print("REPO_HOOKS_DETECTED")
                break
        except:
            pass
PYEOF
```

If the output contains `ERROR_NO_KEY` or `ERROR_EMPTY_KEY`, display an error and ask the user to reconnect.

**CRITICAL: Never echo or log the contents of the `machine_id` file in output shown to the user. It is a stable per-machine identifier and should not be pasted into chat or logs.**

## Step 6: Register Workstation

After hooks are installed, register the workstation. This call also sends `machine_id` in the body so the server can link this checkin to the same host that subsequent HTTP hook calls will report via the `X-Machine-Id` header.
```bash
CK_DIR="$HOME/.clawkeeper-plugin"
[ -n "$CLAUDE_PLUGIN_DATA" ] && CK_DIR="$CLAUDE_PLUGIN_DATA"
API_KEY=$(cat "$CK_DIR/api_key" 2>/dev/null)
MACHINE_ID=$(cat "$CK_DIR/machine_id" 2>/dev/null)
HOSTNAME_VAL=$(scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || echo "unknown")
OS_VAL=$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "unknown")
CC_VERSION=$(claude --version 2>/dev/null | head -1 | awk '{print $1}' || echo "unknown")
CWD_VAL=$(pwd)
curl -s --max-time 10 -X POST "https://clawkeeper.dev/api/v1/claude-code/checkin" \
  -H "Authorization: Bearer $API_KEY" \
  -H "X-Machine-Id: $MACHINE_ID" \
  -H "Content-Type: application/json" \
  -d "{\"hostname\":\"$HOSTNAME_VAL\",\"os\":\"$OS_VAL\",\"claude_version\":\"$CC_VERSION\",\"cwd\":\"$CWD_VAL\",\"machine_id\":\"$MACHINE_ID\"}" 2>/dev/null
echo ""
echo "CHECKIN_DONE"
```

### Handle poll results:

**If approved** (output starts with `APPROVED`), run Step 5 then Step 6, then display:
```
Connected!

Organization: [org_name]
Plan: [plan]
Workstation: [hostname] registered

HTTP hooks installed to ~/.claude/settings.json
Restart Claude Code to activate hooks.
Dashboard: https://clawkeeper.dev/dashboard
```

**If `REPO_HOOKS_DETECTED`** was printed by Step 5, add this note:
```
Note: This repo also has Clawkeeper hooks in its local settings.
You may see duplicate events in this repo — this is harmless.
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
- After connecting, tell the user to RESTART Claude Code for hooks to activate
- This is the only skill that makes network calls by design
