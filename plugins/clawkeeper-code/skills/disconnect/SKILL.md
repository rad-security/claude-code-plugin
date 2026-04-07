---
name: disconnect
description: Remove Clawkeeper hooks and API key. Run when the user wants to unlink their account, remove hooks from settings.json, or clean up before uninstalling the plugin.
---

# Clawkeeper Disconnect

You are helping the user remove Clawkeeper hooks and disconnect from their account.

## Step 1: Confirm

Display:
```
This will:
  - Remove Clawkeeper hooks from ~/.claude/settings.json
  - Delete your stored API key

Local detection via the plugin will still work.
Run /clawkeeper-code:connect to reconnect later.

Proceed? (y/n)
```

If the user declines, stop.

## Step 2: Remove hooks and key

Run:
```bash
python3 << 'PYEOF'
import json, os

settings_path = os.path.expanduser("~/.claude/settings.json")
api_key_path = os.path.expanduser("~/.clawkeeper-plugin/api_key")

removed_hooks = False
removed_key = False

# Remove hooks from settings.json
if os.path.isfile(settings_path):
    try:
        with open(settings_path) as f:
            settings = json.load(f)
        hooks = settings.get("hooks", {})
        changed = False
        for event_name in list(hooks.keys()):
            existing = hooks[event_name]
            cleaned = []
            for group in existing:
                sub_hooks = group.get("hooks", [])
                if any("clawkeeper.dev" in (h.get("url") or "") for h in sub_hooks):
                    changed = True
                    continue
                cleaned.append(group)
            if cleaned:
                hooks[event_name] = cleaned
            else:
                del hooks[event_name]
                changed = True
        if not hooks and "hooks" in settings:
            del settings["hooks"]
            changed = True
        if changed:
            with open(settings_path, "w") as f:
                json.dump(settings, f, indent=2)
                f.write("\n")
            removed_hooks = True
    except (json.JSONDecodeError, KeyError):
        pass

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
Run /clawkeeper-code:connect to reconnect.
```

**If NOTHING_TO_REMOVE**, display:
```
No Clawkeeper hooks or API key found. Already disconnected.
```

## Important Notes
- NEVER print the API key value during removal
- This only removes user-level hooks — repo-level hooks in .claude/settings.json are unaffected
- The plugin itself stays installed; only the account link is removed
