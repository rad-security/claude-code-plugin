#!/usr/bin/env bash
# machine-id.sh — Returns a stable machine identifier that never changes.
# macOS: Hardware UUID from IOPlatformExpertDevice
# Windows: Entra device ID, hashed MachineGuid, or SMBIOS UUID through PowerShell
# Linux: /etc/machine-id (systemd) or DMI product UUID

normalize_agentkeeper_machine_id() {
  printf '%s' "$1" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]'
}

agentkeeper_machine_id_files() {
  printf '%s\n' "$HOME/.agentkeeper-plugin/machine_id"
  printf '%s\n' "$HOME/.agentkeeper/machine_id"
  if [[ -n "${CLAUDE_PLUGIN_DATA:-}" ]]; then
    printf '%s\n' "${CLAUDE_PLUGIN_DATA%/}/machine_id"
  fi
}

write_agentkeeper_machine_id() {
  local mid file seen_files=""
  mid="$(normalize_agentkeeper_machine_id "$1")"
  [[ -n "$mid" ]] || return 0

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    case "|${seen_files}|" in
      *"|${file}|"*) continue ;;
    esac
    seen_files="${seen_files}|${file}"
    mkdir -p "$(dirname "$file")" 2>/dev/null || true
    printf '%s' "$mid" > "$file" 2>/dev/null || true
    chmod 600 "$file" 2>/dev/null || true
  done < <(agentkeeper_machine_id_files)
}

read_agentkeeper_machine_id() {
  local mid file seen_files=""

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    case "|${seen_files}|" in
      *"|${file}|"*) continue ;;
    esac
    seen_files="${seen_files}|${file}"
    [[ -f "$file" ]] || continue
    mid="$(normalize_agentkeeper_machine_id "$(cat "$file" 2>/dev/null || true)")"
    if [[ -n "$mid" ]]; then
      write_agentkeeper_machine_id "$mid"
      printf '%s' "$mid"
      return 0
    fi
  done < <(agentkeeper_machine_id_files)
}

detect_agentkeeper_platform_machine_id() {
  local mid="" os_name
  os_name="$(uname -s 2>/dev/null || printf '')"

  if [[ "$os_name" == "Darwin" ]]; then
    mid=$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk -F'"' '/IOPlatformUUID/{print $4}')
  elif [[ "$os_name" == MINGW* || "$os_name" == MSYS* || "$os_name" == CYGWIN* ]]; then
    if command -v powershell.exe >/dev/null 2>&1; then
      mid=$(powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command 'try { $s = dsregcmd /status 2>$null; foreach ($line in $s) { if ($line -match "^\s*DeviceId\s*:\s*([0-9a-fA-F-]{36})\s*$") { [Console]::Write("entra:" + $Matches[1].ToLowerInvariant()); exit 0 } } } catch {}' 2>/dev/null | tr -d '\r\n[:space:]')
      if [[ -z "$mid" ]]; then
        mid=$(powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command 'try { $v = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Cryptography" -Name MachineGuid).MachineGuid; if ($v) { $bytes = [Text.Encoding]::UTF8.GetBytes($v.ToLowerInvariant()); $hash = [Security.Cryptography.SHA256]::Create().ComputeHash($bytes); $hex = -join ($hash | ForEach-Object { $_.ToString("x2") }); [Console]::Write("winmg:" + $hex.Substring(0, 32)); exit 0 } } catch {}' 2>/dev/null | tr -d '\r\n[:space:]')
      fi
      if [[ -z "$mid" ]]; then
        mid=$(powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command 'try { $v = (Get-CimInstance Win32_ComputerSystemProduct).UUID; if ($v -and $v -notmatch "^0{8}-0{4}-0{4}-0{4}-0{12}$") { [Console]::Write("smbios:" + $v.ToLowerInvariant()) } } catch {}' 2>/dev/null | tr -d '\r\n[:space:]')
      fi
    fi
  else
    # Linux: systemd machine-id (most common)
    if [[ -f /etc/machine-id ]]; then
      mid=$(cat /etc/machine-id 2>/dev/null)
    elif [[ -f /sys/class/dmi/id/product_uuid ]]; then
      mid=$(cat /sys/class/dmi/id/product_uuid 2>/dev/null)
    fi
  fi

  normalize_agentkeeper_machine_id "$mid"
}

get_machine_id() {
  local mid=""

  # Prefer an explicit managed override when present. Otherwise, ask the OS or
  # MDM provider first and repair stale AgentKeeper cache files from that
  # authoritative source. Cached IDs are only a fallback for unusual machines
  # where platform identity is unavailable.
  if [[ -n "${AGENTKEEPER_MACHINE_ID:-}" ]]; then
    mid="$(normalize_agentkeeper_machine_id "$AGENTKEEPER_MACHINE_ID")"
    write_agentkeeper_machine_id "$mid"
    printf '%s' "$mid"
    return 0
  fi

  mid="$(detect_agentkeeper_platform_machine_id)"
  if [[ -n "$mid" ]]; then
    write_agentkeeper_machine_id "$mid"
    printf '%s' "$mid"
    return 0
  fi

  mid="$(read_agentkeeper_machine_id)"
  if [[ -n "$mid" ]]; then
    printf '%s' "$mid"
    return 0
  fi

  printf '%s' "$mid"
}

read_agentkeeper_install_context_value() {
  local key="$1"
  local file value

  for file in "$HOME/.agentkeeper/install-context.json" "$HOME/.agentkeeper-plugin/install-context.json"; do
    [[ -r "$file" ]] || continue

    if command -v plutil >/dev/null 2>&1; then
      if value="$(plutil -extract "$key" raw -o - "$file" 2>/dev/null)"; then
        value="$(printf '%s' "$value" | tr -d '\r\n')"
        case "$value" in
          *"Could not extract value"*|*"No value at that key path"*|*"invalid key path"*) value="" ;;
        esac
        if [[ -n "$value" ]]; then
          printf '%s' "$value"
          return 0
        fi
      fi
    fi

    value="$(sed -nE 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "$file" 2>/dev/null | head -1)"
    value="$(printf '%s' "$value" | tr -d '\r\n')"
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
  done
}

get_agentkeeper_hostname() {
  local host=""
  local os_name
  os_name="$(uname -s 2>/dev/null || printf '')"

  host="${AGENTKEEPER_HOSTNAME:-${AGENTKEEPER_MDM_COMPUTER_NAME:-}}"
  if [[ -z "$host" ]]; then
    host="$(read_agentkeeper_install_context_value hostname 2>/dev/null || true)"
  fi
  if [[ -z "$host" ]]; then
    host="$(read_agentkeeper_install_context_value mdm_computer_name 2>/dev/null || true)"
  fi
  if [[ -n "$host" ]]; then
    host="$(printf '%s' "$host" | tr -d '\r\n')"
    printf '%s' "$host"
    return 0
  fi

  if [[ "$os_name" == "Darwin" ]]; then
    host="$(scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || hostname 2>/dev/null || printf '')"
  elif [[ "$os_name" == MINGW* || "$os_name" == MSYS* || "$os_name" == CYGWIN* ]]; then
    host="${COMPUTERNAME:-}"
    if [[ -z "$host" ]] && command -v powershell.exe >/dev/null 2>&1; then
      host="$(powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command 'try { [Console]::Write($env:COMPUTERNAME) } catch {}' 2>/dev/null | tr -d '\r\n')"
    fi
    if [[ -z "$host" ]]; then
      host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf '')"
    fi
  else
    host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf '')"
  fi

  host="$(printf '%s' "$host" | tr -d '\r\n')"
  printf '%s' "${host:-unknown}"
}
