#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# pf-sync-live.sh — port forwarding's sync (services/gluetun/portfwd.sh), proven
# on a RUNNING stack (not CI) without a provider that forwards: a made-up port
# goes through the real code into each enabled torrent client by its own login,
# is read back from the client, and the client's own settings are put back.
# .env is never changed: forwarding is switched on for this run alone.
#
#   scripts/pf-sync-live.sh [PORT]     default 51234
#
#   file    gluetun's status file as the sync reads it: one written before
#           gluetun's start is ignored (left from before), one written after
#           gives its port, anything but one port is refused — a scratch
#           file, never gluetun's own
#   sync    for each enabled torrent client in turn as the download client:
#           the port from that file reaches it (vpn_pf_sync), doctor's check
#           agrees, then the client gets back its own port, random-port and
#           UPnP settings
#
# Exit 0 = every check passed. Needs: sudo docker, curl, jq.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
repo=$PWD
port=${1:-51234}
[[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1024 && port <= 65535 )) || { echo "usage: scripts/pf-sync-live.sh [PORT 1024-65535]" >&2; exit 2; }

lib=$(mktemp "$repo/.pf-sync-live.XXXXXX")
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"; rm -f "$lib"
set +E; trap - ERR
[[ -f "$ENV_FILE" ]] || { echo "ERROR no .env — this checks an installed stack" >&2; exit 2; }
[[ "$(env_get ENV_SCHEMA)" == "$SCRIPT_SCHEMA" ]] \
    || { echo "ERROR .env schema $(env_get ENV_SCHEMA) != script $SCRIPT_SCHEMA — run ./mediastack.sh up first" >&2; exit 2; }
RENDERED_JSON=""; render
[[ "$(c_state "$(svc_cname gluetun)")" == running ]] || { echo "ERROR gluetun is not running" >&2; exit 2; }

fails=0 passes=0
pass() { echo "PASS $*"; passes=$((passes + 1)); }
flunk() { echo "FAIL $*"; fails=$((fails + 1)); }

# forwarding on for this run alone, read from a scratch file: .env and gluetun's own file untouched
scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT
vpn_pf_kind() { echo native; }
vpn_pf_file() { echo "$scratch/forwarded_port"; }
vpn_pf_tell() { :; }   # nothing to ops from a test

# ---- the file ----
echo "$port" > "$scratch/forwarded_port"; touch -d '-30 days' "$scratch/forwarded_port"
vpn_pf_read; [[ -z "$VPN_PF_PORT" && "$VPN_PF_WHY" == *"older than gluetun's start"* ]] && pass "a file written before gluetun started is ignored ($VPN_PF_WHY)" || flunk "an old file was taken: [$VPN_PF_PORT] $VPN_PF_WHY"
printf '%s\n%s\n' "$port" 4242 > "$scratch/forwarded_port"
vpn_pf_read; [[ -z "$VPN_PF_PORT" && "$VPN_PF_WHY" == *"not one port"* ]] && pass "two ports refused ($VPN_PF_WHY)" || flunk "two ports: [$VPN_PF_PORT] $VPN_PF_WHY"
: > "$scratch/forwarded_port"
vpn_pf_read; [[ -z "$VPN_PF_PORT" && "$VPN_PF_WHY" == *"empty"* ]] && pass "an empty file is no port ($VPN_PF_WHY)" || flunk "an empty file: [$VPN_PF_PORT] $VPN_PF_WHY"
echo "$port" > "$scratch/forwarded_port"
vpn_pf_read; [[ "$VPN_PF_PORT" == "$port" ]] && pass "a file written since gluetun started gives its port ($port)" || flunk "a fresh file: [$VPN_PF_PORT] $VPN_PF_WHY"

# ---- each client: its settings kept, the port synced and checked, its settings put back ----
saved() { # saved CLIENT -> its own port settings, as JSON
    case "$1" in
        qbittorrent) qb_login "$(env_get QBITTORRENT_USER)" "$(env_get QBITTORRENT_PASSWORD)" >/dev/null && qb_api /app/preferences | jq -c '{listen_port, random_port, upnp}' ;;
        transmission) transmission_rpc session-get '{"fields": ["peer-port", "peer-port-random-on-start", "port-forwarding-enabled"]}' ;;
        deluge) deluge_login "$(env_get DELUGE_PASSWORD)" && deluge_connect && deluge_rpc core.get_config_values '[["listen_ports", "random_port", "upnp", "natpmp"]]' ;;
    esac
}
restore() { # restore CLIENT JSON — its own settings back
    case "$1" in
        qbittorrent) qb_login "$(env_get QBITTORRENT_USER)" "$(env_get QBITTORRENT_PASSWORD)" >/dev/null && qb_api /app/setPreferences "json=$2" >/dev/null ;;
        transmission) transmission_rpc session-set "$2" >/dev/null ;;
        deluge) deluge_login "$(env_get DELUGE_PASSWORD)" && deluge_connect && deluge_rpc core.set_config "[$2]" >/dev/null ;;
    esac
}
clients=()
for s in $(svc_managed_where mediastack.torrent true); do svc_enabled "$s" && clients+=("$s"); done
(( ${#clients[@]} )) || { echo "ERROR no torrent client is enabled" >&2; exit 2; }
for c in "${clients[@]}"; do
    echo "── $c ──"
    before=$(saved "$c") || { flunk "$c: its settings could not be read — $before"; continue; }
    echo "  its own settings: $before"
    out=$( role_pick() { echo "$c"; }; vpn_pf_sync 2>&1 ) || true
    echo "$out" | sed 's/^/  /'
    [[ "$out" == *"$c listens on $port, the port the VPN forwards"* ]] && pass "$c: the sync set port $port" || flunk "$c: the sync did not say it set $port"
    if chk=$("${c}_listen_port" "$port" check); then pass "$c: read back from $c — it listens on $port, random port and UPnP off"
    else flunk "$c: read back — $chk"; fi
    restore "$c" "$before" || flunk "$c: its own settings could not be put back ($before) — set them in its UI"
    after=$(saved "$c") || true
    [[ "$after" == "$before" ]] && pass "$c: its own settings put back" || flunk "$c: after the test it reads $after, before it read $before"
done

echo
echo "pf-sync-live: $passes passed, $fails failed"
(( fails == 0 ))
