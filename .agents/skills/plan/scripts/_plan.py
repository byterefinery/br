#!/usr/bin/env python3
"""plan.sh — Phase/task workflow manager for PLAN.md files."""

import argparse
import hashlib
import json
import os
import re
import sys
from datetime import datetime, timezone


# Constants
EMOJI_TODO = "\u2610"               # ☐ todo
EMOJI_QUESTION = "\u2753"           # ❓ question
EMOJI_DOING = "\u2699\ufe0f"        # ⚙️ doing
EMOJI_ERROR = "\u274c"              # ❌ error
EMOJI_DONE = "\u2705"               # ✅ done

ALL_EMOJI = {
    EMOJI_TODO,
    EMOJI_QUESTION,
    EMOJI_DOING,
    EMOJI_ERROR,
    EMOJI_DONE,
}

# Alias map: input emoji variants → canonical emoji
# Users may type ⚙ instead of ⚙️, or ☑/☑️ instead of ✅
_EMOJI_ALIASES = {
    "\u2699": EMOJI_DOING,              # ⚙ (plain) → ⚙️
    "\u2611": EMOJI_DONE,               # ☑ (plain) → ✅
    "\u2611\ufe0f": EMOJI_DONE,        # ☑️ (with VS) → ✅
}

# Text aliases: text input → canonical emoji (case-insensitive lookup)
_TEXT_ALIASES = {
    "todo": EMOJI_TODO,
    "question": EMOJI_QUESTION,
    "doing": EMOJI_DOING,
    "error": EMOJI_ERROR,
    "done": EMOJI_DONE,
}

# Reverse map: canonical emoji → status name
_EMOJI_TO_STATUS = {
    EMOJI_TODO: "todo",
    EMOJI_QUESTION: "question",
    EMOJI_DOING: "doing",
    EMOJI_ERROR: "error",
    EMOJI_DONE: "done",
}


def normalize_emoji(raw):
    """Normalize user input to canonical emoji.

    Accepts:
    - Emoji aliases (⚙, ☑, ☑️) → canonical forms (⚙️, ✅)
    - Text aliases (TODO, doing, Error, etc.) → canonical emoji
    - Already-canonical emojis passed through unchanged.
    """
    # Check text alias first (case-insensitive)
    lower = raw.lower()
    if lower in _TEXT_ALIASES:
        return _TEXT_ALIASES[lower]
    # Check emoji alias
    return _EMOJI_ALIASES.get(raw, raw)


def format_status(emoji: str, status_type: str = "emoji") -> str:
    """Format an emoji status according to the requested type.

    Args:
        emoji: Canonical emoji (e.g., EMOJI_DOING).
        status_type: "emoji" (default), "text" (lowercase name),
                     "TEXT" (uppercase name). "symbol" is alias for "emoji".

    Returns:
        Formatted status string.
    """
    if status_type == "symbol":
        status_type = "emoji"
    if status_type == "emoji":
        return emoji
    name = _EMOJI_TO_STATUS.get(emoji)
    if name is None:
        return emoji  # fallback for unknown emoji
    if status_type == "TEXT":
        return name.upper()
    return name  # "text" = lowercase

VALID_TASK_TRANSITIONS = {
    (EMOJI_TODO, EMOJI_DOING),
    (EMOJI_TODO, EMOJI_QUESTION),
    (EMOJI_DOING, EMOJI_QUESTION),
    (EMOJI_DOING, EMOJI_ERROR),
    (EMOJI_DOING, EMOJI_DONE),
    (EMOJI_QUESTION, EMOJI_DOING),
    (EMOJI_QUESTION, EMOJI_ERROR),
    (EMOJI_ERROR, EMOJI_DOING),
    (EMOJI_ERROR, EMOJI_QUESTION),
}

VALID_PLAN_TRANSITIONS = VALID_TASK_TRANSITIONS.copy()

SEPARATOR = "\u2796"  # ➖
ANCHOR = "\u2693"     # ⚓

# Regex-safe emoji pattern — matches all canonical emojis plus aliases
# Canonical: ☐ ❓ ⚙️(2cp) ❌ ✅
# Aliases:  ⚙ (plain gear), ☑ / ☑️(2cp)
_EMOJI_PAT = r'(?:[\u2610\u2753\u274c\u2705\u2611]|⚙\ufe0f|\u2611\ufe0f)'


# JSON Output Helpers

def json_out(status, command, message, **extra):
    """Print a JSON result and return it."""
    obj = {"status": status, "command": command, "message": message}
    obj.update(extra)
    print(json.dumps(obj, ensure_ascii=False), flush=True)
    return obj


def die(command, message):
    json_out("error", command, message)
    sys.exit(1)


class JsonArgumentParser(argparse.ArgumentParser):
    """ArgumentParser that outputs JSON on error instead of raw text."""

    def error(self, message):
        # Try to determine which subparser triggered the error
        prog = self.prog.replace("plan.sh ", "") if self.prog.startswith("plan.sh ") else self.prog
        json_out("error", prog, message)
        sys.exit(1)


# Checksum

def compute_checksum(content):
    """SHA-256 of content, truncated to 16 hex chars."""
    return hashlib.sha256(content.encode()).hexdigest()[:16]


def strip_checksum(raw):
    """Remove checksum line, return (content_without_checksum, checksum_value)."""
    m = re.search(r'^<!--\s*checksum:\s*([0-9a-f]+)\s*-->\s*$', raw, re.M)
    if m:
        before = raw[:m.start()]
        after = raw[m.end():]
        return (before.rstrip() + after.lstrip()).rstrip(), m.group(1)
    return raw.rstrip(), None


# Parsing

def _try_parse_plan(path):
    """Parse a PLAN.md file. Returns (plan_dict, None) on success or (None, error_message) on failure.
    Does NOT call die() — suitable for batch mode where errors must not print extra JSON."""
    if not os.path.exists(path):
        return None, f"File not found: {path}"

    with open(path, encoding="utf-8") as f:
        raw = f.read()

    content, stored_checksum = strip_checksum(raw)
    lines = content.split("\n")

    plan = {
        "path": os.path.abspath(path),
        "title": "",
        "depends_on": "NONE",
        "created": "",
        "updated": "",
        "current_phase": "NONE",
        "current_task": "NONE",
        "phases": [],
        "raw_checksum": stored_checksum,
    }

    # Parse H1 title line
    if not lines or not lines[0].startswith("# "):
        return None, "Missing H1 title line"

    h1 = lines[0]
    m = re.match(r'#\s*(?:(' + _EMOJI_PAT + r')?\s*)Plan\s*' + re.escape(SEPARATOR) + r'\s*(.*)', h1)
    if not m:
        return None, f"Invalid H1 format: {h1}"
    plan["emoji"] = normalize_emoji(m.group(1)) if m.group(1) else EMOJI_TODO
    plan["title"] = m.group(2).strip()

    # Parse header fields
    i = 1
    while i < len(lines):
        line = lines[i]
        hm = re.match(r'^-\s+(Depends On|Created|Updated|Current Phase|Current Task):\s*(.*)', line)
        if not hm:
            break
        key, val = hm.group(1), hm.group(2).strip()
        if key == "Depends On":
            plan["depends_on"] = val
        elif key == "Created":
            plan["created"] = val
        elif key == "Updated":
            plan["updated"] = val
        elif key == "Current Phase":
            plan["current_phase"] = val
        elif key == "Current Task":
            plan["current_task"] = val
        i += 1

    # Parse phases and tasks
    current_phase = None
    while i < len(lines):
        line = lines[i]

        pm = re.match(r'^##\s*(' + _EMOJI_PAT + r')?\s*(Phase\s+\d+)\s*' + re.escape(SEPARATOR) + r'\s*(.*)', line)
        if pm:
            phase_emoji = normalize_emoji(pm.group(1)) if pm.group(1) else EMOJI_TODO
            phase_id = pm.group(2)
            phase_title = pm.group(3).strip()
            current_phase = {
                "emoji": phase_emoji,
                "id": phase_id,
                "title": phase_title,
                "tasks": [],
            }
            plan["phases"].append(current_phase)
            i += 1
            continue

        if current_phase and line.startswith("- "):
            tm = re.match(
                r'^-\s*(' + _EMOJI_PAT + r')?\s*(Task\s+\d+\.\d+)\s*'
                + re.escape(SEPARATOR) + r'\s*(.+?)'
                r'(?:\s+' + re.escape(ANCHOR) + r'\s+((?:Task|Phase).+))?\s*$',
                line,
            )
            if tm:
                task = {
                    "emoji": normalize_emoji(tm.group(1)) if tm.group(1) else EMOJI_TODO,
                    "id": tm.group(2),
                    "title": tm.group(3).strip(),
                    "dependencies": [],
                    "sub_bullets": [],
                }
                if tm.group(4):
                    deps = [d.strip() for d in tm.group(4).split(",") if d.strip()]
                    task["dependencies"] = deps
                assert current_phase is not None  # guarded by `if current_phase` above
                tasks_list = current_phase["tasks"]
                tasks_list.append(task)  # ty: ignore[unresolved-attribute]
                i += 1

                while i < len(lines) and lines[i].startswith("  - "):
                    task["sub_bullets"].append(lines[i][4:].strip())
                    i += 1
                continue

        i += 1

    return plan, None


def parse_plan(path):
    """Parse a PLAN.md file into a dict structure."""
    plan, err = _try_parse_plan(path)
    if err:
        die("parse", err)
    return plan


def parse_plan_data(content: str, mode: str = "list", status_type: str = "emoji") -> list[dict] | dict:
    """Parse PLAN.md content string into structured data.
    NOTE: Used by 3rd party code. Do not touch it.

    Args:
        content: Raw PLAN.md file content (with or without checksum line).
        mode: "tree" returns nested dict, "list" returns flat list[dict].
        status_type: "emoji" (default), "text" (lowercase name),
                     "TEXT" (uppercase name). "symbol" is alias for "emoji".

    Returns:
        tree mode  -> dict with title, status, depends_on, created, updated,
                       current_phase, current_task, phases (each with tasks).
        list mode  -> list[dict] of flat items alternating phase/task entries.
    """
    if status_type == "symbol":
        status_type = "emoji"
    content, _ = strip_checksum(content)
    lines = content.split("\n")

    # Defaults
    title = ""
    emoji = EMOJI_TODO
    depends_on = "NONE"
    created = ""
    updated = ""
    current_phase = "NONE"
    current_task = "NONE"
    phases: list[dict] = []

    # Parse H1 title line
    if not lines or not lines[0].startswith("# "):
        raise ValueError("Missing H1 title line")

    h1 = lines[0]
    m = re.match(r'#\s*(?:(' + _EMOJI_PAT + r')?\s*)Plan\s*' + re.escape(SEPARATOR) + r'\s*(.*)', h1)
    if not m:
        raise ValueError(f"Invalid H1 format: {h1}")
    emoji = normalize_emoji(m.group(1)) if m.group(1) else EMOJI_TODO
    title = m.group(2).strip()

    # Parse header fields
    i = 1
    while i < len(lines):
        line = lines[i]
        hm = re.match(r'^-\s+(Depends On|Created|Updated|Current Phase|Current Task):\s*(.*)', line)
        if not hm:
            break
        key, val = hm.group(1), hm.group(2).strip()
        if key == "Depends On":
            depends_on = val
        elif key == "Created":
            created = val
        elif key == "Updated":
            updated = val
        elif key == "Current Phase":
            current_phase = val
        elif key == "Current Task":
            current_task = val
        i += 1

    # Parse phases and tasks
    current_phase_obj: dict | None = None
    while i < len(lines):
        line = lines[i]

        pm = re.match(r'^##\s*(' + _EMOJI_PAT + r')?\s*(Phase\s+\d+)\s*' + re.escape(SEPARATOR) + r'\s*(.*)', line)
        if pm:
            current_phase_obj = {
                "emoji": normalize_emoji(pm.group(1)) if pm.group(1) else EMOJI_TODO,
                "id": pm.group(2),
                "title": pm.group(3).strip(),
                "tasks": [],
            }
            phases.append(current_phase_obj)
            i += 1
            continue

        if current_phase_obj is not None and line.startswith("- "):
            tm = re.match(
                r'^-\s*(' + _EMOJI_PAT + r')?\s*(Task\s+\d+\.\d+)\s*'
                + re.escape(SEPARATOR) + r'\s*(.+?)'
                r'(?:\s+' + re.escape(ANCHOR) + r'\s+((?:Task|Phase).+))?\s*$',
                line,
            )
            if tm:
                task: dict = {
                    "emoji": normalize_emoji(tm.group(1)) if tm.group(1) else EMOJI_TODO,
                    "id": tm.group(2),
                    "title": tm.group(3).strip(),
                    "dependencies": [],
                    "sub_bullets": [],
                }
                if tm.group(4):
                    task["dependencies"] = [d.strip() for d in tm.group(4).split(",") if d.strip()]
                current_phase_obj["tasks"].append(task)
                i += 1

                while i < len(lines) and lines[i].startswith("  - "):
                    task["sub_bullets"].append(lines[i][4:].strip())
                    i += 1
                continue

        i += 1

    # Derive emojis bottom-up
    for phase in phases:
        phase["emoji"] = derive_phase_emoji(phase["tasks"])
    emoji = derive_plan_emoji(phases)

    if mode == "list":
        items: list[dict] = []
        for p in phases:
            items.append({
                "type": "phase",
                "id": p["id"],
                "status": format_status(p["emoji"], status_type),
                "title": p["title"],
            })
            for t in p["tasks"]:
                items.append({
                    "type": "task",
                    "phase_id": p["id"],
                    "id": t["id"],
                    "status": format_status(t["emoji"], status_type),
                    "title": t["title"],
                    "dependencies": t["dependencies"],
                })
        return items

    # tree mode (default)
    return {
        "title": title,
        "status": format_status(emoji, status_type),
        "depends_on": depends_on,
        "created": created,
        "updated": updated,
        "current_phase": current_phase,
        "current_task": current_task,
        "phases": [
            {
                "id": p["id"],
                "status": format_status(p["emoji"], status_type),
                "title": p["title"],
                "tasks": [
                    {
                        "id": t["id"],
                        "status": format_status(t["emoji"], status_type),
                        "title": t["title"],
                        "dependencies": t["dependencies"],
                        "sub_bullets": t["sub_bullets"],
                    }
                    for t in p["tasks"]
                ],
            }
            for p in phases
        ],
    }


# Writing

def write_plan(plan):
    """Write a PLAN.md file from the parsed dict."""
    path = plan["path"]
    lines = []

    # H1
    lines.append(f"# {plan['emoji']} Plan {SEPARATOR} {plan['title']}")

    # Header fields
    lines.append(f"- Depends On: {plan['depends_on']}")
    lines.append(f"- Created: {plan['created']}")
    lines.append(f"- Updated: {plan['updated']}")
    lines.append(f"- Current Phase: {plan['current_phase']}")
    lines.append(f"- Current Task: {plan['current_task']}")
    lines.append("")

    # Phases
    for phase in plan["phases"]:
        lines.append(f"## {phase['emoji']} {phase['id']} {SEPARATOR} {phase['title']}")
        lines.append("")
        for task in phase["tasks"]:
            dep_str = ""
            if task["dependencies"]:
                dep_str = f" {ANCHOR} " + ", ".join(task["dependencies"])
            lines.append(f"- {task['emoji']} {task['id']} {SEPARATOR} {task['title']}{dep_str}")
            for sb in task["sub_bullets"]:
                lines.append(f"  - {sb}")
        lines.append("")

    content = "\n".join(lines).rstrip("\n")
    checksum = compute_checksum(content)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content + f"\n<!-- checksum: {checksum} -->\n")


# Status Derivation

def derive_phase_emoji(tasks):
    """Derive phase emoji from its tasks."""
    if not tasks:
        return EMOJI_TODO
    emojis = [t["emoji"] for t in tasks]
    if all(e == EMOJI_DONE for e in emojis):
        return EMOJI_DONE
    if EMOJI_DOING in emojis:
        return EMOJI_DOING
    if EMOJI_ERROR in emojis:
        return EMOJI_ERROR
    if EMOJI_QUESTION in emojis:
        return EMOJI_QUESTION
    return EMOJI_TODO


def derive_plan_emoji(phases):
    """Derive plan emoji from its phases."""
    if not phases:
        return EMOJI_TODO
    emojis = [p["emoji"] for p in phases]
    if all(e == EMOJI_DONE for e in emojis):
        return EMOJI_DONE
    if EMOJI_DOING in emojis:
        return EMOJI_DOING
    if EMOJI_ERROR in emojis:
        return EMOJI_ERROR
    if EMOJI_QUESTION in emojis:
        return EMOJI_QUESTION
    return EMOJI_TODO


def rederive_all(plan):
    """Re-derive all emojis bottom-up."""
    for phase in plan["phases"]:
        phase["emoji"] = derive_phase_emoji(phase["tasks"])
    plan["emoji"] = derive_plan_emoji(plan["phases"])


# Content-string helpers (no file I/O)

def _try_parse_plan_data(content: str):
    """Parse PLAN.md content string into a plan dict. Returns (plan_dict, None) on success or (None, error_message)."""
    raw = content
    content_body, stored_checksum = strip_checksum(raw)
    lines = content_body.split("\n")

    plan = {
        "title": "",
        "depends_on": "NONE",
        "created": "",
        "updated": "",
        "current_phase": "NONE",
        "current_task": "NONE",
        "phases": [],
        "raw_checksum": stored_checksum,
    }

    # Parse H1 title line
    if not lines or not lines[0].startswith("# "):
        return None, "Missing H1 title line"

    h1 = lines[0]
    m = re.match(r'#\s*(?:(' + _EMOJI_PAT + r')?\s*)Plan\s*' + re.escape(SEPARATOR) + r'\s*(.*)', h1)
    if not m:
        return None, f"Invalid H1 format: {h1}"
    plan["emoji"] = normalize_emoji(m.group(1)) if m.group(1) else EMOJI_TODO
    plan["title"] = m.group(2).strip()

    # Parse header fields
    i = 1
    while i < len(lines):
        line = lines[i]
        hm = re.match(r'^-\s+(Depends On|Created|Updated|Current Phase|Current Task):\s*(.*)', line)
        if not hm:
            break
        key, val = hm.group(1), hm.group(2).strip()
        if key == "Depends On":
            plan["depends_on"] = val
        elif key == "Created":
            plan["created"] = val
        elif key == "Updated":
            plan["updated"] = val
        elif key == "Current Phase":
            plan["current_phase"] = val
        elif key == "Current Task":
            plan["current_task"] = val
        i += 1

    # Parse phases and tasks
    current_phase = None
    while i < len(lines):
        line = lines[i]

        pm = re.match(r'^##\s*(' + _EMOJI_PAT + r')?\s*(Phase\s+\d+)\s*' + re.escape(SEPARATOR) + r'\s*(.*)', line)
        if pm:
            phase_emoji = normalize_emoji(pm.group(1)) if pm.group(1) else EMOJI_TODO
            phase_id = pm.group(2)
            phase_title = pm.group(3).strip()
            current_phase = {
                "emoji": phase_emoji,
                "id": phase_id,
                "title": phase_title,
                "tasks": [],
            }
            plan["phases"].append(current_phase)
            i += 1
            continue

        if current_phase and line.startswith("- "):
            tm = re.match(
                r'^-\s*(' + _EMOJI_PAT + r')?\s*(Task\s+\d+\.\d+)\s*'
                + re.escape(SEPARATOR) + r'\s*(.+?)'
                r'(?:\s+' + re.escape(ANCHOR) + r'\s+((?:Task|Phase).+))?\s*$',
                line,
            )
            if tm:
                task = {
                    "emoji": normalize_emoji(tm.group(1)) if tm.group(1) else EMOJI_TODO,
                    "id": tm.group(2),
                    "title": tm.group(3).strip(),
                    "dependencies": [],
                    "sub_bullets": [],
                }
                if tm.group(4):
                    deps = [d.strip() for d in tm.group(4).split(",") if d.strip()]
                    task["dependencies"] = deps
                current_phase["tasks"].append(task)
                i += 1

                while i < len(lines) and lines[i].startswith("  - "):
                    task["sub_bullets"].append(lines[i][4:].strip())
                    i += 1
                continue

        i += 1

    return plan, None


def _write_plan_to_string(plan: dict) -> str:
    """Serialize a plan dict to PLAN.md content string (with checksum). No file I/O."""
    lines = []

    # H1
    lines.append(f"# {plan['emoji']} Plan {SEPARATOR} {plan['title']}")

    # Header fields
    lines.append(f"- Depends On: {plan['depends_on']}")
    lines.append(f"- Created: {plan['created']}")
    lines.append(f"- Updated: {plan['updated']}")
    lines.append(f"- Current Phase: {plan['current_phase']}")
    lines.append(f"- Current Task: {plan['current_task']}")
    lines.append("")

    # Phases
    for phase in plan["phases"]:
        lines.append(f"## {phase['emoji']} {phase['id']} {SEPARATOR} {phase['title']}")
        lines.append("")
        for task in phase["tasks"]:
            dep_str = ""
            if task["dependencies"]:
                dep_str = f" {ANCHOR} " + ", ".join(task["dependencies"])
            lines.append(f"- {task['emoji']} {task['id']} {SEPARATOR} {task['title']}{dep_str}")
            for sb in task["sub_bullets"]:
                lines.append(f"  - {sb}")
        lines.append("")

    content = "\n".join(lines).rstrip("\n")
    checksum = compute_checksum(content)
    return content + f"\n<!-- checksum: {checksum} -->\n"


def set_all_statuses_for_plan_data(content: str, status: str) -> str:
    """Set all statuses (plan, phases, tasks) to the given status in PLAN.md content.

    NOTE: Used by 3rd party code. Do not touch it.

    Args:
        content: Raw PLAN.md file content (with or without checksum line).
        status: Target status — accepts emoji (☐, ❓, ⚙️, ❌, ✅),
                text aliases (TODO, QUESTION, DOING, ERROR, DONE),
                or lowercase variants. Normalized to canonical emoji internally.

    Returns:
        New PLAN.md content string with all statuses set and checksum updated.

    Raises:
        ValueError: If content is not valid PLAN.md format or status is invalid.
    """
    plan, err = _try_parse_plan_data(content)
    if err:
        raise ValueError(err)

    emoji = normalize_emoji(status)
    if not validate_emoji(emoji):
        raise ValueError(f"Invalid status: {status}")

    plan["emoji"] = emoji
    for phase in plan["phases"]:
        phase["emoji"] = emoji
        for task in phase["tasks"]:
            task["emoji"] = emoji
    plan["current_phase"] = "NONE"
    plan["current_task"] = "NONE"

    return _write_plan_to_string(plan)


# Helpers

def find_phase(plan, ref):
    """Find a phase by ID or emoji+ID."""
    for p in plan["phases"]:
        if p["id"] == ref or f"{p['emoji']} {p['id']}" == ref.strip():
            return p
    return None


def find_task(plan, phase_ref, task_ref):
    """Find a task within a phase."""
    phase = find_phase(plan, phase_ref)
    if not phase:
        return None
    for t in phase["tasks"]:
        if t["id"] == task_ref or f"{t['emoji']} {t['id']}" == task_ref.strip():
            return t
    return None


def next_phase_number(plan):
    """Return the next available phase number."""
    nums = []
    for p in plan["phases"]:
        m = re.match(r"Phase\s+(\d+)", p["id"])
        if m:
            nums.append(int(m.group(1)))
    return max(nums, default=0) + 1


def next_task_number(phase):
    """Return the next available task number within a phase."""
    nums = []
    for t in phase["tasks"]:
        m = re.match(r"Task\s+\d+(\.)(\d+)", t["id"])
        if m:
            nums.append(int(m.group(2)))
    return max(nums, default=0) + 1


def parse_task_id(raw):
    """Parse 'Task X.Y' into (phase_num, task_num)."""
    m = re.match(r"Task\s+(\d+)\.(\d+)", raw)
    if m:
        return int(m.group(1)), int(m.group(2))
    return None, None


def parse_phase_id(raw):
    """Parse 'Phase N' into phase number."""
    m = re.match(r"Phase\s+(\d+)", raw)
    if m:
        return int(m.group(1))
    return None


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def validate_title(title):
    if not title or not title.strip():
        return False, "Title cannot be empty"
    if "\n" in title:
        return False, "Title must not contain newlines"
    if len(title) > 2048:
        return False, f"Title exceeds 2048 characters (got {len(title)})"
    return True, ""


def validate_emoji(emoji):
    if emoji not in ALL_EMOJI:
        return False
    return True


# Dependency Cycle Detection

def resolve_task_ref(plan, ref):
    """Resolve a dependency reference to (phase_id, task_id)."""
    # Cross-phase: "Phase X - Task X.Y"
    m = re.match(r"Phase\s+\d+\s*-\s*Task\s+\d+\.\d+", ref)
    if m:
        return ref
    # Phase-bound: "Task X.Y"
    if re.match(r"Task\s+\d+\.\d+", ref):
        return ref
    return None


def detect_cycle(plan, phase_id, task_id, new_dep):
    """Check if adding new_dep would create a cycle. Returns True if cycle found."""
    # Build adjacency: task -> set of tasks it depends on
    adj = {}
    for p in plan["phases"]:
        for t in p["tasks"]:
            key = f"{p['id']} - {t['id']}"
            # Normalize deps to full form
            normalized = set()
            for d in t["dependencies"]:
                nd = _normalize_dep(d, p["id"])
                normalized.add(nd)
            adj[key] = normalized

    # Add proposed edge (normalized)
    src = f"{phase_id} - {task_id}"
    norm_dep = _normalize_dep(new_dep, phase_id)
    adj.setdefault(src, set()).add(norm_dep)

    # DFS cycle detection
    visited = set()
    in_stack = set()

    def dfs(node):
        if node in in_stack:
            return True
        if node in visited:
            return False
        visited.add(node)
        in_stack.add(node)
        for dep in adj.get(node, set()):
            if dfs(dep):
                return True
        in_stack.discard(node)
        return False

    for node in adj:
        visited.clear()
        in_stack.clear()
        if dfs(node):
            return True
    return False


# Checksum Validation

def verify_checksum(plan):
    """Verify stored checksum matches computed one."""
    if not plan["raw_checksum"]:
        return False, "No checksum found"
    # Re-read file to compute
    with open(plan["path"], encoding="utf-8") as f:
        raw = f.read()
    content, stored = strip_checksum(raw)
    computed = compute_checksum(content)
    if computed != stored:
        return False, f"Checksum mismatch: expected {computed}, stored {stored}"
    return True, "OK"


# Subcommands

def cmd_create(args):
    path = args.path
    if os.path.exists(path):
        die("create", f"File already exists: {path}")

    title = args.title
    ok, msg = validate_title(title)
    if not ok:
        die("create", msg)

    deps = "NONE"
    if args.depends_on:
        deps = ", ".join(args.depends_on)

    plan = {
        "path": os.path.abspath(path),
        "emoji": EMOJI_TODO,
        "title": title,
        "depends_on": deps,
        "created": now_iso(),
        "updated": now_iso(),
        "current_phase": "NONE",
        "current_task": "NONE",
        "phases": [],
        "raw_checksum": None,
    }
    write_plan(plan)
    json_out("success", "create", f"Created plan: {title}", path=path)


def cmd_get_plan_title(args):
    plan = parse_plan(args.path)
    json_out("success", "get-plan-title", plan["title"], value=plan["title"], path=plan["path"])


def cmd_get_plan_depends_on(args):
    plan = parse_plan(args.path)
    json_out("success", "get-plan-depends-on", plan["depends_on"], value=plan["depends_on"], path=plan["path"])


def cmd_get_plan_created(args):
    plan = parse_plan(args.path)
    json_out("success", "get-plan-created", plan["created"], value=plan["created"], path=plan["path"])


def cmd_get_plan_updated(args):
    plan = parse_plan(args.path)
    json_out("success", "get-plan-updated", plan["updated"], value=plan["updated"], path=plan["path"])


def cmd_get_plan_current_phase(args):
    plan = parse_plan(args.path)
    json_out("success", "get-plan-current-phase", plan["current_phase"], value=plan["current_phase"], path=plan["path"])


def cmd_get_plan_current_task(args):
    plan = parse_plan(args.path)
    json_out("success", "get-plan-current-task", plan["current_task"], value=plan["current_task"], path=plan["path"])


def cmd_set_plan_title(args):
    plan = parse_plan(args.path)
    ok, msg = validate_title(args.title)
    if not ok:
        die("set-plan-title", msg)
    plan["title"] = args.title
    plan["updated"] = now_iso()
    write_plan(plan)
    json_out("success", "set-plan-title", f"Title set to: {args.title}", value=args.title, path=plan["path"])


def cmd_set_plan_depends_on(args):
    plan = parse_plan(args.path)
    if args.depends_on == ["NONE"]:
        plan["depends_on"] = "NONE"
    else:
        plan["depends_on"] = ", ".join(args.depends_on)
        # Resolve dep paths relative to the plan file's directory
        plan_dir = os.path.dirname(plan["path"])
        resolved_deps = []
        for dep_path in args.depends_on:
            abs_dep = os.path.abspath(os.path.join(plan_dir, dep_path))
            if abs_dep == plan["path"]:
                die("set-plan-depends-on", "Cannot depend on itself")
            resolved_deps.append(abs_dep)
        # Check transitive cycles with resolved paths
        _check_plan_cycles(plan, resolved_deps)
    plan["updated"] = now_iso()
    write_plan(plan)
    json_out("success", "set-plan-depends-on", f"Dependencies set to: {plan['depends_on']}", value=plan["depends_on"], path=plan["path"])


def _check_plan_cycles(plan, resolved_deps=None):
    """Check for cycles in the plan dependency graph.
    resolved_deps: optional list of already-resolved absolute paths for the current plan's deps."""
    visited = set()
    rec_stack = set()

    def resolve_dep_path(dep_str, base_dir):
        """Resolve a dependency path relative to base_dir."""
        return os.path.abspath(os.path.join(base_dir, dep_str.strip()))

    def dfs(p_abs, deps_str):
        if p_abs in rec_stack:
            die("set-plan-depends-on", f"Dependency cycle detected involving {p_abs}")
        if p_abs in visited:
            return
        visited.add(p_abs)
        rec_stack.add(p_abs)
        if deps_str != "NONE":
            base_dir = os.path.dirname(p_abs)
            for dep in [d.strip() for d in deps_str.split(",")]:
                dep_abs = resolve_dep_path(dep, base_dir)
                if os.path.exists(dep_abs):
                    dep_plan = parse_plan(dep_abs)
                    dfs(dep_abs, dep_plan["depends_on"])
        rec_stack.discard(p_abs)

    start_abs = plan["path"]
    # If resolved_deps provided, use them directly for the first level
    if resolved_deps:
        for dep_abs in resolved_deps:
            visited.clear()
            rec_stack.clear()
            rec_stack.add(start_abs)
            if dep_abs in rec_stack:
                die("set-plan-depends-on", f"Dependency cycle detected involving {start_abs}")
            if os.path.exists(dep_abs):
                dep_plan = parse_plan(dep_abs)
                dfs(dep_abs, dep_plan["depends_on"])
    else:
        dfs(start_abs, plan["depends_on"])


def _check_batch_plan_cycles(start_path, new_deps, plan_cache, default_dir=None):
    """Check for cycles in the plan dependency graph (batch mode, multi-plan aware).
    Uses plan_cache to resolve depends_on for plans already loaded.
    default_dir: directory to resolve relative paths against (defaults to CWD).
    Returns True if a cycle is detected."""
    if default_dir is None:
        default_dir = os.getcwd()

    def resolve_dep_path(dep_str, base_dir):
        """Resolve a dependency path relative to base_dir."""
        return os.path.abspath(os.path.join(base_dir, dep_str.strip()))

    visited = set()
    rec_stack = set()

    def get_depends_on(p_abs):
        """Get depends_on for a plan, loading from cache or disk."""
        if p_abs in plan_cache:
            return plan_cache[p_abs]["depends_on"]
        if os.path.exists(p_abs):
            loaded = parse_plan(p_abs)
            plan_cache[p_abs] = loaded
            return loaded["depends_on"]
        return "NONE"

    def dfs(p_abs):
        if p_abs in rec_stack:
            return True
        if p_abs in visited:
            return False
        visited.add(p_abs)
        rec_stack.add(p_abs)
        deps = get_depends_on(p_abs)
        if deps != "NONE":
            base_dir = os.path.dirname(p_abs)
            for dep in [d.strip() for d in deps.split(",")]:
                dep_abs = resolve_dep_path(dep, base_dir)
                if dfs(dep_abs):
                    return True
        rec_stack.discard(p_abs)
        return False

    # Temporarily add proposed deps to check
    start_abs = os.path.abspath(os.path.join(default_dir, start_path))
    if new_deps:
        for dep in new_deps:
            dep_abs = os.path.abspath(os.path.join(default_dir, dep))
            visited.clear()
            rec_stack.clear()
            # Start DFS from the dependency target, see if we reach back to start
            rec_stack.add(start_abs)
            if dfs(dep_abs):
                return True
    return False


def cmd_set_plan_created(args):
    plan = parse_plan(args.path)
    val = args.value
    if val == "--now":
        val = now_iso()
    plan["created"] = val
    plan["updated"] = now_iso()
    write_plan(plan)
    json_out("success", "set-plan-created", f"Created set to: {val}", value=val, path=plan["path"])


def cmd_set_plan_updated(args):
    plan = parse_plan(args.path)
    val = args.value
    if val == "--now":
        val = now_iso()
    plan["updated"] = val
    write_plan(plan)
    json_out("success", "set-plan-updated", f"Updated set to: {val}", value=val, path=plan["path"])


def cmd_set_plan_current_phase(args):
    plan = parse_plan(args.path)
    phase = find_phase(plan, args.phase_id)
    if not phase:
        die("set-plan-current-phase", f"Phase not found: {args.phase_id}")
    plan["current_phase"] = f"{phase['emoji']} {phase['id']}"
    plan["updated"] = now_iso()
    write_plan(plan)
    json_out("success", "set-plan-current-phase", f"Current phase set to: {plan['current_phase']}", value=plan["current_phase"], path=plan["path"])


def cmd_set_plan_current_task(args):
    plan = parse_plan(args.path)
    task = find_task(plan, args.phase_id, args.task_id)
    if not task:
        die("set-plan-current-task", f"Task not found: {args.phase_id} / {args.task_id}")
    plan["current_task"] = f"{task['emoji']} {task['id']}"
    plan["updated"] = now_iso()
    write_plan(plan)
    json_out("success", "set-plan-current-task", f"Current task set to: {plan['current_task']}", value=plan["current_task"], path=plan["path"])


# Status reads

def cmd_get_plan_status(args):
    plan = parse_plan(args.path)
    stype = getattr(args, "status_type", "emoji")
    val = format_status(plan["emoji"], stype)
    json_out("success", "get-plan-status", val, value=val, path=plan["path"])


def cmd_get_phase_status(args):
    plan = parse_plan(args.path)
    phase = find_phase(plan, args.phase_id)
    if not phase:
        die("get-phase-status", f"Phase not found: {args.phase_id}")
    stype = getattr(args, "status_type", "emoji")
    val = format_status(phase["emoji"], stype)
    json_out("success", "get-phase-status", val, value=val, path=plan["path"], phase=phase["id"])


def cmd_get_task_status(args):
    plan = parse_plan(args.path)
    task = find_task(plan, args.phase_id, args.task_id)
    if not task:
        die("get-task-status", f"Task not found: {args.phase_id} / {args.task_id}")
    stype = getattr(args, "status_type", "emoji")
    val = format_status(task["emoji"], stype)
    json_out("success", "get-task-status", val, value=val, path=plan["path"], phase=args.phase_id, task=task["id"])


# Status writes

def cmd_set_all_statuses(args):
    plan = parse_plan(args.path)
    emoji = normalize_emoji(args.emoji)
    if not validate_emoji(emoji):
        die("set-all-statuses", f"Invalid emoji: {emoji}")
    plan["emoji"] = emoji
    for phase in plan["phases"]:
        phase["emoji"] = emoji
        for task in phase["tasks"]:
            task["emoji"] = emoji
    plan["current_phase"] = "NONE"
    plan["current_task"] = "NONE"
    plan["updated"] = now_iso()
    write_plan(plan)
    json_out("success", "set-all-statuses", f"All statuses set to {emoji}", value=emoji, path=plan["path"])


def cmd_set_plan_status(args):
    plan = parse_plan(args.path)
    new = normalize_emoji(args.emoji)
    if not validate_emoji(new):
        die("set-plan-status", f"Invalid emoji: {new}")
    old = plan["emoji"]
    if old != new and (old, new) not in VALID_PLAN_TRANSITIONS:
        die("set-plan-status", f"Invalid transition: {old} -> {new}")
    plan["emoji"] = new
    plan["updated"] = now_iso()
    write_plan(plan)
    json_out("success", "set-plan-status", f"Plan status set to {new}", value=new, path=plan["path"])


def cmd_set_phase_status(args):
    plan = parse_plan(args.path)
    phase = find_phase(plan, args.phase_id)
    if not phase:
        die("set-phase-status", f"Phase not found: {args.phase_id}")
    new = normalize_emoji(args.emoji)
    if not validate_emoji(new):
        die("set-phase-status", f"Invalid emoji: {new}")
    old = phase["emoji"]
    if old != new and (old, new) not in VALID_TASK_TRANSITIONS:
        die("set-phase-status", f"Invalid transition: {old} -> {new}")
    phase["emoji"] = new
    plan["updated"] = now_iso()
    write_plan(plan)
    json_out("success", "set-phase-status", f"Phase {phase['id']} status set to {new}", value=new, path=plan["path"], phase=phase["id"])


def cmd_set_task_status(args):
    plan = parse_plan(args.path)
    task = find_task(plan, args.phase_id, args.task_id)
    if not task:
        die("set-task-status", f"Task not found: {args.phase_id} / {args.task_id}")

    new = normalize_emoji(args.emoji)
    if not validate_emoji(new):
        die("set-task-status", f"Invalid emoji: {new}")
    old = task["emoji"]
    if old != new and (old, new) not in VALID_TASK_TRANSITIONS:
        die("set-task-status", f"Invalid transition: {old} -> {new}")

    # Check dependencies are satisfied before moving to ⚙️
    if new == EMOJI_DOING:
        unsatisfied = []
        for dep in task["dependencies"]:
            dep_task = _resolve_dep_task(plan, task, dep)
            if dep_task and dep_task["emoji"] != EMOJI_DONE:
                unsatisfied.append(dep)
        if unsatisfied:
            die("set-task-status", f"Unmet dependencies: {', '.join(unsatisfied)}")

    task["emoji"] = new

    # Re-derive first so emojis are current
    rederive_all(plan)

    # Update current tracking (after rederive so phase emoji is fresh)
    if new == EMOJI_DOING:
        phase = find_phase(plan, args.phase_id)
        plan["current_phase"] = f"{phase['emoji']} {phase['id']}" if phase else args.phase_id
        plan["current_task"] = f"{new} {task['id']}"
    plan["updated"] = now_iso()
    write_plan(plan)
    json_out("success", "set-task-status", f"Task {task['id']} status set to {new}", value=new, path=plan["path"], phase=args.phase_id, task=task["id"])


def _normalize_dep(dep_ref, source_phase_id):
    """Normalize a dependency ref to 'Phase X - Task X.Y' form."""
    # Already cross-phase
    if re.match(r"Phase\s+\d+\s*-\s*Task\s+\d+\.\d+", dep_ref):
        return dep_ref
    # Phase-bound: resolve within source phase
    if re.match(r"Task\s+\d+\.\d+", dep_ref):
        return f"{source_phase_id} - {dep_ref}"
    return dep_ref


def _resolve_dep_task(plan, source_task, dep_ref):
    """Resolve a dependency reference to the actual task dict."""
    # Cross-phase: "Phase X - Task X.Y"
    m = re.match(r"(Phase\s+\d+)\s*-\s*(Task\s+\d+\.\d+)", dep_ref)
    if m:
        return find_task(plan, m.group(1), m.group(2))
    # Phase-bound: "Task X.Y" — resolve within source task's phase
    if re.match(r"Task\s+\d+\.\d+", dep_ref):
        src_phase_num, _ = parse_task_id(source_task["id"])
        for p in plan["phases"]:
            pnum = parse_phase_id(p["id"])
            if pnum == src_phase_num:
                return find_task(plan, p["id"], dep_ref)
    return None


# Phase CRUD

def cmd_add_phase(args):
    plan = parse_plan(args.path)
    rest = args.rest  # list of remaining args
    phase_id = None
    title = ""

    if len(rest) == 1:
        candidate = rest[0]
        pnum = parse_phase_id(candidate)
        if pnum is not None:
            phase_id = candidate
            title = candidate  # fallback title = ID
        else:
            title = candidate
    elif len(rest) >= 2:
        candidate = rest[0]
        pnum = parse_phase_id(candidate)
        if pnum is not None:
            phase_id = candidate
            title = " ".join(rest[1:])
        else:
            title = " ".join(rest)

    if not phase_id:
        phase_id = f"Phase {next_phase_number(plan)}"
    if not title:
        title = phase_id

    ok, msg = validate_title(title)
    if not ok:
        die("add-phase", msg)

    # Check for duplicate
    for p in plan["phases"]:
        if p["id"] == phase_id:
            die("add-phase", f"Phase already exists: {phase_id}")

    phase = {
        "emoji": EMOJI_TODO,
        "id": phase_id,
        "title": title,
        "tasks": [],
    }
    plan["phases"].append(phase)
    rederive_all(plan)
    plan["updated"] = now_iso()
    write_plan(plan)
    json_out("success", "add-phase", f"Added {phase_id}: {title}", path=plan["path"], phase=phase_id, title=title)


def cmd_update_phase(args):
    plan = parse_plan(args.path)
    phase = find_phase(plan, args.phase_id)
    if not phase:
        die("update-phase", f"Phase not found: {args.phase_id}")
    if args.title:
        ok, msg = validate_title(args.title)
        if not ok:
            die("update-phase", msg)
        phase["title"] = args.title
    plan["updated"] = now_iso()
    write_plan(plan)
    json_out("success", "update-phase", f"Updated {phase['id']}", path=plan["path"], phase=phase["id"], title=phase["title"])


def cmd_remove_phase(args):
    plan = parse_plan(args.path)
    phase = find_phase(plan, args.phase_id)
    if not phase:
        die("remove-phase", f"Phase not found: {args.phase_id}")

    # Remove cross-phase dependencies pointing to this phase's tasks
    for p in plan["phases"]:
        if p["id"] == phase["id"]:
            continue
        for t in p["tasks"]:
            t["dependencies"] = [
                d for d in t["dependencies"]
                if not re.match(rf"{re.escape(phase['id'])}\s*-\s*", d)
            ]

    plan["phases"].remove(phase)

    # Clear current tracking if it pointed to removed phase/task
    # Strip emoji prefix before comparison (e.g., "⚙️ Phase 1" → check for "Phase 1")
    cp = plan["current_phase"]
    if phase["id"] in cp:
        plan["current_phase"] = "NONE"
    for t in phase["tasks"]:
        ct = plan["current_task"]
        if t["id"] in ct:
            plan["current_task"] = "NONE"

    rederive_all(plan)
    plan["updated"] = now_iso()
    write_plan(plan)
    json_out("success", "remove-phase", f"Removed {phase['id']}", path=plan["path"], phase=phase["id"])


# Task CRUD

def cmd_add_task(args):
    plan = parse_plan(args.path)
    phase = find_phase(plan, args.phase_id)
    if not phase:
        die("add-task", f"Phase not found: {args.phase_id}")

    rest = args.rest  # list of remaining args
    task_id = None
    title = ""

    if len(rest) == 1:
        # Just title, auto-number
        title = rest[0]
    elif len(rest) >= 2:
        candidate = rest[0]
        pn, tn = parse_task_id(candidate)
        if pn is not None:
            # Explicit Task X.Y format
            task_id = candidate
            title = " ".join(rest[1:])
        else:
            # Not a task ID, treat first arg as title (ignore extras)
            title = rest[0]
    else:
        die("add-task", "Missing title")

    ok, msg = validate_title(title)
    if not ok:
        die("add-task", msg)

    if not task_id:
        phase_num = parse_phase_id(phase["id"])
        task_num = next_task_number(phase)
        task_id = f"Task {phase_num}.{task_num}"

    # Check for duplicate
    for t in phase["tasks"]:
        if t["id"] == task_id:
            die("add-task", f"Task already exists: {task_id}")

    task = {
        "emoji": EMOJI_TODO,
        "id": task_id,
        "title": title.strip(),
        "dependencies": [],
        "sub_bullets": [],
    }
    phase["tasks"].append(task)
    rederive_all(plan)
    plan["updated"] = now_iso()
    write_plan(plan)
    json_out("success", "add-task", f"Added {task_id}: {title.strip()}", path=plan["path"], phase=args.phase_id, task=task_id, title=title.strip())


def cmd_update_task(args):
    plan = parse_plan(args.path)
    task = find_task(plan, args.phase_id, args.task_id)
    if not task:
        die("update-task", f"Task not found: {args.phase_id} / {args.task_id}")
    if args.title:
        ok, msg = validate_title(args.title)
        if not ok:
            die("update-task", msg)
        task["title"] = args.title
    plan["updated"] = now_iso()
    write_plan(plan)
    json_out("success", "update-task", f"Updated {task['id']}", path=plan["path"], phase=args.phase_id, task=task["id"], title=task["title"])


def cmd_remove_task(args):
    plan = parse_plan(args.path)
    phase = find_phase(plan, args.phase_id)
    if not phase:
        die("remove-task", f"Phase not found: {args.phase_id}")

    task = None
    for t in phase["tasks"]:
        if t["id"] == args.task_id or f"{t['emoji']} {t['id']}" == args.task_id.strip():
            task = t
            break
    if not task:
        die("remove-task", f"Task not found: {args.phase_id} / {args.task_id}")

    assert task is not None  # guaranteed by check above

    # Remove dependencies pointing to this task
    for p in plan["phases"]:
        for t in p["tasks"]:
            t["dependencies"] = [d for d in t["dependencies"] if d != task["id"] and d != f"{phase['id']} - {task['id']}"]

    phase["tasks"].remove(task)

    # Clear current tracking
    if plan["current_task"].startswith(task["id"]):
        plan["current_task"] = "NONE"

    rederive_all(plan)
    plan["updated"] = now_iso()
    write_plan(plan)
    json_out("success", "remove-task", f"Removed {task['id']}", path=plan["path"], phase=args.phase_id, task=task["id"])


# Task Dependencies

def cmd_add_task_dependency(args):
    plan = parse_plan(args.path)
    task = find_task(plan, args.phase_id, args.task_id)
    if not task:
        die("add-task-dependency", f"Task not found: {args.phase_id} / {args.task_id}")

    dep = args.dependency
    if dep in task["dependencies"]:
        json_out("warning", "add-task-dependency", f"Dependency already exists: {dep}", path=plan["path"])
        return

    # Cycle detection
    if detect_cycle(plan, args.phase_id, args.task_id, dep):
        die("add-task-dependency", f"Adding dependency '{dep}' would create a cycle")

    task["dependencies"].append(dep)
    rederive_all(plan)
    plan["updated"] = now_iso()
    write_plan(plan)
    json_out("success", "add-task-dependency", f"Added dependency '{dep}' to {task['id']}", path=plan["path"], phase=args.phase_id, task=task["id"], dependency=dep)


def cmd_remove_task_dependency(args):
    plan = parse_plan(args.path)
    task = find_task(plan, args.phase_id, args.task_id)
    if not task:
        die("remove-task-dependency", f"Task not found: {args.phase_id} / {args.task_id}")

    dep = args.dependency
    if dep not in task["dependencies"]:
        die("remove-task-dependency", f"Dependency not found: {dep}")

    task["dependencies"].remove(dep)
    rederive_all(plan)
    plan["updated"] = now_iso()
    write_plan(plan)
    json_out("success", "remove-task-dependency", f"Removed dependency '{dep}' from {task['id']}", path=plan["path"], phase=args.phase_id, task=task["id"])


# Sort

def cmd_sort(args):
    plan = parse_plan(args.path)

    # Sort phases by number
    plan["phases"].sort(key=lambda p: parse_phase_id(p["id"]) or 0)
    for phase in plan["phases"]:
        phase["tasks"].sort(key=lambda t: parse_task_id(t["id"])[1] or 0)

    rederive_all(plan)
    plan["updated"] = now_iso()
    write_plan(plan)
    json_out("success", "sort", "Phases and tasks sorted", path=plan["path"])


# Check

def _check_plan(plan):
    """Run all checks on a parsed plan dict. Returns list of (severity, message) tuples."""
    issues = []

    # 1. Checksum
    ok, msg = verify_checksum(plan)
    if not ok:
        issues.append(("error", f"Checksum: {msg}"))

    # 2. Emoji derivation
    for phase in plan["phases"]:
        expected = derive_phase_emoji(phase["tasks"])
        if phase["emoji"] != expected:
            issues.append(("warning", f"Phase {phase['id']} emoji mismatch: has {phase['emoji']}, derived {expected}"))
    expected_plan = derive_plan_emoji(plan["phases"])
    if plan["emoji"] != expected_plan:
        issues.append(("warning", f"Plan emoji mismatch: has {plan['emoji']}, derived {expected_plan}"))

    # 3. Numbering gaps/duplicates
    phase_nums = []
    for p in plan["phases"]:
        n = parse_phase_id(p["id"])
        if n:
            phase_nums.append(n)
    for i, n in enumerate(phase_nums):
        if n != i + 1:
            issues.append(("warning", f"Phase numbering gap: expected Phase {i+1}, found {p['id']}"))

    for phase in plan["phases"]:
        pnum = parse_phase_id(phase["id"])
        task_nums = []
        for t in phase["tasks"]:
            _, tn = parse_task_id(t["id"])
            if tn:
                task_nums.append(tn)
        for i, n in enumerate(task_nums):
            if n != i + 1:
                issues.append(("warning", f"Task numbering gap in {phase['id']}: expected Task {pnum}.{i+1}, found {t['id']}"))

    # 4. Ordering
    for phase in plan["phases"]:
        for i in range(1, len(phase["tasks"])):
            _, a = parse_task_id(phase["tasks"][i - 1]["id"])
            _, b = parse_task_id(phase["tasks"][i]["id"])
            if a and b and a > b:
                issues.append(("warning", f"Tasks out of order in {phase['id']}: {phase['tasks'][i-1]['id']} before {phase['tasks'][i]['id']}"))

    # 5. Dangling deps
    for phase in plan["phases"]:
        for task in phase["tasks"]:
            for dep in task["dependencies"]:
                resolved = _resolve_dep_task(plan, task, dep)
                if not resolved:
                    issues.append(("warning", f"Dangling dependency '{dep}' on {task['id']}"))

    # 6. Empty phases
    for phase in plan["phases"]:
        if not phase["tasks"]:
            issues.append(("warning", f"Empty phase: {phase['id']} (no tasks)"))

    return issues


def cmd_check(args):
    plan = parse_plan(args.path)
    issues = _check_plan(plan)

    # Auto-fix
    if args.fix:
        # Fix 1: Emoji derivation
        for phase in plan["phases"]:
            phase["emoji"] = derive_phase_emoji(phase["tasks"])
        plan["emoji"] = derive_plan_emoji(plan["phases"])

        # Fix 2: Renumber phases sequentially
        for i, phase in enumerate(plan["phases"]):
            old_id = phase["id"]
            new_id = f"Phase {i + 1}"
            if old_id != new_id:
                phase["id"] = new_id
                # Update cross-phase dependency references
                for p in plan["phases"]:
                    for t in p["tasks"]:
                        t["dependencies"] = [
                            d.replace(old_id, new_id) for d in t["dependencies"]
                        ]

        # Fix 3: Renumber tasks within each phase sequentially
        for phase in plan["phases"]:
            pnum = parse_phase_id(phase["id"])
            phase["tasks"].sort(key=lambda t: parse_task_id(t["id"])[1] or 0)
            for i, task in enumerate(phase["tasks"]):
                old_id = task["id"]
                new_id = f"Task {pnum}.{i + 1}"
                if old_id != new_id:
                    task["id"] = new_id
                    # Update dependency references across all tasks
                    for p in plan["phases"]:
                        for t in p["tasks"]:
                            t["dependencies"] = [
                                d.replace(old_id, new_id) for d in t["dependencies"]
                            ]
                    # Remove self-dependencies created by rename
                    task["dependencies"] = [
                        d for d in task["dependencies"]
                        if d != new_id and d != f"{phase['id']} - {new_id}"
                    ]

        # Fix 4: Remove dangling dependencies
        for phase in plan["phases"]:
            for task in phase["tasks"]:
                task["dependencies"] = [
                    d for d in task["dependencies"]
                    if _resolve_dep_task(plan, task, d) is not None
                ]

        plan["updated"] = now_iso()
        write_plan(plan)

    # After fixing, re-check to determine post-fix status
    if args.fix and issues:
        # Re-parse the written file to get post-fix state
        plan_fixed = parse_plan(args.path)
        remaining_issues = _check_plan(plan_fixed)
        if not remaining_issues:
            status = "success"
            msg = f"Fixed {len(issues)} issue(s)"
            issues_out = issues
        else:
            # Some issues remain (e.g., checksum errors that can't be auto-fixed)
            status = "error" if any(i[0] == "error" for i in remaining_issues) else "warning"
            msg = f"Fixed some issues; {len(remaining_issues)} remaining"
            issues_out = remaining_issues
    else:
        status = "success" if not issues else ("error" if any(i[0] == "error" for i in issues) else "warning")
        msg = f"{len(issues)} issue(s) found" if issues else "No issues found"
        issues_out = issues

    json_out(status, "check", msg,
         path=plan["path"], issues=issues_out, fixed=args.fix)

    if status == "error":
        sys.exit(1)


# Get Plan (structured output)

def cmd_get_plan(args):
    plan = parse_plan(args.path)
    mode = getattr(args, "mode", "list")
    fmt = getattr(args, "format", "json")
    stype = getattr(args, "status_type", "emoji")

    data = _build_plan_data(plan, mode, stype)

    # Wrap in standard JSON output format (status/command/message + data payload)
    out = {
        "status": "success",
        "command": "get-plan",
        "message": f"Plan: {plan['title']}",
        "path": plan["path"],
        "data": data,
    }
    if fmt == "yaml":
        print(_to_yaml(out), flush=True)
    else:
        print(json.dumps(out, ensure_ascii=False, indent=2), flush=True)


def _build_plan_data(plan, mode="list", status_type="emoji"):
    """Build structured plan data dict for get-plan output."""
    if status_type == "symbol":
        status_type = "emoji"
    if mode == "tree":
        return {
            "title": plan["title"],
            "emoji": format_status(plan["emoji"], status_type),
            "depends_on": plan["depends_on"],
            "created": plan["created"],
            "updated": plan["updated"],
            "current_phase": plan["current_phase"],
            "current_task": plan["current_task"],
            "phases": [
                {
                    "id": p["id"],
                    "emoji": format_status(p["emoji"], status_type),
                    "title": p["title"],
                    "tasks": [
                        {
                            "id": t["id"],
                            "emoji": format_status(t["emoji"], status_type),
                            "title": t["title"],
                            "dependencies": t["dependencies"],
                            "sub_bullets": t["sub_bullets"],
                        }
                        for t in p["tasks"]
                    ],
                }
                for p in plan["phases"]
            ],
        }
    else:
        data = {
            "title": plan["title"],
            "emoji": format_status(plan["emoji"], status_type),
            "depends_on": plan["depends_on"],
            "created": plan["created"],
            "updated": plan["updated"],
            "current_phase": plan["current_phase"],
            "current_task": plan["current_task"],
            "items": [],
        }
        for p in plan["phases"]:
            data["items"].append({
                "type": "phase",
                "id": p["id"],
                "emoji": format_status(p["emoji"], status_type),
                "title": p["title"],
            })
            for t in p["tasks"]:
                data["items"].append({
                    "type": "task",
                    "phase_id": p["id"],
                    "id": t["id"],
                    "emoji": format_status(t["emoji"], status_type),
                    "title": t["title"],
                    "dependencies": t["dependencies"],
                })
        return data


def _to_yaml(obj, indent=0):
    """Simple YAML serializer for nested dicts/lists."""
    lines = []
    prefix = "  " * indent
    if isinstance(obj, dict):
        for k, v in obj.items():
            if isinstance(v, list) and not v:
                lines.append(f"{prefix}{k}: []")
            elif isinstance(v, (dict, list)):
                lines.append(f"{prefix}{k}:")
                lines.append(_to_yaml(v, indent + 1))
            elif isinstance(v, str):
                lines.append(f"{prefix}{k}: {v}")
            else:
                lines.append(f"{prefix}{k}: {json.dumps(v)}")
    elif isinstance(obj, list):
        for item in obj:
            if isinstance(item, dict):
                first = True
                for k, v in item.items():
                    if first:
                        if isinstance(v, list) and not v:
                            lines.append(f"{prefix}- {k}: []")
                        elif isinstance(v, (dict, list)):
                            lines.append(f"{prefix}- {k}:")
                            lines.append(_to_yaml(v, indent + 2))
                        else:
                            lines.append(f"{prefix}- {k}: {v if isinstance(v, str) else json.dumps(v)}")
                        first = False
                    else:
                        if isinstance(v, list) and not v:
                            lines.append(f"{prefix}  {k}: []")
                        elif isinstance(v, (dict, list)):
                            lines.append(f"{prefix}  {k}:")
                            lines.append(_to_yaml(v, indent + 2))
                        else:
                            lines.append(f"{prefix}  {k}: {v if isinstance(v, str) else json.dumps(v)}")
            else:
                lines.append(f"{prefix}- {item if isinstance(item, str) else json.dumps(item)}")
    return "\n".join(lines)


# Batch Mode
# Multi-plan aware: each step can target a different PLAN.md.
# JSON mode: {"command": "...", "args": [...], "plan_path": "..."}
# Line mode:  command arg1 arg2 ... [@path]   — trailing @path overrides default

def cmd_batch(args):
    default_path = args.path
    force_json = getattr(args, "json_mode", False)
    input_file = getattr(args, "input", None)

    # Read commands
    if input_file:
        with open(input_file, encoding="utf-8") as f:
            raw = f.read()
        if not force_json and input_file.endswith(".json"):
            force_json = True
    else:
        raw = sys.stdin.read()

    # Determine mode: auto-detect from content, with --json flag for file override.
    raw_stripped = raw.strip()
    looks_like_json = raw_stripped.startswith("[")
    # --json flag overrides file extension auto-detect, but only if content looks like JSON
    use_json = looks_like_json or (force_json and input_file and not input_file.endswith(".json"))

    if use_json:
        steps = _parse_json_batch(raw)
    else:
        steps = _parse_line_batch(raw)

    # plan_cache: abs_path -> plan dict (in-memory, dirty if mutated)
    plan_cache = {}
    # Set of abs_paths that have mutations pending write
    dirty_plans = set()

    # Resolve default path to absolute and get its directory for relative @path resolution
    default_abs = os.path.abspath(default_path)
    default_dir = os.path.dirname(default_abs)

    # Commands that are read-only (don't mutate the plan file)
    # Note: "check" is NOT read-only — errors indicate plan integrity issues
    # that should halt subsequent mutations. check --fix is a mutation.
    READ_ONLY_CMDS = {
        "get-plan-title", "get-plan-depends-on", "get-plan-created",
        "get-plan-updated", "get-plan-current-phase", "get-plan-current-task",
        "get-plan-status", "get-phase-status", "get-task-status",
        "get-plan",
    }

    results = []
    has_mutation_error = False  # Only mutation errors stop the batch

    for step in steps:
        if has_mutation_error:
            results.append({
                "status": "skipped",
                "command": step.get("command", "?"),
                "message": "Skipped due to previous mutation error",
            })
            continue

        cmd = step["command"]
        cmd_args = step.get("args", [])
        raw_step_path = step.get("plan_path") or default_path
        # Resolve relative @path against default plan's directory
        if step.get("plan_path"):
            step_path = os.path.abspath(os.path.join(default_dir, raw_step_path))
        else:
            step_path = raw_step_path

        try:
            result = _execute_batch_step(cmd, cmd_args, step_path, plan_cache, dirty_plans, default_dir)
            is_mutation = result.pop("_mutation", False)
            results.append(result)
            if result["status"] == "error":
                # Only mutation errors stop the batch; read-only errors are reported but don't halt
                if cmd not in READ_ONLY_CMDS:
                    has_mutation_error = True
                    # If failed step is set-task-status, mark task as ❌
                    if cmd == "set-task-status":
                        _mark_task_error_batch(cmd_args, step_path, plan_cache)
                        dirty_plans.add(os.path.abspath(step_path))
            elif is_mutation:
                abs_p = os.path.abspath(step_path)
                dirty_plans.add(abs_p)
        except SystemExit:
            if cmd not in READ_ONLY_CMDS:
                has_mutation_error = True
            results.append({
                "status": "error",
                "command": cmd,
                "message": f"Command {cmd} failed",
            })

    # Write all dirty plans
    for abs_p in dirty_plans:
        if abs_p in plan_cache:
            write_plan(plan_cache[abs_p])

    overall = "success" if not has_mutation_error else "error"
    out = {"status": overall, "command": "batch", "results": results, "path": default_path}
    print(json.dumps(out, ensure_ascii=False), flush=True)
    if has_mutation_error:
        sys.exit(1)


def _parse_line_batch(raw):
    """Parse line-mode batch input. Trailing @path overrides default plan."""
    steps = []
    for line in raw.split("\n"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = shlex_split(line)
        if not parts:
            continue
        cmd = parts[0]
        rest = parts[1:]
        # Check for trailing @path override
        plan_path = None
        if rest and rest[-1].startswith("@"):
            plan_path = rest[-1][1:]  # strip @
            rest = rest[:-1]
        steps.append({"command": cmd, "args": rest, "plan_path": plan_path})
    return steps


def _parse_json_batch(raw):
    """Parse JSON-mode batch input. Optional 'plan_path' per step."""
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        die("batch", f"Invalid JSON input: {e}")
    if not isinstance(data, list):
        die("batch", "JSON input must be an array of step objects")
    steps = []
    for item in data:
        cmd = item.get("command", "")
        args = item.get("args", [])
        pp = item.get("plan_path", None)
        steps.append({"command": cmd, "args": args, "plan_path": pp})
    return steps


def shlex_split(line):
    """Simple quoted-string aware splitter."""
    parts = []
    current = []
    in_quote = False
    quote_char = None
    i = 0
    while i < len(line):
        c = line[i]
        if in_quote:
            if c == quote_char:
                in_quote = False
            else:
                current.append(c)
        elif c in ('"', "'"):
            in_quote = True
            quote_char = c
        elif c == " ":
            if current:
                parts.append("".join(current))
                current = []
        else:
            current.append(c)
        i += 1
    if current:
        parts.append("".join(current))
    return parts


def _get_plan(path, plan_cache, batch_mode=False):
    """Get or load a plan from cache.
    In batch_mode, returns (plan, error_msg) tuple instead of calling die()."""
    abs_p = os.path.abspath(path)
    if abs_p not in plan_cache:
        plan, err = _try_parse_plan(path)
        if err:
            if batch_mode:
                return None, err
            die("parse", err)
        plan_cache[abs_p] = plan
    if batch_mode:
        return plan_cache[abs_p], None
    return plan_cache[abs_p]


def _execute_batch_step(cmd, args, path, plan_cache, dirty_plans, default_dir=None):
    """Execute a single batch step with multi-plan support.
    default_dir: directory for resolving relative plan dependency paths."""
    abs_path = os.path.abspath(path)
    result_base = {"path": abs_path}

    try:
        # create: doesn't need existing plan
        if cmd == "create":
            title = args[0] if args else ""
            ok, msg = validate_title(title)
            if not ok:
                return {**result_base, "status": "error", "command": cmd, "message": msg}
            deps = "NONE"
            if len(args) > 1:
                deps = ", ".join(args[1:])
            plan_obj = {
                "path": abs_path,
                "emoji": EMOJI_TODO,
                "title": title,
                "depends_on": deps,
                "created": now_iso(),
                "updated": now_iso(),
                "current_phase": "NONE",
                "current_task": "NONE",
                "phases": [],
                "raw_checksum": None,
            }
            plan_cache[abs_path] = plan_obj
            write_plan(plan_obj)
            return {**result_base, "status": "success", "command": cmd,
                    "message": f"Created plan: {title}", "_mutation": True}

        # All other commands need an existing plan
        plan, err = _get_plan(path, plan_cache, batch_mode=True)
        if err:
            return {**result_base, "status": "error", "command": cmd, "message": err}

        # Header reads (read-only, no mutation)
        if cmd == "get-plan-title":
            return {**result_base, "status": "success", "command": cmd,
                    "message": plan["title"], "value": plan["title"]}
        if cmd == "get-plan-depends-on":
            return {**result_base, "status": "success", "command": cmd,
                    "message": plan["depends_on"], "value": plan["depends_on"]}
        if cmd == "get-plan-created":
            return {**result_base, "status": "success", "command": cmd,
                    "message": plan["created"], "value": plan["created"]}
        if cmd == "get-plan-updated":
            return {**result_base, "status": "success", "command": cmd,
                    "message": plan["updated"], "value": plan["updated"]}
        if cmd == "get-plan-current-phase":
            return {**result_base, "status": "success", "command": cmd,
                    "message": plan["current_phase"], "value": plan["current_phase"]}
        if cmd == "get-plan-current-task":
            return {**result_base, "status": "success", "command": cmd,
                    "message": plan["current_task"], "value": plan["current_task"]}

        # Status reads (read-only)
        if cmd == "get-plan-status":
            return {**result_base, "status": "success", "command": cmd,
                    "message": plan["emoji"], "value": plan["emoji"]}
        if cmd == "get-phase-status":
            phase = find_phase(plan, args[0]) if args else None
            if not phase:
                return {**result_base, "status": "error", "command": cmd,
                        "message": f"Phase not found: {args[0] if args else '?'}"}
            return {**result_base, "status": "success", "command": cmd,
                    "message": phase["emoji"], "value": phase["emoji"], "phase": phase["id"]}
        if cmd == "get-task-status":
            if len(args) < 2:
                return {**result_base, "status": "error", "command": cmd,
                        "message": "Missing phase_id or task_id"}
            task = find_task(plan, args[0], args[1])
            if not task:
                return {**result_base, "status": "error", "command": cmd,
                        "message": f"Task not found: {args[0]} / {args[1]}"}
            return {**result_base, "status": "success", "command": cmd,
                    "message": task["emoji"], "value": task["emoji"],
                    "phase": args[0], "task": task["id"]}

        # Header writes
        if cmd == "set-plan-title":
            new_title = args[0] if args else ""
            ok, msg = validate_title(new_title)
            if not ok:
                return {**result_base, "status": "error", "command": cmd, "message": msg}
            plan["title"] = new_title
            plan["updated"] = now_iso()
            return {**result_base, "status": "success", "command": cmd,
                    "message": f"Title set to: {new_title}", "_mutation": True}

        if cmd == "set-plan-depends-on":
            deps = args if args else ["NONE"]
            if deps == ["NONE"]:
                plan["depends_on"] = "NONE"
            else:
                # Self-reference check (resolve relative to default_dir)
                for dep_path in deps:
                    resolved = os.path.abspath(os.path.join(default_dir or os.getcwd(), dep_path))
                    if resolved == abs_path:
                        return {**result_base, "status": "error", "command": cmd,
                                "message": "Cannot depend on itself"}
                # Transitive cycle detection
                if _check_batch_plan_cycles(abs_path, deps, plan_cache, default_dir):
                    return {**result_base, "status": "error", "command": cmd,
                            "message": f"Dependency cycle detected involving {path}"}
                plan["depends_on"] = ", ".join(deps)
            plan["updated"] = now_iso()
            return {**result_base, "status": "success", "command": cmd,
                    "message": f"Dependencies set to: {plan['depends_on']}", "_mutation": True}

        if cmd == "set-plan-created":
            val = args[0] if args else "__NOW__"
            if val == "__NOW__" or val == "--now":
                val = now_iso()
            plan["created"] = val
            plan["updated"] = now_iso()
            return {**result_base, "status": "success", "command": cmd,
                    "message": f"Created set to: {val}", "_mutation": True}

        if cmd == "set-plan-updated":
            val = args[0] if args else "__NOW__"
            if val == "__NOW__" or val == "--now":
                val = now_iso()
            plan["updated"] = val
            return {**result_base, "status": "success", "command": cmd,
                    "message": f"Updated set to: {val}", "_mutation": True}

        if cmd == "set-plan-current-phase":
            if not args:
                return {**result_base, "status": "error", "command": cmd,
                        "message": "Missing phase_id"}
            phase = find_phase(plan, args[0])
            if not phase:
                return {**result_base, "status": "error", "command": cmd,
                        "message": f"Phase not found: {args[0]}"}
            plan["current_phase"] = f"{phase['emoji']} {phase['id']}"
            plan["updated"] = now_iso()
            return {**result_base, "status": "success", "command": cmd,
                    "message": f"Current phase set to: {plan['current_phase']}", "_mutation": True}

        if cmd == "set-plan-current-task":
            if len(args) < 2:
                return {**result_base, "status": "error", "command": cmd,
                        "message": "Missing phase_id or task_id"}
            task = find_task(plan, args[0], args[1])
            if not task:
                return {**result_base, "status": "error", "command": cmd,
                        "message": f"Task not found: {args[0]} / {args[1]}"}
            plan["current_task"] = f"{task['emoji']} {task['id']}"
            plan["updated"] = now_iso()
            return {**result_base, "status": "success", "command": cmd,
                    "message": f"Current task set to: {plan['current_task']}", "_mutation": True}

        # Status writes
        if cmd == "set-all-statuses":
            emoji = normalize_emoji(args[0]) if args else EMOJI_TODO
            if emoji not in ALL_EMOJI:
                return {**result_base, "status": "error", "command": cmd,
                        "message": f"Invalid emoji: {emoji}"}
            plan["emoji"] = emoji
            for phase in plan["phases"]:
                phase["emoji"] = emoji
                for task in phase["tasks"]:
                    task["emoji"] = emoji
            plan["updated"] = now_iso()
            return {**result_base, "status": "success", "command": cmd,
                    "message": f"All statuses set to {emoji}", "_mutation": True}

        if cmd == "set-plan-status":
            emoji = normalize_emoji(args[0]) if args else EMOJI_DOING
            if emoji not in ALL_EMOJI:
                return {**result_base, "status": "error", "command": cmd,
                        "message": f"Invalid emoji: {emoji}"}
            old = plan["emoji"]
            if old != emoji and (old, emoji) not in VALID_PLAN_TRANSITIONS:
                return {**result_base, "status": "error", "command": cmd,
                        "message": f"Invalid transition: {old} -> {emoji}"}
            plan["emoji"] = emoji
            # Do NOT rederive — this is a manual override preserved until check --fix
            plan["updated"] = now_iso()
            return {**result_base, "status": "success", "command": cmd,
                    "message": f"Plan -> {emoji}", "_mutation": True}

        if cmd == "set-phase-status":
            if not args:
                return {**result_base, "status": "error", "command": cmd,
                        "message": "Missing phase_id"}
            phase = find_phase(plan, args[0])
            if not phase:
                return {**result_base, "status": "error", "command": cmd,
                        "message": f"Phase not found: {args[0]}"}
            emoji = normalize_emoji(args[1]) if len(args) > 1 else EMOJI_DOING
            if emoji not in ALL_EMOJI:
                return {**result_base, "status": "error", "command": cmd,
                        "message": f"Invalid emoji: {emoji}"}
            old = phase["emoji"]
            if old != emoji and (old, emoji) not in VALID_TASK_TRANSITIONS:
                return {**result_base, "status": "error", "command": cmd,
                        "message": f"Invalid transition: {old} -> {emoji}"}
            phase["emoji"] = emoji
            # Do NOT rederive — this is a manual override preserved until check --fix
            plan["updated"] = now_iso()
            return {**result_base, "status": "success", "command": cmd,
                    "message": f"Phase {phase['id']} -> {emoji}", "_mutation": True}

        if cmd == "set-task-status":
            if len(args) < 2:
                return {**result_base, "status": "error", "command": cmd,
                        "message": "Missing phase_id or task_id"}
            task = find_task(plan, args[0], args[1])
            if not task:
                return {**result_base, "status": "error", "command": cmd,
                        "message": f"Task not found: {args[0]} / {args[1]}"}
            emoji = normalize_emoji(args[2]) if len(args) > 2 else EMOJI_DOING
            if emoji not in ALL_EMOJI:
                return {**result_base, "status": "error", "command": cmd,
                        "message": f"Invalid emoji: {emoji}"}
            old = task["emoji"]
            if old != emoji and (old, emoji) not in VALID_TASK_TRANSITIONS:
                return {**result_base, "status": "error", "command": cmd,
                        "message": f"Invalid transition: {old} -> {emoji}"}
            # Check dependencies before ⚙️
            if emoji == EMOJI_DOING:
                unsatisfied = []
                for dep in task["dependencies"]:
                    dep_task = _resolve_dep_task(plan, task, dep)
                    if dep_task and dep_task["emoji"] != EMOJI_DONE:
                        unsatisfied.append(dep)
                if unsatisfied:
                    return {**result_base, "status": "error", "command": cmd,
                            "message": f"Unmet dependencies: {', '.join(unsatisfied)}"}
            task["emoji"] = emoji
            rederive_all(plan)
            # Update current tracking after rederive
            if emoji == EMOJI_DOING:
                phase = find_phase(plan, args[0])
                plan["current_phase"] = f"{phase['emoji']} {phase['id']}" if phase else args[0]
                plan["current_task"] = f"{emoji} {task['id']}"
            plan["updated"] = now_iso()
            return {**result_base, "status": "success", "command": cmd,
                    "message": f"Task {task['id']} -> {emoji}", "_mutation": True}

        # Phase CRUD
        if cmd == "add-phase":
            phase_id = args[0] if args else ""
            title = args[1] if len(args) > 1 else ""
            pnum = parse_phase_id(phase_id)
            if pnum is None:
                title = phase_id
                phase_id = f"Phase {next_phase_number(plan)}"
            elif not title:
                title = phase_id
            ok, msg = validate_title(title)
            if not ok:
                return {**result_base, "status": "error", "command": cmd, "message": msg}
            for p in plan["phases"]:
                if p["id"] == phase_id:
                    return {**result_base, "status": "error", "command": cmd,
                            "message": f"Phase already exists: {phase_id}"}
            plan["phases"].append({
                "emoji": EMOJI_TODO, "id": phase_id, "title": title, "tasks": []
            })
            rederive_all(plan)
            plan["updated"] = now_iso()
            return {**result_base, "status": "success", "command": cmd,
                    "message": f"Added {phase_id}: {title}", "_mutation": True}

        if cmd == "update-phase":
            phase = find_phase(plan, args[0]) if args else None
            if not phase:
                return {**result_base, "status": "error", "command": cmd,
                        "message": f"Phase not found: {args[0] if args else '?'}"}
            if len(args) > 1:
                ok, msg = validate_title(args[1])
                if not ok:
                    return {**result_base, "status": "error", "command": cmd, "message": msg}
                phase["title"] = args[1]
            plan["updated"] = now_iso()
            return {**result_base, "status": "success", "command": cmd,
                    "message": f"Updated {phase['id']}", "_mutation": True}

        if cmd == "remove-phase":
            phase = find_phase(plan, args[0]) if args else None
            if not phase:
                return {**result_base, "status": "error", "command": cmd,
                        "message": f"Phase not found: {args[0] if args else '?'}"}
            # Remove cross-phase deps pointing to this phase's tasks
            for p in plan["phases"]:
                if p["id"] == phase["id"]:
                    continue
                for t in p["tasks"]:
                    t["dependencies"] = [
                        d for d in t["dependencies"]
                        if not re.match(rf"{re.escape(phase['id'])}\s*-\s*", d)
                    ]
            plan["phases"].remove(phase)
            if plan["current_phase"].startswith(phase["id"]):
                plan["current_phase"] = "NONE"
            for t in phase["tasks"]:
                if plan["current_task"].startswith(t["id"]):
                    plan["current_task"] = "NONE"
            rederive_all(plan)
            plan["updated"] = now_iso()
            return {**result_base, "status": "success", "command": cmd,
                    "message": f"Removed {phase['id']}", "_mutation": True}

        # Task CRUD
        if cmd == "add-task":
            if not args:
                return {**result_base, "status": "error", "command": cmd,
                        "message": "Missing phase_id"}
            phase = find_phase(plan, args[0])
            if not phase:
                return {**result_base, "status": "error", "command": cmd,
                        "message": f"Phase not found: {args[0]}"}
            task_id = args[1] if len(args) > 1 else None
            title = args[2] if len(args) > 2 else ""
            if task_id:
                tn = parse_task_id(task_id)
                if tn[0] is None:
                    # Not a valid Task X.Y format — treat as title, ignore extras
                    title = task_id
                    task_id = None
            if not task_id:
                pn = parse_phase_id(phase["id"])
                tn = next_task_number(phase)
                task_id = f"Task {pn}.{tn}"
            ok, msg = validate_title(title)
            if not ok:
                return {**result_base, "status": "error", "command": cmd, "message": msg}
            for t in phase["tasks"]:
                if t["id"] == task_id:
                    return {**result_base, "status": "error", "command": cmd,
                            "message": f"Task already exists: {task_id}"}
            phase["tasks"].append({
                "emoji": EMOJI_TODO, "id": task_id, "title": title.strip(),
                "dependencies": [], "sub_bullets": []
            })
            rederive_all(plan)
            plan["updated"] = now_iso()
            return {**result_base, "status": "success", "command": cmd,
                    "message": f"Added {task_id}: {title.strip()}", "_mutation": True}

        if cmd == "update-task":
            if len(args) < 2:
                return {**result_base, "status": "error", "command": cmd,
                        "message": "Missing phase_id or task_id"}
            task = find_task(plan, args[0], args[1])
            if not task:
                return {**result_base, "status": "error", "command": cmd,
                        "message": f"Task not found: {args[0]} / {args[1]}"}
            if len(args) > 2:
                ok, msg = validate_title(args[2])
                if not ok:
                    return {**result_base, "status": "error", "command": cmd, "message": msg}
                task["title"] = args[2]
            plan["updated"] = now_iso()
            return {**result_base, "status": "success", "command": cmd,
                    "message": f"Updated {task['id']}", "_mutation": True}

        if cmd == "remove-task":
            if len(args) < 2:
                return {**result_base, "status": "error", "command": cmd,
                        "message": "Missing phase_id or task_id"}
            phase = find_phase(plan, args[0])
            if not phase:
                return {**result_base, "status": "error", "command": cmd,
                        "message": f"Phase not found: {args[0]}"}
            task = None
            for t in phase["tasks"]:
                if t["id"] == args[1]:
                    task = t
                    break
            if not task:
                return {**result_base, "status": "error", "command": cmd,
                        "message": f"Task not found: {args[0]} / {args[1]}"}
            # Remove deps pointing to this task
            for p in plan["phases"]:
                for t in p["tasks"]:
                    t["dependencies"] = [
                        d for d in t["dependencies"]
                        if d != task["id"] and d != f"{phase['id']} - {task['id']}"
                    ]
            phase["tasks"].remove(task)
            # Clear current tracking (strip emoji prefix for comparison)
            ct = plan["current_task"]
            if task["id"] in ct:
                plan["current_task"] = "NONE"
            rederive_all(plan)
            plan["updated"] = now_iso()
            return {**result_base, "status": "success", "command": cmd,
                    "message": f"Removed {task['id']}", "_mutation": True}

        # Task Dependencies
        if cmd == "add-task-dependency":
            if len(args) < 3:
                return {**result_base, "status": "error", "command": cmd,
                        "message": "Missing phase_id, task_id, or dependency"}
            task = find_task(plan, args[0], args[1])
            if not task:
                return {**result_base, "status": "error", "command": cmd,
                        "message": f"Task not found: {args[0]} / {args[1]}"}
            dep = args[2]
            if dep in task["dependencies"]:
                return {**result_base, "status": "warning", "command": cmd,
                        "message": f"Dependency already exists: {dep}"}
            # Cycle detection
            if detect_cycle(plan, args[0], args[1], dep):
                return {**result_base, "status": "error", "command": cmd,
                        "message": f"Adding dependency '{dep}' would create a cycle"}
            task["dependencies"].append(dep)
            rederive_all(plan)
            plan["updated"] = now_iso()
            return {**result_base, "status": "success", "command": cmd,
                    "message": f"Added dependency '{dep}' to {task['id']}", "_mutation": True}

        if cmd == "remove-task-dependency":
            if len(args) < 3:
                return {**result_base, "status": "error", "command": cmd,
                        "message": "Missing phase_id, task_id, or dependency"}
            task = find_task(plan, args[0], args[1])
            if not task:
                return {**result_base, "status": "error", "command": cmd,
                        "message": f"Task not found: {args[0]} / {args[1]}"}
            dep = args[2]
            if dep not in task["dependencies"]:
                return {**result_base, "status": "error", "command": cmd,
                        "message": f"Dependency not found: {dep}"}
            task["dependencies"].remove(dep)
            rederive_all(plan)
            plan["updated"] = now_iso()
            return {**result_base, "status": "success", "command": cmd,
                    "message": f"Removed dependency '{dep}' from {task['id']}", "_mutation": True}

        # Utility commands
        if cmd == "sort":
            plan["phases"].sort(key=lambda p: parse_phase_id(p["id"]) or 0)
            for phase in plan["phases"]:
                phase["tasks"].sort(key=lambda t: parse_task_id(t["id"])[1] or 0)
            rederive_all(plan)
            plan["updated"] = now_iso()
            return {**result_base, "status": "success", "command": cmd,
                    "message": "Phases and tasks sorted", "_mutation": True}

        if cmd == "check":
            do_fix = "--fix" in args
            issues = _check_plan(plan)

            if do_fix:
                # Fix 1: Emoji derivation
                for phase in plan["phases"]:
                    phase["emoji"] = derive_phase_emoji(phase["tasks"])
                plan["emoji"] = derive_plan_emoji(plan["phases"])

                # Fix 2: Renumber phases sequentially
                for i, phase in enumerate(plan["phases"]):
                    old_id = phase["id"]
                    new_id = f"Phase {i + 1}"
                    if old_id != new_id:
                        phase["id"] = new_id
                        for p in plan["phases"]:
                            for t in p["tasks"]:
                                t["dependencies"] = [
                                    d.replace(old_id, new_id) for d in t["dependencies"]
                                ]

                # Fix 3: Renumber tasks within each phase sequentially
                for phase in plan["phases"]:
                    pnum = parse_phase_id(phase["id"])
                    phase["tasks"].sort(key=lambda t: parse_task_id(t["id"])[1] or 0)
                    for i, task in enumerate(phase["tasks"]):
                        old_id = task["id"]
                        new_id = f"Task {pnum}.{i + 1}"
                        if old_id != new_id:
                            task["id"] = new_id
                            for p in plan["phases"]:
                                for t in p["tasks"]:
                                    t["dependencies"] = [
                                        d.replace(old_id, new_id) for d in t["dependencies"]
                                    ]
                            task["dependencies"] = [
                                d for d in task["dependencies"]
                                if d != new_id and d != f"{phase['id']} - {new_id}"
                            ]

                # Fix 4: Remove dangling dependencies
                for phase in plan["phases"]:
                    for task in phase["tasks"]:
                        task["dependencies"] = [
                            d for d in task["dependencies"]
                            if _resolve_dep_task(plan, task, d) is not None
                        ]

                plan["updated"] = now_iso()
                dirty_plans.add(abs_path)

                # Re-check after fix
                remaining = _check_plan(plan)
                if not remaining:
                    status = "success"
                    msg = f"Fixed {len(issues)} issue(s)"
                    issues_out = issues
                else:
                    status = "error" if any(i[0] == "error" for i in remaining) else "warning"
                    msg = f"Fixed some issues; {len(remaining)} remaining"
                    issues_out = remaining
            else:
                status = "success" if not issues else ("error" if any(i[0] == "error" for i in issues) else "warning")
                msg = f"{len(issues)} issue(s) found" if issues else "No issues found"
                issues_out = issues

            return {**result_base, "status": status, "command": cmd,
                    "message": msg, "issues": issues_out, "fixed": do_fix}

        # get-plan (structured output, read-only)
        if cmd == "get-plan":
            mode = args[0] if args else "list"
            data = _build_plan_data(plan, mode)
            return {**result_base, "status": "success", "command": cmd,
                    "message": f"Plan: {plan['title']}", "data": data}

        # Unknown command
        return {**result_base, "status": "error", "command": cmd,
                "message": f"Unknown command: {cmd}"}

    except Exception as e:
        return {**result_base, "status": "error", "command": cmd, "message": str(e)}


def _mark_task_error_batch(args, path, plan_cache):
    """If set-task-status failed, mark the task as ❌."""
    if len(args) < 2:
        return
    plan, err = _get_plan(path, plan_cache, batch_mode=True)
    if err:
        return
    task = find_task(plan, args[0], args[1])
    if task and task["emoji"] != EMOJI_ERROR:
        task["emoji"] = EMOJI_ERROR
        rederive_all(plan)


# CLI Parser

def build_parser():
    parser = JsonArgumentParser(
        prog="plan.sh",
        description="Phase/task workflow manager for PLAN.md files",
    )
    subs = parser.add_subparsers(dest="command")

    # create
    p = subs.add_parser("create", help="Create a new PLAN.md")
    p.add_argument("path")
    p.add_argument("title")
    p.add_argument("depends_on", nargs="*", default=[])

    # get-plan-title
    p = subs.add_parser("get-plan-title", help="Get plan title")
    p.add_argument("path")

    # get-plan-depends-on
    p = subs.add_parser("get-plan-depends-on", help="Get plan dependencies")
    p.add_argument("path")

    # get-plan-created
    p = subs.add_parser("get-plan-created", help="Get plan creation time")
    p.add_argument("path")

    # get-plan-updated
    p = subs.add_parser("get-plan-updated", help="Get plan update time")
    p.add_argument("path")

    # get-plan-current-phase
    p = subs.add_parser("get-plan-current-phase", help="Get current phase")
    p.add_argument("path")

    # get-plan-current-task
    p = subs.add_parser("get-plan-current-task", help="Get current task")
    p.add_argument("path")

    # set-plan-title
    p = subs.add_parser("set-plan-title", help="Set plan title")
    p.add_argument("path")
    p.add_argument("title")

    # set-plan-depends-on
    p = subs.add_parser("set-plan-depends-on", help="Set plan dependencies")
    p.add_argument("path")
    p.add_argument("depends_on", nargs="+")

    # set-plan-created
    p = subs.add_parser("set-plan-created", help="Set plan creation time")
    p.add_argument("path")
    p.add_argument("value", nargs="?", default="--now")

    # set-plan-updated
    p = subs.add_parser("set-plan-updated", help="Set plan update time")
    p.add_argument("path")
    p.add_argument("value", nargs="?", default="--now")

    # set-plan-current-phase
    p = subs.add_parser("set-plan-current-phase", help="Set current phase")
    p.add_argument("path")
    p.add_argument("phase_id")

    # set-plan-current-task
    p = subs.add_parser("set-plan-current-task", help="Set current task")
    p.add_argument("path")
    p.add_argument("phase_id")
    p.add_argument("task_id")

    # get-plan-status
    p = subs.add_parser("get-plan-status", help="Get plan status")
    p.add_argument("path")
    p.add_argument("--type", dest="status_type", default="emoji",
                   choices=["emoji", "text", "TEXT"],
                   help='Output format: emoji (default), text (lowercase), TEXT (uppercase)')

    # get-phase-status
    p = subs.add_parser("get-phase-status", help="Get phase status")
    p.add_argument("path")
    p.add_argument("phase_id")
    p.add_argument("--type", dest="status_type", default="emoji",
                   choices=["emoji", "text", "TEXT"],
                   help='Output format: emoji (default), text (lowercase), TEXT (uppercase)')

    # get-task-status
    p = subs.add_parser("get-task-status", help="Get task status")
    p.add_argument("path")
    p.add_argument("phase_id")
    p.add_argument("task_id")
    p.add_argument("--type", dest="status_type", default="emoji",
                   choices=["emoji", "text", "TEXT"],
                   help='Output format: emoji (default), text (lowercase), TEXT (uppercase)')

    # set-all-statuses
    p = subs.add_parser("set-all-statuses", help="Set all statuses to same emoji")
    p.add_argument("path")
    p.add_argument("emoji",
                   help="Status: ☐ (TODO), ❓ (QUESTION), ⚙️ (DOING), ❌ (ERROR), ✅ (DONE). Accepts emojis or text aliases (case-insensitive).")

    # set-plan-status
    p = subs.add_parser("set-plan-status", help="Set plan status emoji")
    p.add_argument("path")
    p.add_argument("emoji",
                   help="Status: ☐ (TODO), ❓ (QUESTION), ⚙️ (DOING), ❌ (ERROR), ✅ (DONE). Accepts emojis or text aliases (case-insensitive).")

    # set-phase-status
    p = subs.add_parser("set-phase-status", help="Set phase status emoji")
    p.add_argument("path")
    p.add_argument("phase_id")
    p.add_argument("emoji",
                   help="Status: ☐ (TODO), ❓ (QUESTION), ⚙️ (DOING), ❌ (ERROR), ✅ (DONE). Accepts emojis or text aliases (case-insensitive).")

    # set-task-status
    p = subs.add_parser("set-task-status", help="Set task status emoji")
    p.add_argument("path")
    p.add_argument("phase_id")
    p.add_argument("task_id")
    p.add_argument("emoji",
                   help="Status: ☐ (TODO), ❓ (QUESTION), ⚙️ (DOING), ❌ (ERROR), ✅ (DONE). Accepts emojis or text aliases (case-insensitive).")

    # add-phase
    p = subs.add_parser("add-phase", help="Add a phase")
    p.add_argument("path")
    p.add_argument("rest", nargs="+")

    # add-task
    p = subs.add_parser("add-task", help="Add a task")
    p.add_argument("path")
    p.add_argument("phase_id")
    p.add_argument("rest", nargs="*")

    # update-phase
    p = subs.add_parser("update-phase", help="Update phase title")
    p.add_argument("path")
    p.add_argument("phase_id")
    p.add_argument("title", nargs="?", default=None)

    # update-task
    p = subs.add_parser("update-task", help="Update task title")
    p.add_argument("path")
    p.add_argument("phase_id")
    p.add_argument("task_id")
    p.add_argument("title", nargs="?", default=None)

    # remove-phase
    p = subs.add_parser("remove-phase", help="Remove a phase")
    p.add_argument("path")
    p.add_argument("phase_id")

    # remove-task
    p = subs.add_parser("remove-task", help="Remove a task")
    p.add_argument("path")
    p.add_argument("phase_id")
    p.add_argument("task_id")

    # add-task-dependency
    p = subs.add_parser("add-task-dependency", help="Add task dependency")
    p.add_argument("path")
    p.add_argument("phase_id")
    p.add_argument("task_id")
    p.add_argument("dependency")

    # remove-task-dependency
    p = subs.add_parser("remove-task-dependency", help="Remove task dependency")
    p.add_argument("path")
    p.add_argument("phase_id")
    p.add_argument("task_id")
    p.add_argument("dependency")

    # sort
    p = subs.add_parser("sort", help="Sort phases and tasks")
    p.add_argument("path")

    # check
    p = subs.add_parser("check", help="Validate PLAN.md")
    p.add_argument("path")
    p.add_argument("--fix", action="store_true")

    # get-plan
    p = subs.add_parser("get-plan", help="Structured plan output")
    p.add_argument("path")
    p.add_argument("--list", dest="mode", action="store_const", const="list", default="list")
    p.add_argument("--tree", dest="mode", action="store_const", const="tree")
    p.add_argument("--json", dest="format", action="store_const", const="json", default="json")
    p.add_argument("--yaml", dest="format", action="store_const", const="yaml")
    p.add_argument("--type", dest="status_type", default="emoji",
                   choices=["emoji", "text", "TEXT"],
                   help='Status output format: emoji (default), text (lowercase), TEXT (uppercase)')

    # batch
    p = subs.add_parser("batch", help="Batch mode")
    p.add_argument("path")
    p.add_argument("--input", default=None)
    p.add_argument("--json", dest="json_mode", action="store_true")

    return parser


# Dispatch

COMMAND_MAP = {
    "create": cmd_create,
    "get-plan-title": cmd_get_plan_title,
    "get-plan-depends-on": cmd_get_plan_depends_on,
    "get-plan-created": cmd_get_plan_created,
    "get-plan-updated": cmd_get_plan_updated,
    "get-plan-current-phase": cmd_get_plan_current_phase,
    "get-plan-current-task": cmd_get_plan_current_task,
    "set-plan-title": cmd_set_plan_title,
    "set-plan-depends-on": cmd_set_plan_depends_on,
    "set-plan-created": cmd_set_plan_created,
    "set-plan-updated": cmd_set_plan_updated,
    "set-plan-current-phase": cmd_set_plan_current_phase,
    "set-plan-current-task": cmd_set_plan_current_task,
    "get-plan-status": cmd_get_plan_status,
    "get-phase-status": cmd_get_phase_status,
    "get-task-status": cmd_get_task_status,
    "set-all-statuses": cmd_set_all_statuses,
    "set-plan-status": cmd_set_plan_status,
    "set-phase-status": cmd_set_phase_status,
    "set-task-status": cmd_set_task_status,
    "add-phase": cmd_add_phase,
    "add-task": cmd_add_task,
    "update-phase": cmd_update_phase,
    "update-task": cmd_update_task,
    "remove-phase": cmd_remove_phase,
    "remove-task": cmd_remove_task,
    "add-task-dependency": cmd_add_task_dependency,
    "remove-task-dependency": cmd_remove_task_dependency,
    "sort": cmd_sort,
    "check": cmd_check,
    "get-plan": cmd_get_plan,
    "batch": cmd_batch,
}


def main():
    # Normalize --now so argparse doesn't treat it as a flag
    argv = sys.argv[1:]
    normalized = []
    for i, a in enumerate(argv):
        if a == "--now":
            # Replace with a non-flag sentinel
            normalized.append("__NOW__")
        else:
            normalized.append(a)

    parser = build_parser()
    args = parser.parse_args(normalized)

    if not args.command:
        parser.print_help()
        sys.exit(0)

    # Convert sentinel back
    if hasattr(args, "value") and args.value == "__NOW__":
        args.value = "--now"

    handler = COMMAND_MAP.get(args.command)
    if not handler:
        die(args.command, f"Unknown command: {args.command}")

    assert handler is not None  # guaranteed by check above
    handler(args)


if __name__ == "__main__":
    main()
