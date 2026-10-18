#!/usr/bin/env bash
# test-up-race.sh — up_race (mediastack.sh): a failed first start is retried
# only as gluetun's health race; anything else stops `up` with compose's error
#   * gluetun enabled and starting, unhealthy or absent: the race (retry)
#   * gluetun enabled and healthy: not the race
#   * gluetun disabled: not the race, whatever its container says
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

echo "test-up-race: $checks checks passed"
