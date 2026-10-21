#!/usr/bin/env bash
# The output of the resident check against `flix check` (checkd-freshness C-0 (b), C-1): on one small project, 20 ways
# of breaking it (the last one sound) written one after another, each checked by `flix check` in a JVM of its own and
# by the resident server (`bin/flixlint --check`), and the stdout, the stderr and the exit code compared byte for byte.
# Every odd case runs a resolved index (`--spans --stage resolved`) on the same server first, so a check after the
# resolved stage is compared too (§4.2 3).
#
#   test/check-same.sh BUILD_DIR
#
# The last line counts the cases whose output is the same; exit 0 when all 20 are.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$1"; build="$(cd "$1" && pwd)"
FLIX_JAR="${FLIX_JAR:-$("$here/bin/flix-jar")}"; export FLIX_JAR
p="$build/proj"; rm -rf "$p"; mkdir -p "$p/src" "$p/test"
printf '[package]\nversion = "0.1.0"\nflix = "0.78.0"\n' > "$p/flix.toml"
printf 'def main(): Unit \\ IO = println(A.f(1))\n' > "$p/src/Main.flix"
printf 'mod TestHelp {\n    pub def two(): Int32 = A.f(1)\n}\n' > "$p/test/Help.flix"

# The body of mod A for each case (the module wraps it).
cases=(
    'pub def f(x: Int32): Int32 = x + "s"'
    'pub def f(x: Int32): Int32 = x + y'
    'pub def f(x: Int32): Int32 = x +'
    'pub def f(x: Int32): Int32 = g(x)
    def g(a: Int32, b: Int32): Int32 = a + b'
    'pub def f(x: Int32): Int32 = match Some(x) { case Some(v) => v }'
    'pub def f(x: Int32): Int32 = x
    pub def f(x: Int32): Int32 = x'
    'pub def f(x: Int33): Int32 = 1'
    'pub def f(x: Int32): Int32 = { let z = 1; x }'
    'pub def f(x: Int32): Int32 = { println(x); x }'
    'pub def f(_x: Int32): Int32 = "s"'
    'enum E { case P case Q }
    pub def f(x: Int32): Int32 = match E.P { case E.P => x }'
    'pub def f(x: Int32): Int32 = Q.f(x)'
    'pub def f(x: Int32): Int32 = x
    def unused(): Int32 = 1'
    'pub def f(x: Int32): Int32 = String.length("${zz}") + x'
    'pub def f(x: Int32): Int32 = { let r = {a = x}; r#b }'
    'pub def f(x: Int32): Int32 = { let x = 1; x }'
    'pub def f(x: Int32): Int32 = if (x > 0) 1 else "s"'
    'pub def f(x: Int32): Int32 = { Foo.bar(); x }'
    'pub def f(x: Int32): Int32 = x
    def g(l: List[Int32, Int32]): Int32 = 0'
    'pub def f(x: Int32): Int32 = x + 1'
)

same=0; n=0
for body in "${cases[@]}"; do
    n=$((n + 1))
    printf 'mod A {\n    %s\n}\n' "$body" > "$p/src/A.flix"
    if [ $((n % 2)) = 1 ]; then
        (cd "$p" && "$here/bin/flixlint" --resident --spans "$build/spans.tsv" --stage resolved src test > /dev/null 2>&1) || true
    fi
    (cd "$p" && java -jar "$FLIX_JAR" check > "$build/cli.out" 2> "$build/cli.err"; echo $? > "$build/cli.exit")
    (cd "$p" && "$here/bin/flixlint" --check > "$build/res.out" 2> "$build/res.err"; echo $? > "$build/res.exit")
    grep -v '^flixlint: starting the resident server' "$build/res.err" > "$build/res.err2" || true
    if cmp -s "$build/cli.exit" "$build/res.exit" && cmp -s "$build/cli.out" "$build/res.out" && cmp -s "$build/cli.err" "$build/res.err2"; then
        same=$((same + 1))
    else
        echo "case $n differs (exit $(cat "$build/cli.exit") / $(cat "$build/res.exit")): kept in $build/case-$n" >&2
        mkdir -p "$build/case-$n"; cp "$build"/cli.* "$build"/res.* "$p/src/A.flix" "$build/case-$n/"
    fi
    echo "case $n: exit $(cat "$build/cli.exit")$([ $((n % 2)) = 1 ] && echo ', after a resolved index')" >> "$build/cases.txt"
done
(cd "$p" && "$here/bin/flixlint" --resident-stop) || true
echo "check-same: $same / $n the same as flix check"
[ $same -eq $n ]
