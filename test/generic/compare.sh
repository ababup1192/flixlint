#!/usr/bin/env bash
# Runs a project's custom rules twice, as written on the old facts and as written on the generic AST, and compares the
# violations (`file:line: id: subject: message`) of the rule ids the generic file declares (design 3, v0.7 condition 1).
#
#   test/generic/compare.sh PROJECT CURRENT_RULES GENERIC_RULES STAGE BUILD_DIR [TODAY] [-- FLIXLINT_ARGS...]
#
# The generic rule file declares `pub def rules(ast: Flixlint.Ast.Ast): Flixlint.RuleSet`. It is judged by
# Flixlint.Engine.judgeAll over the facts of the first run, in an engine built from the first run's sources (the same
# Names.flix) with the AST of flixlint.Generic. Exit 0 when the two lists are the same, 1 with their diff when not.
# SRCS is the source directories (src by default; "src test" for a project whose tests are linted too).
# FLIX_JAR and FLIXLINT_SHIM as for bin/flixlint (the shim jar is build/flixlint-shim.jar when FLIXLINT_SHIM is unset).
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
project="$(cd "$1" && pwd)"; current="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; generic="$(cd "$(dirname "$3")" && pwd)/$(basename "$3")"
stage="$4"; mkdir -p "$5"; build="$(cd "$5" && pwd)"; today="${6:-2026-09-19}"
shift 6 2>/dev/null || shift $#
[ "${1:-}" = "--" ] && shift
flix_jar="${FLIX_JAR:-$("$here/bin/flix-jar")}"
shim="${FLIXLINT_SHIM:-$here/build/flixlint-shim.jar}"

# 1. the current rules: their report, and the engine sources (Names.flix) and facts they leave in $build/current
# WhyNot: not through a resident server, even under FLIXLINT_RESIDENT=1. The build directory is this script's own, so a
# server started for it would be left running; one run is all the comparison needs.
set +e
(cd "$project" && FLIXLINT_RESIDENT= "$here/bin/flixlint" --rules "$current" --today "$today" --stage "$stage" --build-dir "$build/current" "$@" ${SRCS:-src}) > "$build/current.txt" 2> "$build/current.stderr"
code=$?
set -e
[ "$code" -le 1 ] || { echo "compare: the current rules ended with exit $code" >&2; cat "$build/current.stderr" >&2; exit 2; }

# 2. the generic AST
(cd "$project" && java -cp "$flix_jar:$shim" flixlint.Generic --out "$build/ast" --stage "$stage" "$@" ${SRCS:-src}) 2> "$build/generic.stderr" \
    || { echo "compare: flixlint.Generic failed" >&2; cat "$build/generic.stderr" >&2; exit 2; }

# 3. the generic rules, judged over the same facts
mod="$(grep -m1 -oE '^[[:space:]]*(pub[[:space:]]+)?mod[[:space:]]+[A-Za-z0-9_.]+' "$generic" | awk '{print $NF}')"
rm -rf "$build/harness"; mkdir -p "$build/harness"
cp -R "$build/current/engine/src" "$build/harness/src"
cp "$generic" "$build/harness/src/Rules.flix"
cat > "$build/harness/src/Main.flix" <<FLIX
import java.lang.System

def main(): Unit \\ IO =
    match Flixlint.Ast.load(System.getenv("FLIXLINT_GENERIC")) {
        case Err(e) => println("compare: \${e}")
        case Ok(ast) =>
            let facts = Fs.FileRead.runWithIO(() -> Flixlint.Facts.load(System.getenv("FLIXLINT_FACTS"), ast));
            let (vs, errors) = Flixlint.Engine.judgeAll(facts, System.getenv("FLIXLINT_TODAY"), ${mod}.rules(ast));
            List.forEach(e -> println("compare: \${e}"), errors);
            vs |> List.map(v -> "\${v#file}:\${v#line}: \${v#id}: \${v#subject}: \${v#message}") |> List.forEach(println)
    }
FLIX
printf '[package]\nversion = "0.0.0"\nflix = "0.0.0"\n' > "$build/harness/flix.toml"
(cd "$build/harness" && java -jar "$flix_jar" build-jar --no-install > build.log 2>&1) \
    || { echo "compare: $generic does not compile:" >&2; sed 's/\x1b\[[0-9;]*m//g' "$build/harness/build.log" | grep -E '^>>|^[0-9]+ \|' | head -40 >&2; exit 2; }
FLIXLINT_FACTS="$build/current/facts" FLIXLINT_GENERIC="$build/ast" FLIXLINT_TODAY="$today" \
    java -jar "$build/harness/artifact/harness.jar" | sort > "$build/generic.txt"

# 4. the same rule ids, both ways
ids="$(grep -oE 'id = "[^"]+"' "$generic" | sed 's/id = "\(.*\)"/\1/' | sort -u | paste -sd'|' -)"
grep -E "^[^ ].*: (${ids}): " "$build/current.txt" | sort > "$build/current-ids.txt" || true
if diff "$build/current-ids.txt" "$build/generic.txt" > "$build/diff.txt"; then
    echo "compare: $(wc -l < "$build/generic.txt" | tr -d ' ') violations of ${ids//|/, } are the same at the $stage stage"
else
    echo "compare: the violations differ at the $stage stage (< current / > generic):"; cat "$build/diff.txt"; exit 1
fi
