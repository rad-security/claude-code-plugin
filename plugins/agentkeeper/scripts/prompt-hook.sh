#!/usr/bin/env bash
# prompt-hook.sh — UserPromptSubmit dispatcher (local or API)
# Reads user prompt JSON from stdin, runs detection, outputs hook response to stdout.
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

# Read all of stdin
INPUT=$(cat 2>/dev/null) || true
if command -v agentkeeper_load_runtime_identity >/dev/null 2>&1; then
  agentkeeper_load_runtime_identity 2>/dev/null || true
fi

# If stdin was empty, nothing to evaluate
if [ -z "$INPUT" ]; then
  emit_allow
  exit 0
fi

# If HTTP-based AgentKeeper hooks are already active, defer
if [ "${AGENTKEEPER_SKIP_CONFLICT_CHECK:-}" != "1" ] && has_agentkeeper_http_hooks; then
  emit_allow
  exit 0
fi

find_detect_script() {
  local detect_script="${PLUGIN_ROOT}/scripts/local-detect.sh"
  if [ ! -x "$detect_script" ]; then
    detect_script="${PLUGIN_ROOT}/local-detect.sh"
  fi
  if [ -x "$detect_script" ]; then
    printf '%s' "$detect_script"
  fi
}

run_local_detection() {
  local detect_script

  detect_script="$(find_detect_script)"
  if [ -z "$detect_script" ]; then
    return 0
  fi

  printf '%s' "$INPUT" | "$detect_script" "prompt" 2>/dev/null || true
}

config_mode() {
  local default_mode="$1"
  local data_dir config_file configured_mode

  data_dir=$(get_data_dir)
  config_file="${data_dir}/config.json"
  if [ -f "$config_file" ]; then
    configured_mode=$(grep -Eo '"mode"[[:space:]]*:[[:space:]]*"[^"]*"' "$config_file" 2>/dev/null | head -1 | grep -Eo '"[^"]*"$' | tr -d '"') || true
    if [ "$configured_mode" = "block" ] || [ "$configured_mode" = "warn" ]; then
      printf '%s' "$configured_mode"
      return 0
    fi
  fi

  printf '%s' "$default_mode"
}

emit_detection_response() {
  local pattern="$1"
  local description="$2"
  local default_mode="$3"
  local mode

  mode="$(config_mode "$default_mode")"
  if [ "$mode" = "block" ]; then
    emit_deny "UserPromptSubmit" "Blocked by AgentKeeper: ${pattern} detected"
  else
    emit_warn "UserPromptSubmit" "$pattern" "$description"
  fi
}

add_local_detection_payload() {
  local pattern="$1"
  local severity="$2"
  local description="$3"

  printf '%s' "$INPUT" | python3 - "$pattern" "$severity" "$description" <<'PY_EOF' 2>/dev/null || printf '%s' "$INPUT"
import json
import sys

pattern, severity, description = sys.argv[1:4]
try:
    data = json.loads(sys.stdin.read())
except Exception:
    raise SystemExit(1)

if not isinstance(data, dict):
    raise SystemExit(1)

data["agentkeeper_local_detection"] = {
    "pattern_name": pattern,
    "severity": severity,
    "description": description,
    "source": "local-detect",
    "hook_event_name": "UserPromptSubmit",
}
print(json.dumps(data, separators=(",", ":")))
PY_EOF
}

LOCAL_DETECTION="$(run_local_detection)"
LOCAL_PATTERN=""
LOCAL_SEVERITY=""
LOCAL_DESCRIPTION=""
if [ -n "$LOCAL_DETECTION" ]; then
  LOCAL_PATTERN=$(printf '%s' "$LOCAL_DETECTION" | cut -f1)
  LOCAL_SEVERITY=$(printf '%s' "$LOCAL_DETECTION" | cut -f2)
  LOCAL_DESCRIPTION=$(printf '%s' "$LOCAL_DETECTION" | cut -f3)
fi

# Resolve API key
API_KEY=$(resolve_api_key) || true

if [ -n "$API_KEY" ]; then
  # ---- API mode: forward to evaluate endpoint ----
  HOSTNAME_VAL=$(get_agentkeeper_hostname 2>/dev/null || scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'unknown')
  MACHINE_ID=$(get_machine_id)
  INSTALL_METHOD="${AGENTKEEPER_INSTALL_METHOD:-$(read_agentkeeper_install_context_value install_method 2>/dev/null || true)}"
  MDM_PROVIDER="${AGENTKEEPER_MDM_PROVIDER:-$(read_agentkeeper_install_context_value mdm_provider 2>/dev/null || true)}"
  MDM_COMPUTER_NAME="${AGENTKEEPER_MDM_COMPUTER_NAME:-$(read_agentkeeper_install_context_value mdm_computer_name 2>/dev/null || true)}"
  MDM_DEPLOYMENT_ID="${AGENTKEEPER_MDM_DEPLOYMENT_ID:-$(read_agentkeeper_install_context_value mdm_deployment_id 2>/dev/null || true)}"
  API_BASE_URL="${AGENTKEEPER_API_URL:-https://www.agentkeeper.dev}"
  API_BASE_URL="${API_BASE_URL%/}"
  API_TOOL="${AGENTKEEPER_API_TOOL:-claude-code}"
  if [ "$API_TOOL" = "claude-code" ]; then
    EVALUATE_URL="${API_BASE_URL}/api/v1/claude-code/evaluate"
  else
    EVALUATE_URL="${API_BASE_URL}/api/v1/evaluate?tool=${API_TOOL}"
  fi
  OUTBOUND_INPUT="$INPUT"
  if [ -n "$LOCAL_DETECTION" ]; then
    OUTBOUND_INPUT="$(add_local_detection_payload "$LOCAL_PATTERN" "$LOCAL_SEVERITY" "$LOCAL_DESCRIPTION")"
  fi
  OUTBOUND_INPUT="$(agentkeeper_enrich_json_payload "$OUTBOUND_INPUT" 2>/dev/null || printf '%s' "$OUTBOUND_INPUT")"
  # Additive: sign the request body when a device keypair exists.
  # Plan 1 dark-launch — server records but does not yet enforce.
  SIGNED_TS=""
  SIGNED_SIG=""
  if agentkeeper_has_keypair 2>/dev/null; then
    TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    SIG=$(printf '%s%s' "$TS" "$OUTBOUND_INPUT" | agentkeeper_sign 2>/dev/null) || SIG=""
    if [ -n "$SIG" ]; then
      SIGNED_TS="$TS"
      SIGNED_SIG="$SIG"
    fi
  fi
  RESPONSE_FILE="$(mktemp "${TMPDIR:-/tmp}/agentkeeper-prompt-response.XXXXXX" 2>/dev/null || printf '/tmp/agentkeeper-prompt-response.%s' "$$")"
  HTTP_STATUS="000"
  if [ -n "$SIGNED_SIG" ]; then
    HTTP_STATUS="$(printf '%s' "$OUTBOUND_INPUT" | curl -sS --max-time 4 \
      -o "$RESPONSE_FILE" -w "%{http_code}" \
      -X POST "$EVALUATE_URL" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${API_KEY}" \
      -H "X-Hostname: ${HOSTNAME_VAL}" \
      -H "X-Machine-Id: ${MACHINE_ID}" \
      -H "X-AgentKeeper-Install-Method: ${INSTALL_METHOD}" \
      -H "X-AgentKeeper-MDM-Provider: ${MDM_PROVIDER}" \
      -H "X-AgentKeeper-MDM-Computer-Name: ${MDM_COMPUTER_NAME}" \
      -H "X-AgentKeeper-MDM-Deployment-Id: ${MDM_DEPLOYMENT_ID}" \
      -H "X-Timestamp: ${SIGNED_TS}" \
      -H "X-Device-Signature: ${SIGNED_SIG}" \
      -H "X-Console-User: ${USER:-unknown}" \
      -d @- 2>/dev/null || printf '000')"
  else
    HTTP_STATUS="$(printf '%s' "$OUTBOUND_INPUT" | curl -sS --max-time 4 \
      -o "$RESPONSE_FILE" -w "%{http_code}" \
      -X POST "$EVALUATE_URL" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${API_KEY}" \
      -H "X-Hostname: ${HOSTNAME_VAL}" \
      -H "X-Machine-Id: ${MACHINE_ID}" \
      -H "X-AgentKeeper-Install-Method: ${INSTALL_METHOD}" \
      -H "X-AgentKeeper-MDM-Provider: ${MDM_PROVIDER}" \
      -H "X-AgentKeeper-MDM-Computer-Name: ${MDM_COMPUTER_NAME}" \
      -H "X-AgentKeeper-MDM-Deployment-Id: ${MDM_DEPLOYMENT_ID}" \
      -d @- 2>/dev/null || printf '000')"
  fi
  RESPONSE="$(cat "$RESPONSE_FILE" 2>/dev/null || true)"
  rm -f "$RESPONSE_FILE" 2>/dev/null || true

  if [ -z "$RESPONSE" ] || ! printf '%s' "$HTTP_STATUS" | grep -q '^2'; then
    if [ -n "$LOCAL_DETECTION" ]; then
      emit_detection_response "$LOCAL_PATTERN" "$LOCAL_DESCRIPTION" "warn"
      exit 0
    fi
    emit_allow
    exit 0
  fi

  printf '%s\n' "$RESPONSE"
  exit 0
fi

# ---- Local mode: run bundled detection engine ----
if [ -z "$(find_detect_script)" ]; then
  emit_allow
  exit 0
fi

if [ -z "$LOCAL_DETECTION" ]; then
  emit_allow
  exit 0
fi

# Emit appropriate response
MODE="$(config_mode "warn")"
if [ "$MODE" = "block" ]; then
  emit_deny "UserPromptSubmit" "Blocked by AgentKeeper: ${LOCAL_PATTERN} detected"
else
  # Warn mode: build context message, possibly with nudge
  NUDGE_TEXT=""
  increment_blocks

  BLOCK_COUNT=$(get_block_count)

  if should_nudge; then
    if [ "$BLOCK_COUNT" -eq 1 ]; then
      NUDGE_TEXT=$(get_nudge_text "first_block" "$LOCAL_PATTERN")
    elif [ "$BLOCK_COUNT" -ge 5 ] && [ $(( BLOCK_COUNT % 5 )) -eq 0 ]; then
      NUDGE_TEXT=$(get_nudge_text "fifth_block" "$LOCAL_PATTERN")
    fi

    if [ -n "$NUDGE_TEXT" ]; then
      record_nudge
    fi
  fi

  if [ -n "$NUDGE_TEXT" ]; then
    emit_warn "UserPromptSubmit" "$LOCAL_PATTERN" "${LOCAL_DESCRIPTION}. ${NUDGE_TEXT}"
  else
    emit_warn "UserPromptSubmit" "$LOCAL_PATTERN" "$LOCAL_DESCRIPTION"
  fi
fi

exit 0
