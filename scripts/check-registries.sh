#!/usr/bin/env bash
# check-registries.sh — a verb that covers several services keeps an explicit,
# ordered list of them; each listed name's part lives with its service. This
# fails a listed name without exactly one matching function under services/
# (or with one defined outside it), and a <service>_* function a lib calls by
# name that nothing defines.
#
#   scripts/check-registries.sh     run (exit 1 on any gap, every gap listed)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

rc=0
want_one() { # want_one <list name> <function>
    local n
    n=$({ grep -lE "^$2\(\)" services/*/*.sh || true; } | wc -l)   # none found is a count, not an error
    [[ "$n" == 1 ]] || { echo "FAIL $1: $n definitions of $2() under services/ (want 1)"; rc=1; }
    if grep -qE "^$2\(\)" lib/*.sh mediastack.sh; then echo "FAIL $1: $2() is defined outside services/"; rc=1; fi
}
list() { # list <file> <sed expression printing the list's words>
    local words; words=$(sed -n "$2" "$1")
    [[ -n "$words" ]] || { echo "FAIL the list in $1 was not found"; rc=1; }
    echo "$words"
}

# wire: WIRE_ROLES -> wire_<role>
for r in $(list lib/wire.sh 's/^WIRE_ROLES=(\(.*\))$/\1/p'); do want_one WIRE_ROLES "wire_$r"; done
# set-credentials: its accepted targets -> sc_rotate_<target> ("all" is the verb's own)
for t in $(list lib/access.sh 's/^    case "$target" in \([a-z|]*\)) ;; \*)$/\1/p' | tr '|' ' '); do
    [[ "$t" == all ]] || want_one set-credentials "sc_rotate_$t"
done
# doctor: DOCTOR_APPS -> <app>_doctor
for a in $(list lib/doctor.sh 's/^DOCTOR_APPS=(\(.*\))$/\1/p'); do want_one DOCTOR_APPS "${a}_doctor"; done
# by name: a lib or the entrypoint calling <service>_<anything> (a service's
# folder name, '-' as '_') needs that function to exist — a typo or a move
# that left a caller behind would otherwise fail only when that line runs
for n in $(ls services | sed 's/^_//; s/-/_/g'); do
    for f in $(grep -hoE "\b${n}_[a-z0-9_]+\b" lib/*.sh mediastack.sh | sort -u); do
        grep -qE "^$f\(\)" services/*/*.sh lib/*.sh mediastack.sh \
            || { echo "FAIL by name: $f is called but defined nowhere"; rc=1; }
    done
done

(( rc == 0 )) && echo "OK registries: every listed name has its function under services/"
exit $rc
