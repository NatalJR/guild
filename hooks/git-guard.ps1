# PreToolUse hook (Bash|PowerShell), PowerShell twin of git-guard.sh (the primary
# implementation; the harness runs this one only where no Git Bash is found): the guild git
# guard. Denies, in the command text, AI attribution in a git commit or a PR create/edit, a hook
# bypass (--no-verify; -n on git commit) and a forced push (--force or -f; --force-with-lease and
# --force-if-includes are not blocked). The whole command string is evaluated, compound commands
# included.
# Text-level guardrail only: it inspects the command string, so attribution supplied through
# files (commit -F, --body-file), templates, or environment variables is not detected. The flag
# checks see standalone tokens of a git commit / git push segment (ended by ;, &, | or a newline)
# with quoted spans removed, so a flag written inside quotes, a bundled short flag (-nm), a
# refspec force push (+branch) or git options before the subcommand (git -C dir push) are not
# detected either.
# Matching follows LC_ALL=C grep -i -E: the text is ASCII-lowercased and the patterns are
# written in lowercase, the space class is the C-locale set. The attribution e-mail address needs
# no alternative of its own: anthropic already matches it.
# Writes nothing to stdout: a block message goes to stderr with exit 2.
# Switch: git.handling, set by the plugin option CLAUDE_PLUGIN_OPTION_GIT_HANDLING only (true,
# 1, on or yes in any case is on; any other value or unset is off). A malformed payload or an
# internal error never blocks.
# Self-contained on purpose: it loads no library, and its text holds no escape characters; the
# characters it needs are built from their character codes.
# Windows PowerShell 5.1 compatible syntax.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$NEWLINE = [string][char]10
$TAB = [string][char]9
$DOUBLE_QUOTE = [string][char]34
$SINGLE_QUOTE = [string][char]39
$BACKSLASH = [string][char]92
# A regex matching one literal backslash.
$ESCAPED_BACKSLASH = [regex]::Escape($BACKSLASH)
# The space class in the C locale: space, tab, newline, vertical tab, form feed, carriage return.
$C_LOCALE_SPACES = -join ([char[]]@(32, 9, 10, 11, 12, 13))
# The same set without the newline, which cannot occur inside one payload line.
$LINE_SPACES = -join ([char[]]@(32, 9, 11, 12, 13))
$SPACE = '[' + $C_LOCALE_SPACES + ']'
$GIT_ARTIFACT_PATTERN = "git$SPACE+commit|gh$SPACE+pr$SPACE+(create|edit)"
$ATTRIBUTION_PATTERN = 'co-authored-by|generated with|claude code|anthropic'
# The rest of a git subcommand up to the next shell operator, then the end of a standalone token.
$SEGMENT = "($SPACE[^;&|]*)?$SPACE"
$FLAG_BOUNDARY = '([' + $C_LOCALE_SPACES + ';&|)]|$)'
# git push -n is --dry-run, not a hook bypass, so -n counts on git commit only.
$NO_VERIFY_PATTERN = "git$SPACE+commit$SEGMENT(--no-verify|-n)$FLAG_BOUNDARY|git$SPACE+push$SEGMENT--no-verify$FLAG_BOUNDARY"
$FORCE_PUSH_PATTERN = "git$SPACE+push$SEGMENT(--force|-f)$FLAG_BOUNDARY"
# A double-quoted span (a backslash escapes the next character, an escaped quote included).
$PLAIN_QUOTED_TEXT = '[^' + $DOUBLE_QUOTE + $ESCAPED_BACKSLASH + ']*'
$DOUBLE_QUOTED_SPAN = $DOUBLE_QUOTE + $PLAIN_QUOTED_TEXT + '(' + $ESCAPED_BACKSLASH + '.' + $PLAIN_QUOTED_TEXT + ')*' + $DOUBLE_QUOTE
$SINGLE_QUOTED_SPAN = $SINGLE_QUOTE + '[^' + $SINGLE_QUOTE + ']*' + $SINGLE_QUOTE
$ATTRIBUTION_MESSAGE = 'BLOCKED: AI attribution in a git artifact is forbidden. Remove the trailer/footer and retry.'
$NO_VERIFY_MESSAGE = 'BLOCKED: hook bypass (--no-verify) is forbidden. Fix the failing hook instead.'
$FORCE_PUSH_MESSAGE = 'BLOCKED: forced push is forbidden. Use --force-with-lease only inside the PR update sequence.'
$GIT_HANDLING_ON_VALUES = @('1', 'on', 'true', 'yes')

$PAYLOAD_UTF8 = New-Object System.Text.UTF8Encoding -ArgumentList $false, $false
# Placeholder characters: raw control characters cannot occur inside a valid JSON string.
$PAYLOAD_MARK = [string][char]31
$PAYLOAD_QUOTE = [string][char]30
$COMMAND_FIELD_PATTERN = New-Object System.Text.RegularExpressions.Regex -ArgumentList ($DOUBLE_QUOTE + 'command' + $DOUBLE_QUOTE + '[' + $LINE_SPACES + ']*:[' + $LINE_SPACES + ']*' + $DOUBLE_QUOTE)

# Like its sh twin, the hook does nothing unless the harness names a plugin root whose hooks
# directory exists.
function Test-PluginRootPresent {
    $pluginRoot = [string][System.Environment]::GetEnvironmentVariable('CLAUDE_PLUGIN_ROOT')
    return ($pluginRoot -ne '') -and [System.IO.Directory]::Exists($pluginRoot + '/hooks')
}

# True when the git handling plugin option is set to 1, true, on or yes in any case.
function Test-GitHandlingOn {
    $option = [string][System.Environment]::GetEnvironmentVariable('CLAUDE_PLUGIN_OPTION_GIT_HANDLING')
    return $GIT_HANDLING_ON_VALUES -ccontains (ConvertTo-AsciiLowerCase $option)
}

# All of stdin as text, with trailing newlines and NUL characters dropped;
# empty when stdin is empty or unreadable. Read as raw UTF-8 bytes, so neither the console code
# page nor a byte order mark changes what the hook sees.
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

# The decoded string value of the first command field in PAYLOAD; $null when the key is absent or
# its value is not a string. The first line holding the key decides. The payload is untrusted
# data, only ever matched against fixed patterns.
function Get-CommandField([string]$Payload) {
    foreach ($line in $Payload.Split([char]10)) {
        if ($COMMAND_FIELD_PATTERN.IsMatch($line)) { return ConvertFrom-PayloadValue ($COMMAND_FIELD_PATTERN.Replace($line, $PAYLOAD_MARK, 1)) }
    }
    return $null
}

# LINE holds the opening quote of the value replaced by the mark. Escaped backslashes and then
# escaped quotes are parked on placeholders, so the first raw quote left is the closing one (no
# closing quote: absent). Parking escaped backslashes first keeps an escaped backslash followed by
# n or t, as in a Windows path, a backslash instead of a newline or a tab. Every step is a plain
# substitution, linear in the payload size. A unicode escape is left untouched.
function ConvertFrom-PayloadValue([string]$Line) {
    $value = $Line.Substring($Line.IndexOf($PAYLOAD_MARK, [System.StringComparison]::Ordinal) + 1)
    $value = $value.Replace($BACKSLASH + $BACKSLASH, $PAYLOAD_MARK).Replace($BACKSLASH + $DOUBLE_QUOTE, $PAYLOAD_QUOTE)
    $closingQuote = $value.IndexOf([char]34)
    if ($closingQuote -lt 0) { return $null }
    $value = $value.Substring(0, $closingQuote).Replace($PAYLOAD_QUOTE, $DOUBLE_QUOTE).Replace($BACKSLASH + '/', '/')
    $value = $value.Replace($BACKSLASH + 'n', $NEWLINE).Replace($BACKSLASH + 't', $TAB).Replace($BACKSLASH + 'r', '')
    return $value.Replace($PAYLOAD_MARK, $BACKSLASH).TrimEnd([char]10)
}

# TEXT with A-Z lowered and every other character kept, as tr and grep -i do in the C locale.
function ConvertTo-AsciiLowerCase([string]$Text) {
    $characters = $Text.ToCharArray()
    for ($index = 0; $index -lt $characters.Length; $index++) {
        $code = [int]$characters[$index]
        if ($code -ge 65 -and $code -le 90) { $characters[$index] = [char]($code + 32) }
    }
    return -join $characters
}

# Writes TEXT to stderr as raw UTF-8 bytes.
function Write-HookError([string]$Text) {
    Write-HookStream ([Console]::OpenStandardError()) ($PAYLOAD_UTF8.GetBytes($Text))
}

function Write-HookStream([System.IO.Stream]$Stream, [byte[]]$Bytes) {
    $Stream.Write($Bytes, 0, $Bytes.Length)
    $Stream.Flush()
}

# TEXT PATTERN: ASCII case-insensitive match anywhere in TEXT.
function Test-Match([string]$Text, [string]$Pattern) {
    return [regex]::IsMatch((ConvertTo-AsciiLowerCase $Text), $Pattern)
}

# Newlines are folded to spaces for the attribution check, which reads the whole command, so an
# artifact command split across lines still counts; a trailing space is added as in the sh twin.
function Get-Folded([string]$Text) {
    return $Text.Replace($NEWLINE, ' ') + ' '
}

# Newlines become semicolons for the flag checks, so a newline ends a command segment like any
# other separator and the next line's flags are never read as the previous command's; a trailing
# semicolon is added as in the sh twin.
function Get-Segmented([string]$Text) {
    return $Text.Replace($NEWLINE, ';') + ';'
}

# Drops double-quoted spans and single-quoted spans, so a flag named inside a commit message is
# not taken for a flag.
function Get-Unquoted([string]$Text) {
    return [regex]::Replace([regex]::Replace($Text, $DOUBLE_QUOTED_SPAN, ''), $SINGLE_QUOTED_SPAN, '')
}

# The block message for the first rule COMMAND breaks; empty otherwise.
function Get-Violation([string]$Command) {
    $folded = Get-Folded $Command
    $words = Get-Unquoted (Get-Segmented $Command)
    if ((Test-Match $folded $GIT_ARTIFACT_PATTERN) -and (Test-Match $folded $ATTRIBUTION_PATTERN)) {
        return $ATTRIBUTION_MESSAGE
    }
    if (Test-Match $words $NO_VERIFY_PATTERN) { return $NO_VERIFY_MESSAGE }
    if (Test-Match $words $FORCE_PUSH_PATTERN) { return $FORCE_PUSH_MESSAGE }
    return ''
}

# The exit status: 2 after printing the block message, 0 otherwise.
function Invoke-GitGuard {
    if (-not (Test-PluginRootPresent)) { return 0 }
    if (-not (Test-GitHandlingOn)) { return 0 }
    $command = Get-CommandField (Read-Payload)
    if ($null -eq $command) { return 0 }
    $message = Get-Violation $command
    if ($message -eq '') { return 0 }
    Write-HookError ($message + $NEWLINE)
    return 2
}

try {
    $status = Invoke-GitGuard
} catch {
    $status = 0
}
exit $status
