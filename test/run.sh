#!/usr/bin/env bash
# Runs flixlint on the fixture project and on examples/, and compares the reports with the expected files:
#   fixture, rules/rules.flix  -> exit 1, test/expected.txt (every family, a path through transitivelyIn, an expired allowUntil, an allow on a custom rule)
#   the same rules with --today before the allowUntil date -> exit 1, test/expected-before-expiry.txt
#   fixture, rules/stale.flix  -> exit 2, test/expected-stale.txt (an allow that matches nothing, on a family and on a custom rule; an allowInFile of a missing file)
#   fixture, rules/broken.flix -> exit 2 (a name the sources do not have: the rules do not compile)
#   a wrong call or environment -> exit 4, so that the 2 above can only mean "the rules are wrong"
#   fixture, rules/clean.flix  -> exit 0
#   fixture, rules/deep.flix   -> exit 1, test/expected-deep.txt (a custom rule on the Deep type relations, parsed only when read)
#   fixture, rules/uses.flix   -> exit 1, test/expected-uses.txt (a `use` its module never uses, on the generic AST; the same at both stages)
#   fixture, rules/nextcms.flix -> exit 1, test/expected-nextcms.txt (the shapes nextcms writes the families in; the same at both stages)
#   fixture, rules/rules.flix --limits limits/*.json -> the ratchet: exit 0 at the count (the violations held: a line on
#                                 stderr and build/fixture/held.txt; --held lists them), 1 over or under it, 2 for a limit of no rule
#   examples/rules.flix        -> exit 1, test/expected-examples.txt (the four rules of examples/README.md)
#   test/spans, --spans alone  -> exit 0, test/expected-spans-<stage>.txt (the name index: every kind, a receiver known by each way)
#   test/fixture, flixlint.Generic -> the kind number of every node names the same kind in the shim and in AstKinds.flix;
#                                     rules/generic.flix reports what rules.flix reports (test/generic/compare.sh)
#   test/generic/limit, flixlint.Generic -> inside the size limit; exit 4 with --node-ratio 2
#   fixture, rules/notice.flix with the generic AST -> exit 0, the notes of test/expected-notices-<stage>.txt on stderr
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
        --build-dir "$root/build/${BUILD:-$(basename "$dir")}" src) > "$actual" 2> "$stderr"
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
lint test/fixture rules/uses.flix 2026-09-19 1 expected-uses.txt
lint test/fixture rules/nextcms.flix 2026-09-19 1 expected-nextcms.txt
lint examples rules.flix 2026-09-19 1 expected-examples.txt

# The ratchet: the same rules judged by count against limits/*.json (at the count: silent; over: listed; under:
# lower the limit; a limit for no rule: the rules are wrong).
LIMITS=limits/at.json lint test/fixture rules/rules.flix 2026-09-19 0 expected-ratchet-at.txt
# At the limit the violations are held: not on stdout, counted by rule in one line on stderr, all of them in held.txt
# beside the facts; --held lists them on stdout too.
held_out="$root/build/held"; mkdir -p "$held_out"
want_held="$(grep -c ': .*: .*: ' "$root/test/expected.txt")"
[ "$(grep -c ': .*: .*: ' "$root/build/fixture/held.txt")" = "$want_held" ] \
    || { echo "test/fixture: build/fixture/held.txt does not hold the $want_held violations at their limits" >&2; exit 1; }
set +e
(cd "$root/test/fixture" && "$lint" --rules rules/rules.flix --today 2026-09-19 --stage "$stage" --limits limits/at.json --held \
    --build-dir "$root/build/fixture" src) > "$held_out/out.txt" 2> "$held_out/err.txt"
code=$?
set -e
[ "$code" = 0 ] && grep -q "^flixlint: ratchet: $want_held violations within their limits (domain-isolation 6, flat-rules 6, clock 4, wrapped-key 4, silent-parse 3, ...); all of them in .*/build/fixture/held.txt, or --held to list them\$" "$held_out/err.txt" \
    && [ "$(grep -c ': .*: .*: ' "$held_out/out.txt")" = "$want_held" ] \
    || { echo "test/fixture: --held: expected exit 0, the held line on stderr and $want_held violations on stdout, got $code" >&2; cat "$held_out/err.txt" >&2; exit 1; }
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
# A directory of one file per rule (limits-dir/*/<rule id>.json) instead of one limits file: the messages name the rule's file.
LIMITS=limits-dir/at lint test/fixture rules/rules.flix 2026-09-19 0 expected-ratchet-at.txt
LIMITS=limits-dir/lower lint test/fixture rules/rules.flix 2026-09-19 1 expected-ratchet-dir-lower.txt
LIMITS=limits-dir/at BASE=limits-dir/base-lower lint test/fixture rules/rules.flix 2026-09-19 1 expected-ratchet-dir-raised.txt
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
# AstKinds.flix; relations of another schema are refused; the custom rules written on it (rules/generic.flix) report
# what rules.flix reports; and the size limit stops a walk that grows past it. The shim jar is the one the runs above built.
gen="$root/build/generic"
shim_jar="${FLIXLINT_SHIM:-$root/build/flixlint-shim.jar}"
rm -rf "$gen"; mkdir -p "$gen/engine/src/Flixlint"
(cd "$root/test/fixture" && java -cp "$FLIX_JAR:$shim_jar" flixlint.Generic --out "$gen/ast" --stage "$stage" src) 2> "$gen/shim.stderr" \
    || { echo "test/fixture: flixlint.Generic failed" >&2; cat "$gen/shim.stderr" >&2; exit 1; }
cp "$root/src/Flixlint/Ast.flix" "$root/src/Flixlint/AstKinds.flix" "$gen/engine/src/Flixlint/"
cp "$root/test/generic/Main.flix" "$gen/engine/src/"
echo 'mod Flixlint { }' > "$gen/engine/src/Flixlint.flix"
printf '[package]\nversion = "0.0.0"\nflix = "0.0.0"\n' > "$gen/engine/flix.toml"
(cd "$gen/engine" && java -jar "$FLIX_JAR" build-jar --no-install > build.log 2>&1) \
    || { echo "test/generic: the check does not compile (src/Flixlint/Ast.flix, AstKinds.flix, test/generic/Main.flix)" >&2; tail -40 "$gen/engine/build.log" >&2; exit 1; }
generic="$(FLIXLINT_GENERIC="$gen/ast" java -jar "$gen/engine/artifact/engine.jar")"
case "$generic" in "generic: ok "*) ;; *) echo "test/generic: the kind numbers differ" >&2; echo "$generic" >&2; exit 1 ;; esac
cp -R "$gen/ast" "$gen/other-schema"; sed -i.bak 's/^schemaHash=.*/schemaHash=0000000000000000/' "$gen/other-schema/meta.txt"
case "$(FLIXLINT_GENERIC="$gen/other-schema" java -jar "$gen/engine/artifact/engine.jar")" in
    *"ast_schema 0000000000000000"*) ;;
    *) echo "test/generic: relations of another ast_schema were not refused" >&2; exit 1 ;;
esac
FLIXLINT_SHIM="$shim_jar" "$root/test/generic/compare.sh" "$root/test/fixture" "$root/test/fixture/rules/rules.flix" "$root/test/fixture/rules/generic.flix" "$stage" "$gen/compare" > "$gen/compare.txt" 2>&1 \
    || { echo "test/generic: the rules written on the generic AST report differently" >&2; cat "$gen/compare.txt" >&2; exit 1; }
# A record alias of 40 fields used in 100 signatures is one shared type: the walk stays well inside the limit, and a
# limit of 2 nodes per source line stops it with exit 4 and the declaration that grew most.
(cd "$root/test/generic/limit" && java -cp "$FLIX_JAR:$shim_jar" flixlint.Generic --out "$gen/limit" --stage "$stage" src) 2> "$gen/limit.stderr" \
    || { echo "test/generic/limit: the walk did not fit its limit" >&2; cat "$gen/limit.stderr" >&2; exit 1; }
set +e
(cd "$root/test/generic/limit" && java -cp "$FLIX_JAR:$shim_jar" flixlint.Generic --out "$gen/limit-low" --node-ratio 2 --stage "$stage" src) 2> "$gen/limit-low.stderr"
code=$?
set -e
[ "$code" = 4 ] && grep -q 'grew past its limit.*The declaration with the most nodes is' "$gen/limit-low.stderr" \
    || { echo "test/generic/limit: --node-ratio 2 should stop with exit 4 and name the declaration, got exit $code" >&2; cat "$gen/limit-low.stderr" >&2; exit 1; }

# What a rule file names that the stage lacks (design 1.5): a plain run writes the generic AST beside the facts with the
# rule file's names, and the engine says each name this stage does not have, these sources never have, and each
# `Unnamed(`, on stderr, with the exit code of the rules alone (0). FLIXLINT_TIMING=1 also times each custom rule.
notice="$gen/notice"
mkdir -p "$notice"
set +e
(cd "$root/test/fixture" && FLIXLINT_RESIDENT= FLIXLINT_TIMING=1 "$lint" --rules rules/notice.flix --stage "$stage" --build-dir "$notice" src) > "$notice/out.txt" 2> "$notice/err.txt"
code=$?
set -e
[ "$code" = 0 ] || { echo "test/fixture: rules/notice.flix: expected exit 0, got $code" >&2; cat "$notice/out.txt" "$notice/err.txt" >&2; exit 1; }
grep '^flixlint: note:' "$notice/err.txt" | diff "$root/test/expected-notices-$stage.txt" - \
    || { echo "test/fixture: the notes differ from test/expected-notices-$stage.txt (< expected / > actual)" >&2; exit 1; }
for id in binders spawns by-string; do
    grep -q "^flixlint timing: judge ${id}=" "$notice/err.txt" || { echo "test/fixture: FLIXLINT_TIMING=1 did not time the rule ${id}" >&2; cat "$notice/err.txt" >&2; exit 1; }
done

# WhyNot: 呼び方と環境の誤りを exit 2 のままにしない。flix.jar が無くても shim が組めなくても --rules の
# パスが違っても broken.flix の行が緑になり、「規則が壊れている事」を確かめたつもりの検査が何も確かめない。
expect4() {
    local code
    set +e
    # No resident server for these: each would be one more server for the default build directory.
    (cd "$root/test/fixture" && FLIXLINT_RESIDENT=0 "$@") >/dev/null 2>&1
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

# The resident server's wire (protocol 2) and the name of its socket, against the fixtures every client shares.
shim="${FLIXLINT_SHIM:-$root/build/flixlint-shim.jar}"
java -cp "$FLIX_JAR:$shim" flixlint.Resident fixture "$root/test/resident" || { echo "test/resident: the wire differs from request.hex / reply.hex" >&2; exit 1; }
while IFS="$(printf '\t')" read -r r id want; do
    case "$r" in '#'*|'') continue ;; esac
    got="$("$lint" --socket-name "$r" "$id")"
    [ "$got" = "$want" ] || { echo "test/resident/socket-name.txt: $r: $got, not $want" >&2; exit 1; }
done < "$root/test/resident/socket-name.txt"
# The version of the sources a check answers with (shim/Check.scala, checkd-freshness 3.1): the server and the
# shell reference give the 64 characters test/resident/version/expected.txt has (every client checks against it too).
want="$(cat "$root/test/resident/version/expected.txt")"
for got in "$(java -cp "$FLIX_JAR:$shim" flixlint.Check version "$root/test/resident/version")" "$("$root/test/version-of.sh" "$root/test/resident/version")"; do
    [ "$got" = "$want" ] || { echo "test/resident/version: $got, not $want" >&2; exit 1; }
done

# Under FLIXLINT_RESIDENT=1 (make test-resident) every run above went through a resident server: one per project root,
# whatever the build directory and the stage. Two runs sent at once wait for each other and report as alone.
if [ "${FLIXLINT_RESIDENT:-0}" = 1 ]; then
    lint test/fixture rules/rules.flix 2026-09-19 1 expected.txt &
    first=$!
    # Each with a build directory of its own: two runs on one build directory overwrite each other's engine sources.
    BUILD=fixture-deep lint test/fixture rules/deep.flix 2026-09-19 1 expected-deep.txt &
    second=$!
    wait "$first" || { echo "test/fixture: the first of two runs sent at once failed" >&2; exit 1; }
    wait "$second" || { echo "test/fixture: the second of two runs sent at once failed" >&2; exit 1; }
    for dir in test/fixture examples test/spans; do
        real="$(cd "$root/$dir" && pwd -P)"
        n="$(ps -Ao args= | grep -F "flixlint.Resident server" | grep -cF -- "--root $real --identity" || true)"
        [ "$n" = 1 ] || { echo "$dir: $n resident servers, not 1" >&2; exit 1; }
        (cd "$root/$dir" && "$lint" --resident-stop)
    done
fi


# The check of the resident server (shim/Check.scala): on test/check/<case>, the same stdout, stderr and exit code as
# `flix check` in a JVM of its own, on the server's first run and on the next (a warm compiler), and the version of the
# sources test/version-of.sh gives. The server is stopped after each case.
for case in broken clean; do
    dir="$root/test/check/$case"; out="$root/build/check-$case"; mkdir -p "$out"
    (cd "$dir" && c=0 && { java -jar "$FLIX_JAR" check > "$out/cli.out" 2> "$out/cli.err" || c=$?; } && echo "$c" > "$out/cli.exit")
    [ "$(cat "$out/cli.exit")" = "$([ $case = clean ] && echo 0 || echo 1)" ] || { echo "test/check/$case: flix check itself ends $(cat "$out/cli.exit")" >&2; exit 1; }
    for n in 1 2; do
        (cd "$dir" && c=0 && { "$lint" --check --version-file "$out/version" > "$out/res.out" 2> "$out/res.err" || c=$?; } && echo "$c" > "$out/res.exit")
        grep -v '^flixlint: starting the resident server' "$out/res.err" > "$out/res.err2" || true
        cmp -s "$out/cli.exit" "$out/res.exit" && cmp -s "$out/cli.out" "$out/res.out" && cmp -s "$out/cli.err" "$out/res.err2" \
            || { echo "test/check/$case: run $n of the server's check differs from flix check (build/check-$case)" >&2; exit 1; }
        [ "$(cat "$out/version")" = "$("$root/test/version-of.sh" "$dir")" ] \
            || { echo "test/check/$case: the version of run $n is not test/version-of.sh's" >&2; exit 1; }
    done
    (cd "$dir" && "$lint" --resident-stop) || true
    rm -rf "$dir/build" "$dir/lib"
done

echo "flixlint test: ok ($(grep -c ': .*: .*: ' "$root/test/expected.txt") violations on the fixture, $(grep -c ': .*: .*: ' "$root/test/expected-examples.txt") on examples; generic AST ${generic#generic: ok }; $(head -1 "$gen/compare.txt" | sed "s/^compare: //; s/ are the same.*//") the same)"
