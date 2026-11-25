#!/usr/bin/env bash
# check-test-runners.sh — a test's runner that runs the code as a run does
# (`set -eE; trap on_err ERR` in its subshell) only does so when it is called
# outside a condition. Called in one — `run … || fail_`, `if run`, `! run`,
# `[[ "$(run)" == x ]] || …` — bash ignores set -e inside it, subshells and
# $( ) included, and a failure a real run stops on passes the test (found Nov
# 2026: the questionnaire's tests could not see one). A plain `x=$(run …)`
# keeps it. The runner records its status in RC; the check after it reads
# RC. This fails a runner called in a condition.
#
#   scripts/check-test-runners.sh     run (exit 1 on any, every one listed)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

rc=0 runners=0
runners_in() { # the functions in FILE whose body sets the run's rules
    awk '
        /^[a-z_][a-z0-9_]*\(\) *\{/ { fn = $0; sub(/\(\).*/, "", fn) }
        /set -eE; trap on_err ERR/ && fn != "" { print fn }
        /^\}/ || /^[a-z_][a-z0-9_]*\(\) *\{.*\}[[:space:]]*$/ { fn = "" }   # a body ends: its own line, or a one-line function'"'"'s' "$1"
}
shared=$(runners_in scripts/testlib.sh)   # as_run: every test may call it
[[ -n "$shared" ]] || { echo "FAIL scripts/testlib.sh has no runner — as_run was not read"; rc=1; }
for f in scripts/test-*.sh; do
    names=$( { runners_in "$f"; if grep -q 'scripts/testlib.sh' "$f"; then echo "$shared"; fi; } | sort -u)
    [[ -n "$names" ]] || continue
    for n in $names; do
        runners=$((runners + 1))
        # a call at a command position (line start, or after ; ( { && || if ! $( )
        # that is a condition: something tests it before, or && / || follow it
        bad=$(grep -nE "(^|[;({]|&&|\|\||\bif|!|\\\$\()[[:space:]]*([A-Z_]+=[^ ]* )*$n( |$)" "$f" \
              | grep -vE "^[0-9]+:[[:space:]]*#|^[0-9]+:$n\(\)" \
              | grep -E "(&&|\|\||\bif|!)[[:space:]]*([A-Z_]+=[^ ]* )*$n( |$)|(^[0-9]+:|[;({])[[:space:]]*([A-Z_]+=[^ ]* )*$n( [^;]*)?(&&|\|\|)" || true)   # none is fine
        if [[ -n "$bad" ]]; then
            while IFS= read -r l; do echo "FAIL $f:${l%%:*}: $n is called in a condition, where set -e is ignored — call it plainly, then read RC: ${l#*:}"; done <<<"$bad"
            rc=1
        fi
    done
done
(( runners )) || { echo "FAIL no runner found — the tests were not read"; rc=1; }
(( rc == 0 )) && echo "OK test runners: $runners runner(s), each called plainly"
exit $rc
