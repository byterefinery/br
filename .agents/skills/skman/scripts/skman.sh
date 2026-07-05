#!/usr/bin/env bash
# skman — Skill Manager: scaffold, validate, and inspect agent skills.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -B "$SCRIPT_DIR/_skman.py" "$@"
