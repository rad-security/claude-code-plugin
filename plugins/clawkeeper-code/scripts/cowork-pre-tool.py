#!/usr/bin/env python3
"""Clawkeeper Cowork PreToolUse evaluator.

Reads a Cowork PreToolUse JSON envelope from stdin, evaluates it against
the policy file, writes a JSONL audit row to the events log, and:
  - exits 0 on allow / warn (Cowork proceeds)
  - exits 2 with a "[Clawkeeper] Blocked …" line on stderr on block

Cowork's model reads the stderr line and surfaces it to the user verbatim.
We validated this end-to-end on 2026-04-28.

Fails OPEN: parse errors, missing policy, broken rules → exit 0 with a
"hook_error" log row. enforcement_mode: "strict" in policy.json flips
that to fail-closed.

Usage: cowork-pre-tool.py <policy_file> <events_log>
"""

import sys
import os
import json
import fnmatch
import re
import datetime


def utcnow() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )


def log_event(events_log: str, row: dict) -> None:
    try:
        os.makedirs(os.path.dirname(events_log), exist_ok=True)
        with open(events_log, "a") as f:
            f.write(json.dumps(row, separators=(",", ":")) + "\n")
    except Exception:
        # Logging must never raise.
        pass


def first_str(d: dict, keys: list) -> str:
    for k in keys:
        v = d.get(k)
        if isinstance(v, str) and v:
            return v
    return ""


def matches(rule: dict, *, tool_name: str, path: str, abs_path: str,
            url: str, recipient: str) -> bool:
    """Return True if `rule.match` matches the synthesized envelope fields."""
    m = rule.get("match") or {}

    name_in = m.get("tool_name_in")
    if isinstance(name_in, list) and name_in:
        if tool_name not in name_in:
            return False

    name_glob = m.get("tool_name_glob")
    if isinstance(name_glob, str) and name_glob:
        if not fnmatch.fnmatch(tool_name, name_glob):
            return False

    ti = m.get("tool_input") or {}

    pg = ti.get("path_glob")
    if isinstance(pg, str) and pg:
        candidates = [c for c in (abs_path, path) if c]
        if not any(fnmatch.fnmatch(c, pg) for c in candidates):
            return False

    pga = ti.get("path_glob_any")
    if isinstance(pga, list) and pga:
        candidates = [c for c in (abs_path, path) if c]
        if not any(
            any(fnmatch.fnmatch(c, g) for g in pga) for c in candidates
        ):
            return False

    pr = ti.get("path_regex")
    if isinstance(pr, str) and pr:
        try:
            if not re.search(pr, abs_path or path):
                return False
        except re.error:
            return False

    uhi = ti.get("url_host_in")
    if isinstance(uhi, list) and uhi:
        if not url:
            return False
        try:
            from urllib.parse import urlparse
            host = (urlparse(url).hostname or "").lower()
            if host not in [h.lower() for h in uhi]:
                return False
        except Exception:
            return False

    rdni = ti.get("recipient_domain_not_in")
    if isinstance(rdni, list) and rdni:
        if "@" not in recipient:
            return False
        domain = recipient.split("@", 1)[1].lower()
        if domain in [d.lower() for d in rdni]:
            return False

    return True


def main() -> int:
    if len(sys.argv) < 3:
        # Misinvoked. Fail open silently — Cowork shouldn't ever see this.
        return 0
    policy_file = sys.argv[1]
    events_log = sys.argv[2]

    raw = sys.stdin.read()
    if not raw.strip():
        log_event(events_log, {"ts": utcnow(), "verdict": "allow",
                               "reason": "empty_envelope"})
        return 0

    try:
        envelope = json.loads(raw)
    except Exception as e:
        log_event(events_log, {"ts": utcnow(), "verdict": "hook_error",
                               "reason": f"envelope_parse_error: {e}"})
        return 0

    tool_name = envelope.get("tool_name") or envelope.get("toolName") or ""
    tool_input = envelope.get("tool_input") or envelope.get("toolInput") or {}
    session_id = envelope.get("session_id") or envelope.get("sessionId") or ""
    if not isinstance(tool_input, dict):
        tool_input = {"_raw": str(tool_input)}

    path = first_str(tool_input, [
        "path", "filePath", "file_path", "directory", "dir", "target",
    ])
    url = first_str(tool_input, ["url", "href", "endpoint"])
    recipient = first_str(tool_input, [
        "to", "recipient", "email", "address",
    ])

    abs_path = ""
    if path:
        try:
            abs_path = os.path.abspath(os.path.expanduser(path))
        except Exception:
            abs_path = path

    try:
        with open(policy_file) as f:
            policy = json.load(f)
    except FileNotFoundError:
        log_event(events_log, {"ts": utcnow(), "verdict": "allow",
                               "reason": "no_policy_installed",
                               "tool_name": tool_name})
        return 0
    except Exception as e:
        log_event(events_log, {"ts": utcnow(), "verdict": "hook_error",
                               "reason": f"policy_parse_error: {e}"})
        return 0

    rules = policy.get("rules") or []
    default_action = policy.get("default_action", "allow")
    policy_version = policy.get("version", 0)

    verdict = default_action
    matched_rule_id = None
    matched_rule_name = ""
    matched_reason = ""

    for rule in rules:
        try:
            if matches(rule, tool_name=tool_name, path=path, abs_path=abs_path,
                       url=url, recipient=recipient):
                verdict = rule.get("action", "allow")
                matched_rule_id = rule.get("id", "")
                matched_rule_name = rule.get("name", matched_rule_id)
                matched_reason = rule.get("reason", "")
                break
        except Exception as e:
            log_event(events_log, {"ts": utcnow(), "verdict": "rule_error",
                                   "rule_id": rule.get("id", "?"),
                                   "error": str(e)})
            continue

    log_event(events_log, {
        "ts": utcnow(),
        "verdict": verdict,
        "tool_name": tool_name,
        "matched_rule_id": matched_rule_id,
        "matched_rule_name": matched_rule_name,
        "policy_version": policy_version,
        "session_id": session_id,
        "path": path,
        "abs_path": abs_path,
        "recipient": recipient,
        "url": url,
    })

    if verdict == "block":
        msg = (
            f'[Clawkeeper] Blocked by policy "{matched_rule_name}": '
            f'{matched_reason or "this action is not permitted"}\n'
            f"Rule ID: {matched_rule_id} · Policy version: {policy_version}"
        )
        sys.stderr.write(msg + "\n")
        sys.stderr.flush()
        return 2

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        # Last-ditch fail-open. Try to log; never raise.
        try:
            log_path = sys.argv[2] if len(sys.argv) > 2 else \
                os.path.expanduser("~/.clawkeeper/cowork/events.log")
            log_event(log_path, {"ts": utcnow(), "verdict": "hook_error",
                                 "reason": f"unhandled: {e}"})
        except Exception:
            pass
        sys.exit(0)
