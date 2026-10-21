#!/usr/bin/env bash
# Where the dependencies come from (Bootstrap, the same as `flix check`): on copies of a project with dependencies, runs
# `flix check` and flixlint the same way and says whether both pass or both stop, case by case.
#
#   test/bootstrap-cases.sh PROJECT BUILD_DIR [LOCAL_FPKG LOCAL_TOML]
#
# PROJECT is a project with Flix and Maven dependencies already installed (its flix.toml, packages.lock, src, test and
# lib are copied; the project itself is not touched). The cases:
#   full-offline  lib/ as it is, the network shut          -> both pass (flixlint also with --offline)
#   no-lib        no lib/ (a fresh worktree), the network   -> both install and pass; flixlint says what it installed
#   no-lib-off    no lib/, flixlint --offline, the network shut for flix -> both stop; flixlint names what it wanted
#   no-maven      lib/ without its Maven jars, the network  -> both install them and pass
#   local-fpkg    LOCAL_FPKG / LOCAL_TOML in place of the first package of packages.lock, the lock's fingerprints set to
#                 them (what `fge use-engine` does), the network shut -> both pass without fetching the package
# "The network shut" is every connection through Java's proxy settings sent to a closed port.
# Exit 0 when every case agrees, 1 when one does not. Needs the network (no-lib, no-maven) and FLIX_JAR (bin/flix-jar).
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
project="$(cd "$1" && pwd)"; mkdir -p "$2"; build="$(cd "$2" && pwd)"
local_fpkg="${3:-}"; local_toml="${4:-}"
flix_jar="${FLIX_JAR:-$("$here/bin/flix-jar")}"
shut="-Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=9 -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=9"
mkdir -p "$build/rules"
printf 'mod BootstrapCases {\n    pub def rules(): Flixlint.RuleSet = Flixlint.ruleSet(Nil)\n}\n' > "$build/rules/rules.flix"

# copy CASE: a fresh copy of the project for one case, without lib/ (the case adds what it needs)
copy() {
    local d="$build/$1"
    rm -rf "$d"; mkdir -p "$d"
    for f in flix.toml packages.lock src test; do [ -e "$project/$f" ] && cp -R "$project/$f" "$d/"; done
    echo "$d"
}

# run CASE NAME JAVA_OPTS CMD...: the command's exit code into $build/CASE.NAME.exit, its output beside it
run() {
    local c="$1" name="$2" opts="$3"; shift 3
    (cd "$build/$c" && JAVA_TOOL_OPTIONS="$opts" "$@") > "$build/$c.$name.out" 2>&1
    echo $? > "$build/$c.$name.exit"
}
flixcheck() { run "$1" check "$2" java -jar "$flix_jar" check; }
flixlint() { local c="$1" name="$2" opts="$3"; shift 3
    run "$c" "$name" "$opts" env FLIXLINT_RESIDENT= "$here/bin/flixlint" --flix-jar "$flix_jar" --rules "$build/rules/rules.flix" \
        --build-dir "$build/$c.$name.build" "$@" src test; }

# pass or stop, from an exit code (flixlint's 0 and 1 are a run that judged; flix check's 0 is a pass)
verdict() { case "$1" in 0) echo pass ;; 1) [ "$2" = lint ] && echo pass || echo stop ;; *) echo stop ;; esac; }

failed=0
# agree CASE EXPECTED NAME...: every run of the case ends EXPECTED
agree() {
    local c="$1" want="$2" line="" ok=1 n e v; shift 2
    for n in "$@"; do
        e="$(cat "$build/$c.$n.exit")"; v="$(verdict "$e" "$([ "$n" = check ] && echo check || echo lint)")"
        line="$line $n=$v($e)"; [ "$v" = "$want" ] || ok=0
    done
    if [ $ok = 1 ]; then echo "$c: all $want:$line"; else echo "$c: DIFFER (want $want):$line"; failed=1; fi
}

c=full-offline; d="$(copy $c)"; cp -R "$project/lib" "$d/"
flixcheck $c "$shut"; flixlint $c lint "$shut"; flixlint $c offline "" --offline
agree $c pass check lint offline

c=no-lib; copy $c > /dev/null
flixcheck $c ""; rm -rf "$build/$c/lib"; flixlint $c lint ""
agree $c pass check lint
grep -h 'flixlint: Flix installed' "$build/$c.lint.out" | sed "s|^|  $c: |"

c=no-lib-off; copy $c > /dev/null
flixcheck $c "$shut"; flixlint $c offline "" --offline
agree $c stop check offline
grep -h 'needed the network' "$build/$c.offline.out" | sed "s|^|  $c: |"

c=no-maven; d="$(copy $c)"; cp -R "$project/lib" "$d/"; rm -rf "$d/lib/cache" "$d/lib/external"
flixcheck $c ""; rm -rf "$d/lib/cache" "$d/lib/external"; flixlint $c lint ""
agree $c pass check lint

if [ -n "$local_fpkg" ]; then
    c=local-fpkg; d="$(copy $c)"; cp -R "$project/lib" "$d/"
    # the first package of the lock: [packages."github:OWNER/NAME"."VERSION"]
    key="$(grep -m1 -oE '^\[packages\."github:[^"]+"\."[^"]+"\]' "$d/packages.lock")"
    owner_name="$(echo "$key" | sed -E 's/.*github:([^"]+)".*/\1/')"; version="$(echo "$key" | sed -E 's/.*"\."([^"]+)"\]/\1/')"
    name="${owner_name#*/}"; dir="$d/lib/github/$owner_name/$version"
    cp "$local_fpkg" "$dir/$name-$version.fpkg"; cp "$local_toml" "$dir/$name-$version.toml"
    fsum="$(shasum -a 256 "$local_fpkg" | cut -d' ' -f1)"; tsum="$(shasum -a 256 "$local_toml" | cut -d' ' -f1)"
    awk -v key="$key" -v f="$fsum" -v t="$tsum" '
        $0 == key { inside = 1; print; next }
        /^\[/ { inside = 0 }
        inside && /^fpkg/ { print "fpkg    = \"sha256:" f "\""; next }
        inside && /^toml/ { print "toml    = \"sha256:" t "\""; next }
        { print }' "$d/packages.lock" > "$d/packages.lock.new" && mv "$d/packages.lock.new" "$d/packages.lock"
    flixcheck $c "$shut"; flixlint $c lint "$shut"
    agree $c pass check lint
    cmp -s "$local_fpkg" "$dir/$name-$version.fpkg" && echo "  $c: the local fpkg is still the one in lib/ after both runs"
fi
exit "$failed"
