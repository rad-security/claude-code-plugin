#!/usr/bin/env bash
# test-antigravity-prompt-capture.sh — Contract tests for the Antigravity
# PreInvocation prompt-capture path in gemini-adapter.sh.
#
# Antigravity fires PreInvocation with NO prompt in the payload; the prompt
# lives in the transcript file (transcriptPath). The adapter must read the last
# user turn and forward it as a prompt — and must fail-open (forward nothing)
# when the transcript is missing, encrypted, or has no user turn.
#
# The harness points AGENTKEEPER_SCRIPTS_DIR at a temp dir with no-op libs and a
# stub prompt-hook.sh that records exactly what the adapter forwards.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ADAPTER="${PLUGIN_ROOT}/scripts/adapters/gemini-adapter.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf "  PASS  %s\n" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf "  FAIL  %s\n" "$1"; }

STUB=$(mktemp -d)
trap 'rm -rf "$STUB"' EXIT
mkdir -p "$STUB/scripts/lib"
printf '%s\n' 'emit_allow(){ printf "{}\n"; }' 'has_agentkeeper_http_hooks(){ return 1; }' > "$STUB/scripts/lib/json-helpers.sh"
printf '%s\n' 'is_duplicate(){ return 1; }' > "$STUB/scripts/lib/dedup.sh"
printf '%s\n' 'debug_log(){ :; }' > "$STUB/scripts/lib/debug-log.sh"
# stub prompt-hook records the forwarded payload to $CAPTURE
printf '%s\n' '#!/usr/bin/env bash' 'cat > "$CAPTURE"' 'printf "{}\n"' > "$STUB/scripts/prompt-hook.sh"
chmod +x "$STUB/scripts/prompt-hook.sh"

CAPTURE="$STUB/captured.json"
export CAPTURE

run_preinvocation() {
  # $1 = transcript file path (may be missing)
  : > "$CAPTURE"
  local payload
  payload=$(printf '{"hook_event_name":"PreInvocation","invocationNum":1,"conversationId":"conv-1","transcriptPath":"%s","artifactDirectoryPath":"/x","modelName":"gemini"}' "$1")
  set +e
  printf '%s' "$payload" | AGENTKEEPER_SCRIPTS_DIR="$STUB" CAPTURE="$CAPTURE" bash "$ADAPTER" >/dev/null 2>&1
  EXIT_CODE=$?
  set -e
}

echo "=== Antigravity Prompt Capture Tests ==="

# 1. Real Antigravity CLI schema: type=USER_INPUT, content wrapped in
#    <USER_REQUEST>. Must extract the LATEST user turn, unwrapped.
printf '%s\n' \
  '{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","content":"<USER_REQUEST>\nfirst prompt\n</USER_REQUEST>"}' \
  '{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":"ok"}' \
  '{"step_index":2,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","content":"<USER_REQUEST>\nList the PHI folder\n</USER_REQUEST>"}' \
  > "$STUB/t1.jsonl"
run_preinvocation "$STUB/t1.jsonl"
if [ "$EXIT_CODE" -eq 0 ] && grep -q '"prompt": "List the PHI folder"' "$CAPTURE"; then
  pass "extracts latest USER_INPUT turn, unwrapped, and forwards it as prompt"
else
  fail "should forward the unwrapped user turn (got: $(cat "$CAPTURE"))"
fi

# 1b. Generic fallback schema (role/content) still works for IDE/SDK variants.
printf '%s\n' '{"role":"assistant","text":"hi"}' '{"role":"user","content":[{"text":"generic turn"}]}' > "$STUB/t1b.jsonl"
run_preinvocation "$STUB/t1b.jsonl"
if [ "$EXIT_CODE" -eq 0 ] && grep -q '"prompt": "generic turn"' "$CAPTURE"; then
  pass "still handles the generic role/content schema"
else
  fail "generic role/content schema should still work (got: $(cat "$CAPTURE"))"
fi

# 2. Antigravity markers preserved so the server keeps the antigravity surface.
if grep -q '"invocationNum"' "$CAPTURE" && grep -q '"transcriptPath"' "$CAPTURE"; then
  pass "keeps antigravity markers on the forwarded payload"
else
  fail "forwarded payload lost antigravity markers"
fi

# 3. Encrypted / binary transcript → no-op (fail-open, no regression).
head -c 200 /dev/urandom > "$STUB/t2.jsonl"
run_preinvocation "$STUB/t2.jsonl"
if [ "$EXIT_CODE" -eq 0 ] && [ ! -s "$CAPTURE" ]; then
  pass "encrypted/binary transcript forwards nothing"
else
  fail "encrypted transcript must forward nothing (got: $(cat "$CAPTURE"))"
fi

# 4. Missing transcript file → no-op.
run_preinvocation "$STUB/does-not-exist.jsonl"
if [ "$EXIT_CODE" -eq 0 ] && [ ! -s "$CAPTURE" ]; then
  pass "missing transcript forwards nothing"
else
  fail "missing transcript must forward nothing"
fi

# 5. No user turn (only Model/Tool) → no-op.
printf '%s\n' '{"actor":"Model","text":"hi"}' '{"actor":"Tool","text":"ran"}' > "$STUB/t3.jsonl"
run_preinvocation "$STUB/t3.jsonl"
if [ "$EXIT_CODE" -eq 0 ] && [ ! -s "$CAPTURE" ]; then
  pass "transcript without a user turn forwards nothing"
else
  fail "no-user transcript must forward nothing (got: $(cat "$CAPTURE"))"
fi

printf "antigravity-prompt-capture results: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
