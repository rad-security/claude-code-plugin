#!/usr/bin/env bash
# local-detect.sh — Local threat detection engine for AgentKeeper Claude Code plugin
#
# Ports the TypeScript detection patterns from claude-code-detect.ts to pure
# bash for offline evaluation. No network calls, no jq dependency.
#
# Usage:  printf '%s' "$json_payload" | local-detect.sh <hook_type>
#   hook_type: pre_tool | post_tool | prompt
#
# Output (stdout):
#   Empty           — no detection (allow)
#   NAME\tSEVERITY\tDESCRIPTION  — detection found (tab-separated, one line)
#
# Exit code: always 0 (fail-open). Errors produce no output.
#
# Performance: all patterns use grep -Eq (short-circuit on first match).
# Only the relevant pattern set runs based on tool_name.
# JSON extraction uses macOS plutil when available, with a simple fallback for
# non-macOS local development. Escaped fields stay decoded before scanning.

set -euo pipefail

# ── Input ───────────────────────────────────────────────────────────────

HOOK_TYPE="${1:-}"
if [ -z "$HOOK_TYPE" ]; then
  exit 0
fi

# Read JSON payload from stdin
INPUT=""
if ! INPUT=$(cat 2>/dev/null); then
  exit 0
fi

if [ -z "$INPUT" ]; then
  exit 0
fi

# ── JSON Field Extraction ───────────────────────────────────────────────
# Portable extraction without jq or a scripting runtime.

JSON_FILE=""
cleanup_json_file() {
  if [ -n "${JSON_FILE:-}" ]; then
    rm -f "$JSON_FILE"
  fi
}
trap cleanup_json_file EXIT

if command -v /usr/bin/plutil >/dev/null 2>&1; then
  JSON_FILE=$(mktemp "${TMPDIR:-/tmp}/agentkeeper-local-detect.XXXXXX") || JSON_FILE=""
  if [ -n "$JSON_FILE" ]; then
    if ! printf '%s' "$INPUT" > "$JSON_FILE"; then
      rm -f "$JSON_FILE"
      JSON_FILE=""
    fi
  fi
fi

extract_plutil_field() {
  local path="$1"
  local value=""
  [ -n "${JSON_FILE:-}" ] || return 1
  value=$(/usr/bin/plutil -extract "$path" raw "$JSON_FILE" 2>/dev/null) || return 1
  printf '%s' "$value"
}

extract_simple_field() {
  local field="$1"
  local value=""
  local path=""

  for path in "tool_input.${field}" "toolInput.${field}" "params.${field}" "arguments.${field}" "args.${field}" "input.${field}" "$field"; do
    value=$(extract_plutil_field "$path") || value=""
    if [ -n "$value" ]; then
      printf '%s' "$value"
      return
    fi
  done

  printf '%s' "$INPUT" | grep -oE "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/' || true
}

extract_command_field() {
  local result=""

  result=$(extract_simple_field "command") || result=""
  if [ -z "$result" ]; then
    result=$(extract_simple_field "cmd") || result=""
  fi
  if [ -z "$result" ]; then
    result=$(extract_simple_field "shell_command") || result=""
  fi
  if [ -z "$result" ]; then
    result=$(extract_simple_field "shellCommand") || result=""
  fi
  if [ -z "$result" ]; then
    result=$(extract_simple_field "command_line") || result=""
  fi
  if [ -z "$result" ]; then
    result=$(extract_simple_field "commandLine") || result=""
  fi

  printf '%s' "$result"
}

extract_prompt_text() {
  # Extract prompt text from UserPromptSubmit payloads.
  # Tries tool_input.{prompt,message,content}, then top-level.
  local result=""

  # Fast path: try grep for each candidate field
  for field in prompt message content; do
    result=$(extract_simple_field "$field")
    if [ -n "$result" ]; then
      printf '%s' "$result"
      return
    fi
  done

  printf '%s' "$result"
}

normalize_command_for_scan() {
  printf '%s' "$1" | sed -e "s/\\\\\\([A-Za-z0-9_./:-]\\)/\\1/g" -e "s/[\"']//g"
}

append_script_content_for_scan() {
  local raw_cmd="$1"
  local cwd="$2"
  local shell_seen=0
  local skip_next=0
  local token=""
  local script=""
  local script_path=""

  [ -n "$cwd" ] || {
    printf '%s' "$raw_cmd"
    return
  }

  for token in $raw_cmd; do
    if [ "$shell_seen" -eq 0 ]; then
      case "$token" in
        bash|sh|zsh) shell_seen=1 ;;
      esac
      continue
    fi
    if [ "$skip_next" -eq 1 ]; then
      skip_next=0
      continue
    fi
    case "$token" in
      -c) skip_next=1 ;;
      -*) ;;
      *) script="$token"; break ;;
    esac
  done

  [ -n "$script" ] || {
    printf '%s' "$raw_cmd"
    return
  }
  case "$script" in
    /*) script_path="$script" ;;
    *) script_path="${cwd}/${script}" ;;
  esac
  if [ -f "$script_path" ] && [ ! -L "$script_path" ]; then
    printf '%s\n%s' "$raw_cmd" "$(head -c 65536 "$script_path" 2>/dev/null || true)"
  else
    printf '%s' "$raw_cmd"
  fi
}

# ── AgentKeeper Bypass Request ──────────────────────────────────────────
# Same rule as web/src/lib/detection/agentkeeper-bypass-request.ts; keep the
# two in step. Per sentence, a control-removal verb with a target that starts
# within eight words after it. Before the verb a target counts only in the
# passive ("agentkeeper should be disabled") or after a causative ("i need the
# agentkeeper hooks turned off"), so "why did agentkeeper stop my build?" is
# not a request, and a verb right after a negation ("do not disable") never
# counts. Targets are AgentKeeper and guardrails, plus hooks, monitoring,
# audit logs, controls, checks and protections when a qualifier (claude,
# agent, security, prompt, policy...) is within the three words before them.
# Webhooks and developer hooks (git, pre-commit, husky, React, web, useX)
# never count. POSIX ERE and C-locale tools only: bash 3.2 with BSD tools, and
# Git Bash.
is_agentkeeper_bypass_request() {
  local sep='[^a-z0-9_]+'
  local near="(${sep}[a-z0-9_]+){0,7}${sep}"
  local near5="(${sep}[a-z0-9_]+){0,5}${sep}"
  local near3="(${sep}[a-z0-9_]+){0,3}${sep}"
  local near2="(${sep}[a-z0-9_]+){0,2}${sep}"
  local verb='(disabl(e|es|ed|ing)|deactivat(e|es|ed|ing)|(turn(s|ed|ing)?|switch(es|ed|ing)?)[[:space:]]+off|shut(s|ting)?[[:space:]]+(off|down)|remov(e|es|ed|ing)|delet(e|es|ed|ing)|uninstall(s|ed|ing)?|bypass(es|ed|ing)?|skip(s|ped|ping)?|evad(e|es|ed|ing)|circumvent(s|ed|ing)?|(get(s|ting)?|got(ten)?)[[:space:]]+around|(go(es|ing|ne)?|went)[[:space:]]+around|work(s|ed|ing)?[[:space:]]+around|kill(s|ed|ing)?|stop(s|ped|ping)?|silenc(e|es|ed|ing)|mut(e|es|ed|ing)|ignor(e|es|ed|ing))'
  local participle='(disabled|deactivated|(turned|switched|shut)[[:space:]]+(off|down)|removed|deleted|uninstalled|bypassed|skipped|evaded|circumvented|killed|stopped|silenced|muted|ignored)'
  local auxiliary='(be|been|being|is|are|was|were|get|gets|getting|got|gotten)'
  local causative='(need|needs|needed|want|wants|wanted|get|gets|got)'
  local qualifier='(claude|agent|agentkeeper|security|pretooluse|posttooluse|userpromptsubmit|prompt|policy)'
  local qualified='(hooks?|monitoring|audit([[:space:]]+|-)?(logging|logs?)|controls|checks|protections?)'
  local target='(agent([[:space:]]+|-)?keeper|guard([[:space:]]+|-)?rails?|qualified_target)'
  local sentences

  # Candidate: every target or qualifier contains one of these stems.
  LC_ALL=C grep -Eiq 'agent|guard|claude|security|tooluse|prompt|policy' <<<"$1" || return 1

  # Exclusions rewrite a word (hook -> xhook, disable -> xdisable) so it can no
  # longer match, leaving word counts unchanged; a useX identifier is
  # camelCase, so it is rewritten before lowercasing. The text is then
  # lowercased with one sentence per line (escaped \n and \r break too: the
  # non-plutil field extraction leaves JSON escapes undecoded), a verb right
  # after a negation is rewritten, and a qualified target with its qualifier
  # becomes the single word qualified_target.
  sentences=$(printf '%s\n' "$1" \
    | LC_ALL=C sed -E \
      -e 's/\\[nr]/./g' \
      -e 's/\\t/ /g' \
      -e 's/(^|[^A-Za-z0-9_])(use[A-Z][A-Za-z0-9_]*[^A-Za-z0-9_]+)([Hh][Oo][Oo][Kk])/\1\2x\3/g' \
    | LC_ALL=C tr 'A-Z.!?;\r' 'a-z\n\n\n\n\n' \
    | LC_ALL=C sed -E \
      -e 's/(^|[^a-z0-9_])(git|pre-commit|precommit|commit|pre-push|post-merge|husky|react|lifecycle|web)([^a-z0-9_]+)hook/\1\2\3xhook/g' \
      -e 's/(^|[^a-z0-9_])(not|never|no|without|avoid|avoiding|cannot|(don|doesn|didn|can|couldn|won|wouldn|shouldn|mustn)[^a-z0-9_]{0,3}t)(([^a-z0-9_]+[a-z0-9_]+)?[^a-z0-9_]+)(disabl|deactivat|turn|switch|shut|remov|delet|uninstall|bypass|skip|evad|circumvent|get|got|go|went|work|kill|stop|silenc|mut|ignor)/\1\2\4x\6/g' \
      -e "s/(^|[^a-z0-9_])${qualifier}((${sep}[a-z0-9_]+){0,2}${sep})${qualified}/\\1\\2\\3qualified_target/g")
  LC_ALL=C grep -Eq "(^|[^a-z0-9_])(${verb}${near}${target}|${target}${near5}${auxiliary}(${sep}[a-z0-9_]+)?${sep}${participle}|${causative}${near3}${target}${near2}${participle})([^a-z0-9_]|\$)" <<<"$sentences"
}

# ── Detection Output ────────────────────────────────────────────────────

emit_detection() {
  local name="$1"
  local severity="$2"
  local description="$3"
  printf '%s\t%s\t%s\n' "$name" "$severity" "$description"
  exit 0
}

# ── Extract tool_name ───────────────────────────────────────────────────

tool_name=""

if [ "$HOOK_TYPE" = "prompt" ]; then
  tool_name="UserPrompt"
else
  tool_name=$(extract_simple_field "tool_name")
fi

# Short-circuit: no tool name means nothing to scan
if [ -z "$tool_name" ] && [ "$HOOK_TYPE" != "prompt" ]; then
  exit 0
fi

# ── Route to Pattern Set ────────────────────────────────────────────────

case "$tool_name" in
  Bash)
    cmd=$(extract_command_field)
    [ -z "$cmd" ] && exit 0
    cwd=$(extract_simple_field "cwd")
    cmd=$(append_script_content_for_scan "$cmd" "$cwd")
    cmd_scan=$(normalize_command_for_scan "$cmd")

    if printf '%s' "$cmd_scan" | grep -Eiq '(^|[;&|[:space:]])(rm|mv|chmod|chown|unlink|truncate|sed[[:space:]]+-i)[[:space:]].*(\.agentkeeper|agentkeeper-plugin|\.claude/(settings|settings\.local)\.json|\.cursor/(hooks/agentkeeper-hook\.sh|hooks\.json)|\.codeium/windsurf/hooks(/agentkeeper-hook\.sh|\.json)|\.copilot/hooks/(agentkeeper-hook\.sh|agentkeeper\.json)|\.github/hooks/agentkeeper\.json|\.gemini/settings\.json|\.codex/(config\.toml|requirements\.toml)|cowork_plugins|known_marketplaces\.json|installed_plugins\.json|cowork_settings\.json)'; then
      emit_detection "agentkeeper_control_tamper" "critical" "Modifying AgentKeeper or managed IDE control files"
    fi

    # ── Credential Exfiltration (pipe) ──
    # More specific: credentials piped directly to network command
    # Must be checked BEFORE the general credential_exfil pattern
    if printf '%s' "$cmd_scan" | grep -Eiq '(cat|head|tail)[[:space:]]+.*(\.env|\.ssh/|\.aws/|credentials|secrets|tokens?).*\|[[:space:]]*(curl|wget|nc|ncat)'; then
      emit_detection "credential_exfil_pipe" "critical" "Piping credentials to a network command"
    fi

    # ── Credential Exfiltration (subshell) ──
    # Embed credential read in network request via $() or backticks
    if printf '%s' "$cmd_scan" | grep -Eiq '(curl|wget).*(\$\(cat|`cat).*(\.env|\.ssh|\.aws|credentials|secrets|token)'; then
      emit_detection "credential_exfil_subshell" "critical" "Embedding credentials in a network request via subshell"
    fi

    # ── Credential Exfiltration (general) ──
    # Reads sensitive file AND sends to network in same command
    if printf '%s' "$cmd_scan" | grep -Eiq '(cat|head|tail|less|more|bat)[[:space:]]+.*(\.env|\.ssh/|\.aws/|\.gnupg/|credentials|secrets|tokens?\.json|\.netrc|\.npmrc|\.pypirc)'; then
      if printf '%s' "$cmd_scan" | grep -Eiq '(curl|wget|nc|ncat)[[:space:]]+.*(https?://|ftp://)'; then
        emit_detection "credential_exfil" "critical" "Reading sensitive files and sending to external endpoint"
      fi
    fi

    # ── Reverse Shells ──
    if printf '%s' "$cmd_scan" | grep -Eiq '(bash[[:space:]]+-i[[:space:]]+>&[[:space:]]*/dev/tcp|nc[[:space:]]+.*-e[[:space:]]+/bin/(sh|bash)|ncat[[:space:]]+.*--exec|python[23]?[[:space:]]+-c[[:space:]]+.*socket.*connect|perl[[:space:]]+-e[[:space:]]+.*socket.*exec|ruby[[:space:]]+-rsocket[[:space:]]+-e)'; then
      emit_detection "reverse_shell" "critical" "Reverse shell connection attempt"
    fi

    # Base64-encoded payload piped to shell
    if printf '%s' "$cmd_scan" | grep -Eiq '(echo|printf)[[:space:]]+[A-Za-z0-9+/=]+[[:space:]]*\|[[:space:]]*(base64[[:space:]]+-d|openssl[[:space:]]+base64[[:space:]]+-d)[[:space:]]*\|[[:space:]]*(bash|sh|zsh|python|perl|ruby)'; then
      emit_detection "reverse_shell_encoded" "critical" "Base64-encoded command piped to shell execution"
    fi

    # ── Security Control Bypass ──
    if printf '%s' "$cmd_scan" | grep -Eiq '(ufw[[:space:]]+disable|iptables[[:space:]]+-F|iptables[[:space:]]+--flush|pfctl[[:space:]]+-d|systemctl[[:space:]]+(stop|disable)[[:space:]]+(ufw|firewalld|iptables))'; then
      emit_detection "firewall_disable" "critical" "Disabling system firewall"
    fi

    if printf '%s' "$cmd_scan" | grep -Eiq '(setenforce[[:space:]]+0|echo[[:space:]]+0[[:space:]]*>[[:space:]]*/sys/fs/selinux/enforce|systemctl[[:space:]]+(stop|disable)[[:space:]]+apparmor|aa-teardown)'; then
      emit_detection "selinux_disable" "critical" "Disabling SELinux or AppArmor"
    fi

    if printf '%s' "$cmd_scan" | grep -Eiq '(systemctl[[:space:]]+(stop|disable)[[:space:]]+(clamd|crowdstrike|falcon-sensor|sentinel|cylance|symantec|mcafee)|launchctl[[:space:]]+unload.*(endpoint|security|protection))'; then
      emit_detection "antivirus_disable" "critical" "Disabling antivirus or endpoint protection"
    fi

    # ── Destructive Operations ──
    if printf '%s' "$cmd_scan" | grep -Eiq 'rm[[:space:]]+(-rf|-fr|--no-preserve-root)[[:space:]]+(/[[:space:]]|/\*|~/|/home|/etc|/usr|/var|/System)'; then
      emit_detection "recursive_delete_root" "critical" "Recursive deletion from root or system directory"
    fi

    # ── History Tampering ──
    if printf '%s' "$cmd_scan" | grep -Eiq '(history[[:space:]]+-c|>[[:space:]]*~/\.(bash_history|zsh_history)|shred[[:space:]]+.*history|rm[[:space:]]+.*\.(bash_history|zsh_history)|unset[[:space:]]+HISTFILE|export[[:space:]]+HISTSIZE=0)'; then
      emit_detection "history_tampering" "high" "Clearing shell history or logs to cover tracks"
    fi

    # ── Shadow File Access ──
    if printf '%s' "$cmd_scan" | grep -Eiq '(cat|head|tail|less|more|vim?|nano|cp|scp)[[:space:]]+(/etc/shadow|/etc/master\.passwd)'; then
      emit_detection "shadow_access" "high" "Accessing system password database"
    fi

    # ── SSH Key Exfiltration ──
    # Reads SSH private key AND has network activity AND is chained
    if printf '%s' "$cmd_scan" | grep -Eiq '(cat|head|tail|cp|scp|base64)[[:space:]]+.*(id_rsa|id_ed25519|id_ecdsa|\.pem|\.key)\b'; then
      if printf '%s' "$cmd_scan" | grep -Eiq '(curl|wget|nc|ssh|scp|rsync)[[:space:]]'; then
        if printf '%s' "$cmd_scan" | grep -Eq '[;&|]'; then
          emit_detection "ssh_key_read_and_send" "critical" "Reading SSH private keys with network activity in same command"
        fi
      fi
    fi

    # ── Cryptomining ──
    if printf '%s' "$cmd_scan" | grep -Eiq '(xmrig|cpuminer|minerd|cgminer|bfgminer|stratum\+tcp|cryptonight|monero.*pool|(curl|wget).*(\.sh|\.bin)[[:space:]]*\|[[:space:]]*(bash|sh).*mine)'; then
      emit_detection "cryptominer" "critical" "Cryptocurrency mining software installation or execution"
    fi

    # ── DNS Exfiltration ──
    # The DNS tool must sit at a command position, and the encoder branch must
    # pipe into it. Word boundaries are load-bearing: without them "od" matches
    # inside code, prod, node and mode, and "host" matches inside hostname and
    # localhost, so any command mentioning both looked like DNS exfiltration.
    if printf '%s' "$cmd_scan" | grep -Eiq '(^|[;&|][[:space:]]*)(dig|nslookup|host)[[:space:]]+.*(\$\(|`)|\b(base64|xxd|od)\b.*\|[[:space:]]*(xargs[[:space:]]+(-[^[:space:]]+[[:space:]]+)*)?(dig|nslookup|host)\b'; then
      emit_detection "dns_exfil" "high" "Encoding data in DNS queries for exfiltration"
    fi

    # ── SUID/SGID Manipulation ──
    # Numeric: setuid bit requires leading octal digit 4-7 (e.g., 4755, 6755)
    # Symbolic: u+s or g+s
    if printf '%s' "$cmd_scan" | grep -Eiq 'chmod[[:space:]]+[ug]\+s[[:space:]]'; then
      emit_detection "suid_manipulation" "critical" "Setting SUID/SGID bits for privilege escalation"
    fi
    if printf '%s' "$cmd_scan" | grep -Eq 'chmod[[:space:]]+[0-7]*[4-7][0-7]{2}[[:space:]]'; then
      # Verify the match is actually a setuid/setgid mode (4-digit with leading 4-7)
      _suid_mode=$(printf '%s' "$cmd_scan" | grep -oE 'chmod[[:space:]]+[0-7]+' | head -1 | grep -oE '[0-7]+$') || true
      if [ -n "${_suid_mode:-}" ] && [ "${#_suid_mode}" -ge 4 ]; then
        # 4+ digit mode — first digit determines special bits
        _suid_first="${_suid_mode:0:1}"
        case "$_suid_first" in
          4|5|6|7) emit_detection "suid_manipulation" "critical" "Setting SUID/SGID bits for privilege escalation" ;;
        esac
      fi
    fi

    # ── Suspicious Package Installation ──
    if printf '%s' "$cmd_scan" | grep -Eiq '(pip[[:space:]]+install|npm[[:space:]]+install|gem[[:space:]]+install)[[:space:]]+(https?://|git\+|git://)'; then
      emit_detection "suspicious_install" "high" "Installing packages from raw URLs instead of registries"
    fi

    # No bash pattern matched
    exit 0
    ;;

  Write|Edit)
    file_path=$(extract_simple_field "file_path")
    [ -z "$file_path" ] && exit 0

    if printf '%s' "$file_path" | grep -Eiq '(/\.claude/(settings|settings\.local)\.json$|/\.agentkeeper|/agentkeeper-plugin|/\.cursor/(hooks/agentkeeper-hook\.sh|hooks\.json)$|/\.codeium/windsurf/hooks(/agentkeeper-hook\.sh|\.json)$|/\.copilot/hooks/(agentkeeper-hook\.sh|agentkeeper\.json)$|/\.github/hooks/agentkeeper\.json$|/\.gemini/settings\.json$|/\.codex/(config\.toml|requirements\.toml)$|/cowork_plugins/|/(known_marketplaces|installed_plugins|cowork_settings)\.json$)'; then
      emit_detection "agentkeeper_control_config_write" "critical" "Modifying AgentKeeper or managed IDE control configuration"
    fi

    # ── SSH Config Write ── (before system_file_write to avoid shadowing)
    if printf '%s' "$file_path" | grep -Eiq '(\.ssh/(authorized_keys|config|known_hosts|id_)|/etc/ssh/sshd_config)'; then
      emit_detection "ssh_config_write" "critical" "Modifying SSH configuration or authorized keys"
    fi

    # ── Cron / LaunchDaemon Injection ── (before system_file_write)
    if printf '%s' "$file_path" | grep -Eiq '(/etc/cron|/var/spool/cron|/Library/LaunchDaemons|/Library/LaunchAgents/)'; then
      # Exclude our own LaunchAgent
      if ! printf '%s' "$file_path" | grep -Eiq '/Library/LaunchAgents/com\.agentkeeper'; then
        emit_detection "cron_injection" "critical" "Modifying system cron jobs or scheduled tasks"
      fi
    fi

    # ── System File Write ──
    if printf '%s' "$file_path" | grep -Eiq '^/(etc|usr|var/(spool|log|lib)|System|Library/[^C])'; then
      # Exclude /var/tmp (legitimate temp dir)
      if ! printf '%s' "$file_path" | grep -Eiq '^/var/tmp/'; then
        emit_detection "system_file_write" "critical" "Writing to system directories outside project scope"
      fi
    fi

    # ── Startup Script Injection ──
    if printf '%s' "$file_path" | grep -Eiq '(/\.(bashrc|bash_profile|zshrc|profile|zprofile|login|zlogin)$|/\.config/fish/config\.fish)'; then
      emit_detection "startup_injection" "high" "Modifying shell startup scripts (persistence mechanism)"
    fi

    # ── CI/CD Pipeline Tampering ──
    if printf '%s' "$file_path" | grep -Eiq '(\.github/workflows/|\.gitlab-ci\.yml|Jenkinsfile|\.circleci/|\.travis\.yml|bitbucket-pipelines\.yml|azure-pipelines\.yml)'; then
      emit_detection "cicd_tampering" "high" "Modifying CI/CD pipeline configuration"
    fi

    # ── Git Hook Injection ──
    if printf '%s' "$file_path" | grep -Eiq '\.git/hooks/'; then
      emit_detection "git_hook_write" "high" "Writing to git hooks (potential supply chain attack)"
    fi

    # No file pattern matched
    exit 0
    ;;

  Read)
    file_path=$(extract_simple_field "file_path")
    [ -z "$file_path" ] && exit 0

    # Sensitive read patterns — warn only, never block
    if printf '%s' "$file_path" | grep -Eiq '(^|/)\.(env|env\.local|env\.production|env\.staging|env\.secret|env\.development\.local)$'; then
      emit_detection "read_env_file" "high" "Reading environment file that may contain secrets"
    fi
    if printf '%s' "$file_path" | grep -Eiq '\.ssh/(id_rsa|id_ed25519|id_ecdsa|id_dsa|authorized_keys|config)$'; then
      emit_detection "read_ssh_keys" "critical" "Reading SSH private keys or configuration"
    fi
    if printf '%s' "$file_path" | grep -Eiq '\.aws/(credentials|config)$'; then
      emit_detection "read_aws_credentials" "critical" "Reading AWS credentials or configuration"
    fi
    if printf '%s' "$file_path" | grep -Eiq '\.config/gcloud/(credentials|application_default_credentials)\.json$'; then
      emit_detection "read_gcloud_credentials" "critical" "Reading Google Cloud credentials"
    fi
    if printf '%s' "$file_path" | grep -Eiq '\.kube/config$'; then
      emit_detection "read_kube_config" "high" "Reading Kubernetes configuration"
    fi
    if printf '%s' "$file_path" | grep -Eiq '\.docker/config\.json$'; then
      emit_detection "read_docker_config" "high" "Reading Docker credentials"
    fi
    if printf '%s' "$file_path" | grep -Eiq '(^|/)\.npmrc$'; then
      emit_detection "read_npm_token" "high" "Reading npm authentication token"
    fi
    if printf '%s' "$file_path" | grep -Eiq '(^|/)\.pypirc$'; then
      emit_detection "read_pypi_token" "high" "Reading PyPI authentication token"
    fi
    if printf '%s' "$file_path" | grep -Eiq '(^|/)\.git-credentials$'; then
      emit_detection "read_git_credentials" "high" "Reading git credentials store"
    fi
    if printf '%s' "$file_path" | grep -Eiq '(^|/)\.(netrc|curlrc)$'; then
      emit_detection "read_netrc" "high" "Reading netrc credentials file"
    fi
    if printf '%s' "$file_path" | grep -Eiq '/etc/(shadow|master\.passwd|gshadow)$'; then
      emit_detection "read_shadow" "critical" "Reading system password database"
    fi
    if printf '%s' "$file_path" | grep -Eiq '/etc/sudoers(\.d/|$)'; then
      emit_detection "read_sudoers" "high" "Reading sudoers configuration"
    fi
    if printf '%s' "$file_path" | grep -Eiq '\.gnupg/(private-keys|secring|trustdb)'; then
      emit_detection "read_gnupg_keys" "critical" "Reading GPG private keys"
    fi
    if printf '%s' "$file_path" | grep -Eiq '(^|/)\.vault-token$'; then
      emit_detection "read_vault_token" "critical" "Reading HashiCorp Vault token"
    fi
    if printf '%s' "$file_path" | grep -Eiq '(^|/)\.pgpass$'; then
      emit_detection "read_pgpass" "high" "Reading PostgreSQL password file"
    fi
    if printf '%s' "$file_path" | grep -Eiq '(^|/)\.my\.cnf$'; then
      emit_detection "read_my_cnf" "high" "Reading MySQL credentials file"
    fi

    # No read pattern matched
    exit 0
    ;;

  Glob)
    pattern=$(extract_simple_field "pattern")
    [ -z "$pattern" ] && exit 0

    # Reuse sensitive read patterns against glob pattern string
    if printf '%s' "$pattern" | grep -Eiq '\.ssh/(id_rsa|id_ed25519|id_ecdsa|id_dsa|authorized_keys|config)'; then
      emit_detection "read_ssh_keys" "critical" "Glob targeting SSH private keys or configuration"
    fi
    if printf '%s' "$pattern" | grep -Eiq '\.aws/(credentials|config)'; then
      emit_detection "read_aws_credentials" "critical" "Glob targeting AWS credentials"
    fi
    if printf '%s' "$pattern" | grep -Eiq '\.gnupg/(private-keys|secring)'; then
      emit_detection "read_gnupg_keys" "critical" "Glob targeting GPG private keys"
    fi

    exit 0
    ;;

  Grep)
    grep_path=$(extract_simple_field "path")
    [ -z "$grep_path" ] && exit 0

    # Check if grep is searching sensitive paths
    if printf '%s' "$grep_path" | grep -Eiq '\.ssh/(id_rsa|id_ed25519|id_ecdsa|id_dsa|authorized_keys|config)'; then
      emit_detection "read_ssh_keys" "critical" "Grep searching SSH private keys or configuration"
    fi
    if printf '%s' "$grep_path" | grep -Eiq '\.aws/(credentials|config)'; then
      emit_detection "read_aws_credentials" "critical" "Grep searching AWS credentials"
    fi

    exit 0
    ;;

  WebFetch|WebSearch)
    url=$(extract_simple_field "url")
    if [ -z "$url" ]; then
      url=$(extract_simple_field "query")
    fi
    [ -z "$url" ] && exit 0

    # ── Known Exfiltration Endpoints ──
    if printf '%s' "$url" | grep -Eiq '(requestbin\.com|pipedream\.net|webhook\.site|hookbin\.com|requestcatcher\.com|beeceptor\.com|mockbin\.org|ngrok\.io|ngrok-free\.app|burpcollaborator\.net|interact\.sh|canarytokens\.com)'; then
      emit_detection "exfil_endpoint" "high" "Fetching from known data exfiltration service"
    fi

    # ── Raw IP Fetch (non-private) ──
    if printf '%s' "$url" | grep -Eq '^https?://[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'; then
      if ! printf '%s' "$url" | grep -Eq '^https?://(127\.0\.0\.1|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|0\.0\.0\.0|localhost)'; then
        emit_detection "raw_ip_fetch" "medium" "Fetching from raw IP address (potential C2)"
      fi
    fi

    exit 0
    ;;

  UserPrompt)
    prompt_text=$(extract_prompt_text)
    [ -z "$prompt_text" ] && exit 0

    if is_agentkeeper_bypass_request "$prompt_text"; then
      emit_detection "agentkeeper_bypass_request" "critical" "Request to disable or bypass AgentKeeper controls"
    fi

    # ── Prompt Injection: Override ──
    if printf '%s' "$prompt_text" | grep -Eiq '(ignore|disregard|forget|override)[[:space:]]+(all[[:space:]]+)?(previous|prior|above|earlier)[[:space:]]+(instructions?|rules?|guidelines?|constraints?)'; then
      emit_detection "prompt_injection_override" "critical" "Attempt to override system instructions or prior context"
    fi

    # ── Prompt Injection: Persona ──
    if printf '%s' "$prompt_text" | grep -Eiq '(you are now|from now on you are|your new identity is|act as if you have no restrictions|pretend (you have|there are) no (rules|restrictions|limits))'; then
      emit_detection "prompt_injection_persona" "critical" "Attempt to change the AI identity or behavior"
    fi

    # ── Prompt Injection: Jailbreak ──
    if printf '%s' "$prompt_text" | grep -Eiq '(jailbreak|DAN[[:space:]]*mode|do anything now|evil[[:space:]]*mode|uncensored[[:space:]]*mode|developer[[:space:]]*mode|god[[:space:]]*mode)'; then
      emit_detection "prompt_injection_jailbreak" "critical" "Known jailbreak pattern"
    fi

    # ── Exfiltration Instruction ──
    if printf '%s' "$prompt_text" | grep -Eiq '(send|post|upload|exfiltrate|forward|transmit)[[:space:]]+(all|the|my|this|every)[[:space:]]+(data|files?|credentials?|secrets?|keys?|tokens?|code|contents?)[[:space:]]+to[[:space:]]+(https?://|an?[[:space:]]+(external|remote))'; then
      emit_detection "exfil_instruction" "critical" "Instruction to send data to an external endpoint"
    fi

    # ── Credential Request ──
    if printf '%s' "$prompt_text" | grep -Eiq '(show|list|output|reveal|dump|print|display|read)[[:space:]]+(all[[:space:]]+)?(my[[:space:]]+)?(api[_ ]?keys?|tokens?|credentials?|secrets?|passwords?|private[_ ]keys?|\.env)'; then
      emit_detection "credential_request" "high" "Request to extract and display credentials"
    fi

    # ── Security Disable Request ──
    if printf '%s' "$prompt_text" | grep -Eiq '(disable|turn off|remove|bypass|skip)[[:space:]]+(the[[:space:]]+)?(firewall|security|antivirus|sandbox|shield|protection|hook|monitoring|logging|audit)'; then
      emit_detection "security_disable_request" "high" "Request to disable security controls"
    fi

    # No prompt pattern matched
    exit 0
    ;;

  *)
    # Unknown tool — no patterns to run
    exit 0
    ;;
esac
