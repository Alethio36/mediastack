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
apply_with() { DC() { printf '%s\n' "$COMPOSE_ERR" >&2; return 1; }; ( apply_up --remove-orphans gluetun ) 2>&1; echo "rc=$?"; }
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

echo "test-up-race: $checks checks passed"
