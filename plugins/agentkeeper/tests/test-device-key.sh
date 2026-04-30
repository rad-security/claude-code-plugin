#!/usr/bin/env bash
# test-device-key.sh — Smoke tests for device-key.sh.
# Exercises: generate → has → public-key derive → sign → roundtrip verify (via openssl) → delete.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$PLUGIN_DIR/scripts/lib/device-key.sh"

# Use a throwaway data dir to avoid touching the user's real key.
export CLAUDE_PLUGIN_DATA="$(mktemp -d)"
trap 'rm -rf "$CLAUDE_PLUGIN_DATA"; agentkeeper_delete_keypair' EXIT

fail=0
step() { printf '  • %s ... ' "$1"; }
pass() { printf 'ok\n'; }
bad() { printf 'FAIL\n    %s\n' "$1" >&2; fail=$((fail + 1)); }

echo "test-device-key.sh"

step "clean slate: no keypair stored"
agentkeeper_delete_keypair
if agentkeeper_has_keypair; then
  bad "agentkeeper_has_keypair unexpectedly returned true"
else
  pass
fi

step "agentkeeper_generate_keypair emits base64 public key"
pub="$(agentkeeper_generate_keypair)"
if [ -z "$pub" ]; then
  bad "empty public key"
elif ! printf '%s' "$pub" | base64 -d >/dev/null 2>&1; then
  bad "public key is not valid base64: $pub"
else
  pass
fi

step "agentkeeper_has_keypair true after generate"
if agentkeeper_has_keypair; then pass; else bad "false after generate"; fi

step "agentkeeper_public_key_b64 matches what agentkeeper_generate_keypair returned"
pub2="$(agentkeeper_public_key_b64)"
if [ "$pub" = "$pub2" ]; then pass; else bad "mismatch: '$pub' vs '$pub2'"; fi

step "agentkeeper_sign emits non-empty base64 over a test payload"
ts="2026-04-22T00:00:00Z"
body='{"context":"claude_code"}'
sig="$(printf '%s%s' "$ts" "$body" | agentkeeper_sign)"
if [ -z "$sig" ]; then
  bad "empty signature"
elif ! printf '%s' "$sig" | base64 -d >/dev/null 2>&1; then
  bad "signature not valid base64"
else
  pass
fi

step "signature verifies with openssl against the derived public key"
pub_der="$(mktemp)"; trap 'rm -f "$pub_der"' RETURN
printf '%s' "$pub" | base64 -d > "$pub_der"
sig_file="$(mktemp)"; trap 'rm -f "$sig_file" "$pub_der"' RETURN
printf '%s' "$sig" | base64 -d > "$sig_file"
payload_file="$(mktemp)"; trap 'rm -f "$sig_file" "$pub_der" "$payload_file"' RETURN
printf '%s%s' "$ts" "$body" > "$payload_file"
if openssl pkeyutl -verify -pubin -inkey "$pub_der" -keyform DER -rawin -sigfile "$sig_file" -in "$payload_file" >/dev/null 2>&1; then
  pass
else
  bad "openssl pkeyutl -verify failed"
fi

step "agentkeeper_delete_keypair clears the key"
agentkeeper_delete_keypair
if agentkeeper_has_keypair; then
  bad "key still present after delete"
else
  pass
fi

if [ $fail -gt 0 ]; then
  echo "FAIL ($fail failure(s))" >&2
  exit 1
fi
echo "PASS"
