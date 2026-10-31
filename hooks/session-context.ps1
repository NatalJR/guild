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
    $switchName = $Marker.Substring(6, $Marker.Length - 8)
    $wanted = $true
    if ($switchName.StartsWith('!', [System.StringComparison]::Ordinal)) {
        $switchName = $switchName.Substring(1)
        $wanted = $false
    }
    return (Get-GuildSwitch $switchName) -eq $wanted
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
    $changed = Get-GuildChangedSwitches
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

# ROOT: true when ROOT is non-empty and names an existing directory; like its sh twin, the hook
# does nothing otherwise.
function Test-PluginRootPresent([string]$Root) {
    return ($Root -ne '') -and [System.IO.Directory]::Exists($Root)
}

try {
    $pluginRoot = [string][System.Environment]::GetEnvironmentVariable('CLAUDE_PLUGIN_ROOT')
    if (-not (Test-PluginRootPresent $pluginRoot)) { exit 0 }
Set-StrictMode -Version 2.0
$GUILD_SWITCHES = New-Object System.Collections.Specialized.OrderedDictionary -ArgumentList ([System.StringComparer]::Ordinal)
$GUILD_DEFAULTS = New-Object System.Collections.Specialized.OrderedDictionary -ArgumentList ([System.StringComparer]::Ordinal)
$GUILD_UTF8 = New-Object System.Text.UTF8Encoding -ArgumentList $false, $false
$GUILD_SPACE_CHARACTERS = [char[]]@(32, 9, 10, 11, 12, 13)
function Import-GuildConfig {
    $GUILD_SWITCHES.Clear()
    Read-GuildDefaultsFile
    $GUILD_DEFAULTS.Clear()
    foreach ($name in @($GUILD_SWITCHES.Keys)) { $GUILD_DEFAULTS[$name] = $GUILD_SWITCHES[$name] }
    $userHome = Get-GuildHome
    if ($userHome -ne '') { Read-GuildConfigFile ($userHome + '/.claude/guild.conf') 'override' }
    $projectDirectory = Get-GuildProjectDir
    if ($projectDirectory -ne '') { Read-GuildConfigFile ($projectDirectory + '/.claude/guild.conf') 'override' }
    Set-GuildOption
}
function Get-GuildSwitch([string]$Name) {
    return (Get-GuildTableValue $GUILD_SWITCHES $Name) -ceq 'on'
}
function Get-GuildChangedSwitches {
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($name in $GUILD_SWITCHES.Keys) {
        if ($GUILD_SWITCHES[$name] -cne (Get-GuildTableValue $GUILD_DEFAULTS $name)) { $names.Add($name) }
    }
    $sortedNames = $names.ToArray()
    [System.Array]::Sort($sortedNames, [System.StringComparer]::Ordinal)
    return ((@($sortedNames) | ForEach-Object { $_ + '=' + $GUILD_SWITCHES[$_] }) -join ' ')
}
function Split-GuildLines([string]$Text) {
    $lines = New-Object System.Collections.Generic.List[string]
    if ($Text -ne '') { $lines.AddRange([string[]]$Text.Split([char]10)) }
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -ceq '') { $lines.RemoveAt($lines.Count - 1) }
    return , $lines.ToArray()
}
function Get-GuildTrimmed([string]$Text) {
    return $Text.Trim($GUILD_SPACE_CHARACTERS)
}
function Get-GuildPluginRoot {
    return [string][System.Environment]::GetEnvironmentVariable('CLAUDE_PLUGIN_ROOT')
}
function Get-GuildProjectDir {
    return [string][System.Environment]::GetEnvironmentVariable('CLAUDE_PROJECT_DIR')
}
function Read-GuildDefaultsFile {
    Add-GuildConfigLine 'style.terse = on' 'declare'
    Add-GuildConfigLine 'rules.universal = on' 'declare'
    Add-GuildConfigLine 'procedure.default_mode = on' 'declare'
    Add-GuildConfigLine 'procedure.investigate_first = on' 'declare'
    Add-GuildConfigLine 'procedure.design_gate = on' 'declare'
    Add-GuildConfigLine 'procedure.sharding = on' 'declare'
    Add-GuildConfigLine 'procedure.cleanup_pass = on' 'declare'
    Add-GuildConfigLine 'review.norms = on' 'declare'
    Add-GuildConfigLine 'review.correctness = on' 'declare'
    Add-GuildConfigLine 'review.security = on' 'declare'
    Add-GuildConfigLine 'docs.sync = on' 'declare'
    Add-GuildConfigLine 'hooks.prompt_reinforce = on' 'declare'
    Add-GuildConfigLine 'hooks.emoji_scan = on' 'declare'
    Add-GuildConfigLine 'hooks.receipt_check = on' 'declare'
}
function Get-GuildHome {
    $userHome = [string][System.Environment]::GetEnvironmentVariable('HOME')
    if ($userHome -eq '') { $userHome = [System.Environment]::GetFolderPath('UserProfile') }
    return [string]$userHome
}
function Get-GuildTableValue($Table, [string]$Name) {
    if ($Table.Contains($Name)) { return [string]$Table[$Name] }
    return Get-GuildBuiltinDefault $Name
}
function Get-GuildBuiltinDefault([string]$Name) {
    if ($Name -ceq 'git.handling') { return 'off' }
    return 'on'
}
function Read-GuildConfigFile([string]$Path, [string]$Mode) {
    if (-not [System.IO.File]::Exists($Path)) { return }
    try {
        $text = $GUILD_UTF8.GetString([System.IO.File]::ReadAllBytes($Path))
    } catch {
        return
    }
    foreach ($line in (Split-GuildLines $text)) { Add-GuildConfigLine $line $Mode }
}
function Add-GuildConfigLine([string]$Line, [string]$Mode) {
    $text = Remove-GuildCarriageReturn $Line
    $equals = $text.IndexOf([char]'=')
    if ($equals -lt 0) { return }
    $name = Get-GuildTrimmed $text.Substring(0, $equals)
    $state = ConvertTo-GuildState (Get-GuildTrimmed $text.Substring($equals + 1))
    if (-not (Test-GuildName $name) -or $null -eq $state -or $name -ceq 'git.handling') { return }
    if (-not $GUILD_SWITCHES.Contains($name) -and $Mode -cne 'declare') { return }
    $GUILD_SWITCHES[$name] = $state
}
function Remove-GuildCarriageReturn([string]$Line) {
    if ($Line.EndsWith([string][char]13, [System.StringComparison]::Ordinal)) {
        return $Line.Substring(0, $Line.Length - 1)
    }
    return $Line
}
function Test-GuildName([string]$Name) {
    return $Name -cmatch '^[a-z][a-z0-9_.]*\z'
}
function ConvertTo-GuildState([string]$Value) {
    if ($Value -cmatch '^([Oo][Nn]|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss])\z') { return 'on' }
    if ($Value -cmatch '^([Oo][Ff][Ff]|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo])\z') { return 'off' }
    return $null
}
function Set-GuildOption {
    $option = [System.Environment]::GetEnvironmentVariable('CLAUDE_PLUGIN_OPTION_GIT_HANDLING')
    if ($null -eq $option) { return }
    if ($option -cmatch '^([Tt][Rr][Uu][Ee]|1|[Oo][Nn]|[Yy][Ee][Ss])\z') {
        $GUILD_SWITCHES['git.handling'] = 'on'
    } else {
        $GUILD_SWITCHES['git.handling'] = 'off'
    }
}
Set-StrictMode -Version 2.0
$PAYLOAD_UTF8 = New-Object System.Text.UTF8Encoding -ArgumentList $false, $false
$PAYLOAD_MARK = [string][char]31
$PAYLOAD_QUOTE = [string][char]30
$PAYLOAD_SPACE_CHARACTERS = [char[]]@(32, 9, 10, 11, 12, 13)
function Read-Payload {
    try {
        $buffer = New-Object System.IO.MemoryStream
        [Console]::OpenStandardInput().CopyTo($buffer)
        $text = $PAYLOAD_UTF8.GetString($buffer.ToArray())
    } catch {
        return ''
    }
    return $text.Replace([string][char]0, '').TrimEnd([char]10)
}
function Get-PayloadField([string]$Payload, [string]$Name) {
    if ($Name -cnotmatch '^[A-Za-z0-9_]+\z') { return $null }
    $fieldPattern = New-Object System.Text.RegularExpressions.Regex -ArgumentList ('"' + $Name + '"[ \t\v\f\r]*:[ \t\v\f\r]*"')
    foreach ($line in $Payload.Split([char]10)) {
        if ($fieldPattern.IsMatch($line)) { return ConvertFrom-PayloadValue ($fieldPattern.Replace($line, $PAYLOAD_MARK, 1)) }
    }
    return $null
}
function Test-PayloadBool([string]$Payload, [string]$Name) {
    $quoted = '"' + $Name + '"'
    return $Payload.Contains($quoted + ':true') -or $Payload.Contains($quoted + ': true')
}
function Get-FirstNonEmptyLine([string]$Text) {
    foreach ($line in $Text.Split([char]10)) {
        if ($line -cmatch '[^ \t\n\v\f\r]') { return $line.Trim($PAYLOAD_SPACE_CHARACTERS) }
    }
    return ''
}
function ConvertTo-AsciiLowerCase([string]$Text) {
    $characters = $Text.ToCharArray()
    for ($index = 0; $index -lt $characters.Length; $index++) {
        $code = [int]$characters[$index]
        if ($code -ge 65 -and $code -le 90) { $characters[$index] = [char]($code + 32) }
    }
    return -join $characters
}
function Write-HookOutput([string]$Text) {
    Write-HookStream ([Console]::OpenStandardOutput()) ($PAYLOAD_UTF8.GetBytes($Text))
}
function Write-HookError([string]$Text) {
    Write-HookStream ([Console]::OpenStandardError()) ($PAYLOAD_UTF8.GetBytes($Text))
}
function Write-HookStream([System.IO.Stream]$Stream, [byte[]]$Bytes) {
    $Stream.Write($Bytes, 0, $Bytes.Length)
    $Stream.Flush()
}
function ConvertFrom-PayloadValue([string]$Line) {
    $value = $Line.Substring($Line.IndexOf($PAYLOAD_MARK, [System.StringComparison]::Ordinal) + 1)
    $value = $value.Replace('\\', $PAYLOAD_MARK).Replace('\"', $PAYLOAD_QUOTE)
    $closingQuote = $value.IndexOf([char]34)
    if ($closingQuote -lt 0) { return $null }
    $value = $value.Substring(0, $closingQuote).Replace($PAYLOAD_QUOTE, '"').Replace('\/', '/')
    $value = $value.Replace('\n', [string][char]10).Replace('\t', [string][char]9).Replace('\r', '')
    return $value.Replace($PAYLOAD_MARK, '\').TrimEnd([char]10)
}
    $part = ''
    if ($args.Count -gt 0) { $part = [string]$args[0] }
    Write-HookOutput (Get-SessionContext $part)
} catch {
    exit 0
}
exit 0
