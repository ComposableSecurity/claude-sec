---
name: claude-sec-fill-deny-paths
description: Scans this project's workspace for credential- and secret-shaped files and populates `.claude/hardening/deny-workspace-paths.txt` with the agreed list, so Claude Code's file tools cannot touch them afterwards. Run this skill once on a fresh project, after `claude-sec .` has installed the hardening template and before any other significant work. The skill can ONLY run when `deny-workspace-paths.txt` has no active rules yet — if the file already has rules, the skill refuses and explains that the file must be cleared first. After the write, the file-access policy seals the `.claude/` directory from Claude Code's file tools. Trigger phrases include "fill deny paths", "scan for sensitive files", "populate the workspace deny list", "run the deny-paths skill", or any first-turn question on a fresh project about which files should be hidden from Claude.
---

# claude-sec — fill `deny-workspace-paths.txt`

This skill identifies credential- and secret-shaped files in this
project and writes them to `.claude/hardening/deny-workspace-paths.txt`
so Claude Code's file tools cannot read or modify them.

It is **one-shot**. The file-access hook only lets you write to
`deny-workspace-paths.txt` while that file has **no active rules**.
The first rule you write closes the window, and from that point on
the entire `.claude/` directory is sealed from Claude Code's file
tools.

## Step 0 — Precondition check

Read `.claude/hardening/deny-workspace-paths.txt` and count how
many active lines it has (a line is "active" if it is non-blank
and does not start with `#`).

- If **at least one active rule exists**, **stop immediately**.
  Tell the user, verbatim:

  > "I can't run because `.claude/hardening/deny-workspace-paths.txt`
  > already has at least one active rule. The file-access hook
  > only allows me to write to that file while it has no rules.
  > To re-run this skill, clear (or delete) every active rule
  > from `.claude/hardening/deny-workspace-paths.txt` yourself
  > (from outside Claude Code or from a Bash shell), then start
  > a new session and ask me again."

  Do not proceed past this point.

- If the file has only blank lines and `#` comments, continue.

## Step 1 — Identify candidate sensitive files

Walk the workspace and collect candidate paths. Useful signals:

- **Environment / dotenv:** `.env`, `.env.*`, `.envrc`
- **Conventional secret directories:** `secrets/`, `private/`,
  `credentials/`, `keys/`, `certs/private/`
- **SSH / PGP / TLS keys:** `id_rsa`, `id_ed25519`, `*.pem`,
  `*.key`, `*.p12`, `*.pfx`, `*.gpg`, `*.asc`
- **Cloud credentials:** `.aws/credentials`, `.aws/config`,
  `.gcp/`, `.azure/`, `service-account*.json`, `gha-creds-*.json`
- **DB dumps / backups:** `*.sqlite`, `*.db`, `dump.sql`, `*.bak`
- **Auth / session files:** `.netrc`, `cookies.txt`, `*.session`
- **Anything in `.gitignore` that looks credential-shaped** —
  cross-check with:
  ```
  git ls-files --others --ignored --exclude-standard
  ```

Tailor the search to what the project actually contains; don't
propose entries for paths that aren't there.

## Step 2 — Confirm with the user

Present the candidate list to the user. Ask which entries to
keep, remove, or add. Be explicit about which entries are
directories (`secrets/` — blocks the whole subtree) vs files
(`.env` — blocks only that one file).

Note for the user: the entire `.claude/` directory is already
implicitly protected by the file-access hook, so listing it here
is optional. Mention this; don't push it.

## Step 3 — Write the file (one-shot)

Write the confirmed list to
`.claude/hardening/deny-workspace-paths.txt` in a **single edit**
using the `Edit` or `Write` tool. The file-access hook's
one-shot exception allows this single write while the file has
no active rules.

Rules:
- One path per line.
- Use directory entries (`secrets/`) for whole subtrees and file
  entries (`.env`) for individual files.
- Preserve the existing header comments at the top of the file
  (the usage notes). Append the rules below them.
- Forward slashes only; no leading slash.

As soon as this write completes:
- The file-access hook locks `deny-workspace-paths.txt` (you
  cannot edit it again from this session).
- The implicit `.claude/` deny was already active for every
  other `.claude/` file and stays that way.

## Step 4 — Tell the user about `claude-sec update-paths`

After the write, the workspace deny list covers Claude Code's
own file tools. To also block Bash and any other sandboxed
subprocess from reaching those same paths via the sandbox's
filesystem layer, the user runs a follow-up command from a
terminal at this project's root:

```
claude-sec update-paths
```

Tell the user, verbatim:

> "`.claude/hardening/deny-workspace-paths.txt` is filled and the
> file is now locked. To extend the same protection to Bash and
> other sandboxed subprocesses — and to optionally add
> external-to-the-workspace sensitive paths like `~/.ssh/`,
> `~/.aws/credentials`, etc. — RUN THIS FROM A TERMINAL in this
> project's root:
>
>     claude-sec update-paths
>
> That command will mirror the workspace paths you just chose
> into `sandbox.filesystem.denyRead` and
> `sandbox.filesystem.denyWrite` in `.claude/settings.json` and
> let you add external paths to `denyRead`."

## ⚠ Step 5 — Heads up: allowing specific paths is manual

`.claude/hardening/allow-paths.txt` cannot be edited from inside
Claude Code. It lives in `.claude/`, and the file-access hook's
one-shot exception covers `deny-workspace-paths.txt` only — every
other `.claude/` file is unwritable from Claude's file tools.

So the **last** thing you do — after the message in Step 4 and
before stopping — is surface a clearly-marked warning to the user
about this. Display this verbatim, in its own block, so it reads
as a callout:

> ⚠ **Heads up — allowing specific paths for me is manual.**
>
> If you want me to be able to **read** specific paths later
> that would otherwise be blocked — for example:
>
> - external (outside-workspace) paths I should be able to
>   read, like `~/.cache/<tool>` or `/tmp/project-inputs`;
> - a workspace subpath you want readable even though a parent
>   rule in `deny-workspace-paths.txt` blocks it
>   (e.g. allow `secrets/public/` while `secrets/` is denied);
>
> … you must add those paths to
> `.claude/hardening/allow-paths.txt` **yourself**, by opening
> the file in a regular editor outside of Claude Code. I can't
> write to it from inside this session — only you can.
>
> (`allow-paths.txt` grants **read-only** access; write tools
> never consult it, so adding a path here does not let me
> modify it.)

After you've shown that warning, **stop**. Do not start any
unrelated work in this turn.

## Guardrails

- Never write to `.claude/hardening/deny-workspace-paths.txt`
  more than once per session. The one-shot window closes on the
  first successful write.
- Never modify any other file under `.claude/`. The
  `Edit`/`Write` tools are blocked there anyway, but do not even
  try `Bash` workarounds from this skill. Feature toggles live
  in `claude-sec configure`; sandbox-filesystem entries live in
  `claude-sec update-paths`.
- Never add paths the user did not explicitly approve.
  Suggestions are fine; silent additions are not.
- Path-list lines use forward slashes, no leading slash, and
  preserve the file's header comments.
- If the project genuinely has no sensitive files, propose a
  minimal default (e.g. `.env`, `.env.*`, `secrets/`) and ask
  the user to confirm it — do not skip Step 3 just because the
  scan came up empty. Writing at least one rule is what closes
  the window and seals `.claude/`.
