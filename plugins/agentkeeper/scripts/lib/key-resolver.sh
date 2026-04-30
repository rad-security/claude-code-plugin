#!/usr/bin/env bash
# key-resolver.sh — Resolve AgentKeeper API key from multiple sources
# Sourced by hook dispatcher scripts. No top-level execution.

# Return the data directory path and ensure it exists.
# Uses $CLAUDE_PLUGIN_DATA if set, otherwise ~/.agentkeeper-plugin.
# Usage: dir=$(get_data_dir)
get_data_dir() {
  local dir="${CLAUDE_PLUGIN_DATA:-$HOME/.agentkeeper-plugin}"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir" 2>/dev/null
  fi
  printf '%s' "$dir"
}

# Resolve the AgentKeeper API key by checking sources in priority order:
#   1. $CLAUDE_PLUGIN_OPTION_API_KEY environment variable
#   2. File at $(get_data_dir)/api_key
#   3. .claude/settings.json in current directory (Bearer ak_live_ pattern)
#   4. Empty string if nothing found
# Usage: key=$(resolve_api_key)
resolve_api_key() {
  # 0. Global environment variable (MDM/enterprise deployment)
  if [ -n "${AGENTKEEPER_API_KEY:-}" ]; then
    printf '%s' "$AGENTKEEPER_API_KEY"
    return 0
  fi

  # 1. Environment variable (highest priority)
  if [ -n "${CLAUDE_PLUGIN_OPTION_API_KEY:-}" ]; then
    printf '%s' "$CLAUDE_PLUGIN_OPTION_API_KEY"
    return 0
  fi

  # 2. Stored key file
  local data_dir
  data_dir=$(get_data_dir)
  local key_file="${data_dir}/api_key"
  if [ -f "$key_file" ]; then
    local stored_key
    stored_key=$(cat "$key_file" 2>/dev/null)
    # Trim whitespace
    stored_key="${stored_key#"${stored_key%%[![:space:]]*}"}"
    stored_key="${stored_key%"${stored_key##*[![:space:]]}"}"
    if [ -n "$stored_key" ]; then
      printf '%s' "$stored_key"
      return 0
    fi
  fi

  # 2b. Multi-IDE shared key file
  local shared_key_file="$HOME/.agentkeeper/config/api_key"
  if [ -f "$shared_key_file" ]; then
    local shared_key
    shared_key=$(cat "$shared_key_file" 2>/dev/null)
    shared_key="${shared_key#"${shared_key%%[![:space:]]*}"}"
    shared_key="${shared_key%"${shared_key##*[![:space:]]}"}"
    if [ -n "$shared_key" ]; then
      printf '%s' "$shared_key"
      return 0
    fi
  fi

  # 3. Extract from .claude/settings.json in current directory
  local settings_file=".claude/settings.json"
  if [ -f "$settings_file" ]; then
    local found_key
    # Look for Bearer ak_live_ pattern and extract the key
    found_key=$(grep -Eo 'Bearer ak_live_[A-Za-z0-9_-]+' "$settings_file" 2>/dev/null | head -1)
    if [ -n "$found_key" ]; then
      # Strip the "Bearer " prefix to return just the key
      found_key="${found_key#Bearer }"
      printf '%s' "$found_key"
      return 0
    fi
  fi

  # 4. Nothing found — return empty string
  printf ''
  return 1
}
