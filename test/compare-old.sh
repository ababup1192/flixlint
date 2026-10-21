#!/usr/bin/env bash
# Compares the relations the engine builds from the generic AST (Flixlint.Rel, written with FLIXLINT_DUMP_REL) with the
# old fact tables the shim writes, table by table, as sets of rows (design 3, v0.8).
#
#   test/compare-old.sh PROJECT STAGE BUILD_DIR [-- FLIXLINT_ARGS...]
#
# SRCS is the source directories (src by default). Prints, per table, how many rows only the old table has and how many
# only the new one has (the rows are in BUILD_DIR/diff/<table>.txt), and the old tables Rel does not build yet.
# Exit 0 when every table Rel builds has the old table's rows, 1 when one differs.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
project="$(cd "$1" && pwd)"; stage="$2"; mkdir -p "$3"; build="$(cd "$3" && pwd)"
shift 3 2>/dev/null || shift $#
[ "${1:-}" = "--" ] && shift

# a rule set that names nothing, so that it compiles against any project
mkdir -p "$build/rules"
printf 'mod CompareOld {\n    pub def rules(): Flixlint.RuleSet = Flixlint.ruleSet(Nil)\n}\n' > "$build/rules/rules.flix"
rm -rf "$build/rel" "$build/diff"; mkdir -p "$build/diff"
set +e
(cd "$project" && FLIXLINT_RESIDENT= FLIXLINT_DUMP_REL="$build/rel" "$here/bin/flixlint" --rules "$build/rules/rules.flix" --stage "$stage" \
    --build-dir "$build/run" "$@" ${SRCS:-src}) > "$build/run.out" 2> "$build/run.err"
code=$?
set -e
[ "$code" -le 1 ] || { echo "compare-old: the run ended with exit $code" >&2; cat "$build/run.err" >&2; exit 2; }

failed=0
for old in "$build/run/facts"/*.tsv; do
    t="$(basename "$old" .tsv)"
    case "$t" in names) continue ;; esac
    new="$build/rel/$t.tsv"
    if [ ! -f "$new" ]; then echo "$t: not built"; continue; fi
    only_old="$(comm -23 <(sort -u "$old") <(sort -u "$new") | tee "$build/diff/$t.txt" | wc -l | tr -d ' ')"
    only_new="$(comm -13 <(sort -u "$old") <(sort -u "$new") | sed 's/^/+ /' | tee -a "$build/diff/$t.txt" | wc -l | tr -d ' ')"
    if [ "$only_old" = 0 ] && [ "$only_new" = 0 ]; then echo "$t: same ($(sort -u "$new" | wc -l | tr -d ' ') rows)"
    else echo "$t: $only_old only old, $only_new only new"; failed=1; fi
done
exit "$failed"
