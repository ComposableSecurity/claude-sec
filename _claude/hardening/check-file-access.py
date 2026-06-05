#!/usr/bin/env python3
"""Claude Code file-access hardening hook.

Reads a Claude Code PreToolUse event from stdin and decides whether to
allow or deny Read / Write / Edit / MultiEdit / NotebookEdit access
based on policy files that live next to this script.

Policy order:
    0. Bootstrap window: if `.claude/hardening/.initialized` does not
       exist and the target is **anywhere inside `.claude/`**, allow.
       This lets a fresh checkout edit any hardening file (policy
       lists, settings, scripts) and create the `.initialized`
       marker without any other rule blocking it.
    1. If the tool is `Read` AND the target matches an entry in
       allow-paths.txt, allow.
    2. Deny if the target is outside the workspace root (event .cwd).
    3. Deny if the target is **anywhere inside `.claude/`** (implicit
       protection of the hardening config itself; active only after
       `.initialized` exists).
    4. Deny if the target matches an entry in deny-workspace-paths.txt.
    5. Otherwise allow.

Note that allow-paths.txt grants **read-only** access. Write-shaped
tools (Write / Edit / MultiEdit / NotebookEdit) never consult that
list, so paths listed there can be read but not modified. The
allow-paths read-override applies to step 3 too: a workspace path
inside `.claude/` listed in allow-paths.txt remains readable after
initialization, but writes to it are still denied.

The implicit `.claude/` deny is the system-level lock on the
hardening config. To re-open the policy for editing, the user
deletes `.claude/hardening/.initialized` from outside Claude Code,
which re-activates the bootstrap window.

Exit 0 with no output on allow. Emit a PreToolUse deny JSON object and
exit 0 on deny (Claude Code reads the decision from stdout).

Standard library only. Python 3.9+. macOS / Linux / Windows.
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
INITIALIZED_FILE = HARDENING_DIR / ".initialized"

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

# Case-insensitive comparison on Windows, case-sensitive elsewhere.
# macOS HFS+/APFS volumes are often case-insensitive too, but we follow
# the POSIX default rather than probing the filesystem.
CASE_INSENSITIVE = os.name == "nt"


def _norm_for_compare(path: Path) -> str:
    s = os.path.normpath(str(path))
    return s.lower() if CASE_INSENSITIVE else s


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

    # 0. Bootstrap window: while .initialized is absent, allow access
    #    to anything inside .claude/ so the agent (or the user via the
    #    hardener-init wizard) can perform first-time setup. Once
    #    .initialized exists this branch is skipped and normal policy
    #    applies, including the implicit deny at step 3.
    if target_in_claude and not INITIALIZED_FILE.exists():
        return 0

    # 1. Allow if target matches an explicitly allowed path AND the
    #    tool is in the read-only allowlist. Write-shaped tools never
    #    short-circuit here, so allow-paths.txt entries are read-only.
    #    This intentionally runs before the implicit .claude/ deny so
    #    users can re-open a specific .claude/ subpath for reading
    #    after initialization without giving up the write protection.
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
    #    not editable after initialization. To re-open it, delete
    #    .claude/hardening/.initialized from outside Claude Code.
    if target_in_claude:
        _deny(
            f"{tool_name} denied: target is inside .claude/ "
            f"(target={target}). The hardening config is "
            f"implicitly protected after first-time setup. To edit "
            f"it again, delete {INITIALIZED_FILE} from outside "
            f"Claude Code to re-open the bootstrap window."
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

    # 4. Allow.
    return 0


if __name__ == "__main__":
    sys.exit(main())
