#!/usr/bin/env bash
# integrity.sh — Script tamper detection via SHA256 manifest
# Sourced by session-start.sh. No top-level execution.
# Depends on: key-resolver.sh (for get_data_dir)

# Check script integrity against the stored manifest.
# Returns tab-separated list of tampered files, or empty string if all OK.
# Usage: tampered=$(check_integrity "/path/to/scripts")
check_integrity() {
  local scripts_dir="$1"
  local manifest_file
  manifest_file="$(get_data_dir)/manifest.json"

  if [ ! -f "$manifest_file" ]; then
    printf ''
    return 0
  fi

  local tampered=""

  while IFS= read -r line; do
    local file_rel hash_expected
    file_rel=$(printf '%s' "$line" | grep -oE '"[^"]+":' | head -1 | tr -d '":')
    hash_expected=$(printf '%s' "$line" | grep -oE '"sha256:[^"]*"' | head -1 | tr -d '"' | sed 's/sha256://')

    [ -z "$file_rel" ] && continue
    [ -z "$hash_expected" ] && continue

    local file_abs="${scripts_dir}/${file_rel}"
    if [ ! -f "$file_abs" ]; then
      tampered="${tampered}${file_rel}(missing) "
      continue
    fi

    local hash_actual
    hash_actual=$(shasum -a 256 "$file_abs" 2>/dev/null | cut -d' ' -f1)
    if [ -z "$hash_actual" ]; then
      continue
    fi

    if [ "$hash_actual" != "$hash_expected" ]; then
      tampered="${tampered}${file_rel}(modified) "
    fi
  done < <(grep -oE '"[^"]+":"sha256:[^"]*"' "$manifest_file" 2>/dev/null)

  printf '%s' "$tampered"
}

# Generate a manifest for all scripts in a directory.
# Writes to $(get_data_dir)/manifest.json.
# Usage: generate_manifest "/path/to/scripts" ["1.0.0"]
generate_manifest() {
  local scripts_dir="$1"
  local manifest_file
  manifest_file="$(get_data_dir)/manifest.json"
  local version="${2:-1.0.0}"

  local entries=""
  local first=true
  while IFS= read -r file; do
    local rel="${file#${scripts_dir}/}"
    local hash
    hash=$(shasum -a 256 "$file" 2>/dev/null | cut -d' ' -f1)
    [ -z "$hash" ] && continue

    if [ "$first" = true ]; then
      first=false
    else
      entries="${entries},"
    fi
    entries="${entries}\"${rel}\":\"sha256:${hash}\""
  done < <(find "$scripts_dir" -name '*.sh' -type f 2>/dev/null | sort)

  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"version":"%s","installed_at":"%s","files":{%s}}\n' \
    "$version" "$now" "$entries" > "$manifest_file"
}
