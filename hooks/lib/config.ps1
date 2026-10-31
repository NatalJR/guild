# Guild switch table (dot-sourced by the guild PowerShell hooks; twin of config.sh, which is the
# primary implementation and the reference for every rule below).
# Sources, later wins: <plugin root>/config/defaults.conf, ~/.claude/guild.conf,
# <project>/.claude/guild.conf. Missing or unreadable files are skipped silently.
# Grammar per line: blank or `#` comment ignored; otherwise `name = value`, optional spaces
# around `=`, names matching ^[a-z][a-z0-9_.]*$, values on|off|true|false|yes|no in any case.
# Any other line (inline comments included) is ignored silently. The defaults file declares the
# known switches; a switch the defaults file does not declare is ignored in the user and project
# files and reads as on. Lines are only matched against that grammar, never expanded or executed.
# git.handling is not a conf switch: a line for it is ignored in every file, the defaults file
# included. The plugin option CLAUDE_PLUGIN_OPTION_GIT_HANDLING (install prompt or /config) is
# its only source: true|1|on|yes in any case is on, any other value is off, unset reads as off.
# The defaults file is read from CLAUDE_PLUGIN_ROOT only; when it is unset no defaults file is
# read (the hooks exit before dot-sourcing this file in that case). The release build compiles
# the defaults in: it replaces that read with one declare line per defaults file entry.
# The home directory is HOME, as in the sh twin; when HOME is unset (the usual case on Windows
# outside Git Bash) it is the user profile directory, so ~/.claude/guild.conf is still read.
# Every comparison is ordinal and every case fold is ASCII-only, as in the C locale.
# Windows PowerShell 5.1 compatible syntax.
Set-StrictMode -Version 2.0

$GUILD_SWITCHES = New-Object System.Collections.Specialized.OrderedDictionary -ArgumentList ([System.StringComparer]::Ordinal)
$GUILD_DEFAULTS = New-Object System.Collections.Specialized.OrderedDictionary -ArgumentList ([System.StringComparer]::Ordinal)
$GUILD_UTF8 = New-Object System.Text.UTF8Encoding -ArgumentList $false, $false
# [[:space:]] in the C locale.
$GUILD_SPACE_CHARACTERS = [char[]]@(32, 9, 10, 11, 12, 13)

# Fills GUILD_SWITCHES: name -> on|off, one entry per switch, in declaration order.
# GUILD_DEFAULTS keeps the same table as declared by the defaults file alone.
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

# True when switch NAME is on. A switch with no entry takes its built-in default.
function Get-GuildSwitch([string]$Name) {
    return (Get-GuildTableValue $GUILD_SWITCHES $Name) -ceq 'on'
}

# The name=on / name=off entries whose value differs from the shipped default, sorted by name,
# space separated; empty when every switch holds its default.
function Get-GuildChangedSwitches {
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($name in $GUILD_SWITCHES.Keys) {
        if ($GUILD_SWITCHES[$name] -cne (Get-GuildTableValue $GUILD_DEFAULTS $name)) { $names.Add($name) }
    }
    $sortedNames = $names.ToArray()
    [System.Array]::Sort($sortedNames, [System.StringComparer]::Ordinal)
    return ((@($sortedNames) | ForEach-Object { $_ + '=' + $GUILD_SWITCHES[$_] }) -join ' ')
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

# Each reader names its variable literally: the Claude Directory validator refuses a variable
# name assembled at run time, so there is no generic reader that takes the name.
function Get-GuildPluginRoot {
    return [string][System.Environment]::GetEnvironmentVariable('CLAUDE_PLUGIN_ROOT')
}

# The project directory from CLAUDE_PROJECT_DIR; empty when unset.
function Get-GuildProjectDir {
    return [string][System.Environment]::GetEnvironmentVariable('CLAUDE_PROJECT_DIR')
}

# The defaults file under the plugin root; skipped when CLAUDE_PLUGIN_ROOT is unset.
function Read-GuildDefaultsFile {
    # Release build anchor: the only code line naming the defaults file, holding the whole read so
    # the generated declare lines replace all of it. Rewriting it or adding a second such line
    # breaks the release build.
    if ((Get-GuildPluginRoot) -ne '') { Read-GuildConfigFile ((Get-GuildPluginRoot) + '/config/defaults.conf') 'declare' }
}

function Get-GuildHome {
    $userHome = [string][System.Environment]::GetEnvironmentVariable('HOME')
    if ($userHome -eq '') { $userHome = [System.Environment]::GetFolderPath('UserProfile') }
    return [string]$userHome
}

# TABLE NAME: NAME's state in TABLE, else its built-in default.
function Get-GuildTableValue($Table, [string]$Name) {
    if ($Table.Contains($Name)) { return [string]$Table[$Name] }
    return Get-GuildBuiltinDefault $Name
}

# Built-in defaults for a switch no defaults file declares: git.handling is opt-in, the rest on.
function Get-GuildBuiltinDefault([string]$Name) {
    if ($Name -ceq 'git.handling') { return 'off' }
    return 'on'
}

# FILE MODE: applies every valid line; MODE declare accepts new switches, override only known ones.
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
    # git.handling comes from the plugin option only.
    if (-not (Test-GuildName $name) -or $null -eq $state -or $name -ceq 'git.handling') { return }
    if (-not $GUILD_SWITCHES.Contains($name) -and $Mode -cne 'declare') { return }
    $GUILD_SWITCHES[$name] = $state
}

# LINE without one trailing carriage return.
function Remove-GuildCarriageReturn([string]$Line) {
    if ($Line.EndsWith([string][char]13, [System.StringComparison]::Ordinal)) {
        return $Line.Substring(0, $Line.Length - 1)
    }
    return $Line
}

function Test-GuildName([string]$Name) {
    return $Name -cmatch '^[a-z][a-z0-9_.]*\z'
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
