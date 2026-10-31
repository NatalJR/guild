# SessionStart and UserPromptSubmit hook, PowerShell twin of render-agents.sh (the primary
# implementation; the harness runs this one only where no Git Bash is found): renders the
# per-agent plugin options (install prompt or /config) into the agent frontmatter. For each
# agent, CLAUDE_PLUGIN_OPTION_<AGENT>_MODEL and CLAUDE_PLUGIN_OPTION_<AGENT>_EFFORT, when set to
# an allowlisted value that differs from the `model:` / `effort:` line of
# <plugin root>/agents/<agent>.md, replace that line in place; nothing else in the file
# changes. Unset or invalid values are ignored. Prints one notice line only when a file changed
# (the harness injects stdout as context), listing the agents rendered. Writes only inside
# agents/. An agent whose rewrite fails is skipped and the others still render; any other
# internal error prints nothing. Always exits 0 (never blocks a session or a prompt).
# Windows PowerShell 5.1 compatible syntax.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ALLOWED = @{
    model = @('haiku', 'sonnet', 'opus', 'fable', 'inherit')
    effort = @('low', 'medium', 'high', 'xhigh', 'max')
}
$FILE_UTF8 = New-Object System.Text.UTF8Encoding -ArgumentList $false, $false

# The Claude Directory validator refuses a variable name assembled at run time, so every option
# variable name below is spelled out in full.
# Agent name to CLAUDE_PLUGIN_OPTION_<AGENT>_MODEL, empty when unset.
$MODEL_OPTIONS = [ordered]@{
    investigator = [string][System.Environment]::GetEnvironmentVariable('CLAUDE_PLUGIN_OPTION_INVESTIGATOR_MODEL')
    builder = [string][System.Environment]::GetEnvironmentVariable('CLAUDE_PLUGIN_OPTION_BUILDER_MODEL')
    architect = [string][System.Environment]::GetEnvironmentVariable('CLAUDE_PLUGIN_OPTION_ARCHITECT_MODEL')
    reviewer = [string][System.Environment]::GetEnvironmentVariable('CLAUDE_PLUGIN_OPTION_REVIEWER_MODEL')
    security = [string][System.Environment]::GetEnvironmentVariable('CLAUDE_PLUGIN_OPTION_SECURITY_MODEL')
    scribe = [string][System.Environment]::GetEnvironmentVariable('CLAUDE_PLUGIN_OPTION_SCRIBE_MODEL')
}
# Agent name to CLAUDE_PLUGIN_OPTION_<AGENT>_EFFORT, empty when unset.
$EFFORT_OPTIONS = [ordered]@{
    investigator = [string][System.Environment]::GetEnvironmentVariable('CLAUDE_PLUGIN_OPTION_INVESTIGATOR_EFFORT')
    builder = [string][System.Environment]::GetEnvironmentVariable('CLAUDE_PLUGIN_OPTION_BUILDER_EFFORT')
    architect = [string][System.Environment]::GetEnvironmentVariable('CLAUDE_PLUGIN_OPTION_ARCHITECT_EFFORT')
    reviewer = [string][System.Environment]::GetEnvironmentVariable('CLAUDE_PLUGIN_OPTION_REVIEWER_EFFORT')
    security = [string][System.Environment]::GetEnvironmentVariable('CLAUDE_PLUGIN_OPTION_SECURITY_EFFORT')
    scribe = [string][System.Environment]::GetEnvironmentVariable('CLAUDE_PLUGIN_OPTION_SCRIBE_EFFORT')
}
# The agents, in render order: the option tables above define the set.
$AGENTS = @($MODEL_OPTIONS.Keys)

# AGENT SETTING: the plugin option for SETTING (model or effort), empty when unset.
function Get-AgentOption([string]$Agent, [string]$Setting) {
    if ($Setting -eq 'model') { return [string]$MODEL_OPTIONS[$Agent] }
    if ($Setting -eq 'effort') { return [string]$EFFORT_OPTIONS[$Agent] }
    return ''
}

# LINES: index of the closing frontmatter line (the last line when unclosed), -1 without one.
function Get-FrontmatterEnd([string[]]$Lines) {
    if ($Lines[0].Replace([string][char]13, '') -cne '---') { return -1 }
    for ($index = 1; $index -lt $Lines.Length; $index++) {
        if ($Lines[$index] -ceq '---') { return $index }
    }
    return $Lines.Length - 1
}

# LINES END SETTING: the value of the first `SETTING:` frontmatter line, empty when absent.
function Get-FrontmatterValue([string[]]$Lines, [int]$End, [string]$Setting) {
    for ($index = 0; $index -le $End; $index++) {
        if ($Lines[$index].StartsWith($Setting + ':', [System.StringComparison]::Ordinal)) {
            return $Lines[$index].Substring($Setting.Length + 1).TrimStart(' ').Replace([string][char]13, '')
        }
    }
    return ''
}

# AGENT SETTING CURRENT: the option value when allowed and CURRENT exists, else CURRENT.
function Get-WantedValue([string]$Agent, [string]$Setting, [string]$Current) {
    $option = Get-AgentOption $Agent $Setting
    if ($Current -ne '' -and $ALLOWED[$Setting] -ccontains $option) { return $option }
    return $Current
}

# LINES END SETTING VALUE: replaces every `SETTING:` frontmatter line with `SETTING: VALUE`, in
# place.
function Set-FrontmatterLine([string[]]$Lines, [int]$End, [string]$Setting, [string]$Value) {
    for ($index = 0; $index -le $End; $index++) {
        if ($Lines[$index].StartsWith($Setting + ':', [System.StringComparison]::Ordinal)) { $Lines[$index] = $Setting + ': ' + $Value }
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
    foreach ($setting in @('model', 'effort')) {
        if (Update-FrontmatterSetting $Lines $End $Agent $setting $values) { $changed = $true }
    }
    if (-not $changed) { return '' }
    return $Agent + ' model=' + $values['model'] + ' effort=' + $values['effort']
}

# LINES END AGENT SETTING VALUES: stores the wanted SETTING value in VALUES and, when it differs
# from the frontmatter, rewrites the SETTING line; true when it did.
function Update-FrontmatterSetting([string[]]$Lines, [int]$End, [string]$Agent, [string]$Setting, [hashtable]$Values) {
    $current = Get-FrontmatterValue $Lines $End $Setting
    $Values[$Setting] = Get-WantedValue $Agent $Setting $current
    if ($Values[$Setting] -ceq $current) { return $false }
    Set-FrontmatterLine $Lines $End $Setting $Values[$Setting]
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

# ROOT: true when ROOT is non-empty and its hooks directory exists; like its sh twin, the hook
# does nothing otherwise.
function Test-PluginRootPresent([string]$Root) {
    return ($Root -ne '') -and [System.IO.Directory]::Exists($Root + '/hooks')
}

try {
    $root = [string][System.Environment]::GetEnvironmentVariable('CLAUDE_PLUGIN_ROOT')
    if (-not (Test-PluginRootPresent $root)) { exit 0 }
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
    $directory = Join-Path $root 'agents'
    $rendered = @(@(foreach ($agent in $AGENTS) { Get-RenderedAgent $directory $agent }) | Where-Object { $_ -ne '' })
    if ($rendered.Count -gt 0) {
        Write-HookOutput ('GUILD AGENTS RENDERED: ' + ($rendered -join '; ') + '. Run the reload-plugins command to apply.' + "`n")
    }
} catch {
    exit 0
}
exit 0
