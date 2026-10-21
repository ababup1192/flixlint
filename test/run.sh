#!/usr/bin/env bash
# Runs flixlint on the fixture project and on examples/, and compares the reports with the expected files:
#   fixture, rules/rules.flix  -> exit 1, test/expected.txt (every family, a path through transitivelyIn, an expired allowUntil, an allow on a custom rule)
#   the same rules with --today before the allowUntil date -> exit 1, test/expected-before-expiry.txt
#   fixture, rules/stale.flix  -> exit 2, test/expected-stale.txt (an allow that matches nothing, on a family and on a custom rule; an allowInFile of a missing file)
#   fixture, rules/broken.flix -> exit 2 (a name the sources do not have: the rules do not compile)
#   a wrong call or environment -> exit 4, so that the 2 above can only mean "the rules are wrong"
#   fixture, rules/clean.flix  -> exit 0
#   fixture, rules/deep.flix   -> exit 1, test/expected-deep.txt (a custom rule on the Deep type relations, parsed only when read)
#   fixture, rules/rules.flix --limits limits/*.json -> the ratchet: exit 0 at the count, 1 over or under it, 2 for a limit of no rule
#   examples/rules.flix        -> exit 1, test/expected-examples.txt (the four rules of examples/README.md)
#   test/spans, --spans alone  -> exit 0, test/expected-spans-<stage>.txt (the name index: every kind, a receiver known by each way)
#   test/fixture, flixlint.Generic -> the kind number of every node names the same kind in the shim and in AstKinds.flix
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
    (cd "$root/$dir" && "$lint" --rules "$1" --today "$2" --stage "$stage" ${LIMITS:+--limits "$LIMITS"} ${BASE:+--limits-base "$BASE"} \
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
lint test/fixture rules/deep.flix 2026-09-19 1 expected-deep.txt
lint examples rules.flix 2026-09-19 1 expected-examples.txt

# The ratchet: the same rules judged by count against limits/*.json (at the count: silent; over: listed; under:
# lower the limit; a limit for no rule: the rules are wrong).
LIMITS=limits/at.json lint test/fixture rules/rules.flix 2026-09-19 0 expected-ratchet-at.txt
LIMITS=limits/over.json lint test/fixture rules/rules.flix 2026-09-19 1 expected-ratchet-over.txt
LIMITS=limits/lower.json lint test/fixture rules/rules.flix 2026-09-19 1 expected-ratchet-lower.txt
LIMITS=limits/stale.json lint test/fixture rules/rules.flix 2026-09-19 2 expected-ratchet-stale.txt
# Against the base the work goes into (--limits-base): a limit that went up fails unless it gives a raiseReason, and a
# raiseReason on a limit that did not go up fails too.
LIMITS=limits/at.json BASE=limits/base-lower.json lint test/fixture rules/rules.flix 2026-09-19 1 expected-ratchet-raised.txt
LIMITS=limits/raised-ok.json BASE=limits/base-lower.json lint test/fixture rules/rules.flix 2026-09-19 0 expected-ratchet-at.txt
LIMITS=limits/raised-ok.json BASE=limits/at.json lint test/fixture rules/rules.flix 2026-09-19 1 expected-ratchet-stale-reason.txt
# A raiseReason the base has too came with a raise already merged: it passes, with a hint once the limit is under the base.
LIMITS=limits/raised-ok.json BASE=limits/raised-ok.json lint test/fixture rules/rules.flix 2026-09-19 0 expected-ratchet-at.txt
LIMITS=limits/raised-ok.json BASE=limits/base-raised5.json lint test/fixture rules/rules.flix 2026-09-19 0 expected-ratchet-inherited.txt
# A limit the base does not have (a forbidden rule added back, or a new rule with violations) needs a raiseReason too.
LIMITS=limits/at.json BASE=limits/base-forbidden.json lint test/fixture rules/rules.flix 2026-09-19 1 expected-ratchet-readded.txt
LIMITS=limits/raised-ok.json BASE=limits/base-forbidden.json lint test/fixture rules/rules.flix 2026-09-19 0 expected-ratchet-at.txt

# The name index (--spans) alone, without rules: exit 0 and every occurrence where test/expected-spans-<stage>.txt says.
# WhyNot: the two stages are not compared with each other here. Each run is one stage; the expected files differ only by
# the typed stage's label-* rows and scrut=, which a reader can check with a diff of the two files.
spans_out="$root/build/spans/spans-$stage.tsv"
mkdir -p "$root/build/spans"
set +e
(cd "$root/test/spans" && "$lint" --spans "$spans_out" --stage "$stage" --build-dir "$root/build/spans" src) > /dev/null 2> "$root/build/spans.stderr"
code=$?
set -e
[ "$code" = 0 ] || { echo "test/spans: expected exit 0, got $code" >&2; cat "$root/build/spans.stderr" >&2; exit 1; }
diff "$root/test/expected-spans-$stage.txt" "$spans_out" || { echo "test/spans: the index differs from test/expected-spans-$stage.txt (< expected / > actual)" >&2; exit 1; }

# The generic AST on the fixture: every node's kind number names the same kind in the shim and in the checked-in
# AstKinds.flix, and columns of another schema are refused. The shim jar is the one the runs above built.
gen="$root/build/generic"
rm -rf "$gen"; mkdir -p "$gen/engine/src/Flixlint"
(cd "$root/test/fixture" && java -cp "$FLIX_JAR:$root/build/flixlint-shim.jar" flixlint.Generic --out "$gen/columns" --stage "$stage" src) 2> "$gen/shim.stderr" \
    || { echo "test/fixture: flixlint.Generic failed" >&2; cat "$gen/shim.stderr" >&2; exit 1; }
cp "$root/src/Flixlint/Ast.flix" "$root/src/Flixlint/AstKinds.flix" "$gen/engine/src/Flixlint/"
cp "$root/test/generic/Main.flix" "$gen/engine/src/"
echo 'mod Flixlint { }' > "$gen/engine/src/Flixlint.flix"
printf '[package]\nversion = "0.0.0"\nflix = "0.0.0"\n' > "$gen/engine/flix.toml"
(cd "$gen/engine" && java -jar "$FLIX_JAR" build-jar --no-install > build.log 2>&1) \
    || { echo "test/generic: the check does not compile (src/Flixlint/Ast.flix, AstKinds.flix, test/generic/Main.flix)" >&2; tail -40 "$gen/engine/build.log" >&2; exit 1; }
generic="$(FLIXLINT_GENERIC="$gen/columns" java -jar "$gen/engine/artifact/engine.jar")"
case "$generic" in "generic: ok "*) ;; *) echo "test/generic: the kind numbers differ" >&2; echo "$generic" >&2; exit 1 ;; esac
cp -R "$gen/columns" "$gen/other-schema"; echo 0000000000000000 > "$gen/other-schema/schema_hash.txt"
case "$(FLIXLINT_GENERIC="$gen/other-schema" java -jar "$gen/engine/artifact/engine.jar")" in
    *"ast_schema 0000000000000000"*) ;;
    *) echo "test/generic: columns of another ast_schema were not refused" >&2; exit 1 ;;
esac

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
expect4 "$lint" --rules rules/clean.flix --limits limits/does-not-exist.json src
expect4 "$lint" --rules rules/clean.flix --limits-base limits/at.json src
# A --pkg path one segment too deep would read owner and name off by one: it is refused, not misread.
expect4 "$lint" --rules rules/clean.flix --pkg lib/github/extra/owner/name/1.0.0/name-1.0.0.fpkg src

echo "flixlint test: ok ($(grep -c ': .*: .*: ' "$root/test/expected.txt") violations on the fixture, $(grep -c ': .*: .*: ' "$root/test/expected-examples.txt") on examples; ${generic#generic: ok })"
