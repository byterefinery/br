# Conventional Commits Reference

[Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) — specification for parsing commit messages to determine semantic version bumps and generate changelogs.

## Format

```
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

- **type:** describes the kind of change
- **scope:** optional noun in parentheses indicating affected section (e.g., `auth`, `api`, `ui`)
- **description:** concise summary in imperative mood ("add" not "added", "fix" not "fixed")
- **body:** detailed explanation, motivated by the change. Use when the description is not enough.
- **footer:** references to issues, breaking change declarations

## Types

| Type | Meaning |
|---|---|
| `feat` | A new feature (→ minor version bump) |
| `fix` | A bug fix (→ patch version bump) |
| `docs` | Documentation only changes |
| `style` | Code style changes (formatting, semicolons, etc.) — no code change |
| `refactor` | Code change that neither fixes a bug nor adds a feature |
| `perf` | A code change that improves performance |
| `test` | Adding missing tests or correcting existing tests |
| `build` | Changes affecting build system or external dependencies |
| `ci` | Changes to CI configuration files and scripts |
| `chore` | Other changes that don't modify source or test files |
| `revert` | Reverts a previous commit |

Custom types are allowed (e.g., `release`, `config`) but stick to the standard set for tooling compatibility.

## Breaking Changes

Indicated by `!` after type/scope and before `:`, or by a `BREAKING CHANGE:` token in the footer.

```
feat!: rename --config to --cfg

feat(api)!: change response format from XML to JSON

fix: resolve auth timeout

BREAKING CHANGE: session tokens now expire after 1h instead of 24h
```

Multiple breaking changes can be declared in the footer with separate `BREAKING CHANGE:` entries.

## Scope

Optional, identifies the module, component, or area affected. Use project-specific conventions.

```
feat(auth): add OAuth2 login
fix(ui): correct button alignment on mobile
docs(api): update endpoint examples
chore(deps): bump lodash to 4.17.21
```

Common scope patterns: module names, file groups, feature areas, or subsystem labels.

## Footers

Key-value pairs, one per line. Key is the token name, value follows a colon and space.

```
fix: resolve race condition in event loop

Closes #42
BREAKING CHANGE: callback signature changed from (err, data) to (data, err)
```

### Keywords

| Token | Meaning |
|---|---|
| `BREAKING CHANGE` | Breaking API/behavior change |
| `Closes`, `Fixes`, `Resolves` | Reference to an issue that will be closed on merge |
| Any other key | Custom metadata (e.g., `Signed-off-by`, `Co-Authored-By`) |

Multiple issue references:
```
Closes #123, #456
```

## Rephrasing Guide

Map natural language to conventional commits:

| User says | Becomes |
|---|---|
| "fixed the login crash" | `fix(auth): handle null session on login` |
| "add avatar upload" | `feat(profile): add avatar upload` |
| "clean up old utils" | `refactor(utils): remove deprecated helpers` |
| "update README" | `docs: update setup instructions` |
| "make API faster" | `perf(api): cache response for GET /users` |
| "revert last commit" | `revert: revert "feat: add broken parser"` |
| "fix typo in config" | `fix(config): correct database port default` |

Rules for rephrasing:
- Use imperative mood ("add" not "added")
- No period at end of description
- Lowercase description unless proper noun
- Pick the most specific type (`fix` over `chore`, `feat` over `refactor`)

## Tooling

Many tools consume conventional commits:

| Tool | Purpose |
|---|---|
| `commitlint` | Lint commit messages against spec |
| `semantic-release` | Auto-version and publish based on commits |
| `conventional-changelog` | Generate changelog from commit history |
| `git cz` (Commitizen) | Interactive commit message wizard |

## Gotchas

- **Body is optional** — single-line commits are valid. Use body for multi-change or complex changes.
- **Type determines version bump** — only `feat` (minor) and `fix` (patch) trigger bumps. Breaking changes (any type with `!`) trigger major. Other types (`docs`, `chore`, etc.) do not.
- **Description is imperative** — "add feature" not "added feature". This matches git's own default merge message style.
- **Scope is project-specific** — there is no standard scope list. Define conventions per project (e.g., match directory names, module names, or feature flags).
- **Breaking change footer must start with `BREAKING CHANGE:`** — the token is case-sensitive. `breaking change:` will not be recognized by tooling.
