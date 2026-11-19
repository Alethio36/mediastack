#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-transmission.sh — Transmission behind the portal (docs/design-logins.md):
#   * its route chains the gate, then transmission-login (mediastack.auth.inject)
#   * transmission-login carries its stored login (HTTP Basic) while the portal
#     guards it (gate_planned), a no-op otherwise; valid YAML either way
#   * Traefik's file gets every enabled service's <svc>_login_middleware
#   * disable authentik: its own login proven to still ask
#   * set-credentials transmission: Traefik's copy regenerated
# Sources the real entrypoint (minus its last line, main "$@"); curl is a stub.
#
#   scripts/test-transmission.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-transmission.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "OK $*"; }; wfail() { WIRE_FAILS=$((WIRE_FAILS + 1)); echo "FAIL $*"; }

# ---- the route: the gate, then its login ----
r=$(edge_route_labels "" transmission torrent 9091 TRANSMISSION gate "" "" true)
grep -qxF 'traefik.http.routers.transmission.middlewares: "mediastack-gate@file,transmission-login@file"' <<<"$r" \
    || fail_ "inject: the gate first, then transmission-login: $r"; pass
r=$(edge_route_labels "" qbittorrent qbit 8085 QBITTORRENT gate "" "" "")
grep -qxF 'traefik.http.routers.qbittorrent.middlewares: "mediastack-gate@file"' <<<"$r" || fail_ "no inject: the gate alone: $r"; pass
r=$(edge_route_labels "" apprise notify 8000 APPRISE gate "" false true)
grep -qxF 'traefik.http.routers.apprise.middlewares: "mediastack-portal-only@file"' <<<"$r" || fail_ "no login of its own wins: portal-only: $r"; pass
r=$(edge_route_labels "" x x 1 X native "" "" true)
! grep -q 'middlewares' <<<"$r" || fail_ "not gated: no middleware, inject or not: $r"; pass
grep -q '"$ownlogin" "$inject")' services/gluetun/vpn.sh && [[ "$(grep -c '"$ownlogin" "$inject")' services/gluetun/vpn.sh)" == 2 ]] \
    || fail_ "vpn_gen passes the label on, on gluetun and on the service itself"; pass

# ---- transmission-login: its login while guarded, a no-op otherwise ----
PLANNED=yes ON=yes
gate_planned() { [[ $PLANNED == yes && "$1" == transmission ]]; }
svc_enabled() { [[ $ON == yes && "$1" == transmission ]]; }
env_get() { case $1 in TRANSMISSION_USER) echo admin ;; TRANSMISSION_PASSWORD) echo s3cretPass16abcd ;; esac; }
y=$(transmission_login_middleware)
want="Basic $(printf 'admin:s3cretPass16abcd' | base64 -w0)"
python3 -I -c 'import sys, yaml; d = yaml.safe_load("m:\n" + sys.argv[1])["m"]["transmission-login"]["headers"]["customRequestHeaders"]["Authorization"]; sys.exit(d != sys.argv[2])' "$y" "$want" \
    || fail_ "guarded: valid YAML carrying its stored login as HTTP Basic: $y"; pass
PLANNED=no; y=$(transmission_login_middleware)
python3 -I -c 'import sys, yaml; d = yaml.safe_load("m:\n" + sys.argv[1])["m"]["transmission-login"]["headers"]; sys.exit("customRequestHeaders" in d or "customResponseHeaders" not in d)' "$y" \
    && ! grep -q 'Authorization' <<<"$y" || fail_ "not guarded: a no-op (a client's own login passes untouched), still defined for its route: $y"; pass
PLANNED=yes ON=no; y=$(transmission_login_middleware)
grep -q 'transmission-login:' <<<"$y" && ! grep -q 'Authorization' <<<"$y" || fail_ "not enabled: a no-op, still defined (its route exists for the whole catalogue): $y"; pass

# ---- Traefik's file: every enabled service's hook ----
o=$( svc_managed() { printf '%s\n' sonarr transmission; }; transmission_login_middleware() { echo HOOK; }; traefik_service_middlewares )
[[ "$o" == HOOK ]] || fail_ "each catalogue service's <svc>_login_middleware, enabled or not, nothing else: $o"; pass
grep -q '^\$(traefik_service_middlewares)$' services/traefik/edge.sh || fail_ "traefik_gen writes them under http.middlewares"; pass

# ---- disable authentik: its own login proven to still ask ----
tg() { ( WIRE_FAILS=0; CODE=$1; transmission_code_anon() { echo "$CODE"; }; transmission_gate_login > "$T/tg" 2>&1; echo "fails=$WIRE_FAILS" ); }
[[ "$(tg 401)" == fails=0 ]] && grep -q 'asks everyone for its login' "$T/tg" || fail_ "401: its login stands: $(cat "$T/tg")"; pass
[[ "$(tg 200)" == fails=1 ]] && grep -q 'answers without a login (HTTP 200)' "$T/tg" || fail_ "200: a failure, never assumed: $(cat "$T/tg")"; pass
[[ "$(tg 000)" == fails=1 ]] || fail_ "unreachable: a failure: $(cat "$T/tg")"; pass

# ---- set-credentials transmission: Traefik's copy follows ----
awk '/^sc_rotate_transmission\(\)/,/^}/' services/transmission/transmission.sh | grep '^        traefik_ensure' >/dev/null \
    || fail_ "set-credentials transmission: Traefik's copy of its login regenerated"; pass

echo "OK transmission: $checks checks"
