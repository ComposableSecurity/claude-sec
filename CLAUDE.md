# Instructions for Claude Code

This repository contains a **Claude Code hardening setup** that is
distributed as a template. End users install it into their projects
via the `claude-sec` script at the repo root; that script copies the
contents of `_claude/` into `.claude/` at the target project. The
underscore-prefixed name keeps the template from being auto-loaded
as active config while we are working on the tool itself.

The hardening scope is:

- `claude-sec` (the installer + configurator script at the repo
  root; provides `.`, `configure`, `update`, `self-install`)
- `_claude/settings.json` (the **security floor** —
  `claude-sec .` copies it to `.claude/settings.json` at install
  time. Holds only the core floor; optional features are added by
  `claude-sec configure`.)
- `_claude/hardening/*` (template hook scripts, policy files, and
  the `features/` directory that ships optional-feature snippets)
- `_claude/hardening/features/*.json` (optional-feature snippets
  that `claude-sec configure` merges into `.claude/settings.json` —
  security-guidance plugin, Bash review prompt, MCP audit prompt)
- `_claude/hardening/features/README.md` (feature-file format +
  merge semantics)
- `_claude/skills/claude-sec-fill-deny-paths/SKILL.md` (scans
  the workspace for credential-shaped files and populates
  `deny-workspace-paths.txt`; one-shot, gated on the file being
  empty)
- `_claude/skills/claude-sec-generate-security-guidance/SKILL.md`
  (drafts `claude-security-guidance.md` at the project root; gated
  on the `security-guidance` plugin being enabled)
- `README.md` (root)
- `CLAUDE.md` (this file)
- `claude-security-guidance.md` (root **of the consumer project**,
  **only if** the `claude-sec-generate-security-guidance` skill
  creates it; it does not live in this repo)

When you edit anything under `_claude/` you are editing the
distributable template. Path references inside template files
(scripts, README, skill body) describe the **runtime** layout at the
consumer project (`.claude/...`), not the repo layout (`_claude/...`)
— do not rewrite those paths.

## Documentation invariants

Whenever you modify any of the files above, you **must** also update the
related documentation in the **same change**:

- If you change `_claude/settings.json`, update the **Settings
  reference** section of root [`README.md`](README.md) so that every
  parameter is documented (name, value, what it controls, why, status).
  Do not silently add, remove, or rename settings without updating that
  section. Mark experimental or version-dependent settings as
  `requires verification`.
- If you change anything under `_claude/hardening/`, update
  [`_claude/hardening/README.md`](_claude/hardening/README.md) to match
  the new hook behavior and policy semantics.
- If you change either skill under `_claude/skills/`, update the
  **First-time setup** section of root [`README.md`](README.md) so
  the user-facing description matches the actual skill flow.
- If you change the `claude-sec` script (subcommands, defaults,
  template-source resolution), update the **Installing into a
  project** section of root [`README.md`](README.md).
- If you change anything under `_claude/hardening/features/`,
  update the **Settings reference** entries that correspond to
  each toggle (so the user can tell what `claude-sec configure`
  adds) and `_claude/hardening/features/README.md` (which
  documents the file format and merge semantics).
- If you change `CLAUDE.md` or root `README.md`, keep them consistent
  with each other and with the actual code.

## Policy order — preserve exactly

The file-access hook (`check-file-access.py`) MUST keep this
exact decision order:

1. If the tool is `Read` **and** the target matches an entry in
   `allow-paths.txt`, **allow**. Write-shaped tools (`Write`, `Edit`,
   `MultiEdit`, `NotebookEdit`) MUST skip this step — `allow-paths.txt`
   is read-only.
2. **Deny** everything else outside the workspace
   (i.e. outside the PreToolUse event's `.cwd`).
3. **Deny** anything inside `.claude/` (implicit protection of the
   hardening config itself). **Exceptions:**
   - `deny-workspace-paths.txt` is **always readable** (so the
     agent can inspect the deny list it is subject to) and is
     **writable while it has no active rules yet** (the one-shot
     first-time-setup window that lets the
     `claude-sec-fill-deny-paths` skill populate the deny list).
     The first rule written closes the **write** exception;
     reads remain allowed.
   - `settings.json` is **always readable** (so the agent can
     inspect feature toggles, sandbox config, etc.) and is
     **never writable** from inside Claude Code. Settings are
     written by `claude-sec configure` / `claude-sec
     update-paths`, or by the user editing the file directly
     outside Claude Code.
4. **Deny** configured paths inside the workspace
   (entries in `deny-workspace-paths.txt`).
5. **Allow** the remaining workspace paths.

Do not reorder, soften, or short-circuit these steps. In particular:

- Do not extend step 1 to write-shaped tools — that would let a
  single `allow-paths.txt` entry punch a hole through the workspace-
  write boundary, which is exactly what this rule was tightened to
  prevent.
- Do not widen the step-3 exceptions beyond the two named
  files. `deny-workspace-paths.txt` and `settings.json` are the
  only entries in `.claude/` reachable from Claude Code's file
  tools. Every other `.claude/` file must remain **unreadable
  AND unwritable** at all times — the agent uses `Bash` (or
  the user edits them manually) for those.
- Do not change the gating conditions:
  - `deny-workspace-paths.txt` — reads always allowed; writes
    allowed exclusively when the file has zero active (non-blank,
    non-`#`-comment) rules. Any rule closes the write window.
    Re-opening writes requires clearing the file from outside
    Claude Code. Never restrict reads, never widen writes past
    the empty-file condition.
  - `settings.json` — reads always allowed; **never** writable.
    Do not add a write exception. Settings flow through
    `claude-sec configure` / `claude-sec update-paths` or
    out-of-session editing only.

If you add new policy layers, slot them in without weakening any
existing deny rule.

## Coding guidelines for the hook

- Keep the implementation **small and readable**.
- Use the **Python standard library only**. Do not introduce
  dependencies unless the user explicitly approves them.
- `check-file-access.sh` is a thin Bash wrapper. Its only
  responsibilities are (a) locating a Python interpreter on `PATH`
  and execing `check-file-access.py`, and (b) **failing closed**
  (emitting a deny JSON) if no interpreter is found. Do not put
  policy logic in this script.
- Handle missing or invalid input safely. Treat missing policy files as
  empty lists. Treat invalid JSON on stdin as a deny.
- Denial messages must include the tool name, the target path, the
  matched policy file, and the matched entry where applicable. They
  must not leak file contents.
- Do not print anything on allow.

## Scope of changes

- Do **not** modify files outside the hardening scope unless the user
  explicitly asks. If a task requires changes elsewhere, surface that
  and ask first.
- Treat the default security posture as a floor, not a ceiling. Future
  updates should **extend** the tool (more checks, finer-grained
  policy, additional guarded tools) without weakening any existing
  default. In particular:
  - Do not flip `sandbox.enabled` to `false`.
  - Do not flip `sandbox.allowUnsandboxedCommands` to `true`.
  - Do not remove `WebFetch` / `WebSearch` from `permissions.deny`
    unless replaced with an equally strict control.
  - Do not switch `permissions.defaultMode` to `bypassPermissions`.
  - Do not change `disableBypassPermissionsMode` away from `"disable"`.
    Bypass mode skips the entire `permissions` block and the
    file-access hook's effective enforcement; keeping it disabled is
    what makes the hardening defaults non-negotiable for this project.
  - Do not narrow the file-access PreToolUse matcher
    (`hooks.PreToolUse[0]`) so that it stops covering `Read`,
    `Write`, `Edit`, `MultiEdit`, or `NotebookEdit`.
  - The optional `prompt`-type PreToolUse entries for `mcp__.*`
    and `Bash` are added by `claude-sec configure` when the user
    opts in. They are **not** part of the security floor in
    `_claude/settings.json`, and they MUST stay defined only in
    `_claude/hardening/features/*.json`. Do not move them back
    into the floor template and do not add them to
    `.claude/settings.json` from anywhere except
    `claude-sec configure`. Skills may **read** these entries to
    see what the user enabled, but must not add, remove, or
    modify them.
  - Do not silently change either skill's step ordering, its
    precondition check, or its guardrails section. The skills are
    the user-facing contract for first-run setup; alterations
    must be paired with a docs sync in `README.md`.
  - `sandbox.filesystem.denyRead` and `sandbox.filesystem.denyWrite`
    must only be written by `claude-sec update-paths`. Its merge
    is set-style: every active rule from
    `deny-workspace-paths.txt` is added to both arrays if it
    isn't already there, and **no existing entry is ever
    removed** (so user-added external entries like `~/.ssh/` are
    preserved across re-runs). Idempotent — running twice with
    the same input must leave the file byte-identical. Skills may
    read these keys but must not write to them.
  - `claude-sec configure` is the **only** sanctioned writer of
    `enabledPlugins` entries and of the optional `prompt`-type
    PreToolUse entries (Bash, `mcp__.*`). Its merge must remain
    idempotent: dict keys merge by name, hook arrays upsert by
    `matcher`, scalar arrays merge as a set. Do not change those
    semantics or duplicates and replacements will start happening
    on re-runs.
  - Do not change the `.sh` wrapper's missing-Python behavior from
    "fail closed" to "fail open". A host without Python must not
    silently bypass the policy.
  - Do not drop the `|| exit 2` tail from the file-access hook
    command. It converts wrapper crashes, missing wrapper files,
    and a missing `bash` into a Claude Code hard-deny (exit code
    2). Without it a broken hook silently allows everything.
  - The `security-guidance@claude-plugins-official` plugin is
    optional and gated by `claude-sec configure`. If the user
    enables it, do not disable it in `enabledPlugins` from
    anywhere else.

## Quick map

| Want to change… | Edit… | Then update… |
| --- | --- | --- |
| Security floor (sandbox / permissions / required hooks) | `_claude/settings.json` | Root `README.md` settings section |
| Add or modify an optional security feature | `_claude/hardening/features/<NN>-<name>.json` (and update `_claude/hardening/features/README.md` if the format changes) | Root `README.md` settings section (so the user can tell what each toggle adds) |
| Hook decision logic | `_claude/hardening/check-file-access.py` | `_claude/hardening/README.md` |
| Allowed external paths (template default) | `_claude/hardening/allow-paths.txt` | (no docs change required) |
| Denied workspace paths (template default) | `_claude/hardening/deny-workspace-paths.txt` | (no docs change required) |
| Wrapper invocation | `.sh` wrapper or `settings.json` hook command | `_claude/hardening/README.md` |
| Deny-paths skill (Phase 2 of first-run setup) | `_claude/skills/claude-sec-fill-deny-paths/SKILL.md` | Root `README.md` **First-time setup** section |
| Security-guidance skill (drafts `claude-security-guidance.md`) | `_claude/skills/claude-sec-generate-security-guidance/SKILL.md` | Root `README.md` **First-time setup** section |
| Installer / configurator behavior (subcommands, merge semantics) | `claude-sec` (and `_claude/hardening/features/README.md` if merge rules change) | Root `README.md` **Installing into a project** section |
