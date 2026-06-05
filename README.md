# Claude Code hardening setup

A small, reusable Claude Code hardening tool that can be dropped into any
project with a single command — `claude-sec .` (see
[Installing into a project](#installing-into-a-project) below). It
does four things:

1. Ships a defensive `.claude/settings.json` that enables Claude Code's
   sandbox, blocks network access by default, and denies `WebFetch` /
   `WebSearch`.
2. Adds a `PreToolUse` hook that constrains which paths Claude Code's
   file tools (`Read`, `Write`, `Edit`, `MultiEdit`, `NotebookEdit`) are
   allowed to touch, via two simple text policy files.
3. Enables the official `security-guidance@claude-plugins-official`
   plugin so Claude Code automatically reviews code changes for
   security issues as they are made.
4. Provides a `hardener-init` skill that runs once on first checkout
   to verify the sandbox, scan the repo for sensitive files, walk the
   user through every optional layer, and seal the policy. Run it as
   your **first action** in a fresh project — see
   [First-time setup](#first-time-setup) below.

The hook implementation, the policy file format, and the manual test
recipes are documented in
[`.claude/hardening/README.md`](_claude/hardening/README.md). This file
documents the project layout and every parameter used in
[`.claude/settings.json`](_claude/settings.json).

## Layout

This repository ships the hardening setup as a **template** under
`_claude/`. The underscore prefix is intentional — it stops Claude
Code from auto-applying the template to this repository itself
during tool maintenance. End users install it as `.claude/` in
their own project via [`./claude-sec .`](#installing-into-a-project).

```text
README.md                                  # this file: settings docs and project overview
CLAUDE.md                                  # instructions for Claude Code itself
claude-sec                                 # installer: see "Installing into a project"
_claude/                                   # shipped template — copied to .claude/ at install
  settings.unix.json                       # macOS + Linux variant of settings.json
  settings.windows.json                    # Windows variant of settings.json
  skills/
    hardener-init/
      SKILL.md                             # first-time setup wizard (run me first)
  hardening/
    README.md                              # hook behavior + path policy docs
    allow-paths.txt                        # external read-only paths
    deny-workspace-paths.txt               # workspace paths Claude Code must NOT touch
    check-file-access.py                   # PreToolUse hook implementation (Python)
    check-file-access.sh                   # thin Python wrapper for macOS/Linux
    check-file-access.ps1                  # standalone PowerShell port for Windows
    check-session-start.sh                 # SessionStart nudge for macOS/Linux
    check-session-start.ps1                # SessionStart nudge for Windows
```


## Installing into a project

The repository ships a small installer at the root, `claude-sec`.

Installation steps:
```bash
git clone <this-repo> ~/.claude-sec     # put the repo wherever you like
cd ~/.claude-sec
./claude-sec self-install                  # one-time: symlink into PATH
cd ~/some-project
claude-sec .                               # drop the template into ./.claude
# then open Claude Code and run the hardener-init skill
```

To upgrade later:

```bash
claude-sec update                          # git pull inside the cloned repo
cd ~/some-project && claude-sec .          # re-install the template
```

| Subcommand | What it does |
| --- | --- |
| `claude-sec .` | Adds the hardened Claude Code config (`settings.json`, hardening skill and hooks) to your workspace. |
| `claude-sec update` | Updates your local `claude-sec`. |
| `claude-sec self-install` | Symlink this script into `$CLAUDE_SEC_BIN_DIR/claude-sec` so it works from any directory. **Does not clone or move the repo** — you keep the cloned repo wherever you put it; the symlink resolves back through to it. |

Defaults (overridable via env vars):

- `CLAUDE_SEC_BIN_DIR` — `~/.local/bin`.
- `CLAUDE_SEC_OS` — auto-detected via `uname -s` and `$OS`. Set
  explicitly to one of `unix` | `windows` if you want to force a
  template.

## First-time setup

The very first time Claude Code runs in a project that has this
hardening setup, run the `hardener-init` skill before anything else.
Claude Code will ask for it.

What the wizard does, in order:

1. **Verify the sandbox.** Confirms Claude Code can actually run
   sandboxed on this host. If it can't, the skill walks you through
   a fix (e.g. installing `bwrap` on Linux,
   `xcode-select --install` on macOS) before continuing.
2. **Identify sensitive files.** Three sub-steps, each user-
   confirmed:
   - **2.A** scans the workspace for credential-shaped files
     (`.env`, `secrets/`, `*.pem`, cloud-creds JSON, etc.) and
     proposes a merged list for
     `.claude/hardening/deny-workspace-paths.txt` (covers Claude's
     file tools).
   - **2.B** offers to add the same workspace paths to
     `sandbox.filesystem.denyRead` and `denyWrite` in
     `.claude/settings.json` (covers Bash and any other sandboxed
     subprocess). You can pick both, one, or skip.
   - **2.C** proposes a list of sensitive paths **outside** the
     workspace (`~/.ssh/`, `~/.aws/credentials`, `~/.gnupg/`,
     `~/.netrc`, registry tokens, …) and adds the confirmed
     entries to `sandbox.filesystem.denyRead` only. External
     paths aren't normal write targets, so `denyWrite` isn't
     suggested by default.
3. **Identify read-only allowances.** For each deny entry from step 2
   (and any external paths you need), asks whether a narrow subpath
   should remain readable, and merges your answers into
   `.claude/hardening/allow-paths.txt` (read-only — entries here
   never grant write access).
4. **Interactive configuration.** Walks you through each optional
   layer and applies your answer to `.claude/settings.json`
   immediately:
   - The `security-guidance@claude-plugins-official` plugin. If you
     keep it, the wizard also drafts a starter
     `claude-security-guidance.md` (project-root file with a threat
     model and review checklist that the plugin loads as additional
     context) and asks you to edit / confirm it.
   - Final review of `allow-paths.txt` and `deny-workspace-paths.txt`.
   - The Bash `prompt`-type PreToolUse hook
     (`hooks.PreToolUse[2]`).
   - The MCP `prompt`-type PreToolUse hook
     (`hooks.PreToolUse[1]`).

   Any layer you decline is removed from `.claude/settings.json`.

5. **Seal the policy.** Creates `.claude/hardening/.initialized`
   with a one-line provenance record (date + which features ended
   up active). From that point on, the bootstrap window is closed
   and edits to the policy files require deleting `.initialized`
   manually from outside Claude Code.

The skill is intentionally one-shot. To re-run it, delete
`.claude/hardening/.initialized` first.

## Settings reference

This section documents every parameter used in `.claude/settings.json`.

### `sandbox.enabled`

- **Value:** `true`
- **Controls:** Enables Claude Code's built-in sandbox for `Bash` and
  subprocess execution.
- **Why:** Default-on sandboxing is the foundation of this hardening
  setup. Combined with `sandbox.allowUnsandboxedCommands: false` and
  `sandbox.failIfUnavailable: true`, it forces all shell-level work
  through the sandbox or stops the session.

### `sandbox.failIfUnavailable`

- **Value:** `true`
- **Controls:** Whether Claude Code should refuse to run when the
  sandbox is requested but unavailable on the host (e.g. unsupported
  OS, missing kernel features).
- **Why:** Default fail-closed. If the sandbox cannot start, the
  hardening setup loses its foundation; aborting is safer than
  silently degrading to unsandboxed execution.

### `sandbox.autoAllowBashIfSandboxed`

- **Value:** `false`
- **Controls:** Whether `Bash` calls auto-allow themselves when they
  run inside the sandbox.
- **Why:** Default off. The sandbox restricts what a Bash call can do,
  but it does not decide whether the call itself is desirable.
  Requiring an explicit per-call permission prompt keeps a human in
  the loop for every shell action.

### `sandbox.excludedCommands`

- **Value:** `[]`
- **Controls:** Commands that should bypass the sandbox even when it
  is enabled.
- **Why:** Empty by default. Adding commands here weakens the security
  posture; do so only with a clear reason.

### `sandbox.allowUnsandboxedCommands`

- **Value:** `false`
- **Controls:** Whether Claude Code is allowed to run commands outside
  the sandbox.
- **Why:** Prevents falling back to unsandboxed execution. Without
  this, `sandbox.enabled: true` can be effectively bypassed.

### `sandbox.enableWeakerNestedSandbox`

- **Value:** `false`
- **Controls:** Allows a weaker fallback sandbox when running inside
  an already-sandboxed environment (e.g. a container or nested VM).
- **Why:** Default off. Opting into a weaker sandbox is precisely what
  we are trying to prevent; the outer environment may already be
  weaker than expected.

### `sandbox.enableWeakerNetworkIsolation`

- **Value:** `false`
- **Controls:** Permits a weaker network-isolation mode on hosts where
  the full mode is unavailable.
- **Why:** Default off. Combined with `failIfUnavailable: true`, the
  hook either gets the strong network isolation it expects or refuses
  to run.

### `sandbox.filesystem.allowRead` / `sandbox.filesystem.denyRead`

- **Default values:** `["."]` / `[]`
- **Controls:** Read scope visible to sandboxed processes (Bash and
  any other subprocess launched through the sandbox). `allowRead`
  is the read allowlist; `denyRead` carves holes out of it. Empty
  `denyRead` ships in the template; the `hardener-init` wizard
  populates it in sub-steps 2.B (workspace paths) and 2.C
  (external sensitive paths).
- **Why:** Pinning `allowRead` to the workspace (`.`) keeps the
  sandbox from accidentally reading host secrets. The wizard then
  extends `denyRead` with paths the project itself ships
  (workspace secrets) and host-level paths the user does not want
  the sandbox to touch (`~/.ssh/`, `~/.aws/credentials`, etc.).
  This is the **sandbox-layer** equivalent of the file-access
  hook's `deny-workspace-paths.txt`; they protect different
  channels and are both needed.

### `sandbox.filesystem.allowWrite` / `sandbox.filesystem.denyWrite`

- **Default values:** `["."]` / `[]`
- **Controls:** Write scope visible to sandboxed processes.
  `allowWrite` is the write allowlist; `denyWrite` carves holes
  out of it. Empty `denyWrite` ships in the template; the
  `hardener-init` wizard populates it in sub-step 2.B (workspace
  paths, optionally) and leaves 2.C entries out by default.
- **Why:** Same rationale as the read-side keys, but for writes.
  External sensitive paths are deliberately not added to
  `denyWrite` by default because that would block legitimate
  shell operations (e.g. `ssh-keygen` writing to `~/.ssh/`).


### `sandbox.network.allowedDomains`

- **Value:** `[]`
- **Controls:** Allowlist of network destinations the sandbox may
  reach.
- **Why:** Empty by default. Combined with `deniedDomains: ["*"]`,
  this denies all outbound network access from sandboxed commands.
  Add specific entries here if a project genuinely needs them.

### `sandbox.network.deniedDomains`

- **Value:** `["*"]`
- **Controls:** Denylist of network destinations. `"*"` denies all.
- **Why:** Default deny everything; opt back in narrowly through
  `allowedDomains`.

### `sandbox.network.allowUnixSockets`

- **Value:** `[]`
- **Controls:** Allowlist of Unix domain sockets reachable from the
  sandbox.
- **Why:** Deny by default. Add only the sockets a project needs
  (e.g. a local Docker socket).

### `sandbox.network.allowAllUnixSockets`

- **Value:** `false`
- **Controls:** Whether to expose every Unix domain socket to
  sandboxed processes.
- **Why:** Default off. Prefer the narrow allowlist in
  `allowUnixSockets`.

### `sandbox.network.allowLocalBinding`

- **Value:** `false`
- **Controls:** Whether sandboxed processes may bind local ports.
- **Why:** Default deny. Prevents the agent from silently spinning up
  listening services.

### `sandbox.network.allowMachLookup`

- **Value:** `[]`
- **Controls:** macOS-specific Mach service names the sandbox may
  look up.
- **Why:** Empty by default. Only relevant on macOS; add names only
  if a tool needs to talk to a specific system service. Ships in
  `settings.unix.json` because the merged Unix template covers both
  macOS and Linux; ignored on Linux.

### `disableBypassPermissionsMode`

- **Value:** `"disable"`
- **Controls:** Disables Claude Code's "bypass permissions" mode (the
  one normally reached via `--dangerously-skip-permissions` or the
  in-app permission switcher), so it cannot be selected for this
  project.
- **Why:** Bypass mode skips the entire `permissions` block — including
  the `WebFetch` / `WebSearch` denies and the file-access hook's
  effective enforcement. Disabling it locks in the hardening defaults
  so a user cannot turn the safety rails off with a single keystroke.
  This is a project-scoped lockout; it should be set in the project
  `.claude/settings.json` that ships with the hardening setup.

### `permissions.defaultMode`

- **Value:** `"default"`
- **Controls:** The base permission mode Claude Code starts in.
- **Why:** Explicitly avoids `bypassPermissions`. Using the default mode
  keeps the per-tool allow / ask / deny rules in force.

### `permissions.allow`

- **Value:** `[]`
- **Controls:** Tools / patterns Claude Code may use without asking.
- **Why:** Empty by default. Add narrow entries only when you have
  decided a tool is always safe in this project.

### `permissions.ask`

- **Value:** `[]`
- **Controls:** Tools / patterns Claude Code must prompt the user about.
- **Why:** Reserved for future hardening; left empty initially.

### `permissions.deny`

- **Value:** `["WebFetch", "WebSearch"]`
- **Controls:** Tools / patterns Claude Code must refuse.
- **Why:** `WebFetch` and `WebSearch` reach out to the network from the
  agent itself, bypassing the Bash sandbox. They are denied here as part
  of the defensive default.

### `enabledPlugins`

- **Value:**
  ```json
  { "security-guidance@claude-plugins-official": true }
  ```
- **Controls:** Plugins from configured Claude Code marketplaces that
  should be enabled for this project.
- **Why:** `security-guidance@claude-plugins-official` is Anthropic's
  official security-guidance plugin. With it enabled, Claude Code
  automatically reviews code changes for security issues during normal
  edits (the plugin contributes the review hooks/skills; this entry
  just turns it on). It complements the local hardening — the
  `.claude/hardening/` hook stops the agent from touching unsafe
  *paths*, while this plugin reviews the *content* of changes the
  agent makes inside the allowed scope.

### `hooks.SessionStart[0]` — first-time-setup nudge

- **Matcher:** `"startup|resume"`
- **Hook (Unix / Windows templates ship one entry each, calling
  their native-shell script):**
  ```json
  [ { "type": "command",
      "command": "bash .claude/hardening/check-session-start.sh" } ]
  ```
- **Controls:** Runs once at session start. If the workspace has
  not been initialized yet, asks Claude to greet the user with a
  short welcome and recommend running `/hardener-init`. Once
  `.claude/hardening/.initialized` exists, the hook stays silent.

### `hooks.PreToolUse[0]` — file-access hook

- **Matcher:** `"Read|Write|Edit|MultiEdit|NotebookEdit"`
- **Hook (Unix / Windows templates ship one entry each, calling
  their native-shell script):**
  ```json
  [ { "type": "command",
      "command": "bash .claude/hardening/check-file-access.sh || exit 2" } ]
  ```
- **Controls:** Intercepts every built-in file-tool call and
  decides allow or deny against the policy: the workspace deny
  list (`deny-workspace-paths.txt`), the read-only allow list
  (`allow-paths.txt`), and an implicit deny on `.claude/` once
  setup is sealed. See
  [`_claude/hardening/README.md`](_claude/hardening/README.md) for
  the full policy semantics.

### `hooks.PreToolUse[1]` — MCP review prompt

- **Matcher:** `"mcp__.*"`
- **Hook type:** `"prompt"`
- **Controls:** Before any MCP tool call, asks Claude to audit the
  tool — identify it, classify it as safe or dangerous using the
  `/security-review` skill, refuse and surface a prompt when
  dangerous, or remember an approval and proceed when safe. The
  decision is made model-side, not by an external script.
- **Audit criteria for "dangerous":** the tool can read/write/move
  files outside the workspace, reach blocked network destinations,
  execute arbitrary code or shell commands, or access secrets,
  credentials, tokens, or environment variables. Approved tools
  are remembered per session so the same audit isn't repeated.

### `hooks.PreToolUse[2]` — Bash review prompt

- **Matcher:** `"Bash"`
- **Hook type:** `"prompt"`
- **Controls:** Before every Bash command, asks Claude to inspect
  the command line for paths that the file-access policy would
  block (outside-workspace or deny-listed) — including indirect
  references like redirections, pipelines, and tools that consume
  paths as arguments (`cat`, `cp`, `rm`, `tar`, `sed -i`, etc.).
  If the command touches a sensitive path, Claude surfaces a
  permission prompt naming the path and the operation; otherwise
  it proceeds.

## Hook behavior and path policy

The path-policy semantics, the contents of `allow-paths.txt` and
`deny-workspace-paths.txt`, manual test recipes, and how to switch
between the Python / `.sh` / `.ps1` invocations live in
[`.claude/hardening/README.md`](_claude/hardening/README.md). Look
there when changing hook behavior or policy files.

## Maintenance

- When you change `.claude/settings.json`, update the **Settings
  reference** section above in the same change.
- When you change hook scripts or policy files, update
  `.claude/hardening/README.md`.
- See [`CLAUDE.md`](CLAUDE.md) for the rules Claude Code itself should
  follow when modifying any of these files.
