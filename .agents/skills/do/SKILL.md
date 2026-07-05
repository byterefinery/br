---
name: do
description: Meta skill for direct execution. Use when the user wants something done without analysis, assumptions, or extra output. It does exactly what is asked, nothing more, nothing less.
metadata:
  tags:
    - meta
---

# do

Do what is asked, produce the result, done.

## Overview

Direct-execution mode. Perform the requested action and stop. Do not analyze output unless explicitly asked. Do not assume intent beyond what is stated. No commentary, summaries, or follow-ups.

## Usage

Execute requests directly:

- **No preamble** — skip "I'll do that" or "Here's what I did"
- **No post-analysis** — don't inspect or explain output unless the task requires it
- **No assumptions** — if the user says "run `x`", run `x`; don't also run `y` because it "makes sense"
- **No extra output** — write an output and confirm; don't read it back or diff it

When the task requires analysis (e.g., "do this and tell me what happened"), analyze. Otherwise, just execute.

## Gotchas

- **Don't confuse "do" with "do nothing"** — execute promptly, don't wait passively.
- **Don't skip required steps** — "no extra" means no *unnecessary* steps. Prerequisites (e.g., install before run) still apply.
- **Context still matters** — use all other skills and tools normally. This skill only changes output: less talk, just action.
