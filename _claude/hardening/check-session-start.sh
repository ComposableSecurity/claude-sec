#!/usr/bin/env bash
# SessionStart hook: nudge the user to run /hardener-init if the
# workspace has not been initialized yet.
#
# SessionStart-hook stdout is consumed by Claude Code as additional
# context for the model rather than printed straight to the user's
# console. So instead of just echoing a banner we emit a structured
# `hookSpecificOutput` JSON object whose `additionalContext` *tells*
# Claude to surface the banner to the user as its first response.
#
# Stays silent (exit 0, no output) when:
#   - `.claude/hardening/.initialized` already exists, OR
#   - this script is running on Windows (the .ps1 sibling handles it).
#
# If the hardener-init skill is also missing the message switches to
# a diagnostic instead of recommending a skill the user does not have.
set -u

# Let the .ps1 sibling handle Windows so the user does not see the
# same message twice on hosts with both shells installed.
if [ "${OS:-}" = "Windows_NT" ]; then exit 0; fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
INITIALIZED_FILE="$DIR/.initialized"
SKILL_FILE="$DIR/../skills/hardener-init/SKILL.md"

# Already initialized — nothing to say.
if [ -e "$INITIALIZED_FILE" ]; then exit 0; fi

# Minimal JSON-string encoder. Handles the chars our banner can
# actually contain (backslash, double-quote, newline, CR, tab).
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

if [ ! -f "$SKILL_FILE" ]; then
    emit_context "claude-sec status: this workspace is NOT initialized (.claude/hardening/.initialized is absent) AND the hardener-init skill is missing from .claude/skills/hardener-init/SKILL.md. As your very first response in this session, tell the user that the hardening template appears incomplete and recommend they run \`./claude-sec .\` from their local claude-sec checkout to reinstall the template, then restart the session."
    exit 0
fi

BANNER='================================================================
  claude-sec — first-time setup recommended
================================================================
This project ships the claude-sec hardening template but has not
been initialized yet (.claude/hardening/.initialized is absent).
The default policy is in force, but you have not picked the
optional security layers for this project yet.

To create a hardened Claude Code setup tailored to this project,
run the setup wizard:

    /hardener-init

The wizard verifies the sandbox, scans the repo for sensitive
files, lets you re-allow specific subpaths for reading, walks
you through every optional layer (security-guidance plugin, Bash
review prompt, MCP review prompt), optionally seeds
claude-security-guidance.md with a threat model, and seals the
policy by creating .claude/hardening/.initialized.
================================================================'

emit_context "claude-sec status: this workspace is not yet initialized. As your very first response in this session, before doing anything else, display the following welcome banner to the user VERBATIM (output it inside a fenced code block exactly as written, do not paraphrase or summarize). After the banner, ask the user whether they want to run /hardener-init now.

$BANNER"
