#!/usr/bin/env bash
# Runs flixlint on the fixture project and compares the report with the expected files:
#   rules/rules.flix  -> exit 1, test/expected.txt (every family, a path through transitivelyIn, an expired allowUntil, an allow on a custom rule)
#   the same rules with --today before the allowUntil date -> exit 1, test/expected-before-expiry.txt
#   rules/stale.flix  -> exit 2, test/expected-stale.txt (an allow that matches nothing, on a family and on a custom rule; an allowInFile of a missing file)
#   rules/broken.flix -> exit 2 (a name the sources do not have: the rules do not compile)
#   rules/clean.flix  -> exit 0
#
#   FLIX_JAR=/path/to/flix.jar test/run.sh   （FLIX_JAR を渡さなければ bin/flix-jar が解決する）
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
FLIX_JAR="${FLIX_JAR:-$("$root/bin/flix-jar")}"
export FLIX_JAR
cd "$root/test/fixture"
lint="$root/bin/flixlint"
stage="${FLIXLINT_STAGE:-typed}"

# lint RULES TODAY EXPECTED_EXIT [EXPECTED_FILE]
lint() {
    local actual code
    actual="$(mktemp)"
    set +e
    "$lint" --rules "$1" --today "$2" --stage "$stage" src > "$actual" 2> /dev/null
    code=$?
    set -e
    [ "$code" = "$3" ] || { echo "$1: expected exit $3, got $code" >&2; cat "$actual" >&2; exit 1; }
    if [ $# -ge 4 ] && ! diff "../$4" "$actual"; then echo "$1: the report differs from test/$4 (< expected / > actual)" >&2; exit 1; fi
}

lint rules/rules.flix 2026-09-19 1 expected.txt
lint rules/rules.flix 2025-12-31 1 expected-before-expiry.txt
lint rules/stale.flix 2026-09-19 2 expected-stale.txt
lint rules/broken.flix 2026-09-19 2
lint rules/clean.flix 2026-09-19 0

echo "flixlint test: ok ($(grep -c ': .*: .*: ' ../expected.txt) violations as expected)"
