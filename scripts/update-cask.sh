#!/bin/bash
# Sets the version and sha256 in a Homebrew cask file.
# Usage: scripts/update-cask.sh path/to/Casks/tannlaus.rb X.Y.Z SHA256
set -euo pipefail

cask="$1"
version="$2"
sha256="$3"

if [[ ! -f "$cask" ]]; then
  echo "error: $cask not found; create the cask in the tap first" >&2
  exit 1
fi

sed -i '' -E \
  -e "s/^(  version )\"[^\"]*\"/\1\"$version\"/" \
  -e "s/^(  sha256 )\"[^\"]*\"/\1\"$sha256\"/" \
  "$cask"

grep -q "version \"$version\"" "$cask" && grep -q "sha256 \"$sha256\"" "$cask" || {
  echo "error: could not update version and sha256 in $cask" >&2
  exit 1
}
