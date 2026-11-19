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
# rotate-secrets: ROTATE_ORDER -> <stem>_secrets and <stem>_secret_rotate
for s in $(list lib/rotate.sh 's/^ROTATE_ORDER=(\(.*\))$/\1/p'); do
    want_one ROTATE_ORDER "${s}_secrets"; want_one ROTATE_ORDER "${s}_secret_rotate"
done
# people-sync: an app people sign in to (mediastack.auth native, or a household
# gate's mediastack.auth.group) says what happens to their accounts —
# mediastack.people follow (its <svc>_people_follow), none (a comment says
# why) or source (where people come from); a follow function needs the label
people_rows() { # -> svc|auth|group|people|comment(yes or no), one per service in services/*/compose.yml ("|": read keeps empty fields)
    awk '
        function out() { if (svc != "") printf "%s|%s|%s|%s|%s\n", svc, auth, grp, ppl, cmt }
        /^services:/ { ins = 1; next }
        /^[^ #]/ { out(); svc = ""; ins = 0; next }
        ins && /^  [a-z0-9-]+:[ ]*$/ { out(); svc = $1; sub(/:$/, "", svc); auth = grp = ppl = ""; cmt = "no"; next }
        svc != "" && /mediastack\.auth: / { v = $0; sub(/.*mediastack\.auth: "/, "", v); sub(/".*/, "", v); auth = v }
        svc != "" && /mediastack\.auth\.group: / { v = $0; sub(/.*mediastack\.auth\.group: "/, "", v); sub(/".*/, "", v); grp = v }
        svc != "" && /mediastack\.people: / { v = $0; sub(/.*mediastack\.people: "/, "", v); sub(/".*/, "", v); ppl = v; cmt = ($0 ~ /" *#/) ? "yes" : "no" }
        END { out() }' services/*/compose.yml
}
followers=0
while IFS='|' read -r s auth grp ppl cmt; do
    case "$ppl" in
        follow) want_one mediastack.people "${s//-/_}_people_follow"; followers=$((followers+1)) ;;
        none)   [[ "$cmt" == yes ]] || { echo "FAIL mediastack.people: $s says none without a comment saying why"; rc=1; } ;;
        source) ;;
        "")     if [[ "$auth" == native || -n "$grp" ]]; then
                    echo "FAIL mediastack.people: people sign in to $s, but it does not say what happens to their accounts — label it follow, none (with why) or source"; rc=1
                fi ;;
        *)      echo "FAIL mediastack.people: $s says '$ppl' — follow, none or source"; rc=1 ;;
    esac
done < <(people_rows)
(( followers )) || { echo "FAIL mediastack.people: no service follows the portal — the compose files were not read"; rc=1; }
for f in $(grep -hoE '^[a-z0-9_]+_people_follow\(\)' services/*/*.sh | sed 's/()$//'); do
    s=${f%_people_follow}
    people_rows | awk -F'|' -v s="$s" '{ n = $1; gsub(/-/, "_", n) } n == s && $4 == "follow" { f = 1 } END { exit !f }' \
        || { echo "FAIL mediastack.people: ${f}() exists, but no service named ${s//_/-} is labelled follow — people-sync would never run it"; rc=1; }
done
# disable authentik: a tool that drops its login behind the gate (gate_trusted
# <svc>, by name) brings <svc>_gate_login, which puts it back before the ports
# reopen — the arrs and Prowlarr (arr_login) have their own loop there
for s in $(grep -hoE 'gate_trusted [a-z0-9-]+' services/*/*.sh | awk '{print $2}' | sort -u); do
    want_one "gate_trusted $s" "${s//-/_}_gate_login"
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
