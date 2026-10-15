#!/usr/bin/env python3
"""Read-only AgentKeeper Inventory Lite scanner.

This script is intentionally small and dependency-free so Claude Code
SessionStart can collect inventory without installing the MCP gateway binary.
It never reads file contents except bounded SKILL.md previews.
"""

from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
from pathlib import Path
from typing import Any


def read_json(path: Path) -> dict[str, Any]:
    try:
        with path.open(encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def read_preview(path: Path, max_bytes: int = 500) -> str:
    try:
        with path.open("rb") as f:
            return f.read(max_bytes).decode("utf-8", errors="replace")
    except OSError:
        return ""


def sha256(path: Path) -> str:
    try:
        h = hashlib.sha256()
        with path.open("rb") as f:
            for chunk in iter(lambda: f.read(8192), b""):
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return ""


def version_key(path: Path) -> tuple[int, ...]:
    parts: list[int] = []
    for piece in path.name.replace("-", ".").split("."):
        if piece.isdigit():
            parts.append(int(piece))
        else:
            parts.append(-1)
    return tuple(parts or [-1])


def project_paths(cwd: Path | None, home: Path) -> list[Path]:
    if not cwd:
        return []
    try:
        cwd = cwd.resolve()
        home = home.resolve()
    except OSError:
        return [cwd]

    if cwd == home:
        return []

    paths = [cwd]
    current = cwd
    while current != current.parent:
        parent = current.parent
        if parent == home or parent == home.parent:
            break
        current = parent
        paths.append(current)

    # One-level child repos catch the common "workspace folder contains repos"
    # case without walking home or node_modules-sized trees.
    try:
        for child in cwd.iterdir():
            if child.name in {".git", "node_modules", "Library", "Applications"}:
                continue
            if child.is_dir() and ((child / ".mcp.json").is_file() or (child / ".claude").is_dir()):
                paths.append(child)
    except OSError:
        pass

    seen: set[str] = set()
    out: list[Path] = []
    for p in paths:
        key = str(p)
        if key not in seen:
            seen.add(key)
            out.append(p)
    return out


def collect_skills(home: Path, cwd: Path | None) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    seen: set[tuple[str, str, str]] = set()

    def add(path: Path, source: str, plugin: str | None = None) -> None:
        name = path.parent.name
        key = (name, source, "claude_code")
        if key in seen:
            return
        seen.add(key)
        entry: dict[str, Any] = {
            "name": name,
            "source": source,
            "platform": "claude_code",
            "preview": read_preview(path),
            "hash": sha256(path),
        }
        if plugin:
            entry["plugin"] = plugin
        out.append(entry)

    for path in skill_files(home / ".claude" / "skills"):
        add(Path(path), "global")

    for project in project_paths(cwd, home):
        for path in skill_files(project / ".claude" / "skills"):
            add(Path(path), "project")

    for plugin_id, install_path, scope in plugin_install_paths(home, cwd):
        for path in skill_files(install_path / "skills"):
            add(Path(path), scope, plugin_id)

    out.sort(key=lambda s: (s["platform"], s["source"], s["name"]))
    return out


def skill_files(root: Path) -> list[str]:
    files: list[str] = []
    for pattern in ("SKILL.md", "skill.md"):
        files.extend(glob.glob(str(root / "*" / pattern)))
    return sorted(set(files))


def enabled_plugin_ids(home: Path, cwd: Path | None) -> set[str]:
    ids: set[str] = set()

    def add_from_settings(path: Path) -> None:
        settings = read_json(path)
        enabled = settings.get("enabledPlugins")
        if isinstance(enabled, dict):
            for key, value in enabled.items():
                if value is not False and isinstance(key, str):
                    ids.add(key)
        elif isinstance(enabled, list):
            for key in enabled:
                if isinstance(key, str):
                    ids.add(key)

    add_from_settings(home / ".claude" / "settings.json")
    for project in project_paths(cwd, home):
        add_from_settings(project / ".claude" / "settings.json")
        add_from_settings(project / ".claude" / "settings.local.json")

    return ids


def plugin_install_paths(home: Path, cwd: Path | None) -> list[tuple[str, Path, str]]:
    found: dict[tuple[str, str], tuple[str, Path, str]] = {}

    manifest = read_json(home / ".claude" / "plugins" / "installed_plugins.json")
    plugins = manifest.get("plugins")
    if isinstance(plugins, dict):
        for plugin_id, installs in plugins.items():
            if not isinstance(plugin_id, str) or not isinstance(installs, list):
                continue
            for inst in installs:
                if not isinstance(inst, dict):
                    continue
                install_path = inst.get("installPath") or inst.get("path")
                if not isinstance(install_path, str):
                    continue
                scope = "project" if inst.get("scope") == "project" else "global"
                p = Path(install_path).expanduser()
                found[(plugin_id, str(p))] = (plugin_id, p, scope)

    for plugin_id in enabled_plugin_ids(home, cwd):
        name, marketplace = parse_plugin_id(plugin_id)
        candidates = sorted(
            (home / ".claude" / "plugins" / "cache" / marketplace / name).glob("*"),
            key=version_key,
            reverse=True,
        )
        for p in candidates:
            if (p / ".claude-plugin" / "plugin.json").is_file():
                found[(plugin_id, str(p))] = (plugin_id, p, "global")
                break

    for project in project_paths(cwd, home):
        for plugin_json in project.glob(".claude/plugins/*/*/.claude-plugin/plugin.json"):
            install_path = plugin_json.parents[1]
            plugin_id = install_path.name
            found[(plugin_id, str(install_path))] = (plugin_id, install_path, "project")

    return sorted(found.values(), key=lambda item: (item[2], item[0], str(item[1])))


def parse_plugin_id(plugin_id: str) -> tuple[str, str]:
    if "@" in plugin_id:
        name, marketplace = plugin_id.split("@", 1)
        return name, marketplace
    return plugin_id, "unknown"


def collect_plugins(home: Path, cwd: Path | None) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    seen: set[tuple[str, str]] = set()

    for plugin_id, install_path, scope in plugin_install_paths(home, cwd):
        meta = read_json(install_path / ".claude-plugin" / "plugin.json")
        name, marketplace = parse_plugin_id(plugin_id)
        plugin_name = str(meta.get("name") or name)
        full_name = plugin_id if "@" in plugin_id else f"{plugin_name}@{marketplace}"
        key = (full_name, str(install_path))
        if key in seen:
            continue
        seen.add(key)

        out.append({
            "name": plugin_name,
            "marketplace": marketplace if marketplace != "unknown" else None,
            "full_name": full_name,
            "version": str(meta.get("version") or install_path.name),
            "scope": scope,
            "platform": "claude_code",
            "source": "installed",
            "install_path": str(install_path),
            "description": meta.get("description") if isinstance(meta.get("description"), str) else None,
            "mcp_server_names": plugin_mcp_server_names(install_path, meta),
            "skill_names": plugin_skill_names(install_path),
        })

    return out


def plugin_skill_names(install_path: Path) -> list[str]:
    names = [Path(p).parent.name for p in skill_files(install_path / "skills")]
    return sorted(set(names))


def plugin_mcp_server_names(install_path: Path, meta: dict[str, Any]) -> list[str]:
    candidates: list[Path] = []
    mcp_ref = meta.get("mcpServers")
    if isinstance(mcp_ref, str):
        candidates.append((install_path / mcp_ref).resolve())
    elif isinstance(mcp_ref, dict):
        return sorted(mcp_ref.keys())
    candidates.append(install_path / ".mcp.json")

    names: set[str] = set()
    for path in candidates:
        data = read_json(path)
        servers = data.get("mcpServers")
        if isinstance(servers, dict):
            names.update(str(k) for k in servers.keys())
    return sorted(names)


def collect_mcp(home: Path, cwd: Path | None) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    seen: set[tuple[str, str, str]] = set()

    sources: list[tuple[str, Path]] = [("global", home / ".claude" / "settings.json")]
    for project in project_paths(cwd, home):
        sources.extend([
            ("project", project / ".claude" / "settings.json"),
            ("project", project / ".claude" / "settings.local.json"),
            ("project", project / ".mcp.json"),
        ])

    for source, path in sources:
        data = read_json(path)
        servers = data.get("mcpServers")
        if not isinstance(servers, dict):
            continue
        for name, cfg in servers.items():
            if not isinstance(name, str) or not isinstance(cfg, dict):
                continue
            key = (name, source, "claude_code")
            if key in seen:
                continue
            seen.add(key)
            stype = cfg.get("type") or ("http" if cfg.get("url") else "stdio")
            command = cfg.get("command")
            if isinstance(command, str) and isinstance(cfg.get("args"), list):
                command = " ".join([command] + [str(a) for a in cfg["args"]])
            out.append({
                "name": name,
                "type": stype,
                "command": command if isinstance(command, str) else None,
                "source": source,
                "platform": "claude_code",
            })

    out.sort(key=lambda s: (s["platform"], s["source"], s["name"]))
    return out


def scan(home: Path, cwd: Path | None) -> dict[str, Any]:
    return {
        "installed_skills": collect_skills(home, cwd),
        "installed_mcp_servers": collect_mcp(home, cwd),
        "installed_plugins": collect_plugins(home, cwd),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--home", default=str(Path.home()))
    parser.add_argument("--cwd", default="")
    parser.add_argument("--format", choices=["object", "fields"], default="object")
    args = parser.parse_args()

    home = Path(args.home).expanduser()
    cwd = Path(args.cwd).expanduser() if args.cwd else None
    payload = scan(home, cwd)

    if args.format == "fields":
        print(",".join(f"{json.dumps(k)}:{json.dumps(v, separators=(',', ':'))}" for k, v in payload.items()))
    else:
        print(json.dumps(payload, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
