---
name: recap
description: Summarize the current Claude Code session from a security perspective. Shows tool call counts, files modified, bash commands run, and threats detected. Run when the user wants to review what happened during their session.
---

# AgentKeeper Session Recap

You are producing a security-aware summary of the current Claude Code session by reading local session data.

## Step 1: Locate Session Data

Check for the session log file:
```bash
AGENTKEEPER_DIR="$HOME/.agentkeeper-plugin"
[ -n "$CLAUDE_PLUGIN_DATA" ] && AGENTKEEPER_DIR="$CLAUDE_PLUGIN_DATA"
cat "$AGENTKEEPER_DIR/sessions/current.jsonl" 2>/dev/null
```

### If the file does not exist or is empty:

Display:
```
AgentKeeper Session Recap

No session data found.

Session tracking begins after the first tool call in an AgentKeeper-enabled
session. The AgentKeeper hooks record tool calls, file changes, and threat
detections to a local session log.

If you just installed the plugin, start a new session and the recap will
be available after some tool activity.

In the meantime, try:
  /agentkeeper:audit — check your Claude Code security setup
  /agentkeeper:secrets — scan for exposed secrets in this directory
```

Stop here if no data exists.

### If the file exists:

Read the full contents. Each line is a JSON object representing a hook event. Parse the entries to extract the information below.

## Step 2: Analyze Session Data

From the JSONL entries, compute the following:

### Tool Call Counts
Count events grouped by tool name (Bash, Edit, Write, Read, Glob, Grep, WebFetch, WebSearch, etc.). Display as a simple table.

### Files Modified
Extract unique file paths from Edit and Write tool events. List them.

### Files Created
Extract file paths from Write events where the file was newly created (if distinguishable from the event data).

### Bash Commands Executed
Extract command strings from Bash tool events. Summarize them — show the first 80 characters of each, truncating long commands. Group similar commands if there are many.

### Network Requests
Extract URLs from WebFetch events. List unique domains accessed.

### Threats Detected
Look for entries where the hook response contained a threat detection (events with `verdict` of `warn` or `block`, or entries with `pattern` or `threat` fields). List each with severity and pattern name.

### Directories Accessed
Extract unique directory paths from Read, Glob, and Grep events.

## Step 3: Format the Report

```
AgentKeeper Session Recap

Session duration: [first_event_time] to [last_event_time]
Total tool calls: [count]

Tool Usage:
  Bash          [count]
  Read          [count]
  Edit          [count]
  Write         [count]
  Glob          [count]
  Grep          [count]
  WebFetch      [count]
  WebSearch     [count]

[If files were modified]:
Files Modified ([count]):
  - [file_path]
  - [file_path]
  ...

[If bash commands were run]:
Bash Commands ([count]):
  - [truncated_command]
  - [truncated_command]
  ...

[If network requests were made]:
Network Requests:
  - [domain] ([count] requests)
  ...

[If threats were detected]:
Threats Detected ([count]):
  [SEVERITY]  [pattern_name] — [brief description]
  ...

[If no threats]:
Threats Detected: None

Working Directories:
  - [directory_path]
  ...

---
[If connected mode]: This recap has been uploaded to your dashboard.
[If local mode]: Connect your free account to track sessions over time: /agentkeeper:connect
```

## Important Notes
- This runs entirely locally — no network calls
- Only display tool types that have a count > 0
- Truncate long command strings to keep the report readable
- Never print secret values that may appear in command arguments — mask them
- If the JSONL file is very large (>1000 lines), summarize rather than listing every entry
- If the file format is unexpected or unparseable, say so and suggest the session data may be from a different plugin version
