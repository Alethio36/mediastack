#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-livetv.sh — Jellyfin's Live TV from the live-tv role (services/jellyfin/livetv.sh):
#   * a fresh Jellyfin gets the provider's tuner and guide, read back
#   * a second run changes nothing
#   * after a VPN toggle the same entries are re-pointed in place: same Id,
#     the settings the user changed kept, nothing added
#   * the user's own tuners and guides are never touched
#   * dry run says what it would do and calls nothing that writes
#   * a tuner whose nginx answers 502 while the app starts is waited for
#   * a change that does not hold, a tuner that does not answer, a provider
#     not running: each a wire failure, said; no provider enabled: nothing
#   * ErsatzTV works from its own template alone; with both, Dispatcharr (priority 1)
# Sources the real entrypoint (minus its last line, main "$@"); Jellyfin's API and curl are stubs.
#
#   scripts/test-livetv.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-livetv.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"
set +E; trap - ERR

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "OK $*"; }; wfail() { WIRE_FAILS=$((WIRE_FAILS + 1)); echo "FAIL $*"; }
info() { echo "INFO $*"; }; hr() { :; }
WIRE_DRY=0 WIRE_FAILS=0

ENV_FILE=$T/env
profiles() { printf 'COMPOSE_PROFILES=%s\n' "$1" > "$ENV_FILE"; }
profiles jellyfin,dispatcharr
HOST=dispatcharr RUNNING=yes
svc_addr()     { echo "$HOST:$(svc_cport "$1")"; }
svc_host()     { echo "$HOST"; }
svc_cport()    { case $1 in dispatcharr) echo 9191 ;; ersatztv) echo 8409 ;; esac; }
svc_hostport() { svc_cport "$1"; }
svc_cname()    { echo "$1"; }
c_state()      { [[ $RUNNING == yes ]] && echo running || echo exited; }

# Jellyfin's live TV settings, as a file (jf_api runs inside $( )); POST upserts by Id,
# and a new tuner gets the DeviceId Jellyfin reads from its discover.json
CFG=$T/livetv.json CALLS=$T/calls
echo 0 > "$T/ids"
newid() { local n; n=$(( $(cat "$T/ids") + 1 )); echo "$n" > "$T/ids"; [[ $n == 1 ]] && echo "$1-new" || echo "$1-$n"; }
jf_code() { echo 200; }
jf_api() {
    echo "$1 $2" >> "$CALLS"
    case "$1 $2" in
        "GET /System/Configuration/livetv") cat "$CFG" ;;
        "POST /LiveTv/TunerHosts")
            [[ -n "${HOLD:-}" ]] && { echo '{}'; return 0; }
            # an entry without an Id is a new one: each its own Id, so a re-point that drops it shows as a twin
            jq -c --argjson t "$4" --arg id "$(newid tun)" '($t | .Id //= $id | .DeviceId //= "12345678") as $t
                | .TunerHosts = ([.TunerHosts[]? | select(.Id != $t.Id)] + [$t])' "$CFG" > "$CFG.n" && mv "$CFG.n" "$CFG"; echo '{}' ;;
        "POST /LiveTv/ListingProviders"*)
            [[ -n "${HOLD:-}" ]] && { echo '{}'; return 0; }
            jq -c --argjson g "$4" --arg id "$(newid lst)" '($g | .Id //= $id) as $g
                | .ListingProviders = ([.ListingProviders[]? | select(.Id != $g.Id)] + [$g])' "$CFG" > "$CFG.n" && mv "$CFG.n" "$CFG"; echo '{}' ;;
        *) echo "unexpected"; return 1 ;;
    esac
}
# the tuner as Dispatcharr's nginx serves it: no socket (DISC_OK=no), or 502
# for its first STARTING calls (the app behind still starting), then the device
DISC_OK=yes STARTING=0
echo 0 > "$T/served"
sleep() { :; }
curl() {
    local u="${*: -1}" n code=200 body='{"DeviceID":"12345678","FriendlyName":"Dispatcharr HDHomeRun"}'
    echo "$u" >> "$T/curled"
    [[ $DISC_OK == yes ]] || { [[ " $* " == *" -w "* ]] && echo 000; return 7; }
    n=$(( $(cat "$T/served") + 1 )); echo "$n" > "$T/served"
    (( n > STARTING )) || { code=502; body='<html><head><title>502 Bad Gateway</title></head></html>'; }
    if [[ " $* " == *" -w "* ]]; then echo "$code"; return 0; fi          # http_ready asks only the code
    if [[ $code != 200 && " $* " == *" -f"* ]]; then echo "curl: (22) The requested URL returned error: $code"; return 22; fi
    echo "$body"
}

# jf_livetv as wire runs it (set -eE, the ERR trap): it never stops a run —
# a failure is wfail and return 0 — so stopping here fails the test
run()    { : > "$CALLS"; : > "$T/curled"; echo 0 > "$T/served"; rm -f "$T/fails"; WIRE_FAILS=0
           set +e; ( set -eE; trap on_err ERR; jf_livetv tok; echo "$WIRE_FAILS" > "$T/fails" ) > "$T/out" 2>&1; RC=$?; set -e
           (( RC == 0 )) && [[ -s "$T/fails" ]] || fail_ "jf_livetv stopped where a run would stop (rc $RC): $(cat "$T/out")"
           WIRE_FAILS=$(cat "$T/fails"); }
writes() { grep -c '^POST' "$CALLS" || true; }
tuner()  { jq -r --arg k "$1" '[.TunerHosts[] | select(.DeviceId == "12345678")][0][$k]' "$CFG"; }
guide()  { jq -r --arg k "$1" '[.ListingProviders[] | select(.Path | endswith(":9191/output/epg"))][0][$k]' "$CFG"; }

# the user's own: another tuner and another guide, which must never change
mine='{"Id":"tun-mine","Type":"hdhomerun","Url":"http://192.168.1.50","DeviceId":"1053ABCD"}'
mineg='{"Id":"lst-mine","Type":"xmltv","Path":"https://example.org/guide.xml"}'
jq -cn --argjson t "$mine" --argjson g "$mineg" '{TunerHosts:[$t], ListingProviders:[$g]}' > "$CFG"

# ---- fresh: added, read back ----
run
[[ $WIRE_FAILS == 0 ]] || fail_ "fresh: no failure: $(cat "$T/out")"; pass
[[ "$(tuner Url)" == http://dispatcharr:9191/hdhr ]] || fail_ "fresh: tuner at Dispatcharr's address: $(cat "$CFG")"; pass
[[ "$(tuner Type)/$(tuner AllowStreamSharing)" == hdhomerun/true ]] || fail_ "fresh: the template's tuner as it is: $(cat "$CFG")"; pass
[[ "$(guide Path)/$(guide Type)" == http://dispatcharr:9191/output/epg/xmltv ]] || fail_ "fresh: its guide: $(cat "$CFG")"; pass
[[ "$(sort -u "$T/curled")" == http://127.0.0.1:9191/hdhr/discover.json ]] || fail_ "its DeviceID asked from this host, by the published port: $(cat "$T/curled")"; pass
grep -q 'OK jellyfin: live TV tuner dispatcharr' "$T/out" && grep -q 'OK jellyfin: live TV guide from dispatcharr' "$T/out" || fail_ "fresh: both said: $(cat "$T/out")"; pass
[[ "$(jq -c '[.TunerHosts[] | select(.Id == "tun-mine")][0]' "$CFG")" == "$mine" && "$(jq -c '[.ListingProviders[] | select(.Id == "lst-mine")][0]' "$CFG")" == "$mineg" ]] || fail_ "the user's own tuner and guide untouched: $(cat "$CFG")"; pass

# ---- again: nothing to do ----
run
[[ "$(writes)" == 0 && $WIRE_FAILS == 0 ]] || fail_ "second run: no writes: $(cat "$CALLS")"; pass

# ---- VPN toggle: re-pointed in place, the user's changes kept ----
tid=$(tuner Id) gid=$(guide Id)
jq -c --arg t "$tid" '(.TunerHosts[] | select(.DeviceId == "12345678")) |= (.FriendlyName = "Our TV" | .TunerCount = 4)
     | (.ListingProviders[] | select(.Path | endswith(":9191/output/epg"))) |= (.EnabledTuners = [$t] | .ChannelMappings = [{"Name":"5","Value":"5.1"}])' "$CFG" > "$CFG.n" && mv "$CFG.n" "$CFG"
HOST=gluetun
run
[[ "$(writes)" == 2 && $WIRE_FAILS == 0 ]] || fail_ "toggle: two writes, no failure: $(cat "$CALLS") $(cat "$T/out")"; pass
[[ "$(tuner Url)/$(tuner Id)" == "http://gluetun:9191/hdhr/$tid" ]] || fail_ "toggle: the same tuner re-pointed: $(cat "$CFG")"; pass
[[ "$(tuner FriendlyName)/$(tuner TunerCount)" == "Our TV/4" ]] || fail_ "toggle: the user's tuner settings kept: $(cat "$CFG")"; pass
[[ "$(guide Path)/$(guide Id)" == "http://gluetun:9191/output/epg/$gid" ]] || fail_ "toggle: the same guide re-pointed: $(cat "$CFG")"; pass
[[ "$(guide ChannelMappings | jq -c .)" == '[{"Name":"5","Value":"5.1"}]' ]] || fail_ "toggle: the guide's channel mappings kept: $(cat "$CFG")"; pass
[[ "$(jq '.TunerHosts | length' "$CFG")/$(jq '.ListingProviders | length' "$CFG")" == 2/2 ]] || fail_ "toggle: nothing added: $(cat "$CFG")"; pass
grep -q 'was http://dispatcharr:9191/hdhr' "$T/out" || fail_ "toggle: says from where: $(cat "$T/out")"; pass

# ---- dry run ----
jq -cn --argjson t "$mine" '{TunerHosts:[$t], ListingProviders:[]}' > "$CFG"
WIRE_DRY=1; run; WIRE_DRY=0
[[ "$(writes)" == 0 ]] || fail_ "dry run writes nothing: $(cat "$CALLS")"; pass
grep -q 'would: jellyfin: dispatcharr as a live TV tuner' "$T/out" && grep -q "would: jellyfin: dispatcharr's guide" "$T/out" || fail_ "dry run says both: $(cat "$T/out")"; pass

# ---- failures, said ----
HOLD=1; run; HOLD=
[[ $WIRE_FAILS == 1 ]] && grep -q 'did not hold' "$T/out" || fail_ "a tuner that does not hold: a failure, and the guide not tried: $(cat "$T/out")"; pass
DISC_OK=no; API_WAIT=0; run; DISC_OK=yes; API_WAIT=90
[[ $WIRE_FAILS == 1 && "$(writes)" == 0 ]] && grep -q "dispatcharr's API never became ready" "$T/out" || fail_ "a tuner that does not answer: a failure, nothing written: $(cat "$T/out")"; pass
# just moved by a VPN toggle: running, its nginx answering 502 while the app
# starts — waited for, never read as the tuner's answer (found live 25 Nov 2026)
jq -cn --argjson t "$mine" '{TunerHosts:[$t], ListingProviders:[]}' > "$CFG"
HOST=dispatcharr STARTING=3; run; STARTING=0
[[ $WIRE_FAILS == 0 && "$(tuner Url)" == http://dispatcharr:9191/hdhr ]] && grep -q 'waiting for dispatcharr' "$T/out" \
    || fail_ "502 while it starts: waited for, then wired: $(cat "$T/out")"; pass
RUNNING=no; run; RUNNING=yes
[[ $WIRE_FAILS == 1 && ! -s "$CALLS" ]] && grep -q 'dispatcharr is not running' "$T/out" || fail_ "provider not running: a failure, Jellyfin not asked: $(cat "$T/out")"; pass
profiles jellyfin; run
[[ $WIRE_FAILS == 0 && ! -s "$CALLS" && ! -s "$T/out" ]] || fail_ "no live TV source: nothing, silently: $(cat "$T/out")"; pass

# ---- ErsatzTV, from its own template ----
profiles jellyfin,ersatztv; HOST=ersatztv
jq -cn '{TunerHosts:[], ListingProviders:[]}' > "$CFG"
run
[[ $WIRE_FAILS == 0 ]] || fail_ "ersatztv: no failure: $(cat "$T/out")"; pass
[[ "$(jq -r '.TunerHosts[0].Url' "$CFG")" == http://ersatztv:8409 ]] || fail_ "ersatztv: its tuner at its root: $(cat "$CFG")"; pass
[[ "$(jq -r '.ListingProviders[0].Path' "$CFG")" == http://ersatztv:8409/iptv/xmltv.xml ]] || fail_ "ersatztv: its guide: $(cat "$CFG")"; pass
grep -qx 'http://127.0.0.1:8409/discover.json' "$T/curled" || fail_ "ersatztv: discover.json at its root: $(cat "$T/curled")"; pass

# ---- both: the first in priority order, and said ----
profiles jellyfin,dispatcharr,ersatztv; HOST=dispatcharr
jq -cn '{TunerHosts:[], ListingProviders:[]}' > "$CFG"
run
[[ "$(jq -r '.TunerHosts[0].Url' "$CFG")" == http://dispatcharr:9191/hdhr ]] || fail_ "both: Dispatcharr wired: $(cat "$CFG")"; pass
grep -q 'live-tv: dispatcharr (also enabled: ersatztv' "$T/out" || fail_ "both: the other named: $(cat "$T/out")"; pass

# ---- wire_jellyfin runs it ----
grep -q '^    jf_livetv "\$tok"' services/jellyfin/jellyfin.sh || fail_ "wire_jellyfin must call jf_livetv"; pass

echo "OK livetv: $checks checks"
