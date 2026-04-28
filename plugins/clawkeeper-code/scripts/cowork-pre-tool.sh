#!/usr/bin/env bash
# cowork-pre-tool.sh — Clawkeeper Cowork PreToolUse guardrail (shell wrapper).
#
# Cowork pipes a PreToolUse JSON envelope to stdin. We forward it to the
# Python evaluator. The evaluator decides allow / warn / block, writes a
# JSONL audit row, and exits 0 (allow|warn) or 2 (block) with a stderr
# message that Cowork's model surfaces to the user verbatim.
#
# This script fails OPEN by design: any error here yields exit 0 with a
# "hook_error" log entry. A misconfigured guardrail must never brick Cowork.
# Customers who want fail-closed behavior set enforcement_mode: "strict" in
# policy.json (handled inside the Python evaluator).

set -u

DATA_DIR="${CLAWKEEPER_COWORK_DIR:-${HOME}/.clawkeeper/cowork}"
POLICY_FILE="${DATA_DIR}/policy.json"
EVENTS_LOG="${DATA_DIR}/events.log"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EVALUATOR="${CLAWKEEPER_COWORK_EVALUATOR:-${SCRIPT_DIR}/cowork-pre-tool.py}"

mkdir -p "${DATA_DIR}" 2>/dev/null || true

log_hook_error() {
  local reason="$1"
  printf '{"ts":"%s","verdict":"hook_error","reason":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${reason}" \
    >> "${EVENTS_LOG}" 2>/dev/null || true
}

if ! command -v python3 >/dev/null 2>&1; then
  log_hook_error "python3_not_found"
  exit 0
fi

if [ ! -f "${EVALUATOR}" ]; then
  log_hook_error "evaluator_not_installed"
  exit 0
fi

exec python3 "${EVALUATOR}" "${POLICY_FILE}" "${EVENTS_LOG}"
