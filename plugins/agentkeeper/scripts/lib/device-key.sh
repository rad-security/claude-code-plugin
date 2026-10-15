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
AGENTKEEPER_SIGN_NAMESPACE="agentkeeper@rad.security"

# macOS /usr/bin/openssl is LibreSSL, which cannot generate ed25519 keys nor
# produce raw signatures (pkeyutl -rawin). Probe for a capable binary once per
# process; empty result means no usable openssl anywhere.
_AGENTKEEPER_OPENSSL_BIN=""
_AGENTKEEPER_OPENSSL_PROBED=0
resolve_agentkeeper_openssl() {
  if [ "$_AGENTKEEPER_OPENSSL_PROBED" -eq 1 ]; then
    printf '%s' "$_AGENTKEEPER_OPENSSL_BIN"
    return 0
  fi
  _AGENTKEEPER_OPENSSL_PROBED=1
  local candidates candidate
  # AGENTKEEPER_OPENSSL_BIN pins the binary: no candidate fallback when set.
  if [ -n "${AGENTKEEPER_OPENSSL_BIN:-}" ]; then
    candidates="${AGENTKEEPER_OPENSSL_BIN}"
  else
    candidates="/opt/homebrew/opt/openssl@3/bin/openssl /opt/homebrew/bin/openssl /usr/local/opt/openssl@3/bin/openssl /usr/local/bin/openssl openssl"
  fi
  for candidate in $candidates; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    if "$candidate" genpkey -algorithm ed25519 -out /dev/null 2>/dev/null; then
      _AGENTKEEPER_OPENSSL_BIN="$candidate"
      break
    fi
  done
  printf '%s' "$_AGENTKEEPER_OPENSSL_BIN"
}

# Convert an OpenSSH ed25519 public key file to base64 SPKI-DER (the format the
# server stores and verifies). SPKI for ed25519 is a fixed 12-byte DER prefix
# followed by the raw 32-byte key, which is the tail of the OpenSSH key blob.
agentkeeper_ssh_pub_to_spki_b64() {
  local pub_file="$1" blob_tmp spki_tmp blob_size
  blob_tmp="$(mktemp)"
  spki_tmp="$(mktemp)"
  awk '{print $2}' "$pub_file" | base64 -d > "$blob_tmp" 2>/dev/null || true
  blob_size="$(wc -c < "$blob_tmp" | tr -d ' ')"
  if [ "$blob_size" -lt 51 ]; then
    rm -f "$blob_tmp" "$spki_tmp"
    return 1
  fi
  printf '\060\052\060\005\006\003\053\145\160\003\041\000' > "$spki_tmp"
  tail -c 32 "$blob_tmp" >> "$spki_tmp"
  base64 < "$spki_tmp" | tr -d '\n '
  rm -f "$blob_tmp" "$spki_tmp"
}

# Which crypto backend the stored key uses: openssl | ssh-keygen | none.
agentkeeper_crypto_backend() {
  local pem
  pem="$(agentkeeper_load_private_key 2>/dev/null || true)"
  case "$pem" in
    *"BEGIN OPENSSH PRIVATE KEY"*) printf 'ssh-keygen' ;;
    *"BEGIN "*) printf 'openssl' ;;
    *) printf 'none' ;;
  esac
}

agentkeeper_platform() {
  case "$(uname -s)" in
    Darwin) echo macos ;;
    Linux)  echo linux ;;
    *)      echo other ;;
  esac
}

agentkeeper_key_storage() {
  printf '%s' "${AGENTKEEPER_KEY_STORAGE:-auto}"
}

agentkeeper_has_libsecret() {
  command -v secret-tool >/dev/null 2>&1
}

# Generate a fresh ed25519 keypair. Stores private key in the OS key store (or file fallback).
# Emits the base64-DER (SPKI) public key on stdout.
# Idempotent: replaces any prior key in the same slot.
# Backend order: capable openssl, then native ssh-keygen (every macOS ships it).
agentkeeper_generate_keypair() {
  local tmp_priv tmp_pub_der ossl
  tmp_priv="$(mktemp)"
  tmp_pub_der="$(mktemp)"
  trap 'rm -f "$tmp_priv" "$tmp_pub_der" "${tmp_priv}.pub"' RETURN

  local pub_b64=""
  ossl="$(resolve_agentkeeper_openssl)"
  if [ -n "$ossl" ]; then
    "$ossl" genpkey -algorithm ed25519 -out "$tmp_priv" 2>/dev/null
    "$ossl" pkey -in "$tmp_priv" -pubout -outform DER -out "$tmp_pub_der" 2>/dev/null
    pub_b64="$(base64 < "$tmp_pub_der" | tr -d '\n ')"
  elif command -v ssh-keygen >/dev/null 2>&1; then
    rm -f "$tmp_priv" "${tmp_priv}.pub"
    ssh-keygen -t ed25519 -N '' -q -f "$tmp_priv" -C agentkeeper-device 2>/dev/null || true
    if [ -s "$tmp_priv" ]; then
      pub_b64="$(agentkeeper_ssh_pub_to_spki_b64 "${tmp_priv}.pub" || true)"
    fi
  fi

  if [ -z "$pub_b64" ]; then
    echo "agentkeeper_generate_keypair: no ed25519-capable backend (openssl/ssh-keygen)" >&2
    return 1
  fi

  if [ "$(agentkeeper_key_storage)" = "file" ]; then
    install -m 0600 "$tmp_priv" "$(AGENTKEEPER_KEY_FILE_FALLBACK)"
    printf '%s' "$pub_b64"
    return 0
  fi

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
  if [ "$(agentkeeper_key_storage)" = "file" ]; then
    [ -r "$(AGENTKEEPER_KEY_FILE_FALLBACK)" ] && cat "$(AGENTKEEPER_KEY_FILE_FALLBACK)"
    return 0
  fi

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
  local pem tmp ossl
  pem="$(agentkeeper_load_private_key)"
  if [ -z "$pem" ]; then
    echo "agentkeeper_public_key_b64: no keypair stored" >&2
    return 1
  fi
  tmp="$(mktemp)"
  trap 'rm -f "$tmp" "${tmp}.pub"' RETURN
  printf '%s\n' "$pem" > "$tmp"
  case "$pem" in
    *"BEGIN OPENSSH PRIVATE KEY"*)
      chmod 0600 "$tmp"
      ssh-keygen -y -f "$tmp" > "${tmp}.pub" 2>/dev/null || return 1
      agentkeeper_ssh_pub_to_spki_b64 "${tmp}.pub"
      ;;
    *)
      ossl="$(resolve_agentkeeper_openssl)"
      [ -n "$ossl" ] || return 1
      "$ossl" pkey -in "$tmp" -pubout -outform DER 2>/dev/null | base64 | tr -d '\n '
      ;;
  esac
}

# Sign the payload read from stdin. Emits a base64 (single-line) signature.
# Caller constructs the payload as `timestamp || body` and pipes it in.
# openssl-backed keys emit a raw ed25519 signature (64 bytes, base64).
# ssh-keygen-backed keys emit the SSHSIG blob (base64, armor stripped); the
# server distinguishes the two by size and the SSHSIG magic.
agentkeeper_sign() {
  local pem key_tmp payload_tmp ossl
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
  case "$pem" in
    *"BEGIN OPENSSH PRIVATE KEY"*)
      chmod 0600 "$key_tmp"
      ssh-keygen -Y sign -f "$key_tmp" -n "$AGENTKEEPER_SIGN_NAMESPACE" - < "$payload_tmp" 2>/dev/null \
        | grep -v -- '-----' | tr -d '\n '
      ;;
    *)
      ossl="$(resolve_agentkeeper_openssl)"
      [ -n "$ossl" ] || return 1
      "$ossl" pkeyutl -sign -inkey "$key_tmp" -rawin -in "$payload_tmp" 2>/dev/null | base64 | tr -d '\n '
      ;;
  esac
}

# Remove the stored keypair. Used by tests and "reset this device" flows.
agentkeeper_delete_keypair() {
  if [ "$(agentkeeper_key_storage)" = "file" ]; then
    rm -f "$(AGENTKEEPER_KEY_FILE_FALLBACK)"
    return 0
  fi

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
