#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-portfwd.sh — port forwarding (services/gluetun/portfwd.sh, docs/design-vpn.md slice 4):
#   * the folders: native or static (and "servers" after native) only; PIA and
#     ProtonVPN on their forwarding servers, PrivateVPN anywhere, AirVPN and
#     Windscribe a port you set
#   * what reaches gluetun: nothing while it is off; native: its own status file
#     in its config folder (no command of ours); static: the port opened on the
#     tunnel, as a reference
#   * refused before gluetun starts: forwarding with a provider that has none, a
#     static provider without its port, a port nobody reads, ProtonVPN over
#     OpenVPN without +pmp; a switch of provider takes off what it cannot do
#   * gluetun's file: one port, written since gluetun started — an old one, an
#     empty one, two ports or a word refused, each saying so
#   * the sync: the port into the download client by its own hook; a failure a
#     warning, ops told once, and once when it works again; no port 5 minutes on
#     told once with the provider's hint; forwarding servers narrow the server check
#   * each client's hook: set, read back, its random port and UPnP off; check
#     mode changes nothing
#   * leak-test: in from the tunnel only the forwarded port, nothing without one
#   * configure and the answers file; schema 54
#
#   scripts/test-portfwd.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-portfwd.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"
set +e +E; trap - ERR

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

LOCAL_DIR=$T/local; STATE_DIR=$LOCAL_DIR/state; PROVIDER_FILE=$LOCAL_DIR/vpn-provider.yml; ENV_FILE=$T/.env
mkdir -p "$STATE_DIR" "$T/config/gluetun"; : > "$ENV_FILE"
repo_owned() { :; }
env_defaults_load
K1=wOEI9rqqbDwnN8/Bpp22sVz48T71vJ4fYmFWujulwUU=
setenv() { : > "$ENV_FILE"; local kv; for kv in "CONFIG_ROOT=$T/config" "$@"; do env_set "${kv%%=*}" "${kv#*=}"; done; }

# ---- the folders ----
for p in $(vpnp_list); do
    vpnp_has "$p" portforward || continue
    w=$(vpnp_call "$p" portforward)
    [[ "$w" =~ ^(native( servers)?|static)$ ]] || fail_ "$p: portforward is native, native servers or static ($w)"; pass
done
[[ "$(vpn_pf_providers | paste -sd' ')" == "airvpn private-internet-access privatevpn protonvpn windscribe" ]] || fail_ "the providers that forward: $(vpn_pf_providers | paste -sd' ')"; pass
vpnp_pf_servers_only protonvpn && vpnp_pf_servers_only private-internet-access && ! vpnp_pf_servers_only privatevpn || fail_ "gluetun keeps only forwarding servers for PIA and ProtonVPN, not PrivateVPN"; pass
[[ "$(vpnp_portforward nordvpn)" == "" && "$(vpnp_portforward airvpn)" == static ]] || fail_ "nordvpn forwards none; airvpn a port you set"; pass

# ---- what reaches gluetun ----
setenv VPN_PROVIDER=protonvpn WIREGUARD_PRIVATE_KEY="$K1"; vpn_provider_gen
! grep -qE 'PORT_FORWARD|FIREWALL_VPN_INPUT' "$PROVIDER_FILE" || fail_ "off: nothing of forwarding reaches gluetun: $(cat "$PROVIDER_FILE")"; pass
setenv VPN_PROVIDER=protonvpn WIREGUARD_PRIVATE_KEY="$K1" VPN_PORT_FORWARDING=on; vpn_provider_gen
grep -qx '      VPN_PORT_FORWARDING: "on"' "$PROVIDER_FILE" && grep -qx '      VPN_PORT_FORWARDING_STATUS_FILE: "/gluetun/forwarded_port"' "$PROVIDER_FILE" \
    && ! grep -qE 'UP_COMMAND|DOWN_COMMAND|FIREWALL_VPN_INPUT' "$PROVIDER_FILE" || fail_ "native: gluetun's own status file in its config folder, no command of ours: $(cat "$PROVIDER_FILE")"; pass
setenv VPN_PROVIDER=airvpn WIREGUARD_PRIVATE_KEY="$K1" VPN_PORT_FORWARDING=on VPN_FORWARDED_PORT=40123; vpn_provider_gen
grep -qx '      FIREWALL_VPN_INPUT_PORTS: "${VPN_FORWARDED_PORT:-}"' "$PROVIDER_FILE" && ! grep -q 'VPN_PORT_FORWARDING:' "$PROVIDER_FILE" \
    || fail_ "static: its port opened on the tunnel, as a reference; gluetun's own forwarding off: $(cat "$PROVIDER_FILE")"; pass

# ---- refused before gluetun starts ----
probs() { setenv "$@"; vpn_provider_problems; }
[[ "$(probs VPN_PROVIDER=nordvpn WIREGUARD_PRIVATE_KEY="$K1" VPN_PORT_FORWARDING=on)" == *"mediastack forwards no port with nordvpn (it does with: airvpn, private-internet-access, privatevpn, protonvpn, windscribe)"* ]] || fail_ "forwarding with a provider that has none"; pass
[[ "$(probs VPN_PROVIDER=windscribe WIREGUARD_PRIVATE_KEY="$K1" WIREGUARD_ADDRESSES=10.1.0.2/32 WIREGUARD_PRESHARED_KEY="$K1" VPN_PORT_FORWARDING=on)" == *"windscribe forwards the port you set on its site: put it in VPN_FORWARDED_PORT"* ]] || fail_ "static without its port"; pass
[[ "$(probs VPN_PROVIDER=protonvpn WIREGUARD_PRIVATE_KEY="$K1" VPN_PORT_FORWARDING=on VPN_FORWARDED_PORT=40000)" == *"VPN_FORWARDED_PORT=40000 does nothing here"*"protonvpn arranges its own"* ]] || fail_ "a port nobody reads (native)"; pass
[[ "$(probs VPN_PROVIDER=airvpn WIREGUARD_PRIVATE_KEY="$K1" VPN_FORWARDED_PORT=40000)" == *"forwarding is off"* ]] || fail_ "a port nobody reads (off)"; pass
[[ "$(probs VPN_PROVIDER=protonvpn VPN_TYPE=openvpn OPENVPN_USER=me OPENVPN_PASSWORD=p VPN_PORT_FORWARDING=on)" == *"OpenVPN username ending in +pmp"* ]] || fail_ "ProtonVPN over OpenVPN without +pmp"; pass
[[ -z "$(probs VPN_PROVIDER=protonvpn VPN_TYPE=openvpn OPENVPN_USER=me+pmp OPENVPN_PASSWORD=p VPN_PORT_FORWARDING=on)" ]] || fail_ "with +pmp: no problem"; pass
[[ -z "$(probs VPN_PROVIDER=protonvpn VPN_TYPE=openvpn OPENVPN_USER=me OPENVPN_PASSWORD=p)" ]] || fail_ "+pmp only matters with forwarding on"; pass
setenv VPN_PROVIDER=airvpn VPN_PORT_FORWARDING=on VPN_FORWARDED_PORT=40000; vpn_keys_drop_others nordvpn wireguard
[[ "$(env_get VPN_PORT_FORWARDING)" == off && -z "$(env_get VPN_FORWARDED_PORT)" ]] || fail_ "a switch to a provider without forwarding takes it off, the port too"; pass
setenv VPN_PROVIDER=airvpn VPN_PORT_FORWARDING=on VPN_FORWARDED_PORT=40000; vpn_keys_drop_others protonvpn wireguard
[[ "$(env_get VPN_PORT_FORWARDING)" == on && -z "$(env_get VPN_FORWARDED_PORT)" ]] || fail_ "to a native one: forwarding stays, a port you set goes"; pass

# ---- gluetun's file ----
STARTED=2026-11-24T05:00:00.123456789Z
c_get() { [[ "$2" == .State.StartedAt ]] && echo "$STARTED"; }
svc_cname() { echo "mediastack-$1"; }
sudo() { "$@"; }
pf_file() { printf '%b' "$1" > "$T/config/gluetun/forwarded_port"; touch -d "${2:-2026-11-24T05:01:00Z}" "$T/config/gluetun/forwarded_port"; vpn_pf_read; }
setenv VPN_PROVIDER=protonvpn WIREGUARD_PRIVATE_KEY="$K1" VPN_PORT_FORWARDING=on
rm -f "$T/config/gluetun/forwarded_port"; vpn_pf_read
[[ -z "$VPN_PF_PORT" && "$VPN_PF_WHY" == "gluetun has written no port yet" ]] || fail_ "no file: no port, said ($VPN_PF_WHY)"; pass
pf_file '51413\n'; [[ "$VPN_PF_PORT" == 51413 ]] || fail_ "written since gluetun started: its port ($VPN_PF_PORT / $VPN_PF_WHY)"; pass
pf_file '51413\n' 2026-11-24T04:59:00Z; [[ -z "$VPN_PF_PORT" && "$VPN_PF_WHY" == *"older than gluetun's start"* ]] || fail_ "written before gluetun started: left from before, ignored ($VPN_PF_WHY)"; pass
pf_file ''; [[ -z "$VPN_PF_PORT" && "$VPN_PF_WHY" == *"its file is empty"* ]] || fail_ "empty: forwarding stopped ($VPN_PF_WHY)"; pass
pf_file '51413\n51414\n'; [[ -z "$VPN_PF_PORT" && "$VPN_PF_WHY" == *"not one port"* ]] || fail_ "two ports: refused ($VPN_PF_WHY)"; pass
pf_file 'port\n'; [[ -z "$VPN_PF_PORT" && "$VPN_PF_WHY" == *"'port', not one port"* ]] || fail_ "a word: refused, shown ($VPN_PF_WHY)"; pass
pf_file '99999\n'; [[ -z "$VPN_PF_PORT" ]] || fail_ "out of range: refused"; pass
pf_file '08080\n'; [[ "$VPN_PF_PORT" == 8080 ]] || fail_ "a leading zero is decimal, never octal ($VPN_PF_PORT)"; pass
setenv VPN_PROVIDER=airvpn VPN_PORT_FORWARDING=on VPN_FORWARDED_PORT=40123; vpn_pf_read
[[ "$VPN_PF_PORT" == 40123 ]] || fail_ "static: the port you set ($VPN_PF_PORT)"; pass
setenv VPN_PROVIDER=protonvpn; vpn_pf_read; [[ -z "$VPN_PF_PORT" && "$VPN_PF_WHY" == "port forwarding is off" ]] || fail_ "off: none"; pass

# ---- the sync ----
NOTES=$T/notes; : > "$NOTES"
notify() { echo "$1|$2|$4" >> "$NOTES"; }
gluetun_instance() { echo "abc $STARTED"; }
role_pick() { echo qbittorrent; }
TAKE=ok; LP_CALLS=$T/lp; : > "$LP_CALLS"
real_qlp=$(declare -f qbittorrent_listen_port)
qbittorrent_listen_port() { echo "$*" >> "$LP_CALLS"; [[ "$TAKE" == ok ]] || { echo "its login from .env is refused"; return 1; }; }
setenv VPN_PROVIDER=protonvpn WIREGUARD_PRIVATE_KEY="$K1" VPN_PORT_FORWARDING=on; pf_file '51413\n'
out=$(vpn_pf_sync 2>&1); [[ "$out" == *"qbittorrent listens on 51413"* && "$(cat "$LP_CALLS")" == 51413 && ! -s "$NOTES" ]] || fail_ "the port into the download client, nothing to ops: $out"; pass
TAKE=no; out=$(vpn_pf_sync 2>&1); vpn_pf_sync >/dev/null 2>&1
[[ "$out" == *"qbittorrent did not take port 51413 — its login from .env is refused (tried again in 5 minutes)"* && "$(grep -c 'did not reach qbittorrent|warning' "$NOTES")" == 1 ]] \
    || fail_ "a client that refuses: a warning, ops told once however often it repeats: $out / $(cat "$NOTES")"; pass
TAKE=ok; vpn_pf_sync >/dev/null 2>&1; vpn_pf_sync >/dev/null 2>&1
[[ "$(grep -c 'works again|info' "$NOTES")" == 1 ]] || fail_ "working again: ops told once: $(cat "$NOTES")"; pass
pf_file '51999\n'; : > "$NOTES"; vpn_pf_sync >/dev/null 2>&1
[[ "$(tail -1 "$LP_CALLS")" == 51999 && ! -s "$NOTES" ]] || fail_ "a new port after a reconnect: synced, no news for ops"; pass
# no port: said; five minutes after gluetun's start, ops told once, with the provider's hint
docker() { echo "2026-11-24 ERROR [port forwarding] getting external IPv4 address: connection refused"; }
rm -f "$T/config/gluetun/forwarded_port"; : > "$NOTES"; STARTED=$(date -u -d '-1 minute' +%FT%TZ)
out=$(vpn_pf_sync 2>&1); [[ "$out" == *"gluetun has written no port yet — tried again in 5 minutes"* && ! -s "$NOTES" ]] || fail_ "no port yet: said, nothing to ops: $out"; pass
STARTED=$(date -u -d '-6 minutes' +%FT%TZ); out=$(vpn_pf_sync 2>&1); vpn_pf_sync >/dev/null 2>&1
[[ "$out" == *"forwarded no port 6 minutes after it started"*"NAT-PMP ticked"*"connection refused"* && "$(grep -c 'No port forwarded|warning' "$NOTES")" == 1 ]] \
    || fail_ "still none 5 minutes on: said with ProtonVPN's hint and gluetun's lines, ops told once: $out / $(cat "$NOTES")"; pass
unset -f docker
setenv VPN_PROVIDER=nordvpn WIREGUARD_PRIVATE_KEY="$K1"; : > "$LP_CALLS"
[[ -z "$(vpn_pf_sync 2>&1)" && ! -s "$LP_CALLS" ]] || fail_ "off: the sync does nothing, says nothing"; pass
setenv VPN_PROVIDER=airvpn WIREGUARD_PRIVATE_KEY="$K1" VPN_PORT_FORWARDING=on VPN_FORWARDED_PORT=40123; TAKE=ok; vpn_pf_sync >/dev/null 2>&1
[[ "$(tail -1 "$LP_CALLS")" == 40123 ]] || fail_ "static: the port you set reaches the client"; pass
role_pick() { echo nosuch; }; out=$(vpn_pf_sync 2>&1); [[ "$out" == *"nosuch cannot take a listening port"* ]] || fail_ "a client without the hook: said ($out)"; pass
unset -f role_pick notify gluetun_instance; eval "$real_qlp"
# every torrent client brings its hook (check-registries holds them to it too)
for s in $(grep -l 'mediastack.torrent: "true"' services/*/compose.yml | sed 's|services/||; s|/compose.yml||'); do
    declare -F "${s}_listen_port" >/dev/null || fail_ "$s brings ${s}_listen_port"; pass
done
# forwarding servers narrow the server check, as gluetun does
printf '%s\n' '[{"vpn":"wireguard","country":"Switzerland","city":"Zurich","port_forward":true,"hostname":"ch-pf"},' \
    '{"vpn":"wireguard","country":"Japan","city":"Tokyo","hostname":"jp"}]' > "$T/proton.json"
VPN_SERVERS=$T/proton.json
setenv VPN_PROVIDER=protonvpn WIREGUARD_PRIVATE_KEY="$K1" VPN_SERVER_COUNTRIES=Japan
[[ -z "$(vpn_choices_problems protonvpn)" ]] || fail_ "off: Japan has a server"; pass
setenv VPN_PROVIDER=protonvpn WIREGUARD_PRIVATE_KEY="$K1" VPN_SERVER_COUNTRIES=Japan VPN_PORT_FORWARDING=on
[[ "$(vpn_choices_problems protonvpn)" == *"no country 'Japan' among protonvpn's WireGuard servers with port forwarding — they are: Switzerland" ]] || fail_ "on: only its forwarding servers: $(vpn_choices_problems protonvpn)"; pass

# ---- each client's hook (state in files: the hooks call them inside $( )) ----
vpn_pf_client_ready() { return 0; }; svc_hostport() { echo 9; }
qb_login() { QB_COOKIE=c; }
echo '{"listen_port":6881,"random_port":true,"upnp":true}' > "$T/qbp"
qb_api() { case "$1" in /app/preferences) cat "$T/qbp" ;; /app/setPreferences) jq -c --argjson s "${2#json=}" '. + $s' "$T/qbp" > "$T/qbp.n" && mv "$T/qbp.n" "$T/qbp"; echo "$2" >> "$T/qbset" ;; esac; }
: > "$T/qbset"
out=$(qbittorrent_listen_port 51413 check); [[ $? == 1 && "$out" == *"listens on port 6881 (random true, UPnP true)"* && ! -s "$T/qbset" ]] || fail_ "qbittorrent, check: says, changes nothing ($out)"; pass
qbittorrent_listen_port 51413 && [[ "$(cat "$T/qbp")" == '{"listen_port":51413,"random_port":false,"upnp":false}' ]] || fail_ "qbittorrent: the port set, random and UPnP off, read back ($(cat "$T/qbp"))"; pass
: > "$T/qbset"; qbittorrent_listen_port 51413 && [[ ! -s "$T/qbset" ]] || fail_ "qbittorrent: already so, nothing written"; pass
qb_api() { case "$1" in /app/preferences) echo '{"listen_port":6881,"random_port":false,"upnp":false}' ;; esac; }
out=$(qbittorrent_listen_port 51413); [[ $? == 1 && "$out" == *"reads back port 6881"* ]] || fail_ "qbittorrent: a port that does not stick is said ($out)"; pass
echo '{"peer-port":51413,"peer-port-random-on-start":true,"port-forwarding-enabled":true}' > "$T/trp"
transmission_rpc() { case "$1" in session-get) cat "$T/trp" ;; session-set) jq -c --argjson s "$2" '. + $s' "$T/trp" > "$T/trp.n" && mv "$T/trp.n" "$T/trp"; echo '{}' ;; esac; }
transmission_listen_port 51413 && jq -e '.["peer-port"] == 51413 and .["peer-port-random-on-start"] == false and .["port-forwarding-enabled"] == false' "$T/trp" >/dev/null \
    || fail_ "transmission: the port, random and UPnP/NAT-PMP off ($(cat "$T/trp"))"; pass
deluge_login() { return 0; }; deluge_connect() { return 0; }
echo '{"listen_ports":[6881,6891],"random_port":true,"upnp":true,"natpmp":true}' > "$T/dlp"
deluge_rpc() { case "$1" in core.get_config_values) cat "$T/dlp" ;; core.set_config) jq -c --argjson s "$2" '. + $s[0]' "$T/dlp" > "$T/dlp.n" && mv "$T/dlp.n" "$T/dlp"; echo null ;; esac; }
deluge_listen_port 51413 && [[ "$(cat "$T/dlp")" == '{"listen_ports":[51413,51413],"random_port":false,"upnp":false,"natpmp":false}' ]] || fail_ "deluge: one port, random, UPnP and NAT-PMP off ($(cat "$T/dlp"))"; pass
unset -f vpn_pf_client_ready qb_login qb_api transmission_rpc deluge_login deluge_connect deluge_rpc svc_hostport

# ---- leak-test: in from the tunnel ----
ADDR_OUT='4: eth0    inet 172.31.250.131/24 brd 172.31.250.255 scope global eth0'
sudo() {
    case "$*" in
        *"iptables -S INPUT"*) printf '%s\n' "$IN_RULES" ;;
        *"ip -o -4 addr"*) echo "$ADDR_OUT" ;;
        *) "$@" ;;
    esac
}
IN_BASE=$'-P INPUT DROP\n-A INPUT -i lo -j ACCEPT\n-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT\n-A INPUT -d 172.31.250.0/24 -i eth0 -j ACCEPT'
fwin() { IN_RULES=$1; lt_reset; lt_firewall_in mediastack-gluetun > "$T/out" 2>&1; }
setenv VPN_PROVIDER=nordvpn WIREGUARD_PRIVATE_KEY="$K1"
fwin "$IN_BASE"; [[ $(lt_exit_code) == 0 ]] && grep -q "nothing comes in from the tunnel but replies" "$T/out" || fail_ "gluetun's own inbound rules, no forwarding: PASS — $(cat "$T/out")"; pass
fwin "$IN_BASE"$'\n-A INPUT -i tun0 -p tcp -m tcp --dport 51413 -j ACCEPT'
[[ $(lt_exit_code) == 1 ]] && grep -q "lets traffic in from the tunnel with no port forwarded" "$T/out" || fail_ "a port open on the tunnel with forwarding off: FAIL — $(cat "$T/out")"; pass
fwin "${IN_BASE/-P INPUT DROP/-P INPUT ACCEPT}"; [[ $(lt_exit_code) == 1 ]] || fail_ "inbound policy ACCEPT: FAIL"; pass
fwin "$IN_BASE"$'\n-A INPUT -i tun0 -j ACCEPT'; [[ $(lt_exit_code) == 1 ]] || fail_ "everything in from the tunnel: FAIL"; pass
fwin "$IN_BASE"$'\n-A INPUT -i eth0 -d 192.168.69.0/24 -j ACCEPT'; [[ $(lt_exit_code) == 2 ]] || fail_ "a rule it cannot account for: UNPROVEN"; pass
setenv VPN_PROVIDER=airvpn WIREGUARD_PRIVATE_KEY="$K1" VPN_PORT_FORWARDING=on VPN_FORWARDED_PORT=40123
fwin "$IN_BASE"$'\n-A INPUT -i tun0 -p tcp -m tcp --dport 40123 -j ACCEPT\n-A INPUT -i tun0 -p udp -m udp --dport 40123 -j ACCEPT'
[[ $(lt_exit_code) == 0 ]] && grep -q "only port 40123 (the port the VPN forwards)" "$T/out" || fail_ "the forwarded port, TCP and UDP: PASS — $(cat "$T/out")"; pass
fwin "$IN_BASE"$'\n-A INPUT -i tun0 -p tcp -m tcp --dport 40123 -j ACCEPT\n-A INPUT -i tun0 -p tcp -m tcp --dport 22 -j ACCEPT'
[[ $(lt_exit_code) == 1 ]] && grep -q "beyond the forwarded port 40123" "$T/out" || fail_ "another port beside it: FAIL — $(cat "$T/out")"; pass
fwin "$IN_BASE"; [[ $(lt_exit_code) == 2 ]] && grep -q "port 40123 is forwarded but not open on the tunnel" "$T/out" || fail_ "forwarded and not open: UNPROVEN, no leak — $(cat "$T/out")"; pass
unset -f sudo

# ---- configure and the answers file ----
ask() { REPLY_VAL=${ANS[$AI]:-}; AI=$((AI + 1)); [[ -n "$REPLY_VAL" ]] || REPLY_VAL=$3; }
confirm() { local a=${ANS[$AI]:-}; AI=$((AI + 1)); [[ "$a" == y ]]; }
confirm_yes() { local a=${ANS[$AI]:-}; AI=$((AI + 1)); [[ "$a" != n ]]; }
Q_MODE=full
qa() { ANS=("${@:2}"); AI=0; vpn_ask_portforward "$1" "$(env_get VPN_TYPE)" > "$T/out" 2>&1; }
setenv VPN_PROVIDER=protonvpn VPN_TYPE=openvpn OPENVPN_USER=me OPENVPN_PASSWORD=p
qa protonvpn y; [[ "$(env_get VPN_PORT_FORWARDING)" == on && "$(env_get OPENVPN_USER)" == me+pmp ]] && grep -q "+pmp added" "$T/out" || fail_ "ProtonVPN over OpenVPN: on, +pmp added and said: $(cat "$T/out")"; pass
qa protonvpn ""; [[ "$(env_get VPN_PORT_FORWARDING)" == on && "$(env_get OPENVPN_USER)" == me+pmp ]] || fail_ "on again: Enter keeps it, +pmp not added twice ($(env_get OPENVPN_USER))"; pass
qa protonvpn n; [[ "$(env_get VPN_PORT_FORWARDING)" == off ]] || fail_ "n: off"; pass
setenv VPN_PROVIDER=airvpn
qa airvpn y 80 40123; [[ "$(env_get VPN_PORT_FORWARDING)" == on && "$(env_get VPN_FORWARDED_PORT)" == 40123 ]] && grep -q "'80' is not a port from 1024 to 65535" "$T/out" || fail_ "static: its port asked, a bad one refused: $(cat "$T/out")"; pass
setenv VPN_PROVIDER=nordvpn VPN_PORT_FORWARDING=on; qa nordvpn
[[ "$(env_get VPN_PORT_FORWARDING)" == off && ! -s "$T/out" ]] || fail_ "a provider that forwards none: not asked, off"; pass
Q_MODE=quick; setenv VPN_PROVIDER=protonvpn VPN_PORT_FORWARDING=on; qa protonvpn
[[ "$(env_get VPN_PORT_FORWARDING)" == on ]] && grep -q "Port forwarding: on (recommended)" "$T/out" || fail_ "quick: kept, said"; pass
Q_MODE=full
unset -f ask confirm confirm_yes

# ---- schema 54 ----
printf 'VPN_PROVIDER=nordvpn\n' > "$ENV_FILE"; migrate_env_53_to_54 >/dev/null 2>&1
grep -qx 'VPN_PORT_FORWARDING=off' "$ENV_FILE" && grep -qx 'VPN_FORWARDED_PORT=' "$ENV_FILE" || fail_ "schema 54: forwarding off, no port: $(cat "$ENV_FILE")"; pass
printf 'VPN_PORT_FORWARDING=on\n' > "$ENV_FILE"; migrate_env_53_to_54 >/dev/null 2>&1
[[ "$(grep -c '^VPN_PORT_FORWARDING=' "$ENV_FILE")" == 1 && "$(env_get VPN_PORT_FORWARDING)" == on ]] || fail_ "schema 54: a value already there kept"; pass

echo "OK port forwarding: $checks checks"
