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
| `check-file-access.py` | The PreToolUse hook (Python). Reads JSON from stdin and decides allow / deny. |
| `check-file-access.sh` | Thin Bash wrapper. Probes for Python on `PATH` (`python3`, `python`) and **fails closed** if none is found. |
| `check-session-start.sh` | SessionStart hook. Pure bash; runs two independent checks at session start: (a) is `deny-workspace-paths.txt` still empty? (b) is the `security-guidance` plugin enabled in `settings.json` while `claude-security-guidance.md` is missing at the project root? Whichever check fails contributes a banner block; the blocks are combined into a single `hookSpecificOutput.additionalContext` payload that instructs Claude to display the banner(s) to the user on its first turn. Silent when both checks pass. Plain stdout from a SessionStart hook is captured as model context, not printed to the user, so the JSON-with-instruction pattern is what makes the banner actually visible. |
| `features/` | Optional-feature snippets that `claude-sec configure` merges into `.claude/settings.json` (security-guidance plugin, Bash review prompt, MCP audit prompt). One snippet per `*.json` file; the `NN-` prefix controls the order they're presented to the user. The format and merge semantics are documented in [`features/README.md`](features/README.md). |
| `allow-paths.txt` | Paths that should be allowed for **Read only** even when the default policy would deny them. Use for external paths (caches, scratch dirs) and for re-allowing reads of workspace subpaths that `deny-workspace-paths.txt` would otherwise block. Write-shaped tools never consult this list. |
| `deny-workspace-paths.txt` | Paths inside the workspace that Claude Code may not access. For reads, an entry in `allow-paths.txt` can override this; writes remain denied. |

## Policy order

For every Read / Write / Edit / MultiEdit / NotebookEdit call the
script evaluates the target path (`tool_input.file_path`, or
`tool_input.notebook_path` for `NotebookEdit`) in this exact order:

1. **Allow** if the tool is `Read` **and** the target matches an
   entry in `allow-paths.txt`.
2. **Deny** if the target is outside the workspace root
   (the `cwd` field of the PreToolUse event).
3. **Deny** if the target is **anywhere inside `.claude/`**
   (implicit protection of the hardening config).
   *Exceptions:*
   - `deny-workspace-paths.txt` is **always readable** (so the
     agent can inspect the deny list it is subject to) and is
     **writable while it has no active rules yet** (the one-shot
     first-time-setup window).
   - `settings.json` is **always readable** (so the agent can
     inspect the active feature toggles and sandbox config) but
     is **never writable** from Claude Code's file tools.

   See [Editing the policy files](#editing-the-policy-files)
   below.
4. **Deny** if the target matches an entry in `deny-workspace-paths.txt`.
5. Otherwise **allow**.

In short: allow specified paths first **for reads only**, then deny
everything else outside the workspace, then deny everything inside
`.claude/` (with one narrow exception for first-time setup), then
deny configured paths inside the workspace.

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

## Editing the policy files

The implicit `.claude/` deny at step 3 protects the hardening
config from the agent — Claude's built-in file tools cannot edit
`allow-paths.txt`, the hook scripts, the skills, or anything else
under `.claude/`. There are two narrow exceptions, split by file:

**`deny-workspace-paths.txt`** — read/write asymmetric:

- **Reads are always allowed**, regardless of whether the file
  has rules. The agent needs to be able to inspect the deny list
  it is subject to (and the `claude-sec-fill-deny-paths` skill's
  precondition check depends on this).
- **Writes are only allowed while the file has no active rules**
  (only blank lines and `#` comments). This lets the
  `claude-sec-fill-deny-paths` skill populate the deny list on a
  fresh project, and locks the file to writes the moment the
  first rule is added.

**`settings.json`** — read-only from inside Claude Code:

- **Reads are always allowed**, so the agent can see which
  features are enabled, what the sandbox config looks like,
  and which optional hooks are active (the
  `claude-sec-generate-security-guidance` skill's precondition
  check depends on this).
- **Writes are never allowed.** Settings are edited through
  `claude-sec configure` / `claude-sec update-paths` (which run
  outside the hook's reach as ordinary shell commands), or by
  opening the file in a regular editor outside Claude Code.

Everything else in `.claude/` is fully sealed from Claude Code's
file tools — neither readable nor writable. That's intentional:
it keeps the agent away from the surface that governs its own
restrictions.

To re-open `deny-workspace-paths.txt` for writing later, clear the
file from outside Claude Code (remove every active rule). Don't do
this casually — once the file is empty, the agent can rewrite the
workspace deny list at will until it adds at least one rule again.

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
- Path comparison is case-sensitive (POSIX default). macOS volumes
  that are themselves case-insensitive will still treat siblings
  that differ only in case as distinct from this hook's point of
  view; we follow the POSIX default rather than probing the
  filesystem.
- Matching uses strict path boundaries: `/tmp/foo` does **not** match
  `/tmp/foobar`. A directory entry matches itself and any descendant
  separated by an OS path separator.

## Hook wiring

[`../settings.json`](../settings.json) registers one PreToolUse
hook command:

```json
"hooks": [
  { "type": "command",
    "command": "bash .claude/hardening/check-file-access.sh || exit 2" }
]
```

The `|| exit 2` tail is a fail-closed safety net: if the wrapper
crashes, the script file is missing, or `bash` itself is not on
`PATH`, the shell falls through and exits `2`, which Claude Code
treats as a hard deny on the tool call. A broken hook never leaves
the file tools unguarded.

### Handling missing Python

The `.sh` wrapper probes `PATH` for a Python interpreter
(`python3`, then `python`; the `PYTHON` environment variable
overrides). If none is found it **fails closed**: it emits a
PreToolUse deny JSON and exits 0. A host that wired up this hook
but has no Python cannot evaluate the policy via Python, so the
safer default is to refuse the call rather than silently allow it.

## Manual testing

Pipe a sample PreToolUse JSON payload into the wrapper. Allow
prints nothing and exits 0; deny prints a JSON object on stdout
and exits 0. The wrapper and the Python script are interchangeable
for testing — both honor the same input and produce the same output.

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

**6. Writing `deny-workspace-paths.txt` works while it has no
active rules, then locks down.**

With a freshly installed template (`deny-workspace-paths.txt`
contains only comments):

```bash
# First write is allowed — empty deny list.
echo '{"tool_name":"Write","tool_input":{"file_path":"'"$WORKSPACE"'/.claude/hardening/deny-workspace-paths.txt"},"cwd":"'"$WORKSPACE"'"}' \
  | bash .claude/hardening/check-file-access.sh        # allow
```

Now add a rule and try the same call again:

```bash
echo "secrets/" >> .claude/hardening/deny-workspace-paths.txt
echo '{"tool_name":"Write","tool_input":{"file_path":"'"$WORKSPACE"'/.claude/hardening/deny-workspace-paths.txt"},"cwd":"'"$WORKSPACE"'"}' \
  | bash .claude/hardening/check-file-access.sh        # deny (.claude/ protection)
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
