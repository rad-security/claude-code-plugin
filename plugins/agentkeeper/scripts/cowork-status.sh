#!/usr/bin/env bash
# Show install state for the AgentKeeper Claude Cowork hook.

set -u

case "$(uname -s)" in
  Darwin) CLAUDE_DATA="$HOME/Library/Application Support/Claude" ;;
  Linux)  CLAUDE_DATA="${XDG_CONFIG_HOME:-$HOME/.config}/Claude" ;;
  *)      CLAUDE_DATA="" ;;
esac

HOOK_SCRIPT="${HOME}/.agentkeeper/scripts/pre-tool-hook.sh"
PLUGIN_KEY_FILE="${HOME}/.agentkeeper-plugin/api_key"
SHARED_KEY_FILE="${HOME}/.agentkeeper/config/api_key"
HOOK_MARKER="${HOME}/.agentkeeper/cowork-hook-last-run.json"
EVALUATE_MARKER="${HOME}/.agentkeeper/cowork-evaluate-last-run.json"
API_BASE_URL="${AGENTKEEPER_API_URL:-https://www.agentkeeper.dev}"
API_BASE_URL="${API_BASE_URL%/}"

# shellcheck disable=SC1090
source "$(cd "$(dirname "$0")" && pwd)/lib/cowork-json.sh" 2>/dev/null || true

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m[ok]\033[0m %s\n' "$*"; }
miss() { printf '  \033[31m[missing]\033[0m %s\n' "$*"; }
note() { printf '     %s\n' "$*"; }
key_file() {
  if [ -s "$PLUGIN_KEY_FILE" ]; then printf '%s\n' "$PLUGIN_KEY_FILE"
  elif [ -s "$SHARED_KEY_FILE" ]; then printf '%s\n' "$SHARED_KEY_FILE"
  fi
}
third_party_platform_mode() {
  [ "$(uname -s)" = "Darwin" ] || return 1
  for plist in \
    "/Library/Managed Preferences/${USER:-}/com.anthropic.claudefordesktop.plist" \
    "/Library/Managed Preferences/com.anthropic.claudefordesktop.plist" \
    "$HOME/Library/Preferences/com.anthropic.claudefordesktop.plist"
  do
    [ -f "$plist" ] || continue
    if plutil -p "$plist" 2>/dev/null | grep -q '"inferenceProvider"'; then
      return 0
    fi
  done
  return 1
}
print_deployment_mode() {
  if third_party_platform_mode; then
    ok "Cowork deployment mode: third-party platform mode detected"
    note "MDM org-plugin mounts are supported for this Claude Cowork mode."
  else
    miss "Cowork deployment mode: standard Claude Cowork detected"
    note "Filesystem hook files alone may not be executed by standard Team/Enterprise Cowork."
    note "If live hook invocation stays missing, a Claude org owner/admin must install the plugin via Organization settings > Plugins or the user's local Upload plugin flow."
  fi
}
plugin_enabled() {
  settings_file="$(dirname "$1")/cowork_settings.json"
  [ -f "$settings_file" ] || return 1
  cowork_json_bool_true "$settings_file" "enabledPlugins.cowork-guardrail@agentkeeper"
}
active_cache_root() {
  local cw="$1"
  local installed_path
  installed_path="$(cowork_json_raw_value "${cw}/installed_plugins.json" "plugins.cowork-guardrail@agentkeeper.0.installPath" 2>/dev/null || true)"
  if [ -n "$installed_path" ] && [ -d "$installed_path" ]; then
    printf '%s\n' "$installed_path"
    return 0
  fi
  find "${cw}/cache/agentkeeper/cowork-guardrail" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -1
}
normalize_agentkeeper_machine_id() {
  printf '%s' "$1" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]'
}
agentkeeper_machine_id_files() {
  printf '%s\n' "$HOME/.agentkeeper-plugin/machine_id"
  printf '%s\n' "$HOME/.agentkeeper/machine_id"
  if [ -n "${CLAUDE_PLUGIN_DATA:-}" ]; then
    printf '%s\n' "${CLAUDE_PLUGIN_DATA%/}/machine_id"
  fi
}
write_agentkeeper_machine_id() {
  local mid file seen_files=""
  mid="$(normalize_agentkeeper_machine_id "$1")"
  [ -n "$mid" ] || return 0

  while IFS= read -r file; do
    [ -n "$file" ] || continue
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
    [ -n "$file" ] || continue
    case "|${seen_files}|" in
      *"|${file}|"*) continue ;;
    esac
    seen_files="${seen_files}|${file}"
    [ -f "$file" ] || continue
    mid="$(normalize_agentkeeper_machine_id "$(cat "$file" 2>/dev/null || true)")"
    if [ -n "$mid" ]; then
      write_agentkeeper_machine_id "$mid"
      printf '%s' "$mid"
      return 0
    fi
  done < <(agentkeeper_machine_id_files)
}
machine_id() {
  local mid="" os_name
  if [ -n "${AGENTKEEPER_MACHINE_ID:-}" ]; then
    mid="$(normalize_agentkeeper_machine_id "$AGENTKEEPER_MACHINE_ID")"
    write_agentkeeper_machine_id "$mid"
    printf '%s' "$mid"
    return 0
  fi

  os_name="$(uname -s 2>/dev/null || printf '')"
  if [ "$os_name" = "Darwin" ]; then
    mid="$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk -F'"' '/IOPlatformUUID/{print $4}')"
  elif [[ "$os_name" == MINGW* || "$os_name" == MSYS* || "$os_name" == CYGWIN* ]]; then
    if command -v powershell.exe >/dev/null 2>&1; then
      mid="$(powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command 'try { $s = dsregcmd /status 2>$null; foreach ($line in $s) { if ($line -match "^\s*DeviceId\s*:\s*([0-9a-fA-F-]{36})\s*$") { [Console]::Write("entra:" + $Matches[1].ToLowerInvariant()); exit 0 } } } catch {}' 2>/dev/null | tr -d '\r\n[:space:]')"
      if [ -z "$mid" ]; then
        mid="$(powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command 'try { $v = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Cryptography" -Name MachineGuid).MachineGuid; if ($v) { $bytes = [Text.Encoding]::UTF8.GetBytes($v.ToLowerInvariant()); $hash = [Security.Cryptography.SHA256]::Create().ComputeHash($bytes); $hex = -join ($hash | ForEach-Object { $_.ToString("x2") }); [Console]::Write("winmg:" + $hex.Substring(0, 32)); exit 0 } } catch {}' 2>/dev/null | tr -d '\r\n[:space:]')"
      fi
      if [ -z "$mid" ]; then
        mid="$(powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command 'try { $v = (Get-CimInstance Win32_ComputerSystemProduct).UUID; if ($v -and $v -notmatch "^0{8}-0{4}-0{4}-0{4}-0{12}$") { [Console]::Write("smbios:" + $v.ToLowerInvariant()) } } catch {}' 2>/dev/null | tr -d '\r\n[:space:]')"
      fi
    fi
  elif [ -f /etc/machine-id ]; then
    mid="$(cat /etc/machine-id 2>/dev/null)"
  elif [ -f /sys/class/dmi/id/product_uuid ]; then
    mid="$(cat /sys/class/dmi/id/product_uuid 2>/dev/null)"
  fi
  if [ -n "$mid" ]; then
    mid="$(normalize_agentkeeper_machine_id "$mid")"
    write_agentkeeper_machine_id "$mid"
    printf '%s' "$mid"
    return 0
  fi

  mid="$(read_agentkeeper_machine_id)"
  if [ -n "$mid" ]; then
    printf '%s' "$mid"
    return 0
  fi
  printf '%s' "$mid"
}
host_name() {
  local os_name host
  os_name="$(uname -s 2>/dev/null || printf '')"
  host=""
  if [[ "$os_name" == MINGW* || "$os_name" == MSYS* || "$os_name" == CYGWIN* ]]; then
    host="${COMPUTERNAME:-}"
    if [ -z "$host" ] && command -v powershell.exe >/dev/null 2>&1; then
      host="$(powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command 'try { [Console]::Write($env:COMPUTERNAME) } catch {}' 2>/dev/null | tr -d '\r\n')"
    fi
  fi
  if [ -z "$host" ]; then
    host="$(scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'unknown')"
  fi
  printf '%s' "$host"
}
status_checkin() {
  local active_key_file host_name mid platform os_version payload response
  active_key_file="$(key_file)"
  [ -n "$active_key_file" ] || return 0

  host_name="$(host_name)"
  mid="$(machine_id 2>/dev/null || true)"
  platform="unknown"
  os_version=""
  case "$(uname -s)" in
    Darwin) platform="darwin"; os_version="$(sw_vers -productVersion 2>/dev/null || true)" ;;
    Linux) platform="linux"; os_version="$(uname -r 2>/dev/null || true)" ;;
    MINGW*|MSYS*|CYGWIN*) platform="windows"; os_version="$(cmd.exe /c ver 2>/dev/null | tr -d '\r' || true)" ;;
  esac

  payload='{"source":"cowork_desktop_posture","hostname":"'"$(cowork_json_escape "${host_name:-unknown}")"'","platform":"'"$(cowork_json_escape "$platform")"'","os_version":"'"$(cowork_json_escape "$os_version")"'","agent_version":"cowork-status","os_username":"'"$(cowork_json_escape "${USER:-unknown}")"'","score":100,"grade":"A","checks":[{"status":"PASS","check_name":"Cowork status check","detail":"AgentKeeper Cowork local status script reached the production API.","category":"runtime_state","severity":"info","source":"cowork_desktop_posture"}],"raw_report":{"source":"cowork_desktop_posture","checkin":"cowork-status","plugin":"cowork-guardrail@agentkeeper"}'
  if [ -n "$mid" ]; then
    payload="${payload},\"machine_id\":\"$(cowork_json_escape "$mid")\""
  fi
  payload="${payload}}"

  response="$(printf '%s' "$payload" | curl -sS --max-time 8 \
    -X POST "${API_BASE_URL}/api/v1/scans" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $(cat "$active_key_file")" \
    -d @- 2>/dev/null || true)"
  if printf '%s' "$response" | grep -q '"ok":true'; then
    ok "server check-in: workstation registered/updated"
  else
    miss "server check-in failed"
    [ -n "$response" ] && note "$response"
  fi
}
marker_value() {
  local path="$1"
  local key="$2"
  [ -f "$path" ] || return 0
  sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\\([^\"\\\\]*\\)\".*/\\1/p" "$path" | head -1
}
marker_bool_true() {
  local path="$1"
  local key="$2"
  [ -f "$path" ] || return 1
  grep -Eq "\"${key}\"[[:space:]]*:[[:space:]]*true" "$path" 2>/dev/null
}
marker_bits() {
  local path="$1"
  local key value bits=""
  for key in last_run_at hook_event_name tool_name server_name session_id http_status response_size self_test_source; do
    value="$(marker_value "$path" "$key")"
    [ -n "$value" ] && bits="${bits}${bits:+ }${key}=${value}"
  done
  printf '%s' "$bits"
}
hook_last_run() {
  if [ ! -f "$HOOK_MARKER" ]; then
    miss "live hook invocation: not seen yet"
    note "After reinstall, trigger a Cowork tool call, then run this status command again."
    return 0
  fi
  session="$(marker_value "$HOOK_MARKER" "session_id")"
  bits="$(marker_bits "$HOOK_MARKER")"
  if marker_bool_true "$HOOK_MARKER" "self_test" || printf '%s' "$session" | grep -Eq '^cowork-(self-test|install-self-test)-'; then
    miss "live hook invocation: not seen yet"
    note "last hook invocation was self-test only: ${bits:-marker present}"
    note "Fully quit/relaunch Claude Desktop, run a real Cowork tool action, then rerun status."
  elif [ -z "$session" ]; then
    miss "live hook invocation: not confirmed"
    note "marker is missing session_id: ${bits:-marker present}"
  else
    ok "live hook invocation: ${bits:-marker present}"
  fi
}
evaluate_last_run() {
  if [ ! -f "$EVALUATE_MARKER" ]; then
    miss "live evaluate request: not seen yet"
    note "Run the self-test below or trigger a Cowork tool call."
    return 0
  fi
  status="$(marker_value "$EVALUATE_MARKER" "http_status")"
  session="$(marker_value "$EVALUATE_MARKER" "session_id")"
  bits="$(marker_bits "$EVALUATE_MARKER")"
  if marker_bool_true "$EVALUATE_MARKER" "self_test" || printf '%s' "$session" | grep -Eq '^cowork-(self-test|install-self-test)-'; then
    miss "live evaluate request: not seen yet"
    note "last evaluate request was self-test only: ${bits:-marker present}"
  elif printf '%s' "$status" | grep -q '^2'; then
    if [ -n "$session" ]; then
      ok "live evaluate request: ${bits:-marker present}"
    else
      miss "live evaluate request: not confirmed"
      note "marker is missing session_id: ${bits:-marker present}"
    fi
  else
    miss "last evaluate request: ${bits:-marker present}"
  fi
}
self_test_evaluate_result() {
  local expected_session_id
  expected_session_id="$1"
  if [ ! -f "$EVALUATE_MARKER" ]; then
    miss "self-test evaluate request: not seen yet"
    note "Expected self-test session: ${expected_session_id}"
    return 0
  fi
  session="$(marker_value "$EVALUATE_MARKER" "session_id")"
  status="$(marker_value "$EVALUATE_MARKER" "http_status")"
  bits="$(marker_bits "$EVALUATE_MARKER")"
  if [ "$session" != "$expected_session_id" ]; then
    miss "self-test evaluate request: marker did not update"
    note "expected session_id=${expected_session_id}"
    note "marker: ${bits:-marker present}"
  elif ! marker_bool_true "$EVALUATE_MARKER" "self_test"; then
    miss "self-test evaluate request: marker was not labeled as self-test"
    note "marker: ${bits:-marker present}"
  elif printf '%s' "$status" | grep -q '^2'; then
    ok "self-test evaluate request: ${bits:-marker present}"
  else
    miss "self-test evaluate request: ${bits:-marker present}"
  fi
}
self_test_marker_ok() {
  local expected_session_id
  expected_session_id="$1"
  [ "$(marker_value "$EVALUATE_MARKER" "session_id")" = "$expected_session_id" ] || return 1
  marker_bool_true "$EVALUATE_MARKER" "self_test" || return 1
  printf '%s' "$(marker_value "$EVALUATE_MARKER" "http_status")" | grep -q '^2'
}
curl_supports_retry_all_errors() {
  curl --help all 2>/dev/null | grep -q -- "--retry-all-errors"
}
download_with_retries() {
  local url="$1"
  local dest="$2"
  local label="${3:-$url}"
  local tmp_dest
  tmp_dest="${dest}.tmp.$$"

  rm -f "$tmp_dest" 2>/dev/null || true
  if curl_supports_retry_all_errors; then
    if curl -fsSL --connect-timeout 10 --max-time 120 --retry 5 --retry-delay 2 --retry-max-time 300 --retry-all-errors "$url" -o "$tmp_dest"; then
      mv "$tmp_dest" "$dest"
      return 0
    fi
  elif curl -fsSL --connect-timeout 10 --max-time 120 --retry 5 --retry-delay 2 --retry-max-time 300 "$url" -o "$tmp_dest"; then
    mv "$tmp_dest" "$dest"
    return 0
  fi

  rm -f "$tmp_dest" 2>/dev/null || true
  miss "automatic repair: could not download ${label} after retries"
  note "$url"
  return 1
}
repair_cowork_install() {
  local tmp
  tmp="$(mktemp 2>/dev/null || printf "/tmp/agentkeeper-cowork-install.$$")"
  if ! download_with_retries "${API_BASE_URL}/cowork-install.sh" "$tmp" "installer"; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  if AGENTKEEPER_API_URL="$API_BASE_URL" AGENTKEEPER_SKIP_BROWSER=1 bash "$tmp" >/dev/null 2>&1; then
    ok "automatic repair: hook files refreshed"
    rm -f "$tmp" 2>/dev/null || true
    return 0
  fi
  miss "automatic repair: installer did not complete"
  note "Run the installer once, then rerun this self-test."
  rm -f "$tmp" 2>/dev/null || true
  return 1
}
invoke_self_test() {
  local session_id payload response
  session_id="$1"

  payload='{"hook_event_name":"PreToolUse","session_id":"'"$(cowork_json_escape "$session_id")"'","tool_name":"Read","tool_input":{"file_path":"~/agentkeeper-cowork-self-test.txt"}}'
  response="$(printf '%s' "$payload" | AGENTKEEPER_SKIP_CONFLICT_CHECK=1 AGENTKEEPER_API_TOOL=cowork AGENTKEEPER_API_URL="$API_BASE_URL" AGENTKEEPER_COWORK_SELF_TEST="cowork-status-self-test" "$HOOK_SCRIPT" 2>/dev/null || true)"
  if [ -n "$response" ]; then
    ok "hook response: ${response}"
  else
    ok "hook response: empty fail-open response"
  fi
  note "Self-test session: ${session_id}"
}
run_self_test() {
  local active_key_file session_id

  bold "AgentKeeper Cowork Hook - self-test"
  echo

  if [ ! -x "$HOOK_SCRIPT" ]; then
    miss "hook script missing: ${HOOK_SCRIPT}"
    note "Refreshing hook files automatically."
    repair_cowork_install || exit 1
    if [ ! -x "$HOOK_SCRIPT" ]; then
      miss "hook script still missing after automatic repair: ${HOOK_SCRIPT}"
      exit 1
    fi
  fi
  active_key_file="$(key_file)"
  if [ -z "$active_key_file" ]; then
    miss "API key missing"
    note "run the installer with AGENTKEEPER_API_KEY=ak_live_..."
    exit 1
  fi

  session_id="cowork-self-test-$(date +%s 2>/dev/null || printf '%s' "$$")"
  rm -f "$EVALUATE_MARKER" 2>/dev/null || true
  invoke_self_test "$session_id"
  self_test_evaluate_result "$session_id"

  if ! self_test_marker_ok "$session_id"; then
    echo
    note "Self-test did not reach AgentKeeper evaluate; refreshing hook files automatically."
    if repair_cowork_install; then
      session_id="cowork-self-test-$(date +%s 2>/dev/null || printf '%s' "$$")"
      rm -f "$EVALUATE_MARKER" 2>/dev/null || true
      invoke_self_test "$session_id"
      self_test_evaluate_result "$session_id"
    fi
  fi

  note "Self-test only is not live protection."
  note "Protection is confirmed only when live hook invocation and live evaluate request update after a real Cowork tool action."
}

if [ "${1:-}" = "--self-test" ]; then
  run_self_test
  exit 0
fi

bold "AgentKeeper Cowork Hook - status"
echo

print_deployment_mode
echo

if [ -x "$HOOK_SCRIPT" ]; then ok "hook script: ${HOOK_SCRIPT}"
else miss "hook script missing: ${HOOK_SCRIPT}"; fi

if [ -s "$PLUGIN_KEY_FILE" ]; then
  ok "API key: present at ${PLUGIN_KEY_FILE}"
elif [ -s "$SHARED_KEY_FILE" ]; then
  ok "API key: present at ${SHARED_KEY_FILE}"
else
  miss "API key missing"
  note "run the installer with AGENTKEEPER_API_KEY=ak_live_..."
fi

status_checkin
hook_last_run
evaluate_last_run

echo
bold "Filesystem compatibility install"
echo

if [ -z "$CLAUDE_DATA" ] || [ ! -d "$CLAUDE_DATA/local-agent-mode-sessions" ]; then
  miss "No Cowork session directory found."
else
  FOUND=0
  COWORK_DIRS="$(find "$CLAUDE_DATA/local-agent-mode-sessions" -maxdepth 4 -type d -name cowork_plugins 2>/dev/null | sort || true)"
  while IFS= read -r cw; do
    [ -d "$cw" ] || continue
    FOUND=$((FOUND + 1))
    workspace_dir="$(dirname "$cw")"
    workspace_id="${workspace_dir##*/}"

    hooks_file="${cw}/marketplaces/agentkeeper/cowork-guardrail/hooks/hooks.json"
    cache_root="$(active_cache_root "$cw")"
    if [ -f "$hooks_file" ] && grep -q "AGENTKEEPER_API_TOOL=cowork" "$hooks_file"; then
      ok "workspace ${workspace_id}: marketplace hook installed"
      if grep -q "CLAUDE_PLUGIN_ROOT" "$hooks_file"; then
        ok "workspace ${workspace_id}: marketplace hook is plugin-root relative"
      else
        miss "workspace ${workspace_id}: marketplace hook uses legacy absolute command"
        note "re-run the installer, then quit and relaunch Claude Desktop"
      fi
    else
      miss "workspace ${workspace_id}: marketplace hook missing"
    fi

    if [ -x "${cw}/marketplaces/agentkeeper/cowork-guardrail/scripts/pre-tool-hook.sh" ]; then
      ok "workspace ${workspace_id}: marketplace embedded hook script installed"
    else
      miss "workspace ${workspace_id}: marketplace embedded hook script missing"
      note "re-run the installer to install the self-contained plugin bundle"
    fi

    manifest_file="${cw}/marketplaces/agentkeeper/cowork-guardrail/.claude-plugin/plugin.json"
    org_manifest_file="${cw}/marketplaces/agentkeeper/cowork-guardrail/claude-plugin/plugin.json"
    if [ -f "$manifest_file" ] && grep -q "UserPromptSubmit" "$manifest_file" && grep -q "AGENTKEEPER_API_TOOL=cowork" "$manifest_file"; then
      ok "workspace ${workspace_id}: marketplace manifest hooks installed"
    else
      miss "workspace ${workspace_id}: marketplace manifest hooks missing"
    fi
    root_version_file="${cw}/marketplaces/agentkeeper/cowork-guardrail/version.json"
    compat_version_file="${cw}/marketplaces/agentkeeper/cowork-guardrail/claude-plugin/version.json"
    if [ -f "$org_manifest_file" ] && grep -q "installationPreference" "$org_manifest_file" && { [ -f "$root_version_file" ] || [ -f "$compat_version_file" ]; }; then
      ok "workspace ${workspace_id}: marketplace org-plugin manifest installed"
    else
      miss "workspace ${workspace_id}: marketplace org-plugin manifest missing"
    fi

    cache_match=""
    if [ -n "$cache_root" ] && [ -f "${cache_root}/hooks/hooks.json" ] && grep -q "AGENTKEEPER_API_TOOL=cowork" "${cache_root}/hooks/hooks.json"; then
      cache_match="${cache_root}/hooks/hooks.json"
    fi
    if [ -n "$cache_match" ]; then
      ok "workspace ${workspace_id}: cache hook installed"
      if grep -q "CLAUDE_PLUGIN_ROOT" "$cache_match"; then
        ok "workspace ${workspace_id}: cache hook is plugin-root relative"
      else
        miss "workspace ${workspace_id}: cache hook uses legacy absolute command"
        note "re-run the installer, then quit and relaunch Claude Desktop"
      fi
    else
      miss "workspace ${workspace_id}: cache hook missing"
    fi

    cache_script=""
    if [ -n "$cache_root" ] && [ -x "${cache_root}/scripts/pre-tool-hook.sh" ]; then
      cache_script="${cache_root}/scripts/pre-tool-hook.sh"
    fi
    if [ -n "$cache_script" ]; then
      ok "workspace ${workspace_id}: cache embedded hook script installed"
    else
      miss "workspace ${workspace_id}: cache embedded hook script missing"
      note "re-run the installer to install the self-contained plugin bundle"
    fi

    cache_manifest=""
    if [ -n "$cache_root" ] && [ -f "${cache_root}/.claude-plugin/plugin.json" ] && grep -q "UserPromptSubmit" "${cache_root}/.claude-plugin/plugin.json" && grep -q "AGENTKEEPER_API_TOOL=cowork" "${cache_root}/.claude-plugin/plugin.json"; then
      cache_manifest="${cache_root}/.claude-plugin/plugin.json"
    fi
    if [ -n "$cache_manifest" ]; then
      ok "workspace ${workspace_id}: cache manifest hooks installed"
    else
      miss "workspace ${workspace_id}: cache manifest hooks missing"
    fi

    cache_org_manifest=""
    if [ -n "$cache_root" ] && [ -f "${cache_root}/claude-plugin/plugin.json" ] && grep -q "installationPreference" "${cache_root}/claude-plugin/plugin.json" && { [ -f "${cache_root}/version.json" ] || [ -f "${cache_root}/claude-plugin/version.json" ]; }; then
      cache_org_manifest="${cache_root}/claude-plugin/plugin.json"
    fi
    if [ -n "$cache_org_manifest" ]; then
      ok "workspace ${workspace_id}: cache org-plugin manifest installed"
    else
      miss "workspace ${workspace_id}: cache org-plugin manifest missing"
    fi

    if plugin_enabled "$cw"; then
      ok "workspace ${workspace_id}: Cowork plugin enabled"
    else
      miss "workspace ${workspace_id}: Cowork plugin disabled"
      note "re-run the installer, then quit and relaunch Claude Desktop"
    fi
  done <<EOF_DIRS
${COWORK_DIRS}
EOF_DIRS
  [ "$FOUND" -eq 0 ] && miss "No Cowork workspaces found."
fi

echo
note "Quit and relaunch Claude Desktop after install or uninstall."
note "Protection is confirmed only when live hook invocation and live evaluate request update after a real Cowork tool action."
