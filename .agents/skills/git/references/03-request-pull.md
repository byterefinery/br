# Git Request-Pull Reference

Generate pull request summaries for email-based workflows, bare repositories, and projects without a hosted git service (GitHub/GitLab).

## What It Does

`git request-pull` produces a human-readable summary describing what commits should be pulled from where. Output includes commit log, ref names, and the URL/path to fetch from. Used in kernel-style development and any workflow where PRs go through email or chat instead of a web UI.

## Syntax

```bash
git request-pull <start-point> <url> [<end-point>]
```

- `<start-point>` — commit/branch both sides share (merge base, last tagged release)
- `<url>` — where the new commits can be fetched from
- `<end-point>` — branch tip to pull (defaults to HEAD)

## Examples

```bash
# Summarize changes since v1.0 on a public repo
git request-pull v1.0 https://github.com/user/project.git

# Changes on a feature branch since main
git request-pull main https://github.com/user/project.git feat/login

# Local bare repo (e.g., shared drive, server)
git request-pull v2.1 /srv/git/project.git release/v2.2

# Pipe to email
git request-pull main git@server:project.git > pull-request.txt
mail -s "PR: new auth module" maintainer@example.com < pull-request.txt
```

## Output Format

```
The following changes since commit abc1234:

  Author Name (2025-01-15 10:30:00 +0000)

        v1.0 release

are available in the Git repository at:

  https://github.com/user/project.git

for you to fetch changes up to def5678:

  Developer Name (2025-01-20 14:00:00 +0000)

        feat: add login module

---

Commit 1: feat: add login page
Commit 2: fix: handle OAuth callback
Commit 3: docs: update auth guide
```

## Typical Workflow

### Contributor side

```bash
# Push changes to a personal fork or shared repo
git push origin feat/new-feature

# Generate pull request summary
git request-pull main https://github.com/me/fork.git feat/new-feature \
  | mail -s "PR: new feature" upstream-maintainer@example.com
```

### Maintainer side

```bash
# Receive the email with request-pull output
# Fetch the proposed changes
git fetch https://github.com/me/fork.git feat/new-feature

# Review
git log main..FETCH_HEAD
git diff main..FETCH_HEAD

# Merge if approved
git merge FETCH_HEAD --no-edit
```

## Tips

- **Use tags as start points** — `v1.0` is clearer than a commit hash. Both sides recognize it.
- **`--from` flag** — customize the "available in" section header
- **Combine with `format-patch`** — for email-based patch series:
  ```bash
  git format-patch main --cover-letter
  # Edit 0000-cover-letter.patch with context
  git send-email --to=maintainer@example.com 0000*.patch
  ```
- **Bare repos** — `request-pull` is the primary tool for bare repositories since there is no working tree to diff against directly

## Gotchas

- **Start point must be reachable from end point** — if the branches diverged and were rebased, the merge base may not match what you expect. Verify with `git merge-base <start> <end>`.
- **URL must be accessible to the recipient** — a local path like `/srv/git/repo.git` only works on shared filesystems. Use SSH or HTTPS URLs for remote recipients.
- **Does not create actual PR objects** — this is a text summary. The recipient manually fetches and merges. No CI, no review UI, no automated checks.
