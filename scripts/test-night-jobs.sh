#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-night-jobs.sh — what the first soak (Oct 2026) found in the night jobs:
#   * gluetun_recreates (lib/backup.sh): a full update recreates the VPN group
#     only when gluetun itself changes — a new image or a changed config —
#     not every time it is in the target list; anything unreadable counts as
#     a change (the group then goes together, as before)
#   * vpn_egress_ready (services/gluetun/vpn.sh): a service on gluetun's
#     network starts only once HTTPS by name works through the tunnel twice in
#     a row; a flapping tunnel resets the count; never working is a FAIL with
#     the last error; a service not on gluetun's network is not probed
#   * prowlarr_indexers_retest: a passing proxy test is followed by Prowlarr's
#     own health check (its health list keeps the old failure otherwise); a
#     failing one is not
# Sources the real entrypoint (minus its last line, main "$@"); docker,
# compose, the clock and the APIs are stubs.
#
#   scripts/test-night-jobs.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-night-jobs.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"
set +e +E; trap - ERR   # each check reads its own status

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

# ---- gluetun_recreates ----
svc_cname() { echo "mediastack-$1"; }
svc_image() { echo "qmcgaw/gluetun:latest"; }
HAVE="sha256:aaa hash1" WANT_IMG="sha256:aaa" WANT_HASH="hash1"
sudo() { # docker inspect / docker image inspect, answered from the variables above
    case "$2 $3" in
        "inspect -f") [[ -n "$HAVE" ]] && echo "$HAVE" || return 1 ;;
        "image inspect") [[ -n "$WANT_IMG" ]] && echo "$WANT_IMG" || return 1 ;;
    esac
}
DC() { [[ "$*" == "config --hash gluetun" ]] && echo "gluetun $WANT_HASH"; }
gluetun_recreates && fail_ "same image, same config: no recreate"; pass
WANT_IMG="sha256:bbb"; gluetun_recreates || fail_ "a new image: recreate"; pass
WANT_IMG="sha256:aaa" WANT_HASH="hash2"; gluetun_recreates || fail_ "a changed config: recreate"; pass
WANT_HASH="hash1" HAVE=""; gluetun_recreates || fail_ "no container: recreate (it will be created)"; pass
HAVE="sha256:aaa hash1" WANT_HASH=""; gluetun_recreates || fail_ "config hash unreadable: counts as a change"; pass
grep -q 'grep -qx gluetun && gluetun_recreates; then' lib/backup.sh \
    || fail_ "update forces the VPN group only when gluetun_recreates says so (lib/backup.sh)"; pass

# ---- vpn_egress_ready ----
unset -f sudo
render() { :; }
RENDERED_JSON='{"services":{"recyclarr":{"network_mode":"service:gluetun"},"jellyfin":{}}}'
sleep() { echo $(( $(cat "$T/now") + 5 )) > "$T/now"; }
date()  { cat "$T/now"; }   # +%s only
sudo() { # docker exec gluetun wget ...: the next scripted answer (ok|fail)
    local n a; n=$(cat "$T/n"); echo $((n + 1)) > "$T/n"
    a=$(sed -n "$((n + 1))p" "$T/answers"); echo "PROBE" >> "$T/probes"
    [[ "${a:-fail}" == ok ]] && return 0
    echo "wget: bad address 'github.com'"; return 1
}
egress() { printf '%s\n' "$@" > "$T/answers"; echo 0 > "$T/n"; echo 1000 > "$T/now"; : > "$T/probes"; VPN_EGRESS_WAIT=60; vpn_egress_ready "${SVC:-recyclarr}" > "$T/out" 2>&1; }

egress ok ok || fail_ "two answers in a row: ready"; pass
[[ $(wc -l < "$T/probes") == 2 ]] || fail_ "ready after exactly two probes ($(wc -l < "$T/probes"))"; pass
egress fail ok fail ok ok || fail_ "a flapping tunnel, then steady: ready"; pass
[[ $(wc -l < "$T/probes") == 5 ]] || fail_ "a failure resets the count ($(wc -l < "$T/probes") probes)"; pass
egress fail && fail_ "never reaching out: not ready"
grep -q "FAIL recyclarr: the tunnel still cannot reach the internet after 60s (last: wget: bad address 'github.com')" "$T/out" \
    || fail_ "never: a FAIL with the last error — $(cat "$T/out")"; pass
SVC=jellyfin egress fail || fail_ "a service off gluetun's network: no wait"; pass
[[ ! -s "$T/probes" ]] || fail_ "and no probe"; pass
unset -f sleep date

# ---- prowlarr: a passing proxy test, then its own health check ----
svc_enabled()  { :; }
c_state()      { echo running; }
wait_verdict() { :; }
arr_key()      { echo key; }
arr_url()      { echo http://p; }
arr_apiver()   { echo v1; }
http_ready()   { :; }
indexer_test_report() { return 1; }
PROXY_OK=1
api() { echo "$1 ${2#http://p/api/v1} ${4:-}" >> "$T/api"; [[ "$2" == */indexerproxy/testall ]] && { (( PROXY_OK )) && echo '[]' || { echo '[{"isValid":false}]'; return 1; }; }; echo '[]'; }
retest() { rm -f "$T/api"; prowlarr_indexers_retest > "$T/out" 2>&1; }

PROXY_OK=1; retest
grep -qx 'POST /command {"name":"CheckHealth"}' "$T/api" || fail_ "a passing proxy test: Prowlarr's health check follows — $(cat "$T/api")"; pass
[[ $(grep -n 'indexerproxy/testall' "$T/api" | cut -d: -f1) -lt $(grep -n 'CheckHealth' "$T/api" | cut -d: -f1) ]] || fail_ "after the test, not before"; pass
PROXY_OK=0; retest
! grep -q CheckHealth "$T/api" && grep -q 'WARN.*re-testing its proxies failed' "$T/out" || fail_ "a failing proxy test: a WARN, no health check — $(cat "$T/out")"; pass

echo "test-night-jobs: $checks checks passed"
