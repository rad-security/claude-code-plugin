#!/usr/bin/env bash
# post-tool-hook.sh — PostToolUse audit dispatcher
# Logs tool usage to a session log file. Can NEVER deny (PostToolUse doesn't support deny).
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
source "${PLUGIN_ROOT}/scripts/lib/machine-id.sh" 2>/dev/null || \
  source "${PLUGIN_ROOT}/lib/machine-id.sh" 2>/dev/null || true

# Fail-open trap
trap 'emit_allow; exit 0' ERR

# Read all of stdin
INPUT=$(cat 2>/dev/null) || true

# If stdin was empty, nothing to log
if [ -z "$INPUT" ]; then
  emit_allow
  exit 0
fi

# If HTTP-based Clawkeeper hooks are already active, defer
if [ "${CLAWKEEPER_SKIP_CONFLICT_CHECK:-}" != "1" ] && has_clawkeeper_http_hooks; then
  emit_allow
  exit 0
fi

# Resolve API key
API_KEY=$(resolve_api_key) || true

if [ -n "$API_KEY" ]; then
  # ---- API mode: forward to audit endpoint ----
  HOSTNAME_VAL=$(scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || printf 'unknown')
  MACHINE_ID=$(get_machine_id)
  curl -s --max-time 4 \
    -X POST "https://clawkeeper.dev/api/v1/claude-code/audit" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "X-Hostname: ${HOSTNAME_VAL}" \
    -H "X-Machine-Id: ${MACHINE_ID}" \
    -d "$INPUT" >/dev/null 2>&1 || true

  # Always allow — audit is fire-and-forget
  emit_allow
  exit 0
fi

# ---- Local mode: append to session log ----
DATA_DIR=$(get_data_dir)
SESSION_DIR="${DATA_DIR}/sessions"
SESSION_LOG="${SESSION_DIR}/current.jsonl"

# Ensure sessions directory exists
if [ ! -d "$SESSION_DIR" ]; then
  mkdir -p "$SESSION_DIR" 2>/dev/null || true
fi

# Extract tool_name from input JSON (lightweight grep — no jq dependency)
TOOL_NAME=$(printf '%s' "$INPUT" | grep -Eo '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | grep -Eo '"[^"]*"$' | tr -d '"') || true

# Extract a summary from tool_input (first 200 chars of the command or content)
INPUT_SUMMARY=""

# Try to extract command (for Bash tool)
INPUT_SUMMARY=$(printf '%s' "$INPUT" | grep -Eo '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | grep -Eo '"[^"]*"$' | tr -d '"') || true

# If no command, try file_path (for Write/Read/Edit)
if [ -z "$INPUT_SUMMARY" ]; then
  INPUT_SUMMARY=$(printf '%s' "$INPUT" | grep -Eo '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | grep -Eo '"[^"]*"$' | tr -d '"') || true
fi

# If no file_path, try pattern (for Grep/Glob)
if [ -z "$INPUT_SUMMARY" ]; then
  INPUT_SUMMARY=$(printf '%s' "$INPUT" | grep -Eo '"pattern"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | grep -Eo '"[^"]*"$' | tr -d '"') || true
fi

# Truncate to 200 characters
if [ ${#INPUT_SUMMARY} -gt 200 ]; then
  INPUT_SUMMARY="${INPUT_SUMMARY:0:200}"
fi

# Get current timestamp
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Escape values for JSON
ESCAPED_TOOL=$(_json_escape "${TOOL_NAME:-unknown}")
ESCAPED_SUMMARY=$(_json_escape "$INPUT_SUMMARY")

# Write log line
printf '{"ts":"%s","tool":"%s","input_summary":"%s","detection":null}\n' \
  "$TS" "$ESCAPED_TOOL" "$ESCAPED_SUMMARY" \
  >> "$SESSION_LOG" 2>/dev/null || true

# PostToolUse always allows
emit_allow
exit 0
