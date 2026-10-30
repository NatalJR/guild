# SessionStart and UserPromptSubmit hook, PowerShell twin of render-agents.sh (the primary
# implementation; the harness runs this one only where no Git Bash is found): renders the
# per-agent plugin options (install prompt or /config) into the agent frontmatter. For each
# agent, CLAUDE_PLUGIN_OPTION_<AGENT>_MODEL and CLAUDE_PLUGIN_OPTION_<AGENT>_EFFORT, when set to
# an allowlisted value that differs from the `model:` / `effort:` line of
# ${CLAUDE_PLUGIN_ROOT}/agents/<agent>.md, replace that line in place; nothing else in the file
# changes. Unset or invalid values are ignored. Prints one notice line only when a file changed
# (the harness injects stdout as context), listing the agents rendered. Writes only inside
# agents/. An agent whose rewrite fails is skipped and the others still render; any other
# internal error prints nothing. Always exits 0 (never blocks a session or a prompt).
# Windows PowerShell 5.1 compatible syntax.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$AGENTS = @('investigator', 'builder', 'architect', 'reviewer', 'security', 'scribe')
$ALLOWED = @{
    model = @('haiku', 'sonnet', 'opus', 'fable', 'inherit')
    effort = @('low', 'medium', 'high', 'xhigh', 'max')
}
$FILE_UTF8 = New-Object System.Text.UTF8Encoding -ArgumentList $false, $false

# AGENT KEY: the plugin option for KEY (model or effort), empty when unset.
function Get-AgentOption([string]$Agent, [string]$Key) {
    $name = 'CLAUDE_PLUGIN_OPTION_' + $Agent.ToUpperInvariant() + '_' + $Key.ToUpperInvariant()
    $value = [System.Environment]::GetEnvironmentVariable($name)
    if ($null -eq $value) { return '' }
    return $value
}

# LINES: index of the closing frontmatter line (the last line when unclosed), -1 without one.
function Get-FrontmatterEnd([string[]]$Lines) {
    if ($Lines[0].Replace([string][char]13, '') -cne '---') { return -1 }
    for ($index = 1; $index -lt $Lines.Length; $index++) {
        if ($Lines[$index] -ceq '---') { return $index }
    }
    return $Lines.Length - 1
}

# LINES END KEY: the value of the first `KEY:` frontmatter line, empty when absent.
function Get-FrontmatterValue([string[]]$Lines, [int]$End, [string]$Key) {
    for ($index = 0; $index -le $End; $index++) {
        if ($Lines[$index].StartsWith($Key + ':', [System.StringComparison]::Ordinal)) {
            return $Lines[$index].Substring($Key.Length + 1).TrimStart(' ').Replace([string][char]13, '')
        }
    }
    return ''
}

# AGENT KEY CURRENT: the option value when allowed and CURRENT exists, else CURRENT.
function Get-WantedValue([string]$Agent, [string]$Key, [string]$Current) {
    $option = Get-AgentOption $Agent $Key
    if ($Current -ne '' -and $ALLOWED[$Key] -ccontains $option) { return $option }
    return $Current
}

# LINES END KEY VALUE: replaces every `KEY:` frontmatter line with `KEY: VALUE`, in place.
function Set-FrontmatterLine([string[]]$Lines, [int]$End, [string]$Key, [string]$Value) {
    for ($index = 0; $index -le $End; $index++) {
        if ($Lines[$index].StartsWith($Key + ':', [System.StringComparison]::Ordinal)) { $Lines[$index] = $Key + ': ' + $Value }
    }
}

# PATH LINES: writes the LF-joined lines through a sibling temp file.
function Write-AgentFile([string]$Path, [string[]]$Lines) {
    $temp = $Path + '.render'
    try {
        [System.IO.File]::WriteAllBytes($temp, $FILE_UTF8.GetBytes($Lines -join [string][char]10))
        Move-Item -LiteralPath $temp -Destination $Path -Force
    } catch {
        if ([System.IO.File]::Exists($temp)) { [System.IO.File]::Delete($temp) }
        throw
    }
}

# DIRECTORY AGENT: rewrites DIRECTORY/AGENT.md when an option differs; the change summary, empty
# when nothing changed.
function Update-Agent([string]$Directory, [string]$Agent) {
    $path = Join-Path $Directory ($Agent + '.md')
    if (-not [System.IO.File]::Exists($path)) { return '' }
    $lines = $FILE_UTF8.GetString([System.IO.File]::ReadAllBytes($path)).Split([char]10)
    $end = Get-FrontmatterEnd $lines
    if ($end -lt 0) { return '' }
    $summary = Update-FrontmatterLines $lines $end $Agent
    if ($summary -ne '') { Write-AgentFile $path $lines }
    return $summary
}

# LINES END AGENT: sets the model and effort lines of LINES to their wanted values; the change
# summary, empty when neither line changed.
function Update-FrontmatterLines([string[]]$Lines, [int]$End, [string]$Agent) {
    $values = @{}
    $changed = $false
    foreach ($key in @('model', 'effort')) {
        if (Update-FrontmatterKey $Lines $End $Agent $key $values) { $changed = $true }
    }
    if (-not $changed) { return '' }
    return $Agent + ' model=' + $values['model'] + ' effort=' + $values['effort']
}

# LINES END AGENT KEY VALUES: stores the wanted KEY value in VALUES and, when it differs from the
# frontmatter, rewrites the KEY line; true when it did.
function Update-FrontmatterKey([string[]]$Lines, [int]$End, [string]$Agent, [string]$Key, [hashtable]$Values) {
    $current = Get-FrontmatterValue $Lines $End $Key
    $Values[$Key] = Get-WantedValue $Agent $Key $current
    if ($Values[$Key] -ceq $current) { return $false }
    Set-FrontmatterLine $Lines $End $Key $Values[$Key]
    return $true
}

# DIRECTORY AGENT: the change summary of Update-Agent; empty when the agent fails, so a failing
# agent is skipped and the others still render.
function Get-RenderedAgent([string]$Directory, [string]$Agent) {
    try {
        return Update-Agent $Directory $Agent
    } catch {
        return ''
    }
}

try {
    $root = [string]$env:CLAUDE_PLUGIN_ROOT
    if ($root -eq '') { exit 0 }
    . "$env:CLAUDE_PLUGIN_ROOT\hooks\lib\payload.ps1"
    $directory = Join-Path $root 'agents'
    $rendered = @(@(foreach ($agent in $AGENTS) { Get-RenderedAgent $directory $agent }) | Where-Object { $_ -ne '' })
    if ($rendered.Count -gt 0) {
        Write-HookOutput ('GUILD AGENTS RENDERED: ' + ($rendered -join '; ') + '. Run /reload-plugins to apply.' + "`n")
    }
} catch {
    exit 0
}
exit 0
