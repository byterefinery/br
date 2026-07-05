---
name: websearch
description: Searches the web via DuckDuckGo and returns results as markdown, CSV, or JSON. Use this skill whenever the user wants to search the web, look up information online, find URLs, do web search, research a topic, or needs current/web-based answers.
metadata:
  tags:
    - meta
---

# websearch

Search the web via DuckDuckGo and return structured results.

## Overview

`websearch` fetches search results from DuckDuckGo, parses the HTML response, and outputs them in a structured format.

Supports three output formats: **markdown** (default), **CSV**, and **JSON**. Results can be written to stdout or a file.

## Usage

```bash
# Basic search (markdown to stdout)
websearch.sh "react hooks tutorial"

# JSON output to file
websearch.sh "python async patterns" --format json --output results.json

# CSV output
websearch.sh "rust vs go 2025" --format csv

# Help
websearch.sh --help
```

### Options

| Flag | Default | Description |
|---|---|---|
| `--format` | `markdown` | Output format: `markdown`, `csv`, `json` |
| `--output` | `stdout` | Output destination: `stdout` or a file path |

## Gotchas

- **DuckDuckGo blocks automated requests** — the script impersonates Safari (iPhone/Mac user agents) to reduce blocking. If results are empty, the site may have rate-limited the IP.
- **URLs in results are DuckDuckGo redirect links** — the `uddg` parameter contains the actual URL (URL-encoded). The parser extracts and decodes it automatically.
- **Results are limited to one page (10 results)** — pagination is not supported. Use more specific queries to surface relevant results on the first page.
