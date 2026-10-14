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
#   * a typo is asked again, never fatal; the portal needs a name; input that
#     ends mid-question stops configure instead of asking forever
#   * secrets are read hidden; the NordVPN token reaches curl on stdin, never
#     on its command line
#   * a blank tunnel token turns the tunnel off; enable refuses it without one
#   * with the portal, the Traefik dashboard asks nothing and never keeps an
#     empty password
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

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; [[ -f "$T/out" ]] && { echo "--- output:" >&2; cat "$T/out" >&2; }; exit 1; }
explain() { printf '%s\n' "$@"; }; hr() { :; }
render() { :; }; repo_owned() { :; }
# shellcheck disable=SC2034  # read by the sourced entrypoint's svc_* helpers
RENDERED_JSON='{"services":{
  "gluetun":     {"labels":{"mediastack.managed":"true","mediastack.desc":"VPN"}},
  "qbittorrent": {"labels":{"mediastack.managed":"true","mediastack.desc":"torrents"},"depends_on":{"gluetun":{}}},
  "deluge":      {"labels":{"mediastack.managed":"true","mediastack.desc":"torrents"},"depends_on":{"gluetun":{}}},
  "transmission":{"labels":{"mediastack.managed":"true","mediastack.desc":"torrents"},"depends_on":{"gluetun":{}}},
  "olivetin":    {"labels":{"mediastack.managed":"true","mediastack.desc":"web panel","mediastack.installer":"frontdoor-install"}},
  "sonarr":      {"labels":{"mediastack.managed":"true","mediastack.desc":"series"}},
  "radarr":      {"labels":{"mediastack.managed":"true","mediastack.desc":"films"}},
  "prowlarr":    {"labels":{"mediastack.managed":"true","mediastack.desc":"indexers"}},
  "jellyfin":    {"labels":{"mediastack.managed":"true","mediastack.desc":"media"}},
  "meilisearch": {"labels":{"mediastack.managed":"true","mediastack.desc":"index"}},
  "jellysearch": {"labels":{"mediastack.managed":"true","mediastack.desc":"search"},"depends_on":{"meilisearch":{}}},
  "seerr":       {"labels":{"mediastack.managed":"true","mediastack.desc":"requests"}},
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
printf 'COMPOSE_PROFILES=%s\nPORTAL_TITLE=\n' "$PRESET" > "$ENV_FILE"
# shellcheck disable=SC2034  # read by _configure_services
CONFIGURE_FRESH=1
printf '1\n3\n\n' | _configure_services > "$T/out" 2>&1 || fail_ "an empty portal name line runs"
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
configure_root() { :; }
mkdir -p "$T/data"; printf 'DATA_ROOT=%s\n' "$T/data" > "$ENV_FILE"
_configure_roots > "$T/out" 2>&1
! grep -q 'different filesystems' "$T/out" || fail_ "a download folder not made yet is no warning"; pass
mkdir -p "$T/data/torrent"
_configure_roots > "$T/out" 2>&1
! grep -q 'different filesystems' "$T/out" || fail_ "an existing one on the same filesystem is no warning"; pass
( fsdev_of() { [[ "$1" == */torrent ]] && echo 99 || echo 1; }; _configure_roots ) > "$T/out" 2>&1
grep -q 'different filesystems' "$T/out" || fail_ "an existing one on another filesystem warns"; pass

# ---- secrets read hidden; the token never on curl's command line ----
curl() { printf '%s\n' "$*" > "$T/curl.args"; cat > "$T/curl.stdin"; echo '{"nordlynx_private_key":"KEY"}'; }
: > "$ENV_FILE"
printf 'nordvpn\nTOKEN123\n\n' | _configure_vpn > "$T/out" 2>&1 || fail_ "nord step runs"
[[ "$(env_get WIREGUARD_PRIVATE_KEY)" == KEY ]] || fail_ "the key is fetched: $(cat "$ENV_FILE")"; pass
! grep -q TOKEN123 "$T/curl.args" && grep -qx 'user = "token:TOKEN123"' "$T/curl.stdin" \
    || fail_ "the token goes on stdin, not the command line: $(cat "$T/curl.args")"; pass
printf 'VPN_PROVIDER=custom\nWIREGUARD_PRIVATE_KEY=OLDKEY\n' > "$ENV_FILE"
printf 'custom\n\n\n' | _configure_vpn > "$T/out" 2>&1 || fail_ "custom step runs"
[[ "$(env_get WIREGUARD_PRIVATE_KEY)" == OLDKEY ]] || fail_ "Enter keeps the private key"; pass
# a prompt is printed only to a terminal, so the echo is checked at the source:
# no secret is read by a prompt that echoes, or offered as a visible default
! grep -nE 'ask WIREGUARD_PRIVATE_KEY|read -r -p "(NordVPN|Tunnel)' lib/configure.sh services/cloudflared/cloudflared.sh \
    || fail_ "a secret is read with an echoing prompt"; pass

# ---- the tunnel needs its token ----
printf 'COMPOSE_PROFILES=traefik,cloudflared,jellyfin\nCLOUDFLARE_TUNNEL_TOKEN=\n' > "$ENV_FILE"
printf '\n' | cloudflared_configure_secret > "$T/out" 2>&1
[[ "$(env_get COMPOSE_PROFILES)" == traefik,jellyfin ]] || fail_ "blank: the tunnel is off: $(env_get COMPOSE_PROFILES)"; pass
grep -q 'enable cloudflared' "$T/out" && grep -q 'Leave the token blank' "$T/out" || fail_ "and says how to turn it on later"; pass
printf 'COMPOSE_PROFILES=traefik,cloudflared\nCLOUDFLARE_TUNNEL_TOKEN=\n' > "$ENV_FILE"
printf 'TUNNEL1\n' | cloudflared_configure_secret > "$T/out" 2>&1
[[ "$(env_get CLOUDFLARE_TUNNEL_TOKEN)" == TUNNEL1 ]] && has cloudflared || fail_ "a token is stored, the tunnel stays"; pass
! grep -q TUNNEL1 "$T/out" || fail_ "the token is not echoed"; pass
printf 'CLOUDFLARE_TUNNEL_TOKEN=\n' > "$ENV_FILE"
( cloudflared_enable_check jellyfin ) > "$T/out" 2>&1 || fail_ "a set without the tunnel needs no token"; pass
( cloudflared_enable_check $'jellyfin\ncloudflared' </dev/null ) > "$T/out" 2>&1 && fail_ "no token, no terminal: enable refuses"
grep -q 'needs its tunnel token' "$T/out" || fail_ "and says how"; pass
printf 'CLOUDFLARE_TUNNEL_TOKEN=T\n' > "$ENV_FILE"
( cloudflared_enable_check cloudflared </dev/null ) > "$T/out" 2>&1 || fail_ "a stored token is enough"; pass

# ---- the dashboard behind the portal: no question, never an empty password ----
printf 'COMPOSE_PROFILES=traefik,authentik\nSTACK_DOMAIN=media.example.com\nACME_EMAIL=me@example.com\nCF_DNS_API_TOKEN=t\nACME_ENV=staging\nTRAEFIK_DASH_USER=\nTRAEFIK_DASH_PASSWORD=\n' > "$ENV_FILE"
( traefik_gen() { :; }; traefik_ensure </dev/null ) > "$T/out" 2>&1 || fail_ "with the portal the dashboard needs no terminal"
[[ "$(env_get TRAEFIK_DASH_USER)" == admin && -n "$(env_get TRAEFIK_DASH_PASSWORD)" ]] \
    || fail_ "a fallback login is generated, not left empty: $(grep TRAEFIK_DASH "$ENV_FILE")"; pass
grep -q 'admins sign in through the portal' "$T/out" || fail_ "and it says so"; pass

echo "OK configure: $checks checks"
