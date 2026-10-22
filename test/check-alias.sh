#!/usr/bin/env bash
# The resident check after a type alias changes gives the verdict `flix check` gives (Resident.give): a record alias
# gains a field in A, B takes the alias only in a signature, C calls B with A's value. B and C are not written. Before
# the fix the second check failed in C with "Extra label 'y'" where `flix check` passed.
#
#   test/check-alias.sh BUILD_DIR
#
# Exit 0 when both checks pass on the resident server; the last line says what each check answered.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$1"; build="$(cd "$1" && pwd)"
FLIX_JAR="${FLIX_JAR:-$("$here/bin/flix-jar")}"; export FLIX_JAR
p="$build/alias"
rm -rf "$p"; mkdir -p "$p/src"
printf '[package]\nversion = "0.1.0"\nflix = "0.78.0"\n' > "$p/flix.toml"
printf 'mod A {\n    pub type alias Res = { x = Int32 }\n    pub def make(): Res = { x = 1 }\n}\n' > "$p/src/A.flix"
printf 'mod B {\n    use A.Res\n    pub def use1(r: Res): Int32 = r#x\n}\n' > "$p/src/B.flix"
printf 'mod C {\n    pub def go(): Int32 = B.use1(A.make())\n}\n' > "$p/src/C.flix"
check() { (cd "$p" && "$here/bin/flixlint" --check > "$build/alias.out" 2> "$build/alias.err"); echo $?; }
first="$(check)"
printf 'mod A {\n    pub type alias Res = {\n        x = Int32,\n        y = Int32\n    }\n    pub def make(): Res = { x = 1, y = 2 }\n}\n' > "$p/src/A.flix"
second="$(check)"
(cd "$p" && "$here/bin/flixlint" --resident-stop > /dev/null 2>&1)
echo "first $first, after the alias gained a field $second"
if [ "$first" != 0 ] || [ "$second" != 0 ]; then
    grep -m1 ">>" "$build/alias.out"
    exit 1
fi
