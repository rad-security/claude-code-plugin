#!/usr/bin/env bash
# session-start.sh — SessionStart hook dispatcher
# Initializes session state and optionally checks in with the API.
# ALWAYS fail-open: any error → output {} and exit 0.

set -euo pipefail

PLUGIN_ROOT="${CLAWKEEPER_SCRIPTS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"

# Source shared libraries
source "${PLUGIN_ROOT}/scripts/lib/json-helpers.sh" 2>/dev/null || \
  source "${PLUGIN_ROOT}/lib/json-helpers.sh" 2>/dev/null || true
source "${PLUGIN_ROOT}/scripts/lib/key-resolver.sh" 2>/dev/null || \
  source "${PLUGIN_ROOT}/lib/key-resolver.sh" 2>/dev/null || true
source "${PLUGIN_ROOT}/scripts/lib/conflict-check.sh" 2>/dev/null || \
  source "${PLUGIN_ROOT}/lib/conflict-check.sh" 2>/dev/null || true
source "${PLUGIN_ROOT}/scripts/lib/nudge.sh" 2>/dev/null || \
  source "${PLUGIN_ROOT}/lib/nudge.sh" 2>/dev/null || true
source "${PLUGIN_ROOT}/scripts/lib/machine-id.sh" 2>/dev/null || \
  source "${PLUGIN_ROOT}/lib/machine-id.sh" 2>/dev/null || true

# Fail-open trap
trap 'emit_allow; exit 0' ERR

# Read all of stdin (SessionStart provides session info)
INPUT=$(cat 2>/dev/null) || true

# If HTTP-based Clawkeeper hooks are already active, defer
if [ "${CLAWKEEPER_SKIP_CONFLICT_CHECK:-}" != "1" ] && has_clawkeeper_http_hooks; then
  emit_allow
  exit 0
fi

# ---- Initialize session ----
DATA_DIR=$(get_data_dir)
SESSION_DIR="${DATA_DIR}/sessions"

# Create sessions directory if needed
if [ ! -d "$SESSION_DIR" ]; then
  mkdir -p "$SESSION_DIR" 2>/dev/null || true
fi

# Truncate (reset) the current session log
: > "${SESSION_DIR}/current.jsonl" 2>/dev/null || true

# Reset session_nudged flag by ensuring state file exists with fresh session
_ensure_state

# Resolve API key
API_KEY=$(resolve_api_key) || true

if [ -n "$API_KEY" ]; then
  # ---- API mode: check in with the server ----
  HOSTNAME_VAL=$(scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || printf 'unknown')
  MACHINE_ID=$(get_machine_id)

  # Check script integrity on session start
  if [ -f "${PLUGIN_ROOT}/scripts/lib/integrity.sh" ] || [ -f "${PLUGIN_ROOT}/lib/integrity.sh" ]; then
    source "${PLUGIN_ROOT}/scripts/lib/integrity.sh" 2>/dev/null || \
      source "${PLUGIN_ROOT}/lib/integrity.sh" 2>/dev/null || true
    TAMPERED=$(check_integrity "${PLUGIN_ROOT}" 2>/dev/null) || true
    if [ -n "$TAMPERED" ] && [ -n "$API_KEY" ]; then
      TAMPER_BODY=$(printf '{"hostname":"%s","detection_layer":"%s","verdict":"warned","severity":"high","security_level":"strict","pattern_name":"script_tamper","input_hash":"","confidence":100,"context":{"tampered_files":"%s"}}' \
        "$(_json_escape "$HOSTNAME_VAL")" "${CLAWKEEPER_IDE:-claude_code}" "$(_json_escape "$TAMPERED")")
      curl -s --max-time 4 -X POST "https://clawkeeper.dev/api/v1/shield/events" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${API_KEY}" \
        -H "X-Machine-Id: ${MACHINE_ID}" \
        -d "{\"events\":[$TAMPER_BODY]}" >/dev/null 2>&1 &
    fi
  fi

  OS_VAL=$(uname -s 2>/dev/null || printf 'unknown')
  CLAUDE_VERSION="${CLAUDE_CODE_VERSION:-unknown}"

  # Extract session_id and cwd from Claude Code's native payload so the
  # server can link subsequent HTTP hook events back to this host.
  # Uses python3 for reliable JSON parsing with grep as fallback.
  SESSION_ID=""
  CWD_VAL=""
  if [ -n "$INPUT" ]; then
    if command -v python3 &>/dev/null; then
      SESSION_ID=$(printf '%s' "$INPUT" | python3 -c "
import json, sys, re
try:
    d = json.load(sys.stdin)
    sid = str(d.get('session_id', ''))
    if sid and re.fullmatch(r'[a-zA-Z0-9_-]+', sid):
        print(sid, end='')
except:
    pass
" 2>/dev/null) || true
      CWD_VAL=$(printf '%s' "$INPUT" | python3 -c "
import json, sys, re
try:
    d = json.load(sys.stdin)
    cwd = str(d.get('cwd', ''))
    if cwd and re.fullmatch(r'[a-zA-Z0-9_./ -]+', cwd):
        print(cwd, end='')
except:
    pass
" 2>/dev/null) || true
    fi
    if [ -z "$SESSION_ID" ]; then
      SESSION_ID=$(printf '%s' "$INPUT" | grep -Eo '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | grep -Eo '"[^"]*"$' | tr -d '"') || true
    fi
    if [ -z "$CWD_VAL" ]; then
      CWD_VAL=$(printf '%s' "$INPUT" | grep -Eo '"cwd"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | grep -Eo '"[^"]*"$' | tr -d '"') || true
    fi
  fi

  EXTRA_FIELDS=""
  if [ -n "$SESSION_ID" ]; then
    EXTRA_FIELDS=$(printf '%s,"session_id":"%s"' "$EXTRA_FIELDS" "$(_json_escape "$SESSION_ID")")
  fi
  if [ -n "$CWD_VAL" ]; then
    EXTRA_FIELDS=$(printf '%s,"cwd":"%s"' "$EXTRA_FIELDS" "$(_json_escape "$CWD_VAL")")
  fi

  # Scan installed agent skills. Mirrors the Python logic in
  # plugin/skills/connect/SKILL.md so we surface skills from all three
  # locations Claude Code can install them:
  #   1. ~/.claude/skills/*/SKILL.md      (hand-rolled global)
  #   2. <cwd>/.claude/skills/*/SKILL.md  (project-local)
  #   3. ~/.claude/plugins/...             (plugin-installed via /plugin install)
  # Most users have #3 exclusively; the previous bash-only scanner missed them.
  SKILL_ENTRIES=""
  if command -v python3 &>/dev/null; then
    SKILL_ENTRIES=$(python3 - "$HOME" "${CWD_VAL:-}" <<'PYEOF' 2>/dev/null || true
import glob, hashlib, json, os, sys
home = sys.argv[1] if len(sys.argv) > 1 else ""
cwd = sys.argv[2] if len(sys.argv) > 2 else ""

def read_preview(path):
    try:
        with open(path, "rb") as f:
            return f.read(300).decode("utf-8", errors="replace")
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
        return ""

out = []
seen = set()

def add(path, source, plugin=None):
    name = os.path.basename(os.path.dirname(path))
    key = (name, source)
    if key in seen:
        return
    seen.add(key)
    entry = {
        "name": name,
        "source": source,
        "preview": read_preview(path),
        "hash": sha256(path),
    }
    if plugin:
        entry["plugin"] = plugin
    out.append(entry)

# 1 + 2. Well-known standalone locations (not tied to a plugin)
patterns = [(os.path.join(home, ".claude", "skills", "*", "SKILL.md"), "global")]
if cwd:
    patterns.append((os.path.join(cwd, ".claude", "skills", "*", "SKILL.md"), "project"))
for pat, src in patterns:
    for f in glob.glob(pat):
        add(f, src)

# 3. Plugin-installed skills via the installed_plugins.json manifest
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
                add(f, scope, plugin=_slug)
except (OSError, json.JSONDecodeError):
    # Fallback: glob the cache directly. Plugin slug is the second-to-last
    # directory component of cache/<owner>/<repo>/<slug>/skills/<skill>/SKILL.md
    for f in glob.glob(os.path.join(home, ".claude", "plugins", "cache", "*", "*", "*", "skills", "*", "SKILL.md")):
        parts = f.split(os.sep)
        slug = parts[-4] if len(parts) >= 4 else None
        add(f, "global", plugin=slug)

# 4. Project-level plugin installs
if cwd:
    for f in glob.glob(os.path.join(cwd, ".claude", "plugins", "*", "*", "skills", "*", "SKILL.md")):
        parts = f.split(os.sep)
        slug = parts[-4] if len(parts) >= 4 else None
        add(f, "project", plugin=slug)

print(",".join(json.dumps(s) for s in out))
PYEOF
)
  fi
  if [ -n "$SKILL_ENTRIES" ]; then
    EXTRA_FIELDS="${EXTRA_FIELDS},\"installed_skills\":[$SKILL_ENTRIES]"
  fi

  # Scan installed MCP servers — read `mcpServers` from ~/.claude/settings.json
  # and <cwd>/.claude/settings.json / settings.local.json. Refreshes on every
  # SessionStart so new MCP servers surface without requiring /connect.
  MCP_ENTRIES=""
  if command -v python3 &>/dev/null; then
    MCP_ENTRIES=$(python3 - "$HOME" "${CWD_VAL:-}" <<'PYEOF' 2>/dev/null || true
import json, os, sys
home = sys.argv[1] if len(sys.argv) > 1 else ""
cwd = sys.argv[2] if len(sys.argv) > 2 else ""
out = []
scopes = [("global",  os.path.join(home, ".claude", "settings.json"))]
if cwd:
    scopes.append(("project", os.path.join(cwd, ".claude", "settings.json")))
    scopes.append(("project", os.path.join(cwd, ".claude", "settings.local.json")))
for scope, path in scopes:
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
print(",".join(json.dumps(s) for s in out))
PYEOF
)
  fi
  if [ -n "$MCP_ENTRIES" ]; then
    EXTRA_FIELDS="${EXTRA_FIELDS},\"installed_mcp_servers\":[$MCP_ENTRIES]"
  fi

  CHECKIN_BODY=$(printf '{"hostname":"%s","os":"%s","claude_version":"%s"%s}' \
    "$(_json_escape "$HOSTNAME_VAL")" \
    "$(_json_escape "$OS_VAL")" \
    "$(_json_escape "$CLAUDE_VERSION")" \
    "$EXTRA_FIELDS")

  RESPONSE=$(printf '%s' "$CHECKIN_BODY" | curl -s --max-time 10 --fail-with-body \
    -X POST "https://clawkeeper.dev/api/v1/claude-code/checkin" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "X-Machine-Id: ${MACHINE_ID}" \
    -d @- 2>/dev/null) || true

  # If the API returned context, pass it through; otherwise allow
  if [ -n "$RESPONSE" ]; then
    printf '%s\n' "$RESPONSE"
  else
    emit_allow
  fi
  exit 0
fi

# ---- Local mode: session start context ----
CONTEXT_PARTS=""

# Check if we should show a weekly nudge
if should_nudge; then
  WEEKLY_NUDGE=$(get_nudge_text "session_start" "")
  if [ -n "$WEEKLY_NUDGE" ]; then
    CONTEXT_PARTS="$WEEKLY_NUDGE"
    record_nudge
  fi
fi

if [ -n "$CONTEXT_PARTS" ]; then
  ESCAPED_CONTEXT=$(_json_escape "$CONTEXT_PARTS")
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' \
    "$ESCAPED_CONTEXT"
else
  emit_allow
fi

exit 0
