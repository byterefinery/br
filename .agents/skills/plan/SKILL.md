---
name: plan
description: Phase/task based workflow system with PLAN.md as single source of truth. Use when tackling projects that require structured iteration through Planning, Analysis, Design, Implementation, Testing, Deployment, Maintenance, etc phases with clear dependency graphs.
metadata:
  tags:
    - meta
---

# plan

Phase/task based workflow system with `PLAN.md` as single source of truth.

## Overview

Structured planning system using phases and tasks, tracked in `PLAN.md` files.

## Statuses

Five statuses are used across plan, phase, and task levels:

- ☐ **Todo** — backlog / not yet started
- ❓ **Question** — needs clarification before work can begin
- ⚙️ **Doing** — in progress
- ❌ **Error** — blocked by failure or critical issue
- ✅ **Done** — completed successfully

**Text aliases:** statuses can be set using text names (case-insensitive): `TODO`, `QUESTION`, `DOING`, `ERROR`, `DONE` (or lowercase). Internally, values are always stored as emojis in PLAN.md.

**Transitions (tasks, phases, and plans):**
- `☐ → ⚙️` — start working
- `☐ → ❓` — need clarification first
- `⚙️ → ✅` — completed 
- `⚙️ → ❓` — unexpected question arose
- `⚙️ → ❌` — error blocked progress
- `❓ → ⚙️` — resolved, resume
- `❓ → ❌` — blocker discovered (bypasses ⚙️)
- `❌ → ⚙️` — retry
- `❌ → ❓` — need help

⚙️ is always required before ✅ — you cannot skip directly to Done.

**Derivation:** plan status derives from phases, phase status derives from tasks. `check --fix` restores auto-derived values after manual overrides.

## Usage

Use `plan.sh` for every PLAN.md operation. Never edit PLAN.md directly — not even to fix a typo or add a comment. The script is the only valid way to interact with plan files.

### JSON Output

Every subcommand outputs valid JSON to stdout with these fields:
- `status` — one of: `"success"`, `"warning"`, `"error"`, or `"skipped"`
- `command` — the subcommand name (e.g., `"add-phase"`)
- `message` — human-readable description

Additional fields vary by command (e.g., `path`, `value`, `issues`).
`get-plan` wraps the full plan structure inside a `data` field.
On error, exit code is 1. On success or warning, exit code is 0.

### Immediate Mode

```bash
#
# Create a new PLAN.md with header
#
plan.sh create PLAN.md "My Project"
plan.sh create PLAN.md "Plan ABC" "../other/PLAN.md"
plan.sh create PLAN.md "Plan XYZ" "../a/PLAN.md" "../../b/PLAN.md"

#
# Header reads
#
plan.sh get-plan-title PLAN.md
plan.sh get-plan-depends-on PLAN.md
plan.sh get-plan-created PLAN.md
plan.sh get-plan-updated PLAN.md
plan.sh get-plan-current-phase PLAN.md
plan.sh get-plan-current-task PLAN.md

#
# Header writes
#
plan.sh set-plan-title PLAN.md "My Project"
plan.sh set-plan-depends-on PLAN.md NONE
plan.sh set-plan-depends-on PLAN.md "../other/PLAN.md"
plan.sh set-plan-depends-on PLAN.md "../a/PLAN.md" "../../b/PLAN.md"
plan.sh set-plan-created PLAN.md --now # UTC ISO format "%Y-%m-%dT%H:%M:%SZ"
plan.sh set-plan-created PLAN.md $(date -u +"%Y-%m-%dT%H:%M:%SZ")
plan.sh set-plan-updated PLAN.md --now # UTC ISO format "%Y-%m-%dT%H:%M:%SZ"
plan.sh set-plan-updated PLAN.md $(date -u +"%Y-%m-%dT%H:%M:%SZ")
plan.sh set-plan-current-phase PLAN.md "Phase 2" # copies `[emoji-of-phase]` of "Phase 2"

plan.sh set-plan-current-task PLAN.md "Phase 2" "Task 2.3" # copies `[emoji-of-task]` of "Task 2.3"

#
# Status reads — default returns emoji, use --type for text output
#
plan.sh get-plan-status PLAN.md # returns emoji (e.g., ⚙️)
plan.sh get-plan-status PLAN.md --type text # returns lowercase name (e.g., "doing")
plan.sh get-plan-status PLAN.md --type TEXT # returns uppercase name (e.g., "DOING")
plan.sh get-phase-status PLAN.md "Phase 2" # returns emoji
plan.sh get-phase-status PLAN.md "Phase 2" --type text # returns lowercase
plan.sh get-task-status PLAN.md "Task 2.3" --type TEXT # returns uppercase

#
# Status writes — accept emojis or text aliases (case-insensitive)
#
plan.sh set-all-statuses PLAN.md ☐ # set plan, all phases, and all tasks status to be the same - use with caution
plan.sh set-all-statuses PLAN.md TODO # same as above using text alias
plan.sh set-plan-status PLAN.md ⚙️ # manual override — `check --fix` re-derives from phases
plan.sh set-plan-status PLAN.md doing # same as above using text alias
plan.sh set-phase-status PLAN.md "Phase 2" DOING # manual override — `check --fix` re-derives from tasks
plan.sh set-task-status PLAN.md "Task 2.3" error # sets ❌ for "Task 2.3" using text alias

#
# add-phase — ID and title as separate arguments
#
plan.sh add-phase PLAN.md "Phase 2" "Description of phase..." # explicit phase number + title
plan.sh add-phase PLAN.md "Planning" # auto-numbered (no explicit ID)

#
# add-task — phase ref, task ID, and title as separate arguments
#
plan.sh add-task PLAN.md "Phase 2" "Task 2.4" "Description of task..." # explicit task number + title
plan.sh add-task PLAN.md "Phase 2" "Do thing" # auto-numbered
# to add a task to a new phase, create the phase first:
#   plan.sh add-phase PLAN.md "Phase 2" "New Phase"
#   plan.sh add-task PLAN.md "Phase 2" "Task 2.1" "First task"

#
# update-phase — phase ref and optional new title
#
plan.sh update-phase PLAN.md "Phase 2" "New description of phase..." # change title
plan.sh update-phase PLAN.md "Phase 2" # no-op (title unchanged)

#
# update-task — phase ref, task ref, and optional new title
#
plan.sh update-task PLAN.md "Phase 2" "Task 2.4" "New description of task..." # change title
plan.sh update-task PLAN.md "Phase 2" "Task 2.4" # no-op (title unchanged)

#
# remove-phase
#
plan.sh remove-phase PLAN.md "Phase 2" # re-derives plan status from remaining phases

#
# remove-task
#
plan.sh remove-task PLAN.md "Phase 2" "Task 2.4" # re-derives phase and plan status from remaining tasks

#
# add-task-dependency
# 
plan.sh add-task-dependency PLAN.md "Phase 2" "Task 2.4" "Task 2.1" # re-derives phase and plan status
plan.sh add-task-dependency PLAN.md "Phase 3" "Task 3.5" "Task 3.4" # re-derives phase and plan status

#
# remove-task-dependency
# 
plan.sh remove-task-dependency PLAN.md "Phase 2" "Task 2.4" "Task 2.1" # re-derives phase and plan status
plan.sh remove-task-dependency PLAN.md "Phase 3" "Task 3.5" "Task 3.4" # re-derives phase and plan status

#
# sort — reorder phases and tasks by number
#
plan.sh sort PLAN.md  # sorts phases by number, then tasks within each phase

#
# check — validate PLAN.md consistency (with optional --fix)
#
# Checks: checksum, emoji derivation, numbering gaps/duplicates,
# ordering, dangling deps, empty phases.
plan.sh check PLAN.md              # report issues
plan.sh check PLAN.md --fix        # report + auto-fix recoverable issues

#
# get-plan — structured plan output (read-only, no file lock needed)
#
# View modes: --list (flat) or --tree (nested). Default: --list.
# Output formats: --json or --yaml. Default: --json.
# Status types: --type emoji|text|TEXT. Default: emoji.
#
plan.sh get-plan PLAN.md                 # default: --list --json
plan.sh get-plan PLAN.md --list --json   # flat list, JSON (same as default)
plan.sh get-plan PLAN.md --list --yaml   # flat list, YAML
plan.sh get-plan PLAN.md --tree --json   # nested tree, JSON
plan.sh get-plan PLAN.md --tree --yaml   # nested tree, YAML
plan.sh get-plan PLAN.md --type text     # statuses as lowercase names ("doing", "done")
plan.sh get-plan PLAN.md --type TEXT     # statuses as uppercase names ("DOING", "DONE")
```

### Batch Mode

In batch mode, if any step returns `"error"`, all remaining steps are marked as `"skipped"` and not executed. Successful mutations are preserved and written to PLAN.md. If the failed step is `set-task-status`, the task is automatically marked ❌ (Error) so the plan reflects what actually happened. This allows mixing mutating and read-only operations in the same batch.

Batch reads commands from stdin or a file (`--input FILE`). Mode is auto-detected from file extension: `.txt`/`.md` → line mode, `.json` → JSON mode. Use `--json` to force JSON mode.

**Multi-plan support:** each step can target a different PLAN.md. In JSON mode, add `"plan_path": "other/PLAN.md"` to any step object. In line mode, append `@other/PLAN.md` at the end of the line. Default fallback is the path argument passed to `batch`.

#### Line Mode (stdin)

Pipe newline-separated commands via stdin. Lines starting with `#` are treated as comments.

```bash
echo 'create "My Project"
add-phase "Phase 1" "Planning"
add-task "Phase 1" "Task 1.1" "Define scope"' | plan.sh batch PLAN.md
```

#### Line Mode with @path Override

Override the target plan per step by appending `@path` at the end of the line.

```bash
echo 'create "Plan A" @plan_a.md
create "Plan B" @plan_b.md
set-task-status "Phase 1" "Task 1.1" ⚙️ @plan_a.md' | plan.sh batch PLAN.md
```

#### Line Mode (file input)

```bash
# .txt or .md file — line mode auto-detected
plan.sh batch --input commands.txt PLAN.md
plan.sh batch --input commands.md PLAN.md
```

#### JSON Mode (stdin)

Force JSON mode with `--json` flag.

```bash
echo '[{"command":"create","args":["My Project"]},
{"command":"add-phase","args":["Phase 1","Planning"]}]' | plan.sh batch --json PLAN.md
```

#### JSON Mode with plan_path Per Step

```bash
echo '[{"command":"create","args":["A"],"plan_path":"a.md"},
{"command":"create","args":["B"],"plan_path":"b.md"}]' | plan.sh batch --json PLAN.md
```

#### JSON Mode (file input)

```bash
# .json file — JSON mode auto-detected
plan.sh batch --input commands.json PLAN.md

# Force JSON mode on non-.json file
plan.sh batch --input commands.txt --json PLAN.md
```

**Output:** a JSON object with `"status"` and `"results"` array. Every result includes a `"path"` field showing which PLAN.md the step operated on. If any step fails (`"error"`), remaining steps are marked `"skipped"`. All mutated plans are written at the end with successful changes applied. If the failed step is `set-task-status`, the task is marked ❌ (Error).

All mutating and read-only commands are supported in batch mode.

## Gotchas

- **Scripts require:** — `python3` 3.10+ with only built-in modules, and no third-party packages needed.
- **Emoji and text aliases are accepted** — emoji aliases: `⚙` (plain) → `⚙️`, `☑` / `☑️` → `✅`. Text aliases (case-insensitive): `TODO`, `QUESTION`, `DOING`, `ERROR`, `DONE` (or lowercase). All variants are normalized to canonical emojis internally. PLAN.md always stores emoji forms.
- **Use `--type` on get-status commands** — by default, status reads return emojis. Use `--type text` for lowercase names ("doing") or `--type TEXT` for uppercase ("DOING"). Available on `get-plan-status`, `get-phase-status`, `get-task-status`, and `get-plan`.
- **Never generate PLAN.md content with the LLM** — do not write, edit, or append to PLAN.md using text generation. Always use `plan.sh` commands. The script enforces status transitions, auto-derives emojis, checks dependency cycles, and maintains a SHA-256 checksum. Any direct edit will cause checksum failures and silent corruption.
- **Do not guess PLAN.md format** — if you are unsure of a command, read the Usage section below or run `plan.sh --help`. Smaller models are especially prone to hallucinating file content. Resist this impulse.
- **Never remove-and-re-add phases or tasks** — use update commands (`update-phase`, `update-task`, `set-task-status`, `add-task-dependency`). Removing and re-adding loses numbering continuity, breaks dependencies, and resets statuses. Only remove when the item is genuinely no longer part of the plan.
- **Updating a plan usually means changing statuses** — most "updates" are status transitions (`set-task-status`, `set-phase-status`). Title/description changes via `update-phase` / `update-task` are rare and should only happen when scope changes. Use sub-bullets for added details.
- **Run `plan.sh check PLAN.md --fix` after any plan update** — validates checksum integrity, emoji derivation, numbering gaps, ordering, and dependency references. The `--fix` flag auto-repairs recoverable issues (wrong emojis, numbering gaps, out-of-order items, dangling dependency references). When tasks are renumbered, self-dependencies created by the rename are automatically removed.
- **Titles must be non-empty and single-line** — empty titles, titles with newlines, or titles exceeding 2048 characters are rejected. This prevents file format corruption from multi-line entries.
- **All subcommands output JSON** — parse the `status` field to determine success/error. Use `"success"`, `"warning"`, `"error"`, or `"skipped"` (in batch mode when a previous step failed).
- **Batch mode preserves successful mutations on error** — if any step fails, all affected PLAN.md files are written with successful changes applied up to that point. If the failed command is `set-task-status`, the task is marked ❌ (Error) so you can see what happened. Remaining steps are marked `"skipped"` and not executed.
- **Batch mode supports multi-plan workflows** — each step can target a different PLAN.md. In JSON mode use `"plan_path"` per step; in line mode append `@path` at end of the line. Each result includes a `"path"` field showing which plan was operated on.
- **Error propagates up through the hierarchy** — a single task at ❌ causes its phase to derive as ❌, which can cause the entire plan to derive as ❌. To unblock the plan, resolve the error task (`❌ → ⚙️ → ✅`) or mark it as done if the error was a false alarm.
- **Direct status overrides require valid transitions** — `set-plan-status`, `set-phase-status`, and `set-task-status` follow transition rules. Cannot jump from ☐ to ❌ or ✅ (must go through ⚙️ first: `☐ → ⚙️ → ❌`). The `❓ → ❌` transition is allowed at all levels (blocker discovered during clarification bypasses ⚙️). Use `check --fix` to restore auto-derived values.
- **Use `--help` for usage information** — run `plan.sh --help` to see all available subcommands, or `plan.sh <subcommand> --help` for detailed usage of a specific command (e.g., which statuses are accepted).
