# Instructions for Claude Code

This repository contains a **Claude Code hardening setup** that is
distributed as a template. End users install it into their projects
via the `claude-sec` script at the repo root; that script copies the
contents of `_claude/` into `.claude/` at the target project. The
underscore-prefixed name keeps the template from being auto-loaded
as active config while we are working on the tool itself.

The hardening scope is:

- `claude-sec` (the installer script at the repo root)
- `_claude/settings.unix.json` and `_claude/settings.windows.json`
  (per-OS settings templates — `claude-sec .` promotes one of them
  to `.claude/settings.json` at install time based on `uname` /
  `CLAUDE_SEC_OS`)
- `_claude/hardening/*` (template hook scripts and policy files)
- `_claude/skills/hardener-init/SKILL.md` (first-time setup wizard)
- `README.md` (root)
- `CLAUDE.md` (this file)
- `claude-security-guidance.md` (root **of the consumer project**,
  **only if** Phase 4a of the hardener-init wizard creates it; it
  does not live in this repo)

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
- If you change `_claude/skills/hardener-init/SKILL.md`, update the
  **First-time setup** section of root [`README.md`](README.md) so the
  user-facing description matches the actual wizard flow.
- If you change the `claude-sec` script (subcommands, defaults,
  template-source resolution), update the **Installing into a
  project** section of root [`README.md`](README.md).
- If you change `CLAUDE.md` or root `README.md`, keep them consistent
  with each other and with the actual code.

## Policy order — preserve exactly

The file-access hooks (`check-file-access.py` and the lockstep
`check-file-access.ps1` port) MUST keep this exact decision order:

0. **Bootstrap window:** if `.claude/hardening/.initialized` does
   not exist and the target is **anywhere inside `.claude/`**,
   **allow**. This intentionally bypasses every other rule so
   first-time setup can edit any hardening file. As soon as
   `.initialized` exists, the bootstrap step is skipped and step 3
   activates.
1. If the tool is `Read` **and** the target matches an entry in
   `allow-paths.txt`, **allow**. Write-shaped tools (`Write`, `Edit`,
   `MultiEdit`, `NotebookEdit`) MUST skip this step — `allow-paths.txt`
   is read-only.
2. **Deny** everything else outside the workspace
   (i.e. outside the PreToolUse event's `.cwd`).
3. **Deny** anything inside `.claude/` (implicit protection of the
   hardening config itself; active only after `.initialized` exists).
4. **Deny** configured paths inside the workspace
   (entries in `deny-workspace-paths.txt`).
5. **Allow** the remaining workspace paths.

Do not reorder, soften, or short-circuit these steps. In particular:

- Do not extend step 1 to write-shaped tools — that would let a
  single `allow-paths.txt` entry punch a hole through the workspace-
  write boundary, which is exactly what this rule was tightened to
  prevent.
- Do not narrow the bootstrap set below "anywhere inside
  `.claude/`". The `hardener-init` wizard needs to edit policy
  lists, `settings.json`, and possibly the skill itself during
  setup; restricting bootstrap to a smaller subset breaks the
  wizard. Do not widen it beyond `.claude/` either — files outside
  `.claude/` are not part of the hardening config and must follow
  the normal policy from session 1.
- Do not invert the bootstrap condition (e.g. allowing edits *after*
  `.initialized` exists). The marker file's existence MUST mean
  "policy is locked, normal rules apply."
- Do not weaken the implicit `.claude/` deny at step 3 to a
  softer rule (e.g. denying writes only, or denying just the
  policy files). The whole `.claude/` directory is the hardening
  config surface; letting the agent edit any of it would erode
  its own restrictions. `allow-paths.txt` is the only sanctioned
  way to re-open a specific subpath, and it only grants reads.

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
- `check-file-access.ps1` is a **standalone PowerShell port** of the
  policy — it does not depend on Python. It and `check-file-access.py`
  MUST stay in decision lockstep: every change to allow/deny logic,
  guarded tools, path normalization, or deny-reason wording must land
  in both files in the same change, and both must be re-tested with
  the manual scenarios in `.claude/hardening/README.md`.
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
  - Do not remove the separate `prompt`-type PreToolUse entries
    that cover `mcp__.*` and `Bash`. Those are the model-side
    reviews that catch what the `command`-type file-access hook
    cannot statically analyze (MCP tools' arbitrary capabilities,
    paths embedded in shell command strings). If you replace them
    with `command`-type hooks later, keep an equivalent or stricter
    review in place — do not just delete them. **Exception:** the
    `hardener-init` setup wizard MAY remove either of these
    prompt-type entries when the user explicitly opts out during
    Phase 4c (Bash) or Phase 4d (MCP). That is the only sanctioned
    path to remove them.
  - Do not silently change `hardener-init`'s Phase ordering, its
    list of guarded settings, or its guardrails section. The skill
    is the user-facing contract for first-run setup; alterations
    must be paired with a docs sync in `README.md`.
  - The `hardener-init` wizard is the **only** sanctioned writer
    of `sandbox.filesystem.denyRead` and `sandbox.filesystem.denyWrite`
    in `.claude/settings.json` during normal use. It must always
    merge into existing arrays (never replace them), confirm each
    sub-step with the user, and not add `denyWrite` entries for
    external paths by default (they block legitimate shell
    operations like `ssh-keygen`).
  - Do not change the `.sh` wrapper's missing-Python behavior from
    "fail closed" to "fail open". A host without Python must not
    silently bypass the policy.
  - Do not collapse `check-file-access.ps1` back into a Python wrapper.
    A standalone PowerShell port is what lets the hook work on Windows
    hosts that don't ship with Python.
  - Keep both scripts wired up as PreToolUse hooks so the same
    `.claude/settings.json` works on macOS, Linux, and Windows
    without per-host editing.
  - Do not drop the `|| exit 2` tail from either hook command. It
    converts wrapper crashes, missing wrapper files, and missing
    launching shells into a Claude Code hard-deny (exit code 2).
    Without it a broken hook silently allows everything.
  - Do not disable
    `security-guidance@claude-plugins-official` in `enabledPlugins`.
    It provides automatic security review of code changes and
    complements the path-restriction hook — the hook controls *where*
    the agent can edit, the plugin reviews *what* it edits.

## Quick map

| Want to change… | Edit… | Then update… |
| --- | --- | --- |
| Sandbox / permissions / hook wiring | `_claude/settings.unix.json` **and** `_claude/settings.windows.json` (keep them in sync where the platform makes that meaningful) | Root `README.md` settings section |
| Hook decision logic | `_claude/hardening/check-file-access.py` **and** `_claude/hardening/check-file-access.ps1` | `_claude/hardening/README.md` |
| Allowed external paths (template default) | `_claude/hardening/allow-paths.txt` | (no docs change required) |
| Denied workspace paths (template default) | `_claude/hardening/deny-workspace-paths.txt` | (no docs change required) |
| Wrapper invocation | `.sh` wrapper or `settings.json` hook command | `_claude/hardening/README.md` |
| First-run setup wizard | `_claude/skills/hardener-init/SKILL.md` | Root `README.md` **First-time setup** section |
| Installer behavior (subcommands, paths) | `claude-sec` | Root `README.md` **Installing into a project** section |
