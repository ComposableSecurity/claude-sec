---
name: claude-sec-generate-security-guidance
description: Generates a `claude-security-guidance.md` file at the project root. The Anthropic `security-guidance` plugin loads it as additional context during its model-backed code reviews. The skill first checks whether the plugin is enabled in `.claude/settings.json`; if not, it tells the user to run `claude-sec configure`, enable the plugin, and then rerun this skill. When the plugin is enabled, the skill reads the project's own docs (README, SECURITY.md, dependency manifests, architecture docs, optionally a website / docs URL), runs an industry / stack interview when the repo lacks enough context, drafts the file with concrete threat-model and review-checklist sections tailored to the project, and saves it after the user reviews and approves. Trigger phrases include "generate security guidance", "write claude-security-guidance", "create the security guidance file", or any question about giving the security-guidance plugin a project-specific threat model.
---

# claude-sec — generate `claude-security-guidance.md`

This skill creates `claude-security-guidance.md` at the project
root. The Anthropic `security-guidance` plugin loads the file as
additional context during its model-backed code reviews,
alongside its built-in vulnerability checklist.

## Step 0 — Precondition check

Read `.claude/settings.json` and look at
`enabledPlugins["security-guidance@claude-plugins-official"]`.

- If the key is missing or set to `false`, the plugin is **not
  enabled**, so writing `claude-security-guidance.md` would have
  no effect — nothing would load it. **Stop** and tell the user,
  verbatim:

  > "The `security-guidance` plugin isn't enabled in
  > `.claude/settings.json`, so writing
  > `claude-security-guidance.md` would have no effect — nothing
  > would load it. Run:
  >
  >     claude-sec configure
  >
  > in a terminal at this project's root and answer **yes** when
  > it asks about the `security-guidance` plugin, then start a
  > new session and ask me to run this skill again."

  Do not proceed.

- If the value is `true`, continue.

## Step 1 — Gather project context from existing artifacts

Read what the project already says about itself. **This is the
primary source of truth.** Do not paraphrase generic templates
over it.

Walk these locations in order and note what you find:

1. **READMEs and top-level docs** — `README.md`, `README.rst`,
   `README.txt`, `OVERVIEW.md`, `ABOUT.md`. These usually state
   what the project is, who it's for, and what it does.
2. **Contribution / security policies** — `CONTRIBUTING.md`,
   `SECURITY.md`, `CODE_OF_CONDUCT.md`. A `SECURITY.md` often
   spells out the threat model in plain language already; treat
   its contents as authoritative for this file.
3. **Architecture and design docs** — anything under `docs/`,
   `architecture/`, `design/`, `adr/` (ADRs), `rfcs/`,
   `whitepapers/`.
4. **Dependency manifests (to identify the stack)** —
   `package.json`, `Cargo.toml`, `pyproject.toml` /
   `requirements*.txt`, `go.mod`, `Gemfile`, `composer.json`,
   `pubspec.yaml`, `build.gradle` / `pom.xml`, `foundry.toml` /
   `hardhat.config.*`, `Dockerfile`, `compose.yaml`,
   `terraform/`, `kubernetes/`, `helm/`.
5. **Source-tree shape** — top-level dirs like `src/`,
   `contracts/`, `apps/`, `services/`, `migrations/`,
   `infrastructure/` reveal the architecture.
6. **External docs / website** — if the README or a manifest
   cites a project website, docs site, or whitepaper URL,
   surface it to the user and ask:

   > "I found a docs link at `<URL>`. May I use it as context
   > for the threat model? If `WebFetch` is denied in this
   > project, please paste the relevant sections (especially
   > anything that talks about threat model, trust boundaries,
   > or security assumptions) and I'll use that instead."

## Step 2 — Interview the user when artifacts are thin

If Step 1 yielded little (thin README, no `SECURITY.md`, generic
dependencies), the project description has to come from the user.
Ask them:

> "I couldn't find enough in the repo to write a useful threat
> model. Could you briefly describe this project?
>
> 1. What does it do? (one paragraph)
>
> 2. What industry / domain does it operate in? Some that have
>    distinctly different threat models:
>    - Web2 SaaS / enterprise apps
>    - Fintech / payments / banking
>    - Web3 / DeFi / on-chain protocols
>    - Cryptography libraries / signing services / wallets
>    - AI / ML / agentic systems
>    - Infrastructure / DevOps / platform engineering
>    - Healthcare / regulated data
>    - Mobile applications
>    - Embedded / IoT
>    - Other — please describe.
>
> 3. What's the stack? (languages, frameworks, datastores,
>    deployment target)
>
> 4. Who is the typical caller / user? (anonymous public-internet
>    users, authenticated employees, smart-contract callers,
>    other internal services, …)"

Combine the answers with whatever Step 1 found. Don't skip the
interview just because Step 1 returned *something* — if what you
found is thin or generic, ask anyway.

## Step 3 — Draft `claude-security-guidance.md`

Write the file at the project root using this structure, and
**tailor every section to what you actually learned**:

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
<concrete, named — e.g. "anonymous attacker on the public
internet", "malicious frontrunner / MEV searcher", "compromised
dependency maintainer", "phishing-victim employee", "rogue
insider with DB read access", "untrusted on-chain caller (any
EOA)", "prompt-injection payload in retrieved web content".>

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

<reviewer-facing imperatives prioritised for THIS stack and
threat model — drawn from the seed checklist below for the
matching industry, adapted, and extended with project-specific
items>
```

Quote the project's own words from `SECURITY.md` / README / docs
where appropriate — do not paraphrase them out of
recognisability.

## Step 4 — Industry-specific seed checklists

Pick the checklist(s) that match what Step 1 / Step 2 found.
Adapt the items, drop what doesn't apply, and add
project-specific items. **The seed is a starting point, not a
copy target.**

- **Web2 SaaS / enterprise** — session / credential handling
  and password storage; MFA enforcement; tenant isolation
  (horizontal authz, IDOR on every resource path); XSS
  (templating auto-escape on/off?); CSRF on state-changing
  endpoints; SSRF on URL-accepting fields; PII inventory and
  access logging; rate limiting / brute-force resistance;
  dependency lockfile + CVE scan.
- **Fintech / payments / banking** — money math (decimal vs
  float, rounding direction, currency conversion); idempotency
  on every money-moving endpoint; replay and double-spend
  prevention; PCI scope and card-data flow; KYC/AML hooks;
  reconciliation between internal ledger and external
  processor; audit-trail completeness; regulatory mapping
  (PCI-DSS, SOX, PSD2).
- **Web3 / DeFi / on-chain protocols** — reentrancy on every
  external call (CEI, ReentrancyGuard, cross-contract); oracle
  dependencies and price-manipulation paths (flash loans, TWAP
  windows); access control between governance / ops / emergency
  pausers (multisig vs EOA); token math rounding direction
  (which side benefits); share / asset accounting on
  deposit/withdraw; fee-skim ordering; cross-chain / bridge
  replay and message ordering; upgradeability (storage layout,
  initializer protection); MEV exposure.
- **Cryptography libraries / signing services / wallets** —
  algorithm safety (no SHA-1/MD5 for signatures, no raw RSA,
  AEAD for symmetric); domain separation across signature
  contexts; nonce / RNG safety (secure RNG, never reuse nonces
  in ECDSA/DSA/GCM); canonicalisation (low-S enforcement,
  deterministic encoding); anti-replay (chain ID, nonce,
  timestamp, message id); side-channel (constant-time
  MAC/signature comparison, no early returns on length checks);
  key management lifecycle.
- **AI / ML / agentic systems** — prompt-injection resilience
  on every untrusted input (web fetch, RAG corpus, tool
  outputs, file contents); tool authorisation (which tools the
  agent may call without confirmation; what data they may
  exfiltrate); output handling (never auto-execute code or
  commands derived from model output); memory / persistence
  (what is written to long-term storage; can an attacker poison
  it?); sandbox boundaries (subprocess egress, filesystem
  reach, network reach); model supply-chain risk.
- **Infrastructure / DevOps / platform** — secret storage (no
  plaintext secrets in repo, env files, Terraform state, CI
  logs); IAM least privilege (no `*` actions in cloud
  policies); container hardening (non-root user, read-only root
  FS, distroless / minimal base); network egress allowlist,
  mTLS internally, no public-by-default services; supply chain
  (pinned digests, SBOM, signed builds, provenance).
- **Healthcare / regulated data** — PHI/PII inventory and
  data-flow diagram; access logging on every read of regulated
  data (e.g. HIPAA §164.312(b)); encryption at rest and in
  transit with key-management separation of duties; data
  minimisation and retention schedule; BAA / processor
  agreements where third parties are involved.
- **Mobile** — secure storage (Keychain / Keystore) for tokens;
  no plaintext credentials in `NSUserDefaults` /
  `SharedPreferences`; TLS pinning when threat model warrants;
  deep-link / intent validation; runtime-permission rationale;
  app-permission audit; jailbreak / root detection where
  relevant.
- **Embedded / IoT** — firmware update integrity (signed
  updates, anti-rollback); secure boot chain; physical-attack
  assumptions; default credential policy; over-the-air channel
  security.

If the project spans multiple categories (e.g. a fintech web2
backend, or an AI agent that signs transactions), pull from each
relevant seed and dedupe overlapping items.

## Step 5 — Confirm with the user, then save

Show the user the draft and ask them to:

1. Verify the **"What this project is"** paragraph matches
   reality.
2. Add or correct **adversaries**, **goals**, **protected
   assets**, and **trust boundaries**.
3. Remove **review checklist** items that don't apply.
4. Add project-specific items the seed templates don't cover
   (proprietary protocols, contractual or regulatory
   obligations specific to this project, known historical
   incidents to watch for).

Apply their edits and save the final version to
`claude-security-guidance.md` at the project root. **Do not
save until the user has reviewed and approved.**

## Guardrails

- Never save `claude-security-guidance.md` before the user has
  reviewed and approved the draft.
- Never write to any file under `.claude/`. This skill operates
  only on the project root (`claude-security-guidance.md`).
- Never fabricate threat-model entries that aren't backed by
  something you read or that the user told you. If you must
  include a placeholder, mark it clearly (e.g.
  "[draft assumption — please correct]").
- Do not paraphrase `SECURITY.md` or README text out of
  recognisability — quote directly where it makes sense.
- If the project legitimately has no obvious threat model
  (e.g. a single-file CLI utility with no inputs from the
  network), say so in the draft and propose a minimal
  checklist; do not invent adversaries to fill space.
