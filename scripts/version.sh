#!/bin/bash
# Prints the newest released version in a changelog, or 0.0.0 if nothing is released yet.
# Fails if the newest version heading is malformed.
# Usage: scripts/version.sh [CHANGELOG.md]
set -euo pipefail

changelog="${1:-CHANGELOG.md}"

# Checked here because the grep below tolerates a changelog with no headings.
if [[ ! -r "$changelog" ]]; then
  echo "error: cannot read $changelog" >&2
  exit 1
fi

# The first level-2 heading that isn't [Unreleased] is the newest release.
heading=$(grep -E '^## ' "$changelog" | grep -vE '^## \[Unreleased\][[:space:]]*$' | head -n 1 || true)

if [[ -z "$heading" ]]; then
  echo "0.0.0"
  exit 0
fi

if [[ ! "$heading" =~ ^##\ \[([0-9]+\.[0-9]+\.[0-9]+)\]\ -\ ([0-9]{4}-[0-9]{2}-[0-9]{2})$ ]]; then
  echo "error: malformed version heading in $changelog: '$heading'" >&2
  echo "expected: ## [X.Y.Z] - YYYY-MM-DD" >&2
  exit 1
fi

version="${BASH_REMATCH[1]}"
date="${BASH_REMATCH[2]}"

# Round-trip the date so impossible dates like 2026-13-45 fail.
if [[ "$(date -j -f %Y-%m-%d "$date" +%Y-%m-%d 2>/dev/null)" != "$date" ]]; then
  echo "error: invalid date in $changelog: '$heading'" >&2
  exit 1
fi

echo "$version"
