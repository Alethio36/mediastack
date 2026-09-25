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
  "cleanuparr":{"labels":{"mediastack.port":"11011"}},
  "radarr":{"labels":{"mediastack.vpn":"true","mediastack.port":"7878"}},
  "prowlarr":{"labels":{"mediastack.vpn":"true","mediastack.port":"9696"}}}}'
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

# addr_stale: only mediastack's own addresses are claimed
stale() { addr_stale "t" "$@" >/dev/null; }
echo "APPRISE_VPN=true" >> "$ENV_FILE"          # apprise back behind the VPN: want gluetun:8000
stale apprise gluetun:8000 && fail_ "already right must not be stale"; pass
stale apprise ""            && fail_ "unreadable must not be stale"; pass
for ours in localhost:8000 127.0.0.1:8000 apprise:8000; do
    stale apprise "$ours" || fail_ "'$ours' is a mediastack address for apprise — must be stale"
done; pass
for foreign in nas.lan:8000 localhost:9999 10.0.0.5:8000; do
    stale apprise "$foreign" && fail_ "'$foreign' was set by hand — must be left alone"
done; pass
grep -q "yours: left alone" <<<"$(addr_stale "x -> apprise" apprise nas.lan:8000)" || fail_ "a foreign address must be reported"; pass

# addr_repoint: dry-run says would and runs nothing; a real run acts and reports
# WIRE_* are read by the sourced addr_repoint / w_would
# shellcheck disable=SC2034
WIRE_DRY=1 WIRE_CHANGES=0 WIRE_FAILS=0
addr_repoint "x -> apprise" localhost:8000 gluetun:8000 -- touch "$T/ran" > "$T/out"
[[ ! -e "$T/ran" && $WIRE_CHANGES == 1 ]] && grep -q 'would: x -> apprise: re-point localhost:8000 -> gluetun:8000' "$T/out" \
    || fail_ "dry-run must only say would: $(cat "$T/out")"; pass
# shellcheck disable=SC2034
WIRE_DRY=0
addr_repoint "x -> apprise" localhost:8000 gluetun:8000 -- touch "$T/ran" > "$T/out"
[[ -e "$T/ran" ]] && grep -q '^OK x -> apprise: re-pointed to gluetun:8000' "$T/out" || fail_ "real run must act: $(cat "$T/out")"; pass
addr_repoint "x -> apprise" localhost:8000 gluetun:8000 -- false > "$T/out"
[[ $WIRE_FAILS == 1 ]] && grep -q 'FAIL x -> apprise: re-point to gluetun:8000 rejected' "$T/out" || fail_ "a rejected re-point must FAIL: $(cat "$T/out")"; pass

multi() { printf '[\n  {\n    "propertyName": "Host",\n    "errorMessage": "Unable to connect"\n  }\n]\n'; return 1; }
addr_repoint "x -> qbittorrent" localhost:8085 gluetun:8085 -- multi > "$T/out"
# the notice line + ONE FAIL line carrying the whole reply; no stray JSON lines
! grep -qvE '^(:: |FAIL )' "$T/out" && grep -q '^FAIL .*"errorMessage": "Unable to connect"' "$T/out" \
    || fail_ "a multi-line rejection must come out whole, on one line: $(cat "$T/out")"; pass

# arr_repoint: PUT the entry back with ONLY the named fields changed
api() { printf '%s\n%s\n' "$1 $2" "$4" > "$T/put"; }
dcs='[{"id":3,"name":"other","fields":[{"name":"host","value":"x"}]},
      {"id":7,"name":"qBittorrent (mediastack)","fields":[{"name":"host","value":"localhost"},{"name":"port","value":8085},
        {"name":"password","value":"********"},{"name":"tvCategory","value":"tv"}]}]'
arr_repoint http://h/api/v3 k downloadclient "$dcs" "qBittorrent (mediastack)" host=gluetun port=8085
put=$(sed -n 2p "$T/put")
eq "PUT target" "$(sed -n 1p "$T/put")" "PUT http://h/api/v3/downloadclient/7"; pass
eq "host changed"         "$(jq -r '.fields[] | select(.name=="host") | .value' <<<"$put")" gluetun; pass
eq "port stays a number"  "$(jq -r '.fields[] | select(.name=="port") | .value | type' <<<"$put")" number; pass
eq "masked secret kept"   "$(jq -r '.fields[] | select(.name=="password") | .value' <<<"$put")" '********'; pass
eq "other field kept"     "$(jq -r '.fields[] | select(.name=="tvCategory") | .value' <<<"$put")" tv; pass

# credentials re-sent from .env replace the mask (repairs a stale password)
arr_repoint http://h/api/v3 k downloadclient "$dcs" "qBittorrent (mediastack)" host=gluetun password=s3cret
eq "re-sent password replaces the mask" "$(sed -n 2p "$T/put" | jq -r '.fields[] | select(.name=="password") | .value')" s3cret; pass

# qbit_login_fields: login re-sent for a login entry; nothing for an API-key entry
# (Sonarr/Radarr/Prowlarr reject an entry holding both)
printf 'QBITTORRENT_USER=admin\nQBITTORRENT_PASSWORD=pw\n' >> "$ENV_FILE"
lg='[{"name":"q","fields":[{"name":"apiKey","value":""},{"name":"username","value":"admin"}]}]'
kk='[{"name":"q","fields":[{"name":"apiKey","value":"********"},{"name":"username","value":""}]}]'
old='[{"name":"q","fields":[{"name":"username","value":"admin"}]}]'
eq "login entry"           "$(qbit_login_fields "$lg" q | tr '\n' ' ')" "username=admin password=pw "; pass
eq "pre-key app (no field)" "$(qbit_login_fields "$old" q | tr '\n' ' ')" "username=admin password=pw "; pass
eq "API-key entry"         "$(qbit_login_fields "$kk" q)" ""; pass

# prowlarr_app_repoint: a hand-set direction survives a re-point of the other
apps='[{"id":4,"name":"radarr (mediastack)","fields":[{"name":"baseUrl","value":"http://nas.lan:7878"},
        {"name":"prowlarrUrl","value":"http://127.0.0.1:9696"},{"name":"apiKey","value":"********"}]}]'
rm -f "$T/put"
prowlarr_app_repoint radarr "radarr (mediastack)" "$apps" http://h k >/dev/null
put=$(sed -n 2p "$T/put")
eq "stale direction re-pointed" "$(jq -r '.fields[] | select(.name=="prowlarrUrl") | .value' <<<"$put")" http://gluetun:9696; pass
eq "hand-set direction kept"    "$(jq -r '.fields[] | select(.name=="baseUrl") | .value' <<<"$put")" http://nas.lan:7878; pass

# static guard: wiring writes addresses only through svc_addr/svc_host — the
# exceptions are the script's own host-side API helpers (built on svc_hostport)
# and addr_stale's recogniser for the old forms it re-points
if grep -nE 'localhost|127\.0\.0\.1|gluetun:' lib/integrations.sh lib/trash.sh lib/access.sh \
        | grep -v 'svc_hostport' | grep -vE '^[^:]+:[0-9]+:\s*#' \
        | grep -vF '=~ ^(localhost|127\.0\.0\.1|gluetun|'; then   # addr_stale's recogniser for old addresses
    fail_ "a hard-coded app-to-app address is back (above) — use svc_addr / svc_host"
fi; pass

# static guard: an app API read whose failure is swallowed must say why that is
# harmless there. A refused read that looks like "nothing configured" created
# duplicates (and skipped a password rotation) — those reads now fail loud.
if grep -nE '(api|cup_api|seerr_api|jf_api) GET' mediastack.sh lib/*.sh | grep '|| true' | grep -v '# soft read:'; then
    fail_ "an API read swallows its failure without a '# soft read: <why>' reason (above) — fail loud, or say why it is harmless"
fi; pass

echo "OK addr: $checks checks"
