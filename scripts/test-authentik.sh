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
#   * the base URL is set when unset or still mediastack's, never over one
#     set in authentik's UI
#   * the gate: Traefik's middleware asks authentik only when it runs; wire
#     adds the gate beside the outpost's providers, puts akadmin in admins
#     once, keeps one admins-only card per gated tool and never touches
#     applications it did not make
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
[[ "$(grep -c 'stage: !KeyOf stage-' "$bp")" == 4 ]] || fail_ "four stages bound: invitation, the page, write, login"; pass
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
svc_url() { echo "https://$1.media.example.com"; }
svc_label() { echo "desc of $1"; }
rm -f "$T/state" "$T/calls"
ak_api() { echo "$1 $2 ${3:-}" >> "$T/calls"
    case "$1 $2" in
        "GET /providers/proxy/?name__iexact=mediastack-gate") echo '{"results":[{"pk":7}]}' ;;
        "GET /outposts/instances/?managed__iexact=goauthentik.io/outposts/embedded") echo '{"results":[{"pk":"op-1","providers":[3]}]}' ;;
        "GET /core/groups/?search=admins") echo '{"results":[{"pk":"g-adm","name":"admins"},{"pk":"g-x","name":"superadmins"}]}' ;;
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
            jq -cn --arg h "$h" '{results:[{name:"Mediastack - Portal", status:"successful", last_applied_hash:$h, pk:"bp-1"}]}' ;;
        "POST /managed/blueprints/bp-1/apply/") BP_APPLIED=new; echo '{}' ;;
        *) echo '{}' ;;
    esac; }
[[ "$(authentik_blueprint_status)" == outdated ]] || fail_ "an earlier file's success is 'outdated', not 'successful'"; pass
BP_APPLIED=old; sleep() { :; }
[[ "$(authentik_blueprint_apply)" == successful ]] || fail_ "applying on demand brings the current file in"; pass
grep -q '^POST /managed/blueprints/bp-1/apply/' "$T/calls" || fail_ "the apply goes through authentik's API"; pass

echo "OK authentik: $checks checks"
