# SessionStart hook: prints one guild context file; the harness injects stdout as context.
# One hook entry per file, because the harness caps a single hook's stdout near 10KB and
# replaces anything larger with a 2KB preview. `{{PLUGIN_ROOT}}` becomes the absolute plugin
# path so the main thread can Read DAG.md and the charter template.
# Missing file or any internal error prints nothing and exits 0 (never blocks a session).
param([string]$Part = 'context/always-on.md')
try {
    $pluginRoot = $env:CLAUDE_PLUGIN_ROOT
    if ([string]::IsNullOrWhiteSpace($pluginRoot)) {
        $pluginRoot = Split-Path -Parent $PSScriptRoot
    }
    $pluginRootForward = $pluginRoot.Replace([char]92, '/')
    $path = Join-Path $pluginRoot $Part
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        [Console]::Out.Write($text.Replace('{{PLUGIN_ROOT}}', $pluginRootForward))
    }
} catch {
    # Swallowed on purpose: a context hook must never crash the session.
}
exit 0
