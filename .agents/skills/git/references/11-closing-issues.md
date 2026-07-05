# Closing Issues via Commit Messages

Many Git hosting platforms (GitHub, GitLab, Gitea, Bitbucket, etc.) automatically close issues when a commit message or PR description contains a closing keyword followed by an issue number.

## Keywords

| Keyword | Effect |
|---|---|
| `Closes #N` | Closes the issue when the commit is merged to the default branch |
| `Fixes #N` | Same as Closes — closes the issue |
| `Resolves #N` | Same as Closes — closes the issue |

All three keywords work on GitHub, GitLab, and Gitea. They are case-insensitive.

## Placement

Put closing references at the **end of the commit message**, after the body:

```
feat(auth): add two-factor authentication

### Added
- TOTP-based 2FA setup and verification
- Backup codes for account recovery

Closes #228
Closes #44
Closes #910
```

Multiple issues, one per line:

```
Closes #228
Closes #44
Closes #910
```

Or comma-separated on one line:

```
Closes #228, #44, #910
```

## How It Works

- The closing keyword + issue number must appear in the commit **message** or PR **description**
- On GitHub/GitLab/Gitea, the issue closes when the commit is **merged to the default branch** (usually `main` or `master`)
- The platform links the commit to the issue automatically, even without a closing keyword — just `#N` creates a link. The keyword actually **closes** it
- Issues from the **same repository** are closed directly
- Cross-repo references (`owner/repo#N`) work on GitHub and GitLab

## Referencing Without Closing

To mention an issue without closing it, use the `#N` reference alone:

```
fix(api): handle null response from upstream

Related to #305 — full fix pending backend changes
See #228 for context
```

This creates a link but does not close the issue.

## Platform Differences

| Feature | GitHub | GitLab | Gitea |
|---|---|---|---|
| `Closes`, `Fixes`, `Resolves` | Yes | Yes | Yes |
| Cross-repo `owner/repo#N` | Yes | Yes | Yes |
| Closes on merge to default branch | Yes | Yes | Yes |
| `Refs #N` (link only) | No special keyword | Yes (`Refs`) | No special keyword |

## In Conventional Commits

Closing references belong in the **footer** section, after a blank line following the body:

```
fix(auth): resolve session expiration on idle

Sessions now persist across idle periods up to 24h.
Token refresh endpoint handles silent renewal.

Closes #42
Closes #157
```

## Gotchas

- **Issue must exist** — referencing a non-existent issue number creates a dead link but doesn't error
- **Merge target matters** — on most platforms, the issue only closes when merged to the default branch, not on feature branches
- **Direct pushes vs PRs** — closing works on both direct commits and PR merges, as long as the commit message contains the keyword
- **Case insensitive** — `closes`, `CLOSES`, `Closes` all work
- **No partial matches** — `Closed #42` won't work; it must be the exact keyword `Closes`, `Fixes`, or `Resolves`
- **Multiple issues** — each gets its own line or comma-separated list; don't bury them in body text
- **MR on GitLab** — GitLab also recognizes `Closes !N` for merge requests, in addition to `#N` for issues
