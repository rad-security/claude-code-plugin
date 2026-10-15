#!/usr/bin/env bash
# runtime-identity.sh — Adds managed runtime identity to hook payloads.
# Sourced by hook dispatcher scripts. No top-level execution.

agentkeeper_identity_env_candidates() {
  if [ -n "${AGENTKEEPER_IDENTITY_ENV:-}" ]; then
    printf '%s\n' "$AGENTKEEPER_IDENTITY_ENV"
  fi
  printf '%s\n' "$HOME/.agentkeeper/config/sagemaker-identity.env"
  printf '%s\n' "$HOME/.agentkeeper-plugin/sagemaker-identity.env"
}

agentkeeper_load_runtime_identity() {
  local file
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    [ -r "$file" ] || continue
    # shellcheck disable=SC1090
    set -a
    . "$file" 2>/dev/null || true
    set +a
    return 0
  done <<EOF
$(agentkeeper_identity_env_candidates)
EOF
  return 0
}

agentkeeper_runtime_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '\r\n'
}

agentkeeper_runtime_trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

agentkeeper_is_serviceish_identity() {
  local value lower
  value="$(agentkeeper_runtime_trim "$1")"
  lower="$(agentkeeper_runtime_lower "$value")"
  case "$lower" in
    ""|"unknown"|"null"|"none"|"root"|"admin"|"administrator"|"daemon"|"nobody"|"system"|"sagemaker-user"|"ec2-user"|"ubuntu")
      return 0
      ;;
  esac
  return 1
}

agentkeeper_runtime_first_identity() {
  local candidate
  for candidate in "$@"; do
    candidate="$(agentkeeper_runtime_trim "$candidate")"
    if [ -n "$candidate" ] && ! agentkeeper_is_serviceish_identity "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
  done
}

agentkeeper_runtime_user_hint() {
  agentkeeper_runtime_first_identity \
    "${AGENTKEEPER_USER_EMAIL:-}" \
    "${AGENTKEEPER_USER_HINT:-}" \
    "${AGENTKEEPER_SAGEMAKER_SSO_USER_VALUE:-}" \
    "${AGENTKEEPER_SAGEMAKER_SPACE_OWNER:-}" \
    "${AGENTKEEPER_SAGEMAKER_USER_PROFILE:-}" \
    "${AGENTKEEPER_SAGEMAKER_SPACE_NAME:-}"
}

agentkeeper_runtime_user_email() {
  local candidate hint
  candidate="$(agentkeeper_runtime_trim "${AGENTKEEPER_USER_EMAIL:-}")"
  case "$candidate" in
    *@*.*) printf '%s' "$candidate"; return 0 ;;
  esac
  hint="$(agentkeeper_runtime_user_hint)"
  case "$hint" in
    *@*.*) printf '%s' "$hint"; return 0 ;;
  esac
}

# Local identity evidence — what the workstation itself can vouch for. None of
# it is verified; the backend ranks it below directory/MDM/browser evidence and
# only uses it when nothing stronger names the person. Opt out with
# AGENTKEEPER_LOCAL_IDENTITY_EVIDENCE=0.
agentkeeper_local_identity_enabled() {
  [ "${AGENTKEEPER_LOCAL_IDENTITY_EVIDENCE:-1}" != "0" ]
}

# The Claude login (corporate SSO on Enterprise/Team plans) from ~/.claude.json.
agentkeeper_claude_account_email() {
  agentkeeper_local_identity_enabled || return 0
  local file="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json" value
  [ -r "$file" ] || file="$HOME/.claude.json"
  [ -r "$file" ] || return 0
  value="$(sed -n 's/.*"emailAddress"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" 2>/dev/null | head -n 1)"
  case "$value" in
    *@*.*) printf '%s' "$value" ;;
  esac
}

# The developer's commit identity (repo config first, then global).
agentkeeper_git_user_email() {
  agentkeeper_local_identity_enabled || return 0
  command -v git >/dev/null 2>&1 || return 0
  local value
  value="$(git config --get user.email 2>/dev/null || true)"
  [ -n "$value" ] || value="$(git config --global --get user.email 2>/dev/null || true)"
  case "$value" in
    *@*.*) printf '%s' "$value" ;;
  esac
}

# The OS account's full name (macOS `id -F`, Linux GECOS). Skipped when it is
# just the username again.
agentkeeper_os_fullname() {
  agentkeeper_local_identity_enabled || return 0
  local value=""
  case "$(uname -s 2>/dev/null)" in
    Darwin) value="$(id -F 2>/dev/null || true)" ;;
    Linux)
      if command -v getent >/dev/null 2>&1; then
        value="$(getent passwd "${USER:-$(id -un 2>/dev/null)}" 2>/dev/null | cut -d: -f5 | cut -d, -f1)"
      fi
      ;;
  esac
  value="$(agentkeeper_runtime_trim "$value")"
  [ -n "$value" ] || return 0
  if [ "$(agentkeeper_runtime_lower "$value")" = "$(agentkeeper_runtime_lower "${USER:-}")" ]; then
    return 0
  fi
  agentkeeper_is_serviceish_identity "$value" && return 0
  printf '%s' "$value"
}

agentkeeper_runtime_json_escape() {
  if command -v _json_escape >/dev/null 2>&1; then
    _json_escape "$1"
    return 0
  fi
  if command -v cowork_json_escape >/dev/null 2>&1; then
    cowork_json_escape "$1"
    return 0
  fi
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

agentkeeper_runtime_identity_fields() {
  local fields user_hint user_email machine_id
  fields=""
  user_hint="$(agentkeeper_runtime_user_hint)"
  user_email="$(agentkeeper_runtime_user_email)"
  machine_id="${AGENTKEEPER_MACHINE_ID:-}"
  if [ -z "$machine_id" ] && command -v get_machine_id >/dev/null 2>&1; then
    machine_id="$(get_machine_id 2>/dev/null || true)"
  fi

  if [ -n "$user_hint" ]; then
    fields="${fields},\"user\":\"$(agentkeeper_runtime_json_escape "$user_hint")\""
    fields="${fields},\"user_hint\":\"$(agentkeeper_runtime_json_escape "$user_hint")\""
  fi
  if [ -n "$user_email" ]; then
    fields="${fields},\"user_email\":\"$(agentkeeper_runtime_json_escape "$user_email")\""
  fi
  local claude_email git_email os_fullname
  claude_email="$(agentkeeper_claude_account_email 2>/dev/null || true)"
  git_email="$(agentkeeper_git_user_email 2>/dev/null || true)"
  os_fullname="$(agentkeeper_os_fullname 2>/dev/null || true)"
  if [ -n "$claude_email" ]; then
    fields="${fields},\"claude_account_email\":\"$(agentkeeper_runtime_json_escape "$claude_email")\""
  fi
  if [ -n "$git_email" ]; then
    fields="${fields},\"git_email\":\"$(agentkeeper_runtime_json_escape "$git_email")\""
  fi
  if [ -n "$os_fullname" ]; then
    fields="${fields},\"os_fullname\":\"$(agentkeeper_runtime_json_escape "$os_fullname")\""
  fi
  if [ -n "${AGENTKEEPER_SAGEMAKER_DOMAIN_ID:-}" ]; then
    fields="${fields},\"sagemaker_domain_id\":\"$(agentkeeper_runtime_json_escape "$AGENTKEEPER_SAGEMAKER_DOMAIN_ID")\""
  fi
  if [ -n "${AGENTKEEPER_SAGEMAKER_USER_PROFILE:-}" ]; then
    fields="${fields},\"sagemaker_user_profile\":\"$(agentkeeper_runtime_json_escape "$AGENTKEEPER_SAGEMAKER_USER_PROFILE")\""
  fi
  if [ -n "${AGENTKEEPER_SAGEMAKER_SPACE_NAME:-}" ]; then
    fields="${fields},\"sagemaker_space_name\":\"$(agentkeeper_runtime_json_escape "$AGENTKEEPER_SAGEMAKER_SPACE_NAME")\""
  fi
  if [ -n "${AGENTKEEPER_SAGEMAKER_APP_TYPE:-}" ]; then
    fields="${fields},\"sagemaker_app_type\":\"$(agentkeeper_runtime_json_escape "$AGENTKEEPER_SAGEMAKER_APP_TYPE")\""
  fi
  if [ -n "${AGENTKEEPER_SAGEMAKER_APP_NAME:-}" ]; then
    fields="${fields},\"sagemaker_app_name\":\"$(agentkeeper_runtime_json_escape "$AGENTKEEPER_SAGEMAKER_APP_NAME")\""
  fi
  if [ "${AGENTKEEPER_RUNTIME_SKIP_MACHINE_ID_FIELD:-}" != "1" ] && [ -n "$machine_id" ]; then
    fields="${fields},\"machine_id\":\"$(agentkeeper_runtime_json_escape "$machine_id")\""
  fi
  printf '%s' "$fields"
}

agentkeeper_enrich_json_payload() {
  local payload="$1"
  if ! command -v python3 >/dev/null 2>&1; then
    printf '%s' "$payload"
    return 0
  fi
  AGENTKEEPER_RUNTIME_PAYLOAD="$payload" \
  AGENTKEEPER_LOCAL_CLAUDE_EMAIL="$(agentkeeper_claude_account_email 2>/dev/null || true)" \
  AGENTKEEPER_LOCAL_GIT_EMAIL="$(agentkeeper_git_user_email 2>/dev/null || true)" \
  AGENTKEEPER_LOCAL_OS_FULLNAME="$(agentkeeper_os_fullname 2>/dev/null || true)" \
  AGENTKEEPER_LOCAL_LOGIN_ENABLED="$(agentkeeper_local_identity_enabled && printf 1 || printf 0)" \
  python3 - <<'PY' 2>/dev/null || printf '%s' "$payload"
import base64
import json
import os
import re
import sys
from pathlib import Path

raw = os.environ.get("AGENTKEEPER_RUNTIME_PAYLOAD", "")
try:
    data = json.loads(raw)
except Exception:
    sys.stdout.write(raw)
    raise SystemExit(0)
if not isinstance(data, dict):
    sys.stdout.write(raw)
    raise SystemExit(0)

def first(*values):
    for value in values:
        if isinstance(value, str) and value.strip():
            stripped = value.strip()
            if stripped.lower() not in {"unknown", "null", "none", "root", "admin", "administrator", "daemon", "nobody", "system", "sagemaker-user", "ec2-user", "ubuntu"}:
                return stripped
    return ""

user_hint = first(
    os.environ.get("AGENTKEEPER_USER_EMAIL"),
    os.environ.get("AGENTKEEPER_USER_HINT"),
    os.environ.get("AGENTKEEPER_SAGEMAKER_SSO_USER_VALUE"),
    os.environ.get("AGENTKEEPER_SAGEMAKER_SPACE_OWNER"),
    os.environ.get("AGENTKEEPER_SAGEMAKER_USER_PROFILE"),
    os.environ.get("AGENTKEEPER_SAGEMAKER_SPACE_NAME"),
)
user_email = os.environ.get("AGENTKEEPER_USER_EMAIL", "").strip()
if not user_email and "@" in user_hint and "." in user_hint:
    user_email = user_hint

updates = {
    "user": user_hint,
    "user_hint": user_hint,
    "user_email": user_email,
    "sagemaker_domain_id": os.environ.get("AGENTKEEPER_SAGEMAKER_DOMAIN_ID", "").strip(),
    "sagemaker_user_profile": os.environ.get("AGENTKEEPER_SAGEMAKER_USER_PROFILE", "").strip(),
    "sagemaker_space_name": os.environ.get("AGENTKEEPER_SAGEMAKER_SPACE_NAME", "").strip(),
    "sagemaker_app_type": os.environ.get("AGENTKEEPER_SAGEMAKER_APP_TYPE", "").strip(),
    "sagemaker_app_name": os.environ.get("AGENTKEEPER_SAGEMAKER_APP_NAME", "").strip(),
    "machine_id": os.environ.get("AGENTKEEPER_MACHINE_ID", "").strip(),
    # Local identity evidence (see agentkeeper_claude_account_email & co).
    "claude_account_email": os.environ.get("AGENTKEEPER_LOCAL_CLAUDE_EMAIL", "").strip(),
    "git_email": os.environ.get("AGENTKEEPER_LOCAL_GIT_EMAIL", "").strip(),
    "os_fullname": os.environ.get("AGENTKEEPER_LOCAL_OS_FULLNAME", "").strip(),
}
for key, value in updates.items():
    if value:
        data[key] = value

# Which login the coding agent is signed in with: personal or company. Read
# from the agent's own login file on the events the server checks
# (SessionStart, UserPromptSubmit). Only identifiers and plan names leave the
# machine; never a token. Claude Code: ~/.claude.json oauthAccount. Codex:
# ~/.codex/auth.json, whose id_token payload is decoded here, never sent.
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
TOKEN_RE = re.compile(r"^[a-z0-9][a-z0-9_.-]{0,63}$")
DOMAIN_RE = re.compile(r"^(?=.{1,253}$)[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$")

def login_text(value, pattern):
    value = value.strip().lower() if isinstance(value, str) else ""
    return value if pattern.match(value) else ""

def login_email(value):
    value = value.strip().lower() if isinstance(value, str) else ""
    if len(value) > 254 or value.count("@") != 1:
        return ""
    local, domain = value.split("@")
    return value if local and DOMAIN_RE.match(domain) else ""

def read_login_file(path, limit):
    try:
        if not os.path.isfile(path) or os.path.getsize(path) > limit:
            return {}
        with open(path, "rb") as handle:
            parsed = json.loads(handle.read(limit).decode("utf-8", "ignore"))
        return parsed if isinstance(parsed, dict) else {}
    except Exception:
        return {}

def claude_login():
    config_dir = os.environ.get("CLAUDE_CONFIG_DIR", "").strip()
    paths = [os.path.join(config_dir, ".claude.json")] if config_dir else []
    paths.append(os.path.join(str(Path.home()), ".claude.json"))
    for path in paths:
        account = read_login_file(path, 16 << 20).get("oauthAccount")
        if isinstance(account, dict):
            email = login_email(account.get("emailAddress"))
            return {
                "claude_account_domain": email.split("@", 1)[1] if email else "",
                "claude_org_uuid": login_text(account.get("organizationUuid"), UUID_RE),
                "claude_org_type": login_text(account.get("organizationType"), TOKEN_RE),
            }
    return {}

def id_token_claims(token):
    if isinstance(token, dict):
        return token
    try:
        segment = token.split(".")[1]
        segment += "=" * (-len(segment) % 4)
        claims = json.loads(base64.urlsafe_b64decode(segment.encode("ascii")).decode("utf-8"))
        return claims if isinstance(claims, dict) else {}
    except Exception:
        return {}

def codex_login():
    codex_home = os.environ.get("CODEX_HOME", "").strip() or os.path.join(str(Path.home()), ".codex")
    auth = read_login_file(os.path.join(codex_home, "auth.json"), 1 << 20)
    if not auth:
        return {}
    tokens = auth.get("tokens") if isinstance(auth.get("tokens"), dict) else {}
    claims = id_token_claims(tokens.get("id_token"))
    openai = claims.get("https://api.openai.com/auth")
    openai = openai if isinstance(openai, dict) else {}
    email = login_email(claims.get("email"))
    return {
        "codex_auth_mode": login_text(auth.get("auth_mode"), TOKEN_RE),
        "chatgpt_account_id": login_text(openai.get("chatgpt_account_id") or tokens.get("account_id"), UUID_RE),
        "chatgpt_plan_type": login_text(openai.get("chatgpt_plan_type"), TOKEN_RE),
        "codex_account_email": email,
        "codex_account_domain": email.split("@", 1)[1] if email else "",
    }

def login_agent():
    tool = (os.environ.get("AGENTKEEPER_API_TOOL") or os.environ.get("AGENTKEEPER_IDE") or "").strip().lower().replace("-", "_")
    if tool in ("", "claude_code", "claude"):
        return "claude_code"
    return tool if tool == "codex" else ""

login_event = data.get("hook_event_name") or data.get("hookEventName")
if os.environ.get("AGENTKEEPER_LOCAL_LOGIN_ENABLED") == "1" and login_event in ("SessionStart", "UserPromptSubmit"):
    try:
        agent = login_agent()
        login = claude_login() if agent == "claude_code" else codex_login() if agent == "codex" else {}
    except Exception:
        login = {}
    for key, value in login.items():
        if value and not data.get(key):
            data[key] = value

def clean_text(value, limit=240):
    if not isinstance(value, str):
        return ""
    value = value.strip().replace("\r", "").replace("\n", "")
    if not value or len(value) > limit:
        return ""
    if value.lower() in {"unknown", "null", "none"}:
        return ""
    return value

def first_string(record, keys):
    if not isinstance(record, dict):
        return ""
    for key in keys:
        value = clean_text(record.get(key))
        if value:
            return value
    return ""

def infer_provider(model):
    model_l = model.lower()
    if "/" in model_l:
        prefix = clean_text(model_l.split("/", 1)[0], 80)
        if prefix:
            return prefix
    if model_l.startswith("claude") or "anthropic" in model_l:
        return "anthropic"
    if model_l.startswith(("gpt", "o1", "o3", "o4")) or "openai" in model_l:
        return "openai"
    if model_l.startswith("gemini") or "google" in model_l:
        return "google"
    return ""

def direct_model(record):
    model = first_string(record, [
        "model", "model_name", "modelName", "active_model", "activeModel",
        "llm_model", "llmModel",
    ])
    provider = first_string(record, [
        "model_provider", "modelProvider", "provider", "provider_id",
        "providerId", "llm_provider", "llmProvider",
    ])
    source = first_string(record, [
        "agentkeeper_model_source", "model_source", "modelSource",
    ])
    confidence = first_string(record, [
        "agentkeeper_model_confidence", "model_confidence", "modelConfidence",
    ])
    if model or provider:
        return {
            "model": model,
            "provider": provider or infer_provider(model),
            "source": source or "payload",
            "confidence": confidence or "high",
        }
    return {}

def env_model():
    model = clean_text(
        os.environ.get("AGENTKEEPER_MODEL")
        or os.environ.get("AGENTKEEPER_MODEL_NAME")
        or os.environ.get("CLAUDE_MODEL")
        or os.environ.get("ANTHROPIC_MODEL")
    )
    provider = clean_text(
        os.environ.get("AGENTKEEPER_MODEL_PROVIDER")
        or os.environ.get("CLAUDE_MODEL_PROVIDER")
    )
    if model or provider:
        return {
            "model": model,
            "provider": provider or infer_provider(model),
            "source": "env",
            "confidence": "high",
        }
    return {}

MODEL_KEYS = {
    "model", "model_name", "modelname", "active_model", "activemodel",
    "llm_model", "llmmodel",
}
PROVIDER_KEYS = {
    "model_provider", "modelprovider", "provider", "provider_id",
    "providerid", "llm_provider", "llmprovider",
}

def walk_for_model(value, depth=0):
    if depth > 6:
        return {}
    if isinstance(value, dict):
        found = direct_model(value)
        if found:
            return found
        for key, nested in value.items():
            key_l = str(key).lower()
            if key_l in MODEL_KEYS:
                model = clean_text(nested)
                if model:
                    return {
                        "model": model,
                        "provider": infer_provider(model),
                        "source": "nested_json",
                        "confidence": "medium",
                    }
            if key_l in PROVIDER_KEYS:
                provider = clean_text(nested)
                if provider:
                    return {
                        "model": "",
                        "provider": provider,
                        "source": "nested_json",
                        "confidence": "medium",
                    }
            found = walk_for_model(nested, depth + 1)
            if found:
                return found
    elif isinstance(value, list):
        for nested in value[-20:]:
            found = walk_for_model(nested, depth + 1)
            if found:
                return found
    return {}

def read_json_file_model(path, source, confidence):
    try:
        with open(path, "rb") as handle:
            raw_bytes = handle.read(262144)
        parsed = json.loads(raw_bytes.decode("utf-8", "ignore"))
    except Exception:
        return {}
    found = walk_for_model(parsed)
    if not found:
        return {}
    found["source"] = source
    found["confidence"] = confidence
    if found.get("model") and not found.get("provider"):
        found["provider"] = infer_provider(found["model"])
    return found

def transcript_model():
    transcript = first_string(data, ["transcript_path", "transcriptPath"])
    if not transcript:
        return {}
    path = Path(transcript).expanduser()
    if not path.is_file():
        return {}
    try:
        lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()[-200:]
    except Exception:
        return {}
    for line in reversed(lines):
        line = line.strip()
        if not line:
            continue
        try:
            parsed = json.loads(line)
        except Exception:
            continue
        found = walk_for_model(parsed)
        if found:
            found["source"] = "claude_transcript"
            found["confidence"] = "medium"
            if found.get("model") and not found.get("provider"):
                found["provider"] = infer_provider(found["model"])
            return found
    return {}

def cowork_session_roots():
    roots = []
    home = Path.home()
    if sys.platform == "darwin":
        roots.append(home / "Library" / "Application Support" / "Claude" / "local-agent-mode-sessions")
    roots.append(Path(os.environ.get("XDG_CONFIG_HOME", home / ".config")) / "Claude" / "local-agent-mode-sessions")
    appdata = os.environ.get("APPDATA")
    if appdata:
        roots.append(Path(appdata) / "Claude" / "local-agent-mode-sessions")
    return [root for root in roots if root.is_dir()]

def cowork_session_model():
    if os.environ.get("AGENTKEEPER_MODEL_DISCOVERY_DISABLED") == "1":
        return {}
    max_files = 80
    try:
        max_files = max(1, min(200, int(os.environ.get("AGENTKEEPER_MODEL_DISCOVERY_MAX_FILES", "80"))))
    except Exception:
        pass
    session_id = first_string(data, ["session_id", "sessionId"])
    candidates = []
    for root in cowork_session_roots():
        try:
            candidates.extend(root.rglob("local_*.json"))
        except Exception:
            continue
    candidates = [path for path in candidates if path.is_file()]
    candidates.sort(key=lambda path: path.stat().st_mtime if path.exists() else 0, reverse=True)
    if session_id:
        session_l = session_id.lower()
        candidates.sort(key=lambda path: 0 if session_l in str(path).lower() else 1)
    for idx, path in enumerate(candidates[:max_files]):
        confidence = "high" if session_id and session_id.lower() in str(path).lower() else "medium"
        found = read_json_file_model(path, "cowork_local_session", confidence)
        if found:
            return found
    return {}

def apply_model_metadata(found):
    if not found:
        return
    model = clean_text(found.get("model"))
    provider = clean_text(found.get("provider"), 120) or infer_provider(model)
    source = clean_text(found.get("source"), 120) or "unknown"
    confidence = clean_text(found.get("confidence"), 40) or "unknown"
    if model and not direct_model(data).get("model"):
        data["model"] = model
    if provider and not direct_model(data).get("provider"):
        data["model_provider"] = provider
    if model or provider:
        data.setdefault("agentkeeper_model_source", source)
        data.setdefault("agentkeeper_model_confidence", confidence)

existing_model = direct_model(data)
if existing_model:
    apply_model_metadata(existing_model)
else:
    apply_model_metadata(env_model() or transcript_model() or cowork_session_model())

sys.stdout.write(json.dumps(data, separators=(",", ":")))
PY
}
