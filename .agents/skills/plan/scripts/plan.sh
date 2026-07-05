#!/usr/bin/env bash
# plan.sh — thin wrapper around _plan.py
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 -B "${SCRIPT_DIR}/_plan.py" "$@"
