---
name: guild
description: >
  Force the guild delegation walk on a task that looks trivial. The walk itself
  (classify, dispatch to guild:investigator / guild:builder / guild:architect /
  guild:reviewer / guild:security / guild:scribe, terminal tokens, review loop)
  is the session's default operating procedure, injected at session start, so
  ordinary coding requests never need this skill. Use only when the user types
  /guild explicitly.
argument-hint: <task to force through the DAG>
---

Walk the `## Operating procedure (default mode)` already present in the session context for `$ARGUMENTS` (or the user's last request), starting at Step 1 with the inline shortcut disabled: the user invoked this skill to force delegation, so "answer inline" is not a valid route this time. `DAG.md` beside this file is binding as always.
