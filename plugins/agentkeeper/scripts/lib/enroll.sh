#!/usr/bin/env bash
# enroll.sh — Device-keypair enrollment orchestrator.
#
# Enrollment paths, in priority order:
#   1. MDM token  — /etc/agentkeeper/enrollment.json dropped by MDM profile
#   2. Device code — interactive browser login; prints a URL the user opens
#
# Admin-approved and mdm_inventory enrollment happen purely server-side; the
# plugin doesn't drive them from here.
#
# Sourced by the login skill (eventually) and by integration tests. No top-level
# execution — callers invoke `agentkeeper_enroll`.

set -euo pipefail

_AGENTKEEPER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$_AGENTKEEPER_LIB_DIR/device-key.sh"  # also brings in machine-id.sh + key-resolver.sh

AGENTKEEPER_API_URL_DEFAULT="https://www.agentkeeper.dev"
AGENTKEEPER_MDM_TOKEN_FILE_DEFAULT="/etc/agentkeeper/enrollment.json"

agentkeeper_api_url() { printf '%s' "${AGENTKEEPER_API_URL:-$AGENTKEEPER_API_URL_DEFAULT}"; }
agentkeeper_mdm_token_file() { printf '%s' "${AGENTKEEPER_MDM_TOKEN_FILE:-$AGENTKEEPER_MDM_TOKEN_FILE_DEFAULT}"; }
agentkeeper_cred_file() { printf '%s/credential.json' "$(get_data_dir)"; }

agentkeeper_ensure_keypair() {
  if agentkeeper_has_keypair; then
    agentkeeper_public_key_b64
  else
    agentkeeper_generate_keypair
  fi
}

# Try MDM-token enrollment. Returns 0 on success (credential written), 1 on any failure.
# Stderr gets a short diagnostic on failure; stdout is empty on failure.
agentkeeper_enroll_via_mdm_token() {
  local file
  file="$(agentkeeper_mdm_token_file)"
  [ -r "$file" ] || return 1

  local org_id token
  org_id="$(jq -r '.org_id // empty' "$file" 2>/dev/null)"
  token="$(jq -r '.token // empty' "$file" 2>/dev/null)"
  if [ -z "$org_id" ] || [ -z "$token" ]; then
    echo "agentkeeper_enroll: MDM token file missing org_id or token" >&2
    return 1
  fi

  local pub machine_id url resp http_code
  pub="$(agentkeeper_ensure_keypair)"
  machine_id="$(get_machine_id)"
  url="$(agentkeeper_api_url)/api/v1/plugin/enroll"

  resp="$(mktemp)"; trap 'rm -f "$resp"' RETURN
  http_code="$(curl -sS -o "$resp" -w '%{http_code}' -X POST "$url" \
    -H 'content-type: application/json' \
    -d "$(jq -n --arg bs mdm_token --arg pk "$pub" --arg mid "$machine_id" --arg oid "$org_id" --arg tok "$token" \
        '{binding_source:$bs, public_key:$pk, machine_id:$mid, org_id:$oid, mdm_token:$tok}')" )"

  if [ "$http_code" != "200" ]; then
    echo "agentkeeper_enroll: MDM enroll failed (http $http_code)" >&2
    head -c 500 "$resp" >&2
    echo >&2
    return 1
  fi

  install -m 0600 /dev/null "$(agentkeeper_cred_file)"
  cat "$resp" > "$(agentkeeper_cred_file)"
  chmod 0600 "$(agentkeeper_cred_file)"
}

# Interactive device-code enrollment. Prints a URL for the user to open.
# Polls until bound or expired. On success writes credential file and returns 0.
agentkeeper_enroll_via_device_code() {
  local api resp code verification_url poll_secs expires_at
  api="$(agentkeeper_api_url)"

  # 1. Request a code.
  resp="$(mktemp)"; trap 'rm -f "$resp"' RETURN
  if ! curl -sS -X POST "$api/api/v1/plugin/device-code/request" -o "$resp" -w '' --fail 2>/dev/null; then
    echo "agentkeeper_enroll: device-code request failed" >&2
    head -c 500 "$resp" >&2
    echo >&2
    return 1
  fi

  code="$(jq -r .code "$resp" 2>/dev/null)"
  verification_url="$(jq -r .verification_url "$resp" 2>/dev/null)"
  poll_secs="$(jq -r '.poll_interval_seconds // 2' "$resp" 2>/dev/null)"
  expires_at="$(jq -r .expires_at "$resp" 2>/dev/null)"

  if [ -z "$code" ] || [ "$code" = "null" ]; then
    echo "agentkeeper_enroll: malformed device-code response" >&2
    return 1
  fi

  echo
  echo "To enroll this device with AgentKeeper, open the following URL in your browser:"
  echo "  $verification_url"
  echo
  echo "Code: $code (expires $expires_at)"
  echo
  case "$(uname -s)" in
    Darwin) open "$verification_url" >/dev/null 2>&1 || true ;;
    Linux)  command -v xdg-open >/dev/null 2>&1 && xdg-open "$verification_url" >/dev/null 2>&1 || true ;;
  esac

  # 2. Poll until bound or expired. Hard cap at 10 minutes wall clock.
  local deadline now status org_id directory_user_id poll_resp
  deadline=$(( $(date +%s) + 600 ))
  poll_resp="$(mktemp)"; trap 'rm -f "$resp" "$poll_resp"' RETURN
  while true; do
    now="$(date +%s)"
    if [ "$now" -gt "$deadline" ]; then
      echo "agentkeeper_enroll: device-code polling timed out after 10 minutes" >&2
      return 1
    fi
    curl -sS -X POST "$api/api/v1/plugin/device-code/poll" \
      -H 'content-type: application/json' \
      -d "$(jq -n --arg c "$code" '{code:$c}')" \
      -o "$poll_resp" >/dev/null 2>&1 || true

    status="$(jq -r .status "$poll_resp" 2>/dev/null)"
    case "$status" in
      bound) break ;;
      expired)
        echo "agentkeeper_enroll: device code expired" >&2
        return 1
        ;;
      pending|not_found|null|"") sleep "$poll_secs" ;;
      *) sleep "$poll_secs" ;;
    esac
  done

  org_id="$(jq -r .org_id "$poll_resp" 2>/dev/null)"
  directory_user_id="$(jq -r .directory_user_id "$poll_resp" 2>/dev/null)"
  if [ -z "$org_id" ] || [ "$org_id" = "null" ]; then
    echo "agentkeeper_enroll: bound poll response missing org_id" >&2
    return 1
  fi

  # 3. Send enroll with user_login binding.
  local pub machine_id enroll_resp http_code
  pub="$(agentkeeper_ensure_keypair)"
  machine_id="$(get_machine_id)"
  enroll_resp="$(mktemp)"; trap 'rm -f "$resp" "$poll_resp" "$enroll_resp"' RETURN
  http_code="$(curl -sS -o "$enroll_resp" -w '%{http_code}' -X POST "$api/api/v1/plugin/enroll" \
    -H 'content-type: application/json' \
    -d "$(jq -n --arg bs user_login --arg pk "$pub" --arg mid "$machine_id" --arg oid "$org_id" --arg c "$code" \
        '{binding_source:$bs, public_key:$pk, machine_id:$mid, org_id:$oid, device_code:$c}')" )"

  if [ "$http_code" != "200" ]; then
    echo "agentkeeper_enroll: final enroll call failed (http $http_code)" >&2
    head -c 500 "$enroll_resp" >&2
    echo >&2
    return 1
  fi

  install -m 0600 /dev/null "$(agentkeeper_cred_file)"
  cat "$enroll_resp" > "$(agentkeeper_cred_file)"
  chmod 0600 "$(agentkeeper_cred_file)"
}

# High-level entry point: try MDM path, then device-code. On success returns 0
# and the credential file is at $(agentkeeper_cred_file).
agentkeeper_enroll() {
  if agentkeeper_enroll_via_mdm_token 2>/dev/null; then
    echo "Enrolled via MDM token."
    return 0
  fi
  if agentkeeper_enroll_via_device_code; then
    echo "Enrolled via browser device-code."
    return 0
  fi
  return 1
}

# Helper for other scripts: emit `Header-Name: value` lines for X-Machine-Id /
# X-Timestamp / X-Device-Signature / X-Console-User — no-op if no key exists.
# Caller passes the request body as $1.
agentkeeper_request_headers() {
  agentkeeper_has_keypair || return 0
  local body="$1"
  local ts mid sig
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mid="$(get_machine_id)"
  sig="$(printf '%s%s' "$ts" "$body" | agentkeeper_sign)"
  printf 'X-Machine-Id: %s\n' "$mid"
  printf 'X-Timestamp: %s\n' "$ts"
  printf 'X-Device-Signature: %s\n' "$sig"
  printf 'X-Console-User: %s\n' "${USER:-unknown}"
}
