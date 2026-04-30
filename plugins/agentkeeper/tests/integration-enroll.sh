#!/usr/bin/env bash
# integration-enroll.sh — End-to-end device-code enrollment + signed heartbeat.
#
# MANUAL integration test. Requires:
#   - A running web dev server (npm run dev) at AGENTKEEPER_APP_URL (default http://localhost:3000).
#   - A browser session signed into a test org (Supabase auth cookie set for that domain).
#   - The signed-in user's auth.users row is linked to a directory_users row
#     (so the bind endpoint can resolve them).
#
# Usage:
#   AGENTKEEPER_APP_URL=http://localhost:3000 bash plugin/tests/integration-enroll.sh
#
# Exits 0 on a successful enrollment + heartbeat round-trip, non-zero otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$PLUGIN_DIR/scripts/lib/enroll.sh"

AGENTKEEPER_APP_URL="${AGENTKEEPER_APP_URL:-http://localhost:3000}"
export AGENTKEEPER_API_URL="$AGENTKEEPER_APP_URL"

# Isolated data dir so we don't touch the user's real key.
export CLAUDE_PLUGIN_DATA="$(mktemp -d)"
trap '
  agentkeeper_delete_keypair 2>/dev/null || true
  rm -rf "$CLAUDE_PLUGIN_DATA"
' EXIT

note() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }

note "API URL: $AGENTKEEPER_APP_URL"
note "Sandbox data dir: $CLAUDE_PLUGIN_DATA"

note "Step 1/5: Verifying API reachability"
if ! curl -sSf -o /dev/null -w '' --max-time 5 "$AGENTKEEPER_APP_URL/api/v1/plugin/device-code/request" -X POST; then
  fail "Cannot reach $AGENTKEEPER_APP_URL. Start the web dev server with 'npm run dev' in web/."
fi

note "Step 2/5: Requesting a device code"
REQ_RESP="$(mktemp)"; trap '[ -f "$REQ_RESP" ] && rm -f "$REQ_RESP"' RETURN
curl -sSf -X POST "$AGENTKEEPER_APP_URL/api/v1/plugin/device-code/request" -o "$REQ_RESP"
CODE="$(jq -r .code "$REQ_RESP")"
VERIFY_URL="$(jq -r .verification_url "$REQ_RESP")"
[ -n "$CODE" ] && [ "$CODE" != "null" ] || fail "Malformed device-code response"

printf "Code: %s\n" "$CODE"
printf "Verification URL: %s\n" "$VERIFY_URL"
printf "\nOpen the URL above in a browser, sign in, and click through the bind page.\n"
printf "Press ENTER once the browser shows 'Done':"
read -r

note "Step 3/5: Polling for bound status"
POLL_RESP="$(mktemp)"; trap '[ -f "$REQ_RESP" ] && rm -f "$REQ_RESP"; [ -f "$POLL_RESP" ] && rm -f "$POLL_RESP"' RETURN
ATTEMPTS=0
MAX_ATTEMPTS=300  # 300 * 2s = 10 min
while : ; do
  if [ "$ATTEMPTS" -ge "$MAX_ATTEMPTS" ]; then
    fail "Polling timed out after 10 minutes"
  fi
  curl -sS -X POST "$AGENTKEEPER_APP_URL/api/v1/plugin/device-code/poll" \
    -H 'content-type: application/json' \
    -d "$(jq -n --arg c "$CODE" '{code:$c}')" \
    -o "$POLL_RESP" >/dev/null
  STATUS="$(jq -r .status "$POLL_RESP")"
  case "$STATUS" in
    bound) break ;;
    expired) fail "Code expired before bind completed" ;;
    pending) sleep 2; ATTEMPTS=$((ATTEMPTS + 1)) ;;
    not_found) fail "Code not_found (did the request step succeed?)" ;;
    *) sleep 2; ATTEMPTS=$((ATTEMPTS + 1)) ;;
  esac
done
ORG_ID="$(jq -r .org_id "$POLL_RESP")"
DIR_USER_ID="$(jq -r .directory_user_id "$POLL_RESP")"
printf "Bound. org_id=%s, directory_user_id=%s\n" "$ORG_ID" "$DIR_USER_ID"

note "Step 4/5: Generating keypair + enrolling"
PUB="$(agentkeeper_generate_keypair)"
MACHINE_ID="$(get_machine_id)"
ENROLL_RESP="$(mktemp)"; trap '[ -f "$REQ_RESP" ] && rm -f "$REQ_RESP"; [ -f "$POLL_RESP" ] && rm -f "$POLL_RESP"; [ -f "$ENROLL_RESP" ] && rm -f "$ENROLL_RESP"' RETURN
HTTP_CODE="$(curl -sS -o "$ENROLL_RESP" -w '%{http_code}' -X POST "$AGENTKEEPER_APP_URL/api/v1/plugin/enroll" \
  -H 'content-type: application/json' \
  -d "$(jq -n --arg bs user_login --arg pk "$PUB" --arg mid "$MACHINE_ID" --arg oid "$ORG_ID" --arg c "$CODE" \
      '{binding_source:$bs, public_key:$pk, machine_id:$mid, org_id:$oid, device_code:$c}')")"
[ "$HTTP_CODE" = "200" ] || fail "enroll returned HTTP $HTTP_CODE: $(head -c 500 "$ENROLL_RESP")"
DEVICE_ID="$(jq -r .device_id "$ENROLL_RESP")"
printf "Enrolled. device_id=%s\n" "$DEVICE_ID"

note "Step 5/5: Sending a signed heartbeat"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BODY='{}'
SIG="$(printf '%s%s' "$TS" "$BODY" | agentkeeper_sign)"
HB_RESP="$(mktemp)"; trap '[ -f "$REQ_RESP" ] && rm -f "$REQ_RESP"; [ -f "$POLL_RESP" ] && rm -f "$POLL_RESP"; [ -f "$ENROLL_RESP" ] && rm -f "$ENROLL_RESP"; [ -f "$HB_RESP" ] && rm -f "$HB_RESP"' RETURN
HTTP_CODE="$(curl -sS -o "$HB_RESP" -w '%{http_code}' -X POST "$AGENTKEEPER_APP_URL/api/v1/plugin/heartbeat" \
  -H 'content-type: application/json' \
  -H "X-Machine-Id: $MACHINE_ID" \
  -H "X-Timestamp: $TS" \
  -H "X-Device-Signature: $SIG" \
  -d "$BODY")"
[ "$HTTP_CODE" = "200" ] || fail "heartbeat returned HTTP $HTTP_CODE: $(head -c 500 "$HB_RESP")"
STATUS="$(jq -r .status "$HB_RESP")"
[ "$STATUS" = "active" ] || fail "heartbeat returned status=$STATUS (expected active)"

printf "\nPASS — device enrolled, signed heartbeat verified active.\n"
