#!/usr/bin/env bash
# debug-log.sh — Debug logging for hook execution
# Sourced by adapter scripts. No top-level execution.
# Depends on: key-resolver.sh (for get_data_dir)

# Maximum log file size in bytes (1MB)
_DEBUG_LOG_MAX_SIZE=1048576

# Write a debug log entry.
# Usage: debug_log "cursor" "beforeShellExecution" "1.0.0" 12 142 "warn" "warned" 0
debug_log() {
  local ide="$1"
  local event="$2"
  local version="$3"
  local detect_ms="$4"
  local api_ms="$5"
  local verdict="$6"
  local enforcement="$7"
  local exit_code="$8"

  local log_file
  log_file="$(get_data_dir)/debug.log"

  # Rotate if too large
  if [ -f "$log_file" ]; then
    local size
    size=$(wc -c < "$log_file" 2>/dev/null | tr -d ' ')
    if [ "${size:-0}" -ge "$_DEBUG_LOG_MAX_SIZE" ]; then
      mv -f "$log_file" "${log_file}.1" 2>/dev/null || true
    fi
  fi

  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  printf '%s %s %s v%s detect=%sms api=%sms verdict=%s enforcement=%s exit=%s\n' \
    "$ts" "$ide" "$event" "$version" "$detect_ms" "$api_ms" "$verdict" "$enforcement" "$exit_code" \
    >> "$log_file" 2>/dev/null || true
}
