# Git Submodules Reference

Embed one repository inside another at a specific commit. The outer repo tracks the submodule's URL and commit hash; the submodule's working tree is managed separately.

## Adding a Submodule

```bash
# Add at a path, tracking default branch
git submodule add <url> <path>

# Track a specific branch
git submodule add -b main <url> <path>

# Shallow clone (depth 1)
git submodule add --depth 1 <url> <path>
```

Creates/updates `.gitmodules` (tracked in the repo) and `.git/modules/<path>/` (local git metadata).

## Cloning with Submodules

```bash
# Clone + init + update submodules in one step
git clone --recurse-submodules <url>

# Already cloned — initialize later
git submodule update --init --recursive
```

Without `--init`, submodule directories exist but are empty. Without `--recursive`, nested submodules (submodules inside submodules) are skipped.

## Updating Submodules

```bash
# Update to the commit recorded in the superproject
git submodule update

# Update and fetch if missing objects
git submodule update --init --recursive --remote

# Pull latest from each submodule's remote (moves the tracked commit)
git submodule foreach 'git pull'
```

### Updating a Submodule's Version

```bash
# Enter the submodule directory
cd <submodule-path>
git checkout main
git pull
cd -

# Record the new commit in the superproject
git add <submodule-path>
git commit -m "bump submodule to latest"
git push
```

The superproject tracks a specific commit hash. Changing it requires a commit in the outer repo.

## Common Operations

```bash
# List submodules
git submodule status
# +abc123 vendor/lib  (dirty/modified)
#  def456 vendor/lib  (clean, matches superproject)

# Run a command in all submodules
git submodule foreach 'git status'
git submodule foreach 'git pull origin main'

# Deinit (remove working tree, keep config)
git submodule deinit <path>
git submodule deinit --all

# Remove entirely
git submodule deinit <path>
git rm <path>
rm -rf .git/modules/<path>
```

## URL Configuration

`.gitmodules` stores relative or absolute URLs:

```ini
[submodule "vendor/lib"]
    path = vendor/lib
    url = https://github.com/user/lib.git
```

### Relative URLs

If the superproject remote is `https://github.com/user/project.git`, a relative URL `../lib.git` resolves to `https://github.com/user/lib.git`. Useful for orgs with consistent repo layouts.

### Syncing URLs

```bash
# Update local URLs from .gitmodules (after URL changes)
git submodule sync
git submodule update --init --recursive
```

## Gotchas

- **Cloning without `--recurse-submodules` leaves empty directories** — the most common mistake. Always use `--recurse-submodules` or run `submodule update --init --recursive` after clone.
- **Submodules point to commits, not branches** — checking out a different branch in the superproject may move the submodule to a different commit. Run `submodule update` after checkout.
- **`git diff` shows submodule changes as "new commits"** — not file diffs. Use `git diff --submodule` or enter the submodule and run `git diff` directly.
- **CI/CD must recurse** — most CI systems need explicit `--recurse-submodules` in their clone step. Check your pipeline config.
- **Moving/renaming a submodule is fragile** — `git mv` works for the superproject, but `.git/modules/` paths may need manual cleanup. Consider deleting and re-adding instead.
- **Shallow submodules cannot be deepened easily** — `--depth 1` saves bandwidth but prevents `git log` beyond one commit inside the submodule. Use `git submodule foreach 'git fetch --unshallow'` if needed.

## Alternatives

Consider these before adding submodules:

- **Git subtrees** (`git subtree add/pull`) — embed repo contents as regular files, no separate git state. Simpler but larger history.
- **Package managers** — prefer language-native deps (npm, pip, cargo) when available.
- **Monorepo tools** — nx, turborepo, bazel manage multi-package repos without submodules.
