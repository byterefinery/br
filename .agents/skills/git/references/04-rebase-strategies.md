# Git Rebase Strategies Reference

When to rebase, when to merge, and how to do interactive rebases cleanly.

## Merge vs Rebase

| | Merge | Rebase |
|---|---|---|
| History | Preserves exact timeline with merge commits | Rewrites history into linear sequence |
| Commits | Keeps original hashes | Creates new commit hashes |
| Shared branches | Safe — never rebase published commits | Dangerous — breaks others' history |
| Readability | Can get noisy with many merge commits | Clean, linear log |
| Blame | Accurate (original authors preserved) | Accurate (`--rebase-merges` helps) |

**Rule of thumb:** merge for integrating public/shared branches, rebase for cleaning up local work before sharing.

## Basic Rebase

```bash
# Rebase current branch onto main
git checkout feat/login
git rebase main

# Rebase onto a specific branch
git rebase develop feat/login

# Equivalent to pull --rebase
git pull --rebase origin main
```

## Interactive Rebase

```bash
# Last 5 commits
git rebase -i HEAD~5

# Since a named branch
git rebase -i main
```

Opens an editor with:

```
pick abc123 feat: add login form
pick def456 fix: validate email
pick ghi789 docs: update README
pick jkl012 feat: add logout button
```

### Commands

| Command | Effect |
|---|---|
| `pick` | Keep commit as-is |
| `reword` | Change commit message |
| `edit` | Stop to amend (change files, message, split) |
| `squash` | Merge into previous commit |
| `fixup` | Merge into previous, discard this message |
| `drop` | Delete the commit |

### Common Patterns

**Squash a feature into one commit:**
```
pick abc123 feat: add login form
fixup def456 fix: validate email
fixup jkl012 feat: add logout button
```

**Reorder commits:**
```
pick jkl012 feat: add logout button
pick abc123 feat: add login form
```
(Rearrange lines. Be careful — later commits may depend on earlier ones.)

**Split a commit:**
```
edit abc123   # stops at this commit
git reset HEAD~1    # unstage all changes
# ... stage subsets with `git add` ...
git commit -m "first part"
git add <rest>
git commit -m "second part"
git rebase --continue
```

## Rebase Merges

Preserve merge topology during rebase (Git 2.38+):

```bash
git rebase --rebase-merges main
```

Useful when your branch has intentional merge commits (e.g., backports, release branches).

## Aborting and Resolving Conflicts

```bash
# Abort a rebase in progress
git rebase --abort

# Skip the problematic commit
git rebase --skip

# Edit the current commit
git rebase --edit-current-commit

# After resolving conflicts:
git add <resolved-files>
git rebase --continue
```

## When NOT to Rebase

- **Published branches** — any branch others have cloned or based work on. Rebasing rewrites hashes, forcing everyone to reset.
- **Shared integration branches** — `main`, `develop`, `release/*`. Merge these, never rebase.
- **After teammates pushed** — if someone else added commits to your branch since you last fetched, rebasing will orphan their work.

## Auto-Rebase Config

```bash
# Always rebase on pull
git config --global pull.rebase true

# Only rebase if no merge base (new branch)
git config --global pull.rebase merges
```

## Gotchas

- **Rebase creates new hashes** — after rebasing, `push` requires `--force-with-lease`. This is expected and correct for local branches.
- **Conflicts can repeat** — if a conflict appeared in an earlier commit, it may reappear later in the rebase. Resolve identically each time.
- **`edit` mode pauses the rebase** — after amending, run `git rebase --continue`, not `git commit` again.
- **Large rebases are slow** — rebasing 100+ commits with binary files can take minutes. Consider merging instead if history is already clean.
