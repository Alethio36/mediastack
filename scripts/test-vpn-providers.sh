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
#   * OpenVPN (slice 2): every provider gluetun runs it for; its login and
#     protocol as references, a protocol it has no servers for refused, a type
#     switch empties the other tunnel's keys; a certificate or key read from its
#     PEM file (an .ovpn's inline block too), an old RSA key refused with the
#     conversion; your own .ovpn — its first remote, a name looked up, the copy
#     gluetun runs (0600, one remote, at the address) mounted read-only with its
#     hash a label, gone on a switch away; schema 52 adds the keys
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

LOCAL_DIR=$T/local; STATE_DIR=$LOCAL_DIR/state; PROVIDER_FILE=$LOCAL_DIR/vpn-provider.yml; ENV_FILE=$T/.env; CUSTOM_DIR=$T/custom
mkdir -p "$STATE_DIR"; : > "$ENV_FILE"
repo_owned() { :; }
env_defaults_load
K1=wOEI9rqqbDwnN8/Bpp22sVz48T71vJ4fYmFWujulwUU=   # well-formed WireGuard keys (gluetun's wiki's examples)
K2=xOEI9rqqbDwnN8/Bpp22sVz48T71vJ4fYmFWujulwUU=
K3=wAUaJMhAq3NFutLHIdF8AN0B5WG8RndfQKLPTEDHal0=
setenv() { : > "$ENV_FILE"; local kv; for kv in "$@"; do env_set "${kv%%=*}" "${kv#*=}"; done; }

# ---- every folder brings its six functions ----
mapfile -t ALL < <(vpnp_list)
(( ${#ALL[@]} >= 23 )) || fail_ "the providers: gluetun's twenty-two and custom (got ${#ALL[@]}: ${ALL[*]})"; pass
[[ "${ALL[-1]}" == custom ]] || fail_ "custom is listed last"; pass
schema_keys=" $(env_schema_rows | cut -f1 | tr '\n' ' ') "
for p in "${ALL[@]}"; do
    vpnp_load "$p" || fail_ "$p: its provider.sh loads"; pass
    for h in name types filters proven questions env; do declare -F "$(vpnp_fn "$p" "$h")" >/dev/null || fail_ "$p brings $h"; pass; done
    [[ "$(vpnp_call "$p" name | tr ' ' -)" == "$p" ]] || fail_ "$p: the folder is its gluetun name, spaces as hyphens"; pass
    for t in $(vpnp_call "$p" types); do [[ " wireguard openvpn " == *" $t "* ]] || fail_ "$p: type $t is one mediastack runs"; pass; done
    for pr in $(vpnp_protocols "$p"); do [[ " udp tcp " == *" $pr "* ]] || fail_ "$p: protocol $pr"; pass; done
    for t in $(vpnp_call "$p" types); do ! vpnp_type_keys "$p" "$t" | grep -vE '^[A-Z][A-Z0-9_]*$' >/dev/null || fail_ "$p ($t): a key that is no key name (a blank one broke configure live, Nov 2026): [$(vpnp_type_keys "$p" "$t" | paste -sd'|')]"; pass; done
    tk=" $(for t in $(vpnp_call "$p" types); do vpnp_type_keys "$p" "$t"; done | tr '\n' ' ') "
    if [[ -f "services/gluetun/providers/$p/env.tsv" ]]; then
        for k in $(grep -vE '^(#|[[:space:]]*$)' "services/gluetun/providers/$p/env.tsv" | cut -f1); do
            [[ "$tk" == *" $k "* ]] || fail_ "$p: its own key $k is read by none of its types (its keys hook) — the answers file would refuse it"; pass
        done
    fi
    for f in $(vpnp_call "$p" filters); do [[ -n "${VPN_FILTER_VAR[$f]-}" ]] || fail_ "$p: filter $f is one mediastack knows"; pass; done
    for k in $(vpnp_keys "$p"); do [[ "$schema_keys" == *" $k "* ]] || fail_ "$p reads $k, which is no schema key"; pass; done
done
! vpn_all_keys | grep -vE '^[A-Z][A-Z0-9_]*$' >/dev/null || fail_ "every key some provider reads is a key name — configure looks each up in ANSWER"; pass
( declare -gA ANSWER=(); set -e; mapfile -t ks < <(vpn_all_keys); answers_any "${ks[@]}" || true ) 2>"$T/err" && [[ ! -s "$T/err" ]] || fail_ "configure's answers check over every provider key: $(cat "$T/err")"; pass
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
grep -qx '      SERVER_CATEGORIES: "Standard VPN servers"' "$PROVIDER_FILE" || fail_ "NordVPN: standard servers only — a Dedicated IP one refuses this account (found live Nov 2026)"; pass
setenv VPN_PROVIDER=nordvpn VPN_TYPE=openvpn OPENVPN_USER=svcuser OPENVPN_PASSWORD='p@ss$word'; vpn_provider_gen
grep -qx '      VPN_TYPE: "openvpn"' "$PROVIDER_FILE" && grep -qx '      OPENVPN_USER: "${OPENVPN_USER:-}"' "$PROVIDER_FILE" \
    && grep -qx '      OPENVPN_PASSWORD: "${OPENVPN_PASSWORD:-}"' "$PROVIDER_FILE" && grep -qx '      OPENVPN_PROTOCOL: "${OPENVPN_PROTOCOL:-udp}"' "$PROVIDER_FILE" \
    || fail_ "OpenVPN: its login and protocol as references: $(cat "$PROVIDER_FILE")"; pass
! grep -qE 'WIREGUARD|svcuser|p@ss' "$PROVIDER_FILE" || fail_ "OpenVPN: no WireGuard key, no login's value"; pass
grep -qx '      SERVER_CATEGORIES: "Standard VPN servers"' "$PROVIDER_FILE" || fail_ "NordVPN over OpenVPN: standard servers only too"; pass
! grep -q 'volumes:' "$PROVIDER_FILE" || fail_ "a provider without files mounts nothing"; pass
setenv VPN_PROVIDER=nosuch; vpn_provider_gen
[[ ! -e "$PROVIDER_FILE" ]] || fail_ "no folder, no file (up says why)"; pass

# ---- before gluetun starts ----
probs() { setenv "$@"; vpn_provider_problems; }
[[ "$(probs VPN_PROVIDER=nosuch)" == *"no provider mediastack knows"* ]] || fail_ "an unknown provider"; pass
[[ "$(probs VPN_PROVIDER=mullvad WIREGUARD_PRIVATE_KEY="$K1")" == *"mullvad needs WIREGUARD_ADDRESSES"* ]] || fail_ "a key it needs"; pass
[[ "$(probs VPN_PROVIDER=windscribe WIREGUARD_PRIVATE_KEY="$K1" WIREGUARD_ADDRESSES=10.1.0.2/32 WIREGUARD_PRESHARED_KEY="$K2" VPN_SERVER_COUNTRIES=Sweden)" \
    == *"VPN_SERVER_COUNTRIES=Sweden, but windscribe does not choose servers by country"* ]] || fail_ "a server choice it lacks"; pass
[[ -z "$(probs VPN_PROVIDER=nordvpn WIREGUARD_PRIVATE_KEY="$K1" VPN_SERVER_COUNTRIES=Sweden)" ]] || fail_ "a complete setup: no problem"; pass
[[ "$(probs VPN_PROVIDER=mullvad VPN_TYPE=openvpn)" == *"VPN_TYPE=openvpn: mediastack runs mullvad with wireguard only"* ]] || fail_ "a type the provider lacks"; pass
[[ "$(probs VPN_PROVIDER=nordvpn VPN_TYPE=openvpn OPENVPN_USER=u)" == *"nordvpn needs OPENVPN_PASSWORD"* ]] || fail_ "OpenVPN: its login, in full"; pass
[[ -z "$(probs VPN_PROVIDER=nordvpn VPN_TYPE=openvpn OPENVPN_USER=u OPENVPN_PASSWORD=p OPENVPN_PROTOCOL=tcp)" ]] || fail_ "nordvpn over TCP: no problem"; pass
[[ "$(probs VPN_PROVIDER=expressvpn VPN_TYPE=openvpn OPENVPN_USER=u OPENVPN_PASSWORD=p OPENVPN_PROTOCOL=tcp)" == *"OPENVPN_PROTOCOL=tcp, but expressvpn has OpenVPN servers over udp only"* ]] \
    || fail_ "a protocol the provider has no servers for"; pass
[[ -z "$(probs VPN_PROVIDER=ivpn VPN_TYPE=openvpn OPENVPN_USER=i-AB12-CD34-EF56)" ]] || fail_ "ivpn: an account ID needs no password"; pass
[[ "$(probs VPN_PROVIDER=ivpn VPN_TYPE=openvpn OPENVPN_USER=me@example.com)" == *"ivpn needs OPENVPN_PASSWORD"* ]] || fail_ "ivpn: an email needs its password"; pass
[[ "$(probs VPN_PROVIDER=cyberghost VPN_TYPE=openvpn OPENVPN_USER=u OPENVPN_PASSWORD=p)" == *"cyberghost needs OPENVPN_CERT"*"cyberghost needs OPENVPN_KEY"* ]] \
    || fail_ "a provider with a client certificate: both needed"; pass

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
env_set VPN_PROVIDER nordvpn; vpn_keys_drop_others nordvpn wireguard
[[ "$(env_get WIREGUARD_PRIVATE_KEY)" == "$K1" ]] || fail_ "a key the new provider reads stays (its own questions decide it)"; pass
for k in WIREGUARD_ADDRESSES WIREGUARD_PUBLIC_KEY WIREGUARD_ENDPOINT_HOST WIREGUARD_ENDPOINT_PORT WIREGUARD_PRESHARED_KEY; do
    [[ -z "$(env_get "$k")" ]] || fail_ "custom -> nordvpn: $k emptied: $(cat "$ENV_FILE")"; pass
done
[[ -z "$(state_get "$VPN_ENDPOINT_STATE")" ]] || fail_ "the endpoint record goes with them"; pass
! grep -qE '^(NORDVPN_TOKEN|WIREGUARD_CONF)=' "$ENV_FILE" || fail_ "a key .env does not hold is never added: $(cat "$ENV_FILE")"; pass
setenv VPN_PROVIDER=mullvad WIREGUARD_PRIVATE_KEY="$K1" WIREGUARD_ADDRESSES=10.64.0.2/32; vpn_keys_drop_others custom wireguard
[[ "$(env_get WIREGUARD_ADDRESSES)" == 10.64.0.2/32 ]] || fail_ "a key both read stays"; pass
state_set "$VPN_ENDPOINT_STATE" "vpn.example.net 198.51.100.3"; vpn_keys_drop_others custom wireguard
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

# ---- a switch of tunnel: the other tunnel's keys go ----
setenv VPN_PROVIDER=nordvpn VPN_TYPE=openvpn WIREGUARD_PRIVATE_KEY="$K1" OPENVPN_USER=u OPENVPN_PASSWORD=p
vpn_keys_drop_others nordvpn openvpn
[[ -z "$(env_get WIREGUARD_PRIVATE_KEY)" && "$(env_get OPENVPN_USER)" == u ]] || fail_ "wireguard -> openvpn: the WireGuard key emptied, the login kept: $(cat "$ENV_FILE")"; pass
setenv VPN_PROVIDER=cyberghost VPN_TYPE=openvpn OPENVPN_USER=u OPENVPN_CERT=AAAA OPENVPN_KEY=BBBB; vpn_keys_drop_others protonvpn openvpn
[[ "$(env_get OPENVPN_USER)" == u && -z "$(env_get OPENVPN_CERT)" && -z "$(env_get OPENVPN_KEY)" ]] || fail_ "cyberghost -> protonvpn: the login stays, its certificate and key go: $(cat "$ENV_FILE")"; pass

# ---- a certificate or key, from its PEM file ----
printf '%s\n' 'client' 'remote 1.2.3.4 1194' '<cert>' '-----BEGIN CERTIFICATE-----' 'MIIBszCCAVmgAwIBAgIU' '  QUJDRA==  ' '-----END CERTIFICATE-----' '</cert>' \
    '<key>' '-----BEGIN PRIVATE KEY-----' 'MIGHAgEAMBMGByqGSM49' 'AgEGCCqGSM49AwEHBG0w' '-----END PRIVATE KEY-----' '</key>' > "$T/p.ovpn"
[[ "$(pem_body "$T/p.ovpn" CERTIFICATE)" == MIIBszCCAVmgAwIBAgIUQUJDRA== ]] || fail_ "an .ovpn's inline certificate, one line, spaces gone: $(pem_body "$T/p.ovpn" CERTIFICATE)"; pass
[[ "$(pem_body "$T/p.ovpn" "PRIVATE KEY")" == MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0w ]] || fail_ "its key"; pass
printf '%s\n' '-----BEGIN RSA PRIVATE KEY-----' 'MIIEowIBAAKCAQEA' '-----END RSA PRIVATE KEY-----' > "$T/rsa.key"
! why=$(pem_body "$T/rsa.key" "PRIVATE KEY") && [[ "$why" == *"openssl pkcs8 -topk8 -nocrypt"* ]] || fail_ "an old RSA key: refused with the conversion ($why)"; pass
! why=$(pem_body "$T/rsa.key" CERTIFICATE) && [[ "$why" == *"no '-----BEGIN CERTIFICATE-----' block"* ]] || fail_ "no such block: named"; pass
[[ -n "$(pem_b64_problem 'not base64!')" && -z "$(pem_b64_problem MIIBszCC)" ]] || fail_ "the answers file's one-line form is checked"; pass

# ---- your own OpenVPN config ----
mkdir -p "$CUSTOM_DIR/vpn"
ovpn() { printf '%s\n' "$@" > "$T/my.ovpn"; }
ovpn 'client' 'dev tun' '# my server' 'remote vpn.example.net 1194 udp' 'remote 198.51.100.50 443 tcp' 'auth-user-pass' '<ca>' '-----BEGIN CERTIFICATE-----' 'remote inside a block' 'AAAA' '-----END CERTIFICATE-----' '</ca>' 'verb 3'
ovpn_read "$T/my.ovpn" || fail_ "an .ovpn with two remotes and an inline block: $OVPN_PROBLEM"; pass
[[ "${OVPN[Host]} ${OVPN[Port]} ${OVPN[Proto]} ${OVPN[Auth]}" == "vpn.example.net 1194 udp 1" ]] || fail_ "its first remote and its login: ${OVPN[*]}"; pass
ovpn 'client' 'proto tcp-client' 'remote 203.0.113.5'; ovpn_read "$T/my.ovpn" && [[ "${OVPN[Port]} ${OVPN[Proto]} ${OVPN[Auth]}" == "443 tcp 0" ]] || fail_ "proto from its own line, gluetun's TCP port default, no login: ${OVPN[*]}"; pass
ovpnbad() { ovpn_read "$T/my.ovpn" && fail_ "refused: $1"; [[ "$OVPN_PROBLEM" == *"$1"* ]] || fail_ "the reason names '$1': $OVPN_PROBLEM"; pass; }
ovpn 'client' 'dev tun'; ovpnbad 'no remote line'
ovpn 'client' '<connection>' 'remote a.example 1194' '</connection>'; ovpnbad 'line 2: a <connection> block'
ovpn 'client' 'remote a.example 1194 sctp'; ovpnbad "proto 'sctp'"
ovpn 'client' 'remote bad_host! 1194'; ovpnbad 'remote:'
ovpn 'client' 'dev tun' 'remote vpn.example.net 1194 udp' 'remote 198.51.100.50 443 tcp' 'auth-user-pass' '<ca>' 'remote inside a block' '</ca>'
ovpn_take "$T/my.ovpn" || fail_ "taken in: $OVPN_PROBLEM"
[[ "$(stat -c %a "$CUSTOM_DIR/vpn/openvpn.ovpn")" == 600 ]] && cmp -s "$T/my.ovpn" "$CUSTOM_DIR/vpn/openvpn.ovpn" || fail_ "kept as custom/vpn/openvpn.ovpn, 0600, unchanged"; pass
setenv VPN_PROVIDER=custom VPN_TYPE=openvpn OPENVPN_USER=u OPENVPN_PASSWORD=p; state_del "$VPN_ENDPOINT_STATE"
[[ "$(vpn_endpoint_host)" == vpn.example.net ]] || fail_ "its endpoint: the file's first remote"; pass
[[ "$(vpn_provider_problems)" == *"vpn.example.net has not been looked up yet"* ]] || fail_ "a name not looked up yet: up does it first ($(vpn_provider_problems))"; pass
RESOLVED="198.51.100.21"; vpn_endpoint_refresh; vpn_provider_gen
run=$LOCAL_DIR/vpn-files/custom.ovpn
[[ "$(stat -c %a "$run")" == 600 ]] && grep -qx 'remote 198.51.100.21 1194 udp' "$run" && ! grep -qE 'vpn\.example\.net|198\.51\.100\.50' "$run" && grep -qx 'remote inside a block' "$run" \
    && grep -qx 'auth-user-pass' "$run" || fail_ "the copy gluetun runs: 0600, one remote at the address, blocks verbatim: $(cat "$run")"; pass
grep -qx '      OPENVPN_CUSTOM_CONFIG: "/mediastack/vpn.ovpn"' "$PROVIDER_FILE" && grep -qxF "      - \"$run:/mediastack/vpn.ovpn:ro\"" "$PROVIDER_FILE" \
    && grep -q '^      mediastack.vpn-files: "[0-9a-f]\{16\}"$' "$PROVIDER_FILE" && ! grep -q OPENVPN_PROTOCOL "$PROVIDER_FILE" \
    || fail_ "custom OpenVPN: the copy mounted read-only, its hash a label, no protocol (the file says it): $(cat "$PROVIDER_FILE")"; pass
[[ -z "$(vpn_provider_problems)" ]] || fail_ "a complete custom OpenVPN setup: no problem: $(vpn_provider_problems)"; pass
h1=$(grep vpn-files: "$PROVIDER_FILE"); before=$(stat -c %Y "$PROVIDER_FILE"); sleep 1; vpn_provider_gen
[[ "$(stat -c %Y "$PROVIDER_FILE")" == "$before" ]] || fail_ "byte-stable: the same file and address render the same"; pass
echo 'verb 4' >> "$CUSTOM_DIR/vpn/openvpn.ovpn"; vpn_provider_gen
[[ "$(grep vpn-files: "$PROVIDER_FILE")" != "$h1" ]] || fail_ "an edited .ovpn changes the label: compose recreates gluetun (through the gate)"; pass
RESOLVED="198.51.100.30"; rc=0; vpn_endpoint_refresh || rc=$?; vpn_provider_gen
(( rc == 10 )) && grep -qx 'remote 198.51.100.30 1194 udp' "$run" || fail_ "the name moving: the copy follows (rc $rc)"; pass
setenv VPN_PROVIDER=custom VPN_TYPE=openvpn OPENVPN_USER=; [[ "$(vpn_provider_problems)" == *"asks for a login (auth-user-pass) and OPENVPN_USER is empty"* ]] || fail_ "a file that asks for a login: its user needed"; pass
setenv VPN_PROVIDER=nordvpn VPN_TYPE=openvpn OPENVPN_USER=u OPENVPN_PASSWORD=p; vpn_provider_gen
[[ ! -e "$run" ]] || fail_ "a switch away: the copy (your keys) is removed from local/"; pass
[[ -f "$CUSTOM_DIR/vpn/openvpn.ovpn" ]] || fail_ "yours stays"; pass
rm -rf "$CUSTOM_DIR/vpn"; setenv VPN_PROVIDER=custom VPN_TYPE=openvpn
[[ "$(vpn_provider_problems)" == *"needs your config at custom/vpn/openvpn.ovpn"* ]] || fail_ "no .ovpn: named"; pass

# ---- schema 52 ----
printf 'VPN_PROVIDER=nordvpn\nOPENVPN_USER=kept\n' > "$ENV_FILE"; migrate_env_51_to_52 >/dev/null 2>&1
grep -qx 'OPENVPN_PROTOCOL=' "$ENV_FILE" && grep -qx 'OPENVPN_KEY_PASSPHRASE=' "$ENV_FILE" && [[ "$(env_get OPENVPN_USER)" == kept && "$(grep -c '^OPENVPN_USER=' "$ENV_FILE")" == 1 ]] \
    || fail_ "schema 52: OpenVPN's keys added empty, a value already there kept: $(cat "$ENV_FILE")"; pass

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
