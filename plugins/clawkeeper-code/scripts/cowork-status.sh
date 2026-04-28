#!/usr/bin/env bash
# cowork-status.sh — Show install state and recent events for the
# Clawkeeper Cowork guardrail.

set -u

case "$(uname -s)" in
  Darwin) CLAUDE_DATA="$HOME/Library/Application Support/Claude" ;;
  Linux)  CLAUDE_DATA="${XDG_CONFIG_HOME:-$HOME/.config}/Claude" ;;
  *)      CLAUDE_DATA="" ;;
esac

DATA_DIR="${HOME}/.clawkeeper/cowork"
POLICY_FILE="${DATA_DIR}/policy.json"
EVENTS_LOG="${DATA_DIR}/events.log"
HOOK_CMD="${HOME}/.clawkeeper/scripts/cowork-pre-tool.sh"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m  %s\n' "$*"; }
miss() { printf '  \033[31m✗\033[0m  %s\n' "$*"; }
note() { printf '     %s\n' "$*"; }

bold "Clawkeeper Cowork Guardrail — status"
echo

# Hook script
if [ -x "$HOOK_CMD" ]; then ok "hook script: ${HOOK_CMD}"
else miss "hook script missing: ${HOOK_CMD}"; fi

# Policy
if [ -f "$POLICY_FILE" ]; then
  ok "policy: ${POLICY_FILE}"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$POLICY_FILE" <<'PY' || true
import json, sys
try:
    with open(sys.argv[1]) as f:
        p = json.load(f)
    print(f"     version: {p.get('version', '?')}, "
          f"rules: {len(p.get('rules', []))}, "
          f"default: {p.get('default_action', 'allow')}, "
          f"mode: {p.get('enforcement_mode', 'permissive')}")
except Exception as e:
    print(f"     (unable to parse: {e})")
PY
  fi
else
  miss "policy file missing: ${POLICY_FILE}"
fi

# Events
if [ -f "$EVENTS_LOG" ]; then
  COUNT=$(wc -l < "$EVENTS_LOG" 2>/dev/null | tr -d ' ' || echo "0")
  ok "events log (${COUNT} entries): ${EVENTS_LOG}"
else
  note "events log not yet created (no hook calls observed)"
fi

echo
bold "Per-workspace install"
echo

if [ -z "$CLAUDE_DATA" ] || [ ! -d "$CLAUDE_DATA/local-agent-mode-sessions" ]; then
  miss "No Cowork session directory found."
else
  FOUND=0
  for cw in "$CLAUDE_DATA"/local-agent-mode-sessions/*/*/cowork_plugins; do
    [ -d "$cw" ] || continue
    FOUND=$((FOUND + 1))
    workspace_dir="$(dirname "$cw")"
    workspace_id="${workspace_dir##*/}"

    HOOKS_FILE_MP="${cw}/marketplaces/clawkeeper/cowork-guardrail/hooks/hooks.json"

    if [ -f "$HOOKS_FILE_MP" ]; then
      ok "workspace ${workspace_id:0:8}: marketplace hook installed"
    else
      miss "workspace ${workspace_id:0:8}: marketplace hook missing"
    fi

    # find handles paths with spaces; -quit on first match to short-circuit.
    cache_match=$(find "${cw}/cache/clawkeeper/cowork-guardrail" \
      -maxdepth 3 -type f -name hooks.json -print -quit 2>/dev/null)
    if [ -n "$cache_match" ]; then
      ok "workspace ${workspace_id:0:8}: cache hook installed"
    else
      miss "workspace ${workspace_id:0:8}: cache hook missing"
    fi
  done
  [ "$FOUND" -eq 0 ] && miss "No Cowork workspaces found."
fi

echo
bold "Recent events (last 5)"
echo
if [ -f "$EVENTS_LOG" ] && [ -s "$EVENTS_LOG" ]; then
  if command -v python3 >/dev/null 2>&1; then
    tail -n 5 "$EVENTS_LOG" | python3 -c '
import json, sys
for line in sys.stdin:
    try:
        e = json.loads(line)
        ts = e.get("ts", "?")
        v = e.get("verdict", "?")
        tn = e.get("tool_name", "")
        rule = e.get("matched_rule_name") or e.get("matched_rule_id") or e.get("reason", "")
        path = e.get("path", "")
        line = f"  {ts}  {v:7s}  {tn:20s}  {rule}"
        if path:
            line += f"  {path}"
        print(line)
    except Exception:
        print("  " + line.rstrip())
'
  else
    tail -n 5 "$EVENTS_LOG"
  fi
else
  note "(no events yet)"
fi
echo
