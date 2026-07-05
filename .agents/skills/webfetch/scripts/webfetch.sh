#!/usr/bin/env bash
# webfetch — Fetch web pages as markdown or HTML for LLM consumption.
# Tries tools in priority order: uvx, pipx, curl, wget, python3 (stdlib only).
set -euo pipefail

# ── Argument parsing ────────────────────────────────────────────────
OUTPUT_FORMAT="md"   # default: markdown
OUTPUT_MODE="stdout" # default: print to stdout
OUTFILE=""           # path when --file is used
TOOL=""              # auto-detect if empty (uvx|pipx|curl|wget|python)
URL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --html)     OUTPUT_FORMAT="html"; shift ;;
        --md|--markdown) OUTPUT_FORMAT="md"; shift ;;
        --stdout)   OUTPUT_MODE="stdout"; shift ;;
        --file)
            OUTPUT_MODE="file"
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                echo "webfetch.sh: --file requires a path argument." >&2
                exit 1
            fi
            OUTFILE="$2"; shift 2
            ;;
        --tool)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                echo "webfetch.sh: --tool requires a value (uvx, pipx, curl, wget, python)." >&2
                exit 1
            fi
            TOOL="$2"; shift 2
            ;;
        -h|--help)
            cat <<'EOF'
Usage: webfetch.sh [OPTIONS] <URL>

Fetch a web page and output as markdown (default) or raw HTML.

Options:
  --html          Output raw HTML instead of markdown
  --md, --markdown  Output markdown (default)
  --stdout        Print result to stdout (default)
  --file <path>   Save result to file; nothing printed to stdout
  --tool <name>   Force a specific tool (uvx, pipx, curl, wget, python/python3)
  -h, --help      Show this help message

Examples:
  webfetch.sh https://example.com
  webfetch.sh --html --stdout https://example.com
  webfetch.sh --md --file ./page.md https://example.com
  webfetch.sh --tool curl https://example.com

Auto-detection tries tools in order: uvx → pipx → curl → wget → python3
EOF
            exit 0
            ;;
        -*) echo "webfetch.sh: unknown option '$1'. Try --help." >&2; exit 1 ;;
        *)  URL="$1"; shift ;;
    esac
done

if [[ -z "$URL" ]]; then
    echo "webfetch.sh: missing URL. Usage: webfetch.sh [OPTIONS] <URL>" >&2
    exit 1
fi

# Normalise tool alias
if [[ "$TOOL" == "python3" ]]; then TOOL="python"; fi

# Validate --tool value
if [[ -n "$TOOL" ]]; then
    case "$TOOL" in
        uvx|pipx|curl|wget|python) ;;
        *) echo "webfetch.sh: unknown tool '$TOOL'. Must be one of: uvx, pipx, curl, wget, python." >&2; exit 1 ;;
    esac
    # Check the chosen tool actually exists
    case "$TOOL" in
        uvx)   command -v uvx    >/dev/null 2>&1 || { echo "webfetch.sh: '$TOOL' is not installed." >&2; exit 1; } ;;
        pipx)  command -v pipx   >/dev/null 2>&1 || { echo "webfetch.sh: '$TOOL' is not installed." >&2; exit 1; } ;;
        curl)  command -v curl   >/dev/null 2>&1 || { echo "webfetch.sh: '$TOOL' is not installed." >&2; exit 1; } ;;
        wget)  command -v wget   >/dev/null 2>&1 || { echo "webfetch.sh: '$TOOL' is not installed." >&2; exit 1; } ;;
        python) command -v python3 >/dev/null 2>&1 || { echo "webfetch.sh: 'python' (python3) is not installed." >&2; exit 1; } ;;
    esac
fi

# Derive output format from --file path if not explicitly set
if [[ "$OUTPUT_MODE" == "file" && -n "$OUTFILE" ]]; then
    case "$OUTFILE" in
        *.html|*.htm) OUTPUT_FORMAT="html" ;;
        *.md|*.markdown) OUTPUT_FORMAT="md" ;;
    esac
fi

# ── Temp file ───────────────────────────────────────────────────────
TMPFILE=""
cleanup() { [[ -n "$TMPFILE" && -f "$TMPFILE" ]] && rm -f "$TMPFILE"; }
trap cleanup EXIT

if [[ "$OUTPUT_FORMAT" == "html" ]]; then
    TMPFILE=$(mktemp /tmp/webfetch.XXXXXX.html)
else
    TMPFILE=$(mktemp /tmp/webfetch.XXXXXX.md)
fi

# ── User agents (Safari impersonation — rarely blocked) ─────────────
UA_IPHONE='Mozilla/5.0 (iPhone; CPU iPhone OS 18_7_8 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1'
UA_MAC='Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15'

# ── Helpers ─────────────────────────────────────────────────────────
# Strip HTML tags, convert to markdown-like text (python3 stdlib only).
html_to_md() {
    python3 -c '
import sys, re, html as html_mod

content = open(sys.argv[1], encoding="utf-8", errors="replace").read()

# Decode HTML entities
content = html_mod.unescape(content)

# Block-level tag conversions (before stripping)
replacements = [
    (r"<h1[^>]*>(.*?)</h1>", r"\n\n# \1\n\n"),
    (r"<h2[^>]*>(.*?)</h2>", r"\n\n## \1\n\n"),
    (r"<h3[^>]*>(.*?)</h3>", r"\n\n### \1\n\n"),
    (r"<h4[^>]*>(.*?)</h4>", r"\n\n#### \1\n\n"),
    (r"<h5[^>]*>(.*?)</h5>", r"\n\n##### \1\n\n"),
    (r"<h6[^>]*>(.*?)</h6>", r"\n\n###### \1\n\n"),
    (r"<p[^>]*>(.*?)</p>",   r"\n\n\1\n\n"),
    (r"<br\s*/?>",           r"\n"),
    (r"<li[^>]*>(.*?)</li>", r"  - \1\n"),
    (r"<a[^>]*href=\"([^\"]*?)\"[^>]*>(.*?)</a>", r"\2 (\1)"),
    (r"<strong[^>]*>(.*?)</strong>", r"**\1**"),
    (r"<b[^>]*>(.*?)</b>",     r"**\1**"),
    (r"<em[^>]*>(.*?)</em>",   r"*\1*"),
    (r"<i[^>]*>(.*?)</i>",     r"*\1*"),
    (r"<code[^>]*>(.*?)</code>", r"`\1`"),
    (r"<pre[^>]*>(.*?)</pre>", r"\n\n```\n\1\n```\n\n"),
]

for pat, repl in replacements:
    content = re.sub(pat, repl, content, flags=re.DOTALL | re.IGNORECASE)

# Strip HTML comments first (contains > chars that break tag stripping)
content = re.sub(r"<!--.*?-->", "", content, flags=re.DOTALL)

# Strip remaining tags
content = re.sub(r"<[^>]+>", "", content)

# Collapse whitespace
content = re.sub(r"[ \t]+", " ", content)
content = re.sub(r"\n{3,}", "\n\n", content)
content = content.strip()

print(content)
' "$1"
}

# ── Try each tool in priority order ────────────────────────────────

try_uvx() {
    command -v uvx >/dev/null 2>&1 || return 1
    if [[ "$OUTPUT_FORMAT" == "html" ]]; then
        uvx 'scrapling[shell]' extract get --impersonate safari "$URL" "$TMPFILE"
    else
        uvx 'scrapling[shell]' extract get --impersonate safari --ai-targeted "$URL" "$TMPFILE"
    fi
}

try_pipx() {
    command -v pipx >/dev/null 2>&1 || return 1
    if [[ "$OUTPUT_FORMAT" == "html" ]]; then
        pipx run 'scrapling[shell]' extract get --impersonate safari "$URL" "$TMPFILE"
    else
        pipx run 'scrapling[shell]' extract get --impersonate safari --ai-targeted "$URL" "$TMPFILE"
    fi
}

try_curl() {
    command -v curl >/dev/null 2>&1 || return 1
    # Follow redirects (-L), use Safari user-agent, silent mode
    curl -sSL --max-time 30 \
        -H "User-Agent: $UA_IPHONE" \
        -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" \
        -H "Accept-Language: en-US,en;q=0.9" \
        "$URL" -o "$TMPFILE"
    if [[ "$OUTPUT_FORMAT" != "html" ]]; then
        html_to_md "$TMPFILE"
    fi
}

try_wget() {
    command -v wget >/dev/null 2>&1 || return 1
    # Follow redirects, use Safari user-agent, quiet mode, output to file
    wget -q --max-redirect=20 --timeout=30 \
        --header="User-Agent: $UA_IPHONE" \
        --header="Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" \
        -O "$TMPFILE" "$URL"
    if [[ "$OUTPUT_FORMAT" != "html" ]]; then
        html_to_md "$TMPFILE"
    fi
}

try_python3() {
    command -v python3 >/dev/null 2>&1 || return 1
    python3 -c '
import sys, urllib.request, ssl

url = sys.argv[1]
outfile = sys.argv[2]
output_format = sys.argv[3]

ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7_8 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"

ctx = ssl.create_default_context()
req = urllib.request.Request(url, headers={"User-Agent": ua})
resp = urllib.request.urlopen(req, context=ctx, timeout=30)
data = resp.read().decode("utf-8", errors="replace")

if output_format == "html":
    with open(outfile, "w", encoding="utf-8") as f:
        f.write(data)
else:
    import re, html as html_mod
    content = html_mod.unescape(data)
    # Basic block-level conversions
    for tag, prefix in [("h1","#"),("h2","##"),("h3","###")]:
        pat = "<" + tag + r"[^>]*>(.*?)</" + tag + ">"
        repl = "\n\n" + prefix + r" \1\n\n"
        content = re.sub(pat, repl, content, flags=re.DOTALL|re.I)
    content = re.sub(r"<p[^>]*>(.*?)</p>", r"\n\n\1\n\n", content, flags=re.DOTALL|re.I)
    content = re.sub(r"<br\s*/?>", "\n", content, flags=re.I)
    content = re.sub(r"<li[^>]*>(.*?)</li>", r"  - \1\n", content, flags=re.DOTALL|re.I)
    content = re.sub(r"<a[^>]*href=\"([^\"]*?)\"[^>]*>(.*?)</a>", r"\2 (\1)", content, flags=re.DOTALL|re.I)
    # Strip HTML comments first (contains > chars that break tag stripping)
    content = re.sub(r"<!--.*?-->", "", content, flags=re.DOTALL)
    content = re.sub(r"<[^>]+>", "", content)
    content = re.sub(r"[ \t]+", " ", content)
    content = re.sub(r"\n{3,}", "\n\n", content)
    with open(outfile, "w", encoding="utf-8") as f:
        f.write(content.strip())
' "$URL" "$TMPFILE" "$OUTPUT_FORMAT"
}

# ── Main: run selected tool or auto-detect ─────────────────────────
if [[ -n "$TOOL" ]]; then
    # User specified a tool — use it directly (already validated above)
    case "$TOOL" in
        uvx)    try_uvx    || { echo "webfetch.sh: '$TOOL' failed to fetch $URL." >&2; exit 1; } ;;
        pipx)   try_pipx   || { echo "webfetch.sh: '$TOOL' failed to fetch $URL." >&2; exit 1; } ;;
        curl)   try_curl   || { echo "webfetch.sh: '$TOOL' failed to fetch $URL." >&2; exit 1; } ;;
        wget)   try_wget   || { echo "webfetch.sh: '$TOOL' failed to fetch $URL." >&2; exit 1; } ;;
        python) try_python3 || { echo "webfetch.sh: '$TOOL' failed to fetch $URL." >&2; exit 1; } ;;
    esac
else
    # Auto-detect: try tools in priority order
    if ! try_uvx 2>/dev/null; then
        if ! try_pipx 2>/dev/null; then
            if ! try_curl 2>/dev/null; then
                if ! try_wget 2>/dev/null; then
                    if ! try_python3 2>/dev/null; then
                        echo "webfetch.sh: no suitable tool found (tried uvx, pipx, curl, wget, python3)." >&2
                        exit 1
                    fi
                fi
            fi
        fi
    fi
fi

# ── Output ──────────────────────────────────────────────────────────
if [[ "$OUTPUT_MODE" == "stdout" ]]; then
    cat "$TMPFILE"
elif [[ "$OUTPUT_MODE" == "file" && -n "$OUTFILE" ]]; then
    cp "$TMPFILE" "$OUTFILE"
fi
