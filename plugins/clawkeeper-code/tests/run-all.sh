#!/usr/bin/env bash
# run-all.sh — Master test runner for Clawkeeper Claude Code plugin
# Runs all test suites and prints an aggregated summary.
#
# Exit code: 0 if all suites pass, 1 if any fail.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SUITES_RUN=0
SUITES_PASSED=0
SUITES_FAILED=0
FAILED_NAMES=()

# Colors (if tty)
if [ -t 1 ]; then
  GREEN='\033[0;32m'
  RED='\033[0;31m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  GREEN='' RED='' BOLD='' NC=''
fi

echo ""
printf "${BOLD}Clawkeeper Plugin — Test Runner${NC}\n"
echo "========================================"
echo ""

run_suite() {
  local name="$1"
  local script="$2"

  SUITES_RUN=$((SUITES_RUN + 1))
  printf "${BOLD}Running: %s${NC}\n" "$name"
  echo "----------------------------------------"

  if bash "$script"; then
    SUITES_PASSED=$((SUITES_PASSED + 1))
    printf "${GREEN}Suite passed: %s${NC}\n\n" "$name"
  else
    SUITES_FAILED=$((SUITES_FAILED + 1))
    FAILED_NAMES+=("$name")
    printf "${RED}Suite FAILED: %s${NC}\n\n" "$name"
  fi
}

# ── Run all suites ─────────────────────────────────────────────────────────

run_suite "Local Detection Engine" "${SCRIPT_DIR}/test-local-detect.sh"
run_suite "Hook Dispatchers" "${SCRIPT_DIR}/test-hooks.sh"

# ── Final Summary ──────────────────────────────────────────────────────────

echo "========================================"
printf "${BOLD}Final Summary${NC}\n"
echo "========================================"
printf "Suites run:    %d\n" "$SUITES_RUN"
printf "Suites passed: %d\n" "$SUITES_PASSED"
printf "Suites failed: %d\n" "$SUITES_FAILED"

if [ "$SUITES_FAILED" -gt 0 ]; then
  echo ""
  printf "${RED}Failed suites:${NC}\n"
  for name in "${FAILED_NAMES[@]}"; do
    printf "  - %s\n" "$name"
  done
  echo ""
  echo "========================================"
  exit 1
fi

echo ""
printf "${GREEN}All test suites passed.${NC}\n"
echo "========================================"
exit 0
