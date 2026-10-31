# UserPromptSubmit hook, PowerShell twin of prompt-reinforce.sh (the primary implementation;
# the harness runs this one only where no Git Bash is found): per-turn reinforcement of the
# guild context, since style drifts in long sessions. The harness injects stdout as context.
# Switch: hooks.prompt_reinforce. Any internal error prints nothing and exits 0 (never blocks a
# prompt).
# Windows PowerShell 5.1 compatible syntax.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$REINFORCEMENT = 'GUILD DEFAULT MODE: replies at most six lines, universal code rules, coding requests walk the operating procedure in session context (no slash command).'

# ROOT: true when ROOT is non-empty and names an existing directory; like its sh twin, the hook
# does nothing otherwise.
function Test-PluginRootPresent([string]$Root) {
    return ($Root -ne '') -and [System.IO.Directory]::Exists($Root)
}

try {
    $pluginRoot = [string][System.Environment]::GetEnvironmentVariable('CLAUDE_PLUGIN_ROOT')
    if (-not (Test-PluginRootPresent $pluginRoot)) { exit 0 }
    . ($pluginRoot + '/hooks/lib/config.ps1')
    . ($pluginRoot + '/hooks/lib/payload.ps1')
    Import-GuildConfig
    if (Get-GuildSwitch 'hooks.prompt_reinforce') { Write-HookOutput ($REINFORCEMENT + "`n") }
} catch {
    exit 0
}
exit 0
