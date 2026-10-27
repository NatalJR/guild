# Guild switch table (dot-sourced by the guild PowerShell hooks; twin of config.sh, which is the
# primary implementation and the reference for every rule below).
# Sources, later wins: <plugin root>/config/defaults.conf, ~/.claude/guild.conf,
# <project>/.claude/guild.conf. Missing or unreadable files are skipped silently.
# Grammar per line: blank or `#` comment ignored; otherwise `key = value`, optional spaces
# around `=`, keys matching ^[a-z][a-z0-9_.]*$, values on|off|true|false|yes|no in any case.
# Any other line (inline comments included) is ignored silently. The defaults file declares the
# known keys; a key the defaults file does not declare is ignored in the user and project files
# and reads as on. Lines are only matched against that grammar, never expanded or executed.
# git.handling is not a conf key: a line for it is ignored in every file, the defaults file
# included. The plugin option CLAUDE_PLUGIN_OPTION_GIT_HANDLING (install prompt or /config) is
# its only source: true|1|on|yes in any case is on, any other value is off, unset reads as off.
# When CLAUDE_PLUGIN_ROOT is unset the root is the directory two levels above this file.
# The home directory is HOME, as in the sh twin; when HOME is unset (the usual case on Windows
# outside Git Bash) it is the user profile directory, so ~/.claude/guild.conf is still read.
# Every comparison is ordinal and every case fold is ASCII-only, as in the C locale.
# Windows PowerShell 5.1 compatible syntax.
Set-StrictMode -Version 2.0

$GUILD_SWITCHES = New-Object System.Collections.Specialized.OrderedDictionary -ArgumentList ([System.StringComparer]::Ordinal)
$GUILD_DEFAULTS = New-Object System.Collections.Specialized.OrderedDictionary -ArgumentList ([System.StringComparer]::Ordinal)
$GUILD_FALLBACK_ROOT = [System.IO.Path]::GetFullPath($PSScriptRoot + '/../..')
$GUILD_UTF8 = New-Object System.Text.UTF8Encoding -ArgumentList $false, $false
# [[:space:]] in the C locale.
$GUILD_SPACE_CHARACTERS = [char[]]@(32, 9, 10, 11, 12, 13)

# Fills GUILD_SWITCHES: key -> on|off, one entry per key, in declaration order.
# GUILD_DEFAULTS keeps the same table as declared by the defaults file alone.
function Import-GuildConfig {
    $GUILD_SWITCHES.Clear()
    Read-GuildConfigFile ((Get-GuildPluginRoot) + '/config/defaults.conf') 'declare'
    $GUILD_DEFAULTS.Clear()
    foreach ($key in @($GUILD_SWITCHES.Keys)) { $GUILD_DEFAULTS[$key] = $GUILD_SWITCHES[$key] }
    $userHome = Get-GuildHome
    if ($userHome -ne '') { Read-GuildConfigFile ($userHome + '/.claude/guild.conf') 'override' }
    $projectDirectory = [string]$env:CLAUDE_PROJECT_DIR
    if ($projectDirectory -ne '') { Read-GuildConfigFile ($projectDirectory + '/.claude/guild.conf') 'override' }
    Set-GuildOption
}

# True when KEY is on. A key with no entry takes its built-in default.
function Get-GuildSwitch([string]$Key) {
    return (Get-GuildTableValue $GUILD_SWITCHES $Key) -ceq 'on'
}

# The key=on / key=off entries whose value differs from the shipped default, sorted by key,
# space separated; empty when every key holds its default.
function Get-GuildChangedKeys {
    $keys = New-Object System.Collections.Generic.List[string]
    foreach ($key in $GUILD_SWITCHES.Keys) {
        if ($GUILD_SWITCHES[$key] -cne (Get-GuildTableValue $GUILD_DEFAULTS $key)) { $keys.Add($key) }
    }
    $sortKeys = $keys.ToArray()
    [System.Array]::Sort($sortKeys, [System.StringComparer]::Ordinal)
    return ((@($sortKeys) | ForEach-Object { $_ + '=' + $GUILD_SWITCHES[$_] }) -join ' ')
}

# Splits TEXT the way a `while read -r line || [ -n "$line" ]` loop does: on LF only, a final
# line without LF kept, no empty line after a trailing LF. Carriage returns stay in the lines.
function Split-GuildLines([string]$Text) {
    $lines = New-Object System.Collections.Generic.List[string]
    if ($Text -ne '') { $lines.AddRange([string[]]$Text.Split([char]10)) }
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -ceq '') { $lines.RemoveAt($lines.Count - 1) }
    return , $lines.ToArray()
}

# TEXT without the C-locale whitespace around it.
function Get-GuildTrimmed([string]$Text) {
    return $Text.Trim($GUILD_SPACE_CHARACTERS)
}

function Get-GuildPluginRoot {
    $root = [string]$env:CLAUDE_PLUGIN_ROOT
    if ($root -eq '') { $root = $GUILD_FALLBACK_ROOT }
    return $root
}

function Get-GuildHome {
    $userHome = [string]$env:HOME
    if ($userHome -eq '') { $userHome = [System.Environment]::GetFolderPath('UserProfile') }
    return [string]$userHome
}

# TABLE KEY: KEY's state in TABLE, else its built-in default.
function Get-GuildTableValue($Table, [string]$Key) {
    if ($Table.Contains($Key)) { return [string]$Table[$Key] }
    return Get-GuildBuiltinDefault $Key
}

# Built-in defaults for a key no defaults file declares: git.handling is opt-in, the rest on.
function Get-GuildBuiltinDefault([string]$Key) {
    if ($Key -ceq 'git.handling') { return 'off' }
    return 'on'
}

# FILE MODE: applies every valid line; MODE declare accepts new keys, override only known ones.
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
    $key = Get-GuildTrimmed $text.Substring(0, $equals)
    $state = ConvertTo-GuildState (Get-GuildTrimmed $text.Substring($equals + 1))
    # git.handling comes from the plugin option only.
    if (-not (Test-GuildKey $key) -or $null -eq $state -or $key -ceq 'git.handling') { return }
    if (-not $GUILD_SWITCHES.Contains($key) -and $Mode -cne 'declare') { return }
    $GUILD_SWITCHES[$key] = $state
}

# LINE without one trailing carriage return.
function Remove-GuildCarriageReturn([string]$Line) {
    if ($Line.EndsWith([string][char]13, [System.StringComparison]::Ordinal)) {
        return $Line.Substring(0, $Line.Length - 1)
    }
    return $Line
}

function Test-GuildKey([string]$Key) {
    return $Key -cmatch '^[a-z][a-z0-9_.]*\z'
}

# on, off, or $null for a value outside the grammar.
function ConvertTo-GuildState([string]$Value) {
    if ($Value -cmatch '^([Oo][Nn]|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss])\z') { return 'on' }
    if ($Value -cmatch '^([Oo][Ff][Ff]|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo])\z') { return 'off' }
    return $null
}

# Maps the git handling plugin option, when set (even to an empty value), onto git.handling.
function Set-GuildOption {
    $option = [System.Environment]::GetEnvironmentVariable('CLAUDE_PLUGIN_OPTION_GIT_HANDLING')
    if ($null -eq $option) { return }
    if ($option -cmatch '^([Tt][Rr][Uu][Ee]|1|[Oo][Nn]|[Yy][Ee][Ss])\z') {
        $GUILD_SWITCHES['git.handling'] = 'on'
    } else {
        $GUILD_SWITCHES['git.handling'] = 'off'
    }
}
