#!/usr/bin/env bash
# test-http-ready.sh — http_ready, the one API-readiness wait behind wire and
# trash-sync. curl and the clock are simulated: a scripted status per virtual
# second, `sleep` advances the clock, so a 90s budget runs in milliseconds.
# Guards: early return on a matching status, the per-app success patterns, the
# shared --until deadline (trash-sync's one budget across every arr), curl
# arguments reaching curl, and "no socket" reported as HTTP 000 (the loops it
# replaced reported 000000).
#
#   scripts/test-http-ready.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-http-ready.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"

NOW=0
date()  { if [[ "${1:-}" == +%s ]]; then echo "$NOW"; else command date "$@"; fi; }
sleep() { NOW=$(( NOW + ${1%.*} )); }
# $T/plan: "<from-second> <status>" lines, last applicable wins; 000 = no socket
curl() {
    printf '%s\n' "$*" > "$T/args"
    local from st code=000
    while read -r from st; do (( NOW >= from )) && code=$st; done < "$T/plan"
    printf '%s' "$code"
    [[ "$code" != 000 ]] || return 7   # real curl: prints 000 AND fails
}
plan() { printf '%s\n' "$@" > "$T/plan"; }
# run [args] — http_ready with errexit live; sets RC, OUT; NOW advanced in-shell
run() { WIRE_FAILS=0; set +e; http_ready "$@" > "$T/out" 2>&1; RC=$?; set -e; OUT=$(cat "$T/out"); }

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

# answers at 10s -> ready early
NOW=0; plan "0 000" "10 200"
run app http://x/health '^200$'
[[ $RC == 0 && $NOW -le 15 ]] || fail_ "ready at 10s: rc=$RC at ${NOW}s"; pass

# never ready -> wfail at the budget, naming the last status and the logs verb
NOW=0; plan "0 503"
run app http://x/health '^200$'
[[ $RC == 1 && $NOW -ge $API_WAIT && $WIRE_FAILS == 1 ]] || fail_ "timeout: rc=$RC at ${NOW}s fails=$WIRE_FAILS"; pass
grep -q "app's API never became ready within ${API_WAIT}s (last: HTTP 503) — inspect: ./mediastack.sh logs app" <<<"$OUT" \
    || fail_ "timeout message: $OUT"; pass

# no socket is HTTP 000, not 000000
NOW=0; plan "0 000"
run app http://x/ '^2'
grep -q '(last: HTTP 000)' <<<"$OUT" || fail_ "no-socket status must read 000: $OUT"; pass

# per-app patterns: lazylibrarian accepts 401 (auth wall = up); 404 is not up
NOW=0; plan "0 401"
run lazylibrarian http://x/ '^([23][0-9][0-9]|401|403)$'
[[ $RC == 0 ]] || fail_ "401 must satisfy lazylibrarian's pattern"; pass
NOW=0; plan "0 404"
run lazylibrarian http://x/ '^([23][0-9][0-9]|401|403)$'
[[ $RC == 1 ]] || fail_ "404 must not satisfy lazylibrarian's pattern"; pass

# qbit's listener check: any status proves a socket, 000 does not
NOW=0; plan "0 000" "6 403"
run qbittorrent http://x/api '^[1-9]'
[[ $RC == 0 && $NOW -ge 6 ]] || fail_ "qbit listener: rc=$RC at ${NOW}s"; pass

# shared deadline: --until in the past allows exactly one probe, then fails
NOW=100; plan "0 503"
run --until 100 radarr http://x/api '^200$'
[[ $RC == 1 && $NOW == 100 ]] || fail_ "--until: rc=$RC at ${NOW}s (no extra wait allowed)"; pass
NOW=100; plan "0 200"
run --until 100 radarr http://x/api '^200$'
[[ $RC == 0 ]] || fail_ "--until: a ready API still passes at the deadline"; pass

# curl arguments reach curl, before the URL
NOW=0; plan "0 200"
run radarr http://x/api/v3/system/status '^200$' -H "X-Api-Key: k123"
grep -q -- '-H X-Api-Key: k123 http://x/api/v3/system/status' "$T/args" || fail_ "curl args: $(cat "$T/args")"; pass

# a readiness probe or healthcheck must not depend on the internet: seerr's
# /api/v1/status asks GitHub for the latest release on every call (found live:
# without outbound DNS it outlasted the 5s probe for 90s on a healthy seerr)
if grep -nE 'seerr.*api/v1/status|5055/api/v1/status' lib/*.sh mediastack.sh compose.d/*.yml | grep -v '^[^:]*:[0-9]*:[[:space:]]*#'; then
    fail_ "seerr's /api/v1/status used as a probe (above) — use /api/v1/settings/public"
fi; pass

echo "OK http-ready: $checks checks"
