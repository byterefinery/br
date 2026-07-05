# Keep a Changelog Reference

[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) — guidelines for human-readable changelogs. Used as the body format in commit messages and `CHANGELOG.md` files.

## Format

```markdown
## [version] - YYYY-MM-DD

### Added
- New feature for users

### Changed
- Something that changed

### Deprecated
- Soon-to-be removed feature

### Removed
- Feature removed in this release

### Fixed
- Bug fix description

### Security
- Vulnerability details
```

- **Version:** semantic version (`1.0.0`), branch name, or commit hash for unreleased work
- **Date:** ISO 8601 format (YYYY-MM-DD)
- **Categories:** ordered as shown above. Omit empty categories.
- **Entries:** descriptive bullet points, written for the user or developer reading them

## Categories

| Category | Use For |
|---|---|
| `Added` | New features, endpoints, options |
| `Changed` | Modifications to existing features |
| `Deprecated` | Features marked for removal |
| `Removed` | Features removed in this release |
| `Fixed` | Bug fixes |
| `Security` | Vulnerability patches, CVE references |

Custom categories are allowed (`Improved`, `Updated`) but prefer the standard six for consistency.

## In Commit Messages

The body of a conventional commit uses Keep a Changelog categories to describe what changed:

```
feat(profile): add avatar upload and settings page

### Added
- profile page with avatar upload
- user settings panel for theme and notifications

### Changed
- auth middleware now returns user preferences in response
```

Rules for commit bodies:
- **Only include changed categories** — omit empty ones
- **Be specific** — "avatar upload" not "new stuff"
- **Reference affected components** — "auth middleware", "login form", "API v2 endpoint"
- **Use bullet points** — one change per line
- **Omit body for single-change commits** — if the description line covers everything, skip the body

## In CHANGELOG.md

Project-level changelog aggregates releases:

```markdown
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.1.0] - 2025-06-10

### Added
- User avatar upload via profile page
- Dark mode toggle in settings

### Changed
- Login redirects to last visited page instead of dashboard
- API rate limit increased from 100 to 500 requests/min

### Fixed
- Session timeout not respecting config value
- Date picker showing wrong timezone on mobile

## [2.0.0] - 2025-05-01

### Added
- OAuth2 authentication support
- REST API v2 endpoints

### Removed
- Legacy XML API (use JSON endpoints)
- Session cookie auth (migrate to token-based)

### Security
- Fixed JWT signature verification bypass (CVE-2025-1234)
```

## Linking Versions

Use anchor links for navigation:

```markdown
[2.1.0]: https://github.com/user/project/compare/v2.0.0...v2.1.0
[2.0.0]: https://github.com/user/project/compare/v1.9.0...v2.0.0
```

Or relative links:

```markdown
[Unreleased]: /compare/v2.1.0...HEAD
[2.1.0]: /compare/v2.0.0...v2.1.0
```

## Writing Style

- **Describe the change, not the implementation** — "login now redirects to last page" not "added redirect middleware in auth.js"
- **Use past tense for `Fixed`, present for others** — "Fixed session timeout" but "Added avatar upload"
- **Reference issues when applicable** — "Fixed null pointer on empty search (#42)"
- **Group related changes** — multiple fixes to the same component can share a bullet with sub-points

## Unreleased Section

Track upcoming changes before release:

```markdown
## [Unreleased]

### Added
- Export data to CSV format

### Fixed
- Crash on empty search results
```

On release, rename `[Unreleased]` to the version number and date, then add a new `[Unreleased]` section.

## Gotchas

- **Categories are ordered** — `Added` before `Changed` before `Fixed`. Do not reorder.
- **Omit empty categories** — do not include `### Fixed` with no entries. It adds noise.
- **Not all changes need a changelog entry** — internal refactors, dependency bumps (unless they affect behavior), and test-only changes belong in commits but not the changelog.
- **Keep it human-readable** — the audience is people reading the log, not machines parsing it. Write for clarity over brevity.
- **`CHANGELOG.md` vs commit messages** — changelogs aggregate user-visible changes per release. Commit bodies describe what that specific commit changed. Same format, different granularity.
