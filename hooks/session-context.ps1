# SessionStart hook: prints the guild always-on context; the harness injects stdout as context.
# Missing context file or any internal error prints nothing and exits 0 (never blocks a session).
try {
    $pluginRoot = $env:CLAUDE_PLUGIN_ROOT
    if ([string]::IsNullOrWhiteSpace($pluginRoot)) {
        $pluginRoot = Split-Path -Parent $PSScriptRoot
    }
    $contextPath = Join-Path $pluginRoot 'context/always-on.md'
    if (Test-Path -LiteralPath $contextPath -PathType Leaf) {
        [Console]::Out.Write([System.IO.File]::ReadAllText($contextPath, [System.Text.Encoding]::UTF8))
    }
} catch {
    # Swallowed on purpose: a context hook must never crash the session.
}
exit 0
