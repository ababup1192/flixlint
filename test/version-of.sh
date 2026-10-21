#!/usr/bin/env bash
# The version of a project's sources (shim/Check.scala `version`, checkd-freshness §3.1) with shell tools only: the
# reference the server's and every client's formula are checked against (test/run.sh, test/resident/version).
#
#   test/version-of.sh DIR
#
# The files: the .flix files under DIR/src and DIR/test, and DIR/flix.toml and DIR/packages.lock when there. Each is
# "path relative to DIR with / NUL sha256-hex NUL"; sorted by the path's bytes; the version is the SHA-256 of them all.
set -euo pipefail
cd "$1"
sum() { if command -v sha256sum > /dev/null; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }
{ for d in src test; do [ -d "$d" ] && find "$d" -name '*.flix' -type f; done
  for f in flix.toml packages.lock; do [ -f "$f" ] && echo "$f"; done; } | LC_ALL=C sort |
while IFS= read -r f; do printf '%s\0%s\0' "$f" "$(sum < "$f")"; done | sum
