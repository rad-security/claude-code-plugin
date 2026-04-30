#!/usr/bin/env bash
# gemini-adapter.sh — Gemini CLI hook adapter for AgentKeeper
#
# Gemini CLI hooks are command hooks. This adapter normalizes BeforeTool /
# AfterTool / prompt payloads to AgentKeeper's canonical hook shape and
# returns Gemini-friendly exit codes:
#   0 = allow
#   2 = block, with stderr containing the reason
#
# Always fail-open on unexpected errors.

set -euo pipefail

export AGENTKEEPER_IDE="gemini"
export AGENTKEEPER_API_TOOL="gemini"
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

trap 'exit 0' ERR

INPUT=$(cat 2>/dev/null) || true
if [ -z "$INPUT" ]; then
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
if [ -z "$HOOK_EVENT" ]; then
  HOOK_EVENT=$(printf '%s' "$INPUT" | read_field "event")
fi
TOOL_ID=$(printf '%s' "$INPUT" | read_field "tool_call_id")
if [ -z "$TOOL_ID" ]; then
  TOOL_ID=$(printf '%s' "$INPUT" | read_field "call_id")
fi

if [ -n "$TOOL_ID" ] && [ -n "$HOOK_EVENT" ] && type is_duplicate >/dev/null 2>&1; then
  if is_duplicate "gemini:${HOOK_EVENT}:${TOOL_ID}" 2>/dev/null; then
    exit 0
  fi
fi

normalize_input() {
  local raw="$1"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$raw" | python3 -c '
import json, sys

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

try:
    d = json.load(sys.stdin)
except Exception:
    print("{}")
    sys.exit(0)

fn = as_dict(d.get("functionCall") or d.get("function_call"))
tc = as_dict(d.get("toolCall") or d.get("tool_call"))
req = as_dict(d.get("request"))
raw_name = (
    d.get("tool_name") or d.get("toolName") or d.get("name") or
    fn.get("name") or tc.get("name") or req.get("name") or ""
)
args = parse_args(
    d.get("tool_args", d.get("toolArgs", d.get("tool_input", d.get("toolInput", d.get("arguments", d.get("args", d.get("params", fn.get("args", fn.get("arguments", tc.get("args", tc.get("arguments", req.get("args", req.get("arguments")))))))))))))
)

name_map = {
    "run_shell_command": "Bash",
    "shell": "Bash",
    "bash": "Bash",
    "read_file": "Read",
    "read_many_files": "Glob",
    "write_file": "Write",
    "replace": "Edit",
    "edit": "Edit",
    "glob": "Glob",
    "grep": "Grep",
    "search_file_content": "Grep",
    "web_fetch": "WebFetch",
    "webfetch": "WebFetch",
    "web_search": "WebSearch",
    "websearch": "WebSearch",
}
server = d.get("mcp_server_name")
mcp_tool = d.get("mcp_tool_name")
if isinstance(raw_name, str) and raw_name.startswith("mcp__"):
    tool_name = raw_name
elif isinstance(server, str) and isinstance(mcp_tool, str):
    tool_name = f"mcp__{server}__{mcp_tool}"
else:
    tool_name = name_map.get(str(raw_name), str(raw_name))

if "file_path" not in args:
    path = first_str(args, ["path", "filePath", "absolute_path", "absolutePath", "target_path", "targetPath"])
    if not path and isinstance(args.get("paths"), list) and args["paths"] and isinstance(args["paths"][0], str):
        path = args["paths"][0]
    if path:
        args["file_path"] = path

if tool_name == "Bash" and "command" not in args:
    cmd = first_str(args, ["cmd", "shell_command", "shellCommand", "command_line", "commandLine", "raw"])
    if cmd:
        args["command"] = cmd

if tool_name == "Glob" and "pattern" not in args:
    pattern = first_str(args, ["glob", "path", "file_path"])
    if pattern:
        args["pattern"] = pattern

out = {
    "tool_name": tool_name,
    "tool_input": args,
    "hook_event_name": d.get("hook_event_name") or d.get("hookEventName") or d.get("event") or "",
}
for src, dst in [
    ("tool_call_id", "tool_use_id"),
    ("call_id", "tool_use_id"),
    ("session_id", "session_id"),
    ("sessionId", "session_id"),
    ("cwd", "cwd"),
    ("prompt", "prompt"),
]:
    if src in d and d[src] is not None:
        out[dst] = d[src]
if "prompt" in out:
    out.setdefault("tool_input", {})["prompt"] = out["prompt"]
for key in ["tool_output", "toolOutput", "tool_response", "toolResponse", "result", "output", "response"]:
    if key in d:
        out["tool_output"] = d[key]
        break

print(json.dumps(out))
' 2>/dev/null
  else
    printf '%s' "$raw"
  fi
}

response_reason() {
  local response="$1"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$response" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
hso = d.get("hookSpecificOutput") if isinstance(d, dict) else None
if isinstance(hso, dict):
    print(hso.get("permissionDecisionReason") or hso.get("additionalContext") or "")
else:
    print(d.get("reason") or d.get("systemMessage") or "")
' 2>/dev/null
  fi
}

is_block_response() {
  local response="$1"
  printf '%s' "$response" | grep -Eq '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"|"decision"[[:space:]]*:[[:space:]]*"block"|"decision"[[:space:]]*:[[:space:]]*"deny"'
}

START_MS=$(_now_ms)
NORMALIZED=$(normalize_input "$INPUT")
RESPONSE=""
IS_POST=false

case "$HOOK_EVENT" in
  BeforeTool|PreToolUse|before_tool|pre_tool)
    RESPONSE=$(printf '%s' "$NORMALIZED" | "${PLUGIN_ROOT}/scripts/pre-tool-hook.sh" 2>/dev/null) || true
    ;;
  AfterTool|PostToolUse|after_tool|post_tool)
    IS_POST=true
    RESPONSE=$(printf '%s' "$NORMALIZED" | "${PLUGIN_ROOT}/scripts/post-tool-hook.sh" 2>/dev/null) || true
    ;;
  BeforeAgent|UserPromptSubmit|user_prompt_submit|prompt)
    RESPONSE=$(printf '%s' "$NORMALIZED" | "${PLUGIN_ROOT}/scripts/prompt-hook.sh" 2>/dev/null) || true
    ;;
  Stop)
    exit 0
    ;;
  *)
    if printf '%s' "$NORMALIZED" | grep -q '"tool_name"[[:space:]]*:[[:space:]]*"[^"]' 2>/dev/null; then
      RESPONSE=$(printf '%s' "$NORMALIZED" | "${PLUGIN_ROOT}/scripts/pre-tool-hook.sh" 2>/dev/null) || true
    else
      exit 0
    fi
    ;;
esac

END_MS=$(_now_ms)
DETECT_MS=$((END_MS - START_MS))

if [ "$IS_POST" = true ]; then
  debug_log "gemini" "${HOOK_EVENT:-unknown}" "1.0.0" "$DETECT_MS" "0" "allow" "audit" "0" 2>/dev/null || true
  exit 0
fi

if is_block_response "$RESPONSE"; then
  REASON=$(response_reason "$RESPONSE")
  [ -n "$REASON" ] || REASON="Blocked by AgentKeeper security policy"
  printf '%s\n' "$REASON" >&2
  debug_log "gemini" "${HOOK_EVENT:-unknown}" "1.0.0" "$DETECT_MS" "0" "deny" "blocked" "2" 2>/dev/null || true
  exit 2
fi

if printf '%s' "$RESPONSE" | grep -Eq '"additionalContext"|"systemMessage"|"decision"[[:space:]]*:[[:space:]]*"warn"' 2>/dev/null; then
  REASON=$(response_reason "$RESPONSE")
  [ -n "$REASON" ] && printf '%s\n' "$REASON" >&2
  debug_log "gemini" "${HOOK_EVENT:-unknown}" "1.0.0" "$DETECT_MS" "0" "warn" "warned" "0" 2>/dev/null || true
else
  debug_log "gemini" "${HOOK_EVENT:-unknown}" "1.0.0" "$DETECT_MS" "0" "allow" "allowed" "0" 2>/dev/null || true
fi

exit 0
