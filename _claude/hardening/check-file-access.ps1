#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Claude Code file-access hardening hook (standalone PowerShell, no Python).

.DESCRIPTION
    PowerShell port of check-file-access.py with the same decision
    semantics. Reads a Claude Code PreToolUse event from stdin and
    decides whether to allow or deny Read / Write / Edit / MultiEdit /
    NotebookEdit access based on the policy files in this directory.

    Policy order:
        0. Bootstrap window: if .claude/hardening/.initialized does
           not exist and the target is **anywhere inside .claude/**,
           allow. Lets a fresh checkout edit any hardening file
           (policy lists, settings, scripts) and create the
           .initialized marker without any other rule blocking it.
        1. If the tool is Read AND target matches an entry in
           allow-paths.txt, allow.
        2. Deny if target is outside the workspace root (the event's
           .cwd field).
        3. Deny if target is **anywhere inside .claude/** (implicit
           protection of the hardening config; active only after
           .initialized exists).
        4. Deny if target matches an entry in deny-workspace-paths.txt.
        5. Otherwise allow.

    Note that allow-paths.txt grants read-only access. The
    allow-paths read-override also applies to step 3: a workspace
    path inside .claude/ listed there remains readable, but writes
    to it are still denied.

    The implicit .claude/ deny is the system-level lock on the
    hardening config. To re-open the policy for editing, delete
    .claude/hardening/.initialized from outside Claude Code.

    Allow: exit 0 with no output.
    Deny:  emit a PreToolUse deny JSON object on stdout, exit 0.

    Compatible with Windows PowerShell 5.1 and PowerShell Core 7+.
    Must stay in decision lockstep with check-file-access.py.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:HardeningDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ClaudeDir       = Split-Path -Parent $script:HardeningDir
$script:AllowPathsFile  = Join-Path $script:HardeningDir 'allow-paths.txt'
$script:DenyPathsFile   = Join-Path $script:HardeningDir 'deny-workspace-paths.txt'
$script:InitializedFile = Join-Path $script:HardeningDir '.initialized'

# Tools we guard and the tool_input field that carries the target
# path. Tools matched by the hook (e.g. mcp__*) but not listed here
# pass through with no path check.
$script:FileTools = @{
    'Read'         = 'file_path'
    'Write'        = 'file_path'
    'Edit'         = 'file_path'
    'MultiEdit'    = 'file_path'
    'NotebookEdit' = 'notebook_path'
}

# Tools for which allow-paths.txt grants access. Only Read; the
# write-shaped tools never consult the allowlist, so allowed entries
# are effectively read-only.
$script:AllowPathsTools = @('Read')

# Case-insensitive comparison on Windows, case-sensitive elsewhere.
$script:IsWindowsHost = ($env:OS -eq 'Windows_NT')


function ConvertTo-ComparePath {
    param([Parameter(Mandatory)][string]$Path)
    if ($script:IsWindowsHost) { return $Path.ToLowerInvariant() }
    return $Path
}

function Resolve-PolicyPath {
    <#
        Expand a path entry into a fully normalized absolute path:
          - `~` and `~/...` expand to the user's home directory.
          - Relative paths resolve against $Workspace.
          - `.` and `..` are collapsed via [Path]::GetFullPath.
          - Existing symlinks are followed via Resolve-Path; missing
            paths fall back to the normalized form (mirrors
            Path.resolve(strict=False) in Python).
    #>
    param(
        [Parameter(Mandatory)][string]$Entry,
        [Parameter(Mandatory)][string]$Workspace
    )

    $expanded = $Entry
    $homeDir  = [Environment]::GetFolderPath('UserProfile')
    if ($expanded -eq '~') {
        $expanded = $homeDir
    } elseif ($expanded.StartsWith('~/') -or $expanded.StartsWith('~\')) {
        $expanded = Join-Path $homeDir $expanded.Substring(2)
    }

    if (-not [System.IO.Path]::IsPathRooted($expanded)) {
        $expanded = Join-Path $Workspace $expanded
    }

    $full = [System.IO.Path]::GetFullPath($expanded)

    if (Test-Path -LiteralPath $full) {
        try {
            $full = (Resolve-Path -LiteralPath $full -ErrorAction Stop).Path
        } catch {
            # fall through to the normalized form
        }
    }

    # Strip a trailing path separator (except on a bare root such as
    # "/" or "C:\") so that descendant matching via
    # StartsWith($prefix + $sep) is consistent. .NET on Linux preserves
    # trailing separators from GetFullPath; .NET on Windows generally
    # does not. Python's Path.resolve always strips them; we match.
    $sep    = [System.IO.Path]::DirectorySeparatorChar
    $alt    = [System.IO.Path]::AltDirectorySeparatorChar
    $isRoot =
        ($full.Length -le 1) -or
        ($full.Length -eq 3 -and $full[1] -eq ':' -and
            ($full[2] -eq $sep -or $full[2] -eq $alt))
    if (-not $isRoot) {
        $full = $full.TrimEnd($sep, $alt)
    }
    return $full
}

function Read-PolicyFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return ,@() }

    try {
        $lines = Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop
    } catch {
        return ,@()
    }

    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($raw in $lines) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        $entries.Add($line)
    }
    return ,$entries.ToArray()
}

function Test-PathMatch {
    <#
        Strict path-boundary match.
        Returns $true iff Target == Policy or Target is a descendant of
        Policy under proper path boundaries. Prevents prefix-bypass
        bugs like /tmp/foo matching /tmp/foobar.
    #>
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Policy
    )
    $t = ConvertTo-ComparePath $Target
    $p = ConvertTo-ComparePath $Policy
    if ($t -ceq $p) { return $true }
    $sep = [string][System.IO.Path]::DirectorySeparatorChar
    return $t.StartsWith($p + $sep)
}

function Get-StringProperty {
    param(
        [Parameter(Mandatory)][AllowNull()] $InputObject,
        [Parameter(Mandatory)][string] $Name
    )
    if ($null -eq $InputObject -or -not ($InputObject -is [psobject])) {
        return ''
    }
    $prop = $InputObject.PSObject.Properties[$Name]
    if (-not $prop) { return '' }
    $value = $prop.Value
    if ($null -eq $value) { return '' }
    return [string]$value
}

function Write-DenyAndExit {
    param([Parameter(Mandatory)][string]$Reason)
    $payload = [ordered]@{
        hookSpecificOutput = [ordered]@{
            hookEventName            = 'PreToolUse'
            permissionDecision       = 'deny'
            permissionDecisionReason = $Reason
        }
    }
    $json = $payload | ConvertTo-Json -Compress -Depth 4
    [Console]::Out.WriteLine($json)
    exit 0
}


# --- main ---

$rawInput = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($rawInput)) { exit 0 }

try {
    $eventObj = $rawInput | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-DenyAndExit 'hardening hook received invalid JSON on stdin'
}

if ($null -eq $eventObj -or -not ($eventObj -is [psobject])) {
    Write-DenyAndExit 'hardening hook expected a JSON object on stdin'
}

$toolName = Get-StringProperty -InputObject $eventObj -Name 'tool_name'
if (-not $script:FileTools.ContainsKey($toolName)) { exit 0 }

$pathKey      = $script:FileTools[$toolName]
$toolInputObj = $null
$toolInputProp = $eventObj.PSObject.Properties['tool_input']
if ($toolInputProp) { $toolInputObj = $toolInputProp.Value }
$filePath = Get-StringProperty -InputObject $toolInputObj -Name $pathKey
if (-not $filePath) { exit 0 }

$cwd = Get-StringProperty -InputObject $eventObj -Name 'cwd'
if (-not $cwd) { $cwd = (Get-Location).Path }

$workspace      = Resolve-PolicyPath -Entry $cwd               -Workspace (Get-Location).Path
$target         = Resolve-PolicyPath -Entry $filePath          -Workspace $workspace
$claudeDir      = Resolve-PolicyPath -Entry $script:ClaudeDir  -Workspace $workspace
$targetInClaude = Test-PathMatch     -Target $target           -Policy    $claudeDir

$allowEntries = Read-PolicyFile $script:AllowPathsFile
$denyEntries  = Read-PolicyFile $script:DenyPathsFile

# 0. Bootstrap window: while .initialized is absent, allow access to
#    anything inside .claude/ so the agent (or the user via the
#    hardener-init wizard) can perform first-time setup. Once
#    .initialized exists this branch is skipped and normal policy
#    applies, including the implicit deny at step 3.
if ($targetInClaude -and -not (Test-Path -LiteralPath $script:InitializedFile)) {
    exit 0
}

# 1. Allow if target matches an explicitly allowed path AND the tool
#    is in the read-only allowlist. Write-shaped tools never
#    short-circuit here, so allow-paths.txt entries are read-only.
#    This runs before the implicit .claude/ deny so users can re-open
#    a specific .claude/ subpath for reading after initialization
#    without giving up the write protection.
if ($script:AllowPathsTools -contains $toolName) {
    foreach ($entry in $allowEntries) {
        $resolved = Resolve-PolicyPath -Entry $entry -Workspace $workspace
        if (Test-PathMatch -Target $target -Policy $resolved) { exit 0 }
    }
}

# 2. Deny if target is outside the workspace root.
if (-not (Test-PathMatch -Target $target -Policy $workspace)) {
    $allowName = Split-Path -Leaf $script:AllowPathsFile
    if ($script:AllowPathsTools -contains $toolName) {
        $scope = "and is not in $allowName"
    } else {
        $scope = "and $allowName grants Read access only ($toolName is a write-shaped tool)"
    }
    $reason = "{0} denied: target path is outside the workspace root {1} (target={2}, workspace={3}, policy={4})" `
        -f $toolName, $scope, $target, $workspace, $allowName
    Write-DenyAndExit $reason
}

# 3. Implicit deny on .claude/ — the hardening config itself is not
#    editable after initialization. To re-open it, delete
#    .claude/hardening/.initialized from outside Claude Code.
if ($targetInClaude) {
    $reason = "{0} denied: target is inside .claude/ (target={1}). The hardening config is implicitly protected after first-time setup. To edit it again, delete {2} from outside Claude Code to re-open the bootstrap window." `
        -f $toolName, $target, $script:InitializedFile
    Write-DenyAndExit $reason
}

# 4. Deny if target matches a workspace deny entry.
foreach ($entry in $denyEntries) {
    $resolved = Resolve-PolicyPath -Entry $entry -Workspace $workspace
    if (Test-PathMatch -Target $target -Policy $resolved) {
        $denyName = Split-Path -Leaf $script:DenyPathsFile
        $reason = "{0} denied: target matches deny entry '{1}' (target={2}, policy={3})" `
            -f $toolName, $entry, $target, $denyName
        Write-DenyAndExit $reason
    }
}

# 5. Allow.
exit 0
