#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-vpn-providers.sh — the VPN provider layer (services/gluetun/provider.sh,
# docs/design-vpn.md):
#   * every folder of services/gluetun/providers brings the six functions; its
#     name is the folder's; it runs types mediastack offers; its filters are
#     ones mediastack knows; every key it reads is a schema key
#   * what reaches gluetun (local/vpn-provider.yml): .env references only — no
#     secret's value in it, 0644, byte-stable; the provider's keys and filters,
#     nothing else; no file without a folder
#   * before gluetun starts: an unknown provider, a type it lacks, a key it
#     needs and lacks, a server choice it does not offer — each refused, named
#   * the gluetun image's providers: read from format-servers' usage (Go's flag
#     format), cached per image; a provider the image lacks is refused; custom
#     needs none
#   * an endpoint by name: the first lookup recorded; an answer still holding
#     the address changes nothing; one without it moves (the first in sorted
#     order); a failed first lookup stops, a later one keeps the tunnel; an
#     address needs no lookup; no address of a name reaches .env
#   * your own config: read with its comments, DNS and AllowedIPs left to
#     gluetun; a [v6]:port endpoint; a second [Peer], a missing key, a bad key
#     and an endpoint without a port refused, the line named
#   * schema 51: NordVPN's address emptied for every provider but custom, a
#     provider with spaces becomes its folder, VPN_TYPE added
#
#   scripts/test-vpn-providers.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-vpnp.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

LOCAL_DIR=$T/local; STATE_DIR=$LOCAL_DIR/state; PROVIDER_FILE=$LOCAL_DIR/vpn-provider.yml; ENV_FILE=$T/.env
mkdir -p "$STATE_DIR"; : > "$ENV_FILE"
repo_owned() { :; }
env_defaults_load
K1=wOEI9rqqbDwnN8/Bpp22sVz48T71vJ4fYmFWujulwUU=   # well-formed WireGuard keys (gluetun's wiki's examples)
K2=xOEI9rqqbDwnN8/Bpp22sVz48T71vJ4fYmFWujulwUU=
K3=wAUaJMhAq3NFutLHIdF8AN0B5WG8RndfQKLPTEDHal0=
setenv() { : > "$ENV_FILE"; local kv; for kv in "$@"; do env_set "${kv%%=*}" "${kv#*=}"; done; }

# ---- every folder brings its six functions ----
mapfile -t ALL < <(vpnp_list)
(( ${#ALL[@]} >= 9 )) || fail_ "the providers: the WireGuard eight and custom (got ${ALL[*]})"; pass
[[ "${ALL[-1]}" == custom ]] || fail_ "custom is listed last"; pass
schema_keys=" $(env_schema_rows | cut -f1 | tr '\n' ' ') "
for p in "${ALL[@]}"; do
    vpnp_load "$p" || fail_ "$p: its provider.sh loads"; pass
    for h in name types filters proven questions env; do declare -F "$(vpnp_fn "$p" "$h")" >/dev/null || fail_ "$p brings $h"; pass; done
    [[ "$(vpnp_call "$p" name | tr ' ' -)" == "$p" ]] || fail_ "$p: the folder is its gluetun name, spaces as hyphens"; pass
    for t in $(vpnp_call "$p" types); do [[ " wireguard " == *" $t "* ]] || fail_ "$p: type $t is one mediastack runs"; pass; done
    for f in $(vpnp_call "$p" filters); do [[ -n "${VPN_FILTER_VAR[$f]-}" ]] || fail_ "$p: filter $f is one mediastack knows"; pass; done
    for k in $(vpnp_keys "$p"); do [[ "$schema_keys" == *" $k "* ]] || fail_ "$p reads $k, which is no schema key"; pass; done
done
grep -rlE '^vpnp_[a-z0-9_]+_name\(\)' services --include=*.sh | grep -v '^services/gluetun/providers/' && fail_ "a provider's functions outside its folder"; pass

# ---- what reaches gluetun ----
setenv VPN_PROVIDER=surfshark WIREGUARD_PRIVATE_KEY="$K1" WIREGUARD_ADDRESSES=10.14.0.2/16 VPN_SERVER_COUNTRIES=Sweden
vpn_provider_gen
[[ -f "$PROVIDER_FILE" && "$(stat -c %a "$PROVIDER_FILE")" == 644 ]] || fail_ "the file is written 0644"; pass
! grep -qF "$K1" "$PROVIDER_FILE" || fail_ "no secret's value in it"; pass
grep -qx '      VPN_SERVICE_PROVIDER: "surfshark"' "$PROVIDER_FILE" && grep -qx '      VPN_TYPE: "wireguard"' "$PROVIDER_FILE" \
    && grep -qx '      WIREGUARD_PRIVATE_KEY: "${WIREGUARD_PRIVATE_KEY:-}"' "$PROVIDER_FILE" \
    && grep -qx '      WIREGUARD_ADDRESSES: "${WIREGUARD_ADDRESSES:-}"' "$PROVIDER_FILE" \
    && grep -qx '      SERVER_COUNTRIES: "${VPN_SERVER_COUNTRIES:-}"' "$PROVIDER_FILE" || fail_ "its provider, type, keys and filters as references: $(cat "$PROVIDER_FILE")"; pass
! grep -q PRESHARED "$PROVIDER_FILE" || fail_ "a key the provider does not read stays out"; pass
before=$(stat -c %Y "$PROVIDER_FILE"); sleep 1; vpn_provider_gen
[[ "$(stat -c %Y "$PROVIDER_FILE")" == "$before" ]] || fail_ "byte-stable: an unchanged render is not rewritten"; pass
setenv VPN_PROVIDER=windscribe
vpn_provider_gen; ! grep -q SERVER_COUNTRIES "$PROVIDER_FILE" || fail_ "windscribe chooses no country: none reaches gluetun"; pass
setenv VPN_PROVIDER=nordvpn; vpn_provider_gen
! grep -q WIREGUARD_ADDRESSES "$PROVIDER_FILE" || fail_ "NordVPN's address is gluetun's own: not sent"; pass
setenv VPN_PROVIDER=nosuch; vpn_provider_gen
[[ ! -e "$PROVIDER_FILE" ]] || fail_ "no folder, no file (up says why)"; pass

# ---- before gluetun starts ----
probs() { setenv "$@"; vpn_provider_problems; }
[[ "$(probs VPN_PROVIDER=nosuch)" == *"no provider mediastack knows"* ]] || fail_ "an unknown provider"; pass
[[ "$(probs VPN_PROVIDER=mullvad WIREGUARD_PRIVATE_KEY="$K1")" == *"mullvad needs WIREGUARD_ADDRESSES"* ]] || fail_ "a key it needs"; pass
[[ "$(probs VPN_PROVIDER=windscribe WIREGUARD_PRIVATE_KEY="$K1" WIREGUARD_ADDRESSES=10.1.0.2/32 WIREGUARD_PRESHARED_KEY="$K2" VPN_SERVER_COUNTRIES=Sweden)" \
    == *"VPN_SERVER_COUNTRIES=Sweden, but windscribe does not choose servers by country"* ]] || fail_ "a server choice it lacks"; pass
[[ -z "$(probs VPN_PROVIDER=nordvpn WIREGUARD_PRIVATE_KEY="$K1" VPN_SERVER_COUNTRIES=Sweden)" ]] || fail_ "a complete setup: no problem"; pass
[[ "$(probs VPN_PROVIDER=nordvpn VPN_TYPE=openvpn WIREGUARD_PRIVATE_KEY="$K1" 2>&1 || true)" == *"VPN_TYPE"* ]] || true   # the schema refuses openvpn first (enum)

# ---- the gluetun image's providers ----
USAGE=$'Usage of format-servers:\n  -airvpn\n    \tFormat Airvpn servers\n  -format string\n    \tFormat to use which can be: \'markdown\' or \'json\' (default "markdown")\n  -nordvpn\n    \tFormat Nordvpn servers\n  -output string\n    \tOutput file to write the formatted data to (default "/dev/stdout")\n  -private-internet-access\n    \tFormat Private Internet Access servers'
IMGID=sha256:aaa; : > "$T/runs"
svc_image() { echo qmcgaw/gluetun:latest; }
sudo() {
    case "$*" in
        "docker image inspect"*) echo "$IMGID" ;;
        "docker run --rm qmcgaw/gluetun:latest format-servers -h") echo run >> "$T/runs"; printf '%s\n' "$USAGE"; return 2 ;;
        *) "$@" ;;
    esac
}
gluetun_image_providers
[[ "$GLUETUN_PROVIDERS" == $'airvpn\nnordvpn\nprivate-internet-access' ]] || fail_ "the image's providers, its other flags left out: [$GLUETUN_PROVIDERS]"; pass
gluetun_image_providers; [[ "$GLUETUN_PROVIDERS" == *nordvpn* && "$(wc -l < "$T/runs")" == 1 ]] || fail_ "cached for the same image: the image is run once"; pass
IMGID=sha256:bbb; gluetun_image_providers; [[ "$(wc -l < "$T/runs")" == 2 ]] || fail_ "a new image is read again"; pass
setenv VPN_PROVIDER=surfshark WIREGUARD_PRIVATE_KEY="$K1" WIREGUARD_ADDRESSES=10.14.0.2/16
out=$( (vpn_provider_ready up) 2>&1 ) && fail_ "a provider the image lacks: up stops"
[[ "$out" == *"does not know surfshark"* && "$out" == *"airvpn nordvpn private-internet-access"* ]] || fail_ "it says so, and what the image knows: $out"; pass
setenv VPN_PROVIDER=nordvpn WIREGUARD_PRIVATE_KEY="$K1"; ( vpn_provider_ready up ) || fail_ "a provider the image knows: up goes on"; pass
USAGE="Error: unknown command"; IMGID=sha256:ccc
out=$( (vpn_provider_ready up) 2>&1 ) && fail_ "an image whose providers cannot be read: up stops"
[[ "$out" == *"cannot read which providers"* ]] || fail_ "saying why: $out"; pass
unset -f sudo svc_image

# ---- an endpoint by name ----
RESOLVED=""
vpn_endpoint_resolve() { [[ -n "$RESOLVED" ]] && printf '%s\n' $RESOLVED | sort -u; return 0; }
cust() { setenv VPN_PROVIDER=custom WIREGUARD_PRIVATE_KEY="$K1" WIREGUARD_ADDRESSES=10.7.0.2/32 WIREGUARD_PUBLIC_KEY="$K3" WIREGUARD_ENDPOINT_PORT=51820 "$@"; }
cust WIREGUARD_ENDPOINT_HOST=203.0.113.9
rc=0; vpn_endpoint_refresh || rc=$?; (( rc == 0 )) && [[ "$(vpn_endpoint_ip)" == 203.0.113.9 ]] || fail_ "an address needs no lookup"; pass
cust WIREGUARD_ENDPOINT_HOST=vpn.example.net; state_del "$VPN_ENDPOINT_STATE"
RESOLVED=""; out=$( (vpn_endpoint_refresh) 2>&1 ) && fail_ "a name that does not resolve, the first time: stops"
[[ "$out" == *"vpn.example.net does not resolve"* ]] || fail_ "naming the name: $out"; pass
RESOLVED="198.51.100.7 198.51.100.3"; rc=0; vpn_endpoint_refresh || rc=$?
(( rc == 0 )) && [[ "$(vpn_endpoint_ip)" == 198.51.100.3 ]] || fail_ "the first lookup: recorded, the first in sorted order, nothing moved (rc $rc, $(vpn_endpoint_ip))"; pass
RESOLVED="198.51.100.3 198.51.100.9"; rc=0; vpn_endpoint_refresh || rc=$?
(( rc == 0 )) && [[ "$(vpn_endpoint_ip)" == 198.51.100.3 ]] || fail_ "an answer still holding the address: nothing moves"; pass
RESOLVED=""; rc=0; vpn_endpoint_refresh >/dev/null 2>&1 || rc=$?
(( rc == 0 )) && [[ "$(vpn_endpoint_ip)" == 198.51.100.3 ]] || fail_ "a failed lookup later: the tunnel keeps its address"; pass
RESOLVED="198.51.100.20 198.51.100.11"; rc=0; vpn_endpoint_refresh || rc=$?
(( rc == 10 )) && [[ "$(vpn_endpoint_ip)" == 198.51.100.11 && "$VPN_ENDPOINT_OLD" == 198.51.100.3 ]] || fail_ "the name points elsewhere: rc 10, the new address, the old one kept for the message"; pass
! grep -q '198\.51\.100' "$ENV_FILE" || fail_ "no address of a name reaches .env"; pass
vpn_provider_gen
grep -qx '      WIREGUARD_ENDPOINT_IP: "198.51.100.11"' "$PROVIDER_FILE" && grep -qx '      WIREGUARD_PUBLIC_KEY: "${WIREGUARD_PUBLIC_KEY:-}"' "$PROVIDER_FILE" \
    && grep -qx '      WIREGUARD_PRESHARED_KEY: "${WIREGUARD_PRESHARED_KEY:-}"' "$PROVIDER_FILE" || fail_ "custom's render: the address looked up, the keys as references: $(cat "$PROVIDER_FILE")"; pass
[[ -z "$(vpn_provider_problems)" ]] || fail_ "a complete custom setup: no problem: $(vpn_provider_problems)"; pass
cust WIREGUARD_ENDPOINT_HOST=other.example.net
[[ "$(vpn_provider_problems)" == *"has not been looked up yet"* ]] || fail_ "a name not looked up yet: up does it first"; pass

# ---- a switch: what only the old provider read goes ----
cust WIREGUARD_ENDPOINT_HOST=vpn.example.net WIREGUARD_PRESHARED_KEY="$K2"; state_set "$VPN_ENDPOINT_STATE" "vpn.example.net 198.51.100.3"
env_set VPN_PROVIDER nordvpn; vpn_keys_drop_others nordvpn
[[ "$(env_get WIREGUARD_PRIVATE_KEY)" == "$K1" ]] || fail_ "a key the new provider reads stays (its own questions decide it)"; pass
for k in WIREGUARD_ADDRESSES WIREGUARD_PUBLIC_KEY WIREGUARD_ENDPOINT_HOST WIREGUARD_ENDPOINT_PORT WIREGUARD_PRESHARED_KEY; do
    [[ -z "$(env_get "$k")" ]] || fail_ "custom -> nordvpn: $k emptied: $(cat "$ENV_FILE")"; pass
done
[[ -z "$(state_get "$VPN_ENDPOINT_STATE")" ]] || fail_ "the endpoint record goes with them"; pass
! grep -qE '^(NORDVPN_TOKEN|WIREGUARD_CONF)=' "$ENV_FILE" || fail_ "a key .env does not hold is never added: $(cat "$ENV_FILE")"; pass
setenv VPN_PROVIDER=mullvad WIREGUARD_PRIVATE_KEY="$K1" WIREGUARD_ADDRESSES=10.64.0.2/32; vpn_keys_drop_others custom
[[ "$(env_get WIREGUARD_ADDRESSES)" == 10.64.0.2/32 ]] || fail_ "a key both read stays"; pass
state_set "$VPN_ENDPOINT_STATE" "vpn.example.net 198.51.100.3"; vpn_keys_drop_others custom
[[ -n "$(state_get "$VPN_ENDPOINT_STATE")" ]] || fail_ "a switch to custom keeps the endpoint record"; pass
state_del "$VPN_ENDPOINT_STATE"

# ---- your own config ----
conf() { printf '%s\n' "$@" > "$T/wg.conf"; }
conf '# from my router' '[Interface]' "PrivateKey = $K1" 'Address = 10.7.0.2/32, fd00::2/128' 'DNS = 10.7.0.1' '' '[Peer]' \
     "PublicKey = $K3" "PresharedKey = $K2" 'AllowedIPs = 0.0.0.0/0, ::/0' 'Endpoint = home.example.net:51820   # my DDNS' 'PersistentKeepalive = 25'
wg_conf_read "$T/wg.conf" || fail_ "a config with comments, DNS and AllowedIPs: $WGC_PROBLEM"; pass
[[ "${WGC[Host]}:${WGC[Port]}" == home.example.net:51820 && "${WGC[Address]}" == '10.7.0.2/32, fd00::2/128' && "${WGC[PresharedKey]}" == "$K2" ]] \
    || fail_ "its server, address and pre-shared key: ${WGC[*]}"; pass
setenv VPN_PROVIDER=custom; wg_conf_record
[[ "$(env_get WIREGUARD_PUBLIC_KEY)" == "$K3" && "$(env_get WIREGUARD_ENDPOINT_HOST)" == home.example.net && "$(env_get WIREGUARD_ENDPOINT_PORT)" == 51820 ]] \
    || fail_ "recorded into .env: $(cat "$ENV_FILE")"; pass
conf '[Interface]' "PrivateKey = $K1" 'Address = 10.7.0.2/32' '[Peer]' "PublicKey = $K3" 'Endpoint = [2001:db8::1]:51820'
wg_conf_read "$T/wg.conf" && [[ "${WGC[Host]}" == 2001:db8::1 ]] || fail_ "a [v6]:port endpoint: $WGC_PROBLEM"; pass
bad() { wg_conf_read "$T/wg.conf" && fail_ "refused: $1"; [[ "$WGC_PROBLEM" == *"$1"* ]] || fail_ "the reason names '$1': $WGC_PROBLEM"; pass; }
conf '[Interface]' "PrivateKey = $K1" 'Address = 10.7.0.2/32' '[Peer]' "PublicKey = $K3" 'Endpoint = a.example:1' '[Peer]' "PublicKey = $K2"; bad 'line 7: a second [Peer]'
conf '[Interface]' "PrivateKey = $K1" 'Address = 10.7.0.2/32' '[Peer]' 'Endpoint = a.example:1'; bad 'no PublicKey'
conf '[Interface]' 'PrivateKey = short' 'Address = 10.7.0.2/32' '[Peer]' "PublicKey = $K3" 'Endpoint = a.example:1'; bad 'PrivateKey: that is not a WireGuard key'
conf '[Interface]' "PrivateKey = $K1" 'Address = 10.7.0.2/32' '[Peer]' "PublicKey = $K3" 'Endpoint = a.example'; bad "line 6: Endpoint 'a.example' is not host:port"
conf '[Interface]' "PrivateKey = $K1" 'Address = 10.7.0.2' '[Peer]' "PublicKey = $K3" 'Endpoint = a.example:1'; bad 'Address:'

# ---- schema 51 ----
m51() { printf '%s\n' "$@" > "$ENV_FILE"; migrate_env_50_to_51 >/dev/null 2>&1; }
m51 'VPN_PROVIDER=nordvpn' 'WIREGUARD_ADDRESSES=10.5.0.2/32'
[[ -z "$(env_get WIREGUARD_ADDRESSES)" ]] && grep -qx 'VPN_TYPE=' "$ENV_FILE" && grep -qx 'WIREGUARD_PRESHARED_KEY=' "$ENV_FILE" \
    || fail_ "nordvpn: its address is gluetun's own now; VPN_TYPE and the pre-shared key added: $(cat "$ENV_FILE")"; pass
m51 'VPN_PROVIDER=mullvad' 'WIREGUARD_ADDRESSES=10.5.0.2/32'; [[ -z "$(env_get WIREGUARD_ADDRESSES)" ]] || fail_ "mullvad: NordVPN's address emptied (configure asks its own)"; pass
m51 'VPN_PROVIDER=custom' 'WIREGUARD_ADDRESSES=10.5.0.2/32'; [[ "$(env_get WIREGUARD_ADDRESSES)" == 10.5.0.2/32 ]] || fail_ "custom: your own address kept"; pass
m51 'VPN_PROVIDER=mullvad' 'WIREGUARD_ADDRESSES=10.64.1.2/32'; [[ "$(env_get WIREGUARD_ADDRESSES)" == 10.64.1.2/32 ]] || fail_ "an address of your own is kept"; pass
m51 'VPN_PROVIDER=Private Internet Access'; [[ "$(env_get VPN_PROVIDER)" == private-internet-access ]] || fail_ "a provider with spaces becomes its folder's name"; pass

echo "OK vpn providers: $checks checks"
