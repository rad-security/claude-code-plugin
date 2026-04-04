#!/usr/bin/env bash
# nudge.sh — Rate-limited nudge system for unauthenticated users
# Sourced by hook dispatcher scripts. No top-level execution.
# Depends on: key-resolver.sh (for get_data_dir)

# ---------------------------------------------------------------------------
# Portable timestamp helpers
# ---------------------------------------------------------------------------

# Convert an ISO 8601 timestamp (YYYY-MM-DDTHH:MM:SSZ) to epoch seconds.
# Works on both macOS (BSD date) and Linux (GNU date).
# Usage: epoch=$(to_epoch "2026-03-30T12:00:00Z")
to_epoch() {
  local ts="$1"
  local epoch

  # Try GNU date first (Linux)
  epoch=$(date -d "$ts" +%s 2>/dev/null)
  if [ $? -eq 0 ] && [ -n "$epoch" ]; then
    printf '%s' "$epoch"
    return 0
  fi

  # Fall back to BSD date (macOS)
  # Strip the trailing Z and convert
  local stripped="${ts%Z}"
  epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
  if [ $? -eq 0 ] && [ -n "$epoch" ]; then
    printf '%s' "$epoch"
    return 0
  fi

  # Last resort: return 0
  printf '0'
  return 1
}

# Return current UTC time in ISO 8601 format.
# Usage: now=$(now_iso)
now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# Return current UTC time as epoch seconds.
# Usage: epoch=$(now_epoch)
now_epoch() {
  date -u +%s
}

# ---------------------------------------------------------------------------
# State file I/O (no jq dependency — pure grep/sed)
# ---------------------------------------------------------------------------

# State file path
_nudge_state_file() {
  local data_dir
  data_dir=$(get_data_dir)
  printf '%s/nudge_state.json' "$data_dir"
}

# Read a string value from the state file.
# Usage: val=$(_read_state_field "field_name")
_read_state_field() {
  local field="$1"
  local state_file
  state_file=$(_nudge_state_file)

  if [ ! -f "$state_file" ]; then
    printf ''
    return 1
  fi

  # Match "field":"value" or "field": "value" — extract the value
  local val
  val=$(grep -Eo "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$state_file" 2>/dev/null | head -1)
  if [ -n "$val" ]; then
    # Strip everything up to and including the colon and opening quote
    val="${val#*:}"
    # Trim whitespace
    val="${val#"${val%%[![:space:]]*}"}"
    # Strip surrounding quotes
    val="${val#\"}"
    val="${val%\"}"
    printf '%s' "$val"
    return 0
  fi

  printf ''
  return 1
}

# Read a numeric value from the state file.
# Usage: val=$(_read_state_number "field_name")
_read_state_number() {
  local field="$1"
  local state_file
  state_file=$(_nudge_state_file)

  if [ ! -f "$state_file" ]; then
    printf '0'
    return 1
  fi

  # Match "field":N or "field": N (unquoted number)
  local val
  val=$(grep -Eo "\"${field}\"[[:space:]]*:[[:space:]]*[0-9]+" "$state_file" 2>/dev/null | head -1)
  if [ -n "$val" ]; then
    # Extract just the number
    val=$(printf '%s' "$val" | grep -Eo '[0-9]+$')
    printf '%s' "$val"
    return 0
  fi

  printf '0'
  return 1
}

# Write the full state file (overwrites).
# Usage: _write_state "iso_timestamp" total_blocks nudges_shown "session_id" "week_start_iso"
_write_state() {
  local last_nudge_at="$1"
  local total_blocks="$2"
  local nudges_shown="$3"
  local session_id="$4"
  local week_start="$5"
  local state_file
  state_file=$(_nudge_state_file)

  printf '{"last_nudge_at":"%s","total_blocks":%d,"nudges_shown":%d,"session_id":"%s","week_start":"%s"}\n' \
    "$last_nudge_at" "$total_blocks" "$nudges_shown" "$session_id" "$week_start" \
    > "$state_file"
}

# Initialize the state file if it does not exist.
_ensure_state() {
  local state_file
  state_file=$(_nudge_state_file)
  if [ ! -f "$state_file" ]; then
    _write_state "" 0 0 "" "$(now_iso)"
  fi
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# Check if a nudge is allowed right now.
# Rules: max 1 nudge per session, max 3 nudges per week.
# Returns 0 (true) if nudge is allowed, 1 (false) otherwise.
# Usage: if should_nudge; then ... fi
should_nudge() {
  _ensure_state

  local current_session="${CLAUDE_SESSION_ID:-unknown}"
  local stored_session
  stored_session=$(_read_state_field "session_id")

  # Rule 1: max 1 per session — if we already nudged in this session, deny
  if [ -n "$stored_session" ] && [ "$stored_session" = "$current_session" ]; then
    local last_nudge
    last_nudge=$(_read_state_field "last_nudge_at")
    if [ -n "$last_nudge" ]; then
      return 1
    fi
  fi

  # Rule 2: max 3 per week
  local week_start
  week_start=$(_read_state_field "week_start")
  local nudges_shown
  nudges_shown=$(_read_state_number "nudges_shown")
  local now_ep
  now_ep=$(now_epoch)

  if [ -n "$week_start" ]; then
    local week_start_ep
    week_start_ep=$(to_epoch "$week_start")
    local seconds_per_week=604800  # 7 * 24 * 60 * 60

    # If more than a week has passed, reset the counter
    local elapsed=$(( now_ep - week_start_ep ))
    if [ "$elapsed" -ge "$seconds_per_week" ]; then
      # Week rolled over — reset nudge counter (will be written by record_nudge)
      return 0
    fi

    # Within the same week — check count
    if [ "$nudges_shown" -ge 3 ]; then
      return 1
    fi
  fi

  return 0
}

# Record that a nudge was just shown.
# Updates last_nudge_at, nudges_shown, session_id, and resets week if needed.
# Usage: record_nudge
record_nudge() {
  _ensure_state

  local now
  now=$(now_iso)
  local now_ep
  now_ep=$(now_epoch)
  local current_session="${CLAUDE_SESSION_ID:-unknown}"

  local total_blocks
  total_blocks=$(_read_state_number "total_blocks")
  local nudges_shown
  nudges_shown=$(_read_state_number "nudges_shown")
  local week_start
  week_start=$(_read_state_field "week_start")

  # Check if week needs resetting
  if [ -n "$week_start" ]; then
    local week_start_ep
    week_start_ep=$(to_epoch "$week_start")
    local elapsed=$(( now_ep - week_start_ep ))
    if [ "$elapsed" -ge 604800 ]; then
      week_start="$now"
      nudges_shown=0
    fi
  else
    week_start="$now"
  fi

  nudges_shown=$(( nudges_shown + 1 ))

  _write_state "$now" "$total_blocks" "$nudges_shown" "$current_session" "$week_start"
}

# Increment the total_blocks counter by 1.
# Usage: increment_blocks
increment_blocks() {
  _ensure_state

  local last_nudge_at
  last_nudge_at=$(_read_state_field "last_nudge_at")
  local total_blocks
  total_blocks=$(_read_state_number "total_blocks")
  local nudges_shown
  nudges_shown=$(_read_state_number "nudges_shown")
  local session_id
  session_id=$(_read_state_field "session_id")
  local week_start
  week_start=$(_read_state_field "week_start")

  total_blocks=$(( total_blocks + 1 ))

  _write_state "$last_nudge_at" "$total_blocks" "$nudges_shown" "$session_id" "$week_start"
}

# Return the current total_blocks count.
# Usage: count=$(get_block_count)
get_block_count() {
  _ensure_state
  _read_state_number "total_blocks"
}

# Return nudge text for the given trigger type.
# Usage: text=$(get_nudge_text "first_block" "secret-in-env")
get_nudge_text() {
  local trigger="$1"
  local pattern_name="$2"

  case "$trigger" in
    first_block)
      printf 'Clawkeeper caught %s. Running in local mode — connect your free account for dashboard visibility: /clawkeeper:connect' \
        "$pattern_name"
      ;;
    fifth_block)
      printf 'Clawkeeper has caught 5 threats. Your free dashboard tracks all of these with full context. /clawkeeper:connect'
      ;;
    session_start)
      printf 'Clawkeeper: protecting this session locally. Free dashboard available at clawkeeper.dev'
      ;;
    *)
      printf ''
      ;;
  esac
}
