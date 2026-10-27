# SessionStart hook, PowerShell twin of session-context.sh (the primary implementation; the
# harness runs this one only where no Git Bash is found). Prints one guild context file; the
# harness injects stdout as context.
# Usage: & session-context.ps1 context/always-on.md
# Rendering: a line `{{#if KEY}}` or `{{#if !KEY}}` opens a block and a line `{{/if}}` closes
# it (no nesting); marker lines are always dropped and the block body is kept only while switch
# KEY is on (`!KEY`: only while it is off).
# `{{PLUGIN_ROOT}}` becomes the plugin path with forward slashes so the main thread can Read
# DAG.md and the charter template. The always-on part gains a `## Guild switches changed`
# section listing key=value for every switch that differs from its shipped default; the procedure
# part prints nothing when procedure.default_mode is off.
# Missing file or any internal error prints nothing and exits 0 (never blocks a session).
# Windows PowerShell 5.1 compatible syntax.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# The part of PATH after its last forward slash.
function Get-BaseName([string]$Path) {
    return $Path.Substring($Path.LastIndexOf([char]'/') + 1)
}

function Test-OpenMarker([string]$Marker) {
    return $Marker.Length -ge 8 -and $Marker.StartsWith('{{#if ', [System.StringComparison]::Ordinal) -and
        $Marker.EndsWith('}}', [System.StringComparison]::Ordinal)
}

# True when the block a `{{#if KEY}}` or `{{#if !KEY}}` marker opens is kept.
function Test-BlockKept([string]$Marker) {
    $key = $Marker.Substring(6, $Marker.Length - 8)
    $wanted = $true
    if ($key.StartsWith('!', [System.StringComparison]::Ordinal)) {
        $key = $key.Substring(1)
        $wanted = $false
    }
    return (Get-GuildSwitch $key) -eq $wanted
}

# The keep state a marker line sets: on after `{{/if}}`, the block decision after an opening
# marker; $null for a line that is not a marker.
function Get-MarkerState([string]$Marker) {
    if ($Marker -ceq '{{/if}}') { return $true }
    if (Test-OpenMarker $Marker) { return Test-BlockKept $Marker }
    return $null
}

# CONTENT rendered line by line, trailing newlines dropped as in `rendered=$(render_file ...)`.
function ConvertTo-RenderedText([string]$Content, [string]$RootForward) {
    $builder = New-Object System.Text.StringBuilder
    $keep = $true
    foreach ($line in (Split-GuildLines $Content)) {
        $state = Get-MarkerState (Remove-GuildCarriageReturn $line)
        if ($null -ne $state) { $keep = $state }
        elseif ($keep) { [void]$builder.Append($line.Replace('{{PLUGIN_ROOT}}', $RootForward)).Append([char]10) }
    }
    return $builder.ToString().TrimEnd([char]10)
}

function Get-SwitchesChangedSection {
    $changed = Get-GuildChangedKeys
    if ($changed -eq '') { return '' }
    return "`n## Guild switches changed`n`n" + $changed.Replace(' ', ', ') + "`n"
}

function Test-Suppressed([string]$Part) {
    return (Get-BaseName $Part) -ceq 'procedure.md' -and -not (Get-GuildSwitch 'procedure.default_mode')
}

# The text to print for PART; empty when nothing is printed.
function Get-SessionContext([string]$Part) {
    if ($Part -eq '') { $Part = 'context/always-on.md' }
    Import-GuildConfig
    if (Test-Suppressed $Part) { return '' }
    $root = Get-GuildPluginRoot
    if (-not [System.IO.File]::Exists($root + '/' + $Part)) { return '' }
    $rootForward = $root.Replace('\', '/')
    $text = (ConvertTo-RenderedText ($GUILD_UTF8.GetString([System.IO.File]::ReadAllBytes($root + '/' + $Part))) $rootForward) + "`n"
    if ((Get-BaseName $Part) -ceq 'always-on.md') { $text += Get-SwitchesChangedSection }
    return $text
}

try {
    . "$PSScriptRoot/lib/config.ps1"
    . "$PSScriptRoot/lib/payload.ps1"
    $part = ''
    if ($args.Count -gt 0) { $part = [string]$args[0] }
    Write-HookOutput (Get-SessionContext $part)
} catch {
    exit 0
}
exit 0
