# UserPromptSubmit hook: per-turn reinforcement of the guild context, since style drifts
# in long sessions. The harness injects stdout as context.
try {
    [Console]::Out.WriteLine('GUILD DEFAULT MODE: terse replies, universal code rules, coding requests walk the operating procedure in session context (no slash command).')
} catch {
    # Swallowed on purpose: a context hook must never crash the session.
}
exit 0
