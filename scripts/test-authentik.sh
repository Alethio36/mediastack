#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-authentik.sh — the authentik shard's rules.
#   * upgrades walk authentik's releases one at a time and never go back; a
#     new database may start on any known release; the release is read from an
#     image tag or a version
#   * secrets: generated once, letters and digits only, never replaced — and
#     refused outright when the database already exists without them
#   * account models: authentik and Wizarr conflict (declared on either side),
#     and a conflict pair in a selection is found
#   * a shard member is never a dependency to enable (it comes with its
#     primary's profile)
#   * a service an upgrade adds gets its UID before it first starts
#   * the portal's blueprint: sign-up needs an invitation, makes internal users
#     in media-users, requires an email; the worker gets its values and mount
#   * invitations: single use, bound to the sign-up flow, 7 days by default
#   * Jellyfin through LDAP: LDAPS to ldap.<domain> through Traefik, checking
#     on with production certificates, media-users or admins, every library;
#     only mediastack's plugin settings change; admin rights follow `admins`
#     for directory users and never touch local accounts
#   * the base URL is set when unset or still mediastack's, never over one
#     set in authentik's UI
#   * the gate: Traefik's middleware asks authentik only when it runs; wire
#     adds the gate beside the outpost's providers, puts akadmin in admins
#     once, keeps one admins-only card per gated tool and never touches
#     applications it did not make
#   * gated ports listen on 127.0.0.1 while the portal runs; an arr trusts the
#     portal only when it is gated AND unreachable by IP, its own login otherwise
#   * the stack network keeps Traefik on a fixed address outside the pool;
#     only that address may name a user (Navidrome), and every route past a
#     gate strips the portal's headers
#   * household apps get Media cards for media-users; Navidrome's carries its
#     own household gate (forward auth for its one address)
#
#   scripts/test-authentik.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-authentik.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }
ok() { :; }

# ---- the upgrade path ----
AUTHENTIK_RELEASES=(2026.2 2026.5 2026.8)
[[ "$(authentik_step "" 2026.8)" == ok ]] || fail_ "a new database may start on any known release"; pass
[[ "$(authentik_step 2026.8 2026.8)" == ok ]] || fail_ "the same release (a patch update) is fine"; pass
[[ "$(authentik_step 2026.5 2026.8)" == ok ]] || fail_ "the next release is fine"; pass
got=$(authentik_step 2026.2 2026.8)
[[ "$got" == *"must not skip"*"2026.2 -> 2026.5 first"*"update authentik --to 2026.5"* ]] || fail_ "skipping: $got"; pass
got=$(authentik_step 2026.8 2026.5)
[[ "$got" == *"cannot go back"*"rollback authentik"* ]] || fail_ "going back: $got"; pass
[[ "$(authentik_step 2026.5 2027.1)" == *"not an authentik release this version of mediastack knows"* ]] || fail_ "an unknown target"; pass
[[ "$(authentik_step 2025.10 2026.2)" == *"which this version of mediastack does not know"* ]] || fail_ "an unknown starting release"; pass
[[ "$(authentik_release_of ghcr.io/goauthentik/server:2026.8)" == 2026.8 ]] || fail_ "release from an image tag"; pass
[[ "$(authentik_release_of 2026.8.3)" == 2026.8 ]] || fail_ "release from a version"; pass
if authentik_release_of ghcr.io/goauthentik/server:latest >/dev/null; then fail_ "'latest' names no release"; fi; pass
# the fragment's tag is a release the list knows (so a fresh install can start)
tag=$(awk '/image: ghcr.io\/goauthentik\/server:/ { sub(/.*:/, ""); print; exit }' compose.d/authentik.yml)
[[ " ${AUTHENTIK_RELEASES[*]} " == *" $(authentik_release_of "$tag") "* ]] || fail_ "the fragment's tag $tag is not in AUTHENTIK_RELEASES"; pass
[[ "$(grep -c "image: ghcr.io/goauthentik/server:$tag$" compose.d/authentik.yml)" == 2 ]] || fail_ "server and worker must run the same tag"; pass
grep -q "image: ghcr.io/goauthentik/ldap:$tag$" compose.d/authentik.yml || fail_ "the LDAP outpost must run the server's release (authentik requires it)"; pass

# ---- secrets ----
s=$(authentik_secret 60)
[[ ${#s} == 60 && "$s" =~ ^[A-Za-z0-9]+$ ]] || fail_ "a secret: 60 letters and digits, got '$s'"; pass
ENV_FILE=$T/env; printf 'AUTHENTIK_DB_PASSWORD=keepme\n' > "$ENV_FILE"
authentik_has_db() { return 1; }
authentik_secrets
[[ "$(env_get AUTHENTIK_DB_PASSWORD)" == keepme ]] || fail_ "an existing secret must never be replaced"; pass
[[ "$(env_get AUTHENTIK_SECRET_KEY | wc -c)" == 61 && "$(env_get AUTHENTIK_API_TOKEN | wc -c)" == 65 ]] \
    || fail_ "missing secrets must be generated at their lengths"; pass
printf 'AUTHENTIK_SECRET_KEY=x\n' > "$ENV_FILE"
authentik_has_db() { return 0; }
out=$( (authentik_secrets) 2>&1 ) && fail_ "a database without its password must stop, not get a new one"
[[ "$out" == *"AUTHENTIK_DB_PASSWORD is missing"* ]] || fail_ "the refusal must name the missing secret: $out"; pass
[[ "$(env_get AUTHENTIK_DB_PASSWORD)" == "" ]] || fail_ "nothing may be written when refusing"; pass

# ---- conflicts and dependencies ----
render() { :; }
RENDERED_JSON='{"services":{
  "authentik":        {"depends_on":{"authentik-db":{},"authentik-worker":{}},"labels":{"mediastack.managed":"true","mediastack.conflicts":"wizarr"}},
  "authentik-worker": {"labels":{"mediastack.shard":"authentik"}},
  "authentik-db":     {"labels":{"mediastack.shard":"authentik"}},
  "wizarr":           {"depends_on":{"jellyfin":{}},"labels":{"mediastack.managed":"true"}},
  "jellyfin":         {"labels":{"mediastack.managed":"true"}}}}'
[[ "$(svc_conflicts wizarr)" == authentik ]] || fail_ "a conflict declared on one side counts for both"; pass
[[ "$(conflicts_in jellyfin wizarr authentik)" == "authentik wizarr" ]] || fail_ "the conflicting pair: $(conflicts_in jellyfin wizarr authentik)"; pass
[[ -z "$(conflicts_in jellyfin authentik)" ]] || fail_ "no pair, no conflict"; pass
[[ -z "$(svc_deps authentik)" ]] || fail_ "a shard member is not a dependency to enable: $(svc_deps authentik)"; pass
[[ "$(svc_deps wizarr)" == jellyfin ]] || fail_ "ordinary dependencies are unchanged"; pass

# ---- a service an upgrade adds gets its UID before it first starts ----
# (found live: an install upgraded to authentik ran it as the images' default
# users — the UID was only allocated by `configure`)
info() { echo "INFO $*" >> "$T/info"; }
CUSTOM_DIR=$T/custom
printf 'UID_BASE=13000\nSONARR_UID=13001\nRADARR_UID=13028\n' > "$ENV_FILE"
_configure_selfheal
u=$(env_get AUTHENTIK_UID)
[[ "$u" =~ ^[0-9]+$ ]] && (( u > 13028 )) \
    || fail_ "a new service gets a UID above every existing one: '$u'"; pass
[[ -z "$(grep -E '_UID=[0-9]+$' "$ENV_FILE" | cut -d= -f2 | sort | uniq -d)" ]] || fail_ "allocated UIDs must be unique"; pass
before=$(cat "$ENV_FILE"); rm -f "$T/info"; _configure_selfheal
[[ "$(cat "$ENV_FILE")" == "$before" && ! -e "$T/info" ]] || fail_ "a second run changes nothing and says nothing"; pass
grep -q '^    _configure_selfheal' <(sed -n '/^provision() {/,/^}/p' mediastack.sh) \
    || fail_ "provision (up, enable) must allocate new services' UIDs"; pass

# ---- the portal's setup (blueprints/authentik/) ----
bp=blueprints/authentik/mediastack-portal.yaml
grep -q "^  name: $AUTHENTIK_BLUEPRINT\$" "$bp" || fail_ "the blueprint's name must be AUTHENTIK_BLUEPRINT ($AUTHENTIK_BLUEPRINT)"; pass
grep -q "^      slug: $AUTHENTIK_JOIN_FLOW\$" "$bp" || fail_ "the sign-up flow's slug must be AUTHENTIK_JOIN_FLOW"; pass
# household members are internal (external users never see the app dashboard), in media-users
grep -A4 'model: authentik_stages_user_write.userwritestage' "$bp" | grep -q 'name: mediastack-join-write' \
    && sed -n '/name: mediastack-join-write/,/^  - /p' "$bp" | grep -q 'user_type: internal' \
    && sed -n '/name: mediastack-join-write/,/^  - /p' "$bp" | grep -q 'create_users_group: !KeyOf group-media-users' \
    || fail_ "sign-up must create internal users in media-users"; pass
sed -n '/name: mediastack-join-invitation/,/^  - /p' "$bp" | grep -q 'continue_flow_without_invitation: false' \
    || fail_ "sign-up must need an invitation"; pass
sed -n '/name: mediastack-join-email/,/^  - /p' "$bp" | grep -q 'required: true' || fail_ "email is required at sign-up"; pass
# one page: every field on the credentials stage, and only one prompt stage bound
sed -n '/name: mediastack-join-credentials/,/^  - /p' "$bp" | grep -c '!KeyOf field-' | grep -qx 6 \
    || fail_ "sign-up is one page: all six fields on one stage"; pass
[[ "$(grep -A1 'target: !KeyOf flow-join' "$bp" | grep -c 'stage: !KeyOf stage-')" == 4 ]] || fail_ "four stages bound to sign-up: invitation, the page, write, login"; pass
sed -n '/^  authentik-worker:/,/^  authentik-db:/p' compose.d/authentik.yml > "$T/worker"
grep -q 'MEDIASTACK_PORTAL_TITLE: ${PORTAL_TITLE:-Mediastack}' "$T/worker" && grep -q 'MEDIASTACK_PORTAL_URL:' "$T/worker" \
    || fail_ "the worker passes the portal's name and address to the blueprint"; pass
grep -q -- '- ${CONFIG_ROOT}/authentik/blueprints:/blueprints/mediastack:ro' "$T/worker" \
    || fail_ "the worker mounts mediastack's blueprints read-only"; pass

# ---- invitations ----
TRAEFIK_ENV="AUTHENTIK_HOST=portal
TRAEFIK_DOMAIN=media.example.com"
printf '%s\n' "$TRAEFIK_ENV" > "$ENV_FILE"
svc_cname() { echo "c-$1"; }; c_health() { echo healthy; }
ak_api() {
    echo "$1 $2 ${3:-}" >> "$T/calls"
    case "$1 $2" in
        "GET /flows/instances/?slug=mediastack-join") echo '{"results":[{"pk":"flow-uuid"}]}' ;;
        "POST /stages/invitation/invitations/")       echo '{"pk":"inv-uuid"}' ;;
        *) return 1 ;;
    esac
}
rm -f "$T/calls"
link=$(authentik_invite 7 | tail -1)
[[ "$link" == "https://portal.media.example.com/if/flow/mediastack-join/?itoken=inv-uuid" ]] || fail_ "invitation link: $link"; pass
body=$(grep '^POST' "$T/calls" | cut -d' ' -f3-)
[[ "$(jq -r '.single_use' <<<"$body")" == true && "$(jq -r '.flow' <<<"$body")" == flow-uuid ]] || fail_ "single use, bound to the sign-up flow: $body"; pass
exp=$(jq -r '.expires' <<<"$body"); want=$(date -u -d '+7 days' +%s); got=$(date -u -d "$exp" +%s)
(( got - want < 120 && want - got < 120 )) || fail_ "expires in 7 days: $exp"; pass

# ---- the base URL: set when unset or still ours, never over one set in the UI ----
state_get() { cat "$T/state" 2>/dev/null || true; }
state_set() { echo "$2" > "$T/state"; }
wire_gate() { :; }; http_ready() { :; }; hr() { :; }; info() { :; }; svc_enabled() { [[ "$1" == authentik ]]; }
authentik_url() { echo http://127.0.0.1:9000; }
WIRE_DRY=0; WIRE_CHANGES=0; WIRE_FAILS=0
base() { # base CURRENT OURS -> the PATCH body sent, or "none"
    CUR=$1; rm -f "$T/calls"; if [[ -n "$2" ]]; then echo "$2" > "$T/state"; else rm -f "$T/state"; fi
    ak_api() { echo "$1 $2 ${3:-}" >> "$T/calls"
        case "$1 $2" in
            "GET /admin/settings/") jq -cn --arg u "$CUR" '{base_url:$u}' ;;
            "PATCH /admin/settings/") : ;;
            "GET /managed/blueprints/?page_size=200") jq -cn --arg h "$BP_CUR" '{results:[{name:"Mediastack - Portal", status:"successful", last_applied_hash:$h, pk:"bp-1"}]}' ;;
        esac; }
    wire_authentik >/dev/null
    if grep -q '^PATCH' "$T/calls"; then grep '^PATCH' "$T/calls" | cut -d' ' -f3-; else echo none; fi
}
BP_CUR=$(sha512sum blueprints/authentik/mediastack-portal.yaml | cut -d' ' -f1)
[[ "$(base "" "")" == '{"base_url":"https://portal.media.example.com"}' ]] || fail_ "unset: set it"; pass
[[ "$(base "https://old.media.example.com" "https://old.media.example.com")" == *portal.media.example.com* ]] || fail_ "still ours (a renamed host): re-point it"; pass
[[ "$(base "https://sso.mine.net" "")" == none ]] || fail_ "set in authentik's UI: never touched"; pass
[[ "$(base "https://portal.media.example.com" "")" == none ]] || fail_ "already right: no write"; pass

# ---- the gate ----
svc_enabled() { [[ "$1" == authentik && -n "${AK_ON:-}" ]]; }
AK_ON=1; mw=$(traefik_gate_middleware)
[[ "$mw" == *"mediastack-gate:"*"forwardAuth:"*"http://authentik:9000/outpost.goauthentik.io/auth/traefik"* ]] \
    || fail_ "with authentik: the gate asks its outpost"; pass
AK_ON=; mw=$(traefik_gate_middleware)
[[ "$mw" == *"mediastack-gate:"* && "$mw" != *forwardAuth* ]] || fail_ "without authentik: the gate is a no-op (Wizarr mode keeps today's access)"; pass

# the provider is ADDED to the built-in outpost, never replacing what is there;
# akadmin joins admins once; cards: one per gated tool, admins only, stale ones go
svc_enabled() { [[ "$1" == authentik ]]; }
authentik_gated() { printf '%s\n' apprise olivetin; }
authentik_household() { :; }
svc_url() { echo "https://$1.media.example.com"; }
svc_label() { echo "desc of $1"; }
rm -f "$T/state" "$T/calls"
ak_api() { echo "$1 $2 ${3:-}" >> "$T/calls"
    case "$1 $2" in
        "GET /providers/proxy/?name__iexact=mediastack-gate") echo '{"results":[{"pk":7}]}' ;;
        "GET /outposts/instances/?managed__iexact=goauthentik.io/outposts/embedded") echo '{"results":[{"pk":"op-1","providers":[3]}]}' ;;
        "GET /core/groups/?search=admins") echo '{"results":[{"pk":"g-adm","name":"admins"},{"pk":"g-x","name":"superadmins"}]}' ;;
        "GET /core/groups/?search=media-users") echo '{"results":[{"pk":"g-mu","name":"media-users"}]}' ;;
        "GET /core/users/?username=akadmin") echo '{"results":[{"pk":1}]}' ;;
        "GET /core/applications/?superuser_full_list=true&page_size=500")
            echo '{"results":[{"slug":"mediastack-tool-apprise","pk":"a-1","meta_launch_url":"https://apprise.media.example.com"},{"slug":"mediastack-tool-oldsvc","pk":"a-9"},{"slug":"my-own-app","pk":"a-5"}]}' ;;
        "POST /core/applications/") echo '{"pk":"a-new"}' ;;
        "GET /policies/bindings/?target=a-1") echo '{"results":[{"group":"g-adm"}]}' ;;
        "GET /policies/bindings/?target=a-new") echo '{"results":[]}' ;;
        *) echo '{}' ;;
    esac; }
wire_authentik_gate >/dev/null
grep -qF 'PATCH /outposts/instances/op-1/ {"providers":[3,7]}' "$T/calls" || fail_ "the gate is added beside the outpost's providers: $(grep PATCH "$T/calls")"; pass
grep -qF 'POST /core/groups/g-adm/add_user/ {"pk":1}' "$T/calls" || fail_ "akadmin joins 'admins' (not a lookalike group)"; pass
rm -f "$T/calls"; wire_authentik_gate >/dev/null
! grep -q 'add_user' "$T/calls" || fail_ "akadmin is added once — after that, 'admins' is yours"; pass
[[ "$(grep -c '^POST /core/applications/' "$T/calls")" == 1 ]] && grep -q '"slug":"mediastack-tool-olivetin"' "$T/calls" \
    || fail_ "a card for the gated tool that has none (olivetin), none for one that has (apprise)"; pass
grep -qF 'POST /policies/bindings/ {"target":"a-new","group":"g-adm","order":0}' "$T/calls" || fail_ "the new card is admins-only"; pass
grep -q '^DELETE /core/applications/mediastack-tool-oldsvc/' "$T/calls" || fail_ "a card for a tool no longer gated leaves"; pass
! grep -q 'my-own-app' <(grep -E '^(DELETE|PATCH)' "$T/calls") || fail_ "an application you made is never touched"; pass

# ---- "successful" counts only for the current file (found live: right after
#      an update, the status still described the previous version) ----
BP_APPLIED=old; rm -f "$T/calls"
ak_api() { echo "$1 $2" >> "$T/calls"
    case "$1 $2" in
        "GET /managed/blueprints/?page_size=200")
            h=$BP_CUR; [[ "$BP_APPLIED" == old ]] && h=deadbeef
            jq -cn --arg h "$h" --arg st "${BP_STATUS:-successful}" '{results:[{name:"Mediastack - Portal", status:$st, last_applied_hash:$h, pk:"bp-1"}]}' ;;
        "POST /managed/blueprints/bp-1/apply/") BP_APPLIED=new; echo '{}' ;;
        *) echo '{}' ;;
    esac; }
[[ "$(authentik_blueprint_status)" == outdated ]] || fail_ "an earlier file's success is 'outdated', not 'successful'"; pass
BP_STATUS=error; [[ "$(authentik_blueprint_status)" == error ]] || fail_ "a failed apply of a newer file says 'error', not 'outdated'"; pass
BP_STATUS=successful
BP_APPLIED=old; sleep() { :; }
[[ "$(authentik_blueprint_apply)" == successful ]] || fail_ "applying on demand brings the current file in"; pass
grep -q '^POST /managed/blueprints/bp-1/apply/' "$T/calls" || fail_ "the apply goes through authentik's API"; pass

# ---- ports close with the portal; logins trust it only once they have ----
printf 'COMPOSE_PROFILES=x\n' > "$ENV_FILE"
AK_ON=1; svc_enabled() { [[ "$1" == authentik && -n "${AK_ON:-}" ]]; }
gate_bind_sync >/dev/null; [[ "$(env_get MEDIASTACK_GATE_BIND)" == "127.0.0.1:" ]] || fail_ "with the portal: gated ports listen on 127.0.0.1"; pass
AK_ON=;  gate_bind_sync >/dev/null; [[ "$(env_get MEDIASTACK_GATE_BIND)" == "" ]] || fail_ "without it: gated ports reopen"; pass
svc_host() { echo "$1"; }; svc_cport() { echo 8989; }; svc_cname() { echo "c-$1"; }
sudo() { [[ "$1 $2" == "docker port" ]] && printf '%s' "$PORTS"; }
PORTS=$'127.0.0.1:8989\n';                svc_bound_local sonarr || fail_ "127.0.0.1 only: local"; pass
PORTS=$'0.0.0.0:8989\n[::]:8989\n';       ! svc_bound_local sonarr || fail_ "every address: not local"; pass
PORTS=$'127.0.0.1:8989\n0.0.0.0:8989\n';  ! svc_bound_local sonarr || fail_ "one open binding is enough to be reachable"; pass
PORTS="";                                 svc_bound_local sonarr || fail_ "nothing published: local"; pass
svc_label() { [[ "$2" == mediastack.auth ]] && echo "${AUTH:-gate}"; }
AK_ON=1 AUTH=gate PORTS=$'127.0.0.1:8989\n'; gate_trusted sonarr || fail_ "portal + gated + closed: trust it"; pass
AK_ON=1 AUTH=gate PORTS=$'0.0.0.0:8989\n';   ! gate_trusted sonarr || fail_ "still reachable by IP: keep its own login"; pass
AK_ON='' AUTH=gate PORTS=$'127.0.0.1:8989\n'; ! gate_trusted sonarr || fail_ "no portal: keep its own login"; pass
AK_ON=1 AUTH=native PORTS=$'127.0.0.1:8989\n'; ! gate_trusted sonarr || fail_ "not gated: keep its own login"; pass
unset -f sudo
# the arr's own login follows gate_trusted
arr_key() { echo k; }; arr_url() { echo http://x; }; arr_apiver() { echo v3; }
arr_forms_login() { echo "FORMS $1"; }
ensure_resource() { local m=$1; shift 4; shift; echo "ENSURE match=$m $*"; }
api() { echo '{"authenticationMethod":"forms","username":"u"}'; }
gate_trusted() { [[ -n "${TRUSTED:-}" ]]; }
TRUSTED=1; out=$(arr_login sonarr)
[[ "$out" == *'match=no'*'"authenticationMethod":"external"'* ]] || fail_ "trusted: switch to external: $out"; pass
TRUSTED=;  [[ "$(arr_login sonarr)" == "FORMS sonarr" ]] || fail_ "not trusted: its own forms login"; pass
# Traefik's dashboard: behind the gate with the portal, its own password without
AK_ON=1; grep -q 'middlewares: \[$(svc_enabled authentik && echo mediastack-gate || echo dash-auth)\]' lib/edge.sh \
    || fail_ "the dashboard router chooses the gate or its password by account model"; pass

# disabling the portal: every arr's own login is verified BEFORE the profile
# changes and the ports reopen (never open to the LAN without a login)
body=$(sed -n '/^cmd_disable() {/,/^}/p' mediastack.sh)
v=$(grep -n 'still trusts the portal' <<<"$body" | head -1 | cut -d: -f1)
e=$(grep -n 'env_set COMPOSE_PROFILES' <<<"$body" | head -1 | cut -d: -f1)
g=$(grep -n 'gate_bind_sync' <<<"$body" | head -1 | cut -d: -f1)
[[ -n "$v" && -n "$e" && -n "$g" ]] && (( v < e && e < g )) || fail_ "disable authentik: logins verified, then the profile, then the ports"; pass

# every arr-family login goes through arr_login — Prowlarr and a credential
# rotation included (found live: Prowlarr kept asking twice)
grep -q '^    arr_login prowlarr' lib/integrations.sh || fail_ "wire prowlarr: its login follows the trust rule"; pass
sed -n '/^sc_rotate_arr() {/,/^}/p' lib/access.sh | grep -q 'arr_login "\$s"' || fail_ "set-credentials arr: back to trusting the portal after the rotation"; pass
sed -n '/^cmd_disable() {/,/^}/p' mediastack.sh | grep -q 'for a in $(arr_instances) $(svc_enabled prowlarr && echo prowlarr)' \
    || fail_ "disable authentik restores Prowlarr's login too"; pass

# ---- credentials: the API keys companion apps need, with their addresses ----
arr_instances() { printf '%s\n' sonarr radarr; }
svc_enabled() { [[ " sonarr prowlarr bazarr authentik " == *" $1 "* ]]; }
arr_key() { [[ "$1" == sonarr ]] && echo SONKEY; [[ "$1" == prowlarr ]] && echo; return 0; }
bazarr_key() { echo BAZKEY; }
svc_url() { echo "https://$1.media.example.com"; }
hr() { echo "== $*"; }; info() { echo "INFO $*"; }
out=$(credentials_api_keys)
grep -qE '^sonarr +https://sonarr.media.example.com +SONKEY$' <<<"$out" || fail_ "an arr: its address and key: $out"; pass
grep -qE '^bazarr +https://bazarr.media.example.com +BAZKEY$' <<<"$out" || fail_ "bazarr's key"; pass
grep -qE '^prowlarr .*not created yet' <<<"$out" || fail_ "a key not minted yet says so"; pass
! grep -q '^radarr' <<<"$out" || fail_ "a service that is not enabled is not listed"; pass
grep -q 'the /api path skips its login' <<<"$out" || fail_ "behind the portal: how the app gets through"; pass

# ---- the stack network: Traefik's fixed address outside the pool ----
cidr_has 172.31.250.0/24 172.31.250.2 && ! cidr_has 172.31.250.128/25 172.31.250.2 && cidr_has 10.0.0.0/8 10.200.3.4 \
    || fail_ "cidr_has"; pass
printf '' > "$ENV_FILE"; [[ -z "$(network_problems)" ]] || fail_ "the defaults agree: $(network_problems)"; pass
printf 'TRAEFIK_ADDRESS=172.31.250.200\n' > "$ENV_FILE"
[[ "$(network_problems)" == *"inside MEDIASTACK_IP_RANGE"* ]] || fail_ "Traefik inside the pool is a problem"; pass
printf 'TRAEFIK_ADDRESS=10.9.9.9\n' > "$ENV_FILE"
[[ "$(network_problems)" == *"not inside MEDIASTACK_SUBNET"* ]] || fail_ "Traefik outside the network is a problem"; pass

# ---- who may name the user: Traefik's address while the portal runs, nobody otherwise ----
printf 'TRAEFIK_ADDRESS=172.31.250.2\n' > "$ENV_FILE"
svc_enabled() { [[ "$1" == authentik && -n "${AK_ON:-}" ]]; }
AK_ON=1; gate_bind_sync >/dev/null; [[ "$(env_get MEDIASTACK_GATE_TRUST)" == 172.31.250.2/32 ]] || fail_ "trust: Traefik only"; pass
AK_ON='';  gate_bind_sync >/dev/null; [[ "$(env_get MEDIASTACK_GATE_TRUST)" == "" ]] || fail_ "no portal: trust nobody"; pass
grep -q 'ND_EXTAUTH_TRUSTEDSOURCES=${MEDIASTACK_GATE_TRUST:-}' compose.d/navidrome.yml || fail_ "Navidrome trusts exactly MEDIASTACK_GATE_TRUST"; pass
for AK_ON in 1 ''; do
    mw=$(traefik_gate_middleware)
    [[ "$mw" == *"mediastack-strip:"*'X-authentik-username: ""'* ]] || fail_ "the strip middleware exists in both account models"; pass
done

# ---- household apps: their own cards; Navidrome's carries its household gate ----
svc_enabled_managed() { printf '%s\n' sonarr navidrome jellyfin; }
svc_label() { case "$1:$2" in
    sonarr:mediastack.auth) echo gate ;; navidrome:mediastack.auth) echo gate ;;
    navidrome:mediastack.auth.group) echo media-users ;;
    navidrome:mediastack.user_facing|jellyfin:mediastack.user_facing) echo true ;;
    *:mediastack.desc) echo "desc of ${1%%:*}" ;; esac; }
unset -f authentik_gated authentik_household
# shellcheck disable=SC1090  # the two real functions, back from their stubs
source <(sed -n '/^authentik_gated() {/,/^}/p; /^authentik_household() {/,/^}/p' lib/authentik.sh)
[[ "$(authentik_gated | tr '\n' ' ')" == "sonarr " ]] || fail_ "the household-gated app is not an admin tool: $(authentik_gated)"; pass
[[ "$(authentik_household | tr '\n' ' ')" == "navidrome jellyfin " ]] || fail_ "household apps by mediastack.user_facing"; pass
rm -f "$T/calls"
ak_api() { echo "$1 $2 ${3:-}" >> "$T/calls"
    case "$1 $2" in
        "GET /core/applications/?superuser_full_list=true&page_size=500") echo '{"results":[{"slug":"mediastack-app-kavita","pk":"a-k"}]}' ;;
        "GET /core/groups/?search=admins") echo '{"results":[{"pk":"g-adm","name":"admins"}]}' ;;
        "GET /core/groups/?search=media-users") echo '{"results":[{"pk":"g-mu","name":"media-users"}]}' ;;
        "GET /providers/proxy/?name__iexact=mediastack-house-navidrome") echo '{"results":[]}' ;;
        "GET /flows/instances/?slug="*) echo '{"results":[{"pk":"flow-x"}]}' ;;
        "POST /providers/proxy/") echo '{"pk":42}' ;;
        "GET /outposts/instances/?managed__iexact=goauthentik.io/outposts/embedded") echo '{"results":[{"pk":"op-1","providers":[6]}]}' ;;
        "POST /core/applications/") echo '{"pk":"a-new"}' ;;
        "GET /policies/bindings/?target=a-new") echo '{"results":[]}' ;;
        *) echo '{}' ;;
    esac; }
wire_authentik_cards >/dev/null
grep -q '^POST /providers/proxy/ .*"name":"mediastack-house-navidrome".*"mode":"forward_single".*"external_host":"https://navidrome.media.example.com"' "$T/calls" \
    || fail_ "Navidrome's household gate: forward auth for its one address"; pass
grep -qF 'PATCH /outposts/instances/op-1/ {"providers":[6,42]}' "$T/calls" || fail_ "the household gate joins the outpost beside the admin gate"; pass
grep -q '^POST /core/applications/ .*"slug":"mediastack-app-navidrome".*"provider":42' "$T/calls" || fail_ "Navidrome's card carries its gate"; pass
grep -q '^POST /core/applications/ .*"slug":"mediastack-app-jellyfin".*"group":"Media"' "$T/calls" \
    && ! grep -q '"slug":"mediastack-app-jellyfin".*"provider"' "$T/calls" || fail_ "Jellyfin: a plain Media card (its own login)"; pass
[[ "$(grep -c '^POST /policies/bindings/ .*"group":"g-mu"' "$T/calls")" == 2 && "$(grep -c '^POST /policies/bindings/ .*"group":"g-adm"' "$T/calls")" == 3 ]] \
    || fail_ "household cards: media-users and admins; admin tools: admins"; pass
grep -q '^DELETE /core/applications/mediastack-app-kavita/' "$T/calls" || fail_ "a household card for an app no longer enabled leaves"; pass

# ---- LDAP: the outpost gets its token from authentik; the route answers the stack only ----
rm -f "$T/calls"; printf '' > "$ENV_FILE"
DC() { echo "DC $*" >> "$T/calls"; }
ak_api() { echo "$1 $2" >> "$T/calls"
    case "$1 $2" in
        "GET /outposts/instances/?name__iexact=mediastack-ldap") echo '{"results":[{"pk":"op-ldap"}]}' ;;
        "GET /core/tokens/ak-outpost-op-ldap-api/view_key/") echo '{"key":"LDAPTOKEN"}' ;;
        *) echo '{}' ;;
    esac; }
wire_authentik_ldap_token >/dev/null
[[ "$(env_get AUTHENTIK_LDAP_TOKEN)" == LDAPTOKEN ]] && grep -q '^DC up -d --no-deps authentik-ldap' "$T/calls" || fail_ "the outpost's token is fetched, then the outpost starts"; pass
rm -f "$T/calls"; wire_authentik_ldap_token >/dev/null
! grep -q '^DC ' "$T/calls" || fail_ "the same token: nothing restarts"; pass
AK_ON=1; svc_enabled() { [[ "$1" == authentik && -n "${AK_ON:-}" ]]; }
grep -q 'mediastack-ldap-allow:' lib/edge.sh && grep -q 'sourceRange: \["$(env_get MEDIASTACK_SUBNET 172.31.250.0/24)"\]' lib/edge.sh \
    || fail_ "the LDAP route answers the stack network only"; pass
grep -q 'traefik.tcp.routers.authentik-ldap.middlewares: "mediastack-ldap-allow@file"' compose.d/authentik.yml || fail_ "the LDAP route carries the allow-list"; pass
bp=blueprints/authentik/mediastack-portal.yaml
sed -n '/name: mediastack-ldap$/,/^  - /p' "$bp" | grep -q 'mfa_support: false' || fail_ "LDAP binds: no MFA prompt (TV apps cannot answer one)"; pass
sed -n '/name: mediastack-ldap$/,/^  - /p' "$bp" | grep -q 'authorization_flow: !KeyOf flow-ldap' \
    || fail_ "the outpost binds through authorization_flow — it must be the LDAP bind flow (found live)"; pass
sed -n '/model: authentik_outposts.outpost/,/^  - /p' "$bp" | grep -q '^      config:' || fail_ "an outpost needs its config block (authentik requires it; found live)"; pass
grep -A3 'permissions:' "$bp" | grep -q 'permission: authentik_providers_ldap.search_full_directory' \
    || fail_ "only the search account may list the directory — by the full permission name (the dry run rejects the short form)"; pass
# reputation: it PASSES for a bad score, so bound negated, at the login step
# (the user is known there), by username only (every bind shares Traefik's IP)
sed -n '/target: !KeyOf binding-ldap-login/,/^  - /p' "$bp" | grep -q 'policy: !KeyOf policy-ldap-reputation' \
    && sed -n '/target: !KeyOf binding-ldap-login/,/^  - /p' "$bp" | grep -q 'negate: true' || fail_ "reputation: negated, at the login step"; pass
sed -n '/name: mediastack-ldap-reputation/,/^  - /p' "$bp" | grep -q 'check_ip: false' || fail_ "reputation by username only — binds share one IP"; pass
sed -n '/stage: !KeyOf stage-ldap-login/,/^  - /p' "$bp" | grep -q 're_evaluate_policies: true' || fail_ "the login step re-checks once the user is known"; pass
grep -B3 'target: !KeyOf flow-ldap$' "$bp" | grep -q 'state: absent' || fail_ "the old flow-level binding is removed"; pass
[[ "$(grep -c 'target: !KeyOf app-ldap' "$bp")" == 3 ]] || fail_ "binds: media-users, admins, the search account — nobody else"; pass

# ---- update --to: the outpost and worker move with the server, the database stays ----
svc_members() { printf '%s\n' authentik-db authentik-ldap authentik-worker; }
svc_image() { case "$1" in authentik|authentik-worker) echo ghcr.io/goauthentik/server:2026.8 ;;
    authentik-ldap) echo ghcr.io/goauthentik/ldap:2026.8 ;; authentik-db) echo postgres:16 ;; esac; }
pin_service() { echo "PIN $1 $2"; }
got=$(pin_shard_to authentik 2026.11 | sort | tr '\n' ';')
[[ "$got" == "PIN authentik ghcr.io/goauthentik/server:2026.11;PIN authentik-ldap ghcr.io/goauthentik/ldap:2026.11;PIN authentik-worker ghcr.io/goauthentik/server:2026.11;" ]] \
    || fail_ "lockstep pinning: $got"; pass

# ---- a rejected blueprint explains itself: authentik's validator, run dry ----
svc_cname() { echo "c-$1"; }
sudo() { [[ "$1 $2" == "docker exec" ]] && printf '%s\n' '{"event": "Imported related module"}' 'Blueprint invalid' \
    "	authentik.blueprints.v1.importer: Entry invalid: Serializer errors {'config': [ErrorDetail(string='This field is required.', code='required')]}: {'entry': {'model': 'x'}}" \
    '	authentik.blueprints.v1.importer: Blueprint validation failed: {}'; }
why=$(authentik_blueprint_why)
[[ "$why" == *"Entry invalid: Serializer errors {'config'"*"This field is required"* && "$why" != *"'entry':"* && "$why" != *Imported* ]] \
    || fail_ "the validator's reason, without the entry dump or import noise: $why"; pass
unset -f sudo

# ---- Jellyfin through LDAP ----
# a plugin is found by its ID, whatever name it loads under (found live: the
# catalog's "LDAP Authentication" loads as "LDAP-Auth")
ids=$(jf_plugin_ids '[{"Name":"LDAP-Auth","Id":"958aad6637844d2ab89aa7b6fab6e25c"},{"Name":"Webhook","Id":"71552A5A-5C5C-4350-A2AE-EBE451A30173"}]')
[[ "$ids" == *"|$(jf_guid "$JF_LDAP_GUID")|"* && "$ids" == *"|$(jf_guid 71552A5A-5C5C-4350-A2AE-EBE451A30173)|"* ]] \
    || fail_ "plugins matched by ID, with or without dashes, any case: $ids"; pass
printf 'TRAEFIK_DOMAIN=media.example.com\nAUTHENTIK_LDAP_BIND_PASSWORD=BINDPW\nACME_ENV=staging\n' > "$ENV_FILE"
w=$(jf_ldap_want)
[[ "$(jq -r '.LdapServer + ":" + (.LdapPort|tostring) + " ssl=" + (.UseSsl|tostring)' <<<"$w")" == "ldap.media.example.com:443 ssl=true" ]] \
    || fail_ "LDAPS to ldap.<domain>:443 through Traefik: $w"; pass
[[ "$(jq -r '.SkipSslVerify' <<<"$w")" == true ]] || fail_ "staging certificates: checking off"; pass
printf 'TRAEFIK_DOMAIN=media.example.com\nACME_ENV=production\n' > "$ENV_FILE"
[[ "$(jf_ldap_want | jq -r '.SkipSslVerify')" == false ]] || fail_ "production certificates: checking on"; pass
[[ "$(jq -r '.LdapSearchFilter' <<<"$w")" == "(|(memberOf=cn=media-users,ou=groups,dc=ldap,dc=mediastack)(memberOf=cn=admins,ou=groups,dc=ldap,dc=mediastack))" ]] \
    || fail_ "media-users or admins may sign in"; pass
[[ "$(jq -r '.CreateUsersFromLdap and .EnableAllFolders' <<<"$w")" == true ]] || fail_ "created on first sign-in, every library"; pass
# configure: managed settings merged over the rest; unchanged: no write
rm -f "$T/calls"
JF_CFG='{"LdapServer":"old","Other":"keep"}'
jf_api() { echo "$1 $2 ${4:-}" >> "$T/calls"; case "$1 $2" in "GET /Plugins/$JF_LDAP_GUID/Configuration") echo "$JF_CFG" ;; *) echo '{}' ;; esac; }
jf_code() { echo 200; }
jf_ldap_configure tok >/dev/null
body=$(grep "^POST /Plugins/$JF_LDAP_GUID/Configuration" "$T/calls" | cut -d' ' -f3-)
[[ "$(jq -r '.Other + " " + .LdapServer' <<<"$body")" == "keep ldap.media.example.com" ]] || fail_ "only mediastack's settings change: $body"; pass
JF_CFG=$(jq -c --argjson w "$(jf_ldap_want)" '. + $w' <<<'{"Other":"keep"}'); rm -f "$T/calls"
jf_ldap_configure tok >/dev/null; ! grep -q '^POST' "$T/calls" || fail_ "already right: no write"; pass
# admin sync: directory users follow `admins`; local accounts are never touched
rm -f "$T/calls"
ak_api() { echo '{"results":[{"username":"akadmin"},{"username":"nick"}]}'; }
jf_api() { echo "$1 $2 ${4:-}" >> "$T/calls"
    case "$1 $2" in
        "GET /Users") jq -cn --arg p "$JF_LDAP_PROVIDER" '[
            {Name:"akadmin", Id:"1", Policy:{IsAdministrator:false, AuthenticationProviderId:$p}},
            {Name:"test-thio", Id:"2", Policy:{IsAdministrator:true, AuthenticationProviderId:$p}},
            {Name:"nick", Id:"3", Policy:{IsAdministrator:true, AuthenticationProviderId:$p}},
            {Name:"mediastack", Id:"4", Policy:{IsAdministrator:true, AuthenticationProviderId:"Jellyfin.Server.Implementations.Users.DefaultAuthenticationProvider"}}]' ;;
        *) echo '{}' ;;
    esac; }
jf_admin_sync tok >/dev/null
grep -q '^POST /Users/1/Policy .*"IsAdministrator":true' "$T/calls" || fail_ "an admin in the directory becomes a Jellyfin administrator"; pass
grep -q '^POST /Users/2/Policy .*"IsAdministrator":false' "$T/calls" || fail_ "a directory user not in admins loses administrator"; pass
! grep -q '^POST /Users/3/' "$T/calls" || fail_ "already right: no write"; pass
! grep -q '^POST /Users/4/' "$T/calls" || fail_ "the stack's own local admin is never touched"; pass

# ---- Audiobookshelf: the stack's root, sign-in through the portal, admin sync ----
printf 'TRAEFIK_DOMAIN=media.example.com\nAUTHENTIK_ABS_CLIENT_SECRET=ABSSEC\nPORTAL_TITLE=Home\n' > "$ENV_FILE"
w=$(abs_oidc_want)
[[ "$(jq -r '.authOpenIDIssuerURL' <<<"$w")" == "https://portal.media.example.com/application/o/mediastack-app-audiobookshelf/" \
   && "$(jq -r '.authOpenIDTokenURL' <<<"$w")" == "https://portal.media.example.com/application/o/token/" \
   && "$(jq -r '.authOpenIDJwksURL' <<<"$w")" == "https://portal.media.example.com/application/o/mediastack-app-audiobookshelf/jwks/" ]] \
    || fail_ "Audiobookshelf's portal addresses: $w"; pass
[[ "$(jq -r '[.authOpenIDClientSecret, .authOpenIDTokenSigningAlgorithm, (.authOpenIDAutoRegister|tostring), .authOpenIDMatchExistingBy, .authOpenIDButtonText] | join(",")' <<<"$w")" == "ABSSEC,RS256,true,username,Log in with Home" ]] \
    || fail_ "secret, RS256, created on first sign-in, matched by username, the portal's name on the button"; pass
[[ "$(jq -c '.authActiveAuthMethods' <<<"$w")" == '["local","openid"]' ]] || fail_ "its own login stays (the stack's root account)"; pass
[[ "$(jq -r '.authOpenIDSubfolderForRedirectURLs | type + ":" + .' <<<"$w")" == "string:" ]] \
    || fail_ "no subfolder, set explicitly — unset, its callback reads undefined/auth/openid/callback (found live)"; pass
# first run: a fresh Audiobookshelf gets the stack's root; a hand-made one is not taken over
rm -f "$T/calls"; printf 'TRAEFIK_DOMAIN=media.example.com\n' > "$ENV_FILE"
svc_enabled() { [[ "$1" == audiobookshelf ]]; }; wire_gate() { :; }; http_ready() { :; }; abs_url() { echo http://abs; }
ABS_INIT=false
abs_api() { echo "$1 $2 ${4:-}" >> "$T/calls"
    case "$1 $2" in
        "GET /status") echo "{\"isInit\":$ABS_INIT}" ;;
        "POST /init") echo 'OK' ;;
        "POST /login") echo '{"user":{"accessToken":"ABSTOK"}}' ;;
        *) echo '{}' ;;
    esac; }
wire_audiobookshelf >/dev/null
grep -q '^POST /init {"newRoot":{"username":"mediastack","password":"' "$T/calls" && [[ "$(env_get ABS_ADMIN_USER)" == mediastack && -n "$(env_get ABS_ADMIN_PASSWORD)" ]] \
    || fail_ "a fresh Audiobookshelf: the stack's root account, stored"; pass
grep -q '^POST /login' "$T/calls" || fail_ "then it logs in with it"; pass
rm -f "$T/calls"; printf '' > "$ENV_FILE"; ABS_INIT=true; WIRE_FAILS=0
out=$(wire_audiobookshelf 2>&1) || true
! grep -q '^POST /init' "$T/calls" && [[ "$out" == *"set up by hand"*"ABS_ADMIN_USER"* ]] || fail_ "one set up by hand is never taken over — it says what to do"; pass
# admin sync: portal-linked accounts follow admins; root and local ones are untouched
rm -f "$T/calls"
ak_api() { echo '{"results":[{"username":"akadmin"}]}'; }
abs_api() { echo "$1 $2 ${4:-}" >> "$T/calls"
    case "$1 $2" in
        "GET /api/users") echo '{"users":[
            {"id":"r","username":"mediastack","type":"root","hasOpenIDLink":false},
            {"id":"a","username":"akadmin","type":"user","hasOpenIDLink":true},
            {"id":"t","username":"test-thio","type":"admin","hasOpenIDLink":true},
            {"id":"l","username":"local-bob","type":"admin","hasOpenIDLink":false}]}' ;;
        *) echo '{}' ;;
    esac; }
abs_admin_sync tok >/dev/null
grep -q '^PATCH /api/users/a {"type":"admin"}' "$T/calls" && grep -q '^PATCH /api/users/t {"type":"user"}' "$T/calls" \
    || fail_ "portal accounts: admins are admin, the rest user"; pass
! grep -qE '^PATCH /api/users/(r|l) ' "$T/calls" || fail_ "the root account and local accounts are never touched"; pass
# the blueprint's OIDC provider for it
sed -n '/name: mediastack-oidc-audiobookshelf/,/^  - model/p' blueprints/authentik/mediastack-portal.yaml > "$T/abs"
grep -q 'client_id: mediastack-audiobookshelf' "$T/abs" && grep -q 'signing_key: !Find' "$T/abs" \
   && grep -q '/auth/openid/callback' "$T/abs" && grep -q '/auth/openid/mobile-redirect' "$T/abs" \
    || fail_ "the OIDC provider: its client ID, a signing key (RS256), web and app redirects"; pass

echo "OK authentik: $checks checks"
