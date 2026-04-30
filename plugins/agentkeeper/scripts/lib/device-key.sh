#!/usr/bin/env bash
# device-key.sh — ed25519 device keypair generation, storage, and signing.
#
# Storage priority:
#   macOS → Keychain (security add-generic-password)
#   Linux → libsecret (secret-tool) if present, else file fallback
#   Other → file fallback
#
# File fallback: $(get_data_dir)/device_key.pem with chmod 0600.
#
# Sourced by hook dispatchers and enrollment scripts. No top-level execution.

set -euo pipefail

# Resolve helpers — we source, caller may also have sourced these already, harmless.
_AGENTKEEPER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$_AGENTKEEPER_LIB_DIR/machine-id.sh"
# shellcheck disable=SC1091
source "$_AGENTKEEPER_LIB_DIR/key-resolver.sh"

AGENTKEEPER_KEY_SERVICE="agentkeeper"
AGENTKEEPER_KEY_LABEL="agentkeeper-device-ed25519"
AGENTKEEPER_KEY_FILE_FALLBACK() { printf '%s/device_key.pem' "$(get_data_dir)"; }

agentkeeper_platform() {
  case "$(uname -s)" in
    Darwin) echo macos ;;
    Linux)  echo linux ;;
    *)      echo other ;;
  esac
}

agentkeeper_has_libsecret() {
  command -v secret-tool >/dev/null 2>&1
}

# Generate a fresh ed25519 keypair. Stores private key in the OS key store (or file fallback).
# Emits the base64-DER (SPKI) public key on stdout.
# Idempotent: replaces any prior key in the same slot.
agentkeeper_generate_keypair() {
  local tmp_priv tmp_pub_der
  tmp_priv="$(mktemp)"
  tmp_pub_der="$(mktemp)"
  trap 'rm -f "$tmp_priv" "$tmp_pub_der"' RETURN

  openssl genpkey -algorithm ed25519 -out "$tmp_priv" 2>/dev/null
  openssl pkey -in "$tmp_priv" -pubout -outform DER -out "$tmp_pub_der" 2>/dev/null

  local pub_b64
  pub_b64="$(base64 < "$tmp_pub_der" | tr -d '\n ')"

  case "$(agentkeeper_platform)" in
    macos)
      # Delete first (security add is not idempotent on conflict).
      security delete-generic-password -a "$USER" -s "$AGENTKEEPER_KEY_LABEL" >/dev/null 2>&1 || true
      # Store the PEM base64-encoded so it round-trips cleanly through the Keychain
      # (multiline PEM stored as-is comes back hex-encoded from security find-generic-password -w).
      local pem_b64
      pem_b64="$(base64 < "$tmp_priv" | tr -d '\n ')"
      if ! security add-generic-password -a "$USER" -s "$AGENTKEEPER_KEY_LABEL" -w "$pem_b64" >/dev/null 2>&1; then
        install -m 0600 "$tmp_priv" "$(AGENTKEEPER_KEY_FILE_FALLBACK)"
      fi
      ;;
    linux)
      if agentkeeper_has_libsecret; then
        printf '%s' "$(cat "$tmp_priv")" | secret-tool store --label="AgentKeeper Device Key" service "$AGENTKEEPER_KEY_SERVICE" key "$AGENTKEEPER_KEY_LABEL"
      else
        install -m 0600 "$tmp_priv" "$(AGENTKEEPER_KEY_FILE_FALLBACK)"
      fi
      ;;
    *)
      install -m 0600 "$tmp_priv" "$(AGENTKEEPER_KEY_FILE_FALLBACK)"
      ;;
  esac

  printf '%s' "$pub_b64"
}

# Load the stored private key PEM to stdout. Exits 1 if no key stored.
agentkeeper_load_private_key() {
  case "$(agentkeeper_platform)" in
    macos)
      # Stored as base64-encoded PEM; decode on retrieval.
      local stored
      stored="$(security find-generic-password -a "$USER" -s "$AGENTKEEPER_KEY_LABEL" -w 2>/dev/null)" && {
        printf '%s' "$stored" | base64 -d
        return 0
      }
      [ -r "$(AGENTKEEPER_KEY_FILE_FALLBACK)" ] && cat "$(AGENTKEEPER_KEY_FILE_FALLBACK)"
      ;;
    linux)
      if agentkeeper_has_libsecret; then
        secret-tool lookup service "$AGENTKEEPER_KEY_SERVICE" key "$AGENTKEEPER_KEY_LABEL" 2>/dev/null
      elif [ -r "$(AGENTKEEPER_KEY_FILE_FALLBACK)" ]; then
        cat "$(AGENTKEEPER_KEY_FILE_FALLBACK)"
      fi
      ;;
    *)
      [ -r "$(AGENTKEEPER_KEY_FILE_FALLBACK)" ] && cat "$(AGENTKEEPER_KEY_FILE_FALLBACK)"
      ;;
  esac
}

# Returns 0 if a device keypair is already stored, non-zero otherwise.
agentkeeper_has_keypair() {
  local pem
  pem="$(agentkeeper_load_private_key 2>/dev/null)"
  [ -n "$pem" ]
}

# Derive the base64-DER (SPKI) public key from the stored private key.
agentkeeper_public_key_b64() {
  local pem tmp
  pem="$(agentkeeper_load_private_key)"
  if [ -z "$pem" ]; then
    echo "agentkeeper_public_key_b64: no keypair stored" >&2
    return 1
  fi
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN
  printf '%s\n' "$pem" > "$tmp"
  openssl pkey -in "$tmp" -pubout -outform DER 2>/dev/null | base64 | tr -d '\n '
}

# Sign the payload read from stdin. Emits a base64 (single-line) signature.
# Caller constructs the payload as `timestamp || body` and pipes it in.
agentkeeper_sign() {
  local pem key_tmp payload_tmp
  pem="$(agentkeeper_load_private_key)"
  if [ -z "$pem" ]; then
    echo "agentkeeper_sign: no device key available" >&2
    return 1
  fi
  key_tmp="$(mktemp)"
  payload_tmp="$(mktemp)"
  trap 'rm -f "$key_tmp" "$payload_tmp"' RETURN
  printf '%s\n' "$pem" > "$key_tmp"
  # openssl pkeyutl -rawin requires -in <file>; it cannot read the payload from stdin.
  cat > "$payload_tmp"
  openssl pkeyutl -sign -inkey "$key_tmp" -rawin -in "$payload_tmp" 2>/dev/null | base64 | tr -d '\n '
}

# Remove the stored keypair. Used by tests and "reset this device" flows.
agentkeeper_delete_keypair() {
  case "$(agentkeeper_platform)" in
    macos)
      security delete-generic-password -a "$USER" -s "$AGENTKEEPER_KEY_LABEL" >/dev/null 2>&1 || true
      rm -f "$(AGENTKEEPER_KEY_FILE_FALLBACK)"
      ;;
    linux)
      if agentkeeper_has_libsecret; then
        secret-tool clear service "$AGENTKEEPER_KEY_SERVICE" key "$AGENTKEEPER_KEY_LABEL" 2>/dev/null || true
      fi
      rm -f "$(AGENTKEEPER_KEY_FILE_FALLBACK)"
      ;;
    *)
      rm -f "$(AGENTKEEPER_KEY_FILE_FALLBACK)"
      ;;
  esac
}
