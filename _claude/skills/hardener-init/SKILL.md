---
name: hardener-init
description: First-time setup wizard for the .claude/hardening/ Claude Code hardening tool. Run this skill the first time Claude Code is started in a project that has the hardening setup but no `.claude/hardening/.initialized` marker yet. It verifies sandbox availability, scans the repo for sensitive files to populate `deny-workspace-paths.txt`, lets the user re-allow specific subpaths via `allow-paths.txt`, walks through each optional security layer (security-guidance plugin, Bash LLM review, MCP LLM review) so the user can opt in or out, optionally seeds `claude-security-guidance.md` with a threat model, then seals the policy by creating `.initialized`. Also triggered by `/hardener-init`, by user phrases like "initialize hardening", "first-time hardening setup", "run the hardener setup wizard", or by any first-turn question about how to configure this project's hardening.
---

# Hardener — first-time setup

You are the first-run setup wizard for the hardening tool that lives under `.claude/hardening/`. Run the whole flow end-to-end in a single session before any other significant work. Be conversational and confirm with the user at every decision point.

While `.claude/hardening/.initialized` is absent the file-access hook lets you (and the user) edit the three bootstrap files — `allow-paths.txt`, `deny-workspace-paths.txt`, `.initialized` — even if the hardening dir is otherwise denied. Use only that bootstrap freedom; do not modify anything else outside the hardening scope during this skill.

## Preconditions

Before doing anything else:

1. Verify that `.claude/hardening/.initialized` does **not** exist. If it does, the project is already initialized — tell the user, ask whether they want to re-run setup (which requires deleting `.initialized`), and stop unless they explicitly confirm.
2. Verify the hardening setup is actually present:
   - `.claude/settings.json`
   - `.claude/hardening/check-file-access.py`
   - `.claude/hardening/check-file-access.ps1`
   - `.claude/hardening/check-file-access.sh`
   - `.claude/hardening/allow-paths.txt`
   - `.claude/hardening/deny-workspace-paths.txt`
   If any of these are missing, stop and tell the user the hardening drop-in is incomplete.

## Phase 1 — Verify the sandbox

Goal: confirm Claude Code can actually run sandboxed on this host before relying on it.

1. Identify the platform: macOS, Linux, or Windows.
2. Confirm `.claude/settings.json` has `sandbox.enabled: true` and `sandbox.failIfUnavailable: true`. If either is missing or off, restore it and continue.
3. Run a benign sandboxed test (e.g. `pwd` via Bash) and observe whether Claude Code reports sandbox unavailability or any setup error.
4. If the sandbox is not available, diagnose by platform and either fix what you can fix from inside the agent or ask the user to fix it:
   - **macOS**: check `sandbox-exec` (`which sandbox-exec`). Missing → ask the user to install Xcode Command Line Tools (`xcode-select --install`).
   - **Linux**: check `bwrap` / bubblewrap (`which bwrap`). Missing → ask the user to install (`sudo apt-get install bubblewrap`, `sudo dnf install bubblewrap`, etc., based on distro).
   - **Windows**: confirm the supported sandbox runtime per the installed Claude Code version. If unsupported, surface the error verbatim and ask the user how to proceed.
5. Do **not** silently degrade. If a fix requires user action, pause and ask them to perform it, then re-verify before continuing. If sandboxing genuinely cannot run on this host, stop the skill and tell the user.

## Phase 2 — Identify sensitive files

This phase populates **two independent layers of protection** with
sensitive paths:

- `.claude/hardening/deny-workspace-paths.txt` covers Claude's file
  tools (Read / Write / Edit / MultiEdit / NotebookEdit) via the
  PreToolUse hook.
- `sandbox.filesystem.denyRead` / `denyWrite` in
  `.claude/settings.json` cover Bash and any other sandboxed
  subprocess.

Both layers are needed because they intercept different access
channels. Run the three sub-steps below in order and **confirm
each one with the user before applying**.

### 2.A — Workspace sensitive files → `deny-workspace-paths.txt`

Goal: identify workspace paths Claude's file tools must not touch.

1. Walk the workspace and collect candidate sensitive paths. Useful signals:
   - Environment / dotenv: `.env`, `.env.*`, `.envrc`
   - Conventional secret directories: `secrets/`, `private/`, `credentials/`, `keys/`, `certs/private/`
   - SSH / PGP / TLS keys: `id_rsa`, `id_ed25519`, `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.gpg`, `*.asc`
   - Cloud credentials: `.aws/credentials`, `.aws/config`, `.gcp/`, `.azure/`, `service-account*.json`, `gha-creds-*.json`
   - DB dumps / backups: `*.sqlite`, `*.db`, `dump.sql`, `*.bak`
   - Auth / session files: `.netrc`, `cookies.txt`, `*.session`
   - Anything in `.gitignore` that looks credential-shaped — cross-check with:
     ```
     git ls-files --others --ignored --exclude-standard
     ```
2. Present the candidate list to the user. Ask which entries to keep, remove, or add. Be explicit about which entries are directories vs files.
3. Merge the confirmed list into `.claude/hardening/deny-workspace-paths.txt`:
   - One path per line.
   - Use directory entries (`secrets/`) to block whole trees and file entries (`.env`) for individual files.
   - Preserve any existing non-comment lines already in the file.
   - Preserve comments and section structure.
4. The entire `.claude/` directory is already implicitly protected
   by the file-access hook once `.initialized` is written, so
   listing it here is optional — but harmless. Mention this to
   the user.

Remember the confirmed list of workspace paths — sub-step 2.B uses it.

### 2.B — Same workspace paths → `sandbox.filesystem` deny

The workspace paths confirmed in 2.A are typically sensitive at
the **sandbox** layer too — Bash commands and any other sandboxed
subprocess should be blocked from them as well, not only Claude's
file tools.

1. Show the user the workspace deny list from 2.A and ask:

   > "Should I also add these paths to `sandbox.filesystem.denyRead`
   > and `sandbox.filesystem.denyWrite` in `.claude/settings.json`?
   > This blocks shell-level access too, not just Claude's file
   > tools."

2. Let the user choose the scope:
   - **Both `denyRead` and `denyWrite`** (default if they just say
     yes) — protects against reads and writes from any sandboxed
     subprocess.
   - **`denyWrite` only** — if the user wants Bash to be able to
     read the file (e.g. to grep through `.env`) but not modify it.
   - **`denyRead` only** — rare but possible.
   - **Skip** — leave `sandbox.filesystem` as-is.

3. On confirmation, edit `.claude/settings.json` with the `Edit`
   tool, **merging** the new entries into any existing
   `sandbox.filesystem.denyRead` / `denyWrite` arrays. Do not
   replace the existing arrays. Preserve other sandbox keys.

4. After the edit, re-read `.claude/settings.json` to confirm the
   file still parses as JSON.

### 2.C — External sensitive paths → `sandbox.filesystem.denyRead`

Some sensitive files live **outside** the workspace, but a Bash
command launched from inside Claude Code could still reach them.
These don't belong in `deny-workspace-paths.txt` (workspace-only)
or `allow-paths.txt` (read-only allowlist), but they should be
blocked at the sandbox layer.

1. Propose a candidate list for the user. Typical entries:
   - `~/.ssh/` — SSH private keys and configs
   - `~/.aws/credentials`, `~/.aws/config`
   - `~/.gnupg/` — GnuPG keyring
   - `~/.config/gh/hosts.yml` — GitHub CLI tokens
   - `~/.netrc` — HTTP / FTP credentials
   - `~/.kube/config` — Kubernetes cluster credentials
   - `~/.azure/`, `~/.gcp/`, `~/.config/gcloud/`
   - `~/.pypirc`, `~/.npmrc`, `~/.cargo/credentials`,
     `~/.bundle/credentials` — package-registry tokens
   - `~/.docker/config.json` — registry credentials
   - On macOS, also: `~/Library/Keychains/`
   - On Windows, equivalents under `~/AppData/Roaming/` and
     `~/AppData/Local/Microsoft/Credentials/`

   Tailor the list to what the user actually has on their host.

2. Present the list. Ask which entries to keep, remove, or add.
   Use absolute paths or `~`-based paths; relative paths don't
   make sense here.

3. On confirmation, **add the entries to
   `sandbox.filesystem.denyRead` in `.claude/settings.json`**.
   - Do **not** also add them to `denyWrite` by default — these
     are external paths and not normal write targets, and adding
     them to `denyWrite` blocks legitimate operations (e.g.
     `ssh-keygen` writing to `~/.ssh/`). Offer it as an option if
     the user explicitly wants it for a specific entry.
   - **Merge** rather than overwrite; preserve any pre-existing
     entries.

4. After the edit, re-read `.claude/settings.json` to confirm the
   file still parses as JSON.

> Note: these external paths are deliberately **not** added to
> `.claude/hardening/allow-paths.txt`. That file is for paths
> Claude's file tools should be allowed to read; here we want the
> opposite — block at the sandbox layer. Claude's file tools
> already deny outside-workspace paths by default (policy step 2),
> so the two layers together cover both access channels.

## Phase 3 — Identify readable-among-blocked files

Goal: populate `.claude/hardening/allow-paths.txt` with paths that should remain readable. Remember: **`allow-paths.txt` grants read-only access**; entries here do not unblock writes.

1. For each entry added to `deny-workspace-paths.txt` in Phase 2, ask the user whether any subpath inside it should still be **readable** by the agent (e.g. `secrets/public/` while `secrets/` is denied; a non-sensitive README inside a secrets directory).
2. Ask whether any external paths (outside the workspace) need to be readable — typical examples: `~/.cache/<tool>`, `/tmp/project-inputs`, a shared inputs directory.
3. Merge the confirmed entries into `.claude/hardening/allow-paths.txt`. Same rules as Phase 2 (one per line, preserve existing entries and comments). Use `~` for the user's home directory.

## Phase 4 — Interactive configuration

For each item below, ask the user whether the feature should be active, then immediately apply the answer to `.claude/settings.json`. Use the `Edit` tool to make minimal structural changes; do not rewrite the whole file. After every edit, validate that `.claude/settings.json` still parses as JSON.

### 4a. `security-guidance@claude-plugins-official` plugin

Ask: *"Activate Anthropic's `security-guidance` plugin? It runs automated security analysis on the code you create or modify in this project."*

- If **NO**:
  1. Remove the `"security-guidance@claude-plugins-official"` key from `enabledPlugins`. If that empties the object, leave it as `{}` rather than deleting the field — it keeps the schema obvious.
  2. Do **not** create `claude-security-guidance.md`. Skip to 4b.

- If **YES**: leave the plugin entry in `enabledPlugins` and build a tailored `claude-security-guidance.md` via the five sub-steps below. The goal is concrete, project-specific guidance, **not** boilerplate — use this project's own docs as the primary source, fall back to a user interview when needed, and adapt the industry-specific seed checklists.

#### 4a.i — Gather project context from existing artifacts

Read what the project already says about itself. This is the primary source of truth; do not paraphrase generic templates over it.

Walk these locations in order and note what you find:

1. **READMEs and top-level docs** — `README.md`, `README.rst`, `README.txt`, `OVERVIEW.md`, `ABOUT.md`. These usually state what the project is, who it's for, and what it does.
2. **Contribution / security policies** — `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`. A `SECURITY.md` often spells out the threat model in plain language already; treat its contents as authoritative for this file.
3. **Architecture and design docs** — anything under `docs/`, `architecture/`, `design/`, `adr/` (architecture decision records), `rfcs/`, `whitepapers/`.
4. **Dependency manifests (to identify the stack)** — `package.json`, `Cargo.toml`, `pyproject.toml` / `requirements*.txt`, `go.mod`, `Gemfile`, `composer.json`, `pubspec.yaml`, `build.gradle` / `pom.xml`, `foundry.toml` / `hardhat.config.*`, `Dockerfile`, `compose.yaml`, `terraform/`, `kubernetes/`, `helm/`.
5. **Source-tree shape** — top-level dirs like `src/`, `contracts/`, `apps/`, `services/`, `migrations/`, `infrastructure/` reveal the architecture.
6. **External docs / website** — if the README or a manifest cites a project website, documentation site, or whitepaper URL, surface the URL to the user and ask:

   > *"I found a docs link at `<URL>`. May I use it as context for the threat model? If `WebFetch` is denied in this project, please paste the relevant sections (especially anything that talks about threat model, trust boundaries, or security assumptions) and I'll use that instead."*

   Use whatever the user provides — fetched content or pasted excerpts.

#### 4a.ii — If the artifacts are insufficient, interview the user

If 4a.i yielded little (thin README, no docs, no `SECURITY.md`, generic dependencies), the project description has to come from the user. Ask them:

> *"I couldn't find enough in the repo to write a useful threat model. Could you briefly describe this project?*
>
> *1. What does it do? (one-paragraph plain-English description)*
>
> *2. What industry / domain does it operate in? Some that have distinctly different threat models:*
>    - *Web2 SaaS / enterprise apps*
>    - *Fintech / payments / banking*
>    - *Web3 / DeFi / on-chain protocols*
>    - *Cryptography libraries / signing services / wallets*
>    - *AI / ML / agentic systems*
>    - *Infrastructure / DevOps / platform engineering*
>    - *Healthcare / regulated data*
>    - *Mobile applications*
>    - *Embedded / IoT*
>    - *Other — please describe.*
>
> *3. What's the stack? (languages, frameworks, datastores, deployment target)*
>
> *4. Who is the typical caller / user? (anonymous public-internet users, authenticated employees, smart-contract callers, other internal services, …)*"

Combine the answers with whatever 4a.i did find. Do not skip the interview just because 4a.i returned *something* — use judgement: if what you found is thin or generic, ask anyway.

#### 4a.iii — Draft `claude-security-guidance.md`

Write the file at the project root using this structure, and **tailor every section to what you actually learned**:

```markdown
# Project security guidance

> Loaded as additional context by the `security-guidance` plugin
> alongside its built-in vulnerability checklist.

## What this project is

<one-paragraph summary distilled from the README / docs / user>

## Stack

- Languages: …
- Frameworks: …
- Datastores: …
- Deployment target: …

## Threat model

### Adversaries
<concrete, named — e.g. "anonymous attacker on the public internet",
"malicious frontrunner / MEV searcher", "compromised dependency
maintainer", "phishing-victim employee", "rogue insider with DB
read access", "untrusted on-chain caller (any EOA)", "prompt-
injection payload in retrieved web content".>

### Goals
<concrete adversary objectives — e.g. "drain funds from the
lending pool", "escalate from authenticated tenant A to read
tenant B's data", "bypass signature verification to forge a
transaction", "exfiltrate user PII", "execute arbitrary code in
the agent's sandbox".>

### Protected assets
<list with concrete examples from THIS project, with file or
module references where possible>

## Trust boundaries

<list each place where untrusted input enters or where an
authorisation decision happens; cite file/module paths>

## Review checklist

<reviewer-facing imperatives prioritised for THIS stack and threat
model — drawn from the seed checklist below for the matching
industry, adapted, and extended with project-specific items>
```

Quote the project's own words from `SECURITY.md` / README / docs where appropriate — do not paraphrase them out of recognisability.

#### 4a.iv — Industry-specific seed checklists

Pick the checklist(s) that match what 4a.i / 4a.ii found, adapt the items, drop what doesn't apply, and add project-specific items. **The seed is a starting point, not a copy target.**

- **Web2 SaaS / enterprise** — session/credential handling and password storage; MFA enforcement; tenant isolation (horizontal authz, IDOR on every resource path); XSS (templating auto-escape on/off?); CSRF on state-changing endpoints; SSRF on URL-accepting fields; PII inventory and access logging; rate limiting / brute-force resistance; dependency lockfile + CVE scan.
- **Fintech / payments / banking** — money math (decimal vs float, rounding direction, currency conversion); idempotency on every money-moving endpoint; replay and double-spend prevention; PCI scope and card-data flow; KYC/AML hooks; reconciliation between internal ledger and external processor; audit-trail completeness; regulatory mapping (PCI-DSS, SOX, PSD2).
- **Web3 / DeFi / on-chain protocols** — reentrancy on every external call (CEI, ReentrancyGuard, cross-contract); oracle dependencies and price-manipulation paths (flash loans, TWAP windows); access control between governance / ops / emergency pausers (multisig vs EOA); token math rounding direction (which side benefits); share / asset accounting on deposit/withdraw; fee-skim ordering; cross-chain / bridge replay and message ordering; upgradeability (storage layout, initializer protection); MEV exposure.
- **Cryptography libraries / signing services / wallets** — algorithm safety (no SHA-1/MD5 for signatures, no raw RSA, AEAD for symmetric); domain separation across signature contexts; nonce / RNG safety (secure RNG, never reuse nonces in ECDSA/DSA/GCM); canonicalisation (low-S enforcement, deterministic encoding); anti-replay (chain ID, nonce, timestamp, message id); side-channel (constant-time MAC/signature comparison, no early returns on length checks); key management lifecycle.
- **AI / ML / agentic systems** — prompt-injection resilience on every untrusted input (web fetch, RAG corpus, tool outputs, file contents); tool authorisation (which tools the agent may call without confirmation; what data they may exfiltrate); output handling (never auto-execute code or commands derived from model output); memory / persistence (what is written to long-term storage; can an attacker poison it?); sandbox boundaries (subprocess egress, filesystem reach, network reach); model supply-chain risk.
- **Infrastructure / DevOps / platform** — secret storage (no plaintext secrets in repo, env files, Terraform state, CI logs); IAM least privilege (no `*` actions in cloud policies); container hardening (non-root user, read-only root FS, distroless / minimal base); network egress allowlist, mTLS internally, no public-by-default services; supply chain (pinned digests, SBOM, signed builds, provenance).
- **Healthcare / regulated data** — PHI/PII inventory and data-flow diagram; access logging on every read of regulated data (e.g. HIPAA §164.312(b)); encryption at rest and in transit with key-management separation of duties; data minimisation and retention schedule; BAA / processor agreements where third parties are involved.
- **Mobile** — secure storage (Keychain / Keystore) for tokens; no plaintext credentials in `NSUserDefaults` / `SharedPreferences`; TLS pinning when threat model warrants; deep-link / intent validation; runtime-permission rationale; app-permission audit; jailbreak / root detection where relevant.
- **Embedded / IoT** — firmware update integrity (signed updates, anti-rollback); secure boot chain; physical-attack assumptions; default credential policy; over-the-air channel security.

If the project spans multiple categories (e.g. a fintech web2 backend, or an AI agent that signs transactions), pull from each relevant seed and dedupe overlapping items.

#### 4a.v — Confirm with the user

Show the user the draft and ask them to:

1. Verify the **"What this project is"** paragraph matches reality.
2. Add or correct **adversaries**, **goals**, **protected assets**, and **trust boundaries**.
3. Remove **review checklist** items that don't apply.
4. Add project-specific items the seed templates don't cover (proprietary protocols, contractual or regulatory obligations specific to this project, known historical incidents to watch for).

Apply their edits and save the final version to `claude-security-guidance.md` at the project root. Do not save until the user has reviewed and approved.

### 4b. Confirm policy file contents

Show the user the final contents of `.claude/hardening/allow-paths.txt` and `.claude/hardening/deny-workspace-paths.txt` as they stand after Phases 2 and 3. Ask whether to add, remove, or edit any line. Apply final edits.

### 4c. Bash file-access review prompt

Ask: *"Keep the LLM security layer that reviews each `Bash` command for paths the file-access policy would block (outside-workspace or deny-listed)?"*

- If **YES**: leave the PreToolUse entry whose `matcher` is exactly `"Bash"` in place.
- If **NO**: remove **only** that entry (matcher `"Bash"`, single `prompt`-type hook) from `hooks.PreToolUse`. Leave the file-access entry and any MCP entry untouched.

### 4d. MCP audit prompt

Ask: *"Keep the LLM security layer that audits every `mcp__*` tool call via `/security-review`?"*

- If **YES**: leave the PreToolUse entry whose `matcher` is exactly `"mcp__.*"` in place.
- If **NO**: remove **only** that entry from `hooks.PreToolUse`. Leave the file-access entry and any Bash entry untouched.

After all edits, the file-access `command`-type hook (`Read|Write|Edit|MultiEdit|NotebookEdit`) MUST still be present. It is the floor of this setup and is not optional.

## Phase 5 — Seal the policy

1. Show the user a final summary:
   - Final `deny-workspace-paths.txt` contents.
   - Final `allow-paths.txt` contents.
   - Which optional features ended up active vs. disabled.
   - Whether `claude-security-guidance.md` was created and saved.
2. Ask for explicit confirmation to seal the policy.
3. On confirmation, create `.claude/hardening/.initialized`. A single line is enough, e.g.:
   ```
   Hardener-init sealed on YYYY-MM-DD. security-guidance=ON, bash-prompt=ON, mcp-prompt=OFF.
   ```
   Replace `YYYY-MM-DD` with the current date and reflect the actual feature toggles.
4. Tell the user the bootstrap window is now closed. From now on, editing any of `allow-paths.txt`, `deny-workspace-paths.txt`, or `.initialized` requires going through the normal policy — i.e. the agent cannot modify them unless their parent dir is removed from `deny-workspace-paths.txt`. The recommended way to re-run setup is to delete `.initialized` manually from outside Claude Code.
5. Stop. Do not start any unrelated task in this turn.

## Guardrails

- Do **not** weaken the default security posture. The user can disable optional layers (Phase 4) but you must never replace a strict setting (e.g. `sandbox.enabled: true`, `allowUnsandboxedCommands: false`, `disableBypassPermissionsMode: "disable"`, `permissions.defaultMode: "default"`) with a looser one.
- Do **not** add paths to `allow-paths.txt` that the user did not explicitly approve. Suggestions are fine; silent additions are not.
- Do **not** modify the file-access `command`-type PreToolUse entry. It is the floor.
- Do **not** touch files outside the hardening scope: `.claude/settings.json`, `.claude/hardening/*`, `.claude/skills/hardener-init/*`, `README.md`, `CLAUDE.md`, and (only if Phase 4a says YES) `claude-security-guidance.md`. If the user asks for unrelated work, defer it to a separate session.
- When editing path-list files, use forward slashes, preserve comments, and never delete the user-facing usage header at the top of each file.
- When editing `.claude/settings.json`, prefer `Edit` over `Write`. Re-read the file after every edit and verify it still parses as JSON before continuing.
