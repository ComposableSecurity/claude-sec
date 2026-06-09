#!/usr/bin/env python3
"""Claude Code file-access hardening hook.

Reads a Claude Code PreToolUse event from stdin and decides whether to
allow or deny Read / Write / Edit / MultiEdit / NotebookEdit access
based on policy files that live next to this script.

Policy order:
    1. If the tool is `Read` AND the target matches an entry in
       allow-paths.txt, allow.
    2. Deny if the target is outside the workspace root (event .cwd).
    3. Deny if the target is **anywhere inside `.claude/`**
       (implicit protection of the hardening config itself).
       *Exceptions:*
         a) `deny-workspace-paths.txt` is always **readable** (so
            the agent can inspect the deny list it is subject to)
            and is **writable** while it has no active rules yet
            (the one-shot first-time-setup window). The first rule
            written closes the write exception; reads remain.
         b) `settings.json` is always **readable** (so the agent
            can inspect the active feature toggles, sandbox
            config, etc.). It is **never writable** from Claude
            Code's file tools — use `claude-sec configure` /
            `claude-sec update-paths`, or edit the file in an
            external editor.
    4. Deny if the target matches an entry in deny-workspace-paths.txt.
    5. Otherwise allow.

Note that allow-paths.txt grants **read-only** access. Write-shaped
tools (Write / Edit / MultiEdit / NotebookEdit) never consult that
list, so paths listed there can be read but not modified. The
allow-paths read-override applies to step 3 too: a workspace path
inside `.claude/` listed in allow-paths.txt remains readable, but
writes to it are still denied.

The implicit `.claude/` deny is the system-level lock on the
hardening config. Reads of `deny-workspace-paths.txt` and
`settings.json` are always permitted; everything else in
`.claude/` is fully sealed for Claude Code's file tools. The only
write the agent ever gets to perform inside `.claude/` is the
first-time population of `deny-workspace-paths.txt` while it is
empty.

Exit 0 with no output on allow. Emit a PreToolUse deny JSON object and
exit 0 on deny (Claude Code reads the decision from stdout).

Standard library only. Python 3.9+. macOS / Linux.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import List

HARDENING_DIR = Path(__file__).resolve().parent
CLAUDE_DIR = HARDENING_DIR.parent  # the .claude/ root
ALLOW_PATHS_FILE = HARDENING_DIR / "allow-paths.txt"
DENY_PATHS_FILE = HARDENING_DIR / "deny-workspace-paths.txt"
SETTINGS_FILE = CLAUDE_DIR / "settings.json"

# Tools we guard, and the tool_input key that carries the target path.
# NotebookEdit uses `notebook_path`; the rest use `file_path`.
# Tools matched by the hook (e.g. mcp__*) but not listed here pass
# through with no path check.
FILE_TOOLS = {
    "Read": "file_path",
    "Write": "file_path",
    "Edit": "file_path",
    "MultiEdit": "file_path",
    "NotebookEdit": "notebook_path",
}

# Tools for which allow-paths.txt grants access. Only Read; the
# write-shaped tools never consult the allowlist, so allowed entries
# are effectively read-only.
ALLOW_PATHS_TOOLS = {"Read"}

# Path comparisons are case-sensitive (POSIX default). macOS HFS+/APFS
# volumes are often case-insensitive, but we follow the POSIX default
# rather than probing the filesystem.


def _norm_for_compare(path: Path) -> str:
    return os.path.normpath(str(path))


def _read_policy(path: Path) -> List[str]:
    if not path.exists():
        return []
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return []
    entries: List[str] = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        entries.append(line)
    return entries


def _resolve(entry: str, workspace: Path) -> Path:
    expanded = os.path.expanduser(entry)
    p = Path(expanded)
    if not p.is_absolute():
        p = workspace / p
    try:
        return p.resolve(strict=False)
    except OSError:
        return Path(os.path.normpath(str(p)))


def _matches(target: Path, policy: Path) -> bool:
    """Strict path-boundary match.

    Returns True iff target == policy or target is a descendant of policy.
    Prevents prefix-bypass bugs like /tmp/foo matching /tmp/foobar.
    """
    t = _norm_for_compare(target)
    p = _norm_for_compare(policy)
    if t == p:
        return True
    return t.startswith(p + os.sep)


def _deny(reason: str) -> None:
    payload = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }
    json.dump(payload, sys.stdout)
    sys.stdout.write("\n")
    sys.exit(0)


def main() -> int:
    raw = sys.stdin.read()
    if not raw.strip():
        return 0
    try:
        event = json.loads(raw)
    except json.JSONDecodeError:
        _deny("hardening hook received invalid JSON on stdin")
        return 0
    if not isinstance(event, dict):
        _deny("hardening hook expected a JSON object on stdin")
        return 0

    tool_name = event.get("tool_name") or ""
    path_key = FILE_TOOLS.get(tool_name)
    if path_key is None:
        # Unknown tool — including any mcp__* tool we don't model.
        # The matcher catches them; this script has no path to check.
        return 0

    tool_input = event.get("tool_input") or {}
    if not isinstance(tool_input, dict):
        return 0
    file_path = tool_input.get(path_key)
    if not isinstance(file_path, str) or not file_path:
        return 0

    cwd = event.get("cwd") or os.getcwd()
    workspace = _resolve(str(cwd), Path(os.getcwd()))
    target = _resolve(file_path, workspace)
    claude_dir = _resolve(str(CLAUDE_DIR), workspace)
    target_in_claude = _matches(target, claude_dir)

    allow_entries = _read_policy(ALLOW_PATHS_FILE)
    deny_entries = _read_policy(DENY_PATHS_FILE)

    # 1. Allow if target matches an explicitly allowed path AND the
    #    tool is in the read-only allowlist. Write-shaped tools never
    #    short-circuit here, so allow-paths.txt entries are read-only.
    #    This intentionally runs before the implicit .claude/ deny so
    #    users can re-open a specific .claude/ subpath for reading
    #    without giving up the write protection.
    if tool_name in ALLOW_PATHS_TOOLS:
        for entry in allow_entries:
            if _matches(target, _resolve(entry, workspace)):
                return 0

    # 2. Deny if target is outside the workspace root.
    if not _matches(target, workspace):
        if tool_name in ALLOW_PATHS_TOOLS:
            scope = f"and is not in {ALLOW_PATHS_FILE.name}"
        else:
            scope = (
                f"and {ALLOW_PATHS_FILE.name} grants Read access only "
                f"({tool_name} is a write-shaped tool)"
            )
        _deny(
            f"{tool_name} denied: target path is outside the workspace root "
            f"{scope} (target={target}, workspace={workspace}, "
            f"policy={ALLOW_PATHS_FILE.name})"
        )
        return 0

    # 3. Implicit deny on .claude/ — the hardening config itself is
    #    not editable. Two narrow read exceptions plus one narrow
    #    write exception:
    #      - deny-workspace-paths.txt is always readable and is
    #        writable while it has no active rules yet (the one-shot
    #        first-time-setup window);
    #      - settings.json is always readable, never writable.
    if target_in_claude:
        target_norm = _norm_for_compare(target)
        deny_file_norm = _norm_for_compare(
            _resolve(str(DENY_PATHS_FILE), workspace)
        )
        settings_file_norm = _norm_for_compare(
            _resolve(str(SETTINGS_FILE), workspace)
        )
        target_is_deny_file = target_norm == deny_file_norm
        target_is_settings_file = target_norm == settings_file_norm
        is_read_tool = tool_name in ALLOW_PATHS_TOOLS

        allowed_by_exception = False
        if is_read_tool and (target_is_deny_file or target_is_settings_file):
            allowed_by_exception = True
        elif target_is_deny_file and not deny_entries:
            # Write-shaped tool on deny-workspace-paths.txt while
            # the file has no active rules — one-shot setup window.
            allowed_by_exception = True

        if not allowed_by_exception:
            if target_is_deny_file:
                # Write attempt on deny-workspace-paths.txt after the
                # one-shot window has closed.
                _deny(
                    f"{tool_name} denied: target is "
                    f"{DENY_PATHS_FILE.name} but the file already has "
                    f"active rules. This file is writable only while "
                    f"it has no active rules (reads are always "
                    f"allowed). Clear the file from outside Claude "
                    f"Code to re-open the one-shot write window."
                )
            elif target_is_settings_file:
                # Write attempt on settings.json (never writable).
                _deny(
                    f"{tool_name} denied: target is "
                    f"{SETTINGS_FILE.name}. Settings.json is readable "
                    f"but never writable from inside Claude Code. Use "
                    f"`claude-sec configure` or `claude-sec "
                    f"update-paths` from a terminal, or edit the file "
                    f"directly in an external editor."
                )
            else:
                # Any other path inside .claude/.
                _deny(
                    f"{tool_name} denied: target is inside .claude/ "
                    f"(target={target}). The hardening config is "
                    f"implicitly protected. Only "
                    f"{DENY_PATHS_FILE.name} (read always, write "
                    f"while empty) and {SETTINGS_FILE.name} (read "
                    f"only) are reachable from Claude Code's file "
                    f"tools; every other .claude/ file is fully "
                    f"sealed."
                )
            return 0

    # 4. Deny if target matches a workspace deny entry.
    for entry in deny_entries:
        if _matches(target, _resolve(entry, workspace)):
            _deny(
                f"{tool_name} denied: target matches deny entry "
                f"'{entry}' (target={target}, policy={DENY_PATHS_FILE.name})"
            )
            return 0

    # 5. Allow.
    return 0


if __name__ == "__main__":
    sys.exit(main())
