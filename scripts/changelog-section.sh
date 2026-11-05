#!/bin/bash
# Prints the body of one version's section in a changelog, for use as release notes.
# Usage: scripts/changelog-section.sh X.Y.Z [CHANGELOG.md]
set -euo pipefail

version="$1"
changelog="${2:-CHANGELOG.md}"

section=$(awk -v heading="## [$version]" '
  index($0, heading) == 1 { found = 1; next }
  found && (/^## / || /^\[[^]]+\]: /) { exit }
  found { print }
' "$changelog")

# Trim leading and trailing blank lines.
section=$(printf '%s\n' "$section" | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}')

if [[ -z "$section" ]]; then
  echo "error: no section for version $version in $changelog" >&2
  exit 1
fi

printf '%s\n' "$section"
