#!/usr/bin/env bash
# session-start.sh — SessionStart hook dispatcher
# Initializes session state and optionally checks in with the API.
# ALWAYS fail-open: any error → output {} and exit 0.

set -euo pipefail

PLUGIN_ROOT="${AGENTKEEPER_SCRIPTS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"

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
source "${PLUGIN_ROOT}/scripts/lib/runtime-identity.sh" 2>/dev/null || \
  source "${PLUGIN_ROOT}/lib/runtime-identity.sh" 2>/dev/null || true
source "${PLUGIN_ROOT}/scripts/lib/device-key.sh" 2>/dev/null || \
  source "${PLUGIN_ROOT}/lib/device-key.sh" 2>/dev/null || true

# Fail-open trap
trap 'emit_allow; exit 0' ERR

# Read all of stdin (SessionStart provides session info)
INPUT=$(cat 2>/dev/null) || true
agentkeeper_load_runtime_identity 2>/dev/null || true

# Command SessionStart is authoritative for inventory and visible startup
# messages. Some Claude Code versions ignore HTTP SessionStart hooks while
# still executing command hooks, so do not defer here merely because an HTTP
# SessionStart is configured.

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
  HOSTNAME_VAL=$(get_agentkeeper_hostname 2>/dev/null || scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'unknown')
  MACHINE_ID=$(get_machine_id)
  RUNTIME_USER_HINT=$(agentkeeper_runtime_user_hint 2>/dev/null || true)
  RUNTIME_USER_EMAIL=$(agentkeeper_runtime_user_email 2>/dev/null || true)
  INSTALL_METHOD="${AGENTKEEPER_INSTALL_METHOD:-$(read_agentkeeper_install_context_value install_method 2>/dev/null || true)}"
  MDM_PROVIDER="${AGENTKEEPER_MDM_PROVIDER:-$(read_agentkeeper_install_context_value mdm_provider 2>/dev/null || true)}"
  MDM_COMPUTER_NAME="${AGENTKEEPER_MDM_COMPUTER_NAME:-$(read_agentkeeper_install_context_value mdm_computer_name 2>/dev/null || true)}"
  MDM_DEPLOYMENT_ID="${AGENTKEEPER_MDM_DEPLOYMENT_ID:-$(read_agentkeeper_install_context_value mdm_deployment_id 2>/dev/null || true)}"
  API_BASE_URL="${AGENTKEEPER_API_URL:-$(agentkeeper_api_base_from_http_hooks 2>/dev/null || true)}"
  API_BASE_URL="${API_BASE_URL:-https://www.agentkeeper.dev}"
  API_BASE_URL="${API_BASE_URL%/}"
  SOURCE_TOOL="${AGENTKEEPER_API_TOOL:-${AGENTKEEPER_IDE:-claude_code}}"

  # Check script integrity on session start
  if [ -f "${PLUGIN_ROOT}/scripts/lib/integrity.sh" ] || [ -f "${PLUGIN_ROOT}/lib/integrity.sh" ]; then
    source "${PLUGIN_ROOT}/scripts/lib/integrity.sh" 2>/dev/null || \
      source "${PLUGIN_ROOT}/lib/integrity.sh" 2>/dev/null || true
    TAMPERED=$(check_integrity "${PLUGIN_ROOT}" 2>/dev/null) || true
    if [ -n "$TAMPERED" ] && [ -n "$API_KEY" ]; then
      RUNTIME_CONTEXT_FIELDS="$(AGENTKEEPER_RUNTIME_SKIP_MACHINE_ID_FIELD=1 agentkeeper_runtime_identity_fields 2>/dev/null || true)"
      TAMPER_BODY=$(printf '{"hostname":"%s","detection_layer":"%s","verdict":"warned","severity":"high","security_level":"strict","pattern_name":"script_tamper","input_hash":"","confidence":100,"context":{"tampered_files":"%s"%s}}' \
        "$(_json_escape "$HOSTNAME_VAL")" "${AGENTKEEPER_IDE:-claude_code}" "$(_json_escape "$TAMPERED")" "$RUNTIME_CONTEXT_FIELDS")
      # Additive: sign the request body when a device keypair exists.
      # Plan 1 dark-launch — server records but does not yet enforce.
      TAMPER_SHIELD_BODY="{\"events\":[$TAMPER_BODY]}"
      SIGNED_TS_TAMPER=""
      SIGNED_SIG_TAMPER=""
      if agentkeeper_has_keypair 2>/dev/null; then
        TS_TAMPER=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        SIG_TAMPER=$(printf '%s%s' "$TS_TAMPER" "$TAMPER_SHIELD_BODY" | agentkeeper_sign 2>/dev/null) || SIG_TAMPER=""
        if [ -n "$SIG_TAMPER" ]; then
          SIGNED_TS_TAMPER="$TS_TAMPER"
          SIGNED_SIG_TAMPER="$SIG_TAMPER"
        fi
      fi
      if [ -n "$SIGNED_SIG_TAMPER" ]; then
        curl -sS --max-time 4 -X POST "${API_BASE_URL}/api/v1/shield/events" \
          -H "Content-Type: application/json" \
          -H "Authorization: Bearer ${API_KEY}" \
          -H "X-Machine-Id: ${MACHINE_ID}" \
          -H "X-Timestamp: ${SIGNED_TS_TAMPER}" \
          -H "X-Device-Signature: ${SIGNED_SIG_TAMPER}" \
          -H "X-Hostname: ${HOSTNAME_VAL}" \
          -H "X-User-Hint: ${RUNTIME_USER_HINT}" \
          -H "X-User-Email: ${RUNTIME_USER_EMAIL}" \
          -H "X-Console-User: ${USER:-unknown}" \
          -d "$TAMPER_SHIELD_BODY" >/dev/null 2>&1 &
      else
        curl -sS --max-time 4 -X POST "${API_BASE_URL}/api/v1/shield/events" \
          -H "Content-Type: application/json" \
          -H "Authorization: Bearer ${API_KEY}" \
          -H "X-Machine-Id: ${MACHINE_ID}" \
          -H "X-Hostname: ${HOSTNAME_VAL}" \
          -H "X-User-Hint: ${RUNTIME_USER_HINT}" \
          -H "X-User-Email: ${RUNTIME_USER_EMAIL}" \
          -d "$TAMPER_SHIELD_BODY" >/dev/null 2>&1 &
      fi
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
import json, sys
try:
    d = json.load(sys.stdin)
    cwd = str(d.get('cwd', ''))
    if cwd and '\n' not in cwd and '\r' not in cwd and len(cwd) < 2048:
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

  GIT_REMOTE_VAL=""
  if [ -n "$CWD_VAL" ] && command -v git &>/dev/null; then
    GIT_REMOTE_VAL=$(git -C "$CWD_VAL" remote get-url origin 2>/dev/null || true)
  fi

  EXTRA_FIELDS=""
  if [ -n "$MACHINE_ID" ]; then
    EXTRA_FIELDS=$(printf '%s,"machine_id":"%s"' "$EXTRA_FIELDS" "$(_json_escape "$MACHINE_ID")")
  fi
  if [ -n "$SOURCE_TOOL" ]; then
    EXTRA_FIELDS=$(printf '%s,"source_tool":"%s"' "$EXTRA_FIELDS" "$(_json_escape "$SOURCE_TOOL")")
  fi
  if [ -n "$SESSION_ID" ]; then
    EXTRA_FIELDS=$(printf '%s,"session_id":"%s"' "$EXTRA_FIELDS" "$(_json_escape "$SESSION_ID")")
  fi
  if [ -n "$CWD_VAL" ]; then
    EXTRA_FIELDS=$(printf '%s,"cwd":"%s"' "$EXTRA_FIELDS" "$(_json_escape "$CWD_VAL")")
  fi
  if [ -n "$GIT_REMOTE_VAL" ]; then
    EXTRA_FIELDS=$(printf '%s,"git_remote_url":"%s"' "$EXTRA_FIELDS" "$(_json_escape "$GIT_REMOTE_VAL")")
  fi

  # Inventory Lite: read-only local scan without requiring the MCP gateway
  # binary. Produces installed_skills, installed_mcp_servers, and
  # installed_plugins fields for the checkin payload.
  INVENTORY_FIELDS=""
  INVENTORY_SCRIPT="${PLUGIN_ROOT}/scripts/lib/inventory-lite.py"
  if [ ! -f "$INVENTORY_SCRIPT" ]; then
    INVENTORY_SCRIPT="${PLUGIN_ROOT}/lib/inventory-lite.py"
  fi
  if command -v python3 &>/dev/null && [ -f "$INVENTORY_SCRIPT" ]; then
    INVENTORY_FIELDS=$(python3 "$INVENTORY_SCRIPT" --home "$HOME" --cwd "${CWD_VAL:-}" --format fields 2>/dev/null || true)
  fi
  if [ -n "$INVENTORY_FIELDS" ]; then
    EXTRA_FIELDS="${EXTRA_FIELDS},${INVENTORY_FIELDS}"
  fi
  IDENTITY_FIELDS="$(AGENTKEEPER_RUNTIME_SKIP_MACHINE_ID_FIELD=1 agentkeeper_runtime_identity_fields 2>/dev/null || true)"
  EXTRA_FIELDS="${EXTRA_FIELDS}${IDENTITY_FIELDS}"

  CHECKIN_BODY=$(printf '{"hostname":"%s","os":"%s","claude_version":"%s"%s}' \
    "$(_json_escape "$HOSTNAME_VAL")" \
    "$(_json_escape "$OS_VAL")" \
    "$(_json_escape "$CLAUDE_VERSION")" \
    "$EXTRA_FIELDS")
  CHECKIN_BODY="$(agentkeeper_enrich_json_payload "$CHECKIN_BODY" 2>/dev/null || printf '%s' "$CHECKIN_BODY")"

  # Additive: sign the request body when a device keypair exists.
  # Plan 1 dark-launch — server records but does not yet enforce.
  SIGNED_TS=""
  SIGNED_SIG=""
  if agentkeeper_has_keypair 2>/dev/null; then
    TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    SIG=$(printf '%s%s' "$TS" "$CHECKIN_BODY" | agentkeeper_sign 2>/dev/null) || SIG=""
    if [ -n "$SIG" ]; then
      SIGNED_TS="$TS"
      SIGNED_SIG="$SIG"
    fi
  fi
  if [ -n "$SIGNED_SIG" ]; then
    RESPONSE=$(printf '%s' "$CHECKIN_BODY" | curl -sS --max-time 10 \
      -X POST "${API_BASE_URL}/api/v1/claude-code/checkin" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${API_KEY}" \
      -H "X-Machine-Id: ${MACHINE_ID}" \
      -H "X-AgentKeeper-Install-Method: ${INSTALL_METHOD}" \
      -H "X-AgentKeeper-MDM-Provider: ${MDM_PROVIDER}" \
      -H "X-AgentKeeper-MDM-Computer-Name: ${MDM_COMPUTER_NAME}" \
      -H "X-AgentKeeper-MDM-Deployment-Id: ${MDM_DEPLOYMENT_ID}" \
      -H "X-AgentKeeper-Source-Tool: ${SOURCE_TOOL}" \
      -H "X-Timestamp: ${SIGNED_TS}" \
      -H "X-Device-Signature: ${SIGNED_SIG}" \
      -H "X-Hostname: ${HOSTNAME_VAL}" \
      -H "X-User-Hint: ${RUNTIME_USER_HINT}" \
      -H "X-User-Email: ${RUNTIME_USER_EMAIL}" \
      -H "X-Console-User: ${USER:-unknown}" \
      -d @- 2>/dev/null) || true
  else
    RESPONSE=$(printf '%s' "$CHECKIN_BODY" | curl -sS --max-time 10 \
      -X POST "${API_BASE_URL}/api/v1/claude-code/checkin" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${API_KEY}" \
      -H "X-Machine-Id: ${MACHINE_ID}" \
      -H "X-AgentKeeper-Install-Method: ${INSTALL_METHOD}" \
      -H "X-AgentKeeper-MDM-Provider: ${MDM_PROVIDER}" \
      -H "X-AgentKeeper-MDM-Computer-Name: ${MDM_COMPUTER_NAME}" \
      -H "X-AgentKeeper-MDM-Deployment-Id: ${MDM_DEPLOYMENT_ID}" \
      -H "X-AgentKeeper-Source-Tool: ${SOURCE_TOOL}" \
      -H "X-Hostname: ${HOSTNAME_VAL}" \
      -H "X-User-Hint: ${RUNTIME_USER_HINT}" \
      -H "X-User-Email: ${RUNTIME_USER_EMAIL}" \
      -d @- 2>/dev/null) || true
  fi

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
