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
source "${PLUGIN_ROOT}/scripts/lib/device-key.sh" 2>/dev/null || \
  source "${PLUGIN_ROOT}/lib/device-key.sh" 2>/dev/null || true

# Fail-open trap
trap 'emit_allow; exit 0' ERR

# Read all of stdin
INPUT=$(cat 2>/dev/null) || true

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

# Resolve API key
API_KEY=$(resolve_api_key) || true

if [ -n "$API_KEY" ]; then
  # ---- API mode: forward to evaluate endpoint ----
  HOSTNAME_VAL=$(scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || printf 'unknown')
  MACHINE_ID=$(get_machine_id)
  API_TOOL="${AGENTKEEPER_API_TOOL:-claude-code}"
  if [ "$API_TOOL" = "claude-code" ]; then
    EVALUATE_URL="https://www.agentkeeper.dev/api/v1/claude-code/evaluate"
  else
    EVALUATE_URL="https://www.agentkeeper.dev/api/v1/evaluate?tool=${API_TOOL}"
  fi
  # Additive: sign the request body when a device keypair exists.
  # Plan 1 dark-launch — server records but does not yet enforce.
  SIGNED_HEADERS=()
  if agentkeeper_has_keypair 2>/dev/null; then
    TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    SIG=$(printf '%s%s' "$TS" "$INPUT" | agentkeeper_sign 2>/dev/null) || SIG=""
    if [ -n "$SIG" ]; then
      SIGNED_HEADERS+=(-H "X-Timestamp: $TS" -H "X-Device-Signature: $SIG" -H "X-Console-User: ${USER:-unknown}")
    fi
  fi
  RESPONSE=$(printf '%s' "$INPUT" | curl -s --max-time 4 --fail-with-body \
    -X POST "$EVALUATE_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "X-Hostname: ${HOSTNAME_VAL}" \
    -H "X-Machine-Id: ${MACHINE_ID}" \
    "${SIGNED_HEADERS[@]}" \
    -d @- 2>/dev/null) || true

  if [ -z "$RESPONSE" ]; then
    emit_allow
    exit 0
  fi

  printf '%s\n' "$RESPONSE"
  exit 0
fi

# ---- Local mode: run bundled detection engine ----
DETECT_SCRIPT="${PLUGIN_ROOT}/scripts/local-detect.sh"
if [ ! -x "$DETECT_SCRIPT" ]; then
  DETECT_SCRIPT="${PLUGIN_ROOT}/local-detect.sh"
fi

if [ ! -x "$DETECT_SCRIPT" ]; then
  emit_allow
  exit 0
fi

# Run local detection with type "prompt"
DETECTION=$(printf '%s' "$INPUT" | "$DETECT_SCRIPT" "prompt" 2>/dev/null) || true

if [ -z "$DETECTION" ]; then
  emit_allow
  exit 0
fi

# Parse detection result (tab-separated: PATTERN\tSEVERITY\tDESCRIPTION)
PATTERN=$(printf '%s' "$DETECTION" | cut -f1)
SEVERITY=$(printf '%s' "$DETECTION" | cut -f2)
DESCRIPTION=$(printf '%s' "$DETECTION" | cut -f3)

# Determine mode from config (default: warn)
DATA_DIR=$(get_data_dir)
MODE="warn"
CONFIG_FILE="${DATA_DIR}/config.json"
if [ -f "$CONFIG_FILE" ]; then
  CONFIGURED_MODE=$(grep -Eo '"mode"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" 2>/dev/null | head -1 | grep -Eo '"[^"]*"$' | tr -d '"') || true
  if [ "$CONFIGURED_MODE" = "block" ] || [ "$CONFIGURED_MODE" = "warn" ]; then
    MODE="$CONFIGURED_MODE"
  fi
fi

# Emit appropriate response
if [ "$MODE" = "block" ]; then
  emit_deny "UserPromptSubmit" "AgentKeeper blocked: ${PATTERN} — ${DESCRIPTION}"
else
  # Warn mode: build context message, possibly with nudge
  NUDGE_TEXT=""
  increment_blocks

  BLOCK_COUNT=$(get_block_count)

  if should_nudge; then
    if [ "$BLOCK_COUNT" -eq 1 ]; then
      NUDGE_TEXT=$(get_nudge_text "first_block" "$PATTERN")
    elif [ "$BLOCK_COUNT" -ge 5 ] && [ $(( BLOCK_COUNT % 5 )) -eq 0 ]; then
      NUDGE_TEXT=$(get_nudge_text "fifth_block" "$PATTERN")
    fi

    if [ -n "$NUDGE_TEXT" ]; then
      record_nudge
    fi
  fi

  if [ -n "$NUDGE_TEXT" ]; then
    emit_warn "UserPromptSubmit" "$PATTERN" "${DESCRIPTION}. ${NUDGE_TEXT}"
  else
    emit_warn "UserPromptSubmit" "$PATTERN" "$DESCRIPTION"
  fi
fi

exit 0
