#!/usr/bin/env python3
"""skman — Skill Manager: scaffold, validate, and inspect agent skills.

Usage:
    skman.sh --help
    skman.sh create --help
    skman.sh validate --help
    skman.sh info --help
"""

import argparse
import os
import re
import sys
import textwrap


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

NAME_RE = re.compile(r'^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$')
MAX_NAME_LEN = 64
MAX_DESC_LEN = 1024

FRONTMATTER_RE = re.compile(
    r'^---\s*\n(?P<content>.*?)^---\s*\n', re.MULTILINE | re.DOTALL
)
YAML_LINE_RE = re.compile(r'^(?P<key>[a-z][a-z0-9_-]*)\s*:\s*(?P<value>.*)$')

DEFAULT_SKILL_MD = textwrap.dedent("""\
---
name: {name}
description: {description}
---

# {title}

## Overview

[Describe what this skill does and when to use it.]

## Usage

[How to use this skill. Include examples.]

""")

DEFAULT_SKILL_MD_WITH_SCRIPTS = textwrap.dedent("""\
---
name: {name}
description: {description}
---

# {title}

## Overview

[Describe what this skill does and when to use it.]

## Usage

```bash
{script_name}.sh --help
```

""")

# Matches trailing version suffix: -<digit>[-<digit>]* at end of dir name
# e.g. "demo-skill-2-4-1" -> "2-4-1", "git-8-20-0" -> "8-20-0"
VERSION_SUFFIX_RE = re.compile(r'-(\d+(?:-\d+)+)$')


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _parse_frontmatter(text):
    """Return (frontmatter_dict, body_text) or (None, text) if no frontmatter.

    Handles single-line values, quoted multi-line values, block scalars (|, >),
    indented continuation lines, and nested mappings/lists (e.g. metadata.tags).
    """
    m = FRONTMATTER_RE.match(text)
    if not m:
        return None, text
    body = text[m.end():]
    fm = {}
    lines = m.group('content').splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        # Skip blank lines and comments
        if not stripped or stripped.startswith('#'):
            i += 1
            continue
        lm = YAML_LINE_RE.match(stripped)
        if not lm:
            i += 1
            continue
        key = lm.group('key')
        value = lm.group('value').strip()
        # Handle block scalars (| or >)
        if value in ('|', '>'):
            i += 1
            block_lines = []
            while i < len(lines):
                bline = lines[i]
                if bline and (bline[0] == ' ' or bline[0] == '\t'):
                    block_lines.append(bline.strip())
                    i += 1
                else:
                    break
            fm[key] = '\n'.join(block_lines)
            continue
        # Handle quoted multi-line values
        if value.startswith('"') and not value.endswith('"'):
            i += 1
            parts = [value[1:]]
            while i < len(lines):
                cline = lines[i].strip()
                if cline.endswith('"'):
                    parts.append(cline[:-1])
                    break
                parts.append(cline)
                i += 1
            fm[key] = '\n'.join(parts)
            continue
        if value.startswith("'") and not value.endswith("'"):
            i += 1
            parts = [value[1:]]
            while i < len(lines):
                cline = lines[i].strip()
                if cline.endswith("'"):
                    parts.append(cline[:-1])
                    break
                parts.append(cline)
                i += 1
            fm[key] = '\n'.join(parts)
            continue
        # Handle nested mapping: key with no value, followed by indented children
        if not value:
            i += 1
            child = {}
            while i < len(lines):
                nline = lines[i]
                if not nline or nline[0] not in (' ', '\t'):
                    break
                nstripped = nline.strip()
                if not nstripped or nstripped.startswith('#'):
                    i += 1
                    continue
                # Check for list items (- item)
                if nstripped.startswith('- '):
                    # Collect all list items under the nearest sub-key
                    # Find the sub-key by looking at previous context
                    list_items = [nstripped[2:].strip()]
                    i += 1
                    while i < len(lines):
                        lline = lines[i]
                        if not lline or lline[0] not in (' ', '\t'):
                            break
                        lstripped = lline.strip()
                        if lstripped.startswith('- '):
                            list_items.append(lstripped[2:].strip())
                            i += 1
                        elif not lstripped or lstripped.startswith('#'):
                            i += 1
                        else:
                            break
                    # Assign to last sub-key seen
                    if child:
                        last_key = list(child.keys())[-1]
                        child[last_key] = list_items
                    continue
                # Sub-key: value
                slm = YAML_LINE_RE.match(nstripped)
                if slm:
                    skey = slm.group('key')
                    sval = slm.group('value').strip()
                    if not sval:
                        # Nested sub-mapping (rare, treat as empty string)
                        child[skey] = {}
                    else:
                        child[skey] = sval
                    i += 1
                else:
                    i += 1
            fm[key] = child
            continue
        # Handle indented continuation lines (next line is indented more)
        i += 1
        while i < len(lines):
            next_line = lines[i]
            if not next_line or next_line[0] in (' ', '\t'):
                cont = next_line.strip()
                if cont:
                    value += ' ' + cont
                i += 1
            else:
                break
        fm[key] = value
    return fm, body


def _validate_name(name):
    """Return list of error strings (empty = valid)."""
    errors = []
    if not name:
        errors.append("name is missing")
        return errors
    if len(name) > MAX_NAME_LEN:
        errors.append(f"name exceeds {MAX_NAME_LEN} characters ({len(name)})")
    if not NAME_RE.match(name):
        errors.append(
            "name must be lowercase letters, numbers, and hyphens only; "
            "no leading/trailing/consecutive hyphens"
        )
    return errors


def _validate_description(desc):
    """Return list of error strings (empty = valid)."""
    errors = []
    if desc is None:
        errors.append("description is missing (required)")
        return errors
    if not desc.strip():
        errors.append("description is empty (required)")
        return errors
    if len(desc) > MAX_DESC_LEN:
        errors.append(
            f"description exceeds {MAX_DESC_LEN} characters ({len(desc)})"
        )
    if re.search(r'<[a-zA-Z/][^>]*>', desc):
        errors.append("description must not contain XML/HTML tags")
    return errors


def _validate_metadata(metadata):
    """Return list of warning strings for optional metadata field.

    metadata should be a dict (mapping). If present, 'tags' must be a list of strings.
    Returns warnings only (metadata is optional).
    """
    warnings = []
    if metadata is None:
        return warnings
    if not isinstance(metadata, dict):
        warnings.append(
            f"metadata should be a mapping (got {type(metadata).__name__})"
        )
        return warnings
    tags = metadata.get('tags')
    if tags is not None:
        if not isinstance(tags, list):
            warnings.append(
                f"metadata.tags should be an array of strings (got {type(tags).__name__})"
            )
        elif not all(isinstance(t, str) for t in tags):
            non_str = [t for t in tags if not isinstance(t, str)]
            warnings.append(
                f"metadata.tags must contain only strings (found: {non_str})"
            )
    return warnings


def _validate_frontmatter(fm):
    """Return list of error strings for the full frontmatter."""
    errors = []
    name = fm.get('name', '') if fm else ''
    errors.extend(_validate_name(name))
    desc = fm.get('description', None) if fm else None
    errors.extend(_validate_description(desc))
    return errors


REQUIRED_SECTIONS = {'#'}  # body must start with a level-1 heading
# Warns when missing — every skill should explain what it does
RECOMMENDED_SECTIONS = {'## Overview'}
# Truly optional — no warning when absent
# (## Usage is for skills with commands/tools; knowledge-only skills don't need it)
TRULY_OPTIONAL_SECTIONS = {'## Usage', '## Gotchas', '## References'}


def _find_skill_md(path):
    """Given a path (file or dir), return the absolute path to SKILL.md."""
    abs_path = os.path.abspath(path)
    if os.path.isfile(abs_path):
        return abs_path
    if os.path.isdir(abs_path):
        candidate = os.path.join(abs_path, 'SKILL.md')
        if os.path.isfile(candidate):
            return candidate
    return None


def _check_sections(body):
    """Check for required and recommended sections in the body.

    ## Overview warns if missing — every skill should explain what it does.
    ## Usage, ## Gotchas, and ## References are truly optional — no warning.

    Returns (errors, warnings) lists.
    """
    errors = []
    warnings = []

    # Collect headings, skipping fenced code blocks
    in_fence = False
    found_headings = set()
    for line in body.splitlines():
        stripped = line.strip()
        if stripped.startswith('```'):
            in_fence = not in_fence
            continue
        if not in_fence and stripped.startswith('#'):
            found_headings.add(stripped)

    # Check recommended sections — warn if missing
    missing_recommended = RECOMMENDED_SECTIONS - found_headings
    if missing_recommended:
        warnings.append(
            f"missing recommended section(s): {', '.join(sorted(missing_recommended))}"
        )

    return errors, warnings


def _check_references_section(body):
    """Check that a ## References section (if present) uses a bulleted list.

    The spec requires bulleted lists like:
      - [01-topic](references/01-topic.md) — description

    Tables are not allowed in the References section.

    Returns (errors, warnings) lists.
    """
    errors = []
    warnings = []

    # Find ## References heading (outside fenced code blocks)
    lines = body.splitlines()
    in_fence = False
    ref_section_start = None
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith('```'):
            in_fence = not in_fence
            continue
        if not in_fence and stripped == '## References':
            ref_section_start = i
            break

    if ref_section_start is None:
        # No References section — nothing to check
        return errors, warnings

    # Collect lines after ## References until next heading or end of body
    section_lines = []
    for i in range(ref_section_start + 1, len(lines)):
        stripped = lines[i].strip()
        if stripped.startswith('```'):
            break  # stop at code fences
        if re.match(r'^#{1,6}\s', stripped) or re.match(r'^#{1,6}$', stripped):
            break  # stop at next heading
        section_lines.append(stripped)

    # Filter out blank lines and prose (non-list, non-table lines)
    content_lines = [l for l in section_lines if l and not l.startswith('|')]
    table_lines = [l for l in section_lines if l.startswith('|')]

    # Check if there's a bulleted list with reference links
    bullet_ref_pattern = re.compile(r'^-\s+\[.+\]\(.*references/.*\)')
    has_bullet_refs = any(bullet_ref_pattern.match(l) for l in content_lines)

    # Check if table format is used instead
    has_table = len(table_lines) > 1  # header + separator + rows = multiple pipe lines

    if has_table and not has_bullet_refs:
        warnings.append(
            "## References uses a table format; use a bulleted list instead "
            "(e.g. '- [01-topic](references/01-topic.md) — description')"
        )
    elif has_bullet_refs:
        pass  # valid bulleted list format
    else:
        warnings.append(
            "## References section does not contain a bulleted list of reference links; "
            "expected lines like '- [01-topic](references/01-topic.md) — description'"
        )

    return errors, warnings


def _check_reference_files(skill_dir):
    """Check that files in references/ directory follow NN-topic.md naming.

    Validates:
      - Each file starts with a numeric prefix (01-, 02-, …)
      - Prefixes are sequential with no gaps
      - Files end in .md

    Returns (errors, warnings) lists.
    """
    errors = []
    warnings = []

    ref_dir = os.path.join(skill_dir, 'references')
    if not os.path.isdir(ref_dir):
        return errors, warnings

    entries = sorted(os.listdir(ref_dir))
    # Filter to only files (skip subdirectories)
    files = [e for e in entries if os.path.isfile(os.path.join(ref_dir, e))]

    if not files:
        warnings.append("references/ directory is empty")
        return errors, warnings

    # Pattern: NN-topic.md where NN is 2+ digit number
    prefix_re = re.compile(r'^(\d{2,})-(.+\.md)$')
    found_prefixes = []
    bad_names = []

    for fname in files:
        m = prefix_re.match(fname)
        if m:
            found_prefixes.append(int(m.group(1)))
        else:
            bad_names.append(fname)

    if bad_names:
        warnings.append(
            f"references/ file(s) missing numeric prefix: "
            f"{', '.join(bad_names)} (expected NN-topic.md)"
        )

    # Check sequential ordering (no gaps)
    found_prefixes.sort()
    if found_prefixes:
        expected = list(range(1, len(found_prefixes) + 1))
        expected_fmt = [f"{e:02d}" for e in expected]
        actual_fmt = [f"{p:02d}" for p in found_prefixes]

        if found_prefixes != expected:
            # Build detailed gap info
            gaps = []
            duplicates = []
            seen = set()
            for p in found_prefixes:
                if p in seen:
                    duplicates.append(f"{p:02d}")
                seen.add(p)
            missing = [e for e in expected if e not in seen]
            if missing:
                gaps.extend([f"{m:02d}" for m in missing])

            detail_parts = []
            if gaps:
                detail_parts.append(f"missing gaps: {', '.join(gaps)}")
            if duplicates:
                detail_parts.append(f"duplicate prefixes: {', '.join(duplicates)}")
            if found_prefixes[-1] > len(found_prefixes):
                detail_parts.append(
                    f"last prefix {found_prefixes[-1]:02d} but only "
                    f"{len(found_prefixes)} files (expected {len(found_prefixes):02d})"
                )

            warnings.append(
                f"references/ prefixes not sequential ({', '.join(detail_parts)}); "
                f"found {actual_fmt}, expected {expected_fmt}"
            )
        else:
            pass  # sequential, no warning

    return errors, warnings


def _check_script_permissions(skill_dir, fm_name):
    """Check that scripts/<name>.sh is executable if it exists.

    Returns (errors, warnings) lists.
    """
    errors = []
    warnings = []

    if not fm_name:
        return errors, warnings

    sh_path = os.path.join(skill_dir, 'scripts', f'{fm_name}.sh')
    if os.path.isfile(sh_path):
        if not os.access(sh_path, os.X_OK):
            warnings.append(
                f"scripts/{fm_name}.sh is not executable (run chmod +x)"
            )

    return errors, warnings


def _check_script_usage_refs(body, fm_name):
    """Check that SKILL.md body uses `<name>.sh` instead of `./<name>.sh`
    for usage/instructional references.

    Scans outside fenced code blocks (``` ... ```) since those often show
    directory trees where `scripts/` is structural, not invocational.

    Returns (errors, warnings) lists.
    """
    errors = []
    warnings = []

    if not fm_name:
        return errors, warnings

    # Also check for the dir basename variant (e.g. demo-skill-2-4-1 vs demo-skill)
    base_name, _ = _strip_version_suffix(fm_name)

    in_fence = False
    bad_refs = set()  # (lineno, pattern)
    for lineno, line in enumerate(body.splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith('```'):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        # Check for ./<name>.sh patterns (both fm_name and base_name)
        for candidate in (fm_name, base_name):
            pattern = f'./{candidate}.sh'
            if pattern in stripped:
                bad_refs.add((lineno, pattern))

    if bad_refs:
        unique_lines = sorted(set(l for l, _ in bad_refs))
        lines_str = ', '.join(f"line {l}" for l in unique_lines)
        preferred = f'{fm_name}.sh'
        warnings.append(
            f"script usage reference(s) use './<name>.sh' instead of '{preferred}' ({lines_str})"
        )

    return errors, warnings


def _strip_version_suffix(dir_basename):
    """Strip trailing -<version> suffix from directory basename.

    Returns (name, version_with_hyphens_or_None).
    e.g. 'demo-skill-2-4-1' -> ('demo-skill', '2-4-1')
         'skman'       -> ('skman', None)
    """
    m = VERSION_SUFFIX_RE.search(dir_basename)
    if m:
        name = dir_basename[:m.start()]
        return name, m.group(1)
    return dir_basename, None


def _dir_version_to_dots(version_with_hyphens):
    """Convert hyphen-separated version to dot-separated.

    e.g. '0-11-19' -> '0.11.19'
    """
    return version_with_hyphens.replace('-', '.')


# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

def cmd_create(args):
    """Scaffold a new skill directory."""
    name = args.name.strip()
    description = args.description.strip()
    output_dir = args.output_dir
    version = getattr(args, 'version', None)
    if version:
        version = version.strip()

    # Validate before creating anything
    errors = []
    errors.extend(_validate_name(name))
    errors.extend(_validate_description(description))

    if errors:
        print("create: validation failed:", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        sys.exit(1)

    # Build directory name and H1 title
    if version:
        # Normalize: dots in H1, hyphens in dir name
        version_dots = version.replace('-', '.')
        version_hyphen = version.replace('.', '-')
        dir_name = f"{name}-{version_hyphen}"
        h1_title = f"{name} {version_dots}"
    else:
        dir_name = name
        h1_title = name

    # Create directory structure
    skill_dir = os.path.join(output_dir, dir_name)
    os.makedirs(skill_dir, exist_ok=True)

    skill_md_path = os.path.join(skill_dir, 'SKILL.md')
    if os.path.exists(skill_md_path):
        print(f"create: {skill_md_path} already exists — skipping", file=sys.stderr)
        sys.exit(1)

    if args.with_scripts:
        content = DEFAULT_SKILL_MD_WITH_SCRIPTS.format(
            name=dir_name, description=description, title=h1_title,
            script_name=name,
        )
    else:
        content = DEFAULT_SKILL_MD.format(name=dir_name, description=description, title=h1_title)
    with open(skill_md_path, 'w') as f:
        f.write(content)

    # Optionally create scripts directory (bash wrapper only — no assumed implementation)
    if args.with_scripts:
        scripts_dir = os.path.join(skill_dir, 'scripts')
        os.makedirs(scripts_dir, exist_ok=True)

        # Bash wrapper (entry point)
        sh_path = os.path.join(scripts_dir, f'{name}.sh')
        with open(sh_path, 'w') as f:
            f.write(f'#!/usr/bin/env bash\n')
            f.write(f'# {name} — {description}\n')
            f.write(f'set -euo pipefail\n')
            f.write(f'\n')
            f.write(f'SCRIPT_DIR="$(cd "$(dirname "${{BASH_SOURCE[0]}}")" && pwd)"\n')
            f.write(f'\n')
            f.write(f'# TODO: implement {name}\n')
            f.write(f'echo "Usage: {name}.sh <subcommand> [args...]"\n')
            f.write(f'exit 1\n')
        os.chmod(sh_path, 0o755)

        print(f"create: created bash wrapper at {sh_path}")

    # Optionally create references directory
    if args.with_references:
        ref_dir = os.path.join(skill_dir, 'references')
        os.makedirs(ref_dir, exist_ok=True)
        placeholder = os.path.join(ref_dir, '01-reference.md')
        with open(placeholder, 'w') as f:
            f.write(f"# {title} Reference\n\n[Detailed reference content.]\n")
        print(f"create: created references placeholder at {placeholder}")

    print(f"create: scaffolded skill '{dir_name}' at {skill_md_path}")


def _discover_skill_dirs(collection_dir):
    """Find all subdirectories in collection_dir that contain a SKILL.md.

    Returns a sorted list of absolute paths to the skill directories.
    """
    skills = []
    if not os.path.isdir(collection_dir):
        return skills
    for entry in sorted(os.listdir(collection_dir)):
        candidate = os.path.join(collection_dir, entry)
        if not os.path.isdir(candidate):
            continue
        skill_md = os.path.join(candidate, 'SKILL.md')
        if os.path.isfile(skill_md):
            skills.append(candidate)
    return skills


def _is_collection_dir(path):
    """Check if path is a collection directory (contains subdirs with SKILL.md).

    Returns True if the path is a directory containing at least one subdirectory
    with a SKILL.md, and does NOT itself have a SKILL.md at its root.
    """
    abs_path = os.path.abspath(path)
    if not os.path.isdir(abs_path):
        return False
    # If this dir itself has SKILL.md, it's a single skill, not a collection
    if os.path.isfile(os.path.join(abs_path, 'SKILL.md')):
        return False
    # Check if any subdirectory has SKILL.md
    return len(_discover_skill_dirs(abs_path)) > 0


def _validate_single_skill(skill_path, strict):
    """Validate a single skill. Returns (results, error_count, warn_count).

    results: list of (label, message) where label in {"PASS", "WARN", "ERROR"}
    """
    skill_md = _find_skill_md(skill_path)
    if skill_md is None:
        return [], 1, 0  # Can't find SKILL.md — treated as 1 error

    with open(skill_md, 'r') as f:
        content = f.read()

    fm, body = _parse_frontmatter(content)

    results = []

    skill_dir = os.path.dirname(skill_md)
    dir_basename = os.path.basename(skill_dir)
    dir_name, dir_version = _strip_version_suffix(dir_basename)

    # --- Frontmatter presence ---
    if fm is None:
        results.append(("ERROR", "no YAML frontmatter found (must start with ---)"))
    else:
        results.append(("PASS", "frontmatter present"))

        # Name
        name_errors = _validate_name(fm.get('name', ''))
        if name_errors:
            for e in name_errors:
                results.append(("ERROR", f"name: {e}"))
        else:
            results.append(("PASS", f"name '{fm.get('name', '')}' is valid"))

        # Description
        desc_errors = _validate_description(fm.get('description', None))
        if desc_errors:
            for e in desc_errors:
                results.append(("ERROR", f"description: {e}"))
        else:
            results.append(("PASS", "description is valid"))

        # Unknown fields
        known_fields = {'name', 'description', 'metadata'}
        unknown = set(fm.keys()) - known_fields
        if unknown:
            results.append(("WARN", f"unknown frontmatter fields: {', '.join(sorted(unknown))}"))
        else:
            results.append(("PASS", "no unknown frontmatter fields"))

        # Metadata validation (optional)
        metadata = fm.get('metadata')
        if metadata is not None:
            meta_warnings = _validate_metadata(metadata)
            for w in meta_warnings:
                results.append(("WARN", f"metadata: {w}"))
            if not meta_warnings:
                results.append(("PASS", "metadata structure is valid"))

        # Name vs directory basename consistency
        fm_name = fm.get('name', '')
        name_matches = (fm_name == dir_basename)
        if fm_name and not name_matches:
            results.append(
                ("WARN",
                 f"directory name '{dir_basename}' does not match "
                 f"frontmatter name '{fm_name}' (expected '{dir_basename}')")
            )
        else:
            results.append(("PASS", f"directory name matches frontmatter name '{fm_name}'"))

        # Script permission checks
        perm_errors, perm_warnings = _check_script_permissions(skill_dir, fm_name)
        for e in perm_errors:
            results.append(("ERROR", e))
        for w in perm_warnings:
            results.append(("WARN", w))
        if not perm_errors and not perm_warnings:
            sh_path = os.path.join(skill_dir, 'scripts', f'{fm_name}.sh')
            if os.path.isfile(sh_path):
                results.append(("PASS", f"scripts/{fm_name}.sh is executable"))

        # Script usage reference style check (outside fenced code blocks)
        ref_errors, ref_warnings = _check_script_usage_refs(body, fm_name)
        for e in ref_errors:
            results.append(("ERROR", e))
        for w in ref_warnings:
            results.append(("WARN", w))
        if not ref_errors and not ref_warnings:
            results.append(("PASS", "script usage references use '<name>.sh' format"))

    # --- Body checks ---
    body_lines = body.splitlines()
    body_line_count = len(body_lines)

    # Level-1 heading
    first_content_line = None
    for line in body_lines:
        stripped = line.strip()
        if stripped:
            first_content_line = stripped
            break
    if first_content_line is None:
        results.append(("PASS", "body is empty (no content lines)"))
    elif not first_content_line.startswith('# '):
        results.append(
            ("ERROR",
             f"body must start with a level-1 heading (found: '{first_content_line[:60]}...')")
        )
    else:
        h1_text = first_content_line[2:]  # strip '# '
        expected_h1 = dir_name
        if dir_version:
            expected_h1 = f"{dir_name} {_dir_version_to_dots(dir_version)}"
        if h1_text == expected_h1:
            results.append(("PASS", f"H1 heading '{first_content_line}' matches expected format"))
        else:
            results.append(
                ("ERROR",
                 f"H1 heading '{first_content_line}' does not match expected "
                 f"'#{expected_h1}' (must be '# <name>' or '# <name> <version>')")
            )

    # Line count
    if body_line_count > 500:
        results.append(
            ("WARN", f"body has {body_line_count} lines (recommended: under 500)")
        )
    else:
        results.append(("PASS", f"body has {body_line_count} lines (under 500)"))

    # Section checks
    sec_errors, sec_warnings = _check_sections(body)
    for e in sec_errors:
        results.append(("ERROR", e))
    for w in sec_warnings:
        results.append(("WARN", w))
    if not sec_errors and not sec_warnings:
        results.append(("PASS", "all recommended sections present"))

    # References section format check (only when ## References exists)
    ref_errors, ref_warnings = _check_references_section(body)
    for e in ref_errors:
        results.append(("ERROR", e))
    for w in ref_warnings:
        results.append(("WARN", w))
    if not ref_errors and not ref_warnings:
        results.append(("PASS", "references section format is correct (or absent)"))

    # Reference files naming check (references/ directory on disk)
    rf_errors, rf_warnings = _check_reference_files(skill_dir)
    for e in rf_errors:
        results.append(("ERROR", e))
    for w in rf_warnings:
        results.append(("WARN", w))
    if not rf_errors and not rf_warnings:
        results.append(("PASS", "reference files follow NN-topic.md naming (or absent)"))

    error_count = sum(1 for label, _ in results if label == "ERROR")
    warn_count = sum(1 for label, _ in results if label == "WARN")

    return results, error_count, warn_count


def _print_single_results(results, strict):
    """Print enumerated results for a single skill."""
    error_count = sum(1 for label, _ in results if label == "ERROR")
    warn_count = sum(1 for label, _ in results if label == "WARN")

    passed = error_count == 0
    if strict and warn_count > 0:
        passed = False

    if error_count:
        print("validate: FAILED")
    elif warn_count:
        print("validate: OK (with warnings)")
    else:
        print("validate: OK")

    passes = [(i, msg) for i, (label, msg) in enumerate(results, 1) if label == "PASS"]
    warns = [(i, msg) for i, (label, msg) in enumerate(results, 1) if label == "WARN"]
    errors_list = [(i, msg) for i, (label, msg) in enumerate(results, 1) if label == "ERROR"]

    counter = 0
    for _, msg in passes:
        counter += 1
        print(f"  {counter}. [PASS] {msg}")
    for _, msg in warns:
        counter += 1
        print(f"  {counter}. [WARN] {msg}")
    for _, msg in errors_list:
        counter += 1
        print(f"  {counter}. [ERROR] {msg}")

    return 0 if passed else 1


def cmd_validate(args):
    """Validate a SKILL.md file or a collection of skills against spec rules.

    Supports three modes:
      1. Single skill (path to skill dir or SKILL.md file)
      2. Collection directory (path to dir containing skill subdirs)
      3. Explicit collection with --all flag on a dir
    """
    target = args.path
    strict = args.strict

    # Resolve path
    abs_target = os.path.abspath(target)

    # Determine mode: single skill vs collection
    if os.path.isfile(abs_target):
        # Direct file path — single skill mode
        skill_md = _find_skill_md(abs_target)
        if skill_md is None:
            print(f"validate: no SKILL.md found at '{target}'", file=sys.stderr)
            sys.exit(1)
        results, error_count, warn_count = _validate_single_skill(abs_target, strict)
        sys.exit(_print_single_results(results, strict))

    elif os.path.isdir(abs_target):
        # Could be single skill dir or collection dir
        skill_md = _find_skill_md(abs_target)
        if skill_md is not None:
            # This dir has SKILL.md — single skill mode
            results, error_count, warn_count = _validate_single_skill(abs_target, strict)
            sys.exit(_print_single_results(results, strict))

        # No SKILL.md at root — check if it's a collection
        skill_dirs = _discover_skill_dirs(abs_target)
        if not skill_dirs:
            print(f"validate: no SKILL.md found at '{target}' "
                  f"(not a skill dir or collection)", file=sys.stderr)
            sys.exit(1)

        # Collection mode — validate all skills
        _validate_collection(skill_dirs, strict)

    else:
        print(f"validate: path not found '{target}'", file=sys.stderr)
        sys.exit(1)


def _validate_collection(skill_dirs, strict):
    """Validate all skills in a collection directory.

    Prints per-skill results and a summary. Exits 0 if all pass, 1 otherwise.
    """
    total = len(skill_dirs)
    passed_count = 0
    failed_count = 0
    warned_count = 0
    total_errors = 0
    total_warnings = 0

    for i, skill_dir in enumerate(skill_dirs, 1):
        skill_name = os.path.basename(skill_dir)
        print(f"{'=' * 60}")
        print(f"  {i}/{total}: {skill_name}")
        print(f"{'=' * 60}")

        results, error_count, warn_count = _validate_single_skill(skill_dir, strict)

        # Determine status for this skill
        skill_passed = error_count == 0
        if strict and warn_count > 0:
            skill_passed = False

        if skill_passed and warn_count > 0:
            status = "OK (with warnings)"
            warned_count += 1
        elif skill_passed:
            status = "OK"
            passed_count += 1
        else:
            status = "FAILED"
            failed_count += 1

        total_errors += error_count
        total_warnings += warn_count

        print(f"  Status: {status} ({error_count} error(s), {warn_count} warning(s))")
        _print_single_results(results, strict)
        print()  # blank line between skills

    # Summary
    print(f"{'=' * 60}")
    print(f"  Summary: {total} skill(s) validated")
    print(f"  Passed: {passed_count}, Warnings: {warned_count}, Failed: {failed_count}")
    print(f"  Total errors: {total_errors}, Total warnings: {total_warnings}")
    print(f"{'=' * 60}")

    sys.exit(0 if failed_count == 0 else 1)


def cmd_info(args):
    """Print parsed frontmatter and structural summary of a skill."""
    target = args.path
    skill_md = _find_skill_md(target)

    if skill_md is None:
        print(f"info: no SKILL.md found at '{target}'", file=sys.stderr)
        sys.exit(1)

    with open(skill_md, 'r') as f:
        content = f.read()

    fm, body = _parse_frontmatter(content)

    # Print frontmatter
    print("info: SKILL.md analysis")
    print("-" * 40)
    if fm:
        for key in ('name', 'description'):
            val = fm.get(key)
            if val is not None:
                print(f"  {key}: {val}")
        # Show metadata if present
        metadata = fm.get('metadata')
        if metadata is not None:
            tags = metadata.get('tags', [])
            if tags:
                print(f"  metadata.tags: {', '.join(tags)}")
        # Show any extra fields
        known_fields = {'name', 'description', 'metadata'}
        extra = set(fm.keys()) - known_fields
        for key in sorted(extra):
            print(f"  {key}: {fm[key]}")
    else:
        print("  (no frontmatter)")

    # Structural summary
    body_lines = body.splitlines()
    headings = []
    in_fence = False
    for line in body_lines:
        stripped = line.strip()
        if stripped.startswith('```'):
            in_fence = not in_fence
            continue
        if not in_fence and stripped.startswith('#'):
            headings.append(stripped)
    line_count = len(body_lines)
    word_count = len(body.split())

    print(f"  body lines: {line_count}")
    print(f"  body words: {word_count}")
    if headings:
        print("  headings:")
        for h in headings:
            depth = len(h) - len(h.lstrip('#'))
            text = h.lstrip('#').strip()
            indent = "    " * (depth - 1)
            print(f"  {indent}- {text}")

    # Directory listing
    skill_dir = os.path.dirname(skill_md)
    entries = sorted(os.listdir(skill_dir))
    if entries:
        print("  files:")
        for entry in entries:
            full = os.path.join(skill_dir, entry)
            if os.path.isdir(full):
                print(f"    {entry}/")
            else:
                size = os.path.getsize(full)
                print(f"    {entry} ({size} bytes)")


# ---------------------------------------------------------------------------
# generate subcommand
# ---------------------------------------------------------------------------

AUTOGEN_MARKER = "<!-- IMPORTANT: never change after this point because it is automatically generated -->"


def _discover_skills(skills_dir):
    """Scan skills_dir for directories containing SKILL.md.

    Returns a sorted list of (name, description) tuples.
    name = directory basename, description = frontmatter 'description' field.
    """
    skills = []
    if not os.path.isdir(skills_dir):
        return skills

    for entry in sorted(os.listdir(skills_dir)):
        skill_md = os.path.join(skills_dir, entry, 'SKILL.md')
        if not os.path.isfile(skill_md):
            continue
        with open(skill_md, 'r') as f:
            content = f.read()
        fm, _ = _parse_frontmatter(content)
        name = entry
        desc = ''
        if fm:
            name = fm.get('name', entry)
            desc = fm.get('description', '') or ''
        skills.append((name, desc))

    return skills


def _build_table(skills):
    """Build the Skills Table markdown from a list of (name, description)."""
    lines = []
    lines.append("## Skills Table")
    lines.append("")
    lines.append("| No | Skill | Description |")
    lines.append("|----|-------|-------------|")
    for i, (name, desc) in enumerate(skills, 1):
        lines.append(f"| {i} | {name} | {desc} |")
    return "\n".join(lines)


def _build_statistics(total):
    """Build the Statistics section markdown."""
    lines = []
    lines.append("")
    lines.append("## Statistics")
    lines.append("")
    lines.append(f"- **Total Skills**: {total}")
    return "\n".join(lines)


def cmd_generate(args):
    """Generate the Skills Table and Statistics in README.md."""
    skills_dir = args.skills_dir
    readme_path = args.readme

    # Discover all skills
    skills = _discover_skills(skills_dir)
    total = len(skills)

    if total == 0:
        print(f"generate: no skills found in '{skills_dir}'", file=sys.stderr)
        sys.exit(1)

    # Build replacement section
    table = _build_table(skills)
    stats = _build_statistics(total)
    new_section = f"{AUTOGEN_MARKER}\n{table}\n{stats}\n"

    # Read README
    if not os.path.isfile(readme_path):
        print(f"generate: README not found at '{readme_path}'", file=sys.stderr)
        sys.exit(1)

    with open(readme_path, 'r') as f:
        readme = f.read()

    # Replace everything from marker to end of file
    idx = readme.find(AUTOGEN_MARKER)
    if idx == -1:
        print(f"generate: auto-generated marker not found in '{readme_path}'", file=sys.stderr)
        sys.exit(1)

    new_readme = readme[:idx] + new_section

    with open(readme_path, 'w') as f:
        f.write(new_readme)

    print(f"generate: updated {readme_path} with {total} skills")


# ---------------------------------------------------------------------------
# Argument parser
# ---------------------------------------------------------------------------

def build_parser():
    parser = argparse.ArgumentParser(
        prog='skman',
        description=textwrap.dedent("""\
            Skill Manager — scaffold, validate, and inspect agent skills.

            Subcommands:
              create      Scaffold a new skill directory with SKILL.md
              validate    Check SKILL.md against spec rules
              info        Print frontmatter and structural summary
              generate    Generate Skills Table and Statistics in README.md

            Use '<subcommand> --help' for details on each subcommand.
        """),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = parser.add_subparsers(dest='subcommand')

    # --- create ---
    p_create = sub.add_parser(
        'create',
        description=textwrap.dedent("""\
            Scaffold a new skill directory with SKILL.md and optional scripts/references.

            Examples:
              skman.sh create my-skill "Does X and Y"
              skman.sh create my-skill "Desc" --with-scripts --with-references
              skman.sh create my-skill "Desc" -o ./custom-skills
              skman.sh create demo-skill "Dummy example skill" --version 2.4.1
        """),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p_create.add_argument('name', help='Skill name (lowercase, hyphens, numbers)')
    p_create.add_argument('description', help='Skill description (max 1024 chars)')
    p_create.add_argument(
        '--version', '-V',
        default=None,
        help='Optional version (e.g. 0.11.19). Dir becomes <name>-<version>, H1 is "# <name> <version>"',
    )
    p_create.add_argument(
        '--output-dir', '-o',
        default='.agents/skills',
        help='Parent directory for the skill (default: .agents/skills)',
    )
    p_create.add_argument(
        '--with-scripts',
        action='store_true',
        help='Also create scripts/ directory with bash wrapper',
    )
    p_create.add_argument(
        '--with-references',
        action='store_true',
        help='Also create a references/ directory with placeholder',
    )

    # --- validate ---
    p_validate = sub.add_parser(
        'validate',
        description=textwrap.dedent("""\
            Validate a SKILL.md file against the agent skills spec.

            Supports three modes:
              - Single skill: path to a skill directory or SKILL.md file
              - Collection: path to a directory containing skill subdirectories
              - Auto-detect: if the path is a directory without SKILL.md but
                contains subdirs with SKILL.md, it validates all of them

            Checks:
              - Frontmatter presence and required fields
              - Name format (lowercase, hyphens, length)
              - Description presence and length
              - Body line count (warning if over 500)

            Examples:
              skman.sh validate ./my-skill
              skman.sh validate ./my-skill/SKILL.md
              skman.sh validate --strict ./my-skill
              skman.sh validate .agents/skills        # validate all skills
              skman.sh validate ./skills-python        # validate custom collection
        """),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p_validate.add_argument('path', help='Path to skill directory, SKILL.md file, or skills collection directory')
    p_validate.add_argument(
        '--strict',
        action='store_true',
        help='Treat warnings as errors (non-zero exit on any warning)',
    )

    # --- info ---
    p_info = sub.add_parser(
        'info',
        description=textwrap.dedent("""\
            Print frontmatter and structural summary of a skill.

            Shows:
              - Parsed frontmatter fields
              - Body line/word count
              - Heading outline
              - Directory listing with file sizes

            Examples:
              skman.sh info ./my-skill
              skman.sh info ./my-skill/SKILL.md
        """),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p_info.add_argument('path', help='Path to skill directory or SKILL.md file')

    # --- generate ---
    p_generate = sub.add_parser(
        'generate',
        description=textwrap.dedent("""\
            Generate the Skills Table and Statistics section in README.md.

            Scans all skill directories for SKILL.md files, parses frontmatter,
            and replaces everything from the auto-generated marker to end of file.

            Examples:
              skman.sh generate
              skman.sh generate --skills-dir ./custom-skills
              skman.sh generate --readme ./docs/README.md
        """),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p_generate.add_argument(
        '--skills-dir',
        default='.agents/skills',
        help='Directory containing skill subdirectories (default: .agents/skills)',
    )
    p_generate.add_argument(
        '--readme',
        default='README.md',
        help='Path to README.md to update (default: README.md)',
    )

    return parser


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    parser = build_parser()
    args = parser.parse_args()

    if args.subcommand is None:
        parser.print_help()
        sys.exit(0)

    dispatch = {
        'create': cmd_create,
        'validate': cmd_validate,
        'info': cmd_info,
        'generate': cmd_generate,
    }
    dispatch[args.subcommand](args)


if __name__ == '__main__':
    main()
