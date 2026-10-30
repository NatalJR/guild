# Hook payload access and hook output (dot-sourced by the guild PowerShell hooks; twin of
# payload.sh, which is the primary implementation and the reference for every rule below).
# The harness sends one compact JSON object on stdin. Fields are located by key name with fixed
# substitutions and never parsed as code: the payload is untrusted data, only ever matched
# against fixed patterns. The search is by key, so nested objects are fine; the first occurrence
# wins. Stdin is read and stdout/stderr are written as raw UTF-8 bytes, so neither the console
# code page nor a byte order mark changes what the harness receives.
# Windows PowerShell 5.1 compatible syntax.
Set-StrictMode -Version 2.0

$PAYLOAD_UTF8 = New-Object System.Text.UTF8Encoding -ArgumentList $false, $false
# Placeholder characters: raw control characters cannot occur inside a valid JSON string.
$PAYLOAD_MARK = [string][char]31
$PAYLOAD_QUOTE = [string][char]30
# [[:space:]] in the C locale.
$PAYLOAD_SPACE_CHARACTERS = [char[]]@(32, 9, 10, 11, 12, 13)

# All of stdin as text, trailing newlines and NUL characters dropped as in `PAYLOAD=$(cat)`;
# empty when stdin is empty or unreadable.
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

# The decoded string value of the first "NAME":"..." in PAYLOAD; $null when the key is absent or
# its value is not a string. The first line holding the key decides, as in the sed filter.
function Get-PayloadField([string]$Payload, [string]$Name) {
    if ($Name -cnotmatch '^[A-Za-z0-9_]+\z') { return $null }
    $fieldPattern = New-Object System.Text.RegularExpressions.Regex -ArgumentList ('"' + $Name + '"[ \t\v\f\r]*:[ \t\v\f\r]*"')
    foreach ($line in $Payload.Split([char]10)) {
        if ($fieldPattern.IsMatch($line)) { return ConvertFrom-PayloadValue ($fieldPattern.Replace($line, $PAYLOAD_MARK, 1)) }
    }
    return $null
}

# True when "NAME":true occurs in PAYLOAD.
function Test-PayloadBool([string]$Payload, [string]$Name) {
    $quoted = '"' + $Name + '"'
    return $Payload.Contains($quoted + ':true') -or $Payload.Contains($quoted + ': true')
}

# The first line of TEXT that is not blank, trimmed of surrounding whitespace; empty when none.
function Get-FirstNonEmptyLine([string]$Text) {
    foreach ($line in $Text.Split([char]10)) {
        if ($line -cmatch '[^ \t\n\v\f\r]') { return $line.Trim($PAYLOAD_SPACE_CHARACTERS) }
    }
    return ''
}

# TEXT with A-Z lowered and every other character kept, as `tr` and `grep -i` do in the C locale.
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

# LINE holds the opening quote of the value replaced by the mark. Escaped backslashes and then
# escaped quotes are parked on placeholders, so the first raw quote left is the closing one (no
# closing quote: absent). Parking `\\` first keeps `\\n` or a Windows path such as `C:\\tests` a
# backslash instead of a newline or a tab. Every step is a plain substitution, linear in the
# payload size. \uXXXX is left untouched.
function ConvertFrom-PayloadValue([string]$Line) {
    $value = $Line.Substring($Line.IndexOf($PAYLOAD_MARK, [System.StringComparison]::Ordinal) + 1)
    $value = $value.Replace('\\', $PAYLOAD_MARK).Replace('\"', $PAYLOAD_QUOTE)
    $closingQuote = $value.IndexOf([char]34)
    if ($closingQuote -lt 0) { return $null }
    $value = $value.Substring(0, $closingQuote).Replace($PAYLOAD_QUOTE, '"').Replace('\/', '/')
    $value = $value.Replace('\n', [string][char]10).Replace('\t', [string][char]9).Replace('\r', '')
    return $value.Replace($PAYLOAD_MARK, '\').TrimEnd([char]10)
}
