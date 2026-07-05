---
name: git
description: Git version control. Use when the user mentions git, commits, branches, pushing, pulling, merging, rebasing, stashing, worktrees, submodules, or any version control task. Covers straightforward workflows (add/commit/push) and advanced topics.
metadata:
  tags:
    - meta
---

# git

Git workflow shorthand — describe what you want, not exact commands.

## Overview

Map natural descriptions to git operations. Use concise shorthand patterns instead of verbose command chains. All paths are relative to the repo root unless stated otherwise.

## Commit Messages

`acp` rephrases descriptions into structured commit messages. First line uses [Conventional Commits](references/08-conventional-commits.md) type and summary. Body (multi-change commits) uses [Keep a Changelog](references/09-keep-a-changelog.md) categories.

## Usage

### `acp` — Auto Commit and Push

The primary workflow: fetch, sync, rephrase message, stage all, commit, push.

```
acp ["natural language description"]
```

1. **Fetch and sync** — pull latest (merge or rebase per config)
2. **Resolve conflicts** — automatic if they arise
3. **Rephrase** — convert to Conventional Commit format
4. **Stage, commit, push** — `add -A`, commit, push

If no message given, infer from staged changes.

### Command Reference

For full command tables (clone, branch, inspect, tags, remote, common workflows), see [Command Reference](references/01-command-reference.md).

## Gotchas

- **`push --force` is dangerous** — use `--force-with-lease` which rejects if others pushed. Only force when you own the branch.
- **`reset --hard` destroys uncommitted work** — stash or commit first if you might need the changes.
- **Detached HEAD** after checking out a commit/tag — create a branch immediately: `checkout -b <name>`.
- **Merge conflicts block commits** — resolve all `<<<<<<<` markers, then `add <files>` and complete.
- **`pull` defaults to merge** — use `pull --rebase` for linear history, or `git config --global pull.rebase true`.
- **Untracked files survive `reset --hard`** — use `clean -fd` to remove (irreversible).
- **Submodules need explicit init** — `submodule update --init --recursive` after clone.
- **`stash pop` fails on conflicts** — stash is preserved. Resolve, then `stash drop`.
- **`Closes #N` in commit messages closes issues** — put `Closes #228` at the end of the commit message (after the body) to auto-close issues on merge. Works on GitHub, GitLab, Gitea. See [Closing Issues](references/11-closing-issues.md) for details.

## References

- [Command Reference](references/01-command-reference.md) — command tables, shorthand, common workflows
- [Worktrees](references/02-worktrees.md) — parallel working directories on one repo
- [Request Pull](references/03-request-pull.md) — generate PR URLs for bare repos and email workflows
- [Rebase Strategies](references/04-rebase-strategies.md) — interactive rebase, merge vs rebase, when to use each
- [Stash / Reset / Revert](references/05-undo-operations.md) — detailed undo patterns, cherry-pick, revert
- [Submodules](references/06-submodules.md) — adding, updating, migrating submodules
- [Bisect and Debugging](references/07-bisect-debugging.md) — bisect, blame, log search, finding regressions
- [Conventional Commits](references/08-conventional-commits.md) — types, scopes, breaking changes, rephrasing guide
- [Keep a Changelog](references/09-keep-a-changelog.md) — categories, commit body format, CHANGELOG.md structure
- [Semantic Versioning](references/10-semver.md) — MAJOR.MINOR.PATCH rules, pre-release, bump mapping
- [Closing Issues](references/11-closing-issues.md) — auto-close issues with `Closes #N`, `Fixes #N`, `Resolves #N` in commit messages
