# Semantic Versioning Reference

[Semantic Versioning](https://semver.org/) — version scheme where the version number communicates the kind of change made.

## Format

```
MAJOR.MINOR.PATCH
```

Example: `2.1.0`

- **MAJOR** — incompatible API changes
- **MINOR** — functionality added in a backward-compatible manner
- **PATCH** — backward-compatible bug fixes

Additional labels for pre-release and build metadata are available as extensions to the `MAJOR.MINOR.PATCH` format (e.g., `1.0.0-alpha.1`, `2.0.0+build.123`).

## Version Bump Rules

| Change | Bump | Example |
|---|---|---|
| Incompatible API change | MAJOR | `1.x.x` → `2.0.0` |
| New backward-compatible feature | MINOR | `1.0.x` → `1.1.0` |
| Backward-compatible bug fix | PATCH | `1.0.0` → `1.0.1` |

### Examples

**MAJOR (breaking):**
- Remove a public function
- Change argument types or order
- Rename an endpoint
- Drop support for a language/runtime version

**MINOR (additive, compatible):**
- Add a new optional parameter with a default value
- Add a new endpoint or method
- Extend an enum with a new value (if consumers handle unknown values)

**PATCH (fix, compatible):**
- Fix a null pointer exception
- Correct a calculation error
- Update a dependency to a compatible version

## Pre-Release Versions

Append after a hyphen. Indicates an unstable version before official release.

```
1.0.0-alpha
1.0.0-alpha.1
1.0.0-beta.2
1.0.0-rc.1
```

Pre-release versions have lower precedence than the normal version. `1.0.0-alpha` < `1.0.0`.

Multiple dot-separated identifiers compare numerically if numeric, lexicographically otherwise:
```
1.0.0-alpha < 1.0.0-alpha.1 < 1.0.0-beta < 1.0.0-rc.1 < 1.0.0
```

## Build Metadata

Append after a plus sign. Ignored when determining version precedence.

```
1.0.0+20250611
1.0.0-beta.1+sha.abc1234
```

Build metadata is for internal tracking (CI builds, commit hashes) and should not affect dependency resolution.

## Leading Zeros

Numeric version identifiers MUST NOT include leading zeros. `1.02.0` is invalid — use `1.2.0`.

## Relationship with Conventional Commits

Conventional Commits map directly to semver bumps:

| Commit Type | Semver Bump |
|---|---|
| `feat` | MINOR |
| `fix` | PATCH |
| Any type with `!` or `BREAKING CHANGE:` | MAJOR |
| `docs`, `style`, `refactor`, `perf`, `test`, `chore`, `build`, `ci` | none (no version bump) |
| `revert` | depends on what was reverted — usually PATCH if reverting a bug, MINOR if reverting a feature |

Tools like `semantic-release` automate version bumps by parsing commit messages and applying these rules.

## In Practice

### Versioning a Library

```
0.1.0  — initial release (pre-1.0, anything can change)
0.2.0  — added new API endpoint (MINOR, still pre-1.0)
1.0.0  — stable API (MAJOR, first production release)
1.0.1  — fixed auth bug (PATCH)
1.1.0  — added export feature (MINOR)
2.0.0  — removed legacy XML support (MAJOR, breaking)
```

### Versioning Internal Tools

Semver is meaningful when others depend on your output. For internal scripts or private tools, version numbers are less critical — use dates or simple incrementing numbers if preferred.

## Gotchas

- **`0.y.z` is special** — anything can change at any time. The public API is not stable until `1.0.0`. Use this for initial development.
- **Minor additions can be breaking for strict consumers** — adding a required field to a config object is technically additive but breaks existing configs. Judge by actual consumer impact, not just the code change.
- **Private APIs don't count** — internal functions, `_private` methods, and undocumented behavior are fair game for MAJOR-free changes. Only the documented public API matters.
- **Semver is a contract with consumers** — if nobody depends on your library, version numbers are informational only. Be consistent regardless.
- **Build metadata is ignored by comparators** — `1.0.0+build.1` and `1.0.0+build.2` are equal for dependency resolution. Use pre-release tags for ordering unstable versions.
