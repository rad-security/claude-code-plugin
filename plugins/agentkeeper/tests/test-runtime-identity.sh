#!/usr/bin/env bash
# test-runtime-identity.sh — Local identity evidence collected by runtime-identity.sh.
# Exercises: Claude account email from ~/.claude.json, git user.email, the
# opt-out switch, and that the enriched hook payload carries the fields.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$PLUGIN_DIR/scripts/lib/runtime-identity.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

export HOME="$SANDBOX/home"
mkdir -p "$HOME"
printf '{"oauthAccount":{"accountUuid":"x","emailAddress":"dev.one@example.com","fullName":"Dev One"},"numStartups":3}\n' > "$HOME/.claude.json"

export GIT_CONFIG_GLOBAL="$SANDBOX/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
printf '[user]\n\temail = dev.one@example.com\n\tname = Dev One\n' > "$GIT_CONFIG_GLOBAL"
cd "$SANDBOX"

unset AGENTKEEPER_LOCAL_IDENTITY_EVIDENCE

fail=0
step() { printf '  • %s ... ' "$1"; }
pass() { printf 'ok\n'; }
bad() { printf 'FAIL\n    %s\n' "$1" >&2; fail=$((fail + 1)); }

echo "test-runtime-identity.sh"

step "claude account email is read from ~/.claude.json"
got="$(agentkeeper_claude_account_email)"
if [ "$got" = "dev.one@example.com" ]; then pass; else bad "got '$got'"; fi

step "git user.email is read from git config"
if command -v git >/dev/null 2>&1; then
  got="$(agentkeeper_git_user_email)"
  if [ "$got" = "dev.one@example.com" ]; then pass; else bad "got '$got'"; fi
else
  printf 'skipped (no git)\n'
fi

step "enriched payload carries claude_account_email and git_email"
if command -v python3 >/dev/null 2>&1; then
  out="$(agentkeeper_enrich_json_payload '{"tool_name":"Bash","session_id":"s1"}')"
  case "$out" in
    *'"claude_account_email":"dev.one@example.com"'*) pass ;;
    *) bad "claude_account_email missing in: $out" ;;
  esac
  step "enriched payload keeps the original fields"
  case "$out" in
    *'"tool_name":"Bash"'*) pass ;;
    *) bad "original payload lost: $out" ;;
  esac
else
  printf 'skipped (no python3)\n'
fi

step "bash fallback fields include the local evidence"
fields="$(agentkeeper_runtime_identity_fields)"
case "$fields" in
  *'"claude_account_email":"dev.one@example.com"'*) pass ;;
  *) bad "fields: $fields" ;;
esac

step "a malformed ~/.claude.json yields nothing"
printf 'not json' > "$HOME/.claude.json"
got="$(agentkeeper_claude_account_email)"
if [ -z "$got" ]; then pass; else bad "got '$got'"; fi

step "AGENTKEEPER_LOCAL_IDENTITY_EVIDENCE=0 disables collection"
printf '{"oauthAccount":{"emailAddress":"dev.one@example.com"}}\n' > "$HOME/.claude.json"
got="$(AGENTKEEPER_LOCAL_IDENTITY_EVIDENCE=0 agentkeeper_claude_account_email)"
got_git="$(AGENTKEEPER_LOCAL_IDENTITY_EVIDENCE=0 agentkeeper_git_user_email)"
if [ -z "$got" ] && [ -z "$got_git" ]; then pass; else bad "got '$got' / '$got_git'"; fi

# --- Coding agent login: personal vs company ---------------------------------
ORG_UUID="11111111-2222-4333-8444-555555555555"
WORKSPACE_ID="66666666-7777-4888-9999-aaaaaaaaaaaa"
printf '{"oauthAccount":{"emailAddress":"Dev.One@Example.com","organizationUuid":"%s","organizationType":"claude_team","organizationName":"Example Org","displayName":"Dev One"},"projects":{"/tmp":{"organizationUuid":"99999999-2222-4333-8444-555555555555"}}}\n' "$ORG_UUID" > "$HOME/.claude.json"

step "Claude Code prompt carries the org uuid, org type and email domain"
if command -v python3 >/dev/null 2>&1; then
  out="$(agentkeeper_enrich_json_payload '{"hook_event_name":"UserPromptSubmit","prompt":"hi"}')"
  missing=""
  for want in "\"claude_org_uuid\":\"$ORG_UUID\"" '"claude_org_type":"claude_team"' '"claude_account_domain":"example.com"'; do
    case "$out" in *"$want"*) ;; *) missing="$missing $want" ;; esac
  done
  if [ -z "$missing" ]; then pass; else bad "missing$missing in: $out"; fi
  step "no organization name or display name leaves the machine"
  case "$out" in
    *"Example Org"*|*"displayName"*) bad "leaked: $out" ;;
    *) pass ;;
  esac
  step "tool events do not read the login"
  out="$(agentkeeper_enrich_json_payload '{"hook_event_name":"PreToolUse","tool_name":"Bash"}')"
  case "$out" in
    *claude_org_uuid*) bad "tool event carried login fields: $out" ;;
    *) pass ;;
  esac
  step "a malformed org uuid is dropped"
  printf '{"oauthAccount":{"emailAddress":"dev.one@example.com","organizationUuid":"$(id)","organizationType":"claude_max"}}\n' > "$HOME/.claude.json"
  out="$(agentkeeper_enrich_json_payload '{"hook_event_name":"UserPromptSubmit"}')"
  case "$out" in
    *claude_org_uuid*) bad "kept a bad uuid: $out" ;;
    *'"claude_org_type":"claude_max"'*) pass ;;
    *) bad "org type missing: $out" ;;
  esac

  # A fake Codex login: header.payload.signature, junk signature.
  mkdir -p "$HOME/.codex"
  ID_TOKEN="$(python3 - "$WORKSPACE_ID" <<'TOKEN'
import base64, json, sys
def seg(obj):
    return base64.urlsafe_b64encode(json.dumps(obj).encode()).decode().rstrip("=")
claims = {"email": "Dev.One@Personal-Mail.test", "https://api.openai.com/auth": {"chatgpt_account_id": sys.argv[1].upper(), "chatgpt_plan_type": "plus", "chatgpt_user_id": "user-1"}}
print(seg({"alg": "RS256"}) + "." + seg(claims) + ".c2lnbmF0dXJl")
TOKEN
)"
  printf '{"auth_mode":"chatgpt","OPENAI_API_KEY":null,"tokens":{"id_token":"%s","access_token":"eyJhY2Nlc3M.secret.token","refresh_token":"rt-secret","account_id":"%s"}}\n' "$ID_TOKEN" "$WORKSPACE_ID" > "$HOME/.codex/auth.json"

  step "Codex prompt carries auth mode, workspace id, plan and email"
  out="$(AGENTKEEPER_IDE=codex AGENTKEEPER_API_TOOL=codex agentkeeper_enrich_json_payload '{"hook_event_name":"UserPromptSubmit","prompt":"hi"}')"
  missing=""
  for want in '"codex_auth_mode":"chatgpt"' "\"chatgpt_account_id\":\"$WORKSPACE_ID\"" '"chatgpt_plan_type":"plus"' '"codex_account_email":"dev.one@personal-mail.test"' '"codex_account_domain":"personal-mail.test"'; do
    case "$out" in *"$want"*) ;; *) missing="$missing $want" ;; esac
  done
  if [ -z "$missing" ]; then pass; else bad "missing$missing in: $out"; fi
  step "no token ever leaves the machine"
  case "$out" in
    *eyJ*|*rt-secret*|*id_token*|*access_token*|*refresh_token*|*signature*) bad "token leaked: $out" ;;
    *) pass ;;
  esac
  step "a Codex hook does not carry the Claude org fields"
  case "$out" in
    *claude_org_type*) bad "claude fields on codex: $out" ;;
    *) pass ;;
  esac

  step "tokens.account_id stands in when the id_token has no workspace"
  printf '{"auth_mode":"chatgpt","tokens":{"id_token":"not-a-jwt","account_id":"%s"}}\n' "$WORKSPACE_ID" > "$HOME/.codex/auth.json"
  out="$(AGENTKEEPER_IDE=codex AGENTKEEPER_API_TOOL=codex agentkeeper_enrich_json_payload '{"hook_event_name":"UserPromptSubmit"}')"
  case "$out" in
    *"\"chatgpt_account_id\":\"$WORKSPACE_ID\""*) pass ;;
    *) bad "fallback missing: $out" ;;
  esac

  step "an API key login sends only the auth mode"
  printf '{"auth_mode":"apikey","OPENAI_API_KEY":"sk-test-not-real"}\n' > "$HOME/.codex/auth.json"
  out="$(AGENTKEEPER_IDE=codex AGENTKEEPER_API_TOOL=codex agentkeeper_enrich_json_payload '{"hook_event_name":"UserPromptSubmit"}')"
  case "$out" in
    *sk-test*|*chatgpt_account_id*) bad "unexpected: $out" ;;
    *'"codex_auth_mode":"apikey"'*) pass ;;
    *) bad "auth mode missing: $out" ;;
  esac

  step "CODEX_HOME moves the auth file"
  mkdir -p "$SANDBOX/codex-home"
  printf '{"auth_mode":"chatgpt","tokens":{"account_id":"%s"}}\n' "$WORKSPACE_ID" > "$SANDBOX/codex-home/auth.json"
  out="$(CODEX_HOME="$SANDBOX/codex-home" AGENTKEEPER_IDE=codex agentkeeper_enrich_json_payload '{"hook_event_name":"SessionStart"}')"
  case "$out" in
    *"$WORKSPACE_ID"*) pass ;;
    *) bad "CODEX_HOME ignored: $out" ;;
  esac

  step "AGENTKEEPER_LOCAL_IDENTITY_EVIDENCE=0 sends no login fields"
  out="$(AGENTKEEPER_LOCAL_IDENTITY_EVIDENCE=0 CODEX_HOME="$SANDBOX/codex-home" AGENTKEEPER_IDE=codex agentkeeper_enrich_json_payload '{"hook_event_name":"UserPromptSubmit"}')"
  out_claude="$(AGENTKEEPER_LOCAL_IDENTITY_EVIDENCE=0 agentkeeper_enrich_json_payload '{"hook_event_name":"UserPromptSubmit"}')"
  case "$out$out_claude" in
    *codex_auth_mode*|*chatgpt_account_id*|*claude_org*|*claude_account*) bad "opt-out ignored: $out $out_claude" ;;
    *) pass ;;
  esac
else
  printf 'skipped (no python3)\n'
fi

echo ""
if [ "$fail" -eq 0 ]; then
  echo "All runtime-identity tests passed"
  exit 0
fi
echo "$fail runtime-identity test(s) failed" >&2
exit 1
