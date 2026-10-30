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

try {
    if ([string]$env:CLAUDE_PLUGIN_ROOT -eq '') { exit 0 }
    . "$env:CLAUDE_PLUGIN_ROOT\hooks\lib\payload.ps1"
    . "$env:CLAUDE_PLUGIN_ROOT\hooks\lib\config.ps1"
    $status = Invoke-ReceiptCheck
} catch {
    $status = 0
}
exit $status
