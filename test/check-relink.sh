#!/usr/bin/env bash
# The resident check after a dependency's package is built again and linked in under the same path gives the verdict
# `flix check` gives (Resident.depsStamp): the project calls `Lib.b`, which only the second build of the package has.
# The package file lib/github/test/lib/0.1.0/lib-0.1.0.fpkg is a link, pointed first at the build without `b`, then
# at the build with it (packages.lock removed, as a workspace that builds its own dependency does). Before the fix the
# server kept the compiler made for the first build and the second check failed with "Undefined name 'Lib.b'".
#
#   test/check-relink.sh BUILD_DIR
#
# Exit 0 when the first check fails and the second passes on the resident server; the last line says what each answered.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$1"; build="$(cd "$1" && pwd)"
FLIX_JAR="${FLIX_JAR:-$("$here/bin/flix-jar")}"; export FLIX_JAR
r="$build/relink"
rm -rf "$r"; mkdir -p "$r/lib-src/src" "$r/store/1" "$r/store/2" "$r/app/src"
printf '[package]\nversion = "0.1.0"\nflix = "0.80.0"\nrepository = "github:test/lib"\n' > "$r/lib-src/flix.toml"
pkg() { # the n-th build of the package, with the defs given
    printf 'pub mod Lib {\n%s}\n' "$2" > "$r/lib-src/src/Lib.flix"
    (cd "$r/lib-src" && rm -rf artifact && java -jar "$FLIX_JAR" build-pkg > "$build/relink-pkg.out" 2>&1) || { cat "$build/relink-pkg.out"; exit 1; }
    cp "$r/lib-src/artifact/"*.fpkg "$r/store/$1/package.fpkg"
    cp "$r/lib-src/flix.toml" "$r/store/$1/flix.toml"
}
pkg 1 '    pub def a(): Int32 = 1
'
pkg 2 '    pub def a(): Int32 = 1
    pub def b(): Int32 = 2
'
printf '[package]\nversion = "0.1.0"\nflix = "0.80.0"\n\n[dependencies]\n"github:test/lib" = { version = "0.1.0", mount = "lib" }\n' > "$r/app/flix.toml"
printf 'mod App {\n    use lib::Lib\n    pub def go(): Int32 = Lib.b()\n}\n' > "$r/app/src/App.flix"
dir="$r/app/lib/github/test/lib/0.1.0"
mkdir -p "$dir"
link() { rm -f "$r/app/packages.lock"; ln -sfn "$r/store/$1/package.fpkg" "$dir/lib-0.1.0.fpkg"; ln -sfn "$r/store/$1/flix.toml" "$dir/lib-0.1.0.toml"; }
check() { (cd "$r/app" && "$here/bin/flixlint" --check > "$build/relink.out" 2> "$build/relink.err"); echo $?; }
link 1
first="$(check)"
link 2
second="$(check)"
(cd "$r/app" && "$here/bin/flixlint" --resident-stop > /dev/null 2>&1)
echo "first build $first, after the second build was linked in $second"
if [ "$first" = 0 ] || [ "$second" != 0 ]; then
    grep -m1 ">>" "$build/relink.out"
    exit 1
fi
