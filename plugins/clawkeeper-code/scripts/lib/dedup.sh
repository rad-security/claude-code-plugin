#!/usr/bin/env bash
# dedup.sh — flock-based event deduplication
# Prevents duplicate events when multiple hook sources fire for the same action.
# Sourced by adapter scripts. No top-level execution.
# Depends on: key-resolver.sh (for get_data_dir)

# Check if an event with this key was already processed within TTL seconds.
# Returns 0 (true) if this is a DUPLICATE (skip it).
# Returns 1 (false) if this is NEW (process it).
# Usage: if is_duplicate "cursor:beforeShellExecution:gen_abc123"; then skip; fi
is_duplicate() {
  local key="$1"
  local ttl=5
  local seen_file
  seen_file="$(get_data_dir)/seen.json"

  # Create file if missing
  if [ ! -f "$seen_file" ]; then
    printf '[]\n' > "$seen_file"
  fi

  local now_ep
  now_ep=$(date -u +%s)

  # Acquire lock: prefer flock (Linux), fall back to mkdir-based lock (macOS)
  local lock_file="${seen_file}.lock"
  local _dedup_result

  if command -v flock >/dev/null 2>&1; then
    # flock path (Linux)
    (
      flock -w 1 200 || return 1
      _dedup_core "$key" "$seen_file" "$now_ep" "$ttl"
    ) 200>"$lock_file"
    _dedup_result=$?
  else
    # mkdir-based atomic lock (macOS / systems without flock)
    local lock_dir="${lock_file}.d"
    local lock_attempts=0
    while ! mkdir "$lock_dir" 2>/dev/null; do
      lock_attempts=$(( lock_attempts + 1 ))
      if [ "$lock_attempts" -ge 10 ]; then
        # Stale lock — remove and retry once
        rmdir "$lock_dir" 2>/dev/null || true
        break
      fi
      sleep 0.1
    done
    _dedup_core "$key" "$seen_file" "$now_ep" "$ttl"
    _dedup_result=$?
    rmdir "$lock_dir" 2>/dev/null || true
  fi

  return $_dedup_result
}

# Internal: read/write seen.json while lock is held.
# Returns 0 = duplicate, 1 = new.
_dedup_core() {
  local key="$1"
  local seen_file="$2"
  local now_ep="$3"
  local ttl="$4"

  local found=false
  local new_entries="["
  local first=true

  while IFS= read -r line; do
    local entry_key entry_ts
    entry_key=$(printf '%s' "$line" | grep -oE '"key":"[^"]*"' | head -1 | sed 's/"key":"//;s/"//')
    entry_ts=$(printf '%s' "$line" | grep -oE '"ts":[0-9]+' | head -1 | sed 's/"ts"://')

    [ -z "$entry_key" ] && continue
    [ -z "$entry_ts" ] && continue

    local age=$(( now_ep - entry_ts ))
    [ "$age" -ge "$ttl" ] && continue

    if [ "$entry_key" = "$key" ]; then
      found=true
    fi

    if [ "$first" = true ]; then
      first=false
    else
      new_entries="${new_entries},"
    fi
    new_entries="${new_entries}{\"key\":\"${entry_key}\",\"ts\":${entry_ts}}"
  done < <(grep -oE '\{[^}]+\}' "$seen_file" 2>/dev/null | tail -100)

  if [ "$found" = false ]; then
    if [ "$first" = true ]; then
      first=false
    else
      new_entries="${new_entries},"
    fi
    new_entries="${new_entries}{\"key\":\"${key}\",\"ts\":${now_ep}}"
  fi

  new_entries="${new_entries}]"
  printf '%s\n' "$new_entries" > "$seen_file"

  if [ "$found" = true ]; then
    return 0
  else
    return 1
  fi
}
