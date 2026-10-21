#!/usr/bin/env bash
# Counts stale answers of the resident check (checkd-freshness C-0 (a), C-1): on a small project, breaks and fixes
# sources in many ways, waits a random while, checks on the resident server as a client does (the answer is used only
# when the version it checked is the version on disk now, else asked again, 3 times, then `flix check` on its own),
# and counts the used answers whose verdict is not the one the sources on disk have.
#
#   test/check-fresh.sh BUILD_DIR [RUNS] [MAX_DELAY_MS] [--no-version]
#
# RUNS 200 and MAX_DELAY_MS 3000 by default. --no-version uses every answer without comparing versions: a run of that
# shows the test catches a stale answer (the writes during a check give one) where the version comparison would not.
# The writes: one file to the same size (`x + 1` <-> `x + y`), two files at once, a file added and removed, a file
# renamed, the target of a symlinked source, a write with its modification time put back (`touch -r`), and writes
# every 100 to 200 ms for as long as a check runs. The last line: runs, stale answers, retries, falls back to `flix check`.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$1"; build="$(cd "$1" && pwd)"; runs="${2:-200}"; max_delay="${3:-3000}"; versioned=1
[ "${4:-}" = --no-version ] && versioned=0
FLIX_JAR="${FLIX_JAR:-$("$here/bin/flix-jar")}"; export FLIX_JAR
p="$build/proj"; outside="$build/outside"
rm -rf "$p" "$outside"; mkdir -p "$p/src" "$p/test" "$outside"
printf '[package]\nversion = "0.1.0"\nflix = "0.78.0"\n' > "$p/flix.toml"
printf 'def main(): Unit \\ IO = println(A.f(1) + B.g() + C.h() + L.k())\n' > "$p/src/Main.flix"
a_good='mod A {\n    pub def f(x: Int32): Int32 = x + 1\n}\n'; a_bad='mod A {\n    pub def f(x: Int32): Int32 = x + y\n}\n'
b_good='mod B {\n    pub def g(): Int32 = 2\n}\n'; b_bad='mod B {\n    pub def g(): Int32 = "2"\n}\n'
l_good='mod L {\n    pub def k(): Int32 = 4\n}\n'; l_bad='mod L {\n    pub def k(): Int32 = true\n}\n'
d_bad='mod D {\n    pub def d(): Int32 = 1 + "d"\n}\n'
printf "$a_good" > "$p/src/A.flix"; printf "$b_good" > "$p/src/B.flix"
printf 'mod C {\n    pub def h(): Int32 = 3\n}\n' > "$p/src/C.flix"
printf "$l_good" > "$outside/L.flix"; ln -s "$outside/L.flix" "$p/src/L.flix"
printf 'mod TestHelp {\n    pub def two(): Int32 = A.f(1)\n}\n' > "$p/test/Help.flix"
bad_a=0; bad_b=0; bad_l=0; has_d=0; c_name=C
expected() { [ $((bad_a + bad_b + bad_l + has_d)) -eq 0 ] && echo 0 || echo 1; }

flip_a() { if [ $bad_a = 0 ]; then printf "$a_bad" > "$p/src/A.flix"; bad_a=1; else printf "$a_good" > "$p/src/A.flix"; bad_a=0; fi; }
op() {
    case "$1" in
        0) flip_a ;;
        1) flip_a; if [ $bad_b = 0 ]; then printf "$b_bad" > "$p/src/B.flix"; bad_b=1; else printf "$b_good" > "$p/src/B.flix"; bad_b=0; fi ;;
        2) if [ $has_d = 0 ]; then printf "$d_bad" > "$p/src/D.flix"; has_d=1; else rm -f "$p/src/D.flix"; has_d=0; fi ;;
        3) if [ $c_name = C ]; then mv "$p/src/C.flix" "$p/src/C2.flix"; c_name=C2; else mv "$p/src/C2.flix" "$p/src/C.flix"; c_name=C; fi ;;
        4) if [ $bad_l = 0 ]; then printf "$l_bad" > "$outside/L.flix"; bad_l=1; else printf "$l_good" > "$outside/L.flix"; bad_l=0; fi ;;
        5) touch -r "$p/src/A.flix" "$build/mtime"; flip_a; touch -r "$build/mtime" "$p/src/A.flix" ;;
    esac
}
ms_sleep() { sleep "$(awk -v m="$1" 'BEGIN { printf "%.3f", m / 1000 }')"; }

stale=0; retries=0; fallbacks=0
check_once() { (cd "$p" && "$here/bin/flixlint" --check --version-file "$build/version" > "$build/out" 2> "$build/err"); echo $?; }
for ((i = 1; i <= runs; i++)); do
    kind=$((RANDOM % 7))
    if [ $kind = 6 ]; then
        # the others sound, so that the verdict follows A alone and an answer of A before the last write shows
        printf "$b_good" > "$p/src/B.flix"; printf "$l_good" > "$outside/L.flix"; rm -f "$p/src/D.flix"; bad_b=0; bad_l=0; has_d=0
        # a write while the check runs: the version tells the answer is of the sources before it
        (cd "$p" && "$here/bin/flixlint" --check --version-file "$build/version" > "$build/out" 2> "$build/err"; echo $? > "$build/bg") &
        bg=$!
        op 0; while kill -0 $bg 2> /dev/null; do ms_sleep $((100 + RANDOM % 100)); kill -0 $bg 2> /dev/null && op 0; done; wait
        code="$(cat "$build/bg")"
    else
        op $kind; ms_sleep $((RANDOM % (max_delay + 1)))
        code="$(check_once)"
    fi
    used=""
    for ((try = 0; try <= 3; try++)); do
        if [ $versioned = 0 ] || [ "$(cat "$build/version" 2>/dev/null)" = "$("$here/test/version-of.sh" "$p")" ]; then used="$code"; break; fi
        [ $try = 3 ] && break
        retries=$((retries + 1)); code="$(check_once)"
    done
    if [ -z "$used" ]; then
        fallbacks=$((fallbacks + 1))
        (cd "$p" && java -jar "$FLIX_JAR" check > /dev/null 2>&1); used=$?
    fi
    want="$(expected)"
    if [ "$used" != "$want" ]; then stale=$((stale + 1)); echo "run $i (write $kind): answered $used, the sources on disk give $want" >&2; cp "$build/out" "$build/stale-$i.out"; (cd "$p" && find src test -name '*.flix' | sort) > "$build/stale-$i.files"; fi
done
(cd "$p" && "$here/bin/flixlint" --resident-stop) || true
echo "check-fresh: runs=$runs stale=$stale retries=$retries fallbacks=$fallbacks (max delay ${max_delay} ms, versions $([ $versioned = 1 ] && echo compared || echo not compared))"
[ $stale -eq 0 ]
