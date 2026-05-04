#!/usr/bin/env bash
# Ensures AgentKeeper plugin skills never collide with Claude Code built-ins.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKILLS_DIR="${PLUGIN_DIR}/skills"

RESERVED_REGEX='^(login|logout|help|plugin|clear|compact|doctor|resume)$'
FAILED=0

while IFS= read -r skill_file; do
  name="$(awk -F: '/^name:/ { gsub(/^[ \t"'"'"'"'"'"']+|[ \t"'"'"'"'"'"']+$/, "", $2); print $2; exit }' "$skill_file")"
  if [[ "$name" =~ $RESERVED_REGEX ]]; then
    echo "Reserved Claude command name used by ${skill_file}: ${name}"
    FAILED=1
  fi
done < <(find "$SKILLS_DIR" -mindepth 2 -maxdepth 2 -name SKILL.md | sort)

if grep -RInE 'agentkeeper:login|/login is the canonical|agentkeeper:connect has been renamed' "$SKILLS_DIR"; then
  echo "Retired AgentKeeper login command copy is still present."
  FAILED=1
fi

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi

echo "Command namespace checks passed."
