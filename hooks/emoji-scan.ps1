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
    Write-HookError ('Emoji found in ' + $filePath + ' at line ' + $hitLine + ', the first hit. Owner rule: no emoji in any committed file; write severity/status markers as words. Remove it.' + "`n")
    return 2
}

# ROOT: true when ROOT is non-empty and its hooks directory exists; like its sh twin, the hook
# does nothing otherwise.
function Test-PluginRootPresent([string]$Root) {
    return ($Root -ne '') -and [System.IO.Directory]::Exists($Root + '/hooks')
}

try {
    $pluginRoot = [string][System.Environment]::GetEnvironmentVariable('CLAUDE_PLUGIN_ROOT')
    if (-not (Test-PluginRootPresent $pluginRoot)) { exit 0 }
    . ($pluginRoot + '/hooks/lib/payload.ps1')
    . ($pluginRoot + '/hooks/lib/config.ps1')
    $status = Invoke-EmojiScan
} catch {
    $status = 0
}
exit $status
