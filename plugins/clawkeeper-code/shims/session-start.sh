#!/usr/bin/env bash
# Shim: finds the cached plugin and execs the real script.
P="$(ls -d "$HOME/.claude/plugins/cache/clawkeeper/clawkeeper-code"/*/scripts 2>/dev/null | tail -1)"
[ -n "$P" ] && [ -f "$P/session-start.sh" ] && exec bash "$P/session-start.sh"
echo '{}'
