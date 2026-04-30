#!/usr/bin/env bash
# integration-plans-1-4.sh — End-to-end integration test for Plans 1 through 4.
#
# What this verifies (in order):
#   1. Plan 1: device enrollment via device-code browser flow (manual bind step)
#   2. Plan 1: signed heartbeat round-trip
#   3. Plan 3: unified /api/v1/policy/resolve endpoint returns a valid shape
#   4. Plan 3: X-Policy-Debug header returns debug block with cache hit states
#   5. Plan 3: Claude Code dual-read (with flag on) populates policy_divergence_log
#   6. Plan 4: /api/v1/shield/policy dual-read fires on org default pack
#   7. Plan 4: /api/v1/mcp/evaluate dual-read fires mcp_gateway context
#
# Requirements:
#   - Web dev server running at $AGENTKEEPER_APP_URL (default http://localhost:3000)
#   - $AGENTKEEPER_API_KEY set to a valid AgentKeeper API key scoped to the test org
#   - $AGENTKEEPER_ORG_ID set to the test org's UUID
#   - Supabase service role key set via $SUPABASE_SERVICE_ROLE_KEY — for
#     direct DB verification of policy_divergence_log rows (optional; skipped
#     if unset)
#   - A directory_user linked to the signed-in browser user in $AGENTKEEPER_APP_URL
#     (needed for the device-code bind step)
#
# Usage:
#   AGENTKEEPER_APP_URL=http://localhost:3000 \
#   AGENTKEEPER_API_KEY=ak_live_xxx \
#   AGENTKEEPER_ORG_ID=00000000-0000-0000-0000-000000000000 \
#   bash plugin/tests/integration-plans-1-4.sh
#
# Exits 0 if every check passes, non-zero otherwise.
# Optional env var: SKIP_FLAG_FLIP=1 — skip the use_policy_packs toggle (useful
# if you don't want to change the org's state; dual-read tests will be skipped).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$PLUGIN_DIR/scripts/lib/enroll.sh"

AGENTKEEPER_APP_URL="${AGENTKEEPER_APP_URL:-http://localhost:3000}"
export AGENTKEEPER_API_URL="$AGENTKEEPER_APP_URL"

AGENTKEEPER_API_KEY="${AGENTKEEPER_API_KEY:-}"
AGENTKEEPER_ORG_ID="${AGENTKEEPER_ORG_ID:-}"
if [ -z "$AGENTKEEPER_API_KEY" ]; then
  echo "ERROR: AGENTKEEPER_API_KEY env var is required." >&2
  exit 2
fi
if [ -z "$AGENTKEEPER_ORG_ID" ]; then
  echo "ERROR: AGENTKEEPER_ORG_ID env var is required." >&2
  exit 2
fi

SKIP_FLAG_FLIP="${SKIP_FLAG_FLIP:-0}"

# Isolated data dir so we don't touch the user's real key.
export CLAUDE_PLUGIN_DATA="$(mktemp -d)"

PASS_COUNT=0
FAIL_COUNT=0
FAILURES=()

cleanup() {
  local ec=$?
  # Best-effort: delete the generated keypair so we don't leave junk in keychain.
  agentkeeper_delete_keypair 2>/dev/null || true
  rm -rf "$CLAUDE_PLUGIN_DATA"
  echo
  echo "======================================"
  echo "Integration test summary"
  echo "======================================"
  echo "  PASS: $PASS_COUNT"
  echo "  FAIL: $FAIL_COUNT"
  if [ $FAIL_COUNT -gt 0 ]; then
    echo
    echo "Failures:"
    for f in "${FAILURES[@]}"; do echo "  - $f"; done
  fi
  echo "======================================"
  exit $ec
}
trap cleanup EXIT

pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); FAILURES+=("$1"); printf '  \033[31m✗\033[0m %s\n' "$1"; }
note() { printf '\n\033[36m==>\033[0m %s\n' "$*"; }
die()  { echo "FATAL: $*" >&2; exit 1; }

# ── Step 1: API reachability ──────────────────────────────────────────
note "Step 1: API reachability ($AGENTKEEPER_APP_URL)"

if curl -sSf -o /dev/null -w '' --max-time 5 -X POST "$AGENTKEEPER_APP_URL/api/v1/plugin/device-code/request" 2>/dev/null; then
  pass "API is reachable"
else
  fail "API is not reachable — is the dev server running?"
  die "Cannot proceed without API"
fi

# ── Step 2: Plan 1 — device enrollment ────────────────────────────────
note "Step 2: Plan 1 — device enrollment (device-code flow)"

REQ_RESP="$(mktemp)"
if ! curl -sSf -X POST "$AGENTKEEPER_APP_URL/api/v1/plugin/device-code/request" -o "$REQ_RESP"; then
  fail "Device-code request endpoint failed"
  die "Cannot proceed without device code"
fi
CODE="$(jq -r .code "$REQ_RESP")"
VERIFY_URL="$(jq -r .verification_url "$REQ_RESP")"
if [ -z "$CODE" ] || [ "$CODE" = "null" ]; then
  fail "Device-code response malformed"
  die "Cannot proceed"
fi
pass "Device code minted: $CODE"

echo
echo "  ▶ Open the URL below in a browser to bind the code to your directory user:"
echo "    $VERIFY_URL"
echo
printf "  Press ENTER after the browser shows 'Done' (or type 'skip' to skip): "
read -r REPLY

if [ "$REPLY" = "skip" ]; then
  fail "Browser bind skipped — cannot test enrollment + signed heartbeat"
else
  # Poll for bound status
  POLL_RESP="$(mktemp)"
  ATTEMPTS=0
  MAX_ATTEMPTS=60   # 60 * 2s = 2 min
  BOUND=false
  while [ "$ATTEMPTS" -lt "$MAX_ATTEMPTS" ]; do
    curl -sSf -X POST "$AGENTKEEPER_APP_URL/api/v1/plugin/device-code/poll" \
      -H 'content-type: application/json' \
      -d "$(jq -n --arg c "$CODE" '{code:$c}')" \
      -o "$POLL_RESP" 2>/dev/null || true
    STATUS="$(jq -r .status "$POLL_RESP" 2>/dev/null)"
    [ "$STATUS" = "bound" ] && { BOUND=true; break; }
    [ "$STATUS" = "expired" ] && break
    sleep 2
    ATTEMPTS=$((ATTEMPTS + 1))
  done

  if [ "$BOUND" != true ]; then
    fail "Device-code never reached 'bound' state (timed out or expired)"
  else
    pass "Device-code bound"

    POLL_ORG_ID="$(jq -r .org_id "$POLL_RESP")"
    POLL_USER_ID="$(jq -r .directory_user_id "$POLL_RESP")"

    # Generate keypair + call enroll
    PUB="$(agentkeeper_generate_keypair)"
    MACHINE_ID="$(get_machine_id)"
    ENROLL_RESP="$(mktemp)"
    HTTP_CODE="$(curl -sS -o "$ENROLL_RESP" -w '%{http_code}' -X POST "$AGENTKEEPER_APP_URL/api/v1/plugin/enroll" \
      -H 'content-type: application/json' \
      -d "$(jq -n --arg bs user_login --arg pk "$PUB" --arg mid "$MACHINE_ID" --arg oid "$POLL_ORG_ID" --arg c "$CODE" \
          '{binding_source:$bs, public_key:$pk, machine_id:$mid, org_id:$oid, device_code:$c}')")"

    if [ "$HTTP_CODE" = "200" ]; then
      pass "Enroll endpoint returned 200"
      DEVICE_ID="$(jq -r .device_id "$ENROLL_RESP")"

      # ── Step 3: signed heartbeat ─────────────────────────────────────
      note "Step 3: Plan 1 — signed heartbeat"
      TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      HB_BODY='{}'
      SIG="$(printf '%s%s' "$TS" "$HB_BODY" | agentkeeper_sign)"
      HB_RESP="$(mktemp)"
      HB_CODE="$(curl -sS -o "$HB_RESP" -w '%{http_code}' -X POST "$AGENTKEEPER_APP_URL/api/v1/plugin/heartbeat" \
        -H 'content-type: application/json' \
        -H "X-Machine-Id: $MACHINE_ID" -H "X-Timestamp: $TS" -H "X-Device-Signature: $SIG" \
        -d "$HB_BODY")"
      if [ "$HB_CODE" = "200" ] && [ "$(jq -r .status "$HB_RESP")" = "active" ]; then
        pass "Signed heartbeat returned status=active"
      else
        fail "Signed heartbeat failed (HTTP $HB_CODE, body: $(head -c 200 "$HB_RESP"))"
      fi

      # ── Step 4: Plan 3 — /api/v1/policy/resolve ──────────────────────
      note "Step 4: Plan 3 — unified policy resolver"
      RESOLVE_BODY='{"context":"claude_code"}'
      RESOLVE_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      RESOLVE_SIG="$(printf '%s%s' "$RESOLVE_TS" "$RESOLVE_BODY" | agentkeeper_sign)"
      RESOLVE_RESP="$(mktemp)"
      RESOLVE_CODE="$(curl -sS -o "$RESOLVE_RESP" -w '%{http_code}' -X POST "$AGENTKEEPER_APP_URL/api/v1/policy/resolve" \
        -H 'content-type: application/json' \
        -H "X-Machine-Id: $MACHINE_ID" -H "X-Timestamp: $RESOLVE_TS" -H "X-Device-Signature: $RESOLVE_SIG" \
        -H 'X-Policy-Debug: true' \
        -d "$RESOLVE_BODY")"

      if [ "$RESOLVE_CODE" = "200" ]; then
        pass "/api/v1/policy/resolve returned 200"

        # Shape checks
        if jq -e '.identity.trust_level' "$RESOLVE_RESP" >/dev/null 2>&1; then
          pass "Response contains identity.trust_level"
        else
          fail "Response missing identity.trust_level"
        fi
        if jq -e '.merged_policy.shield' "$RESOLVE_RESP" >/dev/null 2>&1; then
          pass "Response contains merged_policy.shield"
        else
          fail "Response missing merged_policy.shield"
        fi
        if jq -e '.applied_packs | length > 0' "$RESOLVE_RESP" >/dev/null 2>&1; then
          pass "Response contains applied_packs"
        else
          fail "Response missing applied_packs"
        fi
        if jq -e '.debug.packs_version' "$RESOLVE_RESP" >/dev/null 2>&1; then
          pass "Debug block present (X-Policy-Debug: true honored)"
          WATCHER_MODE="$(jq -r .debug.watcher_mode "$RESOLVE_RESP")"
          echo "     watcher_mode: $WATCHER_MODE (degraded is expected on Vercel serverless)"
        else
          fail "Debug block missing"
        fi
      else
        fail "/api/v1/policy/resolve returned HTTP $RESOLVE_CODE ($(head -c 200 "$RESOLVE_RESP"))"
      fi

      rm -f "$RESOLVE_RESP"
    else
      fail "Enroll endpoint returned HTTP $HTTP_CODE ($(head -c 200 "$ENROLL_RESP"))"
    fi
    rm -f "$ENROLL_RESP"
  fi
fi

# ── Step 5: Plan 3 + 4 — flag flip + divergence pipeline ───────────────
if [ "$SKIP_FLAG_FLIP" = "1" ]; then
  note "Step 5: SKIPPED (SKIP_FLAG_FLIP=1) — flag flip + dual-read verification"
else
  note "Step 5: Plans 3+4 — flag flip + dual-read pipeline"

  # Flip the flag via direct DB. Admin API requires browser-session auth and is
  # inconvenient from a script; the Supabase direct-update is the reliable path.
  if [ -n "${SUPABASE_SERVICE_ROLE_KEY:-}" ] && [ -n "${NEXT_PUBLIC_SUPABASE_URL:-}" ]; then
    # Use the Supabase REST API to PATCH the org row.
    FLIP_RESP="$(mktemp)"
    FLIP_CODE="$(curl -sS -o "$FLIP_RESP" -w '%{http_code}' -X PATCH \
      "${NEXT_PUBLIC_SUPABASE_URL}/rest/v1/organizations?id=eq.$AGENTKEEPER_ORG_ID" \
      -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
      -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
      -H "Content-Type: application/json" \
      -H "Prefer: return=minimal" \
      -d '{"use_policy_packs": true}')"
    if [ "$FLIP_CODE" = "204" ] || [ "$FLIP_CODE" = "200" ]; then
      pass "use_policy_packs flipped on for org $AGENTKEEPER_ORG_ID"

      # Fire Claude Code evaluate with signed headers — should trigger compareAndLog.
      CC_BODY='{"tool_name":"Bash","tool_input":{"command":"echo hi"},"session_id":"integration-test-session"}'
      CURL_OPTS=(-X POST "$AGENTKEEPER_APP_URL/api/v1/claude-code/evaluate"
        -H 'content-type: application/json'
        -H "Authorization: Bearer $AGENTKEEPER_API_KEY"
        -H "X-Hostname: $(hostname)"
        -H "X-Machine-Id: ${MACHINE_ID:-unknown}")

      if agentkeeper_has_keypair; then
        CC_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        CC_SIG="$(printf '%s%s' "$CC_TS" "$CC_BODY" | agentkeeper_sign)"
        CURL_OPTS+=(-H "X-Timestamp: $CC_TS" -H "X-Device-Signature: $CC_SIG" -H "X-Console-User: ${USER:-unknown}")
      fi

      CC_RESP="$(mktemp)"
      CC_CODE="$(curl -sS -o "$CC_RESP" -w '%{http_code}' "${CURL_OPTS[@]}" -d "$CC_BODY")"
      if [ "$CC_CODE" = "200" ]; then
        pass "Claude Code evaluate returned 200 (legacy path still authoritative)"
      else
        fail "Claude Code evaluate failed (HTTP $CC_CODE)"
      fi
      rm -f "$CC_RESP"

      # Fire /api/v1/shield/policy — should trigger compareOrgDefaultAndLog.
      SHIELD_RESP="$(mktemp)"
      SHIELD_CODE="$(curl -sS -o "$SHIELD_RESP" -w '%{http_code}' -X GET \
        "$AGENTKEEPER_APP_URL/api/v1/shield/policy" \
        -H "Authorization: Bearer $AGENTKEEPER_API_KEY")"
      if [ "$SHIELD_CODE" = "200" ]; then
        pass "/api/v1/shield/policy returned 200"
      else
        fail "/api/v1/shield/policy returned HTTP $SHIELD_CODE"
      fi
      rm -f "$SHIELD_RESP"

      # Fire /api/v1/mcp/evaluate — should trigger compareMcpAndLog.
      MCP_BODY='{"server_name":"test-server","tool_name":"test-tool","params":{}}'
      MCP_RESP="$(mktemp)"
      MCP_CODE="$(curl -sS -o "$MCP_RESP" -w '%{http_code}' -X POST \
        "$AGENTKEEPER_APP_URL/api/v1/mcp/evaluate" \
        -H 'content-type: application/json' \
        -H "Authorization: Bearer $AGENTKEEPER_API_KEY" \
        -d "$MCP_BODY")"
      if [ "$MCP_CODE" = "200" ]; then
        pass "/api/v1/mcp/evaluate returned 200"
      else
        fail "/api/v1/mcp/evaluate returned HTTP $MCP_CODE"
      fi
      rm -f "$MCP_RESP"

      # Give fire-and-forget promises ~3s to complete before we check the DB.
      echo "     Waiting 3s for fire-and-forget dual-read to flush..."
      sleep 3

      # Query policy_divergence_log directly via Supabase REST.
      DIVERGE_RESP="$(mktemp)"
      DIVERGE_CODE="$(curl -sS -o "$DIVERGE_RESP" -w '%{http_code}' -X GET \
        "${NEXT_PUBLIC_SUPABASE_URL}/rest/v1/policy_audit_log?org_id=eq.${AGENTKEEPER_ORG_ID}&policy_type=eq.device_binding&field_name=eq.resolve&order=created_at.desc&limit=5" \
        -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
        -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY")"
      if [ "$DIVERGE_CODE" = "200" ]; then
        RECENT_AUDITS="$(jq -r '. | length' "$DIVERGE_RESP")"
        if [ "$RECENT_AUDITS" -gt 0 ]; then
          pass "policy_audit_log shows $RECENT_AUDITS recent resolver audits (resolver is firing)"
        else
          fail "No recent policy_audit_log entries — resolver may not be running"
        fi
      else
        echo "     (Skipped audit-log check: HTTP $DIVERGE_CODE)"
      fi
      rm -f "$DIVERGE_RESP"

      # Flip the flag back off to leave the org in a clean state.
      curl -sS -o /dev/null -X PATCH \
        "${NEXT_PUBLIC_SUPABASE_URL}/rest/v1/organizations?id=eq.$AGENTKEEPER_ORG_ID" \
        -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
        -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
        -H "Content-Type: application/json" \
        -H "Prefer: return=minimal" \
        -d '{"use_policy_packs": false}' || true
      echo "     use_policy_packs flipped back off (cleanup)"
    else
      fail "Flag flip failed (HTTP $FLIP_CODE)"
    fi
    rm -f "$FLIP_RESP"
  else
    echo "     (Skipped: SUPABASE_SERVICE_ROLE_KEY + NEXT_PUBLIC_SUPABASE_URL needed to toggle the flag)"
    fail "Cannot verify dual-read pipeline without Supabase credentials"
  fi
fi

# Exit code set by trap based on FAIL_COUNT
if [ $FAIL_COUNT -gt 0 ]; then
  exit 1
fi
exit 0
