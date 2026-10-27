# SessionStart hook: prints the guild always-on context and the default operating procedure;
# the harness injects stdout as context. `{{PLUGIN_ROOT}}` in the procedure becomes the
# absolute plugin path so the main thread can Read DAG.md and the charter template.
# Missing files or any internal error print nothing and exit 0 (never blocks a session).
try {
    $pluginRoot = $env:CLAUDE_PLUGIN_ROOT
    if ([string]::IsNullOrWhiteSpace($pluginRoot)) {
        $pluginRoot = Split-Path -Parent $PSScriptRoot
    }
    $pluginRootForward = $pluginRoot.Replace([char]92, '/')
    $parts = @('context/always-on.md', 'context/procedure.md')
    foreach ($part in $parts) {
        $path = Join-Path $pluginRoot $part
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        $text = $text.Replace('{{PLUGIN_ROOT}}', $pluginRootForward)
        [Console]::Out.Write($text)
        [Console]::Out.Write("`n")
    }
} catch {
    # Swallowed on purpose: a context hook must never crash the session.
}
exit 0
