# Git Worktrees Reference

Manage multiple working directories from one repository. Each worktree has its own index and working tree but shares commits, refs, and objects with the main repo.

## Why Worktrees

- Switch branches instantly without checking out (no need to stash)
- Review a PR branch while working on another feature
- Run long builds/tests on one branch while editing on another
- Avoid dirty-tree checkout conflicts

## Commands

```bash
# Create a new worktree linked to the main repo
git worktree add <path> <branch-or-commit>
git worktree add ../my-feature feat/login        # new branch at path
git worktree add ../review abc123                # detached HEAD at commit

# List all worktrees
git worktree list

# Remove a worktree (must be outside the repo)
git worktree remove <path>
git worktree prune                              # clean up stale entries

# Move a worktree
git worktree move <old-path> <new-path>
```

## Typical Setup

```bash
# Main repo at byterefinery-skills/
cd byterefinery-skills

# Feature branch in sibling directory
git worktree add ../byterefinery-skills-feat feat/new-feature

# Review branch in another sibling
git worktree add ../byterefinery-skills-review origin/pr-42
```

Directory layout:
```
project/                      # main worktree (main branch)
project-feat/                 # worktree (feat branch, same .git objects)
project-review/              # worktree (review branch)
```

Each worktree has a `.git` file pointing back to the main repo's gitdir.

## Rules and Limitations

- **One branch checked out at a time** — you cannot have two worktrees on the same branch unless one is in detached HEAD state or `--detach` is used
- **Shared object store** — all worktrees share `.git/objects`. Deleting objects from one affects all. Pruning in main prunes for all.
- **Locking** — git prevents destructive operations across worktrees (e.g., force-deleting a branch checked out elsewhere)
- **Paths must be outside the main repo** — cannot nest a worktree inside its own repository tree
- **No submodules auto-update** — each worktree manages submodules independently

## Workflow Patterns

### Review a PR without leaving your branch

```bash
# On main, working on something
git fetch origin pull/42/head:pr-42
git worktree add ../review pr-42
cd ../review
# ... inspect, test, build ...
cd -
git worktree remove ../review
```

### Parallel development with tests

```bash
git worktree add ../test-build main
cd ../test-build
./run-long-tests.sh   # runs in background
cd -                  # back to main, keep coding
```

## Gotchas

- **`git branch -d` refuses if branch is checked out in another worktree** — use `git worktree remove <path>` first, or `git branch -D` (force)
- **Hooks are shared** — hooks live in the main repo's `.git/hooks/`. They fire for all worktrees. Per-worktree hooks: set `core.hooksPath` per-worktree config
- **`.gitignore` is shared** — ignore rules apply to all worktrees identically
- **After `worktree remove`, prune refs** — stale refs may linger. Run `git worktree prune` and `git remote prune origin`
