# Hook contract suite for the PowerShell twins (hooks/*.ps1). Runs every shared case in
# tests/cases/*.cases (format at the top of each file) plus the coded cases that mirror
# tests/run.sh, and prints the same PASS/FAIL summary; exit 1 on any failure.
# Usage, from any directory: pwsh -NoProfile -File tests/run.ps1
# Each hook runs in a child process of the PowerShell running this script, so
# `powershell -NoProfile -File tests/run.ps1` checks Windows PowerShell 5.1 the same way.
# Library and config cases dot-source hooks/lib/*.ps1 in this process. Variables are removed
# with [NullString]::Value, since PowerShell turns $null into an empty string on the way to
# .NET; Windows PowerShell 5.1 cannot hold an empty value, so there the empty plugin option case
# exercises the unset path. check-context-size.sh has no twin and stays in tests/run.sh only.
# render-agents cases run against a scratch copy of agents/ (CLAUDE_PLUGIN_ROOT pointed at it),
# never the repository's files; Reset-Environment also clears every
# CLAUDE_PLUGIN_OPTION_<AGENT>_MODEL / _EFFORT. The hooks dot-source their libraries from
# $env:CLAUDE_PLUGIN_ROOT\hooks\lib only, so every scratch root a hook runs against also holds a
# copy of hooks/lib/.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$TestsDirectory = $PSScriptRoot
$RepoRoot = [System.IO.Path]::GetFullPath($PSScriptRoot + '/..')
$Hooks = Join-Path $RepoRoot 'hooks'
$Fixtures = Join-Path $TestsDirectory 'fixtures'
$FixtureProject = Join-Path $Fixtures 'project'
$FixtureHome = Join-Path $Fixtures 'home'
$PowerShellPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$Utf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false, $false
$NL = [string][char]10
$IsWindowsHost = [System.IO.Path]::DirectorySeparatorChar -eq [char]'\'
$Scratch = Join-Path ([System.IO.Path]::GetTempPath()) ('guild-tests-' + [guid]::NewGuid().ToString('N'))
$Passed = 0
$Failed = 0
$CaseName = ''
$ScratchSequence = 0

. (Join-Path $Hooks 'lib/payload.ps1')
. (Join-Path $Hooks 'lib/config.ps1')

# ---------------------------------------------------------------- harness

function Write-Line([string]$Text) {
    [Console]::Out.WriteLine($Text)
}

function Set-Case([string]$Name) {
    $script:CaseName = $Name
}

function Add-Pass {
    $script:Passed++
}

function Add-Failure([string]$Reason) {
    $script:Failed++
    Write-Line ('FAIL: ' + $script:CaseName + $NL + '      ' + $Reason)
}

function ConvertTo-ForwardSlash([string]$Path) {
    return $Path.Replace('\', '/')
}

# TEXT without its trailing newlines, as `$(cat ...)` leaves captured output.
function Remove-TrailingNewlines([string]$Text) {
    return $Text.TrimEnd([char]10)
}

function Join-CommandLine([string[]]$Arguments) {
    $quoted = foreach ($argument in $Arguments) {
        if ($argument -cmatch '^[A-Za-z0-9_./:\\-]+$') { $argument } else { '"' + $argument.Replace('"', '\"') + '"' }
    }
    return ($quoted -join ' ')
}

# HOOK PAYLOAD ARGUMENTS: runs hooks/HOOK.ps1 in a child PowerShell with PAYLOAD on stdin.
# The result carries Exit, Stdout and Stderr (UTF-8, trailing newlines dropped).
function Invoke-Hook([string]$Hook, [string]$Payload, [string[]]$Arguments = @()) {
    $process = [System.Diagnostics.Process]::Start((New-HookStart $Hook $Arguments))
    $stdout = New-Object System.IO.MemoryStream
    $stderr = New-Object System.IO.MemoryStream
    $copies = @($process.StandardOutput.BaseStream.CopyToAsync($stdout), $process.StandardError.BaseStream.CopyToAsync($stderr))
    Send-Payload $process $Payload
    $process.WaitForExit()
    foreach ($copy in $copies) { $copy.Wait() }
    return New-Object PSObject -Property @{
        Exit = $process.ExitCode
        Stdout = Remove-TrailingNewlines ($Utf8.GetString($stdout.ToArray()))
        Stderr = Remove-TrailingNewlines ($Utf8.GetString($stderr.ToArray()))
    }
}

function New-HookStart([string]$Hook, [string[]]$Arguments) {
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $PowerShellPath
    $start.Arguments = Join-CommandLine (@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Hooks ($Hook + '.ps1'))) + $Arguments)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    return $start
}

# Writes the payload bytes and closes stdin; a hook that exits without reading is fine.
function Send-Payload($Process, [string]$Payload) {
    $stdin = $Process.StandardInput.BaseStream
    try {
        $bytes = $Utf8.GetBytes($Payload)
        $stdin.Write($bytes, 0, $bytes.Length)
    } catch [System.IO.IOException] {
    } finally {
        try { $stdin.Close() } catch [System.IO.IOException] { }
    }
}

# HOOK EXIT PAYLOAD [STDERR_SUBSTRING]
function Assert-Exit([string]$Hook, [int]$Exit, [string]$Payload, [string]$StderrPart = '') {
    $run = Invoke-Hook $Hook $Payload
    if ($run.Exit -ne $Exit) { Add-Failure ('exit ' + $run.Exit + ', want ' + $Exit + '; stderr: ' + $run.Stderr); return }
    if (-not $run.Stderr.Contains($StderrPart)) { Add-Failure ('exit ' + $run.Exit + '; stderr lacks [' + $StderrPart + ']: ' + $run.Stderr); return }
    Add-Pass
}

# SUBSTRING HOOK [ARG]: runs a context hook with an empty payload.
function Assert-StdoutContains([string]$Wanted, [string]$Hook, [string[]]$Arguments = @()) {
    $run = Invoke-Hook $Hook '' $Arguments
    if (-not $run.Stdout.Contains($Wanted)) { Add-Failure ('exit ' + $run.Exit + '; stdout lacks [' + $Wanted + ']; stderr: ' + $run.Stderr); return }
    Add-Pass
}

function Assert-StdoutLacks([string]$Unwanted, [string]$Hook, [string[]]$Arguments = @()) {
    $run = Invoke-Hook $Hook '' $Arguments
    if ($run.Stdout.Contains($Unwanted)) { Add-Failure ('exit ' + $run.Exit + '; stdout contains [' + $Unwanted + ']'); return }
    Add-Pass
}

# WANT GOT
function Assert-Equal([string]$Want, [string]$Got) {
    if ($Got -cne $Want) { Add-Failure ('want [' + $Want + '] got [' + $Got + ']'); return }
    Add-Pass
}

# ---------------------------------------------------------------- shared case runner (tests/cases)

$CaseKinds = @('exit', 'stderr', 'stderr-equals', 'stdout', 'stdout-lacks', 'stdout-equals', 'stdout-under')

function New-CaseRecord {
    return @{
        Name = ''; Hook = ''; Part = $null; Payload = ''; Error = ''; AgentsCopy = ''
        UserConf = (New-Object System.Collections.Generic.List[string])
        ProjectConf = (New-Object System.Collections.Generic.List[string])
        Env = (New-Object System.Collections.Generic.List[string])
        Unset = (New-Object System.Collections.Generic.List[string])
        Expect = (New-Object System.Collections.Generic.List[object])
    }
}

# RECORD LINE: records one `field=value` line.
function Add-CaseField($Record, [string]$Line) {
    $equals = $Line.IndexOf([char]'=')
    $field = $Line
    $value = $Line
    if ($equals -ge 0) {
        $field = $Line.Substring(0, $equals)
        $value = $Line.Substring($equals + 1)
    }
    switch -CaseSensitive ($field) {
        'case' { $Record.Name = $value }
        'hook' { $Record.Hook = $value }
        'part' { $Record.Part = $value }
        'user-conf' { $Record.UserConf.Add($value) }
        'project-conf' { $Record.ProjectConf.Add($value) }
        'agents-copy' { $Record.AgentsCopy = $value }
        'env' { $Record.Env.Add($value) }
        'unset' { $Record.Unset.Add($value) }
        'payload' { $Record.Payload = $value }
        default {
            if ($CaseKinds -ccontains $field) { $Record.Expect.Add(@($field, $value)) } else { $Record.Error = 'unknown field [' + $field + ']' }
        }
    }
}

# FILE: the records of a case file, blank-line separated, `#` lines skipped.
function Read-CaseFile([string]$Path) {
    $records = New-Object System.Collections.Generic.List[object]
    $record = $null
    foreach ($rawLine in $Utf8.GetString([System.IO.File]::ReadAllBytes($Path)).Split([char]10)) {
        $line = Remove-GuildCarriageReturn $rawLine
        if ($line -eq '') {
            if ($null -ne $record) { $records.Add($record) }
            $record = $null
        } elseif (-not $line.StartsWith('#', [System.StringComparison]::Ordinal)) {
            if ($null -eq $record) { $record = New-CaseRecord }
            Add-CaseField $record $line
        }
    }
    if ($null -ne $record) { $records.Add($record) }
    return , $records.ToArray()
}

# VALUE with the case-file placeholders replaced.
function Expand-Placeholders([string]$Value) {
    $project = ConvertTo-ForwardSlash ([string]$env:CLAUDE_PROJECT_DIR)
    return $Value.Replace('%NL%', $NL).Replace('%FIXTURES%', (ConvertTo-ForwardSlash $Fixtures)).Replace('%PROJECT%', $project).Replace('%ROOT%', (ConvertTo-ForwardSlash $RepoRoot))
}

# RECORD: runs one record; empty when it passes, else the reason.
function Invoke-SharedCase($Record) {
    $failure = Get-RecordError $Record
    if ($failure -eq '') { $failure = Set-CaseEnvironment $Record }
    if ($failure -ne '') { return $failure }
    $arguments = @()
    if ($null -ne $Record.Part) { $arguments = @($Record.Part) }
    $run = Invoke-Hook $Record.Hook (Expand-Placeholders $Record.Payload) $arguments
    foreach ($expectation in $Record.Expect) {
        $miss = Test-Expectation $run $expectation[0] (Expand-Placeholders $expectation[1])
        if ($miss -ne '') { return $miss }
    }
    return ''
}

function Get-RecordError($Record) {
    if ($Record.Error -ne '') { return $Record.Error }
    if ($Record.Name -ne '' -and $Record.Hook -ne '' -and [System.IO.File]::Exists((Join-Path $Hooks ($Record.Hook + '.ps1')))) { return '' }
    return 'record needs case= and hook= naming an existing hook, got [' + $Record.Hook + ']'
}

# Setup order: user-conf, project-conf, env, unset. Empty when done, else the reason.
function Set-CaseEnvironment($Record) {
    if ($Record.UserConf.Count -gt 0) { Use-UserConf ($Record.UserConf -join $NL) }
    if ($Record.ProjectConf.Count -gt 0) { Use-ProjectConf ($Record.ProjectConf -join $NL) }
    $failure = Use-CaseAgentsCopy $Record.AgentsCopy
    if ($failure -ne '') { return $failure }
    foreach ($line in $Record.Env) {
        $equals = $line.IndexOf([char]'=')
        if ($equals -lt 1 -or -not (Test-VariableName $line.Substring(0, $equals))) { return 'env= needs NAME=value, got [' + $line + ']' }
        [System.Environment]::SetEnvironmentVariable($line.Substring(0, $equals), $line.Substring($equals + 1))
    }
    foreach ($name in $Record.Unset) {
        if (-not (Test-VariableName $name)) { return 'bad variable name [' + $name + ']' }
        [System.Environment]::SetEnvironmentVariable($name, [NullString]::Value)
    }
    return ''
}

function Test-VariableName([string]$Name) {
    return $Name -cmatch '^[A-Za-z_][A-Za-z0-9_]*\z'
}

# RUN KIND WANT: empty when the expectation holds, else the reason.
function Test-Expectation($Run, [string]$Kind, [string]$Want) {
    $met = switch -CaseSensitive ($Kind) {
        'exit' { [string]$Run.Exit -ceq $Want }
        'stderr' { $Run.Stderr.Contains($Want) }
        'stderr-equals' { $Run.Stderr -ceq $Want }
        'stdout' { $Run.Stdout.Contains($Want) }
        'stdout-lacks' { -not $Run.Stdout.Contains($Want) }
        'stdout-equals' { $Run.Stdout -ceq $Want }
        'stdout-under' { ($Utf8.GetByteCount($Run.Stdout) + 1) -lt [int]$Want }
    }
    if ($met) { return '' }
    $stdoutHead = ($Run.Stdout.Split([char]10) | Select-Object -First 3) -join $NL
    return $Kind + ' [' + $Want + '] not met; exit ' + $Run.Exit + '; stdout: ' + $stdoutHead + '; stderr: ' + $Run.Stderr
}

# FILE: runs every record of a case file, one counted case per record.
function Invoke-CaseFile([string]$Path) {
    $sequence = 0
    foreach ($record in (Read-CaseFile $Path)) {
        $sequence++
        $name = $record.Name
        if ($name -eq '') { $name = 'record ' + $sequence }
        Set-Case $name
        $snapshot = Get-EnvironmentSnapshot
        try {
            $reason = Invoke-SharedCase $record
        } catch {
            $reason = 'runner error: ' + $_.Exception.Message
        } finally {
            Restore-EnvironmentSnapshot $snapshot
        }
        if ($reason -eq '') { Add-Pass } else { Add-Failure $reason }
    }
}

function Get-EnvironmentSnapshot {
    $snapshot = @{}
    foreach ($entry in [System.Environment]::GetEnvironmentVariables().GetEnumerator()) { $snapshot[[string]$entry.Key] = [string]$entry.Value }
    return $snapshot
}

function Restore-EnvironmentSnapshot([hashtable]$Snapshot) {
    foreach ($name in @([System.Environment]::GetEnvironmentVariables().Keys)) {
        if (-not $Snapshot.ContainsKey([string]$name)) { [System.Environment]::SetEnvironmentVariable([string]$name, [NullString]::Value) }
    }
    foreach ($name in $Snapshot.Keys) { [System.Environment]::SetEnvironmentVariable($name, $Snapshot[$name]) }
}

# ---------------------------------------------------------------- environment

function New-ScratchDirectory {
    $script:ScratchSequence++
    $directory = Join-Path $Scratch ('case' + $script:ScratchSequence)
    [void][System.IO.Directory]::CreateDirectory((Join-Path $directory '.claude'))
    return $directory
}

# DIRECTORY LINES: writes DIRECTORY/.claude/guild.conf, one LF-terminated line each.
function Write-ConfFile([string]$Directory, [string[]]$Lines) {
    $text = ($Lines -join $NL) + $NL
    [System.IO.File]::WriteAllBytes((Join-Path $Directory '.claude/guild.conf'), $Utf8.GetBytes($text))
}

# CONTENT: points HOME at a scratch directory whose ~/.claude/guild.conf holds CONTENT.
function Use-UserConf([string]$Content) {
    $directory = New-ScratchDirectory
    Write-ConfFile $directory @($Content)
    $env:HOME = $directory
}

# CONTENT: points CLAUDE_PROJECT_DIR at a scratch project with CONTENT as its guild.conf.
function Use-ProjectConf([string]$Content) {
    $directory = New-ScratchDirectory
    Write-ConfFile $directory @($Content)
    Copy-Item -LiteralPath (Join-Path $FixtureProject 'emoji.md') -Destination (Join-Path $directory 'emoji.md')
    $env:CLAUDE_PROJECT_DIR = $directory
}

function Reset-Environment {
    $env:CLAUDE_PLUGIN_ROOT = $RepoRoot
    $env:CLAUDE_PROJECT_DIR = $FixtureProject
    $env:HOME = $FixtureHome
    [System.Environment]::SetEnvironmentVariable('CLAUDE_PLUGIN_OPTION_GIT_HANDLING', [NullString]::Value)
    Clear-AgentOptions
}

function Clear-AgentOptions {
    foreach ($agent in @('INVESTIGATOR', 'BUILDER', 'ARCHITECT', 'REVIEWER', 'SECURITY', 'SCRIBE')) {
        foreach ($key in @('MODEL', 'EFFORT')) {
            [System.Environment]::SetEnvironmentVariable('CLAUDE_PLUGIN_OPTION_' + $agent + '_' + $key, [NullString]::Value)
        }
    }
}

# ROOT: copies hooks/lib/ into the scratch plugin root ROOT, where the hooks dot-source it from.
function Copy-HookLibraries([string]$Root) {
    [void][System.IO.Directory]::CreateDirectory((Join-Path $Root 'hooks'))
    Copy-Item -LiteralPath (Join-Path $Hooks 'lib') -Destination (Join-Path $Root 'hooks/lib') -Recurse
}

# Points CLAUDE_PLUGIN_ROOT at a scratch root holding a copy of agents/; returns the root.
function Use-AgentsRoot {
    $directory = New-ScratchDirectory
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'agents') -Destination (Join-Path $directory 'agents') -Recurse
    Copy-HookLibraries $directory
    $env:CLAUDE_PLUGIN_ROOT = $directory
    return $directory
}

# VALUE: the agents-copy= setup; empty when done, else the reason.
function Use-CaseAgentsCopy([string]$Value) {
    if ($Value -eq '') { return '' }
    if ($Value -cne 'yes') { return 'agents-copy= takes yes, got [' + $Value + ']' }
    [void](Use-AgentsRoot)
    return ''
}

function Read-FileLines([string]$Path) {
    return , $Utf8.GetString([System.IO.File]::ReadAllBytes($Path)).Split([char]10)
}

# ROOT: every line ROOT/agents changed against the repository copy, as `<file> - <old line>`
# and `<file> + <new line>`, the old lines of a file first (diff order for one hunk).
function Get-AgentsChanges([string]$Root) {
    $changes = foreach ($original in [System.IO.Directory]::GetFiles((Join-Path $RepoRoot 'agents'), '*.md')) {
        $name = [System.IO.Path]::GetFileName($original)
        Get-LineChanges $name (Read-FileLines $original) (Read-FileLines (Join-Path $Root ('agents/' + $name)))
    }
    return (@($changes) -join $NL)
}

# NAME OLD NEW: the changed lines of one file; a line count mismatch is reported as such.
function Get-LineChanges([string]$Name, [string[]]$Old, [string[]]$New) {
    if ($Old.Length -ne $New.Length) { return $Name + ' line count ' + $Old.Length + ' -> ' + $New.Length }
    $indexes = @(for ($index = 0; $index -lt $Old.Length; $index++) { if ($Old[$index] -cne $New[$index]) { $index } })
    foreach ($index in $indexes) { $Name + ' - ' + $Old[$index] }
    foreach ($index in $indexes) { $Name + ' + ' + $New[$index] }
}

function Get-ByteSize([string]$Path) {
    return (New-Object System.IO.FileInfo -ArgumentList $Path).Length
}

function ConvertTo-JsonBackslashes([string]$Text) {
    return $Text.Replace('\', '\\')
}

# ---------------------------------------------------------------- payload builders

function New-FilePayload([string]$Path) {
    return '{"session_id":"s","hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":"' + $Path + '","content":"x"},"tool_response":{"filePath":"' + $Path + '"}}'
}

# AGENT MESSAGE: MESSAGE is already JSON-escaped.
function New-ReceiptPayload([string]$Agent, [string]$Message) {
    return '{"session_id":"s","hook_event_name":"SubagentStop","stop_hook_active":false,"agent_type":"' + $Agent + '","last_assistant_message":"' + $Message + '"}'
}

function Get-FieldOf([string]$Payload, [string]$Name) {
    $value = Get-PayloadField $Payload $Name
    if ($null -eq $value) { return '<absent>' }
    return $value
}

function Get-BoolOf([string]$Payload, [string]$Name) {
    if (Test-PayloadBool $Payload $Name) { return 'true' }
    return 'false'
}

function Get-SwitchState([string]$Key) {
    Import-GuildConfig
    if (Get-GuildSwitch $Key) { return 'on' }
    return 'off'
}

function Get-ChangedKeys {
    Import-GuildConfig
    return Get-GuildChangedSwitches
}

function Get-OnSwitchCount {
    Import-GuildConfig
    $count = 0
    foreach ($value in $GUILD_SWITCHES.Values) { if ($value -ceq 'on') { $count++ } }
    return [string]$count
}

# FROM TO [SKIP]: the defaults.conf lines ending in `= FROM`, rewritten to `= TO`,
# skipping lines that match SKIP (sed -n -e '/SKIP/d' -e 's/= FROM$/= TO/p').
function Get-RewrittenDefaults([string]$From, [string]$To, [string]$Skip = '') {
    $lines = foreach ($line in (Split-GuildLines ($Utf8.GetString([System.IO.File]::ReadAllBytes((Join-Path $RepoRoot 'config/defaults.conf')))))) {
        if ($Skip -ne '' -and $line -cmatch $Skip) { continue }
        if ($line -cmatch ('= ' + $From + '$')) { $line -creplace ('= ' + $From + '$'), ('= ' + $To) }
    }
    return ($lines -join $NL)
}

$TAB = [string][char]9
$Backslash = '\'

try {
    [void][System.IO.Directory]::CreateDirectory($Scratch)
    Reset-Environment

    # ------------------------------------------------------------ payload library

    Set-Case 'payload_field: escaped quote'
    Assert-Equal 'x"y' (Get-FieldOf '{"a":"x\"y"}' 'a')
    Set-Case 'payload_field: escaped backslash'
    Assert-Equal 'x\y' (Get-FieldOf '{"a":"x\\y"}' 'a')
    Set-Case 'payload_field: escaped newline'
    Assert-Equal ('l1' + $NL + 'l2') (Get-FieldOf '{"a":"l1\nl2"}' 'a')
    Set-Case 'payload_field: escaped backslash before n or t stays a backslash'
    Assert-Equal 'C:\new\tests' (Get-FieldOf '{"a":"C:\\new\\tests"}' 'a')
    Set-Case 'payload_field: slash, tab, carriage return, unicode escape'
    Assert-Equal ('a/b' + $TAB + 'c' + $Backslash + 'u0041') (Get-FieldOf ('{"a":"a\/b\tc\r' + $Backslash + 'u0041"}') 'a')
    Set-Case 'payload_field: key inside a nested object'
    Assert-Equal 'ls -la' (Get-FieldOf '{"tool_input":{"command":"ls -la"}}' 'command')
    Set-Case 'payload_field: key text inside another string value is not a match'
    Assert-Equal 'real' (Get-FieldOf '{"description":"\"command\":\"fake\"","command":"real"}' 'command')
    Set-Case 'payload_field: first occurrence wins'
    Assert-Equal 'one' (Get-FieldOf '{"a":"one","b":{"a":"two"}}' 'a')
    Set-Case 'payload_field: empty value is present'
    Assert-Equal '' (Get-FieldOf '{"a":""}' 'a')
    Set-Case 'payload_field: absent key'
    Assert-Equal '<absent>' (Get-FieldOf '{"b":"x"}' 'a')
    Set-Case 'payload_field: non-string value counts as absent'
    Assert-Equal '<absent>' (Get-FieldOf '{"a":null}' 'a')
    Set-Case 'payload_field: unterminated value counts as absent'
    Assert-Equal '<absent>' (Get-FieldOf '{"a":"open' 'a')
    Set-Case 'payload_field: empty payload'
    Assert-Equal '<absent>' (Get-FieldOf '' 'a')
    Set-Case 'payload_bool: true'
    Assert-Equal 'true' (Get-BoolOf '{"x":1,"stop_hook_active":true}' 'stop_hook_active')
    Set-Case 'payload_bool: false'
    Assert-Equal 'false' (Get-BoolOf '{"stop_hook_active":false}' 'stop_hook_active')
    Set-Case 'payload_first_line: skips blank lines and trims'
    Assert-Equal 'verified: ok' (Get-FirstNonEmptyLine ($NL + '   ' + $NL + '  verified: ok  ' + $NL + 'next'))

    # ------------------------------------------------------------ shared cases

    foreach ($caseFile in (Get-ChildItem -LiteralPath (Join-Path $TestsDirectory 'cases') -Filter '*.cases' | Sort-Object Name)) {
        Invoke-CaseFile $caseFile.FullName
    }

    Set-Case 'shared cases: every PowerShell twin has a case file'
    $missingCaseFiles = foreach ($twin in (Get-ChildItem -LiteralPath $Hooks -Filter '*.ps1')) {
        if (-not [System.IO.File]::Exists((Join-Path $TestsDirectory ('cases/' + $twin.BaseName + '.cases')))) { $twin.Name }
    }
    Assert-Equal '' (@($missingCaseFiles) -join $NL)

    # ------------------------------------------------------------ emoji-scan

    Set-Case 'emoji-scan: project prefix needs a path boundary'
    $directory = New-ScratchDirectory
    [void][System.IO.Directory]::CreateDirectory((Join-Path $directory 'proj'))
    [void][System.IO.Directory]::CreateDirectory((Join-Path $directory 'project'))
    Copy-Item -LiteralPath (Join-Path $FixtureProject 'emoji.md') -Destination (Join-Path $directory 'project/emoji.md')
    $env:CLAUDE_PROJECT_DIR = Join-Path $directory 'proj'
    Assert-Exit 'emoji-scan' 0 (New-FilePayload (ConvertTo-ForwardSlash (Join-Path $directory 'project/emoji.md')))
    Reset-Environment

    # NAME BYTES EXIT: writes BYTES on line 2 of a scratch project file.
    $scanCases = @(
        @('U+1FA77 blocked', [byte[]]@(0xF0, 0x9F, 0xA9, 0xB7), 2),
        @('U+2705 blocked', [byte[]]@(0xE2, 0x9C, 0x85), 2),
        @('U+2B50 blocked', [byte[]]@(0xE2, 0xAD, 0x90), 2),
        @('U+FE0F blocked', [byte[]]@(0xEF, 0xB8, 0x8F), 2),
        @('U+200D blocked', [byte[]]@(0xE2, 0x80, 0x8D), 2),
        @('U+1FB00 (outside the ranges) allowed', [byte[]]@(0xF0, 0x9F, 0xAC, 0x80), 0),
        @('em dash and box drawing allowed', [byte[]]@(0xE2, 0x80, 0x94, 0x20, 0xE2, 0x94, 0x80), 0)
    )
    foreach ($scanCase in $scanCases) {
        $directory = New-ScratchDirectory
        $sample = New-Object System.IO.MemoryStream
        $prefix = $Utf8.GetBytes('plain first line' + $NL + 'second ')
        $suffix = $Utf8.GetBytes(' line' + $NL)
        $sample.Write($prefix, 0, $prefix.Length)
        $sample.Write($scanCase[1], 0, $scanCase[1].Length)
        $sample.Write($suffix, 0, $suffix.Length)
        [System.IO.File]::WriteAllBytes((Join-Path $directory 'sample.md'), $sample.ToArray())
        $env:CLAUDE_PROJECT_DIR = $directory
        Set-Case ('emoji-scan: ' + $scanCase[0])
        Assert-Exit 'emoji-scan' $scanCase[2] (New-FilePayload (ConvertTo-ForwardSlash (Join-Path $directory 'sample.md')))
        Reset-Environment
    }

    Set-Case 'emoji-scan: NUL byte keeps the reported line number exact'
    $directory = New-ScratchDirectory
    $nulBytes = [byte[]]@(0x6F, 0x6E, 0x65, 0x0A, 0x74, 0x77, 0x6F, 0x20, 0x00, 0x0A, 0x74, 0x68, 0x72, 0x65, 0x65, 0x20, 0xE2, 0x9C, 0x85, 0x0A)
    [System.IO.File]::WriteAllBytes((Join-Path $directory 'nul.md'), $nulBytes)
    $env:CLAUDE_PROJECT_DIR = $directory
    Assert-Exit 'emoji-scan' 2 (New-FilePayload (ConvertTo-ForwardSlash (Join-Path $directory 'nul.md'))) 'nul.md at line 3 (first hit)'
    Reset-Environment

    Set-Case 'emoji-scan: uppercase binary extension skipped'
    $directory = New-ScratchDirectory
    Copy-Item -LiteralPath (Join-Path $FixtureProject 'image.png') -Destination (Join-Path $directory 'IMAGE.PNG')
    $env:CLAUDE_PROJECT_DIR = $directory
    Assert-Exit 'emoji-scan' 0 (New-FilePayload (ConvertTo-ForwardSlash (Join-Path $directory 'IMAGE.PNG')))
    Reset-Environment

    if ($IsWindowsHost) {
        Set-Case 'emoji-scan: Windows backslash paths (Windows only)'
        $env:CLAUDE_PROJECT_DIR = $RepoRoot + '\tests\fixtures\project'
        Assert-Exit 'emoji-scan' 2 (New-FilePayload (ConvertTo-JsonBackslashes ($env:CLAUDE_PROJECT_DIR + '\emoji.md'))) 'line 3'
        Set-Case 'emoji-scan: Windows backslash path outside the project (Windows only)'
        Assert-Exit 'emoji-scan' 0 (New-FilePayload (ConvertTo-JsonBackslashes ($RepoRoot + '\tests\fixtures\outside\outside.md')))
        Reset-Environment
    }

    # ------------------------------------------------------------ receipt-check

    $largeMessage = 'plan: 2 files\n'
    for ($round = 0; $round -lt 12; $round++) { $largeMessage = $largeMessage + $largeMessage }
    Set-Case 'receipt-check: large message with a token allowed'
    Assert-Exit 'receipt-check' 0 (New-ReceiptPayload 'guild:builder' $largeMessage)
    Set-Case 'receipt-check: large message without a token blocked'
    Assert-Exit 'receipt-check' 2 (New-ReceiptPayload 'guild:builder' ('prose first\n' + $largeMessage)) 'Receipt contract'

    # ------------------------------------------------------------ config

    Set-Case 'config: fixture project carries no guild.conf'
    $fixtureConf = 'absent'
    if (Test-Path -LiteralPath (Join-Path $FixtureProject '.claude/guild.conf')) { $fixtureConf = 'present' }
    Assert-Equal 'absent' $fixtureConf
    Set-Case 'config: defaults declare fourteen keys, all on'
    Assert-Equal '14' (Get-OnSwitchCount)
    Set-Case 'config: shipped defaults report no changed keys'
    Assert-Equal '' (Get-ChangedKeys)
    Set-Case 'config: git.handling reads as off by default'
    Assert-Equal 'off' (Get-SwitchState 'git.handling')
    Set-Case 'config: user conf turns a switch off'
    Use-UserConf 'hooks.emoji_scan = off'
    Assert-Equal 'off' (Get-SwitchState 'hooks.emoji_scan')
    Set-Case 'config: project conf overrides user conf'
    Use-ProjectConf 'hooks.emoji_scan = on'
    Assert-Equal 'on' (Get-SwitchState 'hooks.emoji_scan')
    Reset-Environment
    Set-Case 'config: unknown key ignored'
    Use-UserConf 'hooks.not_a_switch = off'
    Assert-Equal '' (Get-ChangedKeys)
    Set-Case 'config: unknown key reads as on'
    Assert-Equal 'on' (Get-SwitchState 'hooks.not_a_switch')
    Reset-Environment
    Set-Case 'config: malformed lines ignored, valid lines still applied'
    Use-UserConf (@('hooks.emoji_scan off', 'hooks.emoji_scan = maybe', 'Hooks.Emoji_Scan = off', 'review.security = off # trailing comment', '=off', '  # docs.sync = off', 'review.norms=No') -join $NL)
    Assert-Equal 'review.norms=off' (Get-ChangedKeys)
    Reset-Environment
    Set-Case 'config: values are case-insensitive'
    Use-UserConf (@('review.security = OFF', 'docs.sync = False', 'style.terse = YES') -join $NL)
    Assert-Equal 'docs.sync=off review.security=off' (Get-ChangedKeys)
    Reset-Environment
    Set-Case 'config: CRLF line endings'
    $directory = New-ScratchDirectory
    [System.IO.File]::WriteAllBytes((Join-Path $directory '.claude/guild.conf'), $Utf8.GetBytes('review.security = off' + [char]13 + $NL + 'hooks.emoji_scan = off' + [char]13 + $NL))
    $env:HOME = $directory
    Assert-Equal 'hooks.emoji_scan=off review.security=off' (Get-ChangedKeys)
    Reset-Environment
    Set-Case 'config: guild_changed_keys sorted and space separated'
    Use-UserConf (@('style.terse = off', 'docs.sync = off', 'hooks.receipt_check = off') -join $NL)
    Assert-Equal 'docs.sync=off hooks.receipt_check=off style.terse=off' (Get-ChangedKeys)
    Reset-Environment
    Set-Case 'config: a key set to its shipped default is not reported as changed'
    Use-UserConf (@('docs.sync = on', 'review.security = on') -join $NL)
    Assert-Equal '' (Get-ChangedKeys)
    Reset-Environment
    Set-Case 'config: missing defaults file never disables anything'
    $env:CLAUDE_PLUGIN_ROOT = New-ScratchDirectory
    Use-UserConf 'review.security = off'
    Assert-Equal 'on' (Get-SwitchState 'review.security')
    Set-Case 'config: missing defaults file keeps git.handling off'
    Assert-Equal 'off' (Get-SwitchState 'git.handling')
    Set-Case 'config: missing defaults file reports no changed keys'
    Assert-Equal '' (Get-ChangedKeys)
    Set-Case 'config: missing defaults file, plugin option true turns git.handling on'
    $env:CLAUDE_PLUGIN_OPTION_GIT_HANDLING = 'true'
    Assert-Equal 'on' (Get-SwitchState 'git.handling')
    Set-Case 'config: missing defaults file, plugin option true reports git.handling=on'
    Assert-Equal 'git.handling=on' (Get-ChangedKeys)
    Reset-Environment
    Set-Case 'config: unset CLAUDE_PLUGIN_ROOT reads no defaults file'
    Use-UserConf 'review.security = off'
    [System.Environment]::SetEnvironmentVariable('CLAUDE_PLUGIN_ROOT', [NullString]::Value)
    Assert-Equal '' (Get-ChangedKeys)
    Reset-Environment

    foreach ($optionCase in @(@('true', 'on'), @('TRUE', 'on'), @('1', 'on'), @('On', 'on'), @('yes', 'on'), @('false', 'off'), @('0', 'off'), @('', 'off'), @('maybe', 'off'))) {
        Set-Case ('config: plugin option [' + $optionCase[0] + '] maps git.handling to ' + $optionCase[1])
        [System.Environment]::SetEnvironmentVariable('CLAUDE_PLUGIN_OPTION_GIT_HANDLING', $optionCase[0])
        Assert-Equal $optionCase[1] (Get-SwitchState 'git.handling')
        Reset-Environment
    }
    Set-Case 'config: git.handling on in the project conf is ignored'
    Use-ProjectConf 'git.handling = on'
    Assert-Equal 'off' (Get-SwitchState 'git.handling')
    Set-Case 'config: git.handling in the project conf reports no changed keys'
    Assert-Equal '' (Get-ChangedKeys)
    Set-Case 'config: plugin option false leaves git.handling off'
    $env:CLAUDE_PLUGIN_OPTION_GIT_HANDLING = 'false'
    Assert-Equal 'off' (Get-SwitchState 'git.handling')
    Reset-Environment
    Set-Case 'config: plugin option true turns git.handling on despite the user conf'
    Use-UserConf 'git.handling = off'
    $env:CLAUDE_PLUGIN_OPTION_GIT_HANDLING = 'true'
    Assert-Equal 'on' (Get-SwitchState 'git.handling')
    Set-Case 'config: plugin option sets git.handling only'
    Assert-Equal 'git.handling=on' (Get-ChangedKeys)
    Reset-Environment
    Set-Case 'config: git.handling declared in the defaults file is ignored'
    $directory = New-ScratchDirectory
    [void](New-Item -ItemType Directory -Path (Join-Path $directory 'config'))
    [System.IO.File]::WriteAllBytes((Join-Path $directory 'config/defaults.conf'), $Utf8.GetBytes('git.handling = on' + $NL + 'review.security = on' + $NL))
    $env:CLAUDE_PLUGIN_ROOT = $directory
    Assert-Equal 'off' (Get-SwitchState 'git.handling')
    Reset-Environment

    # ------------------------------------------------------------ session-context

    Set-Case 'session-context: every switch off leaves no marker lines'
    Use-UserConf (Get-RewrittenDefaults 'on' 'off')
    Assert-StdoutLacks '{{' 'session-context' @('context/always-on.md')
    Set-Case 'session-context: every switch off except default_mode leaves no marker lines in the procedure'
    Use-UserConf (Get-RewrittenDefaults 'on' 'off' 'procedure.default_mode')
    Assert-StdoutLacks '{{' 'session-context' @('context/procedure.md')
    Reset-Environment
    if ($IsWindowsHost) {
        Set-Case 'session-context: backslash plugin root rendered with forward slashes (Windows only)'
        $env:CLAUDE_PLUGIN_ROOT = $RepoRoot.Replace('/', '\')
        Assert-StdoutContains ((ConvertTo-ForwardSlash $RepoRoot) + '/skills/guild/DAG.md') 'session-context' @('context/procedure.md')
        Reset-Environment
    }
    Set-Case 'session-context: every switch on leaves no marker lines in the procedure'
    $env:CLAUDE_PLUGIN_OPTION_GIT_HANDLING = 'true'
    Assert-StdoutLacks '{{' 'session-context' @('context/procedure.md')
    Reset-Environment

    # Points CLAUDE_PLUGIN_ROOT at a scratch root whose context/markers.md holds a plain and a
    # negated block on the same switch.
    $markerRoot = New-ScratchDirectory
    [void][System.IO.Directory]::CreateDirectory((Join-Path $markerRoot 'config'))
    [void][System.IO.Directory]::CreateDirectory((Join-Path $markerRoot 'context'))
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'config/defaults.conf') -Destination (Join-Path $markerRoot 'config/defaults.conf')
    Copy-HookLibraries $markerRoot
    $markers = (@('head', '{{#if review.security}}', 'plain', '{{/if}}', '{{#if !review.security}}', 'negated', '{{/if}}', 'tail') -join $NL) + $NL
    [System.IO.File]::WriteAllBytes((Join-Path $markerRoot 'context/markers.md'), $Utf8.GetBytes($markers))
    Set-Case 'session-context: negated block dropped while its switch is on'
    $env:CLAUDE_PLUGIN_ROOT = $markerRoot
    Assert-Equal ('head' + $NL + 'plain' + $NL + 'tail') (Invoke-Hook 'session-context' '' @('context/markers.md')).Stdout
    Set-Case 'session-context: negated block kept while its switch is off'
    Use-UserConf 'review.security = off'
    Assert-Equal ('head' + $NL + 'negated' + $NL + 'tail') (Invoke-Hook 'session-context' '' @('context/markers.md')).Stdout
    Reset-Environment

    # ------------------------------------------------------------ render-agents

    $builderRendered = 'builder.md - model: opus' + $NL + 'builder.md + model: sonnet'
    Set-Case 'render-agents: no option set leaves every agent file untouched'
    $agentsRoot = Use-AgentsRoot
    Assert-Equal '' ((Invoke-Hook 'render-agents' '').Stdout + (Get-AgentsChanges $agentsRoot))
    Reset-Environment

    Set-Case 'render-agents: a differing model rewrites only that line'
    $agentsRoot = Use-AgentsRoot
    $env:CLAUDE_PLUGIN_OPTION_BUILDER_MODEL = 'sonnet'
    [void](Invoke-Hook 'render-agents' '')
    Assert-Equal $builderRendered (Get-AgentsChanges $agentsRoot)
    Set-Case 'render-agents: the rewritten file keeps every other byte (LF endings included)'
    Assert-Equal ([string]((Get-ByteSize (Join-Path $RepoRoot 'agents/builder.md')) + 2)) ([string](Get-ByteSize (Join-Path $agentsRoot 'agents/builder.md')))
    Set-Case 'render-agents: no temp file left in agents/'
    Assert-Equal '' (@([System.IO.Directory]::GetFiles((Join-Path $agentsRoot 'agents')) | Where-Object { -not $_.EndsWith('.md') }) -join $NL)
    Set-Case 'render-agents: running again prints nothing'
    Assert-Equal '' (Invoke-Hook 'render-agents' '').Stdout
    Set-Case 'render-agents: running again keeps the rendered file'
    Assert-Equal $builderRendered (Get-AgentsChanges $agentsRoot)
    Reset-Environment

    Set-Case 'render-agents: model and effort of one agent rewritten in one run'
    $agentsRoot = Use-AgentsRoot
    $env:CLAUDE_PLUGIN_OPTION_REVIEWER_MODEL = 'sonnet'
    $env:CLAUDE_PLUGIN_OPTION_REVIEWER_EFFORT = 'low'
    [void](Invoke-Hook 'render-agents' '')
    Assert-Equal ((@('reviewer.md - model: opus', 'reviewer.md - effort: high', 'reviewer.md + model: sonnet', 'reviewer.md + effort: low')) -join $NL) (Get-AgentsChanges $agentsRoot)
    Reset-Environment

    Set-Case 'render-agents: a failing agent is skipped and the others still render'
    $agentsRoot = Use-AgentsRoot
    [void][System.IO.Directory]::CreateDirectory((Join-Path $agentsRoot 'agents/builder.md.render'))
    $env:CLAUDE_PLUGIN_OPTION_BUILDER_MODEL = 'sonnet'
    $env:CLAUDE_PLUGIN_OPTION_REVIEWER_MODEL = 'sonnet'
    $notice = (Invoke-Hook 'render-agents' '').Stdout
    Assert-Equal ('reviewer.md - model: opus' + $NL + 'reviewer.md + model: sonnet') (Get-AgentsChanges $agentsRoot)
    Set-Case 'render-agents: the notice lists only the agents rendered'
    Assert-Equal 'GUILD AGENTS RENDERED: reviewer model=sonnet effort=high. Run /reload-plugins to apply.' $notice
    Reset-Environment

    Set-Case 'render-agents: invalid values leave every agent file untouched'
    $agentsRoot = Use-AgentsRoot
    $env:CLAUDE_PLUGIN_OPTION_BUILDER_MODEL = 'opus sonnet'
    $env:CLAUDE_PLUGIN_OPTION_ARCHITECT_EFFORT = 'extreme'
    $env:CLAUDE_PLUGIN_OPTION_SCRIBE_MODEL = 'sonnet/;s/^/x/'
    Assert-Equal '' ((Invoke-Hook 'render-agents' '').Stdout + (Get-AgentsChanges $agentsRoot))
    Reset-Environment

    # ------------------------------------------------------------ hooks.json wiring

    $hooksJson = $Utf8.GetString([System.IO.File]::ReadAllBytes((Join-Path $Hooks 'hooks.json')))
    $wiredScripts = @([regex]::Matches($hooksJson, '/hooks/([A-Za-z0-9_-]+\.sh)\\"') | ForEach-Object { $_.Groups[1].Value })
    $wiredTwins = @([regex]::Matches($hooksJson, '/hooks/([A-Za-z0-9_-]+\.ps1)\\"') | ForEach-Object { $_.Groups[1].Value })
    $polyglotPattern = '"command": "exec sh \\"\$\{CLAUDE_PLUGIN_ROOT\}/hooks/([A-Za-z0-9_-]+)\.sh\\"([^"\\]*)\\n& \\"\$\{CLAUDE_PLUGIN_ROOT\}/hooks/\1\.ps1\\"\2; exit \$LASTEXITCODE"'
    Set-Case 'hooks.json: every command runs an existing sh script'
    Assert-Equal '' (@($wiredScripts | Where-Object { -not [System.IO.File]::Exists((Join-Path $Hooks $_)) }) -join $NL)
    Set-Case 'hooks.json: eight script references found'
    Assert-Equal '8' ([string]$wiredScripts.Count)
    Set-Case 'hooks.json: every command names an existing PowerShell twin'
    Assert-Equal '' (@($wiredTwins | Where-Object { -not [System.IO.File]::Exists((Join-Path $Hooks $_)) }) -join $NL)
    Set-Case 'hooks.json: eight commands, all the sh/PowerShell polyglot'
    Assert-Equal '8 8' ([string][regex]::Matches($hooksJson, '"command":').Count + ' ' + [regex]::Matches($hooksJson, $polyglotPattern).Count)
    Set-Case 'hooks.json: render-agents wired once on SessionStart and once on UserPromptSubmit'
    Assert-Equal '2' ([string]@($wiredScripts | Where-Object { $_ -ceq 'render-agents.sh' }).Count)
    Set-Case 'hooks.json: no pwsh -File line'
    Assert-Equal '0' ([string][regex]::Matches($hooksJson, 'pwsh -NoProfile -File').Count)
    Set-Case 'hooks.json: no shell field'
    Assert-Equal '0' ([string][regex]::Matches($hooksJson, '"shell"').Count)
} finally {
    if ([System.IO.Directory]::Exists($Scratch)) { Remove-Item -LiteralPath $Scratch -Recurse -Force }
}

Write-Line ([string]$Passed + ' passed, ' + $Failed + ' failed')
if ($Failed -ne 0) { exit 1 }
exit 0
