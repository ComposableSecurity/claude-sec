#!/usr/bin/env bash
# SessionStart hook: nudge the user when first-time setup is
# incomplete. Runs two independent checks:
#
#   1. Has the workspace deny list been populated?
#      (deny-workspace-paths.txt must have at least one active rule)
#
#   2. Is the security-guidance plugin enabled, but the project-root
#      claude-security-guidance.md file is missing?
#
# Each failed check contributes a banner block. The blocks are
# concatenated into a single hookSpecificOutput.additionalContext
# payload telling Claude to greet the user with the banner(s) on
# its first turn. Silent (exit 0, no output) when both checks pass.
#
# SessionStart-hook stdout is consumed by Claude Code as additional
# context for the model rather than printed straight to the user's
# console, so we emit structured JSON instead of plain echo.
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DENY_PATHS_FILE="$DIR/deny-workspace-paths.txt"
SETTINGS_FILE="$DIR/../settings.json"
SKILL_FILL_DENY="$DIR/../skills/claude-sec-fill-deny-paths/SKILL.md"
SKILL_GEN_GUIDANCE="$DIR/../skills/claude-sec-generate-security-guidance/SKILL.md"

# Project root = parent of .claude/, where claude-security-guidance.md
# is expected (the plugin loads it from there).
PROJECT_ROOT="$(cd "$DIR/../.." 2>/dev/null && pwd || true)"
GUIDANCE_FILE="${PROJECT_ROOT:-..}/claude-security-guidance.md"

# ---------- check 1: deny list ----------
# True if deny-workspace-paths.txt has no active (non-blank,
# non-comment) rules — i.e. the workspace setup hasn't been done.
deny_paths_empty=true
if [ -f "$DENY_PATHS_FILE" ] \
   && grep -qE '^[^[:space:]#]' "$DENY_PATHS_FILE" 2>/dev/null; then
    deny_paths_empty=false
fi

# ---------- check 2: security-guidance plugin / guidance file ----------
# True if the security-guidance plugin is enabled in settings.json
# AND claude-security-guidance.md does not exist at the project root.
guidance_missing=false
if [ -f "$SETTINGS_FILE" ] \
   && grep -qE '"security-guidance@claude-plugins-official"[[:space:]]*:[[:space:]]*true' \
              "$SETTINGS_FILE" 2>/dev/null \
   && [ ! -f "$GUIDANCE_FILE" ]; then
    guidance_missing=true
fi

# If neither check fires, stay silent.
if [ "$deny_paths_empty" = false ] && [ "$guidance_missing" = false ]; then
    exit 0
fi

# ---------- JSON encoder ----------
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

emit_context() {
    local escaped
    escaped="$(json_escape "$1")"
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$escaped"
}

# ---------- banner blocks ----------

DENY_BANNER='================================================================
  claude-sec — first-time setup: deny paths
================================================================
This project ships the claude-sec hardening template but the
workspace deny list has not been populated yet
(.claude/hardening/deny-workspace-paths.txt has no active rules).
The default policy is in force, but no project-specific deny
rules have been written.

To scan the project and populate the deny list, run the skill:

    /claude-sec-fill-deny-paths

After it finishes, two follow-ups are available from a terminal
at the project root:

  1. claude-sec update-paths   — mirror the workspace deny list
                                 into sandbox.filesystem and add
                                 external sensitive paths
                                 (~/.ssh/, ~/.aws/credentials, ...)
                                 to denyRead.

  2. claude-sec configure      — enable optional layers
                                 (security-guidance plugin,
                                 Bash review prompt, MCP audit
                                 prompt). Idempotent.

If you enable the security-guidance plugin, also run the
/claude-sec-generate-security-guidance skill afterwards — it
writes a project-tailored claude-security-guidance.md that the
plugin loads as additional context.
================================================================'

GUIDANCE_BANNER='================================================================
  claude-sec — security guidance file missing
================================================================
The security-guidance plugin is enabled in .claude/settings.json
but no claude-security-guidance.md exists at the project root.
Without it, the plugin'"'"'s reviews use only its built-in
checklist — they have no project-specific context (threat model,
adversaries, sensitive assets, trust boundaries).

To generate a tailored file, run the skill:

    /claude-sec-generate-security-guidance

The skill reads this project'"'"'s own docs (README, SECURITY.md,
architecture/, dependency manifests) and, when context is thin,
asks you about the industry and stack to produce a focused
threat model and review checklist.
================================================================'

# ---------- handle missing skill files (diagnostic fallback) ----------
# If a skill is missing the message switches to a different
# diagnostic instead of recommending a skill the user does not have.

deny_missing_skill=false
guidance_missing_skill=false
if [ "$deny_paths_empty" = true ] && [ ! -f "$SKILL_FILL_DENY" ]; then
    deny_missing_skill=true
fi
if [ "$guidance_missing" = true ] && [ ! -f "$SKILL_GEN_GUIDANCE" ]; then
    guidance_missing_skill=true
fi

if [ "$deny_missing_skill" = true ] || [ "$guidance_missing_skill" = true ]; then
    msg="claude-sec status: hardening template appears incomplete."
    if [ "$deny_missing_skill" = true ]; then
        msg="$msg The claude-sec-fill-deny-paths skill is missing from .claude/skills/claude-sec-fill-deny-paths/SKILL.md."
    fi
    if [ "$guidance_missing_skill" = true ]; then
        msg="$msg The claude-sec-generate-security-guidance skill is missing from .claude/skills/claude-sec-generate-security-guidance/SKILL.md."
    fi
    msg="$msg As your very first response in this session, tell the user the template is incomplete and recommend they run \`./claude-sec .\` from their local claude-sec checkout to reinstall it, then restart the session."
    emit_context "$msg"
    exit 0
fi

# ---------- assemble the combined banner ----------

banners=""
if [ "$deny_paths_empty" = true ]; then
    banners="$DENY_BANNER"
fi
if [ "$guidance_missing" = true ]; then
    if [ -n "$banners" ]; then
        banners="$banners

$GUIDANCE_BANNER"
    else
        banners="$GUIDANCE_BANNER"
    fi
fi

# ---------- assemble the instruction wrapper ----------

# Build a short list of which skills the user should be asked about
# (one or both, depending on which checks fired).
if [ "$deny_paths_empty" = true ] && [ "$guidance_missing" = true ]; then
    asks="ask the user whether they want to run /claude-sec-fill-deny-paths first (recommended), and remind them that /claude-sec-generate-security-guidance is available afterwards"
elif [ "$deny_paths_empty" = true ]; then
    asks="ask the user whether they want to run /claude-sec-fill-deny-paths now"
else
    asks="ask the user whether they want to run /claude-sec-generate-security-guidance now"
fi

emit_context "claude-sec status: this project's first-time setup is incomplete. As your very first response in this session, before doing anything else, display the following welcome banner(s) to the user VERBATIM, each inside its own fenced code block, exactly as written; do not paraphrase or summarize. After the banner(s), $asks.

$banners"
