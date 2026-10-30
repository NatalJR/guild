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
# Matching follows `LC_ALL=C grep -i -E`: the text is ASCII-lowercased and the patterns are
# written in lowercase, [[:space:]] is the C-locale set. The attribution e-mail address needs no
# alternative of its own: `anthropic` already matches it.
# Writes nothing to stdout: a block message goes to stderr with exit 2.
# Switch: git.handling, set by the plugin option only (off by default). A
# malformed payload or an internal error never blocks.
# Windows PowerShell 5.1 compatible syntax.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$SPACE = '[ \t\n\v\f\r]'
$GIT_ARTIFACT_PATTERN = "git$SPACE+commit|gh$SPACE+pr$SPACE+(create|edit)"
$ATTRIBUTION_PATTERN = 'co-authored-by|generated with|claude code|anthropic'
# The rest of a git subcommand up to the next shell operator, then the end of a standalone token.
$SEGMENT = "($SPACE[^;&|]*)?$SPACE"
$FLAG_BOUNDARY = '([ \t\n\v\f\r;&|)]|$)'
# git push -n is --dry-run, not a hook bypass, so -n counts on git commit only.
$NO_VERIFY_PATTERN = "git$SPACE+commit$SEGMENT(--no-verify|-n)$FLAG_BOUNDARY|git$SPACE+push$SEGMENT--no-verify$FLAG_BOUNDARY"
$FORCE_PUSH_PATTERN = "git$SPACE+push$SEGMENT(--force|-f)$FLAG_BOUNDARY"
$ATTRIBUTION_MESSAGE = 'BLOCKED: AI attribution in a git artifact is forbidden. Remove the trailer/footer and retry.'
$NO_VERIFY_MESSAGE = 'BLOCKED: hook bypass (--no-verify) is forbidden. Fix the failing hook instead.'
$FORCE_PUSH_MESSAGE = 'BLOCKED: forced push is forbidden. Use --force-with-lease only inside the PR update sequence.'

# TEXT PATTERN: ASCII case-insensitive match anywhere in TEXT.
function Test-Match([string]$Text, [string]$Pattern) {
    return [regex]::IsMatch((ConvertTo-AsciiLowerCase $Text), $Pattern)
}

# Newlines are folded to spaces for the attribution check, which reads the whole command, so an
# artifact command split across lines still counts; a trailing space is added as in the sh twin.
function Get-Folded([string]$Text) {
    return $Text.Replace([string][char]10, ' ') + ' '
}

# Newlines become `;` for the flag checks, so a newline ends a command segment like any other
# separator and the next line's flags are never read as the previous command's; a trailing `;`
# is added as in the sh twin.
function Get-Segmented([string]$Text) {
    return $Text.Replace([string][char]10, ';') + ';'
}

# Drops double-quoted spans (a backslash escapes the next character, \" included) and
# single-quoted spans, so a flag named inside a commit message is not taken for a flag.
function Get-Unquoted([string]$Text) {
    return [regex]::Replace([regex]::Replace($Text, '"[^"\\]*(\\.[^"\\]*)*"', ''), "'[^']*'", '')
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
    Import-GuildConfig
    if (-not (Get-GuildSwitch 'git.handling')) { return 0 }
    $command = Get-PayloadField (Read-Payload) 'command'
    if ($null -eq $command) { return 0 }
    $message = Get-Violation $command
    if ($message -eq '') { return 0 }
    Write-HookError ($message + "`n")
    return 2
}

try {
    $pluginRoot = [string][System.Environment]::GetEnvironmentVariable('CLAUDE_PLUGIN_ROOT')
    if ($pluginRoot -eq '') { exit 0 }
    . ($pluginRoot + '/hooks/lib/payload.ps1')
    . ($pluginRoot + '/hooks/lib/config.ps1')
    $status = Invoke-GitGuard
} catch {
    $status = 0
}
exit $status
