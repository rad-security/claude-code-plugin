#!/usr/bin/env bash
# test-cowork-hook.sh — Integration tests for the Clawkeeper Cowork PreToolUse hook.
#
# Drives plugin/scripts/cowork-pre-tool.sh with synthetic envelopes and asserts:
#   • exit code matches expectation (0 = allow/warn, 2 = block)
#   • stderr contains "[Clawkeeper] Blocked" when expected
#   • events.log contains the expected verdict + matched_rule_id
#
# Each test runs against a per-test temp data dir so they don't share state.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOOK="${PLUGIN_ROOT}/scripts/cowork-pre-tool.sh"

if [ ! -x "$HOOK" ]; then
  echo "FAIL: hook not found or not executable: $HOOK"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 not available"
  exit 0
fi

PASS=0
FAIL=0
FAILED_NAMES=()

write_policy() {
  local dir="$1"
  cat > "${dir}/policy.json" <<'POL'
{
  "version": 42,
  "default_action": "allow",
  "rules": [
    { "id": "phi", "name": "PHI paths",
      "match": { "tool_input": { "path_regex": "(?i)(^|/)(phi|hipaa|pii)(/|$)" } },
      "action": "block",
      "reason": "PHI directories are off-limits." },
    { "id": "dotenv", "name": ".env files",
      "match": { "tool_input": { "path_glob_any": ["**/.env", "**/.env.*"] } },
      "action": "block",
      "reason": "Environment files contain secrets." },
    { "id": "external-mail", "name": "External mail",
      "match": {
        "tool_name_in": ["mail_send", "slack_send"],
        "tool_input": { "recipient_domain_not_in": ["acme.com"] }
      },
      "action": "warn",
      "reason": "Recipient is outside the approved domain list." }
  ]
}
POL
}

run_test() {
  local label="$1" expected_exit="$2" envelope="$3" expected_rule="${4:-}"

  local tmp
  tmp=$(mktemp -d)
  write_policy "$tmp"

  local stderr_file="${tmp}/stderr"
  local actual_exit
  printf '%s' "$envelope" | CLAWKEEPER_COWORK_DIR="$tmp" "$HOOK" \
    >/dev/null 2>"$stderr_file"
  actual_exit=$?

  local stderr
  stderr=$(cat "$stderr_file")

  local pass=1
  local why=""

  if [ "$actual_exit" != "$expected_exit" ]; then
    pass=0
    why="exit=${actual_exit} expected=${expected_exit}"
  fi

  if [ "$expected_exit" = "2" ]; then
    if ! printf '%s' "$stderr" | grep -q '\[Clawkeeper\] Blocked'; then
      pass=0
      why="${why}; missing '[Clawkeeper] Blocked' in stderr"
    fi
  fi

  if [ -n "$expected_rule" ] && [ -f "${tmp}/events.log" ]; then
    if ! grep -q "\"matched_rule_id\":\"${expected_rule}\"" "${tmp}/events.log"; then
      pass=0
      why="${why}; missing rule '${expected_rule}' in events.log"
    fi
  fi

  if [ "$pass" = "1" ]; then
    printf '  PASS  %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s — %s\n' "$label" "$why"
    if [ -n "$stderr" ]; then printf '        stderr: %s\n' "$stderr"; fi
    if [ -f "${tmp}/events.log" ]; then
      printf '        events: %s\n' "$(tail -n 1 "${tmp}/events.log")"
    fi
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$label")
  fi

  rm -rf "$tmp"
}

echo "Cowork Hook Tests"
echo "----------------------------------------"

# Block cases
run_test "block: list ~/Documents/PHI" \
  2 \
  '{"tool_name":"fs_list_dir","tool_input":{"path":"~/Documents/PHI"}}' \
  "phi"

run_test "block: read /Users/x/Documents/PHI/note.txt" \
  2 \
  '{"tool_name":"fs_read","tool_input":{"path":"/Users/x/Documents/PHI/note.txt"}}' \
  "phi"

run_test "block: read /Users/x/HIPAA/report.pdf (case-insensitive)" \
  2 \
  '{"tool_name":"fs_read","tool_input":{"path":"/Users/x/HIPAA/report.pdf"}}' \
  "phi"

run_test "block: read ~/.env" \
  2 \
  '{"tool_name":"fs_read","tool_input":{"path":"~/.env"}}' \
  "dotenv"

run_test "block: read ~/.env.production" \
  2 \
  '{"tool_name":"fs_read","tool_input":{"path":"~/.env.production"}}' \
  "dotenv"

# Allow cases
run_test "allow: read ~/Desktop/notes.md" \
  0 \
  '{"tool_name":"fs_read","tool_input":{"path":"~/Desktop/notes.md"}}'

run_test "allow: read README.md (no path glob match)" \
  0 \
  '{"tool_name":"fs_read","tool_input":{"path":"./README.md"}}'

run_test "allow: tool_name field uses camelCase (toolName/toolInput)" \
  0 \
  '{"toolName":"fs_read","toolInput":{"path":"./README.md"}}'

run_test "allow: warn rule does not block (external mail)" \
  0 \
  '{"tool_name":"mail_send","tool_input":{"recipient":"someone@external.com"}}'

# Edge cases (must fail-open)
run_test "fail-open: empty stdin" \
  0 \
  ''

run_test "fail-open: malformed JSON" \
  0 \
  '{not json'

run_test "fail-open: tool_input is a string (not dict)" \
  0 \
  '{"tool_name":"fs_read","tool_input":"raw string"}'

run_test "fail-open: missing tool_name" \
  0 \
  '{"tool_input":{"path":"~/Desktop/notes.md"}}'

# Stderr message format check
echo
echo "Stderr message format"
echo "----------------------------------------"
{
  TMP=$(mktemp -d)
  write_policy "$TMP"
  STDERR_OUT=$(printf '%s' '{"tool_name":"fs_list_dir","tool_input":{"path":"~/PHI"}}' \
    | CLAWKEEPER_COWORK_DIR="$TMP" "$HOOK" 2>&1 >/dev/null)
  EXPECT='[Clawkeeper] Blocked by policy "PHI paths": PHI directories are off-limits.'
  if printf '%s' "$STDERR_OUT" | grep -qF "$EXPECT"; then
    echo "  PASS  stderr matches expected attribution + message format"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  stderr did not contain expected line"
    echo "        expected: $EXPECT"
    echo "        actual:   $STDERR_OUT"
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("stderr-format")
  fi

  if printf '%s' "$STDERR_OUT" | grep -qF "Rule ID: phi · Policy version: 42"; then
    echo "  PASS  stderr includes rule ID + policy version footer"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  stderr missing rule ID + policy version footer"
    echo "        actual: $STDERR_OUT"
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("stderr-footer")
  fi
  rm -rf "$TMP"
}


echo
echo "Real Cowork envelopes (captured 2026-04-28)"
echo "----------------------------------------"

FIXTURE_DIR="${SCRIPT_DIR}/fixtures/cowork-envelopes"

run_fixture() {
  local label="$1" expected_exit="$2" fixture="$3" expected_rule="${4:-}"
  if [ ! -f "${FIXTURE_DIR}/${fixture}" ]; then
    printf '  SKIP  %s (fixture missing: %s)\n' "$label" "$fixture"
    return
  fi
  run_test "$label" "$expected_exit" "$(cat "${FIXTURE_DIR}/${fixture}")" "$expected_rule"
}

# These three fixtures are the actual envelopes Cowork sends in order when
# the user prompts "read the .env file on my Desktop". Locks in the contract
# that tool_name=Read uses tool_input.file_path (not tool_input.path).
run_fixture "real envelope: ToolSearch (allow)" \
  0 "PreToolUse-ToolSearch.json"
run_fixture "real envelope: request_cowork_directory ~/Desktop (allow)" \
  0 "PreToolUse-cowork-request_cowork_directory.json"
run_fixture "real envelope: Read /Users/jimmy/Desktop/.env (BLOCK)" \
  2 "PreToolUse-Read.json" "dotenv"

echo
echo "----------------------------------------"
printf "  passed: %d  failed: %d\n" "$PASS" "$FAIL"
echo "----------------------------------------"

if [ "$FAIL" -gt 0 ]; then
  echo "Failed: ${FAILED_NAMES[*]}"
  exit 1
fi
exit 0
