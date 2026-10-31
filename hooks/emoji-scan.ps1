# PostToolUse hook (Edit|Write), PowerShell twin of emoji-scan.sh (the primary implementation;
# the harness runs this one only where no Git Bash is found): rejects emoji in the file just
# written (owner rule).
# Skips empty paths, missing files, files outside CLAUDE_PROJECT_DIR, and binary types.
# Project containment is lexical: the path is resolved for `.` and `..` without following
# symlinks, so a symlink inside the project that points outside it is still scanned (read-only;
# only the line number of the first hit is reported).
# Detection is by code point over the file decoded as UTF-8: U+1F000-U+1FAFF, U+2600-U+27BF,
# U+2B00-U+2BFF, U+FE0F, U+200D. Unlike the byte-level sh twin, a malformed UTF-8 sequence
# decodes to U+FFFD and never counts as a hit.
# Switch: hooks.emoji_scan. A malformed payload or an internal error never blocks.
# Windows PowerShell 5.1 compatible syntax.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Generic binary types, tied to no project: images, fonts, archives, executables, model and
# database files, and PDF documents.
$BINARY_EXTENSIONS = ' .png .jpg .jpeg .gif .ico .onnx .sqlite .dll .exe .pdf .zip .woff .woff2 .ttf '
# Characters that can start an emoji: the BMP ranges, plus any high surrogate (decided by the
# code point it forms with the next character).
$EMOJI_CANDIDATE_PATTERN = '[\u200D\u2600-\u27BF\u2B00-\u2BFF\uFE0F\uD800-\uDBFF]'

function ConvertTo-ForwardSlash([string]$Path) {
    return $Path.Replace('\', '/')
}

# DIRECTORY as an absolute forward-slash path; $null when it is not an existing directory.
function Get-AbsoluteDirectory([string]$Directory) {
    try {
        if (-not [System.IO.Directory]::Exists($Directory)) { return $null }
        return ConvertTo-ForwardSlash ([System.IO.Path]::GetFullPath($Directory))
    } catch {
        return $null
    }
}

# PATH without one trailing forward slash.
function Remove-TrailingSlash([string]$Path) {
    if ($Path.EndsWith('/', [System.StringComparison]::Ordinal)) { return $Path.Substring(0, $Path.Length - 1) }
    return $Path
}

# Forward-slash path in, absolute path out with `.` and `..` resolved through its directory;
# $null when the directory does not exist.
function Get-CanonicalFilePath([string]$Path) {
    $slash = $Path.LastIndexOf([char]'/')
    $directory = '.'
    if ($slash -ge 0) { $directory = $Path.Substring(0, $slash) }
    if ($directory -eq '' -or $directory.EndsWith(':', [System.StringComparison]::Ordinal)) { $directory += '/' }
    $absolute = Get-AbsoluteDirectory $directory
    if ($null -eq $absolute) { return $null }
    return (Remove-TrailingSlash $absolute) + '/' + $Path.Substring($slash + 1)
}

# Case-insensitive prefix match against the project root, with a trailing slash.
function Test-InsideProject([string]$Path) {
    $projectDirectory = Get-GuildProjectDir
    if ($projectDirectory -eq '') { return $true }
    $projectRoot = Get-AbsoluteDirectory (ConvertTo-ForwardSlash $projectDirectory)
    if ($null -eq $projectRoot) { $projectRoot = ConvertTo-ForwardSlash $projectDirectory }
    $projectRoot = ConvertTo-AsciiLowerCase ((Remove-TrailingSlash $projectRoot) + '/')
    $candidate = Get-CanonicalFilePath $Path
    if ($null -eq $candidate) { return $false }
    return (ConvertTo-AsciiLowerCase $candidate).StartsWith($projectRoot, [System.StringComparison]::Ordinal)
}

function Test-BinaryExtension([string]$Path) {
    $fileName = $Path.Substring($Path.LastIndexOf([char]'/') + 1)
    $dot = $fileName.LastIndexOf([char]'.')
    if ($dot -lt 0) { return $false }
    return $BINARY_EXTENSIONS.Contains(' ' + (ConvertTo-AsciiLowerCase $fileName.Substring($dot)) + ' ')
}

# PATH FORWARD_PATH: the raw payload path and its forward-slash form.
function Test-Scannable([string]$Path, [string]$ForwardPath) {
    if ($Path -eq '' -or -not [System.IO.File]::Exists($Path)) { return $false }
    if (-not (Test-InsideProject $ForwardPath)) { return $false }
    return -not (Test-BinaryExtension $ForwardPath)
}

function Test-EmojiCodePoint([int]$CodePoint) {
    return ($CodePoint -ge 0x1F000 -and $CodePoint -le 0x1FAFF) -or ($CodePoint -ge 0x2600 -and $CodePoint -le 0x27BF) -or
        ($CodePoint -ge 0x2B00 -and $CodePoint -le 0x2BFF) -or $CodePoint -eq 0xFE0F -or $CodePoint -eq 0x200D
}

# The code point at INDEX of TEXT: a surrogate pair is combined, a lone surrogate stands alone.
function Get-CodePointAt([string]$Text, [int]$Index) {
    if ([char]::IsSurrogatePair($Text, $Index)) { return [char]::ConvertToUtf32($Text, $Index) }
    return [int]$Text[$Index]
}

# The 1-based line of the first emoji in FILE; 0 when none.
function Get-FirstEmojiLine([string]$Path) {
    $text = $PAYLOAD_UTF8.GetString([System.IO.File]::ReadAllBytes($Path))
    foreach ($candidate in [regex]::Matches($text, $EMOJI_CANDIDATE_PATTERN)) {
        if (Test-EmojiCodePoint (Get-CodePointAt $text $candidate.Index)) {
            return $text.Substring(0, $candidate.Index).Split([char]10).Length
        }
    }
    return 0
}

# The exit status: 2 after printing the hit, 0 otherwise.
function Invoke-EmojiScan {
    Import-GuildConfig
    if (-not (Get-GuildSwitch 'hooks.emoji_scan')) { return 0 }
    $filePath = Get-PayloadField (Read-Payload) 'file_path'
    if ($null -eq $filePath) { return 0 }
    if (-not (Test-Scannable $filePath (ConvertTo-ForwardSlash $filePath))) { return 0 }
    $hitLine = Get-FirstEmojiLine $filePath
    if ($hitLine -eq 0) { return 0 }
    Write-HookError ('Emoji found in ' + $filePath + ' at line ' + $hitLine + ' (first hit). Owner rule: no emoji in any committed file; write severity/status markers as words. Remove it.' + "`n")
    return 2
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
    $status = Invoke-EmojiScan
} catch {
    $status = 0
}
exit $status
