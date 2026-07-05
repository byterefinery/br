---
name: webfetch
description: Fetches web pages as markdown or HTML for LLM consumption. Use when the user wants to fetch, scrape, download, retrieve, grab, pull, or access any URL or webpage content. Supports uvx, pipx, curl, wget, and python3 fallbacks. Always impersonates Safari to avoid blocks. Use this whenever the user asks to read a website, get page content, or fetch a URL.
metadata:
  tags:
    - meta
---

# webfetch

## Overview

Fetches web pages and outputs them as LLM-friendly markdown or raw HTML.

## Usage

```bash
# Fetch as markdown to stdout (default)
webfetch.sh https://example.com

# Fetch as raw HTML to stdout
webfetch.sh --html https://example.com

# Explicitly fetch as markdown
webfetch.sh --md https://example.com
webfetch.sh --markdown https://example.com

# Save to file (nothing printed to stdout)
webfetch.sh --file ./page.md https://example.com
webfetch.sh --html --file ./page.html https://example.com

# Force a specific tool (skips auto-detection)
webfetch.sh --tool curl https://example.com
webfetch.sh --tool python https://example.com
webfetch.sh --tool uvx --html https://example.com
```

`--file` auto-detects format from extension (`.md` → markdown, `.html`/`.htm` → HTML) unless `--html`/`--md` is also given.

`--tool` accepts: `uvx`, `pipx`, `curl`, `wget`, `python` (alias `python3`). If the chosen tool is not installed, it exits with an error.

## Gotchas

- **`uvx` is preferred but not always installed** — the script auto-falls back through `pipx`, `curl`, `wget`, `python3`. If all fail, it exits with an error.
- **`--tool` bypasses auto-detection** — if you force a tool that isn't installed (e.g., `--tool uvx` on a system without `uvx`), the script exits with an error. Without `--tool`, it automatically tries the next available option.
- **HTML-to-markdown conversion is best-effort** — when using `curl`/`wget`/`python3`, HTML tags are stripped and basic elements (headings, lists, links, bold/italic) are converted. Complex layouts may lose structure.
- **Follows redirects by default** — curl uses `-L`, `wget` follows redirects natively, python3 urllib follows redirects automatically.
