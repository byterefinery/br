#!/usr/bin/env bash
# websearch.sh — DuckDuckGo Lite search wrapper
# Delegates to _websearch.py for parsing and formatting.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 "${SCRIPT_DIR}/_websearch.py" "$@"
