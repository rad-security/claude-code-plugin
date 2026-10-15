#!/usr/bin/env bash
# cowork-json.sh — Python-free JSON helpers for Cowork macOS scripts.
# Requires macOS plutil for registry mutation. Extraction helpers are best-effort
# and intentionally fail open for hook/runtime diagnostics.

cowork_json_escape() {
  local str="$1"
  str="${str//\\/\\\\}"
  str="${str//\"/\\\"}"
  str="${str//$'\n'/\\n}"
  str="${str//$'\r'/\\r}"
  str="${str//$'\t'/\\t}"
  printf '%s' "$str"
}

cowork_iso_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || printf 'unknown'
}

cowork_json_string_value() {
  local field="$1"
  sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\\([^\"\\\\]*\\)\".*/\\1/p" | head -1
}

cowork_json_bool_true() {
  local path="$1"
  local keypath="$2"
  [ -f "$path" ] || return 1
  [ "$(plutil -extract "$keypath" raw -n "$path" 2>/dev/null || true)" = "true" ]
}

cowork_json_raw_value() {
  local path="$1"
  local keypath="$2"
  [ -f "$path" ] || return 1
  plutil -extract "$keypath" raw -n "$path" 2>/dev/null || true
}

cowork_json_begin() {
  COWORK_JSON_PATH="$1"
  COWORK_JSON_TMP="${COWORK_JSON_PATH}.agentkeeper.$$"
  COWORK_JSON_OUT="${COWORK_JSON_TMP}.json"
  mkdir -p "$(dirname "$COWORK_JSON_PATH")" 2>/dev/null || true
  rm -f "$COWORK_JSON_TMP" "$COWORK_JSON_OUT" 2>/dev/null || true

  if [ -f "$COWORK_JSON_PATH" ]; then
    cp "$COWORK_JSON_PATH" "$COWORK_JSON_TMP"
    if ! plutil -convert xml1 "$COWORK_JSON_TMP" >/dev/null 2>&1; then
      mv "$COWORK_JSON_PATH" "${COWORK_JSON_PATH}.malformed.$(date +%s 2>/dev/null || printf '%s' "$$")" 2>/dev/null || true
      rm -f "$COWORK_JSON_TMP" "$COWORK_JSON_OUT" 2>/dev/null || true
      plutil -create xml1 "$COWORK_JSON_TMP" >/dev/null 2>&1 || return 1
    fi
  else
    plutil -create xml1 "$COWORK_JSON_TMP" >/dev/null 2>&1 || return 1
  fi
}

cowork_json_ensure_dict() {
  local keypath="$1"
  [ -n "${COWORK_JSON_TMP:-}" ] || return 1
  if [ "$(plutil -type "$keypath" "$COWORK_JSON_TMP" 2>/dev/null || true)" = "dictionary" ]; then
    return 0
  fi
  plutil -remove "$keypath" "$COWORK_JSON_TMP" >/dev/null 2>&1 || true
  plutil -insert "$keypath" -dictionary "$COWORK_JSON_TMP" >/dev/null 2>&1
}

cowork_json_set_json() {
  local keypath="$1"
  local value="$2"
  [ -n "${COWORK_JSON_TMP:-}" ] || return 1
  plutil -replace "$keypath" -json "$value" "$COWORK_JSON_TMP" >/dev/null 2>&1 || \
    plutil -insert "$keypath" -json "$value" "$COWORK_JSON_TMP" >/dev/null 2>&1
}

cowork_json_set_bool() {
  local keypath="$1"
  local value="$2"
  [ -n "${COWORK_JSON_TMP:-}" ] || return 1
  plutil -replace "$keypath" -bool "$value" "$COWORK_JSON_TMP" >/dev/null 2>&1 || \
    plutil -insert "$keypath" -bool "$value" "$COWORK_JSON_TMP" >/dev/null 2>&1
}

cowork_json_remove() {
  local keypath="$1"
  [ -n "${COWORK_JSON_TMP:-}" ] || return 1
  plutil -remove "$keypath" "$COWORK_JSON_TMP" >/dev/null 2>&1 || true
}

cowork_json_commit() {
  [ -n "${COWORK_JSON_PATH:-}" ] || return 1
  [ -n "${COWORK_JSON_TMP:-}" ] || return 1
  plutil -convert json -r -o "$COWORK_JSON_OUT" "$COWORK_JSON_TMP" >/dev/null 2>&1 || {
    rm -f "$COWORK_JSON_TMP" "$COWORK_JSON_OUT" 2>/dev/null || true
    return 1
  }
  mv "$COWORK_JSON_OUT" "$COWORK_JSON_PATH"
  rm -f "$COWORK_JSON_TMP" 2>/dev/null || true
  unset COWORK_JSON_PATH COWORK_JSON_TMP COWORK_JSON_OUT
}
