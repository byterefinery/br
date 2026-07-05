# Git Bisect and Debugging Reference

Find regressions, trace code origins, and search history efficiently.

## Bisect

Binary search through commit history to find the commit that introduced a bug.

```bash
# Start bisect
git bisect start

# Mark current (broken) and known-good commits
git bisect bad HEAD
git bisect good v1.0

# Git checks out a midpoint commit. Test it:
git bisect good    # if this commit is OK
git bisect bad     # if this commit is broken

# Repeat until git finds the first bad commit
# Then reset
git bisect reset
```

### Automated Bisect

```bash
# Run a test command at each step
git bisect run ./test.sh

# Exit code 0 = good, 125 = skip, any other = bad
git bisect run sh -c 'npm test && exit 0 || exit 1'
```

### Bisect with Terms

```bash
# Custom terminology (e.g., passing/failing)
git bisect start --term-new=passing --term-old=failing
git bisect passing HEAD
git bisect failing v1.0
```

### Skipping Commits

```bash
# Skip commits where the test cannot run
git bisect skip

# Skip a range
git bisect skip <range>
```

## Blame

Trace line-by-line authorship.

```bash
# Basic blame
git blame <file>

# Show specific lines
git blame -L 10,20 <file>
git blame -L func_name <file>    # by function name

# Ignore whitespace changes
git blame -w <file>

# Show commit graph (who introduced the line, not who last touched it)
git blame --graph <file>

# Date range
git blame --since="2 weeks ago" <file>
git blame --until="2025-01-01" <file>

# Stop at a rename (follow file history)
git blame --porcelain <file> | grep boundary
```

### Blame vs Announce

```bash
# Shorter output
git annotate <file>        # alias for blame
git log -n 1 -p -- <file>  # last change to file with diff
```

## Log Search

```bash
# Find commits by message
git log --grep="fix login" --oneline

# Find commits that changed a function
git log -S"def authenticate" --oneline    # pickaxe: string appearance count changed
git log -G"authenticate" --oneline        # pickaxe: regex match in diff

# Find who changed a specific line range
git log -L 10,20:<file>

# Find commits that touched multiple files
git log --all -- path1 path2

# Diffs in a compact format
git log --stat
git log --name-only
git log --diff-filter=A --oneline    # only additions
git log --diff-filter=D --oneline    # only deletions
```

## Finding Lost Work

```bash
# Reflog: local history of HEAD movements
git reflog
git reflog show <branch>

# Find dangling commits (not reachable from any branch)
git fsck --lost-found

# Recover a specific tree
git log --all --oneline --author="Name" --since="1 week ago"
```

## Debugging Workflow

### "When did this break?"

```bash
git bisect start
git bisect bad HEAD
git bisect good <last-known-good-tag-or-commit>
# ... test at each midpoint ...
git bisect reset
```

### "Who changed this function and why?"

```bash
git log -p -L :func_name:<file>     # line history of a function
git blame -L :func_name:<file>      # current authorship
git show <commit> -- <file>          # full diff of a specific commit
```

### "What changed between two versions?"

```bash
git diff v1.0..v1.1 --stat           # summary
git diff v1.0..v1.1 -- <dir>         # limited to directory
git log v1.0..v1.1 --oneline         # commit list
```

## Gotchas

- **Bisect requires a testable condition** — if you cannot automate the check, manual bisect is slow on large histories. Consider narrowing the range first with `git log --oneline`.
- **`-S` pickaxe counts occurrences** — `-S"foo"` finds commits where the number of "foo" strings changed. It does not match every commit containing "foo". Use `-G"foo"` for regex-in-diff matching.
- **Blame follows renames by default in modern git** — `git blame` tracks file moves within the same file. Cross-file renames need `--track-renames` (slow).
- **Reflog is local and expires** — entries disappear after 90 days. Push important recovery points as branches or tags.
- **Bisect skips merge commits by default** — use `--onto` for forks with merge bases, or `--no-fork-point` to include merges.
