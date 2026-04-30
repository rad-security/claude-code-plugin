#!/usr/bin/env bash
# Tests for AgentKeeper Claude Cowork hook installer.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$ROOT_DIR/scripts/cowork-install.sh"
STATUS="$ROOT_DIR/scripts/cowork-status.sh"
UNINSTALL="$ROOT_DIR/scripts/cowork-uninstall.sh"

pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

TMP_HOME="$(mktemp -d)"
TMP_HOME_CREATE=""
trap 'rm -rf "$TMP_HOME" "$TMP_HOME_CREATE"' EXIT

SESSIONS="$TMP_HOME/Library/Application Support/Claude/local-agent-mode-sessions"
FLAT="$SESSIONS/account-flat/cowork_plugins"
NESTED="$SESSIONS/account-nested/workspace-a/cowork_plugins"
mkdir -p "$FLAT" "$NESTED"

HOME="$TMP_HOME" AGENTKEEPER_API_URL="https://sandbox.agentkeeper.dev" "$INSTALLER" >/tmp/agentkeeper-cowork-install.out

[ -x "$TMP_HOME/.agentkeeper/scripts/pre-tool-hook.sh" ] || fail "pre-tool hook was not deployed"
[ -x "$TMP_HOME/.agentkeeper/scripts/local-detect.sh" ] || fail "local detector was not deployed"
[ -f "$TMP_HOME/.agentkeeper/scripts/lib/key-resolver.sh" ] || fail "libraries were not deployed"
pass "hook scripts deployed"

for cw in "$FLAT" "$NESTED"; do
  hooks="$cw/marketplaces/agentkeeper/cowork-guardrail/hooks/hooks.json"
  cache_hooks="$(find "$cw/cache/agentkeeper/cowork-guardrail" -type f -name hooks.json -print -quit)"
  [ -f "$hooks" ] || fail "marketplace hooks missing for $cw"
  [ -n "$cache_hooks" ] || fail "cache hooks missing for $cw"
  grep -q "AGENTKEEPER_API_TOOL=cowork" "$hooks" || fail "cowork source flag missing for $cw"
  grep -q "AGENTKEEPER_SKIP_CONFLICT_CHECK=1" "$hooks" || fail "conflict skip flag missing for $cw"
  grep -q "https://sandbox.agentkeeper.dev" "$hooks" || fail "api url missing for $cw"
  [ -f "$(dirname "$cw")/cowork_settings.json" ] || fail "cowork settings missing for $cw"
done
pass "flat and nested Cowork workspaces installed"

python3 - "$FLAT" "$NESTED" <<'PY_EOF'
import json
import os
import sys

for cw in sys.argv[1:]:
    with open(os.path.join(cw, "known_marketplaces.json"), encoding="utf-8") as f:
        known = json.load(f)
    with open(os.path.join(cw, "installed_plugins.json"), encoding="utf-8") as f:
        installed = json.load(f)
    assert "agentkeeper" in known, known
    assert "cowork-guardrail@agentkeeper" in installed.get("plugins", {}), installed
    with open(os.path.join(os.path.dirname(cw), "cowork_settings.json"), encoding="utf-8") as f:
        settings = json.load(f)
    assert settings.get("enabledPlugins", {}).get("cowork-guardrail@agentkeeper") is True, settings
    assert "agentkeeper" in settings.get("extraKnownMarketplaces", {}), settings
PY_EOF
pass "Cowork registry and enablement JSON merged"

HOME="$TMP_HOME" "$STATUS" >/tmp/agentkeeper-cowork-status.out
grep -q "marketplace hook installed" /tmp/agentkeeper-cowork-status.out || fail "status did not find installed marketplace hook"
grep -q "Cowork plugin enabled" /tmp/agentkeeper-cowork-status.out || fail "status did not report enabled Cowork plugin"
pass "status detects installed hook"

HOME="$TMP_HOME" "$UNINSTALL" >/tmp/agentkeeper-cowork-uninstall.out
[ ! -d "$FLAT/marketplaces/agentkeeper" ] || fail "flat marketplace was not removed"
[ ! -d "$NESTED/cache/agentkeeper" ] || fail "nested cache was not removed"
python3 - "$FLAT" "$NESTED" <<'PY_EOF'
import json
import os
import sys

for cw in sys.argv[1:]:
    settings_path = os.path.join(os.path.dirname(cw), "cowork_settings.json")
    with open(settings_path, encoding="utf-8") as f:
        settings = json.load(f)
    assert "cowork-guardrail@agentkeeper" not in settings.get("enabledPlugins", {}), settings
    assert "agentkeeper" not in settings.get("extraKnownMarketplaces", {}), settings
PY_EOF
pass "uninstall removes Cowork hook entries"

TMP_HOME_CREATE="$(mktemp -d)"
CREATE_SESSIONS="$TMP_HOME_CREATE/Library/Application Support/Claude/local-agent-mode-sessions"
mkdir -p "$CREATE_SESSIONS/account-create/workspace-b"
HOME="$TMP_HOME_CREATE" "$INSTALLER" >/tmp/agentkeeper-cowork-create.out
[ -d "$CREATE_SESSIONS/account-create/workspace-b/cowork_plugins" ] || fail "installer did not create missing cowork_plugins"
pass "installer creates missing cowork_plugins directory"

echo
echo "Cowork installer tests passed."
