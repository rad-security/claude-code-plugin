#!/usr/bin/env bash
# test-inventory-lite.sh — Inventory Lite scanner and SessionStart e2e checks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf "  PASS  %s\n" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf "  FAIL  %s\n" "$1"; }

TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

export HOME="${TMPDIR_ROOT}/home"
export CLAUDE_PLUGIN_DATA="${TMPDIR_ROOT}/plugin-data"
export AGENTKEEPER_API_URL="https://sandbox.agentkeeper.dev"
export AGENTKEEPER_MACHINE_ID="inventory-machine-123"
export PATH="${TMPDIR_ROOT}/bin:$PATH"

WORK_DIR="${TMPDIR_ROOT}/workspace"
CAPTURE_FILE="${TMPDIR_ROOT}/checkin-body.json"
mkdir -p "$HOME/.claude" "$CLAUDE_PLUGIN_DATA" "$WORK_DIR/child-repo" "$TMPDIR_ROOT/bin"

printf 'ak_test_inventory' > "${CLAUDE_PLUGIN_DATA}/api_key"
printf 'inventory-machine-123' > "${CLAUDE_PLUGIN_DATA}/machine_id"

cat > "$HOME/.claude/settings.json" <<'JSON'
{
  "enabledPlugins": {
    "notion@claude-plugins-official": true
  },
  "mcpServers": {
    "global-db": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-postgres"]
    }
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "http",
            "url": "https://www.agentkeeper.dev/api/v1/claude-code/evaluate"
          }
        ]
      }
    ]
  }
}
JSON

PLUGIN_CACHE="$HOME/.claude/plugins/cache/claude-plugins-official/notion/1.2.3"
mkdir -p "$PLUGIN_CACHE/.claude-plugin" "$PLUGIN_CACHE/skills/notion-pages"
cat > "$PLUGIN_CACHE/.claude-plugin/plugin.json" <<'JSON'
{
  "name": "notion",
  "version": "1.2.3",
  "description": "Notion plugin",
  "mcpServers": "./.mcp.json"
}
JSON
cat > "$PLUGIN_CACHE/.mcp.json" <<'JSON'
{
  "mcpServers": {
    "notion": {
      "command": "node",
      "args": ["server.js"]
    }
  }
}
JSON
cat > "$PLUGIN_CACHE/skills/notion-pages/SKILL.md" <<'EOF_SKILL'
# Notion Pages
Create and update pages in Notion.
EOF_SKILL

cat > "$WORK_DIR/.mcp.json" <<'JSON'
{
  "mcpServers": {
    "project-filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem"]
    }
  }
}
JSON
cat > "$WORK_DIR/child-repo/.mcp.json" <<'JSON'
{
  "mcpServers": {
    "child-github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"]
    }
  }
}
JSON

SCAN_OUTPUT=$(python3 "$PLUGIN_ROOT/scripts/lib/inventory-lite.py" --home "$HOME" --cwd "$WORK_DIR")

if printf '%s' "$SCAN_OUTPUT" | grep -q '"full_name":"notion@claude-plugins-official"'; then
  pass "scanner reports enabled Claude Code plugin"
else
  fail "scanner should report enabled plugin (got: $SCAN_OUTPUT)"
fi

if printf '%s' "$SCAN_OUTPUT" | grep -q '"name":"project-filesystem"' &&
   printf '%s' "$SCAN_OUTPUT" | grep -q '"name":"child-github"' &&
   printf '%s' "$SCAN_OUTPUT" | grep -q '"name":"global-db"'; then
  pass "scanner reports global, project, and child project MCP config"
else
  fail "scanner should report expected MCP servers (got: $SCAN_OUTPUT)"
fi

if printf '%s' "$SCAN_OUTPUT" | grep -q '"name":"notion-pages"'; then
  pass "scanner reports plugin-provided skills"
else
  fail "scanner should report plugin skill (got: $SCAN_OUTPUT)"
fi

cat > "${TMPDIR_ROOT}/bin/curl" <<EOF_CURL
#!/usr/bin/env bash
body=""
prev=""
for arg in "\$@"; do
  if [ "\$prev" = "-d" ]; then
    body="\$arg"
    if [ "\$body" = "@-" ]; then
      body=\$(cat)
    fi
    prev=""
    continue
  fi
  if [ "\$arg" = "-d" ]; then
    prev="-d"
  fi
done
printf '%s' "\$body" > "$CAPTURE_FILE"
printf '{}'
exit 0
EOF_CURL
chmod +x "${TMPDIR_ROOT}/bin/curl"

SESSION_PAYLOAD=$(printf '{"hook_event_name":"SessionStart","session_id":"inventorylite123","cwd":"%s","claude_version":"Claude Code v2.0.0"}' "$WORK_DIR")
(cd "$WORK_DIR" && printf '%s' "$SESSION_PAYLOAD" | "$PLUGIN_ROOT/scripts/session-start.sh" >/tmp/agentkeeper-inventory-lite-session.out 2>/dev/null) || true

if [ -s "$CAPTURE_FILE" ]; then
  pass "session-start posts a checkin payload"
else
  fail "session-start should post checkin payload"
fi

if grep -q '"machine_id":"inventory-machine-123"' "$CAPTURE_FILE" &&
   grep -q '"installed_plugins":' "$CAPTURE_FILE" &&
   grep -q '"installed_mcp_servers":' "$CAPTURE_FILE"; then
  pass "session-start payload includes stable machine_id and inventory arrays"
else
  fail "session-start payload missing expected identity/inventory fields: $(cat "$CAPTURE_FILE" 2>/dev/null)"
fi

echo ""
echo "Inventory Lite tests: $PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
