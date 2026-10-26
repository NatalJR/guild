# SubagentStop hook: enforces the receipt contract on a subagent's final message.
# Payload fields (confirmed by live trace): agent_type, last_assistant_message, stop_hook_active.
# Unknown shape -> no-op (exit 0).
$finalTextFields = @('last_assistant_message')
$receiptTokenPattern = '^(plan:|verify:|verified:|docs-sync\.|No issues\.|No match\.|\d+ findings\.|too-big\.|too-small\.|needs-confirm\.|ambiguous\.|regressed\.|need-map\.|blocked\.|not-security\.|security-scope\.|Defs:|Refs:|Callers:|Tests:|Sites:|Imports:)'
$locationPattern = '^\S+:\d+'

function Get-FinalText($payload) {
    foreach ($field in $finalTextFields) {
        $value = $payload.$field
        if ($value -is [string]) { return $value }
    }
    return $null
}

function Get-FirstNonEmptyLine([string] $text) {
    $lines = $text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    return ($lines | Select-Object -First 1)
}

function Test-ReceiptLine([string] $line) {
    return ($line -imatch $receiptTokenPattern) -or ($line -match $locationPattern)
}

try {
    $rawJson = $input | Out-String
    $payload = $rawJson | ConvertFrom-Json
    # Diagnostic: set GUILD_HOOK_TRACE=<file> to log the payload shape;
    # used once to confirm which field carries the subagent's final message.
    try {
        $tracePath = $env:GUILD_HOOK_TRACE
        if (-not [string]::IsNullOrEmpty($tracePath)) {
            $keys = $payload.PSObject.Properties.Name -join ','
            $rawExcerpt = $rawJson.Substring(0, [Math]::Min(200, $rawJson.Length))
            Add-Content -LiteralPath $tracePath -Value "$((Get-Date).ToString('o')) SubagentStop keys: $keys"
            Add-Content -LiteralPath $tracePath -Value $rawExcerpt
        }
    } catch { }
    # Scope: only guild agents carry the receipt contract; other agent types stop freely.
    $agentType = $payload.agent_type
    if (-not ($agentType -is [string]) -or -not $agentType.StartsWith('guild:', [StringComparison]::OrdinalIgnoreCase)) { exit 0 }
    # Already re-prompted once by this hook: let the subagent stop to avoid a block loop.
    if ($payload.stop_hook_active -eq $true) { exit 0 }
    $finalText = Get-FinalText $payload
    if ($null -eq $finalText) { exit 0 }
    $firstLine = Get-FirstNonEmptyLine $finalText
    if ($null -eq $firstLine) { exit 0 }
    $firstLine = $firstLine.Trim()
    if (Test-ReceiptLine $firstLine) { exit 0 }
    $excerpt = $firstLine.Substring(0, [Math]::Min(80, $firstLine.Length))
    [Console]::Error.WriteLine("Receipt contract: your final message must START with a terminal token or a receipt line (plan:, verify:, verified:, docs-sync., No issues., No match., N findings., too-big., too-small., needs-confirm., ambiguous., need-map., blocked., regressed., not-security., security-scope., or a path:line row). Got: `"$excerpt`". Rewrite your final message with the token on line 1 and stop again.")
    exit 2
} catch {
    # Swallowed on purpose: a malformed payload must never crash the session.
}
exit 0
