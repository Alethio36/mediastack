#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-jf-ready.sh — jf_ready (services/jellyfin/jellyfin.sh): Jellyfin is ready
# only once the real server is up, not while Jellyfin 12's temporary setup
# server answers during startup:
#   * it waits for "Startup complete" in the logs since this container started,
#     and only then asks the API
#   * a line from before the container's start does not count (logs are read
#     --since its start time)
#   * no line within API_WAIT: a failure naming the line and where to look
#   * no start time (not running): a failure, the logs never read
# Sources the real entrypoint (minus its last line, main "$@"); docker, the
# clock and the API wait are stubs.
#
#   scripts/test-jf-ready.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-jf-ready.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

svc_cname()  { echo mediastack-jellyfin; }
c_get()      { cat "$T/started"; }
http_ready() { echo "API $2" >> "$T/calls"; }
sleep()      { echo "SLEEP" >> "$T/calls"; local n; n=$(cat "$T/tick"); echo $((n+1)) > "$T/tick"; }
date()       { echo $(( $(cat "$T/tick") * 2 )); }   # +%s only: two seconds per sleep
sudo() { # docker logs --since S NAME: the lines logged at or after tick T_LINE, if any
    [[ "$1 $2 $3" == "docker logs --since" ]] || return 1
    echo "SINCE $4" >> "$T/calls"
    local n; n=$(cat "$T/tick")
    (( n >= $(cat "$T/line_at") )) && echo "[05:49:00.424] [INF] [11] Main: Startup complete 0:00:10.9"
    echo "[05:48:50.562] [INF] [11] Main: Jellyfin version: 12.2.0"
}
fresh() { rm -f "$T/calls"; echo 0 > "$T/tick"; echo "$1" > "$T/line_at"; echo 2026-10-18T12:48:48.99Z > "$T/started"; WIRE_FAILS=0; API_WAIT=20; }

fresh 3; jf_ready > "$T/out" 2>&1 || true
[[ $(grep -c SLEEP "$T/calls") == 3 ]] || fail_ "it waits until the line appears ($(grep -c SLEEP "$T/calls") waits)"; pass
[[ $(tail -1 "$T/calls") == API* && $(grep -c '^API' "$T/calls") == 1 ]] \
    || fail_ "the API is asked once, only after the line: $(tr '\n' ' ' < "$T/calls")"; pass
grep -qx 'SINCE 2026-10-18T12:48:48.99Z' "$T/calls" || fail_ "the logs are read since this container started"; pass
(( WIRE_FAILS == 0 )) || fail_ "a normal start is no failure: $(cat "$T/out")"; pass

fresh 0; jf_ready > "$T/out" 2>&1 || true
! grep -q SLEEP "$T/calls" && grep -q '^API' "$T/calls" || fail_ "already started: straight to the API"; pass

fresh 999; jf_ready > "$T/out" 2>&1 && fail_ "no line: not ready"
(( WIRE_FAILS == 1 )) && grep -q "never logged 'Main: Startup complete' within 20s" "$T/out" && ! grep -q '^API' "$T/calls" \
    || fail_ "no line within API_WAIT: a failure naming it, the API never asked — $(cat "$T/out")"; pass

fresh 0; : > "$T/started"; jf_ready > "$T/out" 2>&1 && fail_ "no start time: not ready"
(( WIRE_FAILS == 1 )) && ! grep -q SINCE "$T/calls" 2>/dev/null && grep -q 'no start time' "$T/out" \
    || fail_ "no start time: a failure, logs never read — $(cat "$T/out")"; pass

echo "test-jf-ready: $checks checks passed"
