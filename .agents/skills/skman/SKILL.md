---
name: skman
description: Introduces the Agent Skills System — a standardized, lightweight, open format for extending AI agent capabilities with specialized knowledge and workflows. Use for scaffolding, validating, and inspecting agent skills (SKILL.md files and other skill's files and directories).
metadata:
  tags:
    - meta
    - agent
    - skill
    - skills
    - agent skill system
---

# skman

Tools and guidelines for creating, validating, and managing agent skills. Use `skman.sh` to scaffold new skill directories, check format compliance, inspect structure, and regenerate the repository README.

## Overview

Agent Skills are a lightweight, open format for extending AI agent capabilities with specialized knowledge and workflows. An agent skill is a directory containing a `SKILL.md` file — frontmatter metadata (skill's YAML header) plus concise instructions — optionally accompanied by scripts, references, and assets. This standardized format gives agents new expertise on demand without bloating the context window.

`skman` is the skill for creating, validating, and managing agent skills. It provides four functionalities:

- **`create`** — Scaffold a new skill directory with SKILL.md, optional scripts, and references
- **`validate`** — Check a skill against the format specification (frontmatter, naming, structure)
- **`info`** — Inspect frontmatter, body stats, and heading hierarchy
- **`generate`** — Regenerate the repository README.md with skills table and statistics

## Usage

```bash
# Scaffold a new skill
skman.sh create <name> "<description>"

# Create with version (dir: demo-skill-2-4-1/, H1: # demo-skill 2.4.1)
skman.sh create demo-skill "Dummy example skill" --version 2.4.1

# Create with scripts and references
skman.sh create my-skill "Desc" --with-scripts --with-references

# Validate a single skill
skman.sh validate ./my-skill
skman.sh validate --strict ./my-skill

# Validate all skills in a collection directory
skman.sh validate .agents/skills
skman.sh validate ./skills-python

# Inspect frontmatter and structure
skman.sh info ./my-skill

# Regenerate README.md Skills Table and Statistics
skman.sh generate

# Help at every level
skman.sh --help
skman.sh create --help
skman.sh validate --help
skman.sh info --help
skman.sh generate --help
```

### Scaffold New Skill

```bash
# Into default location (.agents/skills/my-skill/)
skman.sh create my-skill "Extracts text from PDF files"

# With version (dir: demo-skill-2-4-1/, H1: # demo-skill 2.4.1)
skman.sh create demo-skill "Dummy example skill" --version 2.4.1

# With scripts and references
skman.sh create my-skill "Desc" --with-scripts --with-references

# Into a specific parent directory
skman.sh create my-skill "Desc" -o ./custom-skills
```

The script validates name and description before creating files.

### Validate

Run the built-in validator on a single skill or an entire collection:

```bash
# Single skill
skman.sh validate ./my-skill
skman.sh validate --strict ./my-skill

# All skills in a collection directory
skman.sh validate .agents/skills
skman.sh validate ./skills-python
```

## Skill Format

A skill is a directory containing a `SKILL.md` file. Everything else is optional.

### Directory Layout

```
<skill-name>/
├── SKILL.md              # Required: frontmatter + instructions
├── scripts/              # Optional: helper scripts (executed, not loaded into context)
│   └── <skill-name>.sh   # Bash entry point — referenced in SKILL.md

> Use `skman.sh create --with-scripts` to scaffold the bash wrapper.
├── references/           # Optional: detailed docs loaded on demand (numbered prefix)
│   └── 01-topic.md
│   └── 02-abc.md
│   └── 03-xyz.md
├── assets/               # Optional: templates, images, data files, schemas
│   └── template.yaml
```

### Frontmatter Fields

| Field | Required | Rules |
|---|---|---|
| `name` | Yes | 1-64 chars, lowercase letters (including Unicode/i18n), 0-9, hyphens; no leading/trailing/consecutive hyphens; must match directory name exactly (e.g., `demo-skill-2-4-1` for `demo-skill-2-4-1/`); meta skills without versions use plain name (e.g., `skman`, `plan`) |
| `description` | Yes | Non-empty, max 1024 chars, third-person, must not contain XML/HTML tags (`<tag>`) |
| `license` | No | License name or reference to a bundled license file (e.g., `Apache-2.0`, `Proprietary. LICENSE.txt has complete terms`) |
| `compatibility` | No | Max 500 chars. Environment requirements — intended product, system packages, network access. Only include if the skill has specific needs |
| `allowed-tools` | No | Space-separated string of pre-approved tools the skill may use (experimental; support varies by agent) |
| `metadata` | No | Optional object. May contain `tags` (array of strings, e.g., `["meta", "devops"]`). Validator warns if `metadata` is not a mapping or `tags` is not a string array.

### Frontmatter Template

```yaml
---
name: my-skill
description: What this skill does and when to use it. Be specific.
license: Apache-2.0
compatibility: Requires Python 3.11+ and uv
allowed-tools: Bash(git:*) Read
metadata:
  tags:
    - dev
---
```

## Creating a New Skill

Follow these steps in order:

1. **Choose a name** — lowercase, hyphens, numbers only (e.g., `pdf-processing`, `git-8-20-0`). No leading/trailing/consecutive hyphens.

2. **Write the frontmatter** — exactly `name` and `description` at minimum. The `name` must match the directory name exactly (e.g., `name: demo-skill-2-4-1` for `demo-skill-2-4-1/`). The description determines when the agent loads this skill; make it specific.

3. **Write the body** — concise instructions, under 5000 tokens. Must start with a level-1 heading matching `# <name>` or `# <name> <version>`. Structure:
   - `# <name>` (e.g., `# skman`) or `# <name> <version>` (e.g., `# demo-skill 2.4.1`)
   - `## Overview` — what it does
   - `## Usage` — Optional: how to use it with examples
   - `## Gotchas` — Optional: The most useful part of teaching a skill is listing its hidden traps. Instead of vague advice, provide specific rules that stop the agent from making predictable, common-sense mistakes in that specific environment.
   - `## References` — Optional: Provides on-demand reference material for agents. Always use a bulleted list, never a table:
     ```
     ## References

     - [01-core-expressions](references/01-core-expressions.md) — Symbols, expressions, numbers
     - [02-algebra-polynomials](references/02-algebra-polynomials.md) — Polynomial rings, factoring
     ```
     Each line: link to the file followed by a dash and a brief topic summary.

4. **Create scripts** — only when the user explicitly requests them. The main script is always `scripts/<skill-name>.sh` (bash). Dependent scripts use whatever language the user specifies (Python, JS/Node/Bun/Deno, Lua, Bash, etc.) — never assume a language. Scripts are **executed** (not loaded into context). The SKILL.md references the `.sh` entry point. Include `--help` at every level. Scaffold with `--with-scripts`.

5. **Validate** — run the validation script:
   ```bash
   skman.sh validate <path-to-skill>
   ```

### Manual Creation

When writing files directly, ensure:
- Directory is named after the skill (e.g., `skman`) or `<skill-name>-<version>` (e.g., `demo-skill-2-4-1`)
- Frontmatter `name` must match the directory name exactly (e.g., `name: demo-skill-2-4-1` for `demo-skill-2-4-1/`, or `name: skman` for `skman/`)
- `SKILL.md` exists at the directory root
- Body starts with `# <name>` or `# <name> <version>` matching the directory (e.g., `# demo-skill 2.4.1` for `demo-skill-2-4-1/`)

## Editing a Skill

Common operations:

- **Update description** — edit the frontmatter; this is what agents see in the system prompt
- **Split long content** — move sections >100 lines into `references/NN-topic.md`, link from SKILL.md
- **Add a script** — place in `scripts/` with the skill's name as base name
- **Restructure references** — keep references one level deep; all should link directly from SKILL.md

## Validation

Checks performed:
- Frontmatter presence and required fields
- Name format (case, characters, length, hyphen rules)
- Description presence, length, and absence of XML/HTML tags
- `metadata` structure (warns if present but not a mapping; warns if `tags` is not a string array)
- Body starts with a level-1 heading
- Body token estimation warning (>5000 tokens)
- Name vs directory basename consistency (warns on mismatch)
- H1 heading format (`# <name>` or `# <name> <version>` — errors on mismatch)
- Recommended section presence (`## Overview` — warns if missing)
- Truly optional sections (`## Usage`, `## Gotchas`, `## References` — no warning when absent)
- Script executability (`<name>.sh` must be `chmod +x` — warns if not)
- Script usage references (`./<name>.sh` → `<name>.sh` — warns if the body uses `./<name>.sh` outside fenced code blocks)

## Best Practices

### Conciseness
- Context window is shared — every token competes with conversation history
- Default assumption: the model already knows basics (what PDFs are, how libraries work)
- Challenge each paragraph: "Does this justify its token cost?"

### Scripting
- **Main script is always `scripts/<name>.sh`** (bash) — the entry point referenced in SKILL.md
- **Dependent scripts use whatever language the user specifies** — Python, JS (Node/Bun/Deno), Lua, Bash, or anything else. Never assume a language; ask the user or wait for their suggestion
- Any libraries, frameworks, or dependencies are allowed when the user explicitly requests them

### Match Specificity to Task Fragility
- **High freedom** (text instructions): multiple valid approaches, context-dependent decisions
- **Medium freedom** (pseudocode/scripts with parameters): preferred pattern exists, some variation OK
- **Low freedom** (exact commands): fragile operations, consistency is critical

### Description Writing
- Always third person ("Processes Excel files" not "I can help you")
- Include both what the skill does and when to use it
- Include relevant context (file extensions, tool names, task types) so the agent knows when to apply the skill

### Writing Style
- **Use imperative voice** — "Run this command" not "You should run this command"
- **Explain the why, avoid rigid MUST/ALWAYS/NEVER in caps** — modern models respond better to reasoning than rigid commands. If something is critical, explain why it matters

### Progressive Disclosure
Skills use a four-level loading system:

1. **Metadata** (name + description) — always in context (~100 words). Always visible to the agent.
2. **SKILL.md body** — loaded on demand (<5000 tokens ideal). Contains the core instructions.
3. **Scripts** — executed (not loaded into context). Run via `<name>.sh`.
4. **References** — loaded as needed (unlimited). Reference files load on demand.

Guidelines:
- Keep SKILL.md body under 5000 tokens
- Move detailed content to `references/` files linked from SKILL.md
- Avoid deeply nested references — all reference files should link directly from SKILL.md
- Include a table of contents in reference files longer than 100 lines
- **Reference file naming** — use numeric prefixes (`01-`, `02-`, `03-`, …) for deterministic ordering and easy insertion. Files should be named `NN-topic.md` where `NN` is an incrementing number starting from 01
- **Multi-domain skills** — when a skill supports multiple variants (frameworks, platforms), organize by domain in references:
  ```
  cloud-deploy/
  ├── SKILL.md              # workflow + variant selection logic
  └── references/
      ├── 00-aws.md
      ├── 01-gcp.md
      └── 02-azure.md
  ```

### Model Compatibility
- SLMs (small models): need more explicit guidance, numbered steps, less ambiguity
- LLMs (large models): prefer concise instructions, avoid over-explaining
- Aim for instructions that work across both: clear structure, explicit rules, no fluff

## Gotchas

- **Never create `scripts/` or `assets/` automatically** — these directories are only created when the user explicitly asks for them. `skman.sh create` does not generate them by default; use `--with-scripts` only on direct user request. Never scaffold scripts or assets without being asked.
- **Scaffolded `.sh` files may lose execute permission** — `skman.sh create --with-scripts` sets `chmod 0o755`, but editors or git checkouts can strip it. Always verify with `ls -l <name>.sh`; the validator warns if the bit is missing.
- **`--strict` turns section warnings into errors** — only `## Overview` produces a warning when missing. `## Usage`, `## Gotchas`, and `## References` are truly optional and never warn (knowledge-only skills often have no Usage section). In strict mode, any warning fails validation.
- **Frontmatter `name` must match the directory basename exactly** — e.g., `demo-skill-2-4-1/` requires `name: demo-skill-2-4-1`, `skman/` requires `name: skman`. The validator warns on mismatch. Fix by renaming the directory or correcting the frontmatter.
- **H1 heading must match `# <name>` or `# <base> <version>`** — the validator errors if the first heading doesn't match. For `skman/` it must be `# skman`; for `demo-skill-2-4-1/` it must be `# demo-skill 2.4.1` (version uses dots, not hyphens). The version in the H1 must correspond to the hyphenated version suffix in the directory/frontmatter name.
- **Reference files are loaded on demand, not into context** — keep SKILL.md self-contained for core instructions; move deep-dive content to `references/NN-topic.md` and link from the body.
- **Clone repos locally before studying them** — when a URL is given as source material to study or analyze for writing a skill, check whether it points to a code repository (GitHub, GitLab, Bitbucket, etc.). If so, clone it into a temporary directory first and read files from the local copy. Fetching individual files over the network is expensive in both time and rate limits; a single `git clone` gives you the full tree instantly. Clean up the temp directory after analysis.
