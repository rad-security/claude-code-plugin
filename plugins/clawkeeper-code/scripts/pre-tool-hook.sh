#!/usr/bin/env bash
# pre-tool-hook.sh — PreToolUse dispatcher (local or API)
# Reads tool call JSON from stdin, runs detection, outputs hook response to stdout.
# ALWAYS fail-open: any error → output {} and exit 0.

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Source shared libraries
source "${PLUGIN_ROOT}/scripts/lib/json-helpers.sh"
source "${PLUGIN_ROOT}/scripts/lib/key-resolver.sh"
source "${PLUGIN_ROOT}/scripts/lib/conflict-check.sh"
source "${PLUGIN_ROOT}/scripts/lib/nudge.sh"

# Fail-open trap: on any unexpected error, emit allow and exit cleanly
trap 'emit_allow; exit 0' ERR

# Read all of stdin
INPUT=$(cat 2>/dev/null) || true

# If stdin was empty, nothing to evaluate
if [ -z "$INPUT" ]; then
  emit_allow
  exit 0
fi

# If HTTP-based Clawkeeper hooks are already active, defer to avoid double-evaluation
if has_clawkeeper_http_hooks; then
  emit_allow
  exit 0
fi

# Resolve API key
API_KEY=$(resolve_api_key) || true

if [ -n "$API_KEY" ]; then
  # ---- API mode: forward to Clawkeeper evaluate endpoint ----
  HOSTNAME_VAL=$(scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || printf 'unknown')
  RESPONSE=$(printf '%s' "$INPUT" | curl -s --max-time 4 --fail-with-body \
    -X POST "https://clawkeeper.dev/api/v1/claude-code/evaluate" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "X-Hostname: ${HOSTNAME_VAL}" \
    -d @- 2>/dev/null) || true

  # If curl failed or returned empty, fail-open
  if [ -z "$RESPONSE" ]; then
    emit_allow
    exit 0
  fi

  # Return API response verbatim
  printf '%s\n' "$RESPONSE"
  exit 0
fi

# ---- Local mode: run bundled detection engine ----
DETECT_SCRIPT="${PLUGIN_ROOT}/scripts/local-detect.sh"

if [ ! -x "$DETECT_SCRIPT" ]; then
  # Detection engine not available — fail-open
  emit_allow
  exit 0
fi

# Run local detection; output is tab-separated: PATTERN\tSEVERITY\tDESCRIPTION
DETECTION=$(printf '%s' "$INPUT" | "$DETECT_SCRIPT" "pre_tool" 2>/dev/null) || true

if [ -z "$DETECTION" ]; then
  # No detection — allow
  emit_allow
  exit 0
fi

# Parse detection result (tab-separated)
PATTERN=$(printf '%s' "$DETECTION" | cut -f1)
SEVERITY=$(printf '%s' "$DETECTION" | cut -f2)
DESCRIPTION=$(printf '%s' "$DETECTION" | cut -f3)

# Determine mode: check config.json for mode setting (default: warn)
DATA_DIR=$(get_data_dir)
MODE="warn"
CONFIG_FILE="${DATA_DIR}/config.json"
if [ -f "$CONFIG_FILE" ]; then
  CONFIGURED_MODE=$(grep -Eo '"mode"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" 2>/dev/null | head -1 | grep -Eo '"[^"]*"$' | tr -d '"') || true
  if [ "$CONFIGURED_MODE" = "block" ] || [ "$CONFIGURED_MODE" = "warn" ]; then
    MODE="$CONFIGURED_MODE"
  fi
fi

# Emit appropriate response based on mode
if [ "$MODE" = "block" ]; then
  emit_deny "PreToolUse" "Clawkeeper blocked: ${PATTERN} — ${DESCRIPTION}"
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
    # Append nudge to description
    emit_warn "PreToolUse" "$PATTERN" "${DESCRIPTION}. ${NUDGE_TEXT}"
  else
    emit_warn "PreToolUse" "$PATTERN" "$DESCRIPTION"
  fi
fi

exit 0
