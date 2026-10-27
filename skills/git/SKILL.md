---
name: git
description: >
  Generic git workflow of the guild: conventional commits, one commit per
  logical change, no AI attribution, never push without an explicit request,
  linear PR flow. Invoke before any commit, push, branch, rebase or PR. Only
  active when the plugin's git handling option is on.
---

Git handling option: ${user_config.git_handling}. When it reads false, stop: this skill is inactive and the project's own git conventions apply.

## Commits

- Conventional Commits: `type: subject`, with `type` one of `feat`, `fix`, `refactor`, `test`, `docs`, `chore`, `style`, `perf`.
- Subject in the imperative mood, at most 72 characters.
- One commit per logical change; changes on different themes go into separate commits.
- Run `git status --porcelain` before staging and account for every entry: each path is either staged for this commit, kept for another commit, or reported to the user.
- No AI attribution anywhere: no `Co-Authored-By` trailer, no "Generated with" footer, no tool or vendor credit in the subject, body, PR title or PR body.

## Push

- Never push without an explicit request.
- A request to open a PR authorizes pushing the feature branch only.
- The main branch is pushed by the owner.

## Branch integration

1. `git fetch origin`.
2. `git rebase origin/main` on the feature branch.
3. After a rewrite (rebase, reorder, squash), push with `--force-with-lease`; never a plain forced push.
4. Open the PR for a rebase merge, keeping history linear.
5. Update local branches with `git pull` under `pull.rebase=true`.

## Forbidden

- `--no-verify` or any other hook bypass; a failing hook is fixed, not skipped.
- `--amend` after a hook failure: the commit did not happen, so amending would rewrite the previous one. Fix the cause and create the commit again.
- `git config` writes, unless the user instructs it.
- Destructive operations (`reset --hard`, `clean -f`, `branch -D`, discarding uncommitted changes) without an explicit instruction.
