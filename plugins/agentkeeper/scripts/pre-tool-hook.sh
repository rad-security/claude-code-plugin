#!/usr/bin/env bash
# AgentKeeper Cowork hook dispatcher.
# Reads raw Cowork hook JSON from stdin, forwards it to AgentKeeper evaluate,
# and always fails open when local parsing, marker writes, or curl fail.

set -euo pipefail

PLUGIN_ROOT="${AGENTKEEPER_SCRIPTS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"

# Source shared libraries.
source "${PLUGIN_ROOT}/scripts/lib/json-helpers.sh" 2>/dev/null || \
  source "${PLUGIN_ROOT}/lib/json-helpers.sh" 2>/dev/null || true
source "${PLUGIN_ROOT}/scripts/lib/cowork-json.sh" 2>/dev/null || \
  source "${PLUGIN_ROOT}/lib/cowork-json.sh" 2>/dev/null || true
source "${PLUGIN_ROOT}/scripts/lib/cowork-mounts.sh" 2>/dev/null || \
  source "${PLUGIN_ROOT}/lib/cowork-mounts.sh" 2>/dev/null || true
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

STATE_DIR="${HOME}/.agentkeeper"
HOOK_MARKER="${STATE_DIR}/cowork-hook-last-run.json"
EVALUATE_MARKER="${STATE_DIR}/cowork-evaluate-last-run.json"
CHECKIN_MARKER="${STATE_DIR}/cowork-checkin-last-at"
EXCEPTION_LAUNCH_MARKER="${STATE_DIR}/cowork-exception-launch-last-run.json"

record_exception_launch() {
  local status="$1"
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  chmod 700 "$STATE_DIR" 2>/dev/null || true
  printf '{"last_run_at":"%s","status":"%s"}\n' \
    "$(cowork_iso_now)" "$(cowork_json_escape "$status")" \
    > "${EXCEPTION_LAUNCH_MARKER}.tmp.$$" 2>/dev/null &&
    mv "${EXCEPTION_LAUNCH_MARKER}.tmp.$$" "$EXCEPTION_LAUNCH_MARKER" 2>/dev/null || true
}

trap 'emit_allow; exit 0' ERR

INPUT="$(cat 2>/dev/null || true)"
agentkeeper_load_runtime_identity 2>/dev/null || true
if [ -z "$INPUT" ]; then
  emit_allow
  exit 0
fi

json_field() {
  local payload="$1"
  local field="$2"
  printf '%s' "$payload" | cowork_json_string_value "$field" 2>/dev/null || true
}

hook_event_name() {
  local value
  value="$(json_field "$INPUT" "hook_event_name")"
  [ -n "$value" ] || value="$(json_field "$INPUT" "hookEventName")"
  [ -n "$value" ] || value="$(json_field "$INPUT" "event_name")"
  [ -n "$value" ] || value="$(json_field "$INPUT" "eventName")"
  if [ -z "$value" ]; then
    case "$(json_field "$INPUT" "tool_name")" in
      UserPrompt|UserPromptSubmit) value="UserPromptSubmit" ;;
    esac
  fi
  printf '%s' "${value:-PreToolUse}"
}

normalized_tool_name() {
  local payload="$1"
  local event_name="$2"
  local value
  value="$(json_field "$payload" "tool_name")"
  [ -n "$value" ] || value="$(json_field "$payload" "name")"
  [ -n "$value" ] || value="$(json_field "$payload" "server_name")"
  if [ -z "$value" ] && [ "$event_name" = "UserPromptSubmit" ]; then
    value="UserPrompt"
  fi
  printf '%s' "$value"
}

payload_session_id() {
  local payload="$1"
  local value
  value="$(json_field "$payload" "session_id")"
  [ -n "$value" ] || value="$(json_field "$payload" "sessionId")"
  printf '%s' "$value"
}

record_hook_invocation() {
  local event_name="$1"
  local tool_name="$2"
  local session_id="$3"
  local server_name has_tool_input has_params has_prompt self_test_json

  mkdir -p "$STATE_DIR" 2>/dev/null || true
  chmod 700 "$STATE_DIR" 2>/dev/null || true

  server_name="$(json_field "$INPUT" "server_name")"
  has_tool_input=false
  has_params=false
  has_prompt=false
  printf '%s' "$INPUT" | grep -q '"tool_input"[[:space:]]*:' 2>/dev/null && has_tool_input=true
  printf '%s' "$INPUT" | grep -q '"params"[[:space:]]*:' 2>/dev/null && has_params=true
  printf '%s' "$INPUT" | grep -q '"prompt"[[:space:]]*:' 2>/dev/null && has_prompt=true

  self_test_json=""
  if [ -n "${AGENTKEEPER_COWORK_SELF_TEST:-}" ]; then
    self_test_json=',"self_test":true,"self_test_source":"'"$(cowork_json_escape "$AGENTKEEPER_COWORK_SELF_TEST")"'"'
  fi

  {
    printf '{'
    printf '"parse_ok":true'
    printf ',"last_run_at":"%s"' "$(cowork_iso_now)"
    printf ',"hook_event_name":"%s"' "$(cowork_json_escape "$event_name")"
    [ -n "$tool_name" ] && printf ',"tool_name":"%s"' "$(cowork_json_escape "$tool_name")"
    [ -n "$server_name" ] && printf ',"server_name":"%s"' "$(cowork_json_escape "$server_name")"
    [ -n "$session_id" ] && printf ',"session_id":"%s"' "$(cowork_json_escape "$session_id")"
    printf ',"has_tool_input":%s' "$has_tool_input"
    printf ',"has_params":%s' "$has_params"
    printf ',"has_prompt":%s' "$has_prompt"
    printf '%s' "$self_test_json"
    printf '}\n'
  } > "${HOOK_MARKER}.tmp.$$" 2>/dev/null && mv "${HOOK_MARKER}.tmp.$$" "$HOOK_MARKER" 2>/dev/null || true
}

record_cowork_evaluate_result() {
  local hook_event="$1"
  local tool_name="$2"
  local session_id="$3"
  local http_status="$4"
  local response_size="$5"
  local self_test_json=""

  mkdir -p "$STATE_DIR" 2>/dev/null || true
  chmod 700 "$STATE_DIR" 2>/dev/null || true

  if [ -n "${AGENTKEEPER_COWORK_SELF_TEST:-}" ]; then
    self_test_json=',"self_test":true,"self_test_source":"'"$(cowork_json_escape "$AGENTKEEPER_COWORK_SELF_TEST")"'"'
  fi

  {
    printf '{'
    printf '"last_run_at":"%s"' "$(cowork_iso_now)"
    [ -n "$hook_event" ] && printf ',"hook_event_name":"%s"' "$(cowork_json_escape "$hook_event")"
    [ -n "$tool_name" ] && printf ',"tool_name":"%s"' "$(cowork_json_escape "$tool_name")"
    [ -n "$session_id" ] && printf ',"session_id":"%s"' "$(cowork_json_escape "$session_id")"
    printf ',"http_status":"%s"' "$(cowork_json_escape "$http_status")"
    printf ',"response_size":%s' "${response_size:-0}"
    printf '%s' "$self_test_json"
    printf '}\n'
  } > "${EVALUATE_MARKER}.tmp.$$" 2>/dev/null && mv "${EVALUATE_MARKER}.tmp.$$" "$EVALUATE_MARKER" 2>/dev/null || true
}

collect_cowork_inventory_json() {
  printf '{}'
}

post_cowork_checkin() {
  local api_key="$1"
  local hostname_val machine_id install_method mdm_provider mdm_computer_name mdm_deployment_id public_key
  local platform os_version stamp payload inventory_json

  stamp="$(date -u +%Y%m%d%H 2>/dev/null || date +%Y%m%d%H 2>/dev/null || printf '')"
  if [ -n "$stamp" ] && [ -f "$CHECKIN_MARKER" ] && [ "$(cat "$CHECKIN_MARKER" 2>/dev/null || true)" = "$stamp" ]; then
    return 0
  fi

  hostname_val="$(get_agentkeeper_hostname 2>/dev/null || scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'unknown')"
  machine_id="$(get_machine_id 2>/dev/null || true)"
  install_method="${AGENTKEEPER_INSTALL_METHOD:-$(read_agentkeeper_install_context_value install_method 2>/dev/null || true)}"
  mdm_provider="${AGENTKEEPER_MDM_PROVIDER:-$(read_agentkeeper_install_context_value mdm_provider 2>/dev/null || true)}"
  mdm_computer_name="${AGENTKEEPER_MDM_COMPUTER_NAME:-$(read_agentkeeper_install_context_value mdm_computer_name 2>/dev/null || true)}"
  mdm_deployment_id="${AGENTKEEPER_MDM_DEPLOYMENT_ID:-$(read_agentkeeper_install_context_value mdm_deployment_id 2>/dev/null || true)}"
  public_key="$(agentkeeper_public_key_b64 2>/dev/null || true)"
  inventory_json="$(collect_cowork_inventory_json)"

  case "$(uname -s)" in
    Darwin) platform="darwin"; os_version="$(sw_vers -productVersion 2>/dev/null || true)" ;;
    Linux) platform="linux"; os_version="$(uname -r 2>/dev/null || true)" ;;
    *) platform="unknown"; os_version="" ;;
  esac

  payload='{"source":"cowork_desktop_posture","hostname":"'"$(cowork_json_escape "$hostname_val")"'","platform":"'"$(cowork_json_escape "$platform")"'","os_version":"'"$(cowork_json_escape "$os_version")"'","agent_version":"cowork-hook","os_username":"'"$(cowork_json_escape "${USER:-unknown}")"'","score":100,"grade":"A","checks":[{"status":"PASS","check_name":"Cowork hook check-in","detail":"AgentKeeper Cowork hook reached the AgentKeeper API.","category":"runtime_state","severity":"info","source":"cowork_desktop_posture"}],"raw_report":{"source":"cowork_desktop_posture","checkin":"cowork-hook","plugin":"cowork-guardrail@agentkeeper","inventory":'"${inventory_json:-{}}"',"install_context":{"install_method":"'"$(cowork_json_escape "${install_method:-cowork-hook}")"'","mdm_provider":"'"$(cowork_json_escape "$mdm_provider")"'","mdm_computer_name":"'"$(cowork_json_escape "$mdm_computer_name")"'","mdm_deployment_id":"'"$(cowork_json_escape "$mdm_deployment_id")"'","public_key":"'"$(cowork_json_escape "$public_key")"'"}}'
  if [ -n "$machine_id" ]; then
    payload="${payload},\"machine_id\":\"$(cowork_json_escape "$machine_id")\""
  fi
  payload="${payload}}"

  printf '%s' "$payload" | curl -sS --max-time 6 \
    -X POST "${API_BASE_URL}/api/v1/scans" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${api_key}" \
    -d @- >/dev/null 2>&1 || true

  [ -n "$stamp" ] && printf '%s' "$stamp" > "$CHECKIN_MARKER" 2>/dev/null || true
}

post_cowork_evaluate_diagnostic() {
  local api_key="$1"
  local hook_event="$2"
  local tool_name="$3"
  local http_status="$4"
  local response_size="$5"
  local hostname_val machine_id platform os_version payload

  hostname_val="$(get_agentkeeper_hostname 2>/dev/null || scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'unknown')"
  machine_id="$(get_machine_id 2>/dev/null || true)"
  case "$(uname -s)" in
    Darwin) platform="darwin"; os_version="$(sw_vers -productVersion 2>/dev/null || true)" ;;
    Linux) platform="linux"; os_version="$(uname -r 2>/dev/null || true)" ;;
    *) platform="unknown"; os_version="" ;;
  esac

  payload='{"source":"cowork_desktop_posture","hostname":"'"$(cowork_json_escape "$hostname_val")"'","platform":"'"$(cowork_json_escape "$platform")"'","os_version":"'"$(cowork_json_escape "$os_version")"'","agent_version":"cowork-hook","os_username":"'"$(cowork_json_escape "${USER:-unknown}")"'","score":100,"grade":"A","checks":[{"status":"PASS","check_name":"Cowork evaluate request","detail":"Cowork hook sent an evaluate request to AgentKeeper.","category":"runtime_state","severity":"info","source":"cowork_desktop_posture"}],"raw_report":{"source":"cowork_desktop_posture","checkin":"cowork-evaluate","plugin":"cowork-guardrail@agentkeeper","hook_event_name":"'"$(cowork_json_escape "$hook_event")"'","tool_name":"'"$(cowork_json_escape "$tool_name")"'","http_status":"'"$(cowork_json_escape "$http_status")"'","response_size":'"${response_size:-0}"'}}'
  if [ -n "$machine_id" ]; then
    payload="${payload},\"machine_id\":\"$(cowork_json_escape "$machine_id")\""
  fi
  payload="${payload}}"

  printf '%s' "$payload" | curl -sS --max-time 6 \
    -X POST "${API_BASE_URL}/api/v1/scans" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${api_key}" \
    -d @- >/dev/null 2>&1 || true
}

find_detect_script() {
  local detect_script="${PLUGIN_ROOT}/scripts/local-detect.sh"
  if [ ! -x "$detect_script" ]; then
    detect_script="${PLUGIN_ROOT}/local-detect.sh"
  fi
  [ -x "$detect_script" ] && printf '%s' "$detect_script"
}

local_hook_type_for_event() {
  case "$1" in
    UserPromptSubmit) printf 'prompt' ;;
    *) printf 'pre_tool' ;;
  esac
}

run_local_detection_payload() {
  local payload="$1"
  local event_name="$2"
  local detect_script hook_type

  detect_script="$(find_detect_script)"
  [ -n "$detect_script" ] || return 0
  hook_type="$(local_hook_type_for_event "$event_name")"
  printf '%s' "$payload" | "$detect_script" "$hook_type" 2>/dev/null || true
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
  local event_name="$1"
  local pattern="$2"
  local description="$3"
  local default_mode="$4"
  local mode

  mode="$(config_mode "$default_mode")"
  if [ "$mode" = "block" ]; then
    emit_deny "$event_name" "Blocked by AgentKeeper: ${pattern} detected"
  else
    emit_warn "$event_name" "$pattern" "$description"
  fi
}

response_string_value() {
  local payload="$1"
  local field="$2"
  printf '%s' "$payload" | sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\\([^\"\\\\]*\\)\".*/\\1/p" | head -1
}

prompt_block_response() {
  local reason="$1"
  local escaped
  escaped="$(cowork_json_escape "${reason:-AgentKeeper blocked Claude Cowork for this organization.}")"
  printf '{"decision":"block","reason":"%s","systemMessage":"%s","suppressOriginalPrompt":true,"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","suppressOriginalPrompt":true}}\n' "$escaped" "$escaped"
}

prompt_warn_response() {
  local message="$1"
  local escaped
  escaped="$(cowork_json_escape "$message")"
  printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"%s"}}\n' "$escaped" "$escaped"
}

pretool_block_response() {
  local reason="$1"
  local escaped
  escaped="$(cowork_json_escape "${reason:-AgentKeeper blocked Claude Cowork for this organization.}")"
  printf '{"decision":"block","reason":"%s","systemMessage":"%s","hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$escaped" "$escaped" "$escaped"
}

exception_request_url() {
  local response="$1"
  local candidate
  candidate="$(response_string_value "$response" "exceptionRequestUrl")"
  case "$candidate" in
    http://*/request-exception/*\?token=*|https://*/request-exception/*\?token=*) printf '%s' "$candidate" ;;
  esac
}

open_exception_request() {
  local response="$1"
  local url platform open_command
  case "${AGENTKEEPER_OPEN_EXCEPTION_LINK:-${AGENTKEEPER_COWORK_OPEN_EXCEPTION_LINK:-1}}" in
    0|false|FALSE|no|NO) record_exception_launch "disabled"; return 0 ;;
  esac
  url="$(exception_request_url "$response")"
  [ -n "$url" ] || return 0
  open_command="${AGENTKEEPER_OPEN_EXCEPTION_COMMAND:-${AGENTKEEPER_COWORK_OPEN_COMMAND:-}}"
  if [ -n "$open_command" ]; then
    if [ -x "$open_command" ]; then
      ("$open_command" "$url" || true) </dev/null >/dev/null 2>&1 &
      record_exception_launch "queued"
    else
      record_exception_launch "failed"
    fi
    return 0
  fi
  platform="$(uname -s 2>/dev/null || true)"
  case "$platform" in
    Darwin)
      if [ -x /usr/bin/open ]; then
        (/usr/bin/open "$url" || true) </dev/null >/dev/null 2>&1 &
        record_exception_launch "queued"
      else
        record_exception_launch "failed"
      fi
      ;;
    Linux)
      if command -v xdg-open >/dev/null 2>&1; then
        (xdg-open "$url" || true) </dev/null >/dev/null 2>&1 &
        record_exception_launch "queued"
      else
        record_exception_launch "failed"
      fi
      ;;
    *) record_exception_launch "unsupported" ;;
  esac
}

format_cowork_api_response() {
  local response="$1"
  local event_name="$2"
  local reason additional_context decision permission_decision

  reason="$(response_string_value "$response" "reason")"
  additional_context="$(response_string_value "$response" "additionalContext")"
  permission_decision="$(response_string_value "$response" "permissionDecision")"
  decision="$(response_string_value "$response" "decision")"

  if [ "$event_name" = "UserPromptSubmit" ]; then
    if [ "$decision" = "block" ] || [ "$decision" = "deny" ]; then
      prompt_block_response "${reason:-$additional_context}"
      return 0
    fi
    if [ "$permission_decision" = "deny" ]; then
      prompt_block_response "$(response_string_value "$response" "permissionDecisionReason")"
      return 0
    fi
    case "$additional_context" in
      "Blocked by AgentKeeper:"*|"AgentKeeper blocked"*)
        prompt_block_response "$additional_context"
        return 0
        ;;
    esac
    if [ -n "$additional_context" ]; then
      prompt_warn_response "$additional_context"
      return 0
    fi
    printf '%s\n' "$response"
    return 0
  fi

  if [ "$decision" = "block" ] || [ "$decision" = "deny" ]; then
    pretool_block_response "${reason:-$additional_context}"
    return 0
  fi
  printf '%s\n' "$response"
}

add_local_detection_payload() {
  printf '%s' "$1"
}

ORIGINAL_HOOK_EVENT="$(hook_event_name)"
TOOL_NAME="$(normalized_tool_name "$INPUT" "$ORIGINAL_HOOK_EVENT")"
SESSION_ID="$(payload_session_id "$INPUT")"
record_hook_invocation "$ORIGINAL_HOOK_EVENT" "$TOOL_NAME" "$SESSION_ID"

if [ "${AGENTKEEPER_SKIP_CONFLICT_CHECK:-}" != "1" ] && has_agentkeeper_http_hooks; then
  emit_allow
  exit 0
fi

LOCAL_DETECTION="$(run_local_detection_payload "$INPUT" "$ORIGINAL_HOOK_EVENT")"
LOCAL_PATTERN=""
LOCAL_SEVERITY=""
LOCAL_DESCRIPTION=""
if [ -n "$LOCAL_DETECTION" ]; then
  LOCAL_PATTERN=$(printf '%s' "$LOCAL_DETECTION" | cut -f1)
  LOCAL_SEVERITY=$(printf '%s' "$LOCAL_DETECTION" | cut -f2)
  LOCAL_DESCRIPTION=$(printf '%s' "$LOCAL_DETECTION" | cut -f3)
fi

API_KEY="$(resolve_api_key)" || true

if [ -n "$API_KEY" ]; then
  HOSTNAME_VAL=$(get_agentkeeper_hostname 2>/dev/null || scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'unknown')
  MACHINE_ID=$(get_machine_id 2>/dev/null || true)
  RUNTIME_USER_HINT=$(agentkeeper_runtime_user_hint 2>/dev/null || true)
  RUNTIME_USER_EMAIL=$(agentkeeper_runtime_user_email 2>/dev/null || true)
  INSTALL_METHOD="${AGENTKEEPER_INSTALL_METHOD:-$(read_agentkeeper_install_context_value install_method 2>/dev/null || true)}"
  MDM_PROVIDER="${AGENTKEEPER_MDM_PROVIDER:-$(read_agentkeeper_install_context_value mdm_provider 2>/dev/null || true)}"
  MDM_COMPUTER_NAME="${AGENTKEEPER_MDM_COMPUTER_NAME:-$(read_agentkeeper_install_context_value mdm_computer_name 2>/dev/null || true)}"
  MDM_DEPLOYMENT_ID="${AGENTKEEPER_MDM_DEPLOYMENT_ID:-$(read_agentkeeper_install_context_value mdm_deployment_id 2>/dev/null || true)}"
  API_BASE_URL="${AGENTKEEPER_API_URL:-https://www.agentkeeper.dev}"
  API_BASE_URL="${API_BASE_URL%/}"
  API_TOOL="${AGENTKEEPER_API_TOOL:-cowork}"
  if [ "$API_TOOL" = "claude-code" ]; then
    EVALUATE_URL="${API_BASE_URL}/api/v1/claude-code/evaluate"
  else
    EVALUATE_URL="${API_BASE_URL}/api/v1/evaluate?tool=${API_TOOL}"
  fi

  OUTBOUND_INPUT="$INPUT"
  if [ -n "$LOCAL_DETECTION" ]; then
    OUTBOUND_INPUT="$(add_local_detection_payload "$INPUT" "$LOCAL_PATTERN" "$LOCAL_SEVERITY" "$LOCAL_DESCRIPTION" "$ORIGINAL_HOOK_EVENT")"
  fi
  OUTBOUND_INPUT="$(agentkeeper_enrich_json_payload "$OUTBOUND_INPUT" 2>/dev/null || printf '%s' "$OUTBOUND_INPUT")"
  if [ "$ORIGINAL_HOOK_EVENT" = "PreToolUse" ] && [ -n "$SESSION_ID" ]; then
    OUTBOUND_INPUT="$(cowork_enrich_mounts_payload "$OUTBOUND_INPUT" "$SESSION_ID" 2>/dev/null || printf '%s' "$OUTBOUND_INPUT")"
  fi

  SIGNED_TS=""
  SIGNED_SIG=""
  if agentkeeper_has_keypair 2>/dev/null; then
    SIGNED_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
    SIGNED_SIG=$(printf '%s%s' "$SIGNED_TS" "$OUTBOUND_INPUT" | agentkeeper_sign 2>/dev/null) || SIGNED_SIG=""
  fi

  RESPONSE_FILE="$(mktemp "${TMPDIR:-/tmp}/agentkeeper-response.XXXXXX" 2>/dev/null || printf '/tmp/agentkeeper-response.%s' "$$")"
  HTTP_STATUS="000"
  if [ -n "$SIGNED_SIG" ]; then
    HTTP_STATUS="$(printf '%s' "$OUTBOUND_INPUT" | curl -sS --max-time "${AGENTKEEPER_TIMEOUT:-4}" \
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
      -H "X-User-Hint: ${RUNTIME_USER_HINT}" \
      -H "X-User-Email: ${RUNTIME_USER_EMAIL}" \
      -H "X-Console-User: ${USER:-unknown}" \
      -d @- 2>/dev/null || printf '000')"
  else
    HTTP_STATUS="$(printf '%s' "$OUTBOUND_INPUT" | curl -sS --max-time "${AGENTKEEPER_TIMEOUT:-4}" \
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
      -H "X-User-Hint: ${RUNTIME_USER_HINT}" \
      -H "X-User-Email: ${RUNTIME_USER_EMAIL}" \
      -d @- 2>/dev/null || printf '000')"
  fi
  RESPONSE="$(cat "$RESPONSE_FILE" 2>/dev/null || true)"
  rm -f "$RESPONSE_FILE" 2>/dev/null || true
  RESPONSE_SIZE="${#RESPONSE}"

  record_cowork_evaluate_result "$ORIGINAL_HOOK_EVENT" "$TOOL_NAME" "$SESSION_ID" "$HTTP_STATUS" "$RESPONSE_SIZE"
  post_cowork_checkin "$API_KEY" &
  post_cowork_evaluate_diagnostic "$API_KEY" "$ORIGINAL_HOOK_EVENT" "$TOOL_NAME" "$HTTP_STATUS" "$RESPONSE_SIZE" &

  if [ -z "$RESPONSE" ] || ! printf '%s' "$HTTP_STATUS" | grep -q '^2'; then
    if [ -n "$LOCAL_DETECTION" ]; then
      emit_detection_response "$ORIGINAL_HOOK_EVENT" "$LOCAL_PATTERN" "$LOCAL_DESCRIPTION" "warn"
      exit 0
    fi
    emit_allow
    exit 0
  fi

  format_cowork_api_response "$RESPONSE" "$ORIGINAL_HOOK_EVENT"
  open_exception_request "$RESPONSE"
  exit 0
fi

if [ -z "$(find_detect_script)" ]; then
  emit_allow
  exit 0
fi

if [ -z "$LOCAL_DETECTION" ]; then
  emit_allow
  exit 0
fi

MODE="$(config_mode "warn")"
if [ "$MODE" = "block" ]; then
  emit_deny "$ORIGINAL_HOOK_EVENT" "Blocked by AgentKeeper: ${LOCAL_PATTERN} detected"
else
  NUDGE_TEXT=""
  increment_blocks
  BLOCK_COUNT=$(get_block_count)

  if should_nudge; then
    if [ "$BLOCK_COUNT" -eq 1 ]; then
      NUDGE_TEXT=$(get_nudge_text "first_block" "$LOCAL_PATTERN")
    elif [ "$BLOCK_COUNT" -ge 5 ] && [ $(( BLOCK_COUNT % 5 )) -eq 0 ]; then
      NUDGE_TEXT=$(get_nudge_text "fifth_block" "$LOCAL_PATTERN")
    fi
    [ -n "$NUDGE_TEXT" ] && record_nudge
  fi

  if [ -n "$NUDGE_TEXT" ]; then
    emit_warn "$ORIGINAL_HOOK_EVENT" "$LOCAL_PATTERN" "${LOCAL_DESCRIPTION}. ${NUDGE_TEXT}"
  else
    emit_warn "$ORIGINAL_HOOK_EVENT" "$LOCAL_PATTERN" "$LOCAL_DESCRIPTION"
  fi
fi

exit 0
