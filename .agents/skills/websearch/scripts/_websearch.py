#!/usr/bin/env python3
"""websearch — DuckDuckGo Lite search with structured output."""

import argparse
import csv
import io
import json
import os
import random
import re
import sys
import urllib.parse
import urllib.request
import html


# ── User agents (Safari impersonation — rarely blocked) ─────────────
UA_IPHONE = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7_8 like Mac OS X) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) "
    "Version/26.0 Mobile/15E148 Safari/604.1"
)
UA_MAC = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_7) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) "
    "Version/26.0 Safari/605.1.15"
)
USER_AGENTS = [UA_IPHONE, UA_MAC]


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        prog="websearch",
        description="Search DuckDuckGo Lite and output structured results.",
    )
    parser.add_argument("query", help="Search query string")
    parser.add_argument(
        "--format",
        choices=["markdown", "md", "csv", "json"],
        default="markdown",
        dest="fmt",
        help="Output format (default: markdown)",
    )
    parser.add_argument(
        "--output",
        default="stdout",
        metavar="FILE",
        help="Output file path or 'stdout' (default: stdout)",
    )
    return parser.parse_args(argv)


def fetch_page(query):
    """Fetch DuckDuckGo Lite search results as HTML using urllib."""
    encoded = urllib.parse.quote_plus(query)
    url = f"https://lite.duckduckgo.com/lite?q={encoded}"
    ua = random.choice(USER_AGENTS)

    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": ua,
            "Accept": "text/html,application/xhtml+xml",
            "Accept-Language": "en-US,en;q=0.9",
        },
    )

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.read().decode("utf-8")
    except urllib.error.URLError as e:
        print(f"Error: request failed: {e.reason}", file=sys.stderr)
        sys.exit(1)
    except TimeoutError:
        print("Error: request timed out after 30s.", file=sys.stderr)
        sys.exit(1)


def parse_results(html_text):
    """Parse DuckDuckGo Lite HTML into list of result dicts."""
    results = []

    # Each result block: link row → snippet row → url row
    # We find all result-link anchors, then look ahead for snippet and source.
    link_re = re.compile(
        r"<a\s+rel=\"nofollow\"\s+href=\"([^\"]+)\"[^>]*class='result-link'>(.*?)</a>",
        re.DOTALL,
    )
    snippet_re = re.compile(
        r"class='result-snippet'>(.*?)</td>",
        re.DOTALL,
    )
    url_re = re.compile(
        r"class='link-text'>(.*?)</span>",
        re.DOTALL,
    )

    for m in link_re.finditer(html_text):
        redirect_url = m.group(1)
        raw_title = re.sub(r"<[^>]+>", "", m.group(2))
        title = html.unescape(raw_title.strip())

        # Search forward from end of this match for snippet and url
        after = html_text[m.end():]

        # Snippet: next result-snippet td after this link
        sm = snippet_re.search(after)
        snippet = ""
        if sm:
            raw_snip = re.sub(r"<[^>]+>", "", sm.group(1))
            snippet = html.unescape(raw_snip.strip())

        # Display URL: next link-text span after this link
        um = url_re.search(after)
        url_display = ""
        if um:
            raw_url = re.sub(r"<[^>]+>", "", um.group(1))
            url_display = html.unescape(raw_url.strip())

        results.append({
            "title": title,
            "url": extract_uddg(redirect_url),
            "snippet": snippet,
            "url_display": url_display,
        })

    return results


def extract_uddg(redirect_url):
    """Extract and decode the actual URL from DuckDuckGo redirect."""
    parsed = urllib.parse.urlparse(redirect_url)
    params = urllib.parse.parse_qs(parsed.query)
    uddg = params.get("uddg", [None])[0]
    if uddg:
        return urllib.parse.unquote(uddg)
    # Fallback: strip the redirect prefix
    return redirect_url.replace("//duckduckgo.com/l/?uddg=", "")


def format_markdown(results):
    """Format results as markdown."""
    if not results:
        return "No results found.\n"

    lines = []
    for i, r in enumerate(results, 1):
        lines.append(f"## {i}. {r['title']}")
        lines.append("")
        if r.get("snippet"):
            lines.append(f"{r['snippet']}")
            lines.append("")
        lines.append(f"- **URL**: {r['url']}")
        if r.get("url_display"):
            lines.append(f"- **Source**: {r['url_display']}")
        lines.append("")

    return "\n".join(lines)


def format_csv(results):
    """Format results as CSV (RFC 4180, all fields quoted)."""
    buf = io.StringIO()
    writer = csv.writer(buf, quoting=csv.QUOTE_ALL, lineterminator="\n")
    writer.writerow(["title", "url", "snippet", "source"])
    for r in results:
        writer.writerow([
            r["title"],
            r["url"],
            r.get("snippet", ""),
            r.get("url_display", ""),
        ])
    return buf.getvalue()


def format_json(results):
    """Format results as JSON."""
    return json.dumps(results, indent=2, ensure_ascii=False) + "\n"


def main():
    args = parse_args()

    fmt = "markdown" if args.fmt == "md" else args.fmt

    html_text = fetch_page(args.query)
    results = parse_results(html_text)

    if fmt == "markdown":
        output = format_markdown(results)
    elif fmt == "csv":
        output = format_csv(results)
    elif fmt == "json":
        output = format_json(results)
    else:
        print(f"Error: unknown format '{fmt}'", file=sys.stderr)
        sys.exit(1)

    if args.output == "stdout":
        sys.stdout.write(output)
    else:
        os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(output)
        print(f"Results written to {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()
