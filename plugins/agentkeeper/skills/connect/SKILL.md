---
name: connect
description: Connect AgentKeeper to this workstation. Supports interactive device-code browser flow (no args) or headless `--api-key <key>` for CI, managed laptops, and fleet provisioning. Run when the user wants to authenticate, link their account, set up an API key, or paste an existing key.
---

# AgentKeeper Connect

You are helping the user connect the AgentKeeper plugin to their www.agentkeeper.dev account. There are two paths:

- **Interactive (default)**: device-code browser flow. Open a URL, user approves in browser, we receive the key and install hooks.
- **Headless** (`--api-key <key>`): user supplies an existing API key inline. Validate it server-side, store, install hooks. No browser, no prompts. Required for CI, MDM fleet provisioning, and SSO-managed laptops where the browser flow is blocked.

After either path succeeds, command preflight hooks are installed into `~/.claude/settings.json` so Claude Code can inspect local helper scripts before forwarding hook events to the AgentKeeper API.

## Step 0: Parse Arguments

Check the user's slash command invocation for flags:

- If the invocation is `/agentkeeper:connect --api-key <KEY>` or `/agentkeeper:connect --api-key=<KEY>`: take the headless path (Step 1B). The `<KEY>` value is the raw API key string. **Never echo it.**
- Otherwise: take the interactive path (Step 1 onward, existing flow).

If `--api-key` is present but no value follows, print:
```
The --api-key flag requires a value. Usage:
  /agentkeeper:connect --api-key ak_live_...

Generate a key at https://www.agentkeeper.dev/settings#api-keys
```
and stop.

## Step 1B: Headless --api-key path

1. Validate the key against the health endpoint. Display a brief message while the request is in flight (do NOT echo the key itself):

   ```bash
   AGENTKEEPER_DIR="$HOME/.agentkeeper-plugin"
   [ -n "$CLAUDE_PLUGIN_DATA" ] && AGENTKEEPER_DIR="$CLAUDE_PLUGIN_DATA"
   mkdir -p "$AGENTKEEPER_DIR"
   HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
     "https://www.agentkeeper.dev/api/v1/claude-code/health" \
     -H "Authorization: Bearer PASTE_KEY_HERE")
   echo "$HTTP_CODE"
   ```
   Replace `PASTE_KEY_HERE` with the value from the `--api-key` arg. Do NOT print the key in any output.

2. If the HTTP status is not `200`:
   ```
   That API key did not validate. www.agentkeeper.dev returned HTTP [status].

   Common causes:
     - Key was revoked or belongs to a deleted org
     - Typo or extra whitespace in the pasted value
     - Wrong environment (staging key vs prod)

   Generate a fresh key at https://www.agentkeeper.dev/settings#api-keys
   ```
   Stop. Do NOT write the key to disk.

3. If the HTTP status is `200`, write the key and install hooks + register. Use the same Step 5 and Step 6 code blocks as the interactive path. To write the key, use a heredoc so the value never appears on the command line:

   ```bash
   AGENTKEEPER_DIR="$HOME/.agentkeeper-plugin"
   [ -n "$CLAUDE_PLUGIN_DATA" ] && AGENTKEEPER_DIR="$CLAUDE_PLUGIN_DATA"
   mkdir -p "$AGENTKEEPER_DIR"
   # Use printf with a variable rather than echoing to avoid leaking through `ps`
   API_KEY_FROM_FLAG="PASTE_KEY_HERE"
   printf '%s' "$API_KEY_FROM_FLAG" > "$AGENTKEEPER_DIR/api_key"
   chmod 600 "$AGENTKEEPER_DIR/api_key"
   unset API_KEY_FROM_FLAG
   ```

4. Run Step 5 (install command preflight hooks, generates machine_id) and Step 6 (register workstation + skill inventory).

5. Display (never include the API key value):
   ```
   Logged in (headless).

   Workstation: [hostname] registered
   Hooks installed at ~/.claude/settings.json
   Machine ID generated at $AGENTKEEPER_DIR/machine_id

   Restart Claude Code so hooks load at startup.
   Dashboard: https://www.agentkeeper.dev/dashboard
   ```

6. **STOP**. Do not proceed to the interactive Step 2 (device register). The headless path is complete.

**CRITICAL for Step 1B: Never echo the API key in any output, prompt, status message, or confirmation. Never include it in a log. The only legitimate destination for the key value is the `$AGENTKEEPER_DIR/api_key` file (mode 600) and the Authorization header of outbound HTTPS requests.**

## Step 1: Check Existing Connection

First check if an API key already exists:
```bash
AGENTKEEPER_DIR="$HOME/.agentkeeper-plugin"
[ -n "$CLAUDE_PLUGIN_DATA" ] && AGENTKEEPER_DIR="$CLAUDE_PLUGIN_DATA"
cat "$AGENTKEEPER_DIR/api_key" 2>/dev/null
```

If a key exists, validate it:
```bash
AGENTKEEPER_DIR="$HOME/.agentkeeper-plugin"
[ -n "$CLAUDE_PLUGIN_DATA" ] && AGENTKEEPER_DIR="$CLAUDE_PLUGIN_DATA"
API_KEY=$(cat "$AGENTKEEPER_DIR/api_key")
curl -s --max-time 5 "https://www.agentkeeper.dev/api/v1/claude-code/health" \
  -H "Authorization: Bearer $API_KEY"
```

If valid, check if AgentKeeper hooks are already installed:
```bash
grep -q 'agentkeeper\.dev' "$HOME/.claude/settings.json" 2>/dev/null && echo "HOOKS_EXIST" || echo "NO_HOOKS"
```

- If `HOOKS_EXIST`: run Step 5 (refresh hooks) then Step 6 (checkin), then display:
```
Already connected! Hooks refreshed.

Organization: [org_name]
Plan: [plan]
Workstation: [hostname] registered

Dashboard: https://www.agentkeeper.dev/dashboard
```

- If `NO_HOOKS`: run Step 5 (install hooks) then Step 6 (checkin), then display:
```
Connected! Hooks installed.

Organization: [org_name]
Plan: [plan]
Workstation: [hostname] registered

Restart Claude Code to activate hooks.
Dashboard: https://www.agentkeeper.dev/dashboard
```

Then ask if they want to reconnect with a different account. If not, stop here.

## Step 2: Register a Device Code

Request a device code from the API:
```bash
REGISTER_RESPONSE=$(curl -s --max-time 10 -X POST "https://www.agentkeeper.dev/api/v1/device/register" -H "Content-Type: application/json" 2>&1)
CURL_EXIT=$?
echo "$REGISTER_RESPONSE"
```

If the curl command fails (non-zero exit code, empty response, or no `code` field in JSON), display:
```
Could not reach www.agentkeeper.dev. Check your network connection and try again.

Having trouble? You can also paste an API key manually from:
  https://www.agentkeeper.dev/settings#api-keys
```
If the user pastes a key manually, store it:
```bash
DATA_DIR="$HOME/.agentkeeper-plugin"
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
  https://www.agentkeeper.dev/auth/device?code=[CODE]

Waiting for approval...
```

## Step 4: Poll for Approval

Poll every 3 seconds for up to 100 seconds (~33 attempts):
```bash
CODE="[code from register response]"
DATA_DIR="$HOME/.agentkeeper-plugin"
[ -n "$CLAUDE_PLUGIN_DATA" ] && DATA_DIR="$CLAUDE_PLUGIN_DATA"
ATTEMPTS=0
MAX_ATTEMPTS=33

while [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; do
  POLL_RESPONSE=$(curl -s --max-time 5 "https://www.agentkeeper.dev/api/v1/device/poll?code=$CODE")
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

## Step 5: Install Hooks (and persist a stable machine_id)

After the key is stored, install runtime command hooks plus a command-based `SessionStart` inventory hook into `~/.claude/settings.json`, and ensure a stable `machine_id` exists alongside the API key. The machine_id must come from the platform or an explicit managed override: macOS `IOPlatformUUID`, Windows Entra DeviceId / hashed MachineGuid / SMBIOS UUID, or Linux `/etc/machine-id` / DMI UUID. It must not be a random AgentKeeper-generated UUID; random IDs make reinstall, Jamf, Intune, and Codex/Claude plugin installs disagree about the same workstation. Without a stable platform ID, two checkins from the same machine with different hostnames produce duplicate workstation rows.

`UserPromptSubmit`, `PreToolUse`, and `SessionStart` should be command hooks for managed installs. HTTP-only `PreToolUse` can evaluate the visible command, but it cannot inspect the contents of a local helper script before execution. The command preflight hook inspects local scripts, forwards an enriched event to AgentKeeper, sends hostname and machine_id explicitly, and then exits fail-open except for critical local preflight detections.

This is CRITICAL — without the hooks AND the machine_id, AgentKeeper cannot reliably track a workstation. Run this single command:

```bash
python3 << 'PYEOF'
import glob, json, os, platform, re, shlex, shutil, stat, subprocess, sys, time

data_dir = os.environ.get("CLAUDE_PLUGIN_DATA") or os.path.expanduser("~/.agentkeeper-plugin")
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

def normalize_machine_id(value):
    if not value:
        return ""
    return re.sub(r"\s+", "", str(value)).lower()

def run_output(cmd):
    try:
        return subprocess.check_output(cmd, stderr=subprocess.DEVNULL, text=True, timeout=5)
    except Exception:
        return ""

def machine_id_paths():
    paths = [
        machine_id_path,
        os.path.expanduser("~/.agentkeeper-plugin/machine_id"),
        os.path.expanduser("~/.agentkeeper/machine_id"),
    ]
    seen = set()
    for path in paths:
        if path and path not in seen:
            seen.add(path)
            yield path

def write_machine_id(machine_id):
    machine_id = normalize_machine_id(machine_id)
    if not machine_id:
        return ""
    for path in machine_id_paths():
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                f.write(machine_id)
            os.chmod(path, 0o600)
        except OSError:
            pass
    return machine_id

def read_cached_machine_id():
    for path in machine_id_paths():
        try:
            with open(path) as f:
                machine_id = normalize_machine_id(f.read())
        except OSError:
            continue
        if machine_id:
            return write_machine_id(machine_id)
    return ""

def windows_machine_id():
    ps = "powershell.exe" if os.name != "nt" else "powershell"
    entra = run_output([
        ps, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command",
        r'try { $s = dsregcmd /status 2>$null; foreach ($line in $s) { if ($line -match "^\s*DeviceId\s*:\s*([0-9a-fA-F-]{36})\s*$") { [Console]::Write("entra:" + $Matches[1].ToLowerInvariant()); exit 0 } } } catch {}',
    ])
    if entra:
        return normalize_machine_id(entra)
    machine_guid = run_output([
        ps, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command",
        r'try { $v = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Cryptography" -Name MachineGuid).MachineGuid; if ($v) { $bytes = [Text.Encoding]::UTF8.GetBytes($v.ToLowerInvariant()); $hash = [Security.Cryptography.SHA256]::Create().ComputeHash($bytes); $hex = -join ($hash | ForEach-Object { $_.ToString("x2") }); [Console]::Write("winmg:" + $hex.Substring(0, 32)); exit 0 } } catch {}',
    ])
    if machine_guid:
        return normalize_machine_id(machine_guid)
    smbios = run_output([
        ps, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command",
        r'try { $v = (Get-CimInstance Win32_ComputerSystemProduct).UUID; if ($v -and $v -notmatch "^0{8}-0{4}-0{4}-0{4}-0{12}$" -and $v -notmatch "^f{8}-f{4}-f{4}-f{4}-f{12}$") { [Console]::Write("smbios:" + $v.ToLowerInvariant()); exit 0 } } catch {}',
    ])
    return normalize_machine_id(smbios)

def detect_platform_machine_id():
    override = normalize_machine_id(os.environ.get("AGENTKEEPER_MACHINE_ID"))
    if override:
        return override

    system = platform.system().lower()
    uname = run_output(["uname", "-s"]).strip().lower()
    if system == "darwin" or uname == "darwin":
        output = run_output(["ioreg", "-rd1", "-c", "IOPlatformExpertDevice"])
        match = re.search(r'"IOPlatformUUID"\s*=\s*"([^"]+)"', output)
        return normalize_machine_id(match.group(1) if match else "")
    if system == "windows" or uname.startswith(("mingw", "msys", "cygwin")):
        return windows_machine_id()
    for path in ("/etc/machine-id", "/sys/class/dmi/id/product_uuid"):
        try:
            with open(path) as f:
                machine_id = normalize_machine_id(f.read())
        except OSError:
            continue
        if machine_id:
            return machine_id
    return ""

# Platform identity wins over stale AgentKeeper cache files. Cache files are
# repaired from the platform value and are only used as a last-resort fallback.
machine_id = detect_platform_machine_id() or read_cached_machine_id()
if machine_id:
    machine_id = write_machine_id(machine_id)
else:
    print("WARN_NO_MACHINE_ID")

os.makedirs(os.path.dirname(settings_path), exist_ok=True)
settings_exists = os.path.exists(settings_path)
settings_mode = 0o600
try:
    if settings_exists:
        settings_mode = stat.S_IMODE(os.stat(settings_path).st_mode)
    with open(settings_path) as f:
        settings = json.load(f)
except FileNotFoundError:
    settings = {}
except json.JSONDecodeError:
    print("ERROR_INVALID_SETTINGS_JSON")
    sys.exit(1)

if not isinstance(settings, dict):
    print("ERROR_INVALID_SETTINGS_SHAPE")
    sys.exit(1)

hooks = settings.get("hooks")
if hooks is None:
    hooks = {}
    settings["hooks"] = hooks
elif not isinstance(hooks, dict):
    print("ERROR_INVALID_HOOKS_SHAPE")
    sys.exit(1)

# HTTP fallback hooks send machine_id as a header. Command hooks resolve and
# send the stable machine_id from the local hook scripts.
hook_headers = {"Authorization": "Bearer " + api_key}
if machine_id:
    hook_headers["X-Machine-Id"] = machine_id

plugin_root = os.environ.get("CLAUDE_PLUGIN_ROOT") or ""
if not plugin_root:
    matches = sorted(
        glob.glob(os.path.expanduser("~/.claude/plugins/cache/agentkeeper/agentkeeper/*/scripts/session-start.sh")),
        key=os.path.getmtime,
        reverse=True,
    )
    if matches:
        plugin_root = os.path.dirname(os.path.dirname(matches[0]))

session_start_hook = None
if plugin_root:
    session_script = os.path.join(plugin_root, "scripts", "session-start.sh")
    if os.path.isfile(session_script):
        session_start_hook = {
            "matcher": "*",
            "hooks": [{
                "type": "command",
                "command": "bash " + shlex.quote(session_script),
                "timeout": 15,
            }],
        }

agentkeeper_hooks = {
    "UserPromptSubmit": [{"matcher": "*", "hooks": [{"type": "http", "url": "https://www.agentkeeper.dev/api/v1/claude-code/evaluate", "headers": hook_headers}]}],
    "PreToolUse": [{"matcher": "*", "hooks": [{"type": "http", "url": "https://www.agentkeeper.dev/api/v1/claude-code/evaluate", "headers": hook_headers}]}],
    "PostToolUse": [{"matcher": "*", "hooks": [{"type": "http", "url": "https://www.agentkeeper.dev/api/v1/claude-code/audit", "headers": hook_headers}]}],
}
if session_start_hook:
    agentkeeper_hooks["SessionStart"] = [session_start_hook]
else:
    # Fallback registration only. Inventory is unavailable until the plugin
    # command script can be resolved.
    agentkeeper_hooks["SessionStart"] = [{"matcher": "*", "hooks": [{"type": "http", "url": "https://www.agentkeeper.dev/api/v1/claude-code/checkin", "headers": hook_headers}]}]

pre_tool_script = os.path.join(plugin_root, "scripts", "pre-tool-hook.sh") if plugin_root else ""
post_tool_script = os.path.join(plugin_root, "scripts", "post-tool-hook.sh") if plugin_root else ""
if plugin_root and os.path.isfile(pre_tool_script) and os.path.isfile(post_tool_script):
    api_url = os.environ.get("AGENTKEEPER_API_URL", "https://www.agentkeeper.dev").rstrip("/")
    prefix = (
        "AGENTKEEPER_SKIP_CONFLICT_CHECK=1 "
        "AGENTKEEPER_API_TOOL=claude-code "
        f"AGENTKEEPER_API_URL={shlex.quote(api_url)} "
        f"AGENTKEEPER_SCRIPTS_DIR={shlex.quote(plugin_root)} "
    )
    agentkeeper_hooks["UserPromptSubmit"] = [{"matcher": "*", "hooks": [{"type": "command", "command": prefix + "bash " + shlex.quote(pre_tool_script), "timeout": 10}]}]
    agentkeeper_hooks["PreToolUse"] = [{"matcher": "*", "hooks": [{"type": "command", "command": prefix + "bash " + shlex.quote(pre_tool_script), "timeout": 10}]}]
    agentkeeper_hooks["PostToolUse"] = [{"matcher": "*", "hooks": [{"type": "command", "command": prefix + "bash " + shlex.quote(post_tool_script), "timeout": 10}]}]

def is_agentkeeper_hook(hook):
    if not isinstance(hook, dict):
        return False
    url = str(hook.get("url") or "")
    command = str(hook.get("command") or "")
    return (
        "agentkeeper.dev" in url
        or "/api/v1/claude-code/" in url
        or "AGENTKEEPER_API_TOOL=claude-code" in command
        or "AGENTKEEPER_SCRIPTS_DIR=" in command
        or "/.agentkeeper/" in command
    )

def prune_agentkeeper_hooks(group):
    if not isinstance(group, dict):
        return group
    raw_hooks = group.get("hooks", [])
    if not isinstance(raw_hooks, list):
        return group
    kept_hooks = [hook for hook in raw_hooks if not is_agentkeeper_hook(hook)]
    if len(kept_hooks) == len(raw_hooks):
        return group
    if not kept_hooks:
        return None
    clone = dict(group)
    clone["hooks"] = kept_hooks
    return clone

for event_name, new_entries in agentkeeper_hooks.items():
    existing = hooks.get(event_name, [])
    if not isinstance(existing, list):
        print("ERROR_INVALID_HOOK_EVENT_SHAPE:" + event_name)
        sys.exit(1)
    cleaned = []
    for group in existing:
        pruned = prune_agentkeeper_hooks(group)
        if pruned is not None:
            cleaned.append(pruned)
    cleaned.extend(new_entries)
    hooks[event_name] = cleaned

if settings_exists:
    backup_path = settings_path + ".agentkeeper-backup-" + time.strftime("%Y%m%d%H%M%S")
    shutil.copy2(settings_path, backup_path)

tmp_path = settings_path + ".agentkeeper-tmp-" + str(os.getpid())
try:
    with open(tmp_path, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    os.chmod(tmp_path, settings_mode)
    os.replace(tmp_path, settings_path)
finally:
    try:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)
    except OSError:
        pass

print("HOOKS_SAFE_MERGED")
print("HOOKS_WRITTEN")
if session_start_hook:
    print("INVENTORY_LITE_SESSIONSTART_WRITTEN")
else:
    print("WARN_SESSIONSTART_HTTP_FALLBACK")

for repo_file in [".claude/settings.json", ".claude/settings.local.json"]:
    if os.path.isfile(repo_file):
        try:
            content = open(repo_file).read()
            if '"http"' in content and "www.agentkeeper.dev" in content:
                print("REPO_HOOKS_DETECTED")
                break
        except:
            pass
PYEOF
```

If the output contains `ERROR_NO_KEY` or `ERROR_EMPTY_KEY`, display an error and ask the user to reconnect. If the output contains `ERROR_INVALID_SETTINGS_JSON`, `ERROR_INVALID_SETTINGS_SHAPE`, `ERROR_INVALID_HOOKS_SHAPE`, or `ERROR_INVALID_HOOK_EVENT_SHAPE`, tell the user AgentKeeper left `~/.claude/settings.json` untouched and they must repair the existing Claude Code settings JSON before reconnecting.

**CRITICAL: Never echo or log the contents of the `machine_id` file in output shown to the user. It is a stable per-machine identifier and should not be pasted into chat or logs.**

## Step 6: Register Workstation (with skill + MCP inventory)

After hooks are installed, register the workstation. This call also sends `machine_id` in the body so the server can link this checkin to the same host that subsequent HTTP hook calls will report via the `X-Machine-Id` header.

In addition to the basic workstation metadata, this call enumerates the skills and MCP servers installed locally and sends them in the payload. The server persists them in `host_skill_inventory` and `host_mcp_inventory` so admins can see — on the Agent Skills panel at `/security` — which skills each workstation has, with risk classification. Without this, the panel shows "0 skills discovered" even on machines that have the plugin installed.

```bash
AGENTKEEPER_DIR="$HOME/.agentkeeper-plugin"
[ -n "$CLAUDE_PLUGIN_DATA" ] && AGENTKEEPER_DIR="$CLAUDE_PLUGIN_DATA"
API_KEY=$(cat "$AGENTKEEPER_DIR/api_key" 2>/dev/null)

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$PLUGIN_ROOT" ]; then
  SESSION_SCRIPT=$(ls -t "$HOME"/.claude/plugins/cache/agentkeeper/agentkeeper/*/scripts/session-start.sh 2>/dev/null | head -1)
  [ -n "$SESSION_SCRIPT" ] && PLUGIN_ROOT=$(cd "$(dirname "$SESSION_SCRIPT")/.." && pwd)
fi
if [ -n "$PLUGIN_ROOT" ]; then
  source "$PLUGIN_ROOT/scripts/lib/machine-id.sh" 2>/dev/null || source "$PLUGIN_ROOT/lib/machine-id.sh" 2>/dev/null || true
fi

if command -v get_machine_id >/dev/null 2>&1; then
  MACHINE_ID=$(get_machine_id)
else
  MACHINE_ID=$(cat "$AGENTKEEPER_DIR/machine_id" 2>/dev/null)
fi
if command -v get_agentkeeper_hostname >/dev/null 2>&1; then
  HOSTNAME_VAL=$(get_agentkeeper_hostname)
else
  HOSTNAME_VAL=$(scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || hostname 2>/dev/null || echo "unknown")
fi
export MACHINE_ID HOSTNAME_VAL
export OS_VAL=$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "unknown")
export CC_VERSION=$(claude --version 2>/dev/null | head -1 | awk '{print $1}' || echo "unknown")
CWD_VAL=$(pwd)

# Build the full JSON payload in Python — enumerates installed skills (global + plugin-provided)
# and MCP servers so the server-side inventory is populated on first /connect and on every
# subsequent /connect (the skill set can change between connects).
BODY=$(python3 - <<PYEOF
import json, os, hashlib, glob

home = os.path.expanduser("~")
cwd = os.getcwd()

def read_preview(path, max_bytes=2048):
    try:
        with open(path, "rb") as f:
            data = f.read(max_bytes)
        return data.decode("utf-8", errors="replace")
    except OSError:
        return ""

def sha256(path):
    try:
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(8192), b""):
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return None

def collect_skills():
    out = []
    seen = set()

    def add(path, source):
        name = os.path.basename(os.path.dirname(path))
        key = (name, source)
        if key in seen:
            return
        seen.add(key)
        out.append({
            "name": name,
            "source": source,
            "preview": read_preview(path),
            "hash": sha256(path),
        })

    # 1. Standalone skills at well-known locations.
    for pat, src in [
        (os.path.join(home, ".claude", "skills", "*", "SKILL.md"), "global"),
        (os.path.join(cwd,  ".claude", "skills", "*", "SKILL.md"), "project"),
    ]:
        for f in glob.glob(pat):
            add(f, src)

    # 2. Plugin-provided skills, read from the Claude Code manifest when present
    #    (authoritative — points at the specific installed version). Fall back to
    #    globbing the cache if the manifest is missing or unreadable.
    manifest_path = os.path.join(home, ".claude", "plugins", "installed_plugins.json")
    try:
        with open(manifest_path) as f:
            manifest = json.load(f)
        for _slug, installs in (manifest.get("plugins") or {}).items():
            for inst in installs or []:
                install_path = inst.get("installPath")
                scope = "project" if inst.get("scope") == "project" else "global"
                if not install_path:
                    continue
                for f in glob.glob(os.path.join(install_path, "skills", "*", "SKILL.md")):
                    add(f, scope)
    except (OSError, json.JSONDecodeError):
        # Fallback: glob the cache directly
        for f in glob.glob(os.path.join(home, ".claude", "plugins", "cache", "*", "*", "*", "skills", "*", "SKILL.md")):
            add(f, "global")

    # 3. Project-level plugin installs (rare, but supported)
    for f in glob.glob(os.path.join(cwd, ".claude", "plugins", "*", "*", "skills", "*", "SKILL.md")):
        add(f, "project")

    return out

def collect_mcp():
    out = []
    # MCP servers live in settings.json under "mcpServers" (user-level and project-level).
    for scope, path in [
        ("global",  os.path.join(home, ".claude", "settings.json")),
        ("project", os.path.join(cwd, ".claude", "settings.json")),
        ("project", os.path.join(cwd, ".claude", "settings.local.json")),
    ]:
        if not os.path.isfile(path):
            continue
        try:
            with open(path) as f:
                settings = json.load(f)
        except (OSError, json.JSONDecodeError):
            continue
        servers = settings.get("mcpServers") or {}
        if not isinstance(servers, dict):
            continue
        for name, cfg in servers.items():
            if not isinstance(cfg, dict):
                continue
            stype = cfg.get("type") or ("http" if cfg.get("url") else "stdio")
            cmd = cfg.get("command")
            if isinstance(cfg.get("args"), list) and cmd:
                cmd = " ".join([cmd] + [str(a) for a in cfg["args"]])
            out.append({
                "name": name,
                "type": stype,
                "command": cmd,
                "source": scope,
            })
    return out

payload = {
    "hostname": os.environ.get("HOSTNAME_VAL") or "unknown",
    "os": os.environ.get("OS_VAL") or "unknown",
    "claude_version": os.environ.get("CC_VERSION") or "unknown",
    "cwd": cwd,
    "machine_id": os.environ.get("MACHINE_ID") or "",
    "installed_skills": collect_skills(),
    "installed_mcp_servers": collect_mcp(),
}
print(json.dumps(payload))
PYEOF
)

HEADERS=(-H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json")
if [ -n "$MACHINE_ID" ]; then
  HEADERS+=(-H "X-Machine-Id: $MACHINE_ID")
fi

curl -s --max-time 10 -X POST "https://www.agentkeeper.dev/api/v1/claude-code/checkin" \
  "${HEADERS[@]}" \
  -d "$BODY" 2>/dev/null
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

Command preflight hooks installed to ~/.claude/settings.json
Restart Claude Code to activate hooks.
Dashboard: https://www.agentkeeper.dev/dashboard
```

**If `REPO_HOOKS_DETECTED`** was printed by Step 5, add this note:
```
Note: This repo also has AgentKeeper hooks in its local settings.
You may see duplicate events in this repo — this is harmless.
```

**If expired** (output is `EXPIRED`), display:
```
Code expired. Run /agentkeeper:connect again.

Having trouble? You can also paste an API key manually from:
  https://www.agentkeeper.dev/settings#api-keys
```

**If timed out** (output is `TIMEOUT`), display:
```
Timed out waiting for approval. Run /agentkeeper:connect to try again.

Having trouble? You can also paste an API key manually from:
  https://www.agentkeeper.dev/settings#api-keys
```

## Step 7: Configure OTLP Telemetry (when --enable-telemetry flag is passed OR org has otlp_enabled)

1. Detect the user's shell from $SHELL:
   - /bin/zsh or /usr/bin/zsh → ~/.zshrc
   - /bin/bash or /usr/bin/bash → ~/.bashrc
   - /usr/bin/fish → ~/.config/fish/config.fish

2. Generate the OTEL export block using the API key from step 3:

   For bash/zsh:
   ```bash
   # >>> agentkeeper-telemetry >>>
   export CLAUDE_CODE_ENABLE_TELEMETRY=1
   export OTEL_LOGS_EXPORTER=otlp
   export OTEL_METRICS_EXPORTER=otlp
   export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
   export OTEL_EXPORTER_OTLP_ENDPOINT=https://www.agentkeeper.dev/api/v1/otlp
   export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer {API_KEY}"
   export OTEL_LOG_TOOL_DETAILS=1
   export OTEL_LOG_USER_PROMPTS=0
   export OTEL_RESOURCE_ATTRIBUTES="host.name=$(scutil --get LocalHostName 2>/dev/null || hostname -s | tr ' ' '_')"
   # <<< agentkeeper-telemetry <<<
   ```

   For fish shell, use `set -gx` instead of `export`:
   ```fish
   # >>> agentkeeper-telemetry >>>
   set -gx CLAUDE_CODE_ENABLE_TELEMETRY 1
   set -gx OTEL_LOGS_EXPORTER otlp
   set -gx OTEL_METRICS_EXPORTER otlp
   set -gx OTEL_EXPORTER_OTLP_PROTOCOL http/protobuf
   set -gx OTEL_EXPORTER_OTLP_ENDPOINT https://www.agentkeeper.dev/api/v1/otlp
   set -gx OTEL_EXPORTER_OTLP_HEADERS "Authorization=Bearer {API_KEY}"
   set -gx OTEL_LOG_TOOL_DETAILS 1
   set -gx OTEL_LOG_USER_PROMPTS 0
   set -gx OTEL_RESOURCE_ATTRIBUTES "host.name=$(scutil --get LocalHostName 2>/dev/null || hostname -s | tr ' ' '_')"
   # <<< agentkeeper-telemetry <<<
   ```

3. Check if the guard block `# >>> agentkeeper-telemetry >>>` already exists in the rc file:
   - If yes: replace the entire block between guards (inclusive) with the new content
   - If no: append the block to the end of the rc file

   Use this bash command to write idempotently:
   ```bash
   RC_FILE="[detected rc file path]"
   API_KEY="[api key from step 3]"

   BLOCK="# >>> agentkeeper-telemetry >>>\nexport CLAUDE_CODE_ENABLE_TELEMETRY=1\nexport OTEL_LOGS_EXPORTER=otlp\nexport OTEL_METRICS_EXPORTER=otlp\nexport OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf\nexport OTEL_EXPORTER_OTLP_ENDPOINT=https://www.agentkeeper.dev/api/v1/otlp\nexport OTEL_EXPORTER_OTLP_HEADERS=\"Authorization=Bearer $API_KEY\"\nexport OTEL_LOG_TOOL_DETAILS=1\nexport OTEL_LOG_USER_PROMPTS=0\nexport OTEL_RESOURCE_ATTRIBUTES=\"host.name=\$(scutil --get LocalHostName 2>/dev/null || hostname -s | tr ' ' '_')\"\n# <<< agentkeeper-telemetry <<<"

   if grep -q '# >>> agentkeeper-telemetry >>>' "$RC_FILE" 2>/dev/null; then
     # Replace existing block
     python3 -c "
   import re, sys
   content = open('$RC_FILE').read()
   block = '''$BLOCK'''
   new_content = re.sub(
     r'# >>> agentkeeper-telemetry >>>.*?# <<< agentkeeper-telemetry <<<',
     block,
     content,
     flags=re.DOTALL
   )
   open('$RC_FILE', 'w').write(new_content)
   print('TELEMETRY_UPDATED')
   "
   else
     printf '\n%b\n' "$BLOCK" >> "$RC_FILE"
     echo "TELEMETRY_WRITTEN"
   fi
   ```

4. Tell the user:
   ```
   Telemetry configured in {rc_file}. Restart your terminal or run:
     source {rc_file}
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
