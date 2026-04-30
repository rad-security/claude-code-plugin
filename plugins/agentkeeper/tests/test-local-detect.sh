#!/usr/bin/env bash
# test-local-detect.sh — Test suite for the local detection engine
# Exercises dangerous-commands, safe-commands, dangerous-paths, safe-paths,
# dangerous-prompts, safe-prompts fixtures against local-detect.sh.
#
# Exit code: 0 if all pass, 1 if any fail.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DETECT="${PLUGIN_ROOT}/scripts/local-detect.sh"
FIXTURES="${SCRIPT_DIR}/fixtures"

PASS=0
FAIL=0
SLOW=0
MAX_MS=100  # generous margin for per-case timing

# Temp file for payloads (avoids nested quoting issues)
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

# Colors (if tty)
if [ -t 1 ]; then
  GREEN='\033[0;32m'
  RED='\033[0;31m'
  YELLOW='\033[0;33m'
  NC='\033[0m'
else
  GREEN='' RED='' YELLOW='' NC=''
fi

pass() { PASS=$((PASS + 1)); printf "${GREEN}  PASS${NC}  %s\n" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf "${RED}  FAIL${NC}  %s\n" "$1"; }

# Build JSON payload safely using python3 to handle all escaping.
# Usage: build_payload "Bash" "command" "the command string" > tmpfile
#        build_payload "Write" "file_path" "/etc/shadow" > tmpfile
#        build_prompt_payload "the prompt text" > tmpfile
build_payload() {
  local tool_name="$1"
  local field_name="$2"
  local field_value="$3"
  python3 -c "
import json, sys
payload = {
    'tool_name': sys.argv[1],
    'tool_input': {sys.argv[2]: sys.argv[3]},
    'hook_event_name': 'PreToolUse'
}
print(json.dumps(payload))
" "$tool_name" "$field_name" "$field_value"
}

build_prompt_payload() {
  local prompt_text="$1"
  python3 -c "
import json, sys
payload = {
    'prompt': sys.argv[1],
    'hook_event_name': 'UserPromptSubmit'
}
print(json.dumps(payload))
" "$prompt_text"
}

# Run detection with timing. Reads payload from $TMPFILE.
# Sets TIMED_OUTPUT and ELAPSED_MS.
run_detect() {
  local hook_type="$1"
  local start_ms end_ms

  # macOS/BSD date doesn't support %N; fall back to seconds
  if date +%s%N 2>/dev/null | grep -q 'N'; then
    start_ms=$(( $(date +%s) * 1000 ))
    TIMED_OUTPUT=$("$DETECT" "$hook_type" < "$TMPFILE" 2>/dev/null) || true
    end_ms=$(( $(date +%s) * 1000 ))
  else
    start_ms=$(( $(date +%s%N) / 1000000 ))
    TIMED_OUTPUT=$("$DETECT" "$hook_type" < "$TMPFILE" 2>/dev/null) || true
    end_ms=$(( $(date +%s%N) / 1000000 ))
  fi
  ELAPSED_MS=$(( end_ms - start_ms ))
}

check_timing() {
  local label="$1"
  if [ "$ELAPSED_MS" -gt "$MAX_MS" ]; then
    SLOW=$((SLOW + 1))
    printf "${YELLOW}  SLOW${NC}  %s (%dms > %dms)\n" "$label" "$ELAPSED_MS" "$MAX_MS"
  fi
}

# ── Dangerous Commands ─────────────────────────────────────────────────────

echo ""
echo "=== Dangerous Commands (must trigger detection) ==="
while IFS= read -r line; do
  [ -z "$line" ] && continue

  build_payload "Bash" "command" "$line" > "$TMPFILE"
  run_detect "pre_tool"

  if [ -n "$TIMED_OUTPUT" ]; then
    pass "$line"
  else
    fail "$line"
  fi
  check_timing "$line"
done < "${FIXTURES}/dangerous-commands.txt"

# ── Safe Commands ──────────────────────────────────────────────────────────

echo ""
echo "=== Safe Commands (must NOT trigger detection) ==="
while IFS= read -r line; do
  [ -z "$line" ] && continue

  build_payload "Bash" "command" "$line" > "$TMPFILE"
  run_detect "pre_tool"

  if [ -z "$TIMED_OUTPUT" ]; then
    pass "$line"
  else
    fail "$line (got: $TIMED_OUTPUT)"
  fi
  check_timing "$line"
done < "${FIXTURES}/safe-commands.txt"

# ── Dangerous Paths (Write tool) ──────────────────────────────────────────

echo ""
echo "=== Dangerous Paths — Write (must trigger detection) ==="
while IFS= read -r line; do
  [ -z "$line" ] && continue

  build_payload "Write" "file_path" "$line" > "$TMPFILE"
  run_detect "pre_tool"

  if [ -n "$TIMED_OUTPUT" ]; then
    pass "$line"
  else
    fail "$line"
  fi
  check_timing "$line"
done < "${FIXTURES}/dangerous-paths.txt"

# ── Safe Paths (Write tool) ───────────────────────────────────────────────

echo ""
echo "=== Safe Paths — Write (must NOT trigger detection) ==="
while IFS= read -r line; do
  [ -z "$line" ] && continue

  build_payload "Write" "file_path" "$line" > "$TMPFILE"
  run_detect "pre_tool"

  if [ -z "$TIMED_OUTPUT" ]; then
    pass "$line"
  else
    fail "$line (got: $TIMED_OUTPUT)"
  fi
  check_timing "$line"
done < "${FIXTURES}/safe-paths.txt"

# ── Dangerous Prompts ─────────────────────────────────────────────────────

echo ""
echo "=== Dangerous Prompts (must trigger detection) ==="
while IFS= read -r line; do
  [ -z "$line" ] && continue

  build_prompt_payload "$line" > "$TMPFILE"
  run_detect "prompt"

  if [ -n "$TIMED_OUTPUT" ]; then
    pass "$line"
  else
    fail "$line"
  fi
  check_timing "$line"
done < "${FIXTURES}/dangerous-prompts.txt"

# ── Safe Prompts ──────────────────────────────────────────────────────────

echo ""
echo "=== Safe Prompts (must NOT trigger detection) ==="
while IFS= read -r line; do
  [ -z "$line" ] && continue

  build_prompt_payload "$line" > "$TMPFILE"
  run_detect "prompt"

  if [ -z "$TIMED_OUTPUT" ]; then
    pass "$line"
  else
    fail "$line (got: $TIMED_OUTPUT)"
  fi
  check_timing "$line"
done < "${FIXTURES}/safe-prompts.txt"

# ── Summary ────────────────────────────────────────────────────────────────

TOTAL=$((PASS + FAIL))
echo ""
echo "========================================"
printf "local-detect results: %d passed, %d failed out of %d tests\n" "$PASS" "$FAIL" "$TOTAL"
if [ "$SLOW" -gt 0 ]; then
  printf "${YELLOW}Warning: %d test(s) exceeded %dms threshold${NC}\n" "$SLOW" "$MAX_MS"
fi
echo "========================================"
echo ""

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

exit 0
