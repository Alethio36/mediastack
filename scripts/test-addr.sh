#!/usr/bin/env bash
# test-addr.sh — app-to-app addresses (svc_addr and friends). wire used to
# write fixed strings (localhost:8000, gluetun:8085, ...) that each assumed a
# network layout; a VPN toggle made them point at nothing (apprise off the VPN
# silently cut every arr's notifications). Proven live, the rule is: target
# behind the VPN -> gluetun:<port>, target outside -> <service>:<port>, from
# any caller. Pins that rule, the drift report, and — statically — that no
# wiring code writes a hard-coded loopback or gluetun address again.
#
#   scripts/test-addr.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-addr.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"

# ENV_FILE and RENDERED_JSON are read by the sourced entrypoint
# shellcheck disable=SC2034
ENV_FILE=$T/.env
# shellcheck disable=SC2034
RENDERED_JSON='{"services":{
  "qbittorrent":{"labels":{"mediastack.vpn":"true","mediastack.port":"8085"}},
  "apprise":{"labels":{"mediastack.vpn":"true","mediastack.port":"8000"}},
  "jellyfin":{"labels":{"mediastack.vpn":"false","mediastack.port":"8096"}},
  "flaresolverr":{"labels":{"mediastack.vpn":"true","mediastack.port":"8191"}},
  "cleanuparr":{"labels":{"mediastack.port":"11011"}}}}'
: > "$ENV_FILE"

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }
eq()    { [[ "$2" == "$3" ]] || fail_ "$1: got '$2' want '$3'"; }

# the rule: the target's effective VPN membership alone decides
eq "vpn'd by default"        "$(svc_addr qbittorrent)" gluetun:8085; pass
eq "outside by default"      "$(svc_addr jellyfin)"    jellyfin:8096; pass
eq "no vpn label = outside"  "$(svc_addr cleanuparr)"  cleanuparr:11011; pass
echo "APPRISE_VPN=false" >> "$ENV_FILE"
eq "toggled off"             "$(svc_addr apprise)"     apprise:8000; pass
echo "JELLYFIN_VPN=true" >> "$ENV_FILE"
eq "toggled on"              "$(svc_addr jellyfin)"    gluetun:8096; pass
eq "host only"               "$(svc_host qbittorrent)" gluetun; pass
eq "port only"               "$(svc_cport flaresolverr)" 8191; pass

# stored addresses normalise to host:port whatever shape the app keeps
eq "url"          "$(addr_of http://localhost:8000)"              localhost:8000; pass
eq "url + slash"  "$(addr_of http://gluetun:8191/)"               gluetun:8191; pass
eq "url + path"   "$(addr_of http://gluetun:8000/notify/x)"       gluetun:8000; pass
eq "bare"         "$(addr_of apprise:8000)"                       apprise:8000; pass

# arr-family entries: fields[] of {name, value}, numbers included
list='[{"name":"qBittorrent (mediastack)","fields":[{"name":"host","value":"localhost"},{"name":"port","value":8085}]},
       {"name":"other","fields":[{"name":"host","value":"x"}]}]'
eq "entry host" "$(arr_entry_field "$list" "qBittorrent (mediastack)" host)" localhost; pass
eq "entry port" "$(arr_entry_field "$list" "qBittorrent (mediastack)" port)" 8085; pass

# drift report: silent when right or unreadable; counted as drift under
# --dry-run/--verify; a WARN (never a failure) on a real run
# WIRE_* are read by the sourced addr_check / w_would
# shellcheck disable=SC2034
WIRE_DRY=1 WIRE_CHANGES=0 WIRE_FAILS=0
out=$(addr_check "x -> apprise" gluetun:8000 gluetun:8000); eq "match is silent" "$out" ""; pass
out=$(addr_check "x -> apprise" "" gluetun:8000); eq "unreadable is silent" "$out" ""; pass
addr_check "x -> apprise" localhost:8000 gluetun:8000 > "$T/out"
[[ $WIRE_CHANGES == 1 ]] && grep -q 'would: x -> apprise: re-point localhost:8000 -> gluetun:8000' "$T/out" \
    || fail_ "dry-run drift must count and say would: $(cat "$T/out") changes=$WIRE_CHANGES"; pass
# shellcheck disable=SC2034
WIRE_DRY=0 WIRE_CHANGES=0
addr_check "x -> apprise" localhost:8000 gluetun:8000 > "$T/out"
[[ $WIRE_CHANGES == 0 && $WIRE_FAILS == 0 ]] && grep -q '^WARN x -> apprise points at localhost:8000' "$T/out" \
    || fail_ "real-run drift must WARN only: $(cat "$T/out")"; pass

# static guard: wiring writes addresses only through svc_addr/svc_host — the
# script's own host-side API helpers (built on svc_hostport) are the exception
if grep -nE 'localhost|127\.0\.0\.1|gluetun:' lib/integrations.sh lib/trash.sh lib/access.sh \
        | grep -v 'svc_hostport' | grep -vE '^[^:]+:[0-9]+:\s*#'; then
    fail_ "a hard-coded app-to-app address is back (above) — use svc_addr / svc_host"
fi; pass

echo "OK addr: $checks checks"
