#!/usr/bin/env bash
# test-verdict.sh — wait_verdict, the one definition of "came up" behind every
# health wait (doctor, the update gate, up, vpn-guard, new-service, wire).
# Docker and the clock are simulated: each container's state lives in files,
# `sleep` advances a virtual clock and applies scheduled state changes, so a
# 300s wait runs in milliseconds and every timing is exact. Each case guards a
# failure that shipped or nearly shipped:
#   - a service turning healthy mid-wait is seen (the frozen-cache bug, twice)
#   - "-" passes only for a RUNNING container (the update gate passed exited
#     and missing containers)
#   - Docker's unhealthy verdict ends the wait at once, not at the cap
#
#   scripts/test-verdict.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-verdict.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"
# ENV_FILE / RENDERED_JSON / INSPECT_JSON below are read by the sourced entrypoint
# shellcheck disable=SC2034
ENV_FILE=/dev/null
# shellcheck disable=SC2034
RENDERED_JSON=$(jq -cn '{services: ([range(1;6)] | map({key: "s\(.)", value: {container_name: "mediastack-s\(.)", labels: {"mediastack.managed": "true"}}}) | from_entries)}')

# ---- simulated docker: $T/c/<cname>/{status,health,restarts}; no dir = absent
NOW=0
date() { if [[ "${1:-}" == +%s ]]; then echo "$NOW"; else command date "$@"; fi; }
sleep() { NOW=$(( NOW + ${1%.*} )); apply_events; }
apply_events() { # $T/events: "<at> <cname> <field> <value>"
    local at cn f v
    [[ -f "$T/events" ]] || return 0
    while read -r at cn f v; do
        (( NOW >= at )) && echo "$v" > "$T/c/$cn/$f"
    done < "$T/events"
}
sudo() {
    [[ "$1 $2" == "docker inspect" ]] || { "$@"; return; }
    shift 4   # docker inspect --type container
    local cn out="" h
    for cn in "$@"; do
        [[ -d "$T/c/$cn" ]] || continue
        h=$(cat "$T/c/$cn/health"); [[ "$h" == - ]] && h=null || h="{\"Status\":\"$h\"}"
        out+="${out:+,}{\"Name\":\"/$cn\",\"RestartCount\":$(cat "$T/c/$cn/restarts"),\"State\":{\"Status\":\"$(cat "$T/c/$cn/status")\",\"Health\":$h},\"Mounts\":[]}"
    done
    echo "[$out]"
}
ctr() { mkdir -p "$T/c/mediastack-$1"; echo "$2" > "$T/c/mediastack-$1/status"; echo "$3" > "$T/c/mediastack-$1/health"; echo 0 > "$T/c/mediastack-$1/restarts"; }
at()  { echo "$1 mediastack-$2 $3 $4" >> "$T/events"; }
reset() { rm -rf "$T/c" "$T/events"; NOW=0; INSPECT_JSON=""; }
# run [svc...] — wait_verdict with errexit live; sets RC, OUT, and the verdict globals
run() { set +e; OUT=$( { wait_verdict "$@"; echo "rc=$?"; declare -p VERDICT_BAD VERDICT_WHY NOW; } 2>&1 ); set -e
        # declare -p re-evaluated inside a function would make LOCALS: force -g
        eval "$(grep -E '^declare ' <<<"$OUT" | sed -E 's/^declare -- /declare -g /; s/^declare -([A-Za-z]+) /declare -g\1 /')"
        RC=$(sed -n 's/^rc=//p' <<<"$OUT"); }

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

# healthy mid-wait ends the wait early
reset; ctr s1 running starting; at 10 s1 health healthy
run s1
[[ $RC == 0 && $NOW -le 15 ]] || fail_ "healthy at 10s: rc=$RC after ${NOW}s"; pass

# Docker's unhealthy verdict ends it at once, not at the cap
reset; ctr s1 running starting; at 150 s1 health unhealthy
run s1
[[ $RC == 1 && $NOW -lt 160 && "${VERDICT_WHY[s1]}" == *unhealthy* ]] || fail_ "unhealthy at 150s: rc=$RC after ${NOW}s why=${VERDICT_WHY[s1]:-}"; pass

# no healthcheck: running passes; exited / absent fail at once
reset; ctr s1 running -
run s1
[[ $RC == 0 && $NOW == 0 ]] || fail_ "running without healthcheck must pass at once"; pass
reset; ctr s1 exited -
run s1
[[ $RC == 1 && $NOW == 0 && "${VERDICT_WHY[s1]}" == "is exited" ]] || fail_ "exited must fail at once: ${VERDICT_WHY[s1]:-}"; pass
reset
run s1
[[ $RC == 1 && "${VERDICT_WHY[s1]}" == "is absent" ]] || fail_ "absent must fail: ${VERDICT_WHY[s1]:-}"; pass

# "created" (held back by depends_on: service_healthy, e.g. behind gluetun) is
# not started yet: no healthcheck must not make it pass before it runs
reset; ctr s1 created -; at 20 s1 status running
run s1
[[ $RC == 0 && $NOW -ge 20 ]] || fail_ "created must wait until running: rc=$RC at ${NOW}s"; pass

# boot loop: a restart during the wait fails it
reset; ctr s1 running starting; at 20 s1 restarts 1
run s1
[[ $RC == 1 && "${VERDICT_WHY[s1]}" == *boot-looping* ]] || fail_ "boot loop: ${VERDICT_WHY[s1]:-}"; pass

# a hanging healthcheck is cut off at START_WAIT, and says so
reset; ctr s1 running starting
run s1
[[ $RC == 1 && $NOW -ge $START_WAIT && "${VERDICT_WHY[s1]}" == *undecided* ]] || fail_ "hang: rc=$RC after ${NOW}s"; pass

# the caller's stale cache is ignored: live says healthy
reset; ctr s1 running healthy
# shellcheck disable=SC2034  # read by wait_verdict's caller-cache path
INSPECT_JSON='[{"Name":"/mediastack-s1","RestartCount":0,"State":{"Status":"running","Health":{"Status":"starting"}}}]'
run s1
[[ $RC == 0 && $NOW == 0 ]] || fail_ "a stale caller cache must not be read"; pass

# mixed: only the failures are reported, in argument order
reset; ctr s1 running healthy; ctr s2 exited -; ctr s3 running starting; at 60 s3 health unhealthy; ctr s4 running starting; at 30 s4 health healthy
run s1 s2 s3 s4
[[ $RC == 1 && "$VERDICT_BAD" == "s2 s3" ]] || fail_ "mixed: VERDICT_BAD='$VERDICT_BAD'"; pass
grep -q '^OK s4 (running, healthy)' <<<"$OUT" || fail_ "a pass prints an OK line: $OUT"; pass

echo "OK verdict: $checks checks"
