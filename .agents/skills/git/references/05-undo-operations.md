# Git Undo Operations Reference

Stash, reset, revert, and cherry-pick — detailed patterns for undoing and recovering work.

## Stash

Save uncommitted work without creating a commit.

```bash
# Save current changes
git stash
git stash push -m "WIP: half-done refactor"

# Save selectively
git stash push -m "db changes" src/db/
git stash push --keep-index             # keep staged, stash unstaged only

# List stashes
git stash list
# stash@{0}: WIP on main: abc123 ...
# stash@{1}: WIP on feat: def456 ...

# Apply (keep in list) or pop (remove from list)
git stash apply stash@{0}
git stash pop                           # apply and drop stash@{0}

# Create a branch from a stash
git stash branch <name> stash@{0}

# Drop without applying
git stash drop stash@{0}
git stash clear                         # remove all stashes
```

### Stash Conflicts

`stash pop` can fail with merge conflicts. The stash is preserved — resolve normally, then `git add <files>` and commit. Drop the stash manually if needed: `git stash drop`.

## Reset

Move the current branch pointer and optionally adjust index/working tree.

```bash
# Soft: move branch, keep everything staged
git reset --soft HEAD~1

# Mixed (default): move branch, unstage files, keep working tree
git reset HEAD~1

# Hard: move branch, discard everything
git reset --hard HEAD~1

# Unstage specific files (keep changes)
git reset <file>
git reset HEAD <file>

# Reset to match a remote branch
git reset --hard origin/main
```

### Three Trees

| Mode | Branch | Index (staged) | Working tree |
|---|---|---|---|
| `--soft` | moves | unchanged | unchanged |
| `--mixed` | moves | reset to target | unchanged |
| `--hard` | moves | reset to target | reset to target |

## Revert

Create a new commit that undoes changes. Safe for shared history — never rewrites existing commits.

```bash
# Revert a single commit
git revert <commit>

# Revert a range (reverse order)
git revert <oldest>^..<newest>

# Revert without auto-committing
git revert --no-commit <commit>
```

Use `revert` when the commit is already on a shared branch (`main`, `release/*`). Use `reset` for local-only undo.

## Cherry-Pick

Apply specific commits from another branch.

```bash
# Pick one commit
git cherry-pick <commit>

# Pick a range
git cherry-pick <start>^..<end>

# Pick without committing (review first)
git cherry-pick --no-commit <commit>

# Abort mid-sequence
git cherry-pick --abort
```

### Cherry-Pick vs Revert

- `cherry-pick abc` — apply changes from commit `abc`
- `revert abc` — apply inverse of changes from commit `abc`
- `revert` is equivalent to `cherry-pick` of the diff reversed

## Recovery Patterns

### "I reset --hard and need my work back"

```bash
# Find the lost commit in reflog
git reflog
# HEAD@{1}: reset: moving to HEAD~3

# Recover
git reset --hard HEAD@{1}
# or
git checkout -b recovered HEAD@{1}
```

### "I deleted a branch accidentally"

```bash
# Find last known commit of the branch
git reflog | grep <branch-name>
# or search all reflogs
git fsck --lost-found

# Recreate
git branch <name> <commit-hash>
```

### "I committed to the wrong branch"

```bash
# Option A: move commit to correct branch
git checkout main
git checkout -b correct-branch
git cherry-pick <wrong-commit>
git checkout wrong-branch
git reset --hard HEAD~1

# Option B: if nothing else was pushed
git reset --hard HEAD~1    # on wrong branch
git checkout correct-branch
git cherry-pick <commit-hash-from-reflog>
```

## Gotchas

- **`reset --hard` is irreversible** unless reflog still has the entry. Reflog entries expire after 90 days by default (`gc.reflogExpire`).
- **Stash does not track untracked files by default** — use `git stash -u` or `--include-untracked`. Without it, new files remain after stash.
- **`revert` on a merge commit** needs `--mainline <parent-number>` to specify which parent to keep.
- **`cherry-pick` can conflict** even if the original commit applied cleanly — the target branch may have diverged. Resolve normally, then `git cherry-pick --continue`.
- **Reflog is local only** — other clones do not see your reflog. You cannot recover someone else's reset from your machine.
