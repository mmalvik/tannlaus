#!/bin/bash
# Tests the changelog scripts against the fixtures in Tests/fixtures.
set -uo pipefail
cd "$(dirname "$0")/.."

fixtures=Tests/fixtures
failures=0

expect() {
  local name="$1" expected="$2"; shift 2
  local actual
  if actual=$("$@" 2>/dev/null) && [[ "$actual" == "$expected" ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: expected '$expected', got '$actual'"
    failures=$((failures + 1))
  fi
}

expect_failure() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "FAIL $name: expected failure"
    failures=$((failures + 1))
  else
    echo "ok   $name"
  fi
}

expect "version: only unreleased" "0.0.0" scripts/version.sh $fixtures/unreleased.md
expect "version: newest release" "1.2.3" scripts/version.sh $fixtures/released.md
expect "version: without unreleased" "0.1.0" scripts/version.sh $fixtures/last-section.md
expect_failure "version: malformed version" scripts/version.sh $fixtures/malformed-version.md
expect_failure "version: malformed separator" scripts/version.sh $fixtures/malformed-separator.md
expect_failure "version: invalid date" scripts/version.sh $fixtures/invalid-date.md
expect_failure "version: missing changelog" scripts/version.sh $fixtures/missing.md
# Compared with the first released heading, found here independently of version.sh.
newest_heading=$(grep -m 1 -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' CHANGELOG.md | tr -d '#[] ' || true)
expect "version: repository changelog" "${newest_heading:-0.0.0}" scripts/version.sh CHANGELOG.md

expect "section: middle" "$(printf '### Fixed\n\n- Bluetooth comes back after wake.')" \
  scripts/changelog-section.sh 1.2.3 $fixtures/released.md
expect "section: last before links" "$(printf '### Added\n\n- First release.')" \
  scripts/changelog-section.sh 0.1.0 $fixtures/last-section.md
expect_failure "section: missing version" scripts/changelog-section.sh 9.9.9 $fixtures/released.md

cask=$(mktemp)
printf 'cask "tannlaus" do\n  version "0.1.0"\n  sha256 "old"\nend\n' > "$cask"
expect "cask: update" "$(printf 'cask "tannlaus" do\n  version "1.2.3"\n  sha256 "abc123"\nend')" \
  bash -c "scripts/update-cask.sh '$cask' 1.2.3 abc123 && cat '$cask'"
rm -f "$cask"

if (( failures > 0 )); then
  echo "$failures script test(s) failed"
  exit 1
fi
