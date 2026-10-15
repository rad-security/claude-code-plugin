#!/usr/bin/env bash
# Exact Cowork selected-folder mappings from Claude's local session metadata.
# This helper is bounded and fail-open: any missing tool, malformed JSON, or
# ambiguous metadata returns the original hook payload unchanged.

cowork_plutil_value() {
  local file="$1"
  local keypath="$2"
  local value
  value="$(plutil -extract "$keypath" raw -o - "$file" 2>/dev/null)" || return 1
  printf '%s' "$value"
}

cowork_find_session_metadata() {
  local session_id="$1"
  local root file resolved matches cache_dir cache_file cached

  [ -n "$session_id" ] || return 1
  [ "${#session_id}" -le 128 ] || return 1
  case "$session_id" in *[!A-Za-z0-9._:-]*) return 1 ;; esac
  printf '%s' "$session_id" | grep -Eq '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' || return 1
  command -v plutil >/dev/null 2>&1 || return 1

  cache_dir="${STATE_DIR:-${HOME}/.agentkeeper}/cowork-session-metadata"
  cache_file="${cache_dir}/${session_id}.path"
  if [ -f "$cache_file" ]; then
    cached="$(sed -n '1p' "$cache_file" 2>/dev/null || true)"
    if [ -f "$cached" ]; then
      resolved="$(cowork_plutil_value "$cached" cliSessionId 2>/dev/null || true)"
      if [ "$resolved" = "$session_id" ]; then
        printf '%s' "$cached"
        return 0
      fi
    fi
  fi

  for root in \
    "${HOME}/Library/Application Support/Claude/local-agent-mode-sessions" \
    "${XDG_CONFIG_HOME:-${HOME}/.config}/Claude/local-agent-mode-sessions"; do
    [ -d "$root" ] || continue
    # grep scans the bounded-size metadata in a few processes. Only the first
    # sixteen textual candidates are parsed with plutil and exact-matched.
    matches="$(find "$root" -maxdepth 5 -type f -name 'local_*.json' -size -262145c -print0 2>/dev/null \
      | xargs -0 grep -F -l -m 1 -- "$session_id" 2>/dev/null | head -16)"
    while IFS= read -r file; do
      [ -f "$file" ] || continue
      resolved="$(cowork_plutil_value "$file" cliSessionId 2>/dev/null || true)"
      if [ "$resolved" = "$session_id" ]; then
        mkdir -p "$cache_dir" 2>/dev/null || true
        chmod 700 "$cache_dir" 2>/dev/null || true
        printf '%s\n' "$file" > "${cache_file}.tmp.$$" 2>/dev/null && \
          mv "${cache_file}.tmp.$$" "$cache_file" 2>/dev/null || true
        printf '%s' "$file"
        return 0
      fi
    done <<EOF_FILES
$matches
EOF_FILES
  done
  return 1
}

cowork_session_mounts_json() {
  local session_id="$1"
  local metadata index kind_index host_root display kind mount_name entry mappings matched

  metadata="$(cowork_find_session_metadata "$session_id" 2>/dev/null || true)"
  [ -n "$metadata" ] && [ -f "$metadata" ] || return 1

  mappings=""
  index=0
  while [ "$index" -lt 16 ]; do
    host_root="$(cowork_plutil_value "$metadata" "userSelectedFolders.${index}" 2>/dev/null || true)"
    [ -n "$host_root" ] || break
    index=$((index + 1))

    [ "${#host_root}" -le 2048 ] || continue
    case "$host_root" in
      /*) ;;
      *) continue ;;
    esac
    case "/${host_root#/}/" in */../*|*/./*) continue ;; esac
    case "$host_root" in *$'\n'*|*$'\r'*) continue ;; esac

    matched=0
    kind_index=0
    while [ "$kind_index" -lt 32 ]; do
      display="$(cowork_plutil_value "$metadata" "resolvedFolderKinds.${kind_index}.display" 2>/dev/null || true)"
      kind="$(cowork_plutil_value "$metadata" "resolvedFolderKinds.${kind_index}.kind" 2>/dev/null || true)"
      if [ "$display" = "$host_root" ] && [ "$kind" = "local" ]; then
        matched=1
        break
      fi
      [ -n "$display" ] || break
      kind_index=$((kind_index + 1))
    done
    [ "$matched" -eq 1 ] || continue

    host_root="${host_root%/}"
    mount_name="${host_root##*/}"
    [ -n "$mount_name" ] && [ "${#mount_name}" -le 128 ] || continue
    case "$mount_name" in .|..|*/*|*\\*|*$'\n'*|*$'\r'*) continue ;; esac

    entry='{"mount_name":"'"$(cowork_json_escape "$mount_name")"'","host_root":"'"$(cowork_json_escape "$host_root")"'","source":"claude_session_metadata","confidence":"exact"}'
    if [ -n "$mappings" ]; then mappings="${mappings},${entry}"; else mappings="$entry"; fi
  done

  [ -n "$mappings" ] || return 1
  printf '[%s]' "$mappings"
}

cowork_enrich_mounts_payload() {
  local payload="$1"
  local session_id="$2"
  local mappings tmp enriched

  mappings="$(cowork_session_mounts_json "$session_id" 2>/dev/null || true)"
  if [ -z "$mappings" ]; then
    printf '%s' "$payload"
    return 0
  fi

  tmp="$(mktemp "${TMPDIR:-/tmp}/agentkeeper-cowork-mounts.XXXXXX" 2>/dev/null || true)"
  if [ -z "$tmp" ]; then
    printf '%s' "$payload"
    return 0
  fi
  printf '%s' "$payload" > "$tmp" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null || true
    printf '%s' "$payload"
    return 0
  }

  plutil -replace agentkeeper_cowork_mounts -json "$mappings" "$tmp" >/dev/null 2>&1 || \
    plutil -insert agentkeeper_cowork_mounts -json "$mappings" "$tmp" >/dev/null 2>&1 || true
  enriched="$(plutil -convert json -o - "$tmp" 2>/dev/null || true)"
  rm -f "$tmp" 2>/dev/null || true
  printf '%s' "${enriched:-$payload}"
}
