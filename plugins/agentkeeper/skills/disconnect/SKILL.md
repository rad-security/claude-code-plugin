---
name: disconnect
description: Remove AgentKeeper hooks and API key. Run when the user wants to unlink their account, remove hooks from settings.json, or clean up before uninstalling the plugin.
---

# AgentKeeper Disconnect

You are helping the user remove AgentKeeper hooks and disconnect from their account.

## Step 1: Confirm

Display:
```
This will:
  - Remove AgentKeeper hooks from ~/.claude/settings.json
  - Delete your stored API key

Local detection via the plugin will still work.
Run /agentkeeper:connect to reconnect later.

Proceed? (y/n)
```

If the user declines, stop.

## Step 2: Remove hooks and key

Run:
```bash
python3 << 'PYEOF'
import json, os, shutil, stat, time

settings_path = os.path.expanduser("~/.claude/settings.json")
api_key_path = os.path.expanduser("~/.agentkeeper-plugin/api_key")

removed_hooks = False
removed_key = False

# Remove hooks from settings.json
if os.path.isfile(settings_path):
    try:
        settings_mode = stat.S_IMODE(os.stat(settings_path).st_mode)
        with open(settings_path) as f:
            settings = json.load(f)
        if not isinstance(settings, dict):
            print("ERROR_INVALID_SETTINGS_SHAPE")
            settings = None
        hooks = settings.get("hooks", {}) if settings else {}
        if settings and hooks is None:
            hooks = {}
        if settings and not isinstance(hooks, dict):
            print("ERROR_INVALID_HOOKS_SHAPE")
            settings = None
            hooks = {}

        def is_agentkeeper_hook(hook):
            if not isinstance(hook, dict):
                return False
            url = str(hook.get("url") or "")
            command = str(hook.get("command") or "")
            return (
                "agentkeeper.dev" in url
                or "/api/v1/claude-code/" in url
                or "AGENTKEEPER_API_TOOL=claude-code" in command
                or "AGENTKEEPER_SCRIPTS_DIR=" in command
                or "/.agentkeeper/" in command
            )

        def prune_agentkeeper_hooks(group):
            if not isinstance(group, dict):
                return group
            raw_hooks = group.get("hooks", [])
            if not isinstance(raw_hooks, list):
                return group
            kept_hooks = [hook for hook in raw_hooks if not is_agentkeeper_hook(hook)]
            if len(kept_hooks) == len(raw_hooks):
                return group
            if not kept_hooks:
                return None
            clone = dict(group)
            clone["hooks"] = kept_hooks
            return clone

        changed = False
        for event_name in list(hooks.keys()) if settings else []:
            existing = hooks.get(event_name, [])
            if not isinstance(existing, list):
                print("ERROR_INVALID_HOOK_EVENT_SHAPE:" + event_name)
                settings = None
                changed = False
                break
            cleaned = []
            for group in existing:
                pruned = prune_agentkeeper_hooks(group)
                if pruned is None:
                    changed = True
                    continue
                if pruned is not group:
                    changed = True
                cleaned.append(pruned)
            if cleaned:
                hooks[event_name] = cleaned
            else:
                del hooks[event_name]
                changed = True
        if settings and not hooks and "hooks" in settings:
            del settings["hooks"]
            changed = True
        if settings and changed:
            backup_path = settings_path + ".agentkeeper-backup-" + time.strftime("%Y%m%d%H%M%S")
            shutil.copy2(settings_path, backup_path)
            tmp_path = settings_path + ".agentkeeper-tmp-" + str(os.getpid())
            try:
                with open(tmp_path, "w") as f:
                    json.dump(settings, f, indent=2)
                    f.write("\n")
                os.chmod(tmp_path, settings_mode)
                os.replace(tmp_path, settings_path)
            finally:
                try:
                    if os.path.exists(tmp_path):
                        os.remove(tmp_path)
                except OSError:
                    pass
            removed_hooks = True
    except json.JSONDecodeError:
        print("ERROR_INVALID_SETTINGS_JSON")

# Delete API key
if os.path.isfile(api_key_path):
    os.remove(api_key_path)
    removed_key = True

if removed_hooks:
    print("HOOKS_REMOVED")
if removed_key:
    print("KEY_REMOVED")
if not removed_hooks and not removed_key:
    print("NOTHING_TO_REMOVE")
PYEOF
```

## Step 3: Display result

**If HOOKS_REMOVED and/or KEY_REMOVED**, display:
```
Disconnected.

  Hooks: removed from ~/.claude/settings.json
  API key: deleted

Local detection is still active via the plugin.
Restart Claude Code for changes to take effect.
Run /agentkeeper:connect to reconnect.
```

**If NOTHING_TO_REMOVE**, display:
```
No AgentKeeper hooks or API key found. Already disconnected.
```

**If `ERROR_INVALID_SETTINGS_JSON`, `ERROR_INVALID_SETTINGS_SHAPE`, `ERROR_INVALID_HOOKS_SHAPE`, or `ERROR_INVALID_HOOK_EVENT_SHAPE` appears**, display:
```
The API key was removed if present, but AgentKeeper left ~/.claude/settings.json untouched because the existing Claude Code settings were not safe to edit. Repair the settings JSON, then run /agentkeeper:disconnect again to remove hooks.
```

## Important Notes
- NEVER print the API key value during removal
- This only removes user-level hooks — repo-level hooks in .claude/settings.json are unaffected
- The plugin itself stays installed; only the account link is removed
