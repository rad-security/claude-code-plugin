#!/usr/bin/env bash
# codex-adapter.sh — Codex hook adapter for AgentKeeper
#
# Normalizes Codex hook JSON to the AgentKeeper canonical hook shape, then
# calls the shared pre/post/prompt/session scripts. Always fail-open.

set -euo pipefail

export AGENTKEEPER_IDE="codex"
export AGENTKEEPER_API_TOOL="codex"
export AGENTKEEPER_SKIP_CONFLICT_CHECK=1
export CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA:-$HOME/.agentkeeper}"

ADAPTER_DIR="$(cd "$(dirname "$0")" && pwd)"
export AGENTKEEPER_SCRIPTS_DIR="${AGENTKEEPER_SCRIPTS_DIR:-$(cd "$ADAPTER_DIR/../.." && pwd)}"
PLUGIN_ROOT="$AGENTKEEPER_SCRIPTS_DIR"

source "${PLUGIN_ROOT}/scripts/lib/json-helpers.sh" 2>/dev/null || \
  source "${PLUGIN_ROOT}/lib/json-helpers.sh" 2>/dev/null || true
source "${PLUGIN_ROOT}/scripts/lib/dedup.sh" 2>/dev/null || \
  source "${PLUGIN_ROOT}/lib/dedup.sh" 2>/dev/null || true
source "${PLUGIN_ROOT}/scripts/lib/debug-log.sh" 2>/dev/null || \
  source "${PLUGIN_ROOT}/lib/debug-log.sh" 2>/dev/null || true

trap 'emit_allow; exit 0' ERR

INPUT=$(cat 2>/dev/null) || true
if [ -z "$INPUT" ]; then
  emit_allow
  exit 0
fi

_now_ms() {
  if command -v gdate >/dev/null 2>&1; then
    gdate +%s%3N
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.time()*1000))'
  else
    printf '%s000' "$(date +%s)"
  fi
}

read_field() {
  local field="$1"
  if command -v python3 >/dev/null 2>&1; then
    FIELD_NAME="$field" python3 -c '
import json, os, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
field = os.environ["FIELD_NAME"]
for key in [field, field.replace("_", ""), field[0].lower() + field[1:]]:
    value = d.get(key)
    if isinstance(value, str):
        print(value, end="")
        break
' 2>/dev/null
  fi
}

HOOK_EVENT=$(printf '%s' "$INPUT" | read_field "hook_event_name")
if [ -z "$HOOK_EVENT" ]; then
  HOOK_EVENT=$(printf '%s' "$INPUT" | read_field "hookEventName")
fi
TOOL_ID=$(printf '%s' "$INPUT" | read_field "tool_call_id")
if [ -z "$TOOL_ID" ]; then
  TOOL_ID=$(printf '%s' "$INPUT" | read_field "tool_use_id")
fi

if [ -n "$TOOL_ID" ] && [ -n "$HOOK_EVENT" ] && type is_duplicate >/dev/null 2>&1; then
  if is_duplicate "codex:${HOOK_EVENT}:${TOOL_ID}" 2>/dev/null; then
    emit_allow
    exit 0
  fi
fi

normalize_input() {
  local raw="$1"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$raw" | python3 -c '
import json, re, sys

def as_dict(v):
    return v if isinstance(v, dict) else {}

def parse_args(v):
    if isinstance(v, dict):
        return dict(v)
    if isinstance(v, str):
        try:
            parsed = json.loads(v)
            if isinstance(parsed, dict):
                return parsed
        except Exception:
            pass
        return {"raw": v}
    return {}

def first_str(obj, keys):
    for key in keys:
        value = obj.get(key)
        if isinstance(value, str) and value:
            return value
    return ""

def patch_path(text):
    if not isinstance(text, str):
        return ""
    match = re.search(r"^\*\*\* (?:Update|Add|Delete) File:\s*(.+)$", text, re.M)
    return match.group(1).strip() if match else ""

try:
    d = json.load(sys.stdin)
except Exception:
    print("{}")
    sys.exit(0)

tool_obj = as_dict(d.get("tool"))
raw_name = (
    d.get("tool_name") or d.get("toolName") or d.get("name") or
    tool_obj.get("name") or ""
)
args = parse_args(
    d.get("tool_input", d.get("toolInput", d.get("arguments", d.get("args", d.get("params", d.get("input", tool_obj.get("input")))))))
)

name_map = {
    "bash": "Bash",
    "shell": "Bash",
    "exec": "Bash",
    "exec_command": "Bash",
    "unified_exec": "Bash",
    "read": "Read",
    "read_file": "Read",
    "write": "Write",
    "write_file": "Write",
    "edit": "Edit",
    "apply_patch": "Edit",
    "grep": "Grep",
    "search": "Grep",
    "glob": "Glob",
    "list_files": "Glob",
    "web_fetch": "WebFetch",
    "webfetch": "WebFetch",
    "web_search": "WebSearch",
    "websearch": "WebSearch",
}
tool_name = raw_name if str(raw_name).startswith("mcp__") else name_map.get(str(raw_name), str(raw_name))

if "file_path" not in args:
    path = first_str(args, ["path", "filePath", "absolute_path", "absolutePath", "target_path", "targetPath"])
    if not path and tool_name == "Edit":
        path = patch_path(args.get("patch") or args.get("raw") or d.get("patch"))
    if path:
        args["file_path"] = path

if tool_name == "Bash" and "command" not in args:
    cmd = first_str(args, ["cmd", "shell_command", "shellCommand", "command_line", "commandLine", "raw"])
    if cmd:
        args["command"] = cmd

out = {
    "tool_name": tool_name,
    "tool_input": args,
    "hook_event_name": d.get("hook_event_name") or d.get("hookEventName") or "",
}
for src, dst in [
    ("tool_call_id", "tool_use_id"),
    ("tool_use_id", "tool_use_id"),
    ("session_id", "session_id"),
    ("sessionId", "session_id"),
    ("cwd", "cwd"),
    ("prompt", "prompt"),
]:
    if src in d and d[src] is not None:
        out[dst] = d[src]
if "prompt" in out:
    out.setdefault("tool_input", {})["prompt"] = out["prompt"]
if "tool_output" in d:
    out["tool_output"] = d["tool_output"]
elif "toolOutput" in d:
    out["tool_output"] = d["toolOutput"]
elif "result" in d:
    out["tool_output"] = d["result"]

print(json.dumps(out))
' 2>/dev/null
  else
    printf '%s' "$raw"
  fi
}

translate_response() {
  local response="$1"
  if [ -z "$response" ]; then
    emit_allow
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$response" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("{}")
    sys.exit(0)
hso = d.get("hookSpecificOutput")
if isinstance(hso, dict) and hso.get("permissionDecision") == "allow" and hso.get("additionalContext") and "systemMessage" not in d:
    d["systemMessage"] = hso["additionalContext"]
print(json.dumps(d))
' 2>/dev/null || printf '%s\n' "$response"
  else
    printf '%s\n' "$response"
  fi
}

START_MS=$(_now_ms)
NORMALIZED=$(normalize_input "$INPUT")
RESPONSE=""

case "$HOOK_EVENT" in
  PreToolUse|PermissionRequest)
    RESPONSE=$(printf '%s' "$NORMALIZED" | "${PLUGIN_ROOT}/scripts/pre-tool-hook.sh" 2>/dev/null) || true
    ;;
  PostToolUse)
    RESPONSE=$(printf '%s' "$NORMALIZED" | "${PLUGIN_ROOT}/scripts/post-tool-hook.sh" 2>/dev/null) || true
    ;;
  UserPromptSubmit)
    RESPONSE=$(printf '%s' "$NORMALIZED" | "${PLUGIN_ROOT}/scripts/prompt-hook.sh" 2>/dev/null) || true
    ;;
  SessionStart)
    RESPONSE=$(printf '%s' "$NORMALIZED" | "${PLUGIN_ROOT}/scripts/session-start.sh" 2>/dev/null) || true
    ;;
  Stop)
    emit_allow
    exit 0
    ;;
  *)
    # Some Codex builds omit the event name in command hooks; assume a
    # pre-tool check when a tool name exists, otherwise fail open.
    if printf '%s' "$NORMALIZED" | grep -q '"tool_name"[[:space:]]*:[[:space:]]*"[^"]' 2>/dev/null; then
      RESPONSE=$(printf '%s' "$NORMALIZED" | "${PLUGIN_ROOT}/scripts/pre-tool-hook.sh" 2>/dev/null) || true
    else
      emit_allow
      exit 0
    fi
    ;;
esac

END_MS=$(_now_ms)
DETECT_MS=$((END_MS - START_MS))

VERDICT="allow"
ENFORCEMENT="allow"
if printf '%s' "$RESPONSE" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"' 2>/dev/null; then
  VERDICT="deny"
  ENFORCEMENT="blocked"
elif printf '%s' "$RESPONSE" | grep -Eq '"additionalContext"|"systemMessage"' 2>/dev/null; then
  VERDICT="warn"
  ENFORCEMENT="warned"
fi
debug_log "codex" "${HOOK_EVENT:-unknown}" "1.0.0" "$DETECT_MS" "0" "$VERDICT" "$ENFORCEMENT" "0" 2>/dev/null || true

translate_response "$RESPONSE"
exit 0
