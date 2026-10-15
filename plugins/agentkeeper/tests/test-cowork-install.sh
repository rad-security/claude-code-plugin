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
TMP_HOME_LINUX=""
FAKE_BIN="$(mktemp -d)"
NO_PLUTIL_BIN=""
PYTHON_MARKER="$TMP_HOME/python-invoked"
trap 'rm -rf "$TMP_HOME" "$TMP_HOME_CREATE" "$TMP_HOME_LINUX" "$FAKE_BIN" "$NO_PLUTIL_BIN"' EXIT

cat > "$FAKE_BIN/python3" <<EOF_FAKE
#!/usr/bin/env bash
printf 'fake python invoked: %s\n' "\$*" >> "$PYTHON_MARKER"
printf '%s\n' "You have not agreed to the Xcode license agreements." >&2
exit 69
EOF_FAKE
chmod +x "$FAKE_BIN/python3"

SESSIONS="$TMP_HOME/Library/Application Support/Claude/local-agent-mode-sessions"
FLAT="$SESSIONS/account-flat/cowork_plugins"
NESTED="$SESSIONS/account-nested/workspace-a/cowork_plugins"
mkdir -p "$FLAT" "$NESTED"

cat > "$FLAT/known_marketplaces.json" <<'EOF_JSON'
{
  "other_marketplace": {
    "source": { "source": "local", "path": "/tmp/other-marketplace" },
    "installLocation": "/tmp/other-marketplace"
  }
}
EOF_JSON
cat > "$(dirname "$FLAT")/cowork_settings.json" <<'EOF_JSON'
{
  "enabledPlugins": {
    "other-plugin@other_marketplace": true
  },
  "extraKnownMarketplaces": {
    "other_marketplace": {
      "source": { "source": "local", "path": "/tmp/other-marketplace" }
    }
  }
}
EOF_JSON
cat > "$FLAT/installed_plugins.json" <<'EOF_JSON'
{
  "version": 2,
  "plugins": {
    "other-plugin@other_marketplace": [
      { "scope": "user", "installPath": "/tmp/other-plugin", "version": "1.0.0" }
    ]
  }
}
EOF_JSON
printf '{malformed\n' > "$NESTED/installed_plugins.json"

PATH="$FAKE_BIN:$PATH" HOME="$TMP_HOME" AGENTKEEPER_API_URL="https://sandbox.agentkeeper.dev" "$INSTALLER" >/tmp/agentkeeper-cowork-install.out
[ ! -f "$PYTHON_MARKER" ] || fail "installer invoked python despite fake broken python in PATH"

[ -x "$TMP_HOME/.agentkeeper/scripts/pre-tool-hook.sh" ] || fail "pre-tool hook was not deployed"
[ -x "$TMP_HOME/.agentkeeper/scripts/local-detect.sh" ] || fail "local detector was not deployed"
[ -f "$TMP_HOME/.agentkeeper/scripts/lib/key-resolver.sh" ] || fail "libraries were not deployed"
[ -f "$TMP_HOME/.agentkeeper/scripts/lib/cowork-json.sh" ] || fail "Cowork JSON helper was not deployed"
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

for cw in "$FLAT" "$NESTED"; do
  plutil -extract agentkeeper raw "$cw/known_marketplaces.json" >/dev/null || fail "agentkeeper marketplace missing for $cw"
  plutil -extract 'plugins.cowork-guardrail@agentkeeper.0.installPath' raw "$cw/installed_plugins.json" >/dev/null || fail "agentkeeper installed plugin missing for $cw"
  plutil -extract 'enabledPlugins.cowork-guardrail@agentkeeper' raw "$(dirname "$cw")/cowork_settings.json" | grep -q true || fail "agentkeeper enabled flag missing for $cw"
  plutil -extract 'extraKnownMarketplaces.agentkeeper' raw "$(dirname "$cw")/cowork_settings.json" >/dev/null || fail "agentkeeper extra marketplace missing for $cw"
done
plutil -extract other_marketplace raw "$FLAT/known_marketplaces.json" >/dev/null || fail "unrelated marketplace was not preserved"
plutil -extract 'plugins.other-plugin@other_marketplace.0.installPath' raw "$FLAT/installed_plugins.json" >/dev/null || fail "unrelated plugin was not preserved"
plutil -extract 'enabledPlugins.other-plugin@other_marketplace' raw "$(dirname "$FLAT")/cowork_settings.json" | grep -q true || fail "unrelated enabled plugin was not preserved"
ls "$NESTED"/installed_plugins.json.malformed.* >/dev/null 2>&1 || fail "malformed registry was not backed up"
pass "Cowork registry and enablement JSON merged idempotently"

PATH="$FAKE_BIN:$PATH" HOME="$TMP_HOME" AGENTKEEPER_API_URL="https://sandbox.agentkeeper.dev" "$INSTALLER" >/tmp/agentkeeper-cowork-rerun.out
[ ! -f "$PYTHON_MARKER" ] || fail "rerun invoked python despite fake broken python in PATH"
plutil -extract other_marketplace raw "$FLAT/known_marketplaces.json" >/dev/null || fail "rerun removed unrelated marketplace"
plutil -extract 'plugins.other-plugin@other_marketplace.0.installPath' raw "$FLAT/installed_plugins.json" >/dev/null || fail "rerun removed unrelated plugin"
pass "rerun is transparent for existing workstations"

PATH="$FAKE_BIN:$PATH" HOME="$TMP_HOME" "$STATUS" >/tmp/agentkeeper-cowork-status.out
[ ! -f "$PYTHON_MARKER" ] || fail "status invoked python despite fake broken python in PATH"
grep -q "marketplace hook installed" /tmp/agentkeeper-cowork-status.out || fail "status did not find installed marketplace hook"
grep -q "Cowork plugin enabled" /tmp/agentkeeper-cowork-status.out || fail "status did not report enabled Cowork plugin"
pass "status detects installed hook"

PATH="$FAKE_BIN:$PATH" HOME="$TMP_HOME" "$UNINSTALL" >/tmp/agentkeeper-cowork-uninstall.out
[ ! -f "$PYTHON_MARKER" ] || fail "uninstall invoked python despite fake broken python in PATH"
[ ! -d "$FLAT/marketplaces/agentkeeper" ] || fail "flat marketplace was not removed"
[ ! -d "$NESTED/cache/agentkeeper" ] || fail "nested cache was not removed"
for cw in "$FLAT" "$NESTED"; do
  if plutil -extract 'enabledPlugins.cowork-guardrail@agentkeeper' raw "$(dirname "$cw")/cowork_settings.json" >/dev/null 2>&1; then
    fail "enabled plugin entry was not removed for $cw"
  fi
  if plutil -extract 'extraKnownMarketplaces.agentkeeper' raw "$(dirname "$cw")/cowork_settings.json" >/dev/null 2>&1; then
    fail "extra marketplace entry was not removed for $cw"
  fi
done
plutil -extract other_marketplace raw "$FLAT/known_marketplaces.json" >/dev/null || fail "uninstall removed unrelated marketplace"
plutil -extract 'plugins.other-plugin@other_marketplace.0.installPath' raw "$FLAT/installed_plugins.json" >/dev/null || fail "uninstall removed unrelated plugin"
pass "uninstall removes Cowork hook entries"

TMP_HOME_CREATE="$(mktemp -d)"
CREATE_SESSIONS="$TMP_HOME_CREATE/Library/Application Support/Claude/local-agent-mode-sessions"
mkdir -p "$CREATE_SESSIONS/account-create/workspace-b"
PATH="$FAKE_BIN:$PATH" HOME="$TMP_HOME_CREATE" "$INSTALLER" >/tmp/agentkeeper-cowork-create.out
[ ! -f "$PYTHON_MARKER" ] || fail "create path invoked python despite fake broken python in PATH"
[ -d "$CREATE_SESSIONS/account-create/workspace-b/cowork_plugins" ] || fail "installer did not create missing cowork_plugins"
pass "installer creates missing cowork_plugins directory"

TMP_HOME_LINUX="$(mktemp -d)"
LINUX_SESSIONS="$TMP_HOME_LINUX/.config/Claude/local-agent-mode-sessions"
mkdir -p "$LINUX_SESSIONS/account-linux/workspace-c/cowork_plugins"
LINUX_EXISTING="$LINUX_SESSIONS/account-linux-existing/workspace-d/cowork_plugins"
mkdir -p "$LINUX_EXISTING"
cat > "$LINUX_EXISTING/known_marketplaces.json" <<'EOF_JSON'
{
  "other_marketplace": {
    "source": { "source": "local", "path": "/tmp/other-marketplace" }
  }
}
EOF_JSON
cat > "$(dirname "$LINUX_EXISTING")/cowork_settings.json" <<'EOF_JSON'
{
  "enabledPlugins": {
    "other-plugin@other_marketplace": true
  }
}
EOF_JSON
cat > "$LINUX_EXISTING/installed_plugins.json" <<'EOF_JSON'
{
  "version": 2,
  "plugins": {
    "other-plugin@other_marketplace": [
      { "scope": "user", "installPath": "/tmp/other-plugin", "version": "1.0.0" }
    ]
  }
}
EOF_JSON
NO_PLUTIL_BIN="$(mktemp -d)"
for cmd in bash cat chmod cp date dirname find grep head mkdir pwd rm sort uname; do
  if [ "$cmd" = "uname" ]; then
    cat > "$NO_PLUTIL_BIN/uname" <<'EOF_UNAME'
#!/bin/sh
printf 'Linux\n'
EOF_UNAME
    chmod +x "$NO_PLUTIL_BIN/uname"
  else
    ln -s "$(command -v "$cmd")" "$NO_PLUTIL_BIN/$cmd"
  fi
done

PATH="$NO_PLUTIL_BIN" HOME="$TMP_HOME_LINUX" "$INSTALLER" >/tmp/agentkeeper-cowork-linux.out
LINUX_CW="$LINUX_SESSIONS/account-linux/workspace-c/cowork_plugins"
plutil -extract 'plugins.cowork-guardrail@agentkeeper.0.installPath' raw "$LINUX_CW/installed_plugins.json" >/dev/null || fail "Linux best-effort installed plugin registry missing"
plutil -extract 'enabledPlugins.cowork-guardrail@agentkeeper' raw "$(dirname "$LINUX_CW")/cowork_settings.json" | grep -q true || fail "Linux best-effort enabled flag missing"
plutil -extract other_marketplace raw "$LINUX_EXISTING/known_marketplaces.json" >/dev/null || fail "Linux fallback clobbered existing marketplace registry"
plutil -extract 'plugins.other-plugin@other_marketplace.0.installPath' raw "$LINUX_EXISTING/installed_plugins.json" >/dev/null || fail "Linux fallback clobbered existing plugin registry"
plutil -extract 'enabledPlugins.other-plugin@other_marketplace' raw "$(dirname "$LINUX_EXISTING")/cowork_settings.json" | grep -q true || fail "Linux fallback clobbered existing enabled plugin"
grep -q "best-effort Linux registry writes" /tmp/agentkeeper-cowork-linux.out || fail "Linux fallback did not report best-effort registry writes"
pass "Linux best-effort install works without plutil in PATH and preserves existing registries"

echo
echo "Cowork installer tests passed."
