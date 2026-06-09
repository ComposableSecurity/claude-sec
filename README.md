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
3. Lets you opt into the official `security-guidance@claude-plugins-official`
   plugin (via `claude-sec configure`) so Claude Code automatically
   reviews code changes for security issues as they are made.
4. Ships two skills:
   - **`claude-sec-fill-deny-paths`** — scans the project for
     credential- and secret-shaped files and writes them to
     `deny-workspace-paths.txt`. One-shot; the moment it writes the
     first rule, the file-access hook seals `.claude/`.
   - **`claude-sec-generate-security-guidance`** — drafts a
     project-tailored `claude-security-guidance.md` (loaded by the
     security-guidance plugin) by reading the project's own docs and
     running a stack / industry interview when needed.

   See [First-time setup](#first-time-setup) below for the
   recommended order.

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
claude-sec                                 # installer + configurator (see "Installing into a project")
_claude/                                   # shipped template — copied to .claude/ at install
  settings.json                            # security-floor settings
  skills/
    claude-sec-fill-deny-paths/
      SKILL.md                             # scans the repo + populates deny-workspace-paths.txt (one-shot)
    claude-sec-generate-security-guidance/
      SKILL.md                             # drafts claude-security-guidance.md (plugin-gated)
  hardening/
    README.md                              # hook behavior + path policy docs
    allow-paths.txt                        # external read-only paths
    deny-workspace-paths.txt               # workspace paths Claude Code must NOT touch
    check-file-access.py                   # PreToolUse hook implementation
    check-file-access.sh                   # thin Bash wrapper
    check-session-start.sh                 # SessionStart nudge
    features/                              # optional-feature snippets used by `claude-sec configure`
      README.md                            # feature-file format + merge semantics
      10-security-guidance-plugin.json
      20-bash-review-prompt.json
      30-mcp-review-prompt.json
```


## Installing into a project

The repository ships a small installer at the root, `claude-sec`.

Installation steps:
```bash
git clone https://github.com/ComposableSecurity/claude-sec ~/.claude-sec     # put the repo wherever you like
cd ~/.claude-sec
./claude-sec self-install                  # one-time: symlink into PATH
cd ~/some-project
claude-sec .                               # drop the security floor into ./.claude and optionally configure additional layers
# then open Claude Code in this project and run:
#   /claude-sec-fill-deny-paths               (scans + populates the deny list)
#   /claude-sec-generate-security-guidance    (only if you enabled the plugin)
# after the deny list is filled, back in your terminal:
claude-sec update-paths                    # mirror the deny list into sandbox.filesystem
```

To upgrade later:

```bash
claude-sec update                          # git pull inside the cloned repo
cd ~/some-project && claude-sec .          # re-install the security floor and re-confirm optional layers (idempotent)
```

| Subcommand | What it does |
| --- | --- |
| `claude-sec .` | Drops a minimal **security floor** into `./.claude` (sandbox, permissions, file-access hook, SessionStart nudge). Optional layers are **not** included here. |
| `claude-sec configure` | Interactively walks each optional layer (security-guidance plugin, Bash review prompt, MCP audit prompt) read from `./.claude/hardening/features/` and merges the chosen ones into `./.claude/settings.json`. Idempotent — safe to re-run. Requires `python3`. |
| `claude-sec update-paths` | Mirrors every active rule from `./.claude/hardening/deny-workspace-paths.txt` into `sandbox.filesystem.denyRead` and `sandbox.filesystem.denyWrite` in `./.claude/settings.json`. Set-style merge: adds missing rules, never removes existing entries (so user-added external paths like `~/.ssh/` survive re-runs). Idempotent. Requires `python3`. |
| `claude-sec update` | `git pull --ff-only` inside the cloned repo. |
| `claude-sec self-install` | Symlinks the script into `$CLAUDE_SEC_BIN_DIR/claude-sec` so it works from any directory. **Does not clone or move the repo** — the symlink resolves back through to it. |

Defaults (overridable via env vars):

- `CLAUDE_SEC_BIN_DIR` — `~/.local/bin`.

The hardening setup targets macOS and Linux. Windows hosts are not
supported by this version.

## First-time setup

First-time setup is split between **the command line** (where
you pick which optional security layers to enable) and **two
skills in Claude Code** (where the agent does the
project-specific work that needs Claude's reasoning).

### Step 1 — `claude-sec configure`

Run this in a terminal at the project root. It walks each optional
layer and asks y/n:

- the `security-guidance@claude-plugins-official` plugin
- the Bash review prompt (`hooks.PreToolUse[Bash]`)
- the MCP audit prompt (`hooks.PreToolUse[mcp__.*]`)

Whatever you say "yes" to is merged into `.claude/settings.json`.
Anything you decline is simply left out. The merge is idempotent —
re-running with the same answers is a no-op, and re-running with
different answers upserts hook entries by `matcher` (no duplicates).

### Step 2 — `/claude-sec-fill-deny-paths` in Claude Code

Open Claude Code in the project and run the
`/claude-sec-fill-deny-paths` skill. It will:

1. Refuse with a clear message if
   `.claude/hardening/deny-workspace-paths.txt` already has any
   active rules. (Re-running requires clearing the file from
   outside Claude Code.)
2. Walk the workspace for credential- and secret-shaped files
   (`.env`, `.env.*`, `secrets/`, `*.pem`, cloud-creds JSON,
   SSH/PGP keys, DB dumps, anything in `.gitignore` that looks
   credential-shaped, …) and present a candidate list.
3. Ask you to keep / remove / add entries.
4. Write the confirmed list to
   `.claude/hardening/deny-workspace-paths.txt` in a single edit.
5. Tell you to run `claude-sec update-paths` to mirror those
   paths into `sandbox.filesystem.denyRead`/`denyWrite` and to
   add **external** sensitive paths (`~/.ssh/`,
   `~/.aws/credentials`, registry tokens, …) to `denyRead`.

The skill is **one-shot by design**: the moment it writes the
first rule, the file-access hook locks
`deny-workspace-paths.txt` (and the rest of `.claude/`) from
Claude Code's file tools. To re-run, clear every active rule from
`.claude/hardening/deny-workspace-paths.txt` from outside Claude
Code.

### Step 3 — `claude-sec update-paths`

Back in your terminal, run:

```bash
claude-sec update-paths
```

This mirrors every active rule from
`.claude/hardening/deny-workspace-paths.txt` into both
`sandbox.filesystem.denyRead` and `sandbox.filesystem.denyWrite`
in `.claude/settings.json`. The result: Bash and any other
sandboxed subprocess sees the same path restrictions that
Claude Code's file tools do.

The merge is **set-style** — it only adds rules that aren't
already present and never removes anything. That means it's
safe to re-run after editing `deny-workspace-paths.txt` (e.g.
if the file was cleared and refilled), and it's also safe to
hand-edit `sandbox.filesystem.denyRead` / `denyWrite` to add
external sensitive paths like `~/.ssh/` or `~/.aws/credentials`
— those entries survive every subsequent `update-paths` run.

### Step 4 — `/claude-sec-generate-security-guidance` (optional)

Only relevant if you enabled the `security-guidance` plugin in
Step 1. Open Claude Code and run
`/claude-sec-generate-security-guidance`. It will:

1. Refuse with a clear message if the plugin isn't enabled in
   `.claude/settings.json`, and tell you to run
   `claude-sec configure` first.
2. Read the project's own docs (README, `SECURITY.md`,
   `CONTRIBUTING.md`, `docs/`, `architecture/`, dependency
   manifests for stack identification, and optionally a docs /
   website URL you paste in).
3. Run an industry / stack interview (Web2 SaaS, Fintech, Web3 /
   DeFi, Crypto libs / wallets, AI / agentic, Infra / DevOps,
   Healthcare, Mobile, Embedded / IoT, …) when the repo doesn't
   provide enough context.
4. Draft a tailored `claude-security-guidance.md` at the
   project root: "What this project is", "Stack", "Threat
   model" (adversaries / goals / protected assets), "Trust
   boundaries", and a "Review checklist" pulled from a matching
   industry seed.
5. Show you the draft and apply your edits before saving.

The plugin loads the saved file as additional context for every
model-backed review.

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
  `denyRead` ships in the template; the future
  `claude-sec update-paths` subcommand populates it with both the
  workspace deny list (mirrored from
  `deny-workspace-paths.txt`) and external sensitive paths the
  user picks.
- **Why:** Pinning `allowRead` to the workspace (`.`) keeps the
  sandbox from accidentally reading host secrets. Extending
  `denyRead` afterwards layers in paths the project itself ships
  (workspace secrets) and host-level paths the user does not want
  the sandbox to touch (`~/.ssh/`, `~/.aws/credentials`, etc.).
  This is the **sandbox-layer** equivalent of the file-access
  hook's `deny-workspace-paths.txt`; they protect different
  channels and are both needed.

### `sandbox.filesystem.allowWrite` / `sandbox.filesystem.denyWrite`

- **Default values:** `["."]` / `[]`
- **Controls:** Write scope visible to sandboxed processes.
  `allowWrite` is the write allowlist; `denyWrite` carves holes
  out of it. Empty `denyWrite` ships in the template;
  `claude-sec update-paths` extends it with the workspace deny
  paths (mirrored from `deny-workspace-paths.txt`) and leaves
  external sensitive paths out by default.
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
  if a tool needs to talk to a specific system service. Ignored on
  Linux.

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
- **Hook:**
  ```json
  [ { "type": "command",
      "command": "bash .claude/hardening/check-session-start.sh" } ]
  ```
- **Controls:** Runs once at session start. Runs two independent
  checks and emits banner(s) for whichever fail; silent when both
  pass:
  1. **Deny-list populated?** If
     `.claude/hardening/deny-workspace-paths.txt` has no active
     rules yet, asks Claude to greet the user and recommend
     `/claude-sec-fill-deny-paths`.
  2. **Security-guidance file present (when the plugin is on)?**
     If the `security-guidance@claude-plugins-official` plugin is
     enabled in `.claude/settings.json` but
     `claude-security-guidance.md` does not exist at the project
     root, asks Claude to recommend
     `/claude-sec-generate-security-guidance`.

  Both banners are concatenated into a single
  `additionalContext` payload when both checks fire, with the
  instruction to ask about the deny-paths skill first
  (recommended) and remind the user that the
  guidance-generation skill is available afterwards.

### `hooks.PreToolUse[0]` — file-access hook

- **Matcher:** `"Read|Write|Edit|MultiEdit|NotebookEdit"`
- **Hook:**
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
- **⚠ Warning — this is AI guarding AI:** the audit is performed
  by Claude reviewing Claude's own intended action. It is
  **non-deterministic** and cannot be relied on as a 100%
  effective control. Use it as **defense-in-depth alongside**
  the deterministic file-access hook and sandbox, not as a
  substitute for them.

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
- **⚠ Warning — this is AI guarding AI:** the review is performed
  by Claude reviewing Claude's own intended action. It is
  **non-deterministic** and cannot be relied on as a 100%
  effective control. Use it as **defense-in-depth alongside**
  the deterministic file-access hook and sandbox, not as a
  substitute for them.

## Hook behavior and path policy

The path-policy semantics, the contents of `allow-paths.txt` and
`deny-workspace-paths.txt`, and the manual test recipes live in
[`.claude/hardening/README.md`](_claude/hardening/README.md). Look
there when changing hook behavior or policy files.

## Maintenance

- When you change `.claude/settings.json`, update the **Settings
  reference** section above in the same change.
- When you change hook scripts or policy files, update
  `.claude/hardening/README.md`.
- See [`CLAUDE.md`](CLAUDE.md) for the rules Claude Code itself should
  follow when modifying any of these files.
