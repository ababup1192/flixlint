#!/usr/bin/env bash
# Runs flixlint on the fixture project and on examples/, and compares the reports with the expected files:
#   fixture, rules/rules.flix  -> exit 1, test/expected.txt (every family, a path through transitivelyIn, an expired allowUntil, an allow on a custom rule)
#   the same rules with --today before the allowUntil date -> exit 1, test/expected-before-expiry.txt
#   fixture, rules/stale.flix  -> exit 2, test/expected-stale.txt (an allow that matches nothing, on a family and on a custom rule; an allowInFile of a missing file)
#   fixture, rules/broken.flix -> exit 2 (a name the sources do not have: the rules do not compile)
#   a wrong call or environment -> exit 4, so that the 2 above can only mean "the rules are wrong"
#   fixture, rules/clean.flix  -> exit 0
#   examples/rules.flix        -> exit 1, test/expected-examples.txt (the four rules of examples/README.md)
#
#   FLIX_JAR=/path/to/flix.jar test/run.sh   （FLIX_JAR を渡さなければ bin/flix-jar が解決する）
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
FLIX_JAR="${FLIX_JAR:-$("$root/bin/flix-jar")}"
export FLIX_JAR
lint="$root/bin/flixlint"
stage="${FLIXLINT_STAGE:-typed}"

# lint DIR RULES TODAY EXPECTED_EXIT [EXPECTED_FILE]
# WhyNot: --build-dir is not left at its default. It is relative to the current directory, so the facts and the
# generated engine would land inside the project being linted, and test/ is one of the two directories Flix's
# project mode compiles.
lint() {
    local actual code dir stderr
    dir="$1"; shift
    actual="$(mktemp)"
    # WhyNot: stderr is kept, not dropped. A run that fails for a reason of its own (no flix.jar, a JDK the
    # compiler cannot run on, a shim that does not build) then reports nothing on stdout and looks like a
    # report that changed, and the reason is the only thing that says what happened.
    stderr="$(mktemp)"
    set +e
    (cd "$root/$dir" && "$lint" --rules "$1" --today "$2" --stage "$stage" \
        --build-dir "$root/build/$(basename "$dir")" src) > "$actual" 2> "$stderr"
    code=$?
    set -e
    [ "$code" = "$3" ] || { echo "$dir/$1: expected exit $3, got $code" >&2; cat "$actual" "$stderr" >&2; exit 1; }
    if [ $# -ge 4 ] && ! diff "$root/test/$4" "$actual"; then echo "$dir/$1: the report differs from test/$4 (< expected / > actual)" >&2; cat "$stderr" >&2; exit 1; fi
}

lint test/fixture rules/rules.flix 2026-09-19 1 expected.txt
lint test/fixture rules/rules.flix 2025-12-31 1 expected-before-expiry.txt
lint test/fixture rules/stale.flix 2026-09-19 2 expected-stale.txt
lint test/fixture rules/broken.flix 2026-09-19 2
lint test/fixture rules/clean.flix 2026-09-19 0
lint examples rules.flix 2026-09-19 1 expected-examples.txt

# WhyNot: 呼び方と環境の誤りを exit 2 のままにしない。flix.jar が無くても shim が組めなくても --rules の
# パスが違っても broken.flix の行が緑になり、「規則が壊れている事」を確かめたつもりの検査が何も確かめない。
expect4() {
    local code
    set +e
    (cd "$root/test/fixture" && "$@") >/dev/null 2>&1
    code=$?
    set -e
    [ "$code" = 4 ] || { echo "expected exit 4, got $code: $*" >&2; exit 1; }
}
expect4 env FLIX_JAR=/nonexistent/flix.jar "$lint" --rules rules/clean.flix src
expect4 "$lint" --rules rules/clean.flix --stage bogus src
expect4 "$lint" --rules rules/does-not-exist.flix src
expect4 "$lint" --rules rules/clean.flix --nonsense src

echo "flixlint test: ok ($(grep -c ': .*: .*: ' "$root/test/expected.txt") violations on the fixture, $(grep -c ': .*: .*: ' "$root/test/expected-examples.txt") on examples)"
