# PreToolUse hook (Bash|PowerShell): blocks a git commit or a PR create/edit whose command
# text carries AI attribution (owner rule).
# Text-level guardrail only: it inspects the command string, so attribution supplied through
# files (commit -F, --body-file), templates, or environment variables is not detected.
$gitArtifactPattern = 'git\s+commit|gh\s+pr\s+(create|edit)'
$attributionPattern = 'Co-Authored-By|Generated with|Claude Code|Anthropic|noreply@anthropic\.com'
$blockMessage = 'BLOCKED: AI attribution in a git artifact is forbidden (owner rule). Remove the trailer/footer and retry.'

try {
    $payload = $input | Out-String | ConvertFrom-Json
    $command = [string]$payload.tool_input.command
    $createsGitArtifact = $command -imatch $gitArtifactPattern
    $carriesAttribution = $command -imatch $attributionPattern
    if ($createsGitArtifact -and $carriesAttribution) {
        [Console]::Error.WriteLine($blockMessage)
        exit 2
    }
} catch {
    # Swallowed on purpose: a malformed payload must never block the session.
}
exit 0
