---
name: jump
description: Conditional branching — jump forward or backward to a named label and resume processing from that point. Deterministic conditions (math, logic) are evaluated via on-the-fly scripts. Only vague natural-language conditions fall back to LLM judgment.
metadata:
  tags:
    - meta
---

# jump

## Overview

Evaluates a condition and, when satisfied, redirects processing to a named label placed by the `label` skill.

## Core Principle: Deterministic by Default

**Math/logic conditions are NEVER evaluated by the LLM:** They are compiled into a script (prefer inline on the fly), executed, and the exit code determines the jump.
**Free-form natural language conditions:** subjective, intent-based, fall back to LLM judgment.

## Core Principle: Execution Never Stops

After emitting `jump: LABEL_NAME`, the agent does NOT halt. It immediately recalls the label's context from conversation history and continues generating from that point. There is no pause, no waiting for external intervention. This is critical for loops — the agent iterates until the exit condition is met, all within a single generation pass.

## Usage

### Activation

When loaded without a condition, output exactly:

```
jump skill activated
```

Skill is ready. No action until a condition is encountered.

### Conditional Jump to Label
```
jump <label-name> [if <condition>]
```

If condition is met, outputs:
```
jump: <label-name>
```

**Agent must continue after `jump: LABEL_NAME`** — do not stop generating. Recall the label's context from conversation history and resume execution immediately. The harness detects the jump marker but the agent itself drives continuation.

Otherwise, if condition is not met, outputs:
```
continue
```

**Loops require explicit exit conditions** — a jump back to a earlier label creates a loop. The label's instructions or a subsequent condition must eventually produce `continue` (not jump) or an exit, otherwise the loop runs indefinitely.

### Unknown Labels

If a loop jumps to a label not yet defined, assume it may be defined in the future. Output `noop` (no operation) and continue with execution or agent/harness prompt logic.

### Condition Types

- **Math** (write and exec inline script) — `attempts < 3`, `score >= 90`, `count > max + 10`
- **Logic** (write and exec inline script) — `status == "failed"`, `ready && connected`, `not in_whitelist`
- **Free-form** (ask LLM) — `output is too verbose`, `user seems confused`, `performance is a concern`
