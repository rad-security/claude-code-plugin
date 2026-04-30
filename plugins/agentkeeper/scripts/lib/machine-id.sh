#!/usr/bin/env bash
# machine-id.sh — Returns a stable machine identifier that never changes.
# macOS: Hardware UUID from IOPlatformExpertDevice
# Linux: /etc/machine-id (systemd) or DMI product UUID

get_machine_id() {
  local mid=""
  if [[ "$(uname)" == "Darwin" ]]; then
    mid=$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk -F'"' '/IOPlatformUUID/{print $4}')
  else
    # Linux: systemd machine-id (most common)
    if [[ -f /etc/machine-id ]]; then
      mid=$(cat /etc/machine-id 2>/dev/null)
    elif [[ -f /sys/class/dmi/id/product_uuid ]]; then
      mid=$(cat /sys/class/dmi/id/product_uuid 2>/dev/null)
    fi
  fi
  printf '%s' "$mid"
}
