#!/usr/bin/env pwsh
<#
.SYNOPSIS
    SessionStart hook: nudge the user to run /hardener-init if the
    workspace has not been initialized yet (Windows side).

.DESCRIPTION
    SessionStart-hook stdout is consumed by Claude Code as additional
    context for the model, not printed straight to the user's
    console. So instead of just echoing a banner we emit a structured
    `hookSpecificOutput` JSON object whose `additionalContext`
    *tells* Claude to surface the banner to the user as its first
    response.

    Stays silent (exit 0, no output) when:
      - `.claude/hardening/.initialized` already exists, OR
      - this script is running on a non-Windows host (the .sh
        sibling handles it).

    If the hardener-init skill is also missing the message switches
    to a diagnostic instead of recommending a skill the user does
    not have.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'SilentlyContinue'

# Let the .sh sibling handle non-Windows so the user does not see the
# same message twice on hosts with both shells installed.
if ($env:OS -ne 'Windows_NT') { exit 0 }

$ScriptDir       = Split-Path -Parent $MyInvocation.MyCommand.Path
$InitializedFile = Join-Path $ScriptDir '.initialized'
$SkillFile       = Join-Path $ScriptDir '..\skills\hardener-init\SKILL.md'

if (Test-Path -LiteralPath $InitializedFile) { exit 0 }

function Emit-Context {
    param([Parameter(Mandatory)][string]$Message)
    $payload = [ordered]@{
        hookSpecificOutput = [ordered]@{
            hookEventName     = 'SessionStart'
            additionalContext = $Message
        }
    }
    [Console]::Out.WriteLine(($payload | ConvertTo-Json -Compress -Depth 4))
}

if (-not (Test-Path -LiteralPath $SkillFile)) {
    Emit-Context @'
claude-sec status: this workspace is NOT initialized (.claude\hardening\.initialized is absent) AND the hardener-init skill is missing from .claude\skills\hardener-init\SKILL.md. As your very first response in this session, tell the user that the hardening template appears incomplete and recommend they run `.\claude-sec .` from their local claude-sec checkout to reinstall the template, then restart the session.
'@
    exit 0
}

$Banner = @'
================================================================
  claude-sec — first-time setup recommended
================================================================
This project ships the claude-sec hardening template but has not
been initialized yet (.claude\hardening\.initialized is absent).
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
policy by creating .claude\hardening\.initialized.
================================================================
'@

$Message = "claude-sec status: this workspace is not yet initialized. As your very first response in this session, before doing anything else, display the following welcome banner to the user VERBATIM (output it inside a fenced code block exactly as written, do not paraphrase or summarize). After the banner, ask the user whether they want to run /hardener-init now.`n`n$Banner"

Emit-Context $Message
exit 0
