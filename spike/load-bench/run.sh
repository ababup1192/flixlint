#!/usr/bin/env bash
# Measures how long Flixlint.Ast.load takes on a project's columns (design 3, step 1).
#
#   spike/load-bench/run.sh PROJECT_ROOT [typed|resolved] [RUNS]
#
# Writes the columns once with flixlint.Generic (SRC is PROJECT_ROOT/src), builds a small jar of src/Flixlint/Ast.flix
# and Main.flix, and runs it RUNS times (5 by default), each in a fresh JVM. The jar and the columns are under
# build/load-bench. FLIX_JAR picks the compiler, as for bin/flixlint.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
project="$(cd "$1" && pwd)"
stage="${2:-typed}"
runs="${3:-5}"
flix_jar="${FLIX_JAR:-$("$here/bin/flix-jar")}"
out="$here/build/load-bench"
shim="$here/build/flixlint-shim.jar"

if [ ! -f "$shim" ] || [ -n "$(find "$here/shim" -newer "$shim" -name '*.scala')" ]; then
    (cd "$here" && devbox run -- scala-cli --power package shim --jar "$flix_jar" --library -o "$shim" -f >/dev/null)
fi

(cd "$project" && java -cp "$flix_jar:$shim" flixlint.Generic --out "$out/columns-$stage" --stage "$stage" --project-root "$project" src)
ls -l "$out/columns-$stage" >&2

rm -rf "$out/engine"; mkdir -p "$out/engine/src/Flixlint"
cp "$here/src/Flixlint/Ast.flix" "$here/src/Flixlint/AstKinds.flix" "$out/engine/src/Flixlint/"
cp "$here/spike/load-bench/Main.flix" "$here/spike/load-bench/Flixlint.flix" "$out/engine/src/"
printf '[package]\nversion = "0.0.0"\nflix = "0.0.0"\n' > "$out/engine/flix.toml"
(cd "$out/engine" && java -jar "$flix_jar" build-jar --no-install >build.log 2>&1) || { cat "$out/engine/build.log" >&2; exit 2; }

for _ in $(seq "$runs"); do
    FLIXLINT_GENERIC="$out/columns-$stage" java -jar "$out/engine/artifact/engine.jar"
done
