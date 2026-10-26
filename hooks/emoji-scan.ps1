# PostToolUse hook (Edit|Write): rejects emoji in the file just written (owner rule).
# Skips empty paths, missing files, files outside CLAUDE_PROJECT_DIR, and binary types.
$binaryExtensions = @('.png', '.jpg', '.jpeg', '.gif', '.ico', '.onnx', '.sqlite', '.dll',
    '.exe', '.pdf', '.zip', '.woff', '.woff2', '.ttf')

function Test-InsideProject([string] $path) {
    if ([string]::IsNullOrWhiteSpace($env:CLAUDE_PROJECT_DIR)) { return $true }
    $separator = [System.IO.Path]::DirectorySeparatorChar
    $projectRoot = [System.IO.Path]::GetFullPath($env:CLAUDE_PROJECT_DIR).TrimEnd('\', '/') + $separator
    $fullPath = [System.IO.Path]::GetFullPath($path)
    return $fullPath.StartsWith($projectRoot, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-Scannable([string] $path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return $false }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    if (-not (Test-InsideProject $path)) { return $false }
    $extension = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
    return -not ($binaryExtensions -contains $extension)
}

function Test-EmojiCodePoint([int] $codePoint) {
    $isPictograph = $codePoint -ge 0x1F000 -and $codePoint -le 0x1FAFF
    $isSymbolOrDingbat = $codePoint -ge 0x2600 -and $codePoint -le 0x27BF
    $isMiscSymbolOrArrow = $codePoint -ge 0x2B00 -and $codePoint -le 0x2BFF
    $isJoinerOrSelector = $codePoint -eq 0xFE0F -or $codePoint -eq 0x200D
    return $isPictograph -or $isSymbolOrDingbat -or $isMiscSymbolOrArrow -or $isJoinerOrSelector
}

function Test-LineHasEmoji([string] $line) {
    for ($position = 0; $position -lt $line.Length; $position++) {
        $isPair = [char]::IsSurrogatePair($line, $position)
        $codePoint = if ($isPair) { [char]::ConvertToUtf32($line, $position) } else { [int]$line[$position] }
        if (Test-EmojiCodePoint $codePoint) { return $true }
        if ($isPair) { $position++ }
    }
    return $false
}

function Find-FirstEmojiLine([string] $text) {
    $lines = $text -split "`r?`n"
    for ($index = 0; $index -lt $lines.Length; $index++) {
        if (Test-LineHasEmoji $lines[$index]) { return $index + 1 }
    }
    return 0
}

try {
    $payload = $input | Out-String | ConvertFrom-Json
    $filePath = [string]$payload.tool_input.file_path
    if (-not (Test-Scannable $filePath)) { exit 0 }
    $hitLine = Find-FirstEmojiLine ([System.IO.File]::ReadAllText($filePath, [System.Text.Encoding]::UTF8))
    if ($hitLine -gt 0) {
        [Console]::Error.WriteLine("Emoji found in $filePath at line $hitLine (first hit). Owner rule: no emoji in any committed file; write severity/status markers as words. Remove it.")
        exit 2
    }
} catch {
    # Swallowed on purpose: a scan failure must never crash the session.
}
exit 0
