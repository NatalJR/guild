# UserPromptSubmit hook: per-turn reinforcement of the guild context, since style drifts
# in long sessions. The harness injects stdout as context.
try {
    [Console]::Out.WriteLine('GUILD CONTEXT ACTIVE: terse replies, universal code rules, delegation through /guild.')
} catch {
    # Swallowed on purpose: a context hook must never crash the session.
}
exit 0
