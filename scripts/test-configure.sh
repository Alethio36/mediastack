#!/usr/bin/env bash
# test-configure.sh — configure's questions, driven through stdin:
#   * a .env configure just created holds the example's preset, not a choice:
#     no "keep current" in Services or Accounts
#   * Traefik and npm are two front doors: "everything" asks which (Traefik
#     the default), the portal keeps Traefik without asking, and the portal
#     brings Traefik into a set that lacks it
#   * the hardlink check only compares a download folder that exists
#   * "everything" asks for one download client or all of them, and leaves out
#     a service its own command sets up (the panel) — enable refuses it, up
#     refuses it half-installed
#   * a typo is asked again, never fatal; the portal needs a name (its own
#     question, authentik_questions); input that
#     ends mid-question stops configure instead of asking forever
#   * the VPN is asked about only when something runs in it; secrets are read
#     hidden; the NordVPN token reaches curl on stdin, never on its command line;
#     a provider is a folder, chosen by name or number; a new provider is not
#     offered the old one's key; a WireGuard key is checked
#   * a blank tunnel token turns the tunnel off; enable refuses it without one
#   * the Traefik dashboard's login asks nothing at up (it is a stack login)
#   * the panel is asked for, not installed: configure installs it after
# The entrypoint is sourced (minus main "$@"); the rendered catalogue is a
# small fixture, so no Docker is needed.
#
#   scripts/test-configure.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
lib=$(mktemp .test-configure.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"
set +e +E; trap - ERR   # each check reads its own status
ENV_FILE=$T/.env
# shellcheck disable=SC2034  # read by state_set (the panel's answer)
STATE_DIR=$T/state

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; [[ -f "$T/out" ]] && { echo "--- output:" >&2; cat "$T/out" >&2; }; exit 1; }
explain() { printf '%s\n' "$@"; }; hr() { :; }
render() { :; }; repo_owned() { :; }
# shellcheck disable=SC2034  # read by the sourced entrypoint's svc_* helpers
RENDERED_JSON='{"services":{
  "gluetun":     {"labels":{"mediastack.managed":"true","mediastack.preset":"standard","mediastack.desc":"VPN"}},
  "qbittorrent": {"labels":{"mediastack.managed":"true","mediastack.preset":"standard","mediastack.desc":"torrents"},"depends_on":{"gluetun":{}}},
  "deluge":      {"labels":{"mediastack.managed":"true","mediastack.desc":"torrents"},"depends_on":{"gluetun":{}}},
  "transmission":{"labels":{"mediastack.managed":"true","mediastack.desc":"torrents"},"depends_on":{"gluetun":{}}},
  "olivetin":    {"labels":{"mediastack.managed":"true","mediastack.desc":"web panel","mediastack.installer":"frontdoor-install"}},
  "sonarr":      {"labels":{"mediastack.managed":"true","mediastack.preset":"standard","mediastack.desc":"series"}},
  "radarr":      {"labels":{"mediastack.managed":"true","mediastack.preset":"standard","mediastack.desc":"films"}},
  "prowlarr":    {"labels":{"mediastack.managed":"true","mediastack.preset":"standard","mediastack.desc":"indexers"}},
  "jellyfin":    {"labels":{"mediastack.managed":"true","mediastack.preset":"standard","mediastack.desc":"media"}},
  "meilisearch": {"labels":{"mediastack.managed":"true","mediastack.preset":"standard","mediastack.desc":"index"}},
  "jellysearch": {"labels":{"mediastack.managed":"true","mediastack.preset":"standard","mediastack.desc":"search"},"depends_on":{"meilisearch":{}}},
  "seerr":       {"labels":{"mediastack.managed":"true","mediastack.preset":"standard","mediastack.desc":"requests"}},
  "traefik":     {"labels":{"mediastack.managed":"true","mediastack.desc":"https","mediastack.conflicts":"npm"}},
  "npm":         {"labels":{"mediastack.managed":"true","mediastack.desc":"gui proxy","mediastack.conflicts":"traefik"}},
  "authentik":   {"labels":{"mediastack.managed":"true","mediastack.desc":"portal","mediastack.conflicts":"wizarr"}},
  "wizarr":      {"labels":{"mediastack.managed":"true","mediastack.desc":"invites","mediastack.conflicts":"authentik"}},
  "cloudflared": {"labels":{"mediastack.managed":"true","mediastack.desc":"tunnel"}}}}'
PRESET=gluetun,qbittorrent,sonarr,radarr,prowlarr,jellyfin,meilisearch,jellysearch,seerr
profiles() { env_get COMPOSE_PROFILES | tr ',' ' '; }
has()      { [[ " $(profiles) " == *" $1 "* ]]; }

# services STDIN [FRESH] [PROFILES] — run the Services + Accounts step on a .env holding PROFILES (the preset)
services() {
    printf 'COMPOSE_PROFILES=%s\nPORTAL_TITLE=Mediastack\n' "${3:-$PRESET}" > "$ENV_FILE"   # as .env.example ships it
    # shellcheck disable=SC2034  # read by _configure_services
    CONFIGURE_FRESH=${2:-0}
    printf '%b' "$1" | _configure_services > "$T/out" 2>&1
}

# ---- a fresh .env holds no choice ----
services '\n3\n\n' 1 || fail_ "fresh: Enter + portal runs"
! grep -q 'keep current' "$T/out" || fail_ "a fresh .env offers nothing to keep"; pass
for s in ${PRESET//,/ }; do has "$s" || fail_ "fresh: Enter is standard (missing $s): $(profiles)"; done; pass
has traefik && has authentik || fail_ "the portal brings traefik: $(profiles)"; pass
grep -q '+ traefik (required by authentik' "$T/out" || fail_ "and says why"; pass
services '0\n0\n' 0 || fail_ "re-run: keep current runs"
grep -q '0) keep current: 9 enabled' "$T/out" || fail_ "a configured .env offers to keep"; pass
[[ "$(env_get COMPOSE_PROFILES)" == "$PRESET" ]] || fail_ "keep current changes nothing"; pass

# ---- a typo is asked again; the portal needs a name ----
services 'x\n1\n1\n' 1 || fail_ "a typo at Services is asked again"
grep -q 'Pick 1-3' "$T/out" && has sonarr || fail_ "and the next answer counts: $(profiles)"; pass
printf 'COMPOSE_PROFILES=traefik,authentik\nPORTAL_TITLE=\n' > "$ENV_FILE"
printf '\n\n' | authentik_questions > "$T/out" 2>&1 || fail_ "an empty portal name line runs"
[[ "$(env_get PORTAL_TITLE)" == Mediastack ]] && ! grep -q 'The portal needs a name' "$T/out" \
    || fail_ "an empty PORTAL_TITLE= line offers the schema's default: $(env_get PORTAL_TITLE)"; pass

services '1\n' 1 && fail_ "input that ends before Accounts stops configure"
grep -q "no answer to 'Choice': the input ended" "$T/out" || fail_ "and says why"; pass

# ---- everything: one download client, or all; the panel is not part of it ----
services '2\n1\n1\n\n' 1 || fail_ "everything + one client runs"
has qbittorrent && ! has deluge && ! has transmission || fail_ "1 keeps qbittorrent only: $(profiles)"; pass
services '2\n4\n1\n\n' 1 || fail_ "everything + all clients runs"
has qbittorrent && has deluge && has transmission || fail_ "all three are kept: $(profiles)"; pass
! has olivetin && grep -q 'olivetin — web panel: set up by its own command, not here: ./mediastack.sh frontdoor-install' "$T/out" \
    || fail_ "everything leaves out the panel, with the command that sets it up: $(profiles)"; pass
services '2\n1\n1\n\n' 0 "$PRESET,olivetin" || fail_ "everything on a stack with the panel runs"
has olivetin || fail_ "an installed panel stays: $(profiles)"; pass
printf 'COMPOSE_PROFILES=sonarr\nCONFIG_ROOT=%s\n' "$T/cfg" > "$ENV_FILE"
( load_env() { :; }; cmd_enable olivetin ) > "$T/out" 2>&1 && fail_ "enable olivetin refuses"
grep -q 'set up by its own command, which also enables it: ./mediastack.sh frontdoor-install' "$T/out" || fail_ "and names the command"; pass
printf 'COMPOSE_PROFILES=olivetin\nCONFIG_ROOT=%s\n' "$T/cfg" > "$ENV_FILE"
( frontdoor_require ) > "$T/out" 2>&1 && fail_ "up refuses a panel frontdoor-install never set up"
grep -q 'enabled but not installed — run: ./mediastack.sh frontdoor-install' "$T/out" || fail_ "and says what to run"; pass
mkdir -p "$T/cfg/olivetin/passwd"
( frontdoor_require ) > "$T/out" 2>&1 && fail_ "a directory where the file belongs is refused"
grep -q 'is a directory docker made' "$T/out" || fail_ "and named as docker's leftover"; pass
rmdir "$T/cfg/olivetin/passwd"; : > "$T/cfg/olivetin/passwd"
( frontdoor_require ) > "$T/out" 2>&1 || fail_ "an installed panel starts"; pass

# ---- two front doors: one of them ----
services '2\n1\n3\n\n' 1 || fail_ "everything + portal runs"
has traefik && ! has npm || fail_ "with the portal, traefik is kept: $(profiles)"; pass
grep -q 'npm left out: the portal' "$T/out" && ! grep -q 'Choose one: npm or traefik' "$T/out" \
    || fail_ "without a question"; pass
services '2\n1\n1\n\n' 1 || fail_ "everything + none runs (Enter at the front door)"
grep -q 'Choose one: npm or traefik' "$T/out" || fail_ "everything asks which front door"; pass
has traefik && ! has npm || fail_ "Enter keeps traefik: $(profiles)"; pass
services '2\n1\n1\n1\n' 1 || fail_ "everything + none runs (npm picked)"
has npm && ! has traefik || fail_ "1 keeps npm: $(profiles)"; pass
for f in services/traefik/compose.yml services/npm/compose.yml; do
    other=traefik; [[ "$f" == *traefik* ]] && other=npm
    grep -qE "^\s+mediastack\.conflicts: \"$other\"" "$f" || fail_ "$f declares the conflict with $other"; pass
done

# ---- hardlink check ----
# shellcheck disable=SC2034  # read by _configure_roots
configure_root() { Q_ROOT[$1]=$(env_get "$1"); }
mkdir -p "$T/data"; printf 'DATA_ROOT=%s\n' "$T/data" > "$ENV_FILE"
_configure_roots > "$T/out" 2>&1
! grep -q 'different filesystems' "$T/out" || fail_ "a download folder not made yet is no warning"; pass
mkdir -p "$T/data/torrent"
_configure_roots > "$T/out" 2>&1
! grep -q 'different filesystems' "$T/out" || fail_ "an existing one on the same filesystem is no warning"; pass
( fsdev_of() { [[ "$1" == */torrent ]] && echo 99 || echo 1; }; _configure_roots ) > "$T/out" 2>&1
grep -q 'different filesystems' "$T/out" || fail_ "an existing one on another filesystem warns"; pass

# ---- secrets read hidden; the token never on curl's command line ----
curl() { printf '%s\n' "$*" > "$T/curl.args"; cat > "$T/curl.stdin"; echo '{"nordlynx_private_key":"KEY","username":"NORDUSER","password":"NORDPASS"}'; }
printf 'COMPOSE_PROFILES=sonarr\n' > "$ENV_FILE"
gluetun_vpn_questions </dev/null > "$T/out" 2>&1 && [[ ! -s "$T/out" ]] || fail_ "nothing in the VPN: no VPN question"; pass
printf 'COMPOSE_PROFILES=gluetun\n' > "$ENV_FILE"
printf 'nordvpn\n\nTOKEN123\n\n\n\n\n' | gluetun_vpn_questions > "$T/out" 2>&1 || fail_ "nord step runs: $(cat "$T/out")"
[[ "$(env_get WIREGUARD_PRIVATE_KEY)" == KEY ]] || fail_ "the key is fetched: $(cat "$ENV_FILE")"; pass
! grep -q TOKEN123 "$T/curl.args" && grep -qx 'user = "token:TOKEN123"' "$T/curl.stdin" \
    || fail_ "the token goes on stdin, not the command line: $(cat "$T/curl.args")"; pass
# a provider chosen by its number; a key the old provider made is not offered
# again (Enter refused, a bad key refused, then a good one); its address asked
WGK=wOEI9rqqbDwnN8/Bpp22sVz48T71vJ4fYmFWujulwUU=
printf 'COMPOSE_PROFILES=gluetun\nVPN_PROVIDER=nordvpn\nWIREGUARD_PRIVATE_KEY=OLDNORDKEY\n' > "$ENV_FILE"
n=$(vpnp_list | grep -nx mullvad | cut -d: -f1)
printf '%s\n\nnot-a-key\n%s\n10.64.0.2/32\n\n\n\n\n' "$n" "$WGK" | Q_TERMINAL=1 gluetun_vpn_questions > "$T/out" 2>&1 || fail_ "mullvad step runs: $(cat "$T/out")"
[[ "$(env_get VPN_PROVIDER)" == mullvad && "$(env_get WIREGUARD_PRIVATE_KEY)" == "$WGK" && "$(env_get WIREGUARD_ADDRESSES)" == 10.64.0.2/32 ]] \
    || fail_ "by number, the old provider's key not kept, its address asked: $(cat "$ENV_FILE")"; pass
grep -q 'this value is required' "$T/out" && grep -q 'not a WireGuard key' "$T/out" || fail_ "Enter and a bad key refused, saying why: $(cat "$T/out")"; pass
printf 'mullvad\n\n\n\n\n\n\n' | Q_TERMINAL=1 gluetun_vpn_questions > "$T/out" 2>&1 || fail_ "mullvad again runs"
[[ "$(env_get WIREGUARD_PRIVATE_KEY)" == "$WGK" && "$(env_get WIREGUARD_ADDRESSES)" == 10.64.0.2/32 ]] || fail_ "the same provider: Enter keeps its key and address"; pass
# your own config, by its path: a broken one refused naming its line, then a good one read in
printf '[Interface]\nPrivateKey = %s\nAddress = 10.7.0.2/32\n[Peer]\nPublicKey = %s\nEndpoint = home.example.net\n' "$WGK" "$WGK" > "$T/bad.conf"
printf '[Interface]\nPrivateKey = %s\nAddress = 10.7.0.2/32\n[Peer]\nPublicKey = %s\nEndpoint = home.example.net:51820\n' "$WGK" "$WGK" > "$T/good.conf"
printf 'custom\n\n%s\n%s\n' "$T/bad.conf" "$T/good.conf" | Q_TERMINAL=1 gluetun_vpn_questions > "$T/out" 2>&1 || fail_ "custom step runs: $(cat "$T/out")"
[[ "$(env_get VPN_PROVIDER)" == custom && "$(env_get WIREGUARD_ENDPOINT_HOST)" == home.example.net && "$(env_get WIREGUARD_ENDPOINT_PORT)" == 51820 ]] \
    && grep -q "line 6: Endpoint 'home.example.net' is not host:port" "$T/out" && grep -q 'looks it up from this host' "$T/out" \
    || fail_ "custom: a bad config named by its line, a good one read in, a name said to be looked up: $(cat "$T/out")"; pass
# back to nordvpn: custom's server, its key and its address go with it
printf 'nordvpn\n\nTOKEN123\n\n\n\n\n' | Q_TERMINAL=1 gluetun_vpn_questions > "$T/out" 2>&1 || fail_ "custom -> nordvpn runs: $(cat "$T/out")"
[[ "$(env_get VPN_PROVIDER)" == nordvpn && "$(env_get WIREGUARD_PRIVATE_KEY)" == KEY ]] \
    && ! grep -qE '^WIREGUARD_(ADDRESSES|PUBLIC_KEY|ENDPOINT_HOST|ENDPOINT_PORT)=.' "$ENV_FILE" \
    || fail_ "a switch empties what only the old provider read: $(cat "$ENV_FILE")"; pass
# OpenVPN (slice 2): nordvpn's tunnel asked, the token gives the login; a switch of tunnel drops the WireGuard key
printf 'nordvpn\nopenvpn\nTOKEN123\n\n\n\n\n' | Q_TERMINAL=1 gluetun_vpn_questions > "$T/out" 2>&1 || fail_ "nord over OpenVPN runs: $(cat "$T/out")"
[[ "$(env_get VPN_TYPE)" == openvpn && "$(env_get OPENVPN_USER)" == NORDUSER && "$(env_get OPENVPN_PASSWORD)" == NORDPASS && "$(env_get OPENVPN_PROTOCOL)" == udp && -z "$(env_get WIREGUARD_PRIVATE_KEY)" ]] \
    && ! grep -q 'OpenVPN protocol' "$T/out" \
    || fail_ "nordvpn over OpenVPN: its login fetched, UDP without asking (its only one), the WireGuard key gone: $(grep -E '^(VPN_|OPENVPN_|WIREGUARD_PRIVATE)' "$ENV_FILE")"; pass
grep -q 'Tunnel (wireguard/openvpn) \[wireguard\]' "$T/out" || grep -q 'WireGuard is faster' "$T/out" || fail_ "the tunnel asked where the provider has both: $(cat "$T/out")"; pass
printf 'expressvpn\nEXPUSER\nEXPPASS\n\n\n' | Q_TERMINAL=1 gluetun_vpn_questions > "$T/out" 2>&1 || fail_ "an OpenVPN-only provider runs: $(cat "$T/out")"
[[ "$(env_get VPN_TYPE)" == openvpn && "$(env_get OPENVPN_USER)" == EXPUSER && "$(env_get OPENVPN_PROTOCOL)" == udp ]] && ! grep -q 'OpenVPN protocol' "$T/out" \
    || fail_ "expressvpn: no tunnel or protocol asked (one of each), its login asked anew: $(grep -E '^(VPN_TYPE|OPENVPN_)' "$ENV_FILE")"; pass
# a client certificate and key, from the .ovpn the provider gives (an old RSA key refused first)
printf '%s\n' '-----BEGIN RSA PRIVATE KEY-----' 'MIIE' '-----END RSA PRIVATE KEY-----' > "$T/old.key"
printf '%s\n' 'client' 'remote 1.2.3.4 1194' '<cert>' '-----BEGIN CERTIFICATE-----' 'Q0VSVA==' '-----END CERTIFICATE-----' '</cert>' '<key>' '-----BEGIN PRIVATE KEY-----' 'S0VZ' '-----END PRIVATE KEY-----' '</key>' > "$T/cg.ovpn"
printf 'cyberghost\nu\np\n%s\n%s\n%s\n\n\n' "$T/cg.ovpn" "$T/old.key" "$T/cg.ovpn" | Q_TERMINAL=1 gluetun_vpn_questions > "$T/out" 2>&1 || fail_ "cyberghost runs: $(cat "$T/out")"
[[ "$(env_get OPENVPN_CERT)" == Q0VSVA== && "$(env_get OPENVPN_KEY)" == S0VZ ]] && grep -q 'openssl pkcs8' "$T/out" \
    || fail_ "its certificate and key read from the file, an RSA key refused with the conversion: $(cat "$T/out")"; pass
# your own .ovpn: kept under custom/vpn/, its login asked because it has auth-user-pass
CUSTOM_DIR=$T/custom
printf '%s\n' 'client' 'remote vpn.example.net 1194 udp' 'auth-user-pass' > "$T/mine.ovpn"
printf 'custom\nopenvpn\n%s\nMYUSER\nMYPASS\n' "$T/mine.ovpn" | Q_TERMINAL=1 gluetun_vpn_questions > "$T/out" 2>&1 || fail_ "custom OpenVPN runs: $(cat "$T/out")"
cmp -s "$T/mine.ovpn" "$CUSTOM_DIR/vpn/openvpn.ovpn" && [[ "$(env_get OPENVPN_USER)" == MYUSER && -z "$(env_get OPENVPN_CERT)" ]] && grep -q 'server vpn.example.net:1194 over udp, a login' "$T/out" \
    || fail_ "custom OpenVPN: the file kept as yours, its login asked, cyberghost's certificate gone: $(cat "$T/out")"; pass
grep -qx 'OPENVPN_PROTOCOL=' "$ENV_FILE" || fail_ "custom OpenVPN: no protocol left behind — its file says it ($(grep OPENVPN_PROTOCOL "$ENV_FILE"))"; pass
# server choices (slice 3), with gluetun's server list on this host: "?" lists
# them, a typo is refused with close matches, an answer kept as the list spells it
printf '%s\n' '[{"vpn":"wireguard","country":"Switzerland","region":"Europe","city":"Zurich","categories":["Standard VPN servers","P2P"],"hostname":"ch1"},' \
    '{"vpn":"wireguard","country":"Switzerland","region":"Europe","city":"Geneva","categories":["Standard VPN servers"],"hostname":"ch2"},' \
    '{"vpn":"wireguard","country":"Netherlands","region":"Europe","city":"Amsterdam","categories":["Standard VPN servers","P2P"],"hostname":"nl1"}]' > "$T/servers.json"
real_load=$(declare -f vpn_servers_load)
# shellcheck disable=SC2034  # read by the questions
vpn_servers_load() { VPN_SERVERS=$T/servers.json; }
printf 'COMPOSE_PROFILES=gluetun\nVPN_PROVIDER=nordvpn\nWIREGUARD_PRIVATE_KEY=KEY\n' > "$ENV_FILE"
printf 'nordvpn\n\nTOKEN123\np2p\n\n?\nswitzerland\nzurik\nzurich\n' | Q_TERMINAL=1 gluetun_vpn_questions > "$T/out" 2>&1 || fail_ "nord with its server list runs: $(cat "$T/out")"
[[ "$(env_get VPN_SERVER_CATEGORIES)" == P2P && -z "$(env_get VPN_SERVER_REGIONS)" && "$(env_get VPN_SERVER_COUNTRIES)" == Switzerland && "$(env_get VPN_SERVER_CITIES)" == Zurich ]] \
    || fail_ "each answer as the list spells it, Enter on an empty one is any: $(grep '^VPN_SERVER' "$ENV_FILE")"; pass
grep -q '  Netherlands, Switzerland$' "$T/out" && grep -q "no city 'zurik' among nordvpn's WireGuard servers with VPN_SERVER_CATEGORIES=P2P, VPN_SERVER_COUNTRIES=Switzerland — close: Zurich" "$T/out" \
    || fail_ "? lists the P2P countries, a typo names the close one: $(cat "$T/out")"; pass
printf 'nordvpn\n\nTOKEN123\n\n\n\nany\n' | Q_TERMINAL=1 gluetun_vpn_questions > "$T/out" 2>&1 || fail_ "nord again runs: $(cat "$T/out")"
[[ "$(env_get VPN_SERVER_CATEGORIES)" == P2P && "$(env_get VPN_SERVER_COUNTRIES)" == Switzerland && -z "$(env_get VPN_SERVER_CITIES)" ]] || fail_ "Enter keeps a choice, any clears it: $(grep '^VPN_SERVER' "$ENV_FILE")"; pass
eval "$real_load"
# a prompt is printed only to a terminal, so the echo is checked at the source:
# no secret is read by a prompt that echoes, or offered as a visible default
! grep -nE 'ask WIREGUARD_(PRIVATE|PRESHARED)_KEY|read -r -p "(NordVPN|Tunnel)' lib/questionnaire.sh services/gluetun/*.sh services/gluetun/providers/*/provider.sh services/cloudflared/cloudflared.sh \
    || fail_ "a secret is read with an echoing prompt"; pass

# ---- the tunnel needs its token ----
printf 'COMPOSE_PROFILES=traefik,cloudflared,jellyfin\nCLOUDFLARE_TUNNEL_TOKEN=\n' > "$ENV_FILE"
printf '\n' | cloudflared_questions > "$T/out" 2>&1
[[ "$(env_get COMPOSE_PROFILES)" == traefik,jellyfin ]] || fail_ "blank: the tunnel is off: $(env_get COMPOSE_PROFILES)"; pass
grep -q 'enable cloudflared' "$T/out" && grep -q 'Leave the token blank' "$T/out" || fail_ "and says how to turn it on later"; pass
printf 'COMPOSE_PROFILES=traefik,cloudflared\nCLOUDFLARE_TUNNEL_TOKEN=\n' > "$ENV_FILE"
printf 'TUNNEL1\n' | cloudflared_questions > "$T/out" 2>&1
[[ "$(env_get CLOUDFLARE_TUNNEL_TOKEN)" == TUNNEL1 ]] && has cloudflared || fail_ "a token is stored, the tunnel stays"; pass
! grep -q TUNNEL1 "$T/out" || fail_ "the token is not echoed"; pass
printf 'COMPOSE_PROFILES=cloudflared\nCLOUDFLARE_TUNNEL_TOKEN=T\n' > "$ENV_FILE"
cloudflared_questions </dev/null > "$T/out" 2>&1 && [[ ! -s "$T/out" ]] || fail_ "a stored token is enough: nothing asked"; pass

# ---- the dashboard's login is one of the stack's own: up asks nothing for it ----
printf 'COMPOSE_PROFILES=traefik\nSTACK_DOMAIN=media.example.com\nACME_EMAIL=me@example.com\nCF_DNS_API_TOKEN=t\nACME_ENV=staging\nTRAEFIK_DASH_USER=\nTRAEFIK_DASH_PASSWORD=\n' > "$ENV_FILE"
( traefik_gen() { :; }; traefik_ensure </dev/null ) > "$T/out" 2>&1 || fail_ "Traefik answered: the dashboard's login needs no terminal (logins_fill records it)"; pass

# ---- the panel, offered at the end when Traefik serves it; configure installs it ----
printf 'COMPOSE_PROFILES=traefik,sonarr\n' > "$ENV_FILE"
printf '\n' | _configure_panel_offer > "$T/out" 2>&1
[[ "$(state_get "$PANEL_STATE")" == yes ]] || fail_ "Enter installs the panel (default yes)"; pass
printf 'n\n' | _configure_panel_offer > "$T/out" 2>&1
[[ -z "$(state_get "$PANEL_STATE")" ]] && grep -q 'Later: ./mediastack.sh frontdoor-install' "$T/out" || fail_ "n leaves it, with the command for later"; pass
printf 'COMPOSE_PROFILES=sonarr\n' > "$ENV_FILE"
_configure_panel_offer </dev/null > "$T/out" 2>&1; [[ ! -s "$T/out" ]] || fail_ "without Traefik nothing is offered"; pass
printf 'COMPOSE_PROFILES=traefik,olivetin\n' > "$ENV_FILE"
_configure_panel_offer </dev/null > "$T/out" 2>&1; [[ ! -s "$T/out" ]] || fail_ "an installed panel is not offered again"; pass

# ---- each answer's check: says why, changes nothing (the answers file reuses them) ----
cp "$ENV_FILE" "$T/checks.before"
[[ -z "$(vpn_provider_problem NordVPN)" && -n "$(vpn_provider_problem 'bad name!')" && -n "$(vpn_provider_problem perfect-privacy)" ]] \
    || fail_ "provider: a folder of services/gluetun/providers (any case) — nothing else"; pass
[[ -z "$(vpn_list_tidy auto)" && "$(vpn_list_tidy 'Netherlands, Sweden')" == Netherlands,Sweden ]] \
    || fail_ "a server choice: auto (or any) is no limit; a typed list as gluetun reads one (no space after a comma)"; pass
[[ -z "$(wg_addresses_problem '10.5.0.2/32, fd00::2/128')" && -n "$(wg_addresses_problem 10.5.0.2)" ]] || fail_ "addresses: IP/prefix, comma-separated"; pass
[[ -z "$(sched_problem 'Tue 04:00')" && "$(sched_problem bogus)" == "'bogus' is not a valid schedule." ]] || fail_ "a schedule is what systemd takes"; pass
[[ "$(accounts_current gluetun,authentik,traefik)" == authentik && "$(accounts_current gluetun,wizarr)" == wizarr \
   && "$(accounts_current gluetun)" == none && -z "$(accounts_current '')" ]] || fail_ "the current account model"; pass
# the services' own (their question hooks)
[[ -z "$(portal_title_problem 'My Portal')" && -n "$(portal_title_problem '   ')" ]] || fail_ "the portal needs a name"; pass
[[ -z "$(smtp_host_problem smtp.Example.com)" && -n "$(smtp_host_problem 'bad host!')" ]] || fail_ "a mail server's name (any case)"; pass
[[ -z "$(smtp_password_problem 'ab cd ef')" && -z "$(smtp_password_problem 'pa$s')" && -n "$(smtp_password_problem $'pa\x01s')" ]] || fail_ "a mail password: spaces dropped, a \$ carried, a control character refused"; pass
[[ -z "$(jf_server_name_problem 'My Jelly')" && -n "$(jf_server_name_problem 'bad$name')" && -n "$(jf_server_name_problem ' ')" ]] \
    || fail_ "Jellyfin's name: something, nothing .env cannot hold"; pass
[[ -z "$(trash_profile_problem 720p)" && -z "$(trash_profile_problem skip)" && -n "$(trash_profile_problem 8k)" ]] || fail_ "a TRaSH profile"; pass
[[ -z "$(traefik_domain_problem Media.Example.com)" && -n "$(traefik_domain_problem 'Bad Domain')" ]] || fail_ "a domain (any case)"; pass
cmp -s "$ENV_FILE" "$T/checks.before" || fail_ "a check writes nothing"; pass
vpnp_load nordvpn
( curl() { cat >/dev/null; echo '{"nordlynx_private_key":"K1"}'; }; [[ "$(nord_wg_key T)" == K1 ]] ) || fail_ "Nord's key for a token"; pass
( curl() { cat >/dev/null; echo '{}'; }; ! out=$(nord_wg_key T) && [[ "$out" == "Token rejected by NordVPN"* ]] ) || fail_ "a rejected token: rc 1 and why"; pass

echo "OK configure: $checks checks"
