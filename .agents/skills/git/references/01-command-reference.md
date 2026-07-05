# Git Command Reference

Shorthand patterns mapped to git commands. All paths relative to repo root unless stated otherwise.

## Start / Clone

```
clone <url>                    # git clone <url>
init                           # git init
init --bare                    # git init --bare (remote/bare repo)
```

## Stage / Commit / Push

```
add <files>                    # git add <files>
add -A                         # stage everything (new, modified, deleted)
commit "msg"                   # git commit -m "msg"
commit --amend                 # rewrite last commit message or add files
acp ["msg"]                    # fetch + merge/rebase (resolve conflicts), rephrase msg → Conventional Commit, then add -A && commit && push
push                           # git push
push --force-with-lease        # safe force push (rejects if remote has new commits)
push --set-upstream origin <br> # git push -u origin <br>
```

### `acp` Workflow

Takes an optional natural-language description. Before committing:

1. **Fetch and sync** — pull latest from remote (merge or rebase depending on config)
2. **Resolve conflicts** — if merge/rebase conflicts arise, resolve them automatically
3. **Rephrase message** — convert description to Conventional Commit format (see [07-conventional-commits.md](07-conventional-commits.md))
4. **Stage, commit, push** — `add -A`, commit with rephrased message, push

If no message given, infer one from the staged changes.

## Fetch / Pull

```
fetch                          # git fetch (download, don't merge)
pull                           # git pull (fetch + merge)
pull --rebase                  # git pull --rebase (fetch + rebase onto remote)
fetch --all --prune            # clean up stale remote tracking branches
```

## Branching

```
branch <name>                  # git branch <name>
checkout <name>                # git switch <name> (or git checkout <name>)
checkout -b <name>             # create and switch to new branch
checkout -- <files>            # discard working tree changes in files
merge <branch>                 # git merge <branch>
delete <branch>                # git branch -d <branch>
delete --force <branch>        # git branch -D <branch>
branches                       # list local branches
branches -r                    # list remote tracking branches
```

## Inspect

```
status                         # git status
log                            # git log --oneline --graph --all
log <n>                        # last n commits
diff                           # unstaged changes
diff --staged                  # staged but not committed
show <commit>                  # show commit details
show :<file>                   # show file content at current tree (staged)
blame <file>                   # git blame <file> (line-by-line authorship)
who <file>                     # short: git log -1 --format='%an <%ae>' -- <file>
```

## Tags

```
tag <name>                     # lightweight tag
tag -a <name> -m "msg"         # annotated tag
push --tags                    # push tags to remote
delete-tag <name>              # git tag -d <name>
push --delete origin <name>    # delete remote tag
```

## Remote

```
remotes                        # git remote -v
remote add <name> <url>        # add remote
remote set-url <name> <url>    # change remote url
remote rename <old> <new>      # rename remote
```

## Common Workflows

### Quick fix on main

```
checkout main
pull
acp "fixed the login crash when token expires"
# → rephrases to: fix(auth): handle expired token gracefully
```

### Feature branch

```
checkout -b feat/<name>
... work ...
acp "add user profile page with avatar upload"
# → rephrases to: feat(profile): add user profile page with avatar upload
```

### Clean up after merge

```
checkout main
pull
delete <merged-branch>
fetch --all --prune
```

### Undo local changes (quick)

```
checkout -- <files>            # discard unstaged file changes
reset HEAD~1                   # uncommit last commit (keep changes staged)
reset --hard HEAD~1            # drop last commit entirely
```

For detailed undo patterns (stash, cherry-pick, recovery), see [04-undo-operations.md](04-undo-operations.md).
