#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced entrypoint
# test-up-race.sh — up_race (mediastack.sh): a failed first start is retried
# only as gluetun's health race; anything else stops `up` with compose's error
#   * gluetun enabled and starting, unhealthy or absent: the race (retry)
#   * gluetun enabled and healthy: not the race
#   * gluetun disabled: not the race, whatever its container says
#   * update's apply (apply_up): a dependency compose names unhealthy is deferred to
#     the health gate; a daemon error dies at once with compose's message, even when
#     the lines it interrupted mention health (found live Nov 2026: a restore waited
#     400s and blamed gluetun for olivetin's failed mount)
#   * pulls: what is missing is pulled first, a one-off registry refusal
#     retried (found live Nov 2026: a throttled pull ended a first install),
#     a lasting one stops the start; apply_up pulls its services, not up's flags
# Sources the real entrypoint (minus its last line, main "$@"); svc_enabled,
# svc_cname and c_health are stubs.
#
#   scripts/test-up-race.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-up-race.XXXXXX)
trap 'rm -f "$lib"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

ENABLED=gluetun HEALTH=healthy
svc_enabled() { [[ ",$ENABLED," == *",$1,"* ]]; }
svc_cname()   { echo "mediastack-$1"; }
c_health()    { echo "$HEALTH"; }

for HEALTH in starting unhealthy -; do
    up_race || fail_ "gluetun enabled and '$HEALTH': the race, so up retries"; pass
done
HEALTH=healthy
up_race && fail_ "gluetun healthy: not the race — up stops with compose's error"; pass
ENABLED=jellyfin HEALTH=starting
up_race && fail_ "gluetun disabled: not the race — up stops with compose's error"; pass

# ---- apply_up: which compose failures the health gate may adjudicate ----
set +e +E; trap - ERR
APPLY_VERB=restore
apply_with() { DC() { [[ "$1" == pull ]] && return 0; printf '%s\n' "$COMPOSE_ERR" >&2; return 1; }; ( apply_up --remove-orphans gluetun ) 2>&1; echo "rc=$?"; }
COMPOSE_ERR=' Container mediastack-gluetun Error dependency failed to start: container mediastack-gluetun is unhealthy
dependency failed to start: container mediastack-gluetun is unhealthy'
out=$(apply_with)
[[ "$out" == *"deferring the verdict to the health gate"*"rc=0" ]] || fail_ "an unhealthy dependency: deferred to the health gate — $out"; pass
COMPOSE_ERR=' Container mediastack-olivetin Error response from daemon: failed to create task for container: OCI runtime create failed: error mounting "/x/olivetin/passwd" to rootfs at "/etc/passwd": not a directory
 Container mediastack-authentik not started: condition "service_healthy" of service "authentik-db" not reached: interrupted by the failure of Container mediastack-olivetin
 Container mediastack-gluetun interrupted by the failure of Container mediastack-olivetin
Error response from daemon: failed to create task for container: OCI runtime create failed'
out=$(apply_with)
[[ "$out" == *"restore: 'up' failed for a non-health reason"* && "$out" != *"deferring"* && "$out" != *"rc=0" ]] \
    || fail_ "a daemon error (lines it interrupted mention service_healthy): dies at once with compose's message — $out"; pass
COMPOSE_ERR='service "jellyfin" depends on undefined service "nope": invalid compose project'
out=$(apply_with); [[ "$out" == *"non-health reason"* && "$out" != *"rc=0" ]] || fail_ "a broken config: dies — $out"; pass
COMPOSE_ERR=' Container mediastack-qbittorrent not started: condition "service_healthy" of service "gluetun" not reached: container mediastack-gluetun is unhealthy'
out=$(apply_with); [[ "$out" == *"deferring"*"rc=0" ]] || fail_ "compose 5 words a health wait as a condition not reached: deferred — $out"; pass

# ---- pulls: a registry's one-off refusal is retried, a lasting one stops the start ----
T=$(mktemp -d); trap 'rm -f "$lib"; rm -rf "$T"' EXIT
pm() { # pm FAILS-BEFORE-SUCCESS -> "rc=N pulls=N"
    ( echo 0 > "$T/n"; sleep() { :; }; warn() { :; }
      DC() { local n; n=$(( $(cat "$T/n") + 1 )); echo "$n" > "$T/n"; [[ "$*" == "pull --policy missing"* ]] || return 9; (( n > FAILS )); }
      FAILS=$1; rc=0; pull_missing jellyfin || rc=$?; echo "rc=$rc pulls=$(cat "$T/n")" )
}
[[ "$(pm 0)" == "rc=0 pulls=1" ]] || fail_ "pulls fine: once: $(pm 0)"; pass
[[ "$(pm 2)" == "rc=0 pulls=3" ]] || fail_ "two refusals, then through: retried, the start goes on: $(pm 2)"; pass
[[ "$(pm 9)" == "rc=1 pulls=3" ]] || fail_ "refused every time: bounded, then a failure: $(pm 9)"; pass
r=$(declare -f cmd_up); r=${r%%DC up -d*}
[[ "$r" == *pull_missing* ]] || fail_ "up pulls, retried, before it starts anything"; pass
r=$(DC() { echo "$*" >> "$T/args"; return 0; }; : > "$T/args"; ( apply_up -d --remove-orphans gluetun qbittorrent ) >/dev/null 2>&1; sed -n 1p "$T/args")
[[ "$r" == "pull --policy missing gluetun qbittorrent" ]] || fail_ "update's and restore's apply pull its services first, without up's flags: $r"; pass

echo "test-up-race: $checks checks passed"
