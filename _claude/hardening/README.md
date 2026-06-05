# Claude Code file-access hardening hook

This directory contains a small, standard-library-only Python hook that
restricts which paths Claude Code's file tools (`Read`, `Write`, `Edit`,
`MultiEdit`, `NotebookEdit`) are allowed to touch in this project.

`.claude/settings.json` also registers two separate `"type":
"prompt"` PreToolUse hooks — one for `mcp__.*` (MCP tool review via
the `@hardener-audit-mcp` skill) and one for `Bash` (review whether
the shell command touches paths the file-access policy would
block). Those entries are documented in the root [`README.md`
settings reference](../../README.md#hookspretoolse1--mcp-review-prompt);
they are evaluated by Claude itself, not by these scripts.

It complements Claude Code's built-in sandboxing:

- **Sandboxing** restricts Bash and subprocess behavior (including
  filesystem and network reachability for `Bash` calls).
- **These hooks** protect the Claude Code file tools (`Read`, `Write`,
  `Edit`, `MultiEdit`, `NotebookEdit`), which run inside the agent
  itself and are not governed by the Bash sandbox.

Settings (sandbox, permissions, hook wiring) live in
[`../settings.json`](../settings.json) and are documented in the root
[`README.md`](../../README.md). This file documents only the hook
implementation and the path-policy behavior.

## Files

| File | Purpose |
| --- | --- |
| `check-file-access.py` | Reference hook implementation (Python). Reads PreToolUse JSON from stdin and decides allow / deny. |
| `check-file-access.sh` | Thin Bash wrapper for macOS / Linux. Probes for Python on `PATH` (`python3`, `python`) and **fails closed** if none is found. |
| `check-file-access.ps1` | **Standalone PowerShell port** of the policy for Windows. No Python dependency. Must stay in decision lockstep with `check-file-access.py`. |
| `check-session-start.sh` | SessionStart hook for macOS / Linux. Pure bash; if `.initialized` is absent, emits a `hookSpecificOutput.additionalContext` JSON object instructing Claude to display a welcome banner to the user and recommend `/hardener-init`. Plain stdout from a SessionStart hook is captured as model context, not printed to the user, so the JSON-with-instruction pattern is what makes the banner actually visible. Bails silently when running on Windows so the `.ps1` sibling handles it. |
| `check-session-start.ps1` | SessionStart hook for Windows. Pure PowerShell; same behaviour, mirrored. Bails silently on non-Windows so the `.sh` sibling handles it. |
| `allow-paths.txt` | Paths that should be allowed for **Read only** even when the default policy would deny them. Use for external paths (caches, scratch dirs) and for re-allowing reads of workspace subpaths that `deny-workspace-paths.txt` would otherwise block. Write-shaped tools never consult this list. |
| `deny-workspace-paths.txt` | Paths inside the workspace that Claude Code may not access. For reads, an entry in `allow-paths.txt` can override this; writes remain denied. |
| `.initialized` *(absent by default)* | Marker file. While absent, the hook opens a [bootstrap window](#bootstrap-window) that lets the policy files be edited even if the hardening dir is in the deny list. Once present, the window closes and normal policy applies. |

## Policy order

For every Read / Write / Edit / MultiEdit / NotebookEdit call the
script evaluates the target path (`tool_input.file_path`, or
`tool_input.notebook_path` for `NotebookEdit`) in this exact order:

0. **Bootstrap window:** if `.claude/hardening/.initialized` does
   **not** exist and the target is **anywhere inside `.claude/`**,
   **allow**. See [Bootstrap window](#bootstrap-window) below.
1. **Allow** if the tool is `Read` **and** the target matches an
   entry in `allow-paths.txt`.
2. **Deny** if the target is outside the workspace root
   (the `cwd` field of the PreToolUse event).
3. **Deny** if the target is **anywhere inside `.claude/`** (implicit
   protection of the hardening config; active only after
   `.initialized` exists).
4. **Deny** if the target matches an entry in `deny-workspace-paths.txt`.
5. Otherwise **allow**.

In short: allow specified paths first **for reads only**, then deny
everything else outside the workspace, then deny selected paths inside
the workspace.

`allow-paths.txt` grants **read-only** access. The write-shaped tools
(`Write`, `Edit`, `MultiEdit`, `NotebookEdit`) skip step 1 entirely,
so:

- An external path listed in `allow-paths.txt` can be read but **not
  written, edited, or modified**.
- A workspace path listed in both `allow-paths.txt` and
  `deny-workspace-paths.txt` (e.g. `secrets/public/`) can be read,
  but writes still hit the workspace-deny rule.

This is intentional: external paths are typically read-only inputs
(caches, configs), and re-opening a denied subdirectory for reads
is a much smaller concession than re-opening it for writes.

## Bootstrap window

The hardening setup ships with an implicit deny on the entire
`.claude/` directory — once first-time setup is complete, neither
Claude Code nor the agent itself can read or write any hardening
file. To avoid the chicken-and-egg problem of locking yourself out
before you've configured anything, the hook gives you a one-shot
bootstrap window:

- **While `.claude/hardening/.initialized` does not exist**, the
  hook unconditionally allows access to **anything inside
  `.claude/`** — policy lists, `settings.json`, the scripts
  themselves, the `hardener-init` skill, etc.
- This bypass applies to all guarded tools (Read, Write, Edit,
  MultiEdit, NotebookEdit) and overrides every other rule in the
  policy order.
- **Once `.initialized` exists**, the bootstrap step is skipped
  and the implicit deny at step 3 kicks in: every `.claude/` path
  is denied. A specific subpath can still be re-opened **for
  reading** by listing it in `allow-paths.txt` (the read-only
  override at step 1 runs before the implicit deny); writes
  remain denied.

The intended flow:

1. Drop the hardening setup into a project (`claude-sec .`).
2. Run the `hardener-init` skill in Claude Code. The wizard edits
   `allow-paths.txt`, `deny-workspace-paths.txt`, `settings.json`,
   etc. — all permitted because the bootstrap window is open — and
   creates `.claude/hardening/.initialized` at the end.
3. The `.initialized` marker closes the bootstrap window and
   activates the implicit `.claude/` deny.

After that point the policy seals: the agent can no longer edit
the hardening config without the user first deleting `.initialized`
manually (from outside Claude Code, since the `.claude/` deny
includes the marker file itself).

## Adding allow paths

Edit `allow-paths.txt`. One path per line, with `#` comments and blank
lines ignored. **Entries here grant `Read` access only**; they do not
grant Write / Edit / MultiEdit / NotebookEdit. Use the file for two
purposes:

1. Whitelist reads of specific paths **outside** the workspace.
2. Re-allow reads of specific paths **inside** the workspace that
   `deny-workspace-paths.txt` would otherwise block.

```text
# allow-paths.txt
~/.cache/some-tool        # external cache dir, read-only
/tmp/project-inputs       # external scratch dir, read-only
secrets/public/           # workspace path: read allowed, writes still denied
```

- Absolute paths and `~` are recommended for external paths.
- Relative paths are resolved against the workspace root, which is the
  convenient form for re-allowing reads of workspace subpaths.
- A directory entry matches the directory and every descendant.
- A file entry matches only that exact file.
- For reads, entries here take precedence over `deny-workspace-paths.txt`.
- For writes, entries here have no effect; the deny still applies.

## Adding denied workspace paths

Edit `deny-workspace-paths.txt`. Same syntax as above.

```text
# deny-workspace-paths.txt
.env
secrets/
private/
```

- Relative paths are resolved against the workspace root.
- A directory entry blocks the directory and every descendant.
- A file entry blocks only that exact file.

## Path normalization and matching

- `~` is expanded to the current user's home directory.
- `.` and `..` are resolved.
- Symlinks are resolved when possible (non-existent paths fall back to
  pure normalization).
- On **Windows**, path comparison is case-insensitive.
- On **macOS / Linux**, path comparison is case-sensitive. macOS volumes
  that are themselves case-insensitive will still treat siblings that
  differ only in case as distinct from this hook's point of view; we
  follow the POSIX default rather than probing the filesystem.
- Matching uses strict path boundaries: `/tmp/foo` does **not** match
  `/tmp/foobar`. A directory entry matches itself and any descendant
  separated by an OS path separator.

## Cross-platform hook wiring

[`../settings.json`](../settings.json) registers **both** wrappers as
PreToolUse hooks for the same matcher:

```json
"hooks": [
  { "type": "command",
    "command": "bash .claude/hardening/check-file-access.sh || exit 2" },
  { "type": "command",
    "command": "pwsh -NoProfile -File .claude/hardening/check-file-access.ps1 || exit 2" }
]
```

The `|| exit 2` tail is a fail-closed safety net: if the wrapper
crashes, the script file is missing, or the launching shell itself
is not on `PATH`, the shell falls through and exits `2`, which
Claude Code treats as a hard deny on the tool call. A broken hook
never leaves the file tools unguarded.

The configuration works on hosts that have both shells installed
(common on macOS via Homebrew's `powershell`, on Linux via the
`powershell` deb/snap, and on Windows with Git Bash + the system
PowerShell). On those hosts:

- **macOS / Linux:** `bash` runs the `.sh` wrapper, which execs the
  Python policy script.
- **Windows:** `pwsh` runs the standalone `.ps1` script — no Python
  required.
- **Hosts with both:** both entries run; both implementations agree
  on the decision (decision lockstep is enforced); Claude Code
  denies if either denies.

### Hosts that lack one of the two shells

Because of the `|| exit 2` safety net, the failing entry **denies**
rather than silently no-ops. On a macOS/Linux host without `pwsh`,
the pwsh entry would deny every guarded tool call; on a Windows host
without `bash`, the bash entry would. Pick one of:

1. Install the missing shell. PowerShell is freely available for
   macOS/Linux; Git Bash is freely available for Windows.
2. Remove the entry for the platform you don't ship to. This loses
   portability of `.claude/settings.json` across platforms but is the
   right call if a project is single-platform.
3. Soften that single entry by dropping its `|| exit 2`. This
   restores the silent no-op behavior for that one shell while
   keeping the other entry fail-closed.

Option (1) keeps the file portable and the security posture
unchanged. Prefer it.

### Handling missing Python

The `.sh` wrapper probes `PATH` for a Python interpreter (`python3`,
then `python`; the `PYTHON` environment variable overrides). If none
is found it **fails closed**: it emits a PreToolUse deny JSON and
exits 0. A host that wired up this hook but has no Python cannot
evaluate the policy via Python, so the safer default is to refuse
the call rather than silently allow it.

On Windows the `.ps1` script does not depend on Python — it is a
direct PowerShell port of `check-file-access.py`. Windows hosts
therefore have no "missing Python" failure mode for the hook.

### Keeping the two implementations in lockstep

`check-file-access.py` and `check-file-access.ps1` implement the
same policy. Whenever you change one — adding a guarded tool,
adjusting path normalization, refining a deny reason — make the
matching change in the other in the same commit, and re-run the
manual tests below against both.

To run the policy script directly without the platform wrappers
(e.g. on a host where you know Python is available and don't want
the dual-entry setup), replace the two hook entries with one:

```json
"hooks": [
  { "type": "command",
    "command": "bash .claude/hardening/check-file-access.sh" }
]
```

## Manual testing

Pipe a sample PreToolUse JSON payload into the wrapper for your
platform (`check-file-access.sh` on macOS/Linux,
`check-file-access.ps1` on Windows). Allow prints nothing and exits 0;
deny prints a JSON object on stdout and exits 0. The wrappers and the
Python script are interchangeable for testing — both honor the same
input and produce the same output.

Set `WORKSPACE` to this project's root for the examples below.

```bash
WORKSPACE="$(pwd)"
```

**1. Reading a normal workspace file is allowed (no output).**

```bash
echo '{"tool_name":"Read","tool_input":{"file_path":"'"$WORKSPACE"'/README.md"},"cwd":"'"$WORKSPACE"'"}' \
  | bash .claude/hardening/check-file-access.sh
```

**2. Reading an external file such as `/etc/passwd` is denied.**

```bash
echo '{"tool_name":"Read","tool_input":{"file_path":"/etc/passwd"},"cwd":"'"$WORKSPACE"'"}' \
  | bash .claude/hardening/check-file-access.sh
```

**3. Reading an explicitly allowed external path is allowed.**

First add the path to `allow-paths.txt` (e.g. `/tmp/project-inputs`),
then:

```bash
mkdir -p /tmp/project-inputs && : > /tmp/project-inputs/data.txt
echo '{"tool_name":"Read","tool_input":{"file_path":"/tmp/project-inputs/data.txt"},"cwd":"'"$WORKSPACE"'"}' \
  | bash .claude/hardening/check-file-access.sh
```

**4. Writing a denied workspace path such as `.env` is denied.**

First add `.env` to `deny-workspace-paths.txt`, then:

```bash
echo '{"tool_name":"Write","tool_input":{"file_path":"'"$WORKSPACE"'/.env"},"cwd":"'"$WORKSPACE"'"}' \
  | bash .claude/hardening/check-file-access.sh
```

**5. Writing an explicitly allowed external path is *denied* (allow
is read-only).**

With `/tmp/project-inputs` in `allow-paths.txt`:

```bash
echo '{"tool_name":"Write","tool_input":{"file_path":"/tmp/project-inputs/data.txt"},"cwd":"'"$WORKSPACE"'"}' \
  | bash .claude/hardening/check-file-access.sh
```

The deny reason makes the read-only nature of `allow-paths.txt`
explicit, e.g. `Write denied: target path is outside the workspace
root and allow-paths.txt grants Read access only (Write is a
write-shaped tool) ...`.

**6. Bootstrap window: editing policy files works even when the
hardening dir is denied.**

Add `.claude/hardening/` to `deny-workspace-paths.txt` and make sure
`.claude/hardening/.initialized` does not exist, then:

```bash
rm -f .claude/hardening/.initialized
echo '{"tool_name":"Write","tool_input":{"file_path":"'"$WORKSPACE"'/.claude/hardening/allow-paths.txt"},"cwd":"'"$WORKSPACE"'"}' \
  | bash .claude/hardening/check-file-access.sh        # allow (bootstrap)
```

Now create the marker and try the same call:

```bash
: > .claude/hardening/.initialized
echo '{"tool_name":"Write","tool_input":{"file_path":"'"$WORKSPACE"'/.claude/hardening/allow-paths.txt"},"cwd":"'"$WORKSPACE"'"}' \
  | bash .claude/hardening/check-file-access.sh        # deny (workspace deny)
```

## Maintenance

- Whenever hook behavior or the policy files change, update this file.
- Whenever `.claude/settings.json` changes, update the root
  [`README.md`](../../README.md) settings section.
- Keep the script standard-library-only unless dependencies are
  explicitly approved.
- Future updates must extend the tool without weakening the default
  security posture (allow-by-default inside the workspace,
  deny-by-default outside).
