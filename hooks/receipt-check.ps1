# SubagentStop hook, PowerShell twin of receipt-check.sh (the primary implementation; the
# harness runs this one only where no Git Bash is found): enforces the receipt contract on a
# subagent's final message.
# Payload fields (confirmed by live trace): agent_type, last_assistant_message, stop_hook_active.
# Unknown shape -> no-op (exit 0). Switch: hooks.receipt_check.
# Matching follows `LC_ALL=C grep -i -E`: the line is ASCII-lowercased and the token pattern is
# written in lowercase; the excerpt is the first 80 bytes, as GNU `cut -c` takes them.
# A malformed payload or an internal error never blocks.
# Windows PowerShell 5.1 compatible syntax.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RECEIPT_MARKER_PATTERN = '^(plan:|verify:|verified:|docs-sync\.|no issues\.|no match\.|[0-9]+ findings\.|too-big\.|too-small\.|needs-confirm\.|ambiguous\.|regressed\.|need-map\.|blocked\.|not-security\.|security-scope\.|defs:|refs:|callers:|tests:|sites:|imports:)'
$LOCATION_PATTERN = '^[^ \t\n\v\f\r]+:[0-9]+'
$EXCERPT_BYTES = 80
$REJECT_PREFIX = 'Receipt contract: your final message must START with a terminal token or a receipt line (plan:, verify:, verified:, docs-sync., No issues., No match., N findings., too-big., too-small., needs-confirm., ambiguous., need-map., blocked., regressed., not-security., security-scope., or a path:line row). Got: "'
$REJECT_SUFFIX = '". Rewrite your final message with the token on line 1 and stop again.' + "`n"

function Add-Bytes([System.IO.MemoryStream]$Buffer, [byte[]]$Bytes) {
    $Buffer.Write($Bytes, 0, $Bytes.Length)
}

# The first COUNT bytes of TEXT encoded as UTF-8 (a multibyte character may be cut).
function Get-LeadingBytes([string]$Text, [int]$Count) {
    $bytes = $PAYLOAD_UTF8.GetBytes($Text)
    if ($bytes.Length -le $Count) { return , $bytes }
    $leading = New-Object byte[] $Count
    [System.Array]::Copy($bytes, $leading, $Count)
    return , $leading
}

function Test-GuildAgent([string]$AgentType) {
    return $AgentType -cmatch '^[Gg][Uu][Ii][Ll][Dd]:'
}

# Scope: only guild agents carry the receipt contract, and a stop this hook already
# re-prompted once (stop_hook_active) goes through to avoid a block loop.
function Test-InScope([string]$Payload) {
    $agentType = Get-PayloadField $Payload 'agent_type'
    if ($null -eq $agentType) { return $false }
    return (Test-GuildAgent $agentType) -and -not (Test-PayloadBool $Payload 'stop_hook_active')
}

function Test-ReceiptLine([string]$Line) {
    if ([regex]::IsMatch((ConvertTo-AsciiLowerCase $Line), $RECEIPT_MARKER_PATTERN)) { return $true }
    return [regex]::IsMatch($Line, $LOCATION_PATTERN)
}

function Write-Rejection([string]$Line) {
    $message = New-Object System.IO.MemoryStream
    Add-Bytes $message ($PAYLOAD_UTF8.GetBytes($REJECT_PREFIX))
    Add-Bytes $message (Get-LeadingBytes $Line $EXCERPT_BYTES)
    Add-Bytes $message ($PAYLOAD_UTF8.GetBytes($REJECT_SUFFIX))
    Write-HookStream ([Console]::OpenStandardError()) ($message.ToArray())
}

# The exit status: 2 after printing the rejection, 0 otherwise.
function Invoke-ReceiptCheck {
    Import-GuildConfig
    if (-not (Get-GuildSwitch 'hooks.receipt_check')) { return 0 }
    $payload = Read-Payload
    if (-not (Test-InScope $payload)) { return 0 }
    $firstLine = Get-FinalFirstLine $payload
    if ($firstLine -eq '' -or (Test-ReceiptLine $firstLine)) { return 0 }
    Write-Rejection $firstLine
    return 2
}

# The first non-empty line of the subagent's final message; empty when the field is absent.
function Get-FinalFirstLine([string]$Payload) {
    $finalText = Get-PayloadField $Payload 'last_assistant_message'
    if ($null -eq $finalText) { return '' }
    return Get-FirstNonEmptyLine $finalText
}

# ROOT: true when ROOT is non-empty and its hooks directory exists; like its sh twin, the hook
# does nothing otherwise.
function Test-PluginRootPresent([string]$Root) {
    return ($Root -ne '') -and [System.IO.Directory]::Exists($Root + '/hooks')
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
    $status = Invoke-ReceiptCheck
} catch {
    $status = 0
}
exit $status
