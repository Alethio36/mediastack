#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-authentik.sh — the authentik shard's rules.
#   * upgrades walk authentik's releases one at a time and never go back; a
#     new database may start on any known release; the release is read from an
#     image tag or a version
#   * secrets: generated once, letters and digits only, never replaced — and
#     refused outright when the database already exists without them
#   * account models: authentik and Wizarr conflict (declared on either side),
#     and a conflict pair in a selection is found; configure asks which one
#     (none, Wizarr, authentik) every time, whatever the preset — a re-run
#     keeping both services and model leaves .env untouched
#   * a shard member is never a dependency to enable (it comes with its
#     primary's profile)
#   * a service an upgrade adds gets its UID before it first starts
#   * the portal's blueprint: sign-up needs an invitation, makes internal users
#     in frontend, requires an email; the worker gets its values and mount
#   * invitations: single use, bound to the sign-up flow, 7 days by default
#   * Jellyfin through LDAP: LDAPS to ldap.<domain> through Traefik, checking
#     on with production certificates, frontend or admin, every library;
#     only mediastack's plugin settings change; admin rights follow the admin group
#     for directory users and never touch local accounts
#   * the base URL is set when unset or still mediastack's, never over one
#     set in authentik's UI
#   * values the blueprint reads from the worker (!Env) reach authentik: wire
#     records them (as digests) at each apply and applies again when the
#     worker's differ — --verify and doctor report it; an apply waits for the
#     apply it asked for, even when the file was already applied
#   * a first start: authentik is wired before jellyfin, and wire waits
#     (bounded) for the blueprint to be discovered — a timeout is a failure,
#     a dry run never waits
#   * the first wire's restore point waits (bounded) for a first start's own
#     pass to finish, so its stop does not start authentik over
#   * a tool with no login of its own (Apprise): through the portal, or — with
#     no portal — refused at Traefik and reached on this host only
#   * the gate: Traefik's middleware asks authentik only when it runs; wire
#     adds the gate beside the outpost's providers, puts akadmin in admin
#     once, keeps one admin-only card per gated tool and never touches
#     applications it did not make
#   * gated ports listen on 127.0.0.1 while the portal runs; an arr trusts the
#     portal only when it is gated AND unreachable by IP, its own login otherwise
#   * the stack network keeps Traefik on a fixed address outside the pool;
#     only that address may name a user (Navidrome), and every route past a
#     gate strips the portal's headers
#   * household apps get Media cards for the household; Navidrome's carries its
#     own household gate (forward auth for its one address)
#   * Audiobookshelf through OIDC: never matched to an existing account, the
#     settings read back after a write, a root linked to the portal unlinked
#     and its password rotated (ends its sessions); admin rights follow
#     the admin group, a guest outside it stays a guest
#   * sign-up refuses a username the apps would confuse: the stack's own app
#     accounts (any case) and an existing person's name in another case
#   * Kavita: published on 127.0.0.1; its OIDC provider; the stack's admin with
#     an unclaimable email (a hand-made one never taken over, a claimable email
#     warned); sign-in merged into its settings, read back, one restart only
#     when its start-up part changes (the secret by digest); every current
#     library for new people; admin sync on portal accounts only, the whole
#     record back with only the roles changed; doctor reports library gaps
#   * link-account: only local accounts offered (never the stack's own); the
#     same name is the default choice; Jellyfin renamed and moved to the LDAP
#     plugin's login, the rest of the account as it was; Kavita renamed, given
#     the portal email and portal flag, everything else exact, its own password
#     replaced; Audiobookshelf's window refused while another unlinked account
#     (root included) could be claimed, and closed once linked or timed out
#   * credentials: Audiobookshelf's root and akadmin rotate through their APIs
#     into .env; reset-password clears a person's login throttle and mints a
#     single-use link, never for akadmin, the search account, a service
#     account or a deactivated one
#   * password reset by email: the flow never reveals an account, never
#     creates one, leaves a deactivated one deactivated and clears the login
#     throttle; its email is mediastack's own (no inline logo, the portal's
#     name as data, byte-stable), synced and read by a restart on change; the
#     sign-in page links it only while email has passed a test, never over a
#     flow set in authentik's UI; doctor fails a link without working email
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
people_timer_ensure() { :; }   # a wire reaching the portal step starts it (systemd): scripts/test-people.sh

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
# a digest pin (restore, rollback) names no release: the image's own version label does
# (found live Nov 2026: up after restore --all died on 'server@sha256:…')
dig=ghcr.io/goauthentik/server@sha256:6b924afb97053a27ca3f42f006c920464fb77763558c72219019365db191827b
ri() { ( sudo() { case "$*" in "docker image inspect -f"*) echo "$LABEL" ;; "docker image inspect "*) [[ -n "$HAVE" ]] ;; "docker pull"*) echo pulled >> "$T/pull"; HAVE=1; [[ -z "$PULLFAIL" ]] ;; esac; }
       authentik_image_release "$1" ) 2>/dev/null; }
LABEL=2026.8.2 HAVE=1 PULLFAIL=""; : > "$T/pull"
[[ "$(ri "$dig")" == 2026.8 && ! -s "$T/pull" ]] || fail_ "a digest pin: the release from the image's label ($(ri "$dig"))"; pass
HAVE="" ; [[ "$(ri "$dig")" == 2026.8 && -s "$T/pull" ]] || fail_ "a digest pin not on this host yet (a rebuild): pulled, then read"; pass
HAVE="" PULLFAIL=1; ri "$dig" >/dev/null && fail_ "a pull that fails: no release, never a guess"; pass
PULLFAIL=""; HAVE=1; [[ "$(ri ghcr.io/goauthentik/server:2026.5)" == 2026.5 ]] || fail_ "a tag still reads as before"; pass
# the fragment's tag is a release the list knows (so a fresh install can start)
tag=$(awk '/image: ghcr.io\/goauthentik\/server:/ { sub(/.*:/, ""); print; exit }' services/authentik/compose.yml)
[[ " ${AUTHENTIK_RELEASES[*]} " == *" $(authentik_release_of "$tag") "* ]] || fail_ "the fragment's tag $tag is not in AUTHENTIK_RELEASES"; pass
[[ "$(grep -c "image: ghcr.io/goauthentik/server:$tag$" services/authentik/compose.yml)" == 2 ]] || fail_ "server and worker must run the same tag"; pass
grep -q "image: ghcr.io/goauthentik/ldap:$tag$" services/authentik/compose.yml || fail_ "the LDAP outpost must run the server's release (authentik requires it)"; pass
# the outpost starts once the server is ready: its startup backoff is uncapped,
# so a late first fetch outlives its start period (6 Oct 2026)
sed -n '/^  authentik-ldap:/,/^  authentik-db:/p' services/authentik/compose.yml > "$T/ldap"
grep -q '/-/health/ready/' "$T/ldap" && grep -q 'exec /ldap$' "$T/ldap" \
    || fail_ "the LDAP outpost must wait for the server's readiness, then exec /ldap"; pass
# doctor's log-noise count: a boot's info/warn lines are not errors, a level is
# (one start matched the word "error" ~26 times and tripped the 25/24h warning)
re=$(sed -n "s/^ *mediastack\.errors: '\(.*\)'\$/\1/p" services/authentik/compose.yml)
[[ -n "$re" ]] || fail_ "the authentik server declares no mediastack.errors pattern"; pass
saved=$RENDERED_JSON
RENDERED_JSON=$(jq -n --arg re "$re" '{services:{authentik:{labels:{"mediastack.errors":$re}},plain:{labels:{}}}}')
boot='{"level":"warn","target":"authentik::server","event":"failed to send health live request to server","error":"connection refused"}
{"event": "Starting gunicorn 26.0.0", "level": "info", "logger": "gunicorn.error"}
{"event":"installing error formatting","level":"info"}'
real='{"event": "Task failed", "level": "error", "logger": "authentik.tasks"}'
[[ "$(log_errors authentik <<<"$boot")" == 0 ]] || fail_ "authentik's boot lines counted as errors"; pass
[[ "$(log_errors authentik <<<"$boot"$'\n'"$real")" == 1 ]] || fail_ "an error-level line must count"; pass
[[ "$(log_errors plain <<<"$boot")" == 3 ]] || fail_ "a service with no pattern keeps the default (any line naming an error)"; pass
# every container in the shard counts by its own pattern; doctor reads the members too
for m in authentik-worker authentik-ldap authentik-db; do
    grep -q 'mediastack.errors:' <<<"$(sed -n "/^  $m:/,/^  [a-z-]*:\$/p" services/authentik/compose.yml)" || fail_ "$m declares no mediastack.errors"; pass
done
grep -q 'for s in $(svc_shard $(svc_enabled_managed)); do' <(awk '/^_doctor_runtime_audit\(\)/,/^}/' lib/doctor.sh) \
    || fail_ "doctor's log-noise check covers shard members"; pass
re=$(sed -n "/^  authentik-db:/,/^  [a-z-]*:\$/p" services/authentik/compose.yml | sed -n "s/^ *mediastack\.errors: '\(.*\)'\$/\1/p")
RENDERED_JSON=$(jq -n --arg re "$re" '{services:{"authentik-db":{labels:{"mediastack.errors":$re}}}}')
pg='2026-10-08 03:09:53.702 PDT [1] LOG:  database system is ready to accept connections
2026-10-08 03:10:01.000 PDT [9] ERROR:  relation "x" does not exist
2026-10-08 03:10:02.000 PDT [9] FATAL:  terminating connection due to administrator command'
[[ "$(log_errors authentik-db <<<"$pg")" == 1 ]] || fail_ "postgres: FATAL counts; a handled ERROR and LOG lines do not"; pass
# kavita: its migrations logged at [Fatal] are routine; a real Error/Fatal counts
k_re=$(sed -n "s/^ *mediastack\.errors: '\(.*\)'\$/\1/p" services/kavita/compose.yml)
k_ex=$(sed -n "s/^ *mediastack\.errors\.except: '\(.*\)'\$/\1/p" services/kavita/compose.yml)
RENDERED_JSON=$(jq -n --arg re "$k_re" --arg ex "$k_ex" '{services:{kavita:{labels:{"mediastack.errors":$re,"mediastack.errors.except":$ex}}}}')
kv='[Kavita] [2026-10-14 07:12:00 -07:00  7] [Fatal] Kavita.Server.Program Running ManualMigrateX migration - Please be patient, this may take some time.
[Kavita] [2026-10-14 07:12:01 -07:00  7] [Fatal] Kavita.Server.Program Running ManualMigrateX migration - Completed. This is not an error
[Kavita] [2026-10-14 07:12:02 -07:00  7] [Information] Kavita.Server Starting
[Kavita] [2026-10-14 07:13:00 -07:00  9] [Error] Kavita.Services.ScannerService Library scan failed'
[[ "$(log_errors kavita <<<"$kv")" == 1 ]] || fail_ "kavita: its migration lines are routine, a real error counts: $(log_errors kavita <<<"$kv")"; pass
RENDERED_JSON=$saved

# ---- secrets ----
s=$(gen_secret 60)
[[ ${#s} == 60 && "$s" =~ ^[A-Za-z0-9]+$ ]] || fail_ "a secret: 60 letters and digits, got '$s'"; pass
ENV_FILE=$T/env; printf 'AUTHENTIK_DB_PASSWORD=keepme\n' > "$ENV_FILE"
authentik_has_db() { return 1; }
authentik_secrets_make
[[ "$(env_get AUTHENTIK_DB_PASSWORD)" == keepme ]] || fail_ "an existing secret must never be replaced"; pass
[[ "$(env_get AUTHENTIK_SECRET_KEY | wc -c)" == 61 && "$(env_get AUTHENTIK_API_TOKEN | wc -c)" == 65 ]] \
    || fail_ "missing secrets must be generated at their lengths"; pass
printf 'AUTHENTIK_SECRET_KEY=x\n' > "$ENV_FILE"
authentik_has_db() { return 0; }
out=$( (authentik_secrets_make) 2>&1 ) && fail_ "a database without its password must stop, not get a new one"
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

# ---- the portal's setup (services/authentik/blueprints/) ----
bp=services/authentik/blueprints/mediastack-portal.yaml
grep -q "^  name: $AUTHENTIK_BLUEPRINT\$" "$bp" || fail_ "the blueprint's name must be AUTHENTIK_BLUEPRINT ($AUTHENTIK_BLUEPRINT)"; pass
grep -q "^      slug: $AUTHENTIK_JOIN_FLOW\$" "$bp" || fail_ "the sign-up flow's slug must be AUTHENTIK_JOIN_FLOW"; pass
# household members are internal (external users never see the app dashboard), in frontend
grep -q 'name: mediastack-join-write' <<<"$(grep -A4 'model: authentik_stages_user_write.userwritestage' "$bp")" \
    && grep -q 'user_type: internal' <<<"$(sed -n '/name: mediastack-join-write/,/^  - /p' "$bp")" \
    && grep -q 'create_users_group: !KeyOf group-frontend' <<<"$(sed -n '/name: mediastack-join-write/,/^  - /p' "$bp")" \
    || fail_ "sign-up must create internal users in frontend"; pass
# the groups' names: the blueprint writes them out, the code reads PORTAL_* — held equal
[[ "$(awk '/id: group-frontend$/{f=1} f && /name:/{print $2; exit}' "$bp") $(awk '/id: group-admin$/{f=1} f && /name:/{print $2; exit}' "$bp")" == "$PORTAL_FRONTEND $PORTAL_ADMIN" ]] \
    || fail_ "the blueprint's group names are PORTAL_FRONTEND and PORTAL_ADMIN"; pass
[[ "$(grep -oP 'mediastack.auth.group: "\K[^"]+' services/navidrome/compose.yml)" == "$PORTAL_FRONTEND" ]] \
    || fail_ "Navidrome's household gate names PORTAL_FRONTEND"; pass
# the rename, in place and only while the old group exists — before the entries that find the new names
r=$(awk '/^  - model:/{m=$0} /id: group-rename-media-users$|id: group-rename-admins$|id: group-frontend$|id: group-admin$/{print $2}' "$bp" | paste -sd' ' -)
[[ "$r" == "group-rename-media-users group-rename-admins group-frontend group-admin" ]] || fail_ "the rename entries come first: $r"; pass
for pair in "media-users frontend" "admins admin"; do
    set -- $pair
    blk=$(sed -n "/id: group-rename-$1\$/,/^  - model:/p" "$bp")
    # authentik's importer merges an entry's identifiers OVER its attrs: found by
    # its name, the group would get the old name back (found live, 16 Nov 2026)
    grep -qF -- "- !Find [authentik_core.group, [name, $1]]" <<<"$blk" \
        && grep -qF -- "pk: !Find [authentik_core.group, [name, $1]]" <<<"$blk" \
        && ! grep -qE '^      name:' <<<"$(sed -n '/identifiers:/,/attrs:/p' <<<"$blk")" \
        && [[ "$(sed -n '/attrs:/,$p' <<<"$blk" | grep -cE "^      name: $2\$")" == 1 ]] \
        || fail_ "the rename of $1: only while it exists, found by its pk (never its name), given the new name: $blk"; pass
done
# wire and doctor: a group still under its old name fails, named
rc() { ( OLD=$1; ak_group_pk() { [[ " $OLD " == *" $1 "* ]] && echo "pk-$1"; return 0; }
         wfail() { echo "WFAIL $*"; }; d_fail() { echo "DFAIL $1"; }; warn() { echo "WARN $*"; }
         authentik_rename_check "$2" ) }
[[ -z "$(rc '' wfail)" ]] || fail_ "renamed: nothing said"; pass
[[ "$(rc 'media-users admins' d_fail)" == "DFAIL authentik: the portal's groups are not renamed — still there: media-users admins" ]] \
    || fail_ "doctor: both old groups still there, named: $(rc 'media-users admins' d_fail)"; pass
[[ "$(rc 'admins' wfail)" == "WFAIL authentik: the portal's groups are not renamed — still there: admins"* ]] || fail_ "wire: one left, a failure naming it: $(rc admins wfail)"; pass
grep -q 'authentik_rename_check d_fail' <(awk '/^_doctor_accounts\(\)/,/^}/' services/authentik/authentik.sh) || fail_ "doctor runs the rename check"; pass
! grep -qE 'KeyOf group-(media-users|admins)\b' "$bp" || fail_ "nothing in the blueprint points at the old groups' entries"; pass
grep -q 'continue_flow_without_invitation: false' <<<"$(sed -n '/name: mediastack-join-invitation/,/^  - /p' "$bp")" \
    || fail_ "sign-up must need an invitation"; pass
grep -q 'required: true' <<<"$(sed -n '/name: mediastack-join-email/,/^  - /p' "$bp")" || fail_ "email is required at sign-up"; pass
# one page: every field on the credentials stage, and only one prompt stage bound
[[ $(grep -c '!KeyOf field-' <<<"$(sed -n '/name: mediastack-join-credentials/,/^  - /p' "$bp")") == 6 ]] \
    || fail_ "sign-up is one page: all six fields on one stage"; pass
[[ "$(grep -A1 'target: !KeyOf flow-join' "$bp" | grep -c 'stage: !KeyOf stage-')" == 4 ]] || fail_ "four stages bound to sign-up: invitation, the page, write, login"; pass
sed -n '/^  authentik-worker:/,/^  authentik-db:/p' services/authentik/compose.yml > "$T/worker"
grep -q 'MEDIASTACK_PORTAL_TITLE: ${PORTAL_TITLE:-Mediastack}' "$T/worker" && grep -q 'MEDIASTACK_PORTAL_URL:' "$T/worker" \
    || fail_ "the worker passes the portal's name and address to the blueprint"; pass
grep -q -- '- ${CONFIG_ROOT}/authentik/blueprints:/blueprints/mediastack:ro' "$T/worker" \
    || fail_ "the worker mounts mediastack's blueprints read-only"; pass

# ---- invitations ----
TRAEFIK_ENV="AUTHENTIK_HOST=portal
STACK_DOMAIN=media.example.com"
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
# (the worker's values: as applied, unless a section below says otherwise)
authentik_blueprint_inputs_changed() { return 1; }; authentik_blueprint_inputs_record() { :; }; authentik_applied_by_this_worker() { return 1; }
state_get() { cat "$T/state" 2>/dev/null || true; }
state_set() { echo "$2" > "$T/state"; }
wire_gate() { :; }; http_ready() { :; }; hr() { :; }; info() { :; }; svc_enabled() { [[ "$1" == authentik ]]; }
authentik_url() { echo http://127.0.0.1:9000; }
WIRE_DRY=0; WIRE_CHANGES=0; WIRE_FAILS=0
base() { # base CURRENT OURS -> the PATCH body sent, or "none"
    CUR=$1; rm -f "$T/calls"; if [[ -n "$2" ]]; then echo "$2" > "$T/state"; else rm -f "$T/state"; fi
    ak_api() { echo "$1 $2 ${3:-}" >> "$T/calls"
        case "$1 $2" in
            "GET /admin/settings/") jq -cn --arg u "$CUR" '{base_url:$u, default_user_change_email:false, default_user_change_username:false}' ;;
            "PATCH /admin/settings/") : ;;
            "GET /managed/blueprints/?page_size=200") jq -cn --arg h "$BP_CUR" '{results:[{name:"Mediastack - Portal", status:"successful", last_applied_hash:$h, pk:"bp-1"}]}' ;;
        esac; }
    wire_authentik >/dev/null
    if grep -q '^PATCH' "$T/calls"; then grep '^PATCH' "$T/calls" | cut -d' ' -f3-; else echo none; fi
}
BP_CUR=$(sha512sum services/authentik/blueprints/mediastack-portal.yaml | cut -d' ' -f1)
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
# a tool with no login of its own: through the portal, or nobody
AK_ON=1; mw=$(traefik_gate_middleware)
[[ "$mw" == *$'mediastack-portal-only:\n      chain:\n        middlewares: [mediastack-gate]'* ]] || fail_ "with authentik: portal-only is the gate"; pass
AK_ON=; mw=$(traefik_gate_middleware)
[[ "$mw" == *$'mediastack-portal-only:\n      ipAllowList:\n        sourceRange: ["127.0.0.1/32"]'* ]] || fail_ "without authentik: portal-only refuses everyone through Traefik"; pass
r=$(edge_route_labels "" apprise notify 8000 APPRISE gate "" false)
[[ "$r" == *'routers.apprise.middlewares: "mediastack-portal-only@file"'* && "$r" != *mediastack-gate@file* ]] || fail_ "no login of its own: the route takes portal-only: $r"; pass
r=$(edge_route_labels "" sonarr sonarr 8989 SONARR gate "" "")
[[ "$r" == *'routers.sonarr.middlewares: "mediastack-gate@file"'* ]] || fail_ "its own login: the gate, as before: $r"; pass

# the provider is ADDED to the built-in outpost, never replacing what is there;
# akadmin joins admins once (the cards: the next block)
svc_enabled() { [[ "$1" == authentik ]]; }
authentik_gated() { printf '%s\n' apprise olivetin; }
authentik_household() { :; }
svc_url() { echo "https://$1.media.example.com"; }
svc_label() { echo "desc of $1"; }
rm -f "$T/state" "$T/calls"
ak_api() { echo "$1 $2 ${3:-}" >> "$T/calls"
    case "$1 $2" in
        "GET /providers/proxy/?name__iexact=mediastack-gate") echo '{"results":[{"pk":7}]}' ;;
        "GET /outposts/instances/?managed__iexact=goauthentik.io/outposts/embedded") echo '{"results":[{"pk":"op-1","providers":[3],"config":{"log_level":"info","authentik_host":""}}]}' ;;
        "GET /core/groups/?search=admin") echo '{"results":[{"pk":"g-adm","name":"admin"},{"pk":"g-x","name":"superadmin"}]}' ;;
        "GET /core/groups/?search=frontend") echo '{"results":[{"pk":"g-mu","name":"frontend"}]}' ;;
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
grep -qF 'POST /core/groups/g-adm/add_user/ {"pk":1}' "$T/calls" || fail_ "akadmin joins '$PORTAL_ADMIN' (not a lookalike group)"; pass
grep -qF "PATCH /outposts/instances/op-1/ {\"config\":{\"log_level\":\"info\",\"authentik_host\":\"$(authentik_portal)\"}}" "$T/calls" \
    || fail_ "the outpost sends sign-ins to the portal, the rest of its config kept: $(grep 'PATCH.*config' "$T/calls")"; pass
rm -f "$T/calls"; wire_authentik_gate >/dev/null
! grep -q 'add_user' "$T/calls" || fail_ "akadmin is added once — after that, 'admins' is yours"; pass

# ---- "successful" counts only for the current file (found live: right after
#      an update, the status still described the previous version) ----
BP_APPLIED=old; rm -f "$T/calls"
ak_api() { echo "$1 $2" >> "$T/calls"
    case "$1 $2" in
        "GET /managed/blueprints/?page_size=200")
            h=$BP_CUR; [[ "$BP_APPLIED" == old ]] && h=deadbeef
            jq -cn --arg h "$h" --arg st "${BP_STATUS:-successful}" --arg at "$BP_APPLIED" '{results:([{name:"Mediastack - Portal", status:$st, last_applied_hash:$h, last_applied:$at, pk:"bp-1"}]
                + ($ARGS.positional | map({path: ., status: "successful"})))}' --args "${AUTHENTIK_BLUEPRINT_NEEDS[@]}" ;;   # authentik's own defaults, listed beside ours
        "POST /managed/blueprints/bp-1/apply/") BP_APPLIED=new; echo '{}' ;;
        *) echo '{}' ;;
    esac; }
[[ "$(authentik_blueprint_status)" == outdated ]] || fail_ "an earlier file's success is 'outdated', not 'successful'"; pass
BP_STATUS=error; [[ "$(authentik_blueprint_status)" == error ]] || fail_ "a failed apply of a newer file says 'error', not 'outdated'"; pass
BP_STATUS=successful
BP_APPLIED=old; sleep() { :; }
[[ "$(authentik_blueprint_apply)" == successful ]] || fail_ "applying on demand brings the current file in"; pass
grep -q '^POST /managed/blueprints/bp-1/apply/' "$T/calls" || fail_ "the apply goes through authentik's API"; pass
# an unchanged file says "successful" before the apply runs: wait for the apply asked for
applied_after() { # applied_after POLLS -> "STATUS after N sleeps" (authentik applies after POLLS looks)
    ( echo 0 > "$T/tick"; sleep() { echo $(( $(cat "$T/tick") + 1 )) > "$T/tick"; }
      ak_api() { case "$1 $2" in
          "GET /managed/blueprints/?page_size=200")
              at=t1; (( $(cat "$T/tick") >= POLLS )) && at=t2
              jq -cn --arg h "$BP_CUR" --arg at "$at" '{results:([{name:"Mediastack - Portal", status:"successful", last_applied_hash:$h, last_applied:$at, pk:"bp-1"}]
                  + ($ARGS.positional | map({path: ., status: "successful"})))}' --args "${AUTHENTIK_BLUEPRINT_NEEDS[@]}" ;;
          *) echo '{}' ;; esac; }
      POLLS=$1; st=$(authentik_blueprint_apply); echo "$st after $(cat "$T/tick")" )
}
[[ "$(applied_after 3)" == "successful after 3" ]] || fail_ "the file already applied: wait for authentik to apply again, not its old status: $(applied_after 3)"; pass
[[ "$(applied_after 9999)" == "outdated after $(( AUTHENTIK_APPLY_WAIT / 2 ))" ]] || fail_ "an apply that never runs: bounded, and not a success: $(applied_after 9999)"; pass
[[ "$(applied_after 125)" == "successful after 125" ]] || fail_ "an apply of four minutes is waited for (4m10s live): $(applied_after 125)"; pass

# ---- the worker's values (the blueprint's !Env) ----
inputs() { ( sudo() { [[ "$*" == "docker inspect -f "* ]] || return 1; [[ -z "$NOWORKER" ]] || return 1; printf '%s\n' "${ENVS[@]}"; }
             svc_cname() { echo w; }; unset -f authentik_blueprint_inputs_changed authentik_blueprint_inputs_record
             # shellcheck disable=SC1090  # the three real functions, back from their stubs
             source <(sed -n '/^authentik_blueprint_inputs() {/,/^}/p; /^authentik_blueprint_inputs_changed() {/,/^}/p; /^authentik_blueprint_inputs_record() {/,/^}/p' services/authentik/authentik.sh)
             state_get() { cat "$T/st-$1" 2>/dev/null || true; }; state_set() { printf '%s\n' "$2" > "$T/st-$1"; }
             "$@" ) }
rm -f "$T"/st-*; NOWORKER=
ENVS=(PATH=/bin MEDIASTACK_PORTAL_TITLE=Mediastack MEDIASTACK_LDAP_BIND_PASSWORD='s3cr=t' AUTHENTIK_SECRET_KEY=k)
out=$(inputs authentik_blueprint_inputs)
[[ "$(cut -d' ' -f1 <<<"$out" | paste -sd' ' -)" == "MEDIASTACK_LDAP_BIND_PASSWORD MEDIASTACK_PORTAL_TITLE" ]] || fail_ "only the MEDIASTACK_ values, sorted: $out"; pass
! grep -qE 's3cr=t|Mediastack' <<<"$out" || fail_ "a digest per value, never the value: $out"; pass
r=$(inputs authentik_blueprint_inputs_changed; echo "rc=$?")
[[ "$r" == *"no record"*"rc=0" ]] || fail_ "nothing recorded (an install from before this): apply once: $r"; pass
inputs authentik_blueprint_inputs_record
[[ "$(inputs authentik_blueprint_inputs_changed; echo "rc=$?")" == "rc=1" ]] || fail_ "as applied: nothing to do"; pass
ENVS=(PATH=/bin MEDIASTACK_PORTAL_TITLE=Rotatetest MEDIASTACK_LDAP_BIND_PASSWORD='s3cr=t' MEDIASTACK_KAVITA_URL=https://k)
r=$(inputs authentik_blueprint_inputs_changed; echo "rc=$?")
[[ "$r" == $'MEDIASTACK_KAVITA_URL MEDIASTACK_PORTAL_TITLE\nrc=0' ]] || fail_ "a changed and a new value are named, the rest not: $r"; pass
r=$(NOWORKER=1 inputs authentik_blueprint_inputs_changed; echo "rc=$?")
[[ "$r" == "rc=2" ]] || fail_ "no worker to read: unreadable, never 'unchanged': $r"; pass
# wire: a changed worker is applied; --verify says so and does not call it applied
changed_wire() { # changed_wire DRY CHANGED-RC -> "applied|not recorded|not ok-line|ok-line" (what wire did)
    ( ak_api() { [[ "$1 $2" == "GET /admin/settings/" ]] && echo '{"base_url":"https://portal.media.example.com"}' || echo '{}'; }
      authentik_blueprint_status() { echo successful; }
      authentik_blueprint_inputs_changed() { (( CRC == 0 )) && echo MEDIASTACK_PORTAL_TITLE; return "$CRC"; }
      authentik_blueprint_inputs_record() { echo recorded > "$T/rec"; }
      authentik_blueprint_apply() { echo applied > "$T/app"; echo successful; }
      c_state() { echo exited; }; ok() { echo "OK $*"; }
      wire_authentik_identity() { :; }; wire_authentik_recovery() { :; }; wire_authentik_show_password() { :; }; wire_authentik_web_tokens() { :; }; wire_authentik_app_password_lifetime() { :; }; wire_authentik_lockout_alerts() { :; }
      wire_authentik_gate() { :; }; panel_signin_check() { :; }
      rm -f "$T/rec" "$T/app"; WIRE_DRY=$1 CRC=$2 WIRE_FAILS=0
      wire_authentik > "$T/wout" 2>&1   # not in $( ): WIRE_FAILS is counted in this shell
      echo "$(cat "$T/app" 2>/dev/null || echo none) $(cat "$T/rec" 2>/dev/null || echo none) fails=$WIRE_FAILS $(grep -c 'portal setup applied' "$T/wout")$(grep -o 'values changed: [A-Z_]*' "$T/wout" | sed 's/^/ /')" )
}
[[ "$(changed_wire 0 0)" == "applied recorded fails=0 1" ]] || fail_ "the worker changed: applied, recorded: $(changed_wire 0 0)"; pass
[[ "$(changed_wire 1 0)" == "none none fails=0 0 values changed: MEDIASTACK_PORTAL_TITLE" ]] || fail_ "--verify: named, nothing applied, not called applied: $(changed_wire 1 0)"; pass
[[ "$(changed_wire 0 1)" == "none none fails=0 1" ]] || fail_ "as applied: no apply: $(changed_wire 0 1)"; pass
[[ "$(changed_wire 0 2)" == "none none fails=1 0" ]] || fail_ "the worker unreadable: a failure: $(changed_wire 0 2)"; pass
# no record, but the last apply ran on this worker (a first wire: the restore point waited out its first pass): recorded, never applied again
nr_wire() { # nr_wire DRY BY-THIS-WORKER(yes|no) -> "applied|none recorded|none"
    ( ak_api() { [[ "$1 $2" == "GET /admin/settings/" ]] && echo '{"base_url":"https://portal.media.example.com"}' || echo '{}'; }
      authentik_blueprint_status() { echo successful; }; state_get() { :; }
      authentik_applied_by_this_worker() { [[ "$BY" == yes ]]; }
      authentik_blueprint_inputs_changed() { echo "no record"; return 0; }
      authentik_blueprint_inputs_record() { echo recorded > "$T/rec"; }
      authentik_blueprint_apply() { echo applied > "$T/app"; echo successful; }
      c_state() { echo exited; }; ok() { :; }
      wire_authentik_identity() { :; }; wire_authentik_recovery() { :; }; wire_authentik_show_password() { :; }; wire_authentik_web_tokens() { :; }; wire_authentik_app_password_lifetime() { :; }; wire_authentik_lockout_alerts() { :; }
      wire_authentik_gate() { :; }; panel_signin_check() { :; }
      rm -f "$T/rec" "$T/app"; WIRE_DRY=$1 BY=$2 WIRE_FAILS=0
      wire_authentik > /dev/null 2>&1
      echo "$(cat "$T/app" 2>/dev/null || echo none) $(cat "$T/rec" 2>/dev/null || echo none)" )
}
[[ "$(nr_wire 0 yes)" == "none recorded" ]] || fail_ "applied on this worker already: recorded, not applied again: $(nr_wire 0 yes)"; pass
[[ "$(nr_wire 1 yes)" == "none none" ]] || fail_ "a dry run: no drift, nothing written: $(nr_wire 1 yes)"; pass
[[ "$(nr_wire 0 no)" == "applied recorded" ]] || fail_ "no record and an older apply: applied, then recorded: $(nr_wire 0 no)"; pass
abw() { # abw LAST-APPLIED CREATED [STARTED] -> yes|no
    ( authentik_blueprint_instance() { jq -cn --arg a "$A" '{last_applied: $a}'; }
      sudo() { case "$*" in *'{{.Created}}'*) echo "$S" ;; *'{{.State.StartedAt}}'*) echo "$R" ;; esac; }
      svc_cname() { echo w; }; A=$1 S=$2 R=${3:-$2}
      authentik_applied_by_this_worker && echo yes || echo no )
}
unset -f authentik_applied_by_this_worker
# shellcheck disable=SC1090  # the real one, back from its stub
source <(sed -n '/^authentik_applied_by_this_worker() {/,/^}/p' services/authentik/authentik.sh)
[[ "$(abw 2026-11-14T07:12:13.904Z 2026-11-14T07:05:46.123456789Z)" == yes ]] || fail_ "applied after the worker was created: its values"; pass
[[ "$(abw 2026-11-14T07:00:00Z 2026-11-14T07:05:46Z)" == no ]] || fail_ "applied before the worker was created: maybe another's values"; pass
[[ "$(abw 2026-11-15T10:28:40Z 2026-11-15T10:24:57.30760565Z 2026-11-15T10:31:36.037480597Z)" == yes ]] \
    || fail_ "restarted after the apply (the first wire's restore point): still its values, never applied twice (found live 15 Nov 2026)"; pass
[[ "$(abw '' 2026-11-14T07:05:46Z)" == no ]] || fail_ "never applied: not current"; pass
authentik_applied_by_this_worker() { return 1; }

# ---- a first start: one `wire` finishes it — authentik before jellyfin, and
#      wire waits (bounded) for the blueprint to be discovered ----
ai=; ji=; for i in "${!WIRE_ROLES[@]}"; do
    [[ "${WIRE_ROLES[$i]}" == authentik ]] && ai=$i; [[ "${WIRE_ROLES[$i]}" == jellyfin ]] && ji=$i
done
(( ai < ji )) || fail_ "authentik is wired before jellyfin (Jellyfin's portal sign-in needs the LDAP token)"; pass
ak_api() { case "$1 $2" in
    "GET /managed/blueprints/?page_size=200")
        n=$(( $(cat "$T/seen") + 1 )); echo "$n" > "$T/seen"
        if (( n < BP_FOUND_AT )); then echo '{"results":[]}'
        else jq -cn --arg h "$BP_CUR" '{results:[{name:"Mediastack - Portal", status:"successful", last_applied_hash:$h, pk:"bp-1"}]}'; fi ;;
    *) echo '{}' ;;
esac; }
echo 0 > "$T/seen"; BP_FOUND_AT=3
[[ "$(authentik_blueprint_discovered)" == successful ]] || fail_ "discovered on a later look: its status"; pass
echo 0 > "$T/seen"; BP_FOUND_AT=999
[[ -z "$(authentik_blueprint_discovered)" ]] || fail_ "never discovered: empty"; pass
[[ "$(cat "$T/seen")" == $(( AUTHENTIK_DISCOVER_WAIT / 5 + 1 )) ]] || fail_ "the wait is bounded: $(cat "$T/seen") looks"; pass
first_start() { # first_start DRY DISCOVERED -> what wire_authentik did: "gate|nogate fails=N waited|nowait"
    ( ak_api() { [[ "$1 $2" == "GET /admin/settings/" ]] && echo '{"base_url":"https://portal.media.example.com"}' || echo '{}'; }
      authentik_blueprint_status() { echo ""; }
      authentik_blueprint_discovered() { echo waited > "$T/waited"; echo "$DISC"; }
      wire_authentik_gate() { echo gate > "$T/gated"; }; wire_authentik_recovery() { :; }; wire_authentik_show_password() { :; }; wire_authentik_web_tokens() { :; }; wire_authentik_app_password_lifetime() { :; }; wire_authentik_lockout_alerts() { :; }   # their own sections below
      rm -f "$T/waited" "$T/gated"; WIRE_DRY=$1 DISC=$2 WIRE_FAILS=0
      wire_authentik >/dev/null 2>&1
      echo "$(cat "$T/gated" 2>/dev/null || echo nogate) fails=$WIRE_FAILS $(cat "$T/waited" 2>/dev/null || echo nowait)" )
}
[[ "$(first_start 0 successful)" == "gate fails=0 waited" ]] || fail_ "discovered while waiting: the gate and cards follow in the same run: $(first_start 0 successful)"; pass
[[ "$(first_start 0 "")" == "nogate fails=1 waited" ]] || fail_ "never discovered: a failure, not a quiet success: $(first_start 0 "")"; pass
[[ "$(first_start 1 "")" == "nogate fails=0 nowait" ]] || fail_ "a dry run reports without waiting: $(first_start 1 "")"; pass
why_said() { # why_said STATUS APPLIED-HASH -> the reason wire gives for applying (dry run)
    ( ak_api() { [[ "$1 $2" == "GET /admin/settings/" ]] && echo '{"base_url":"https://portal.media.example.com"}' || echo '{}'; }
      authentik_blueprint_status() { echo "$ST"; }
      authentik_blueprint_instance() { jq -cn --arg h "$HASH" '{last_applied_hash:$h}'; }
      wire_authentik_gate() { :; }
      WIRE_DRY=1 ST=$1 HASH=$2; wire_authentik 2>&1 | sed -n 's/.*portal setup now (\(.*\))$/\1/p' )
}
[[ -z "$(why_said outdated "")" ]] || fail_ "a first start is never forced: $(why_said outdated "")"; pass
# a first start, for real: authentik's own first pass applies it (after its default
# flows, which the blueprint references — forced sooner it failed, found live Nov 2026)
first_pass() { # first_pass STATUS-AFTER-THE-WAIT -> "forced|waited-only fails=N gate|nogate"
    ( ak_api() { [[ "$1 $2" == "GET /admin/settings/" ]] && echo '{"base_url":"https://portal.media.example.com"}' || echo '{}'; }
      authentik_blueprint_status() { echo outdated; }
      authentik_blueprint_instance() { echo '{"last_applied_hash":""}'; }
      authentik_first_pass_wait() { echo "$AFTER"; }
      authentik_blueprint_apply() { echo forced > "$T/forced"; echo successful; }
      wire_authentik_identity() { :; }; wire_authentik_recovery() { :; }; wire_authentik_show_password() { :; }; wire_authentik_web_tokens() { :; }; wire_authentik_app_password_lifetime() { :; }; wire_authentik_lockout_alerts() { :; }
      wire_authentik_gate() { echo gate > "$T/gated"; }; panel_signin_check() { :; }
      rm -f "$T/forced" "$T/gated"; WIRE_DRY=0 AFTER=$1 WIRE_FAILS=0
      wire_authentik >/dev/null 2>&1
      echo "$(cat "$T/forced" 2>/dev/null || echo waited-only) fails=$WIRE_FAILS $(cat "$T/gated" 2>/dev/null || echo nogate)" )
}
[[ "$(first_pass successful)" == "waited-only fails=0 gate" ]] || fail_ "applied by its own first pass: nothing forced, the gate follows: $(first_pass successful)"; pass
[[ "$(first_pass outdated)" == "waited-only fails=1 nogate" ]] || fail_ "not applied within the wait: a failure, still nothing forced: $(first_pass outdated)"; pass
[[ "$(first_pass error)" == "forced fails=0 gate" ]] || fail_ "its first pass failed (with its defaults applied): applied once more, the gate follows: $(first_pass error)"; pass
# the first pass applies everything at once, ours before its defaults (found
# live Nov 2026: ours 04:55:08, the defaults 04:55:46-04:56:09): an error while
# they are pending is provisional — wait for them; a clock ticks with each sleep
bp_clock() { # bp_clock NEEDS-APPLIED-AT -> "STATUS-RETURNED at TICK"
    ( echo 0 > "$T/tick"; sleep() { echo $(( $(cat "$T/tick") + 1 )) > "$T/tick"; }
      ak_api() { [[ "$1 $2" == "GET /managed/blueprints/?page_size=200" ]] || { echo '{}'; return 0; }
          local st=outdated; (( $(cat "$T/tick") >= NEEDS_AT )) && st=successful
          jq -cn --arg st "$st" '{results:([{name:"Mediastack - Portal", status:"error", last_applied_hash:"", pk:"bp-1"}]
              + ($ARGS.positional | map({path: ., status: $st})))}' --args "${AUTHENTIK_BLUEPRINT_NEEDS[@]}"; }
      NEEDS_AT=$1; st=$(authentik_first_pass_wait); echo "$st at $(cat "$T/tick")" )
}
[[ "$(bp_clock 4)" == "error at 4" ]] || fail_ "an error while its defaults are pending waits for them, then stands: $(bp_clock 4)"; pass
[[ "$(bp_clock 0)" == "error at 0" ]] || fail_ "an error with its defaults applied is final at once: $(bp_clock 0)"; pass
[[ "$(bp_clock 9999)" == "error at $(( AUTHENTIK_DISCOVER_WAIT / 5 ))" ]] || fail_ "the wait for them is bounded: $(bp_clock 9999)"; pass
# the first wire's restore point stops the stack: a first start of authentik
# stopped mid-pass starts its whole pass over (~3 min lost, found live Nov
# 2026) — wire lets that pass finish before the point, and only then
fw=$(awk '/^cmd_wire\(\)/,/^}/' lib/wire.sh)
settle=$(grep -n 'signin_is authentik.*authentik_first_pass_settle' <<<"$fw" | cut -d: -f1 || true)
take=$(grep -n 'backup_take manual "before the first wire"' <<<"$fw" | cut -d: -f1 || true)
[[ -n "$settle" && -n "$take" ]] && (( settle < take )) || fail_ "the first wire lets authentik's first pass finish before its restore point"; pass
settled() { # settled STATE READABLE-AT HASH -> "looks=N waited|nowait" (a clock ticks with each sleep)
    ( echo 0 > "$T/tick"; echo 0 > "$T/looks"; rm -f "$T/fpw"
      sleep() { echo $(( $(cat "$T/tick") + 1 )) > "$T/tick"; }
      c_state() { echo "$CST"; }
      authentik_blueprint_status() { echo $(( $(cat "$T/looks") + 1 )) > "$T/looks"
          if (( $(cat "$T/tick") < AT )); then echo "unreadable (HTTP 000)"; else echo outdated; fi; }
      authentik_blueprint_instance() { jq -cn --arg h "$HASH" '{last_applied_hash:$h}'; }
      authentik_first_pass_wait() { echo waited > "$T/fpw"; echo successful; }
      CST=$1 AT=$2 HASH=$3; authentik_first_pass_settle >/dev/null
      echo "looks=$(cat "$T/looks") $(cat "$T/fpw" 2>/dev/null || echo nowait)" )
}
[[ "$(settled exited 0 "")" == "looks=0 nowait" ]] || fail_ "authentik not running: nothing to wait for: $(settled exited 0 "")"; pass
[[ "$(settled running 0 abc)" == "looks=1 nowait" ]] || fail_ "applied before (a hash): not a first start, no wait: $(settled running 0 abc)"; pass
[[ "$(settled running 3 "")" == "looks=4 waited" ]] || fail_ "a first start: its API first, then its own first pass: $(settled running 3 "")"; pass
[[ "$(settled running 9999 "")" == "looks=$(( AUTHENTIK_DISCOVER_WAIT / 5 + 1 )) nowait" ]] || fail_ "never readable: bounded, and the restore point goes ahead: $(settled running 9999 "")"; pass
# what our blueprint builds on is applied first, in its own run: authentik's
# first pass applied ours before its defaults (found live Nov 2026)
bpe=$(python3 - <<'PY'
import yaml
class L(yaml.SafeLoader): pass
L.add_multi_constructor('!', lambda l, s, n: None)
e=yaml.load(open('services/authentik/blueprints/mediastack-portal.yaml'), Loader=L)['entries']
n=0
for x in e:
    if x['model'] != 'authentik_blueprints.metaapplyblueprint': break
    print(x['attrs']['identifiers']['path'], x['attrs'].get('required')); n+=1
print('rest-meta', sum(1 for x in e[n:] if x['model'] == 'authentik_blueprints.metaapplyblueprint'))
PY
)
for p in "${AUTHENTIK_BLUEPRINT_NEEDS[@]}"; do
    grep -qx "$p True" <<<"$bpe" || fail_ "the blueprint applies $p first, required: $bpe"
done; pass
grep -qx 'rest-meta 0' <<<"$bpe" || fail_ "the prerequisites come before every other entry"; pass
# every object the blueprint looks up (!Find) comes from a prerequisite, or is
# made by authentik before any blueprint runs: the scope mappings were missed
# once (found live 12 Nov 2026: ours failed, providers-oauth2 applied after it)
finds=$(grep -oE '!Find \[[a-z0-9_.]+, \[[a-z_]+, [^]]+\]\]' services/authentik/blueprints/mediastack-portal.yaml | sort -u)
[[ -n "$finds" ]] || fail_ "no !Find found in the blueprint: the pattern no longer matches it"
while IFS= read -r f; do
    case "$f" in
        '!Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]')
            want=default/flow-default-provider-authorization-implicit-consent.yaml ;;
        '!Find [authentik_flows.flow, [slug, default-provider-invalidation-flow]]')
            want=default/flow-default-provider-invalidation.yaml ;;
        '!Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-'*)
            want=system/providers-oauth2.yaml ;;
        '!Find [authentik_crypto.certificatekeypair, [name, authentik Self-signed Certificate]]')
            continue ;;   # made at start (authentik/crypto/apps.py, self_signed), before any blueprint
        '!Find [authentik_core.group, [name, media-users]]'|'!Find [authentik_core.group, [name, admins]]')
            # the groups' rename (Nov 2026): a condition, where finding nothing is the answer (a fresh install)
            grep -qF -- "- $f" services/authentik/blueprints/mediastack-portal.yaml || fail_ "$f outside a rename's conditions"
            continue ;;
        *) fail_ "the blueprint looks up $f: add the blueprint that makes it to the prerequisites" ;;
    esac
    [[ " ${AUTHENTIK_BLUEPRINT_NEEDS[*]} " == *" $want "* ]] || fail_ "$f comes from $want, which is not a prerequisite"
done <<<"$finds"; pass
# a forced apply waits for authentik to have APPLIED them — found is not enough
# (found live Nov 2026); never applied: no apply, the pending ones named
r=$( ( ak_api() { if [[ "$1 $2" == "POST /managed/blueprints/"* ]]; then echo APPLIED >> "$T/applied"; fi
                  echo '{"results":[{"path":"default/default-brand.yaml","status":"successful"},{"path":"default/flow-default-provider-authorization-implicit-consent.yaml","status":"outdated"}]}'; }
       sleep() { :; }; rm -f "$T/applied"; authentik_blueprint_apply ) )
[[ "$r" == "unreadable (authentik has not applied its own default/flow-default-provider-authorization-implicit-consent.yaml default/flow-default-provider-invalidation.yaml system/providers-oauth2.yaml yet)" && ! -e "$T/applied" ]] \
    || fail_ "its defaults found but not applied (or not found): nothing forced, the pending ones named: $r"; pass

# the reason printer is how a failure is reported: it never fails itself
r=$( ( set -Ee; trap 'echo TRAPPED; exit 9' ERR   # as wire runs it
       sudo() { echo '{"event": "Imported related module"}'; return 1; }; svc_cname() { echo w; }; authentik_blueprint_why ); echo "rc=$?" )
[[ "$r" == *"its validator finds nothing wrong now"*"rc=0" ]] || fail_ "the validator says nothing: said, and wire carries on: $r"; pass
r=$( ( sudo() { printf 'x\n  Entry invalid: flow not found {"entry": 1}\n'; }; svc_cname() { echo w; }; authentik_blueprint_why ) )
[[ "$r" == "Entry invalid: flow not found" ]] || fail_ "the validator's own words, trimmed: $r"; pass
[[ "$(why_said outdated abc123)" == "an earlier version is in place" ]] || fail_ "an older file applied: $(why_said outdated abc123)"; pass
[[ "$(why_said error abc123)" == "its last apply failed" ]] || fail_ "a failed apply: $(why_said error abc123)"; pass

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
svc_label() { case "$2" in mediastack.auth) echo "${AUTH:-gate}" ;; mediastack.subdomain) [[ "$1" == authentik ]] && echo portal ;; esac; return 0; }
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
AK_ON=1; grep -q 'middlewares: \[$(signin_is authentik && echo mediastack-gate || echo dash-auth)\]' services/traefik/edge.sh \
    || fail_ "the dashboard router chooses the gate or its password by account model"; pass

# disabling the portal: every arr's own login is verified BEFORE the profile
# changes and the ports reopen (never open to the LAN without a login)
body=$(sed -n '/^cmd_disable() {/,/^}/p' mediastack.sh)
v=$(grep -n 'still trusts the portal' <<<"$body" | sed -n 1p | cut -d: -f1)
e=$(grep -n 'env_set COMPOSE_PROFILES' <<<"$body" | sed -n 1p | cut -d: -f1)
g=$(grep -n 'gate_bind_sync' <<<"$body" | sed -n 1p | cut -d: -f1)
[[ -n "$v" && -n "$e" && -n "$g" ]] && (( v < e && e < g )) || fail_ "disable authentik: logins verified, then the profile, then the ports"; pass

# every arr-family login goes through arr_login — Prowlarr and a credential
# rotation included (found live: Prowlarr kept asking twice)
grep -q '^    arr_login prowlarr' services/prowlarr/prowlarr.sh || fail_ "wire prowlarr: its login follows the trust rule"; pass
grep -q 'arr_login "\$s"' <<<"$(sed -n '/^sc_rotate_arr() {/,/^}/p' services/_arr/arr.sh)" || fail_ "set-credentials arr: back to trusting the portal after the rotation"; pass
grep -q 'for a in $(arr_instances) $(svc_enabled prowlarr && echo prowlarr)' <<<"$(sed -n '/^cmd_disable() {/,/^}/p' mediastack.sh)" \
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
grep -q 'also sends a device password as a header' <<<"$out" || fail_ "behind the portal: how the app gets through"; pass

# ---- the stack network: Traefik's fixed address outside the pool ----
cidr_has 172.31.250.0/24 172.31.250.2 && ! cidr_has 172.31.250.128/25 172.31.250.2 && cidr_has 10.0.0.0/8 10.200.3.4 \
    || fail_ "cidr_has"; pass
printf '' > "$ENV_FILE"; [[ -z "$(network_problems)" ]] || fail_ "the defaults agree: $(network_problems)"; pass
printf 'TRAEFIK_ADDRESS=172.31.250.200\n' > "$ENV_FILE"
[[ "$(network_problems)" == *"inside MEDIASTACK_IP_RANGE"* ]] || fail_ "Traefik inside the pool is a problem"; pass
printf 'TRAEFIK_ADDRESS=10.9.9.9\n' > "$ENV_FILE"
[[ "$(network_problems)" == *"not inside MEDIASTACK_SUBNET"* ]] || fail_ "Traefik outside the network is a problem"; pass
# gluetun's too: in the pool, another container's tracked connections are taken for its own
printf 'GLUETUN_ADDRESS=172.31.250.131\n' > "$ENV_FILE"
[[ "$(network_problems)" == *"GLUETUN_ADDRESS (172.31.250.131) is inside MEDIASTACK_IP_RANGE"* ]] || fail_ "gluetun inside the pool is a problem"; pass
printf 'GLUETUN_ADDRESS=172.31.250.2\n' > "$ENV_FILE"
[[ "$(network_problems)" == *"the same address"* ]] || fail_ "gluetun on Traefik's address is a problem"; pass

# ---- who may name the user: Traefik's address while the portal runs, nobody otherwise ----
printf 'TRAEFIK_ADDRESS=172.31.250.2\n' > "$ENV_FILE"
svc_enabled() { [[ "$1" == authentik && -n "${AK_ON:-}" ]]; }
AK_ON=1; gate_bind_sync >/dev/null; [[ "$(env_get MEDIASTACK_GATE_TRUST)" == 172.31.250.2/32 ]] || fail_ "trust: Traefik only"; pass
AK_ON='';  gate_bind_sync >/dev/null; [[ "$(env_get MEDIASTACK_GATE_TRUST)" == "" ]] || fail_ "no portal: trust nobody"; pass
grep -q 'ND_EXTAUTH_TRUSTEDSOURCES=${MEDIASTACK_GATE_TRUST:-}' services/navidrome/compose.yml || fail_ "Navidrome trusts exactly MEDIASTACK_GATE_TRUST"; pass
for AK_ON in 1 ''; do
    mw=$(traefik_gate_middleware)
    [[ "$mw" == *"mediastack-strip:"*'X-authentik-username: ""'* ]] || fail_ "the strip middleware exists in both account models"; pass
done

# ---- household apps: their own cards; Navidrome's carries its household gate ----
svc_enabled_managed() { printf '%s\n' sonarr navidrome jellyfin seerr kavita; }
svc_label() { case "$1:$2" in
    sonarr:mediastack.auth) echo gate ;; navidrome:mediastack.auth) echo gate ;;
    navidrome:mediastack.auth.group) echo frontend ;;
    navidrome:mediastack.user_facing|jellyfin:mediastack.user_facing|seerr:mediastack.user_facing|kavita:mediastack.user_facing) echo true ;;
    jellyfin:mediastack.auth|seerr:mediastack.auth|kavita:mediastack.auth) echo native ;;
    jellyfin:mediastack.tier|kavita:mediastack.tier) echo frontend ;; seerr:mediastack.access.of) echo jellyfin ;;
    authentik:mediastack.subdomain) echo portal ;;
    *:mediastack.desc) echo "desc of ${1%%:*}" ;; esac; }
unset -f authentik_gated authentik_household
# shellcheck disable=SC1090  # the two real functions, back from their stubs
source <(sed -n '/^authentik_gated() {/,/^}/p; /^authentik_household() {/,/^}/p' services/authentik/authentik.sh)
[[ "$(authentik_gated | tr '\n' ' ')" == "sonarr " ]] || fail_ "the household-gated app is not an admin tool: $(authentik_gated)"; pass
[[ "$(authentik_household | tr '\n' ' ')" == "navidrome jellyfin seerr kavita " ]] || fail_ "household apps by mediastack.user_facing"; pass
[[ "$(svc_enabled() { :; }; authentik_native_ruled | tr '\n' ' ')" == "jellyfin kavita " ]] || fail_ "under the rule, signing people in themselves: Jellyfin and Kavita (a tier label) — not Seerr, not the gated"; pass
[[ "$(svc_enabled() { :; }; svc_access_of seerr) $(svc_enabled() { :; }; svc_access_of jellyfin) $(svc_enabled() { :; }; svc_access_of navidrome)" == "jellyfin jellyfin " ]] \
    || fail_ "whose rule a card follows: Seerr Jellyfin's, Jellyfin its own, others none here"; pass
[[ -z "$(svc_enabled() { [[ "$1" != jellyfin ]]; }; svc_access_of seerr)" ]] || fail_ "Seerr with Jellyfin off: no rule to follow"; pass
# ---- every gated app its own gate (decision 7, docs/design-access.md): its
#      group, its provider, its card carrying the rule — on the outpost only
#      once the card's bindings read back (an unbound application admits
#      everyone signed in) ----
AK_APPS='{"results":[
  {"slug":"mediastack-tool-sonarr","pk":"a-ts","meta_launch_url":"https://sonarr.media.example.com"},
  {"slug":"mediastack-tool-oldsvc","pk":"a-to"},
  {"slug":"my-own-app","pk":"a-mine"},
  {"slug":"mediastack-app-audiobookshelf","pk":"a-k"},
  {"slug":"mediastack-app-navidrome","pk":"a-nav","provider":42,"group":"Media","meta_launch_url":"https://navidrome.media.example.com"}]}'
gates_run() { # gates_run [DRY] [REFUSE-BINDINGS] — wire_authentik_cards against a stateful authentik; calls in $T/calls
    ( WIRE_DRY=${1:-0} WIRE_FAILS=0 NOBIND=${2:-0}
      rm -f "$T/calls" "$T/made" "$T/patched"; printf 'a-nav g-mu\na-nav g-adm\n' > "$T/bind"   # Navidrome's card as wired before: the household and its admins
      printf 'a-ldap g-mu\na-ldap g-adm\n' >> "$T/bind"   # the LDAP application, as the blueprint bound it before slice B
      printf 'admin g-adm\nfrontend g-mu\n' > "$T/groups"; echo '[6]' > "$T/op"; echo 'mediastack-ldap a-ldap' > "$T/apps"
      svc_enabled() { [[ " sonarr navidrome jellyfin seerr kavita " == *" $1 "* ]]; }
      ak_api() { echo "$1 $2 ${3:-}" >> "$T/calls"
        case "$1 $2" in
          "GET /core/applications/?superuser_full_list=true&page_size=500") echo "$AK_APPS" ;;
          "GET /core/groups/?search="*) awk -v q="${2#*=}" 'index($1,q){printf "%s{\"name\":\"%s\",\"pk\":\"%s\"}", (n++?",":""), $1, $2} BEGIN{printf "{\"results\":["} END{print "]}"}' "$T/groups" ;;
          "POST /core/groups/") n=$(jq -r .name <<<"$3"); echo "$n g-$n" >> "$T/groups"; echo "{\"pk\":\"g-$n\"}" ;;
          "GET /providers/proxy/?name__iexact=mediastack-house-navidrome") echo '{"results":[{"pk":42,"external_host":"https://navidrome.media.example.com"}]}' ;;
          "GET /providers/proxy/?name__iexact=mediastack-app-sonarr") if [[ -f "$T/made" || -n "${MOVED:-}" ]]; then echo '{"results":[{"pk":50,"external_host":"https://old.example.com"}]}'; else echo '{"results":[]}'; fi ;;
          "GET /providers/proxy/?name__iexact="*) echo '{"results":[]}' ;;
          "POST /providers/proxy/") echo made > "$T/made"; [[ -n "${LATE:-}" ]] && { echo 'no answer within 90s'; return 1; }; echo '{"pk":50}' ;;
          "PATCH /providers/proxy/"*)   # authentik checks a partial update as a full proxy unless mode says otherwise
              jq -e '.mode == "forward_single"' <<<"$3" >/dev/null || { echo '{"internal_host":["Internal host cannot be empty when forward auth is disabled."]}'; return 1; }
              echo '{}' ;;
          "GET /flows/instances/?slug="*) echo '{"results":[{"pk":"flow-x"}]}' ;;
          "GET /providers/oauth2/?client_id=mediastack-kavita") echo '{"results":[{"pk":77}]}' ;;   # Kavita signs in through OIDC: its card is that application
          "GET /providers/oauth2/?client_id="*) echo '{"results":[]}' ;;
          "POST /core/applications/") sl=$(jq -r .slug <<<"$3"); echo "$sl a-$sl" >> "$T/apps"; echo "{\"pk\":\"a-$sl\"}" ;;
          "PATCH /core/applications/"*/) sl=${2#/core/applications/}; sl=${sl%/}; echo "$sl" >> "$T/patched"   # authentik answers with the application
              pk=$(awk -v s="$sl" '$1==s{print $2}' "$T/apps"); [[ "$sl" == mediastack-app-navidrome ]] && pk="a-nav"; echo "{\"pk\":\"$pk\"}" ;;
          "GET /core/applications/"*/) sl=${2#/core/applications/}; sl=${sl%/}
              pk=$(awk -v s="$sl" '$1==s{print $2}' "$T/apps"); [[ "$sl" == mediastack-app-navidrome ]] && pk="a-nav"
              [[ -n "$pk" ]] && echo "{\"pk\":\"$pk\"}" || { echo '{"detail":"Not found."}'; return 1; } ;;
          "GET /policies/bindings/?target="*) t=${2#*=}
              awk -v t="$t" '$1==t{printf "%s{\"group\":\"%s\",\"pk\":\"%s~%s\"}", (n++?",":""), $2, $1, $2} BEGIN{printf "{\"results\":["} END{print "]}"}' "$T/bind" 2>/dev/null || echo '{"results":[]}' ;;
          "DELETE /policies/bindings/"*/) b=${2#/policies/bindings/}; b=${b%/}; awk -v t="${b%%~*}" -v g="${b#*~}" '!($1==t && $2==g)' "$T/bind" > "$T/bind.n"; mv "$T/bind.n" "$T/bind"; echo '' ;;
          "POST /policies/bindings/") (( NOBIND )) && return 1; echo "$(jq -r .target <<<"$3") $(jq -r .group <<<"$3")" >> "$T/bind"; echo '{}' ;;
          "GET /outposts/instances/?managed__iexact=goauthentik.io/outposts/embedded") echo "{\"results\":[{\"pk\":\"op-1\",\"providers\":$(cat "$T/op")}]}" ;;
          "PATCH /outposts/instances/op-1/") [[ -n "${LOST:-}" ]] && { echo 'no answer within 90s'; return 1; }
              jq -c .providers <<<"$3" > "$T/op"; [[ -n "${LATE:-}" ]] && { echo 'no answer within 90s'; return 1; }; echo '{}' ;;
          *) echo '{}' ;;
        esac; }
      svc_tier() { case "$1" in sonarr) echo "${ST:-admin}" ;; navidrome) echo "${NT:-frontend}" ;; jellyfin) echo "${JT:-frontend}" ;; kavita) echo "${KT:-frontend}" ;; *) echo admin ;; esac; }
      wire_authentik_cards >/dev/null 2>&1; echo "fails=$WIRE_FAILS" )
}
binds() { awk -v t="$1" '$1==t{print $2}' "$T/bind" | sort | paste -sd, -; }
[[ "$(gates_run)" == fails=0 ]] || fail_ "every gated app wired without a failure: $(gates_run)"; pass
grep -q '^POST /core/groups/ .*"name":"app-sonarr"' "$T/calls" && grep -q '^POST /core/groups/ .*"name":"app-navidrome"' "$T/calls" \
    || fail_ "each gated app gets its own app-<svc> group"; pass
grep -q '^POST /providers/proxy/ .*"name":"mediastack-app-sonarr".*"mode":"forward_single".*"external_host":"https://sonarr.media.example.com"' "$T/calls" \
    || fail_ "an admin tool gets a gate of its own: forward auth for its one address"; pass
grep -qF 'PATCH /providers/proxy/42/ {"name":"mediastack-app-navidrome","mode":"forward_single","external_host":"https://navidrome.media.example.com"}' "$T/calls" \
    && ! grep -q '^POST /providers/proxy/ .*mediastack-app-navidrome' "$T/calls" || fail_ "Navidrome's household gate is renamed in place, not made anew"; pass
grep -q '^POST /core/applications/ .*"slug":"mediastack-app-sonarr".*"group":"Admin tools".*"provider":50' "$T/calls" \
    || fail_ "the tool's card carries its gate: $(grep 'POST /core/applications/' "$T/calls")"; pass
[[ "$(awk '$1=="a-mediastack-app-sonarr"{print $2}' "$T/bind" | sort | paste -sd, -)" == "g-adm,g-app-sonarr" ]] \
    || fail_ "a tool: admins and its own group, nobody else: $(cat "$T/bind")"; pass
[[ "$(awk '$1=="a-nav"{print $2}' "$T/bind" | sort | paste -sd, -)" == "g-adm,g-app-navidrome,g-mu" ]] \
    && [[ "$(grep -c 'POST /policies/bindings/ .*"target":"a-nav"' "$T/calls")" == 1 ]] \
    || fail_ "Navidrome keeps the household and admin groups and gains its own group, one binding added: $(awk '$1=="a-nav"' "$T/bind" | paste -sd' ' -)"; pass
[[ "$(cat "$T/op")" == "[6,42,50]" ]] || fail_ "both gates join the outpost beside what is there: $(cat "$T/op")"; pass
[[ "$(grep -c '^PATCH /outposts/instances/op-1/' "$T/calls")" == 1 ]] \
    || fail_ "one outpost write for every gate (writes one after another can undo each other): $(grep -c '^PATCH /outposts' "$T/calls")"; pass
b=$(grep -n 'POST /policies/bindings/ .*a-mediastack-app-sonarr' "$T/calls" | tail -1 | cut -d: -f1)
o=$(grep -n 'PATCH /outposts/instances/op-1/ .*50' "$T/calls" | sed -n 1p | cut -d: -f1)
[[ -n "$b" && -n "$o" ]] && (( b < o )) || fail_ "the gate reaches the outpost only after its card's rule is in (bindings line $b, outpost line $o)"; pass
grep -q '^POST /core/applications/ .*"slug":"mediastack-app-jellyfin".*"group":"Media"' "$T/calls" \
    && ! grep -q '"slug":"mediastack-app-jellyfin".*"provider"' "$T/calls" || fail_ "Jellyfin: a plain Media card (its own login)"; pass
grep -q '^DELETE /core/applications/mediastack-tool-sonarr/' "$T/calls" && grep -q '^DELETE /core/applications/mediastack-tool-oldsvc/' "$T/calls" \
    || fail_ "the tools' old link cards leave"; pass
grep -q '^DELETE /core/applications/mediastack-app-audiobookshelf/' "$T/calls" || fail_ "a card for an app no longer enabled leaves"; pass
! grep -q 'my-own-app' <(grep -E '^(DELETE|PATCH)' "$T/calls") || fail_ "an application you made is never touched"; pass
[[ "$(gates_run 0 1)" != fails=0 ]] && [[ "$(cat "$T/op")" == "[6]" ]] \
    || fail_ "bindings refused: no gate reaches the outpost (an unbound card would admit everyone): $(cat "$T/op")"; pass
gates_run 1 >/dev/null; ! grep -qE '^(POST|PATCH|DELETE) ' "$T/calls" || fail_ "a dry run writes nothing: $(grep -E '^(POST|PATCH|DELETE) ' "$T/calls")"; pass
[[ "$(LATE=1 gates_run)" == fails=0 && "$(cat "$T/op")" == "[6,42,50]" ]] && [[ "$(grep -c '^POST /providers/proxy/' "$T/calls")" == 1 ]] \
    || fail_ "authentik slow to answer: the gate made once, read back; the outpost write read back — no failure: $(LATE=1 gates_run) $(cat "$T/op")"; pass
[[ "$(LOST=1 gates_run)" == fails=1 && "$(cat "$T/op")" == "[6]" ]] \
    || fail_ "an outpost write that never landed: one failure, nothing assumed: $(LOST=1 gates_run) $(cat "$T/op")"; pass
# tiers: frontend — the household and its admins, on the Media shelf; admin —
# admins only, with the tools, the household's binding taken off
[[ "$(ST=frontend gates_run)" == fails=0 ]] && grep -q '^POST /core/applications/ .*"slug":"mediastack-app-sonarr".*"group":"Media"' "$T/calls" \
    && [[ "$(awk '$1=="a-mediastack-app-sonarr"{print $2}' "$T/bind" | sort | paste -sd, -)" == "g-adm,g-app-sonarr,g-mu" ]] \
    || fail_ "sonarr in frontend: on the Media shelf, for the household, admins and its own group: $(awk '$1=="a-mediastack-app-sonarr"' "$T/bind" | paste -sd' ' -)"; pass
[[ "$(NT="admin" gates_run)" == fails=0 ]] && grep -q '^PATCH /core/applications/mediastack-app-navidrome/ .*"group":"Admin tools"' "$T/calls" \
    && grep -qx 'DELETE /policies/bindings/a-nav~g-mu/ ' "$T/calls" \
    && [[ "$(awk '$1=="a-nav"{print $2}' "$T/bind" | sort | paste -sd, -)" == "g-adm,g-app-navidrome" ]] \
    || fail_ "navidrome in admin: moved to the tools, the household's binding removed, admins and its own group kept: $(awk '$1=="a-nav"' "$T/bind" | paste -sd' ' -) $(grep -c DELETE "$T/calls")"; pass
[[ "$(NT="admin" gates_run 1)" == fails=0 ]] && ! grep -qE '^(POST|PATCH|DELETE) ' "$T/calls" || fail_ "a dry run of a tier move writes nothing"; pass
# Jellyfin under the rule (slice B): its card, Seerr's (it signs in through
# Jellyfin) and Jellyfin's sign-in — the LDAP application — say who may open it
[[ "$(gates_run)" == fails=0 ]] || fail_ "with Jellyfin and Seerr: no failure"; pass
grep -q '^POST /core/groups/ .*"name":"app-jellyfin"' "$T/calls" && ! grep -q '"name":"app-seerr"' "$T/calls" || fail_ "Jellyfin gets app-jellyfin; Seerr no group of its own"; pass
[[ "$(binds a-mediastack-app-jellyfin)" == "g-adm,g-app-jellyfin,g-mu" && "$(binds a-mediastack-app-seerr)" == "g-adm,g-app-jellyfin,g-mu" ]] \
    || fail_ "tier frontend: Jellyfin's and Seerr's cards — the household, admins, app-jellyfin: $(binds a-mediastack-app-jellyfin) / $(binds a-mediastack-app-seerr)"; pass
[[ "$(binds a-ldap)" == "g-adm,g-app-jellyfin,g-mu" ]] && [[ "$(grep -c 'POST /policies/bindings/ .*"target":"a-ldap"' "$T/calls")" == 1 ]] \
    || fail_ "tier frontend: the LDAP application keeps the household and admins, gains app-jellyfin (one binding): $(binds a-ldap)"; pass
[[ "$(JT="admin" gates_run)" == fails=0 ]] || fail_ "Jellyfin to admin: no failure"; pass
[[ "$(binds a-ldap)" == "g-adm,g-app-jellyfin" ]] && grep -qx 'DELETE /policies/bindings/a-ldap~g-mu/ ' "$T/calls" \
    || fail_ "tier admin: the household off Jellyfin's sign-in, admins and app-jellyfin kept: $(binds a-ldap)"; pass
[[ "$(binds a-mediastack-app-jellyfin)" == "g-adm,g-app-jellyfin" && "$(binds a-mediastack-app-seerr)" == "g-adm,g-app-jellyfin" ]] \
    && grep -q '^POST /core/applications/ .*"slug":"mediastack-app-seerr".*"group":"Admin tools"' "$T/calls" \
    || fail_ "tier admin: Jellyfin's and Seerr's cards with the tools, for admins and app-jellyfin: $(binds a-mediastack-app-jellyfin) / $(binds a-mediastack-app-seerr)"; pass
[[ "$(JT="admin" gates_run 1)" == fails=0 ]] && ! grep -qE '^(POST|PATCH|DELETE) ' "$T/calls" || fail_ "a dry run of Jellyfin's tier move writes nothing"; pass
# Kavita (slice C): its card is its OIDC application — bound by the rule, the portal refuses at sign-in, before Kavita
[[ "$(gates_run)" == fails=0 ]] && grep -q '^POST /core/applications/ .*"slug":"mediastack-app-kavita".*"provider":77' "$T/calls" \
    && [[ "$(binds a-mediastack-app-kavita)" == "g-adm,g-app-kavita,g-mu" ]] \
    || fail_ "tier frontend: Kavita's sign-in application admits the household, admins, app-kavita: $(binds a-mediastack-app-kavita)"; pass
[[ "$(KT="admin" gates_run)" == fails=0 && "$(binds a-mediastack-app-kavita)" == "g-adm,g-app-kavita" ]] && [[ "$(binds a-ldap)" == "g-adm,g-app-jellyfin,g-mu" ]] \
    || fail_ "Kavita to admin: the household off its sign-in; Jellyfin's left as it was: $(binds a-mediastack-app-kavita) / $(binds a-ldap)"; pass
[[ "$(MOVED=1 gates_run)" == fails=0 ]] && grep -qF 'PATCH /providers/proxy/50/ {"mode":"forward_single","external_host":"https://sonarr.media.example.com"}' "$T/calls" \
    || fail_ "an app's address changed: its gate follows, the update saying its mode (authentik refuses one without): $(grep 'PATCH /providers/proxy/50' "$T/calls")"; pass

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
grep -q 'mediastack-ldap-allow:' services/traefik/edge.sh && grep -q 'sourceRange: \["$(env_get MEDIASTACK_SUBNET)"\]' services/traefik/edge.sh \
    || fail_ "the LDAP route answers the stack network only"; pass
grep -q 'traefik.tcp.routers.authentik-ldap.middlewares: "mediastack-ldap-allow@file"' services/authentik/compose.yml || fail_ "the LDAP route carries the allow-list"; pass
bp=services/authentik/blueprints/mediastack-portal.yaml
grep -q 'mfa_support: false' <<<"$(sed -n '/name: mediastack-ldap$/,/^  - /p' "$bp")" || fail_ "LDAP binds: no MFA prompt (TV apps cannot answer one)"; pass
grep -q 'search_mode: direct' <<<"$(sed -n '/name: mediastack-ldap$/,/^  - /p' "$bp")" \
    || fail_ "LDAP searches ask authentik live (cached: a new sign-up waited up to 5 minutes for Jellyfin, found live)"; pass
grep -q 'bind_mode: direct' <<<"$(sed -n '/name: mediastack-ldap$/,/^  - /p' "$bp")" \
    || fail_ "LDAP binds run authentik's sign-in every time (cached: a correct guess got past the throttle, found live)"; pass
grep -q 'authorization_flow: !KeyOf flow-ldap' <<<"$(sed -n '/name: mediastack-ldap$/,/^  - /p' "$bp")" \
    || fail_ "the outpost binds through authorization_flow — it must be the LDAP bind flow (found live)"; pass
grep -q '^      config:' <<<"$(sed -n '/model: authentik_outposts.outpost/,/^  - /p' "$bp")" || fail_ "an outpost needs its config block (authentik requires it; found live)"; pass
grep -q 'permission: authentik_providers_ldap.search_full_directory' <<<"$(grep -A3 'permissions:' "$bp")" \
    || fail_ "only the search account may list the directory — by the full permission name (the dry run rejects the short form)"; pass
# the throttle: at the login step (the user is known there), counting only the
# person's score at Traefik's address — the Jellyfin path (found live: authentik's
# reputation policy summed every address, and web sign-ins hid the guessing)
grep -q 'policy: !KeyOf policy-ldap-throttle' <<<"$(sed -n '/target: !KeyOf binding-ldap-login/,/^  - /p' "$bp")" \
    && ! grep -q 'negate: true' <<<"$(sed -n '/target: !KeyOf binding-ldap-login/,/^  - /p' "$bp")" || fail_ "throttle: at the login step, not negated (True = let in)"; pass
grep -q 'state: absent' <<<"$(sed -n '/name: mediastack-ldap-reputation$/,/^  - /p' "$bp")" || grep -q 'state: absent' <<<"$(grep -B2 'name: mediastack-ldap-reputation$' "$bp")" \
    || fail_ "the summing reputation policy is removed (its bindings with it)"; pass
grep -q 'MEDIASTACK_TRAEFIK_ADDRESS: ${TRAEFIK_ADDRESS:-172.31.250.2}' "$T/worker" || fail_ "the worker passes Traefik's address to the throttle"; pass
# run the expression itself against scores: per person, only the Jellyfin path, floor -5
expr=$(awk '/name: mediastack-ldap-throttle$/{f=1} f && /^        - \|$/{g=1; next} g && /^        - !Env/{exit} g{sub(/^          /, ""); print}' "$bp")
[[ "$expr" == *'ip="%s"'* ]] || fail_ "throttle expression not found in the blueprint"; pass
throttle_says() { # throttle_says USER 'ROWS' [RECENT] -> allow|refuse   (ROWS: identifier,ip,score;...; RECENT=1: an alert in the last 6 h)
    python3 - "$1" "$2" "${expr//%s/172.31.250.2}" "${3:-0}" <<'PY'
import sys, types
user, rows, expr, recent = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
rows = [tuple(r.split(",")) for r in rows.split(";") if r]
class Q:
    def __init__(s, kw): s.kw = kw
    def aggregate(s, **_):
        m = [int(sc) for i, ip, sc in rows if i == s.kw["identifier"] and ip == s.kw["ip"]]
        return {"total": sum(m) if m else None}
class Mgr:
    def filter(s, **kw): return Q(kw)
mods = {"django": types.ModuleType("django"), "django.db": types.ModuleType("django.db"), "django.db.models": types.ModuleType("django.db.models"),
        "authentik": types.ModuleType("authentik"), "authentik.policies": types.ModuleType("authentik.policies"),
        "authentik.policies.reputation": types.ModuleType("authentik.policies.reputation"),
        "authentik.policies.reputation.models": types.ModuleType("authentik.policies.reputation.models"),
        "django.utils": types.ModuleType("django.utils"), "django.utils.timezone": types.ModuleType("django.utils.timezone"),
        "authentik.events": types.ModuleType("authentik.events"), "authentik.events.models": types.ModuleType("authentik.events.models")}
import datetime
mods["django.utils.timezone"].now = datetime.datetime.now
asked = []
class EvQ:
    def __init__(s, kw): s.kw = kw
    def exists(s): asked.append(s.kw); return recent
mods["authentik.events.models"].Event = type("E", (), {"objects": types.SimpleNamespace(filter=lambda **kw: EvQ(kw))})
mods["django.db.models"].Sum = lambda f: f
mods["authentik.policies.reputation.models"].Reputation = type("R", (), {"objects": Mgr()})
sys.modules.update(mods)
req = types.SimpleNamespace(user=types.SimpleNamespace(username=user))
logged = []
log = types.SimpleNamespace(warning=lambda m, **kw: logged.append((m, kw)))
events = []
env = {"request": req, "ak_logger": log, "ak_create_event": lambda a, **kw: events.append((a, kw))}
exec("def _f():\n" + "\n".join("    " + l for l in expr.splitlines()), env)
ok = env["_f"]()
# a refusal names the person in the server log; a let-in logs nothing
assert (not ok) == bool(logged), logged
assert all("throttled" in m and kw.get("user") == user for m, kw in logged), logged
# a refusal raises the lockout alert for that person, unless one went out in the
# last 6 hours (it asks about this person and this action only); a let-in raises none
if ok:
    assert not events and not asked, (events, asked)
else:
    assert asked and asked[0].get("context__username") == user and asked[0].get("action__endswith") == "mediastack_jellyfin_lockout", asked
    assert events == ([] if recent else [("mediastack_jellyfin_lockout", {"username": user})]), events
print("allow" if ok else "refuse")
PY
}
[[ "$(throttle_says milo 'milo,172.31.250.2,-5' 1)" == refuse ]] || fail_ "an alert in the last 6 hours: still refused, no second alert"; pass
[[ "$(throttle_says milo 'milo,172.31.250.2,-5;milo,192.168.69.18,1;milo,192.168.69.103,1')" == refuse ]] \
    || fail_ "at the floor on the Jellyfin path: refused, whatever the web sign-ins (the live -5 + 1 + 1 case)"; pass
[[ "$(throttle_says milo 'milo,172.31.250.2,-4;milo,192.168.69.18,-5')" == allow ]] || fail_ "above the floor on the Jellyfin path: let in (web failures do not count)"; pass
[[ "$(throttle_says milo 'jo,172.31.250.2,-5')" == allow ]] || fail_ "another person's failures never lock this one out"; pass
[[ "$(throttle_says milo '')" == allow ]] || fail_ "no score at all: let in"; pass
! grep -q 'ak_message' <<<"$expr" || fail_ "throttle: no ak_message — on a stage binding it is shown nowhere (found live); the server log tells the admin"; pass
grep -q 're_evaluate_policies: true' <<<"$(sed -n '/stage: !KeyOf stage-ldap-login/,/^  - /p' "$bp")" || fail_ "the login step re-checks once the user is known"; pass
lb=$(grep -A2 'target: !KeyOf app-ldap' "$bp")
[[ "$(grep -c 'target: !KeyOf app-ldap' "$bp")" == 2 ]] && [[ "$lb" == *'group: !KeyOf group-admin'* && "$lb" != *group-frontend* ]] \
    || fail_ "binds here: admin and the search account only — the household's is wire's (a re-applied blueprint would undo a tier move)"; pass

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
printf 'STACK_DOMAIN=media.example.com\nAUTHENTIK_LDAP_BIND_PASSWORD=BINDPW\nACME_ENV=staging\n' > "$ENV_FILE"
svc_tier() { echo frontend; }   # Jellyfin's tier as its label sets it (no render here)
w=$(jf_ldap_want)
[[ "$(jq -r '.LdapServer + ":" + (.LdapPort|tostring) + " ssl=" + (.UseSsl|tostring)' <<<"$w")" == "ldap.media.example.com:443 ssl=true" ]] \
    || fail_ "LDAPS to ldap.<domain>:443 through Traefik: $w"; pass
[[ "$(jq -r '.SkipSslVerify' <<<"$w")" == true ]] || fail_ "staging certificates: checking off"; pass
printf 'STACK_DOMAIN=media.example.com\nACME_ENV=production\n' > "$ENV_FILE"
[[ "$(jf_ldap_want | jq -r '.SkipSslVerify')" == false ]] || fail_ "production certificates: checking on"; pass
[[ "$(jq -r '.LdapSearchFilter' <<<"$w")" == "(|(memberOf=cn=frontend,ou=groups,dc=ldap,dc=mediastack)(memberOf=cn=admin,ou=groups,dc=ldap,dc=mediastack)(memberOf=cn=app-jellyfin,ou=groups,dc=ldap,dc=mediastack))" ]] \
    || fail_ "tier frontend: the household, admins and those granted Jellyfin may sign in: $(jq -r '.LdapSearchFilter' <<<"$w")"; pass
[[ "$(svc_tier() { echo admin; }; jf_ldap_want | jq -r '.LdapSearchFilter')" == "(|(memberOf=cn=admin,ou=groups,dc=ldap,dc=mediastack)(memberOf=cn=app-jellyfin,ou=groups,dc=ldap,dc=mediastack))" ]] \
    || fail_ "tier admin: admins and those granted Jellyfin only"; pass
# shellcheck disable=SC1090  # the real one, back from its stub
source <(sed -n '/^svc_tier() {/,/^}/p' services/authentik/authentik.sh)
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
ak_api() { echo '{"results":[{"username":"akadmin"},{"username":"alice"}]}'; }
jf_api() { echo "$1 $2 ${4:-}" >> "$T/calls"
    case "$1 $2" in
        "GET /Users") jq -cn --arg p "$JF_LDAP_PROVIDER" '[
            {Name:"akadmin", Id:"1", Policy:{IsAdministrator:false, AuthenticationProviderId:$p}},
            {Name:"test-thio", Id:"2", Policy:{IsAdministrator:true, AuthenticationProviderId:$p}},
            {Name:"alice", Id:"3", Policy:{IsAdministrator:true, AuthenticationProviderId:$p}},
            {Name:"mediastack", Id:"4", Policy:{IsAdministrator:true, AuthenticationProviderId:"Jellyfin.Server.Implementations.Users.DefaultAuthenticationProvider"}}]' ;;
        *) echo '{}' ;;
    esac; }
jf_admin_sync tok >/dev/null
grep -q '^POST /Users/1/Policy .*"IsAdministrator":true' "$T/calls" || fail_ "an admin in the directory becomes a Jellyfin administrator"; pass
grep -q '^POST /Users/2/Policy .*"IsAdministrator":false' "$T/calls" || fail_ "a directory user not in admins loses administrator"; pass
! grep -q '^POST /Users/3/' "$T/calls" || fail_ "already right: no write"; pass
! grep -q '^POST /Users/4/' "$T/calls" || fail_ "the stack's own local admin is never touched"; pass

# ---- Audiobookshelf: the stack's root, sign-in through the portal, admin sync ----
printf 'STACK_DOMAIN=media.example.com\nAUTHENTIK_ABS_CLIENT_SECRET=ABSSEC\nPORTAL_TITLE=Home\n' > "$ENV_FILE"
w=$(abs_oidc_want)
[[ "$(jq -r '.authOpenIDIssuerURL' <<<"$w")" == "https://portal.media.example.com/application/o/mediastack-app-audiobookshelf/" \
   && "$(jq -r '.authOpenIDTokenURL' <<<"$w")" == "https://portal.media.example.com/application/o/token/" \
   && "$(jq -r '.authOpenIDJwksURL' <<<"$w")" == "https://portal.media.example.com/application/o/mediastack-app-audiobookshelf/jwks/" ]] \
    || fail_ "Audiobookshelf's portal addresses: $w"; pass
[[ "$(jq -r '[.authOpenIDClientSecret, .authOpenIDTokenSigningAlgorithm, (.authOpenIDAutoRegister|tostring), .authOpenIDButtonText] | join(",")' <<<"$w")" == "ABSSEC,RS256,true,Log in with Home" ]] \
    || fail_ "secret, RS256, created on first sign-in, the portal's name on the button"; pass
[[ "$(jq -c 'has("authOpenIDMatchExistingBy") and .authOpenIDMatchExistingBy == null' <<<"$w")" == true ]] \
    || fail_ "never matched to an existing account (by username the stack's root was claimable), set explicitly to null"; pass
[[ "$(jq -c '.authActiveAuthMethods' <<<"$w")" == '["local","openid"]' ]] || fail_ "its own login stays (the stack's root account)"; pass
[[ "$(jq -r '.authOpenIDAutoLaunch' <<<"$w")" == true ]] || fail_ "its login page goes straight to the portal (the form stays behind ?autoLaunch=0)"; pass
[[ "$(jq -r '.authOpenIDSubfolderForRedirectURLs | type + ":" + .' <<<"$w")" == "string:" ]] \
    || fail_ "no subfolder, set explicitly — unset, its callback reads undefined/auth/openid/callback (found live)"; pass
# first run: a fresh Audiobookshelf gets the stack's root; a hand-made one is not taken over
rm -f "$T/calls"; printf 'STACK_DOMAIN=media.example.com\nABS_ADMIN_USER=admin\nABS_ADMIN_PASSWORD=Pw0123456789ab\n' > "$ENV_FILE"
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
grep -q '^POST /init {"newRoot":{"username":"admin","password":"Pw0123456789ab"}}' "$T/calls" \
    || fail_ "a fresh Audiobookshelf: the stack's root account, as configure recorded it"; pass
grep -q '^POST /login' "$T/calls" || fail_ "then it logs in with it"; pass
rm -f "$T/calls"; printf 'STACK_DOMAIN=media.example.com\n' > "$ENV_FILE"; WIRE_FAILS=0
out=$(wire_audiobookshelf 2>&1) || true
! grep -q '^POST /init' "$T/calls" && [[ "$out" == *"root login is not in .env"* ]] || fail_ "no recorded login: wire makes none — it says so"; pass
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
            {"id":"l","username":"local-bob","type":"admin","hasOpenIDLink":false},
            {"id":"g","username":"kid","type":"guest","hasOpenIDLink":true}]}' ;;
        *) echo '{}' ;;
    esac; }
abs_admin_sync tok >/dev/null
grep -q '^PATCH /api/users/a {"type":"admin"}' "$T/calls" && grep -q '^PATCH /api/users/t {"type":"user"}' "$T/calls" \
    || fail_ "portal accounts: admins are admin, the rest user"; pass
! grep -qE '^PATCH /api/users/(r|l|g) ' "$T/calls" || fail_ "the root account, local accounts and a guest outside admins are never touched"; pass
# sign-in settings: read back after the write — a value it skips is a failure, not success
printf 'STACK_DOMAIN=media.example.com\nAUTHENTIK_ABS_CLIENT_SECRET=ABSSEC\n' > "$ENV_FILE"
ABS_KEPT='{"authOpenIDMatchExistingBy":"username"}'
abs_api() { echo "$1 $2" >> "$T/calls"
    case "$1 $2" in
        "GET /api/auth-settings") abs_oidc_want | jq -c --argjson k "$ABS_KEPT" '. + $k' ;;
        *) echo '{}' ;;
    esac; }
rm -f "$T/calls"; WIRE_FAILS=0
out=$(abs_oidc tok 2>&1) && rc=0 || rc=$?
(( rc != 0 )) && [[ "$out" == *"did not keep"*"authOpenIDMatchExistingBy"* ]] && grep -q '^PATCH /api/auth-settings' "$T/calls" \
    || fail_ "a setting it answered 200 to but did not keep fails, naming the setting"; pass
ABS_KEPT='{}'; rm -f "$T/calls"; WIRE_FAILS=0
abs_oidc tok >/dev/null && ! grep -q '^PATCH' "$T/calls" || fail_ "already right: no write"; pass
# root's password: changed through its own account, stored, then proven by a sign-in
# (a password change is what ends Audiobookshelf sessions — an unlink does not)
printf 'ABS_ADMIN_USER=mediastack\nABS_ADMIN_PASSWORD=OLDPW\n' > "$ENV_FILE"
echo OLDPW > "$T/abs-pw"; ABS_PW_REFUSE=false; ABS_ROOT_LINK=true
abs_api() { echo "$1 $2 ${4:-}" >> "$T/calls"
    case "$1 $2" in
        "POST /login") [[ "$(jq -r .password <<<"$4")" == "$(cat "$T/abs-pw")" ]] || return 1
                       echo '{"user":{"accessToken":"ABSTOK"}}' ;;
        "PATCH /api/me/password") $ABS_PW_REFUSE && { echo 'Invalid password'; return 1; }
                       [[ "$(jq -r .password <<<"$4")" == "$(cat "$T/abs-pw")" ]] || return 1
                       jq -r .newPassword <<<"$4" > "$T/abs-pw"; echo '{"success":true}' ;;
        "GET /api/users") echo "{\"users\":[{\"id\":\"r\",\"username\":\"mediastack\",\"type\":\"root\",\"hasOpenIDLink\":$ABS_ROOT_LINK},
                          {\"id\":\"t\",\"username\":\"test-thio\",\"type\":\"user\",\"hasOpenIDLink\":true}]}" ;;
        *) echo '{}' ;;
    esac; }
rm -f "$T/calls"
abs_root_rotate NEWPW >/dev/null && [[ "$(env_get ABS_ADMIN_PASSWORD)" == NEWPW && "$(cat "$T/abs-pw")" == NEWPW ]] \
    && grep -q '^PATCH /api/me/password {"password":"OLDPW","newPassword":"NEWPW"}' "$T/calls" \
    && [[ "$(grep -c '^POST /login' "$T/calls")" == 2 ]] \
    || fail_ "root's password: changed with the old one, stored, verified by signing in with the new one"; pass
ABS_PW_REFUSE=true; rm -f "$T/calls"
if abs_root_rotate OTHER >/dev/null; then fail_ "a refused change must fail"; fi
[[ "$(env_get ABS_ADMIN_PASSWORD)" == NEWPW ]] || fail_ "a refused change leaves .env as it was"; pass
ABS_PW_REFUSE=false
# the root account linked to a portal identity (the old username match) is unlinked
# AND its password rotated — that is what signs the intruder out — loudly
rm -f "$T/calls"; WIRE_FAILS=0
out=$(abs_root_unlink tok 2>&1) || true
grep -q '^PATCH /api/users/r/openid-unlink' "$T/calls" && ! grep -q '/api/users/t/' "$T/calls" && [[ "$out" == *"root account had been linked"*"password rotated"* ]] \
    || fail_ "a linked root is unlinked and reported as a failure; portal accounts keep their link"; pass
[[ "$(env_get ABS_ADMIN_PASSWORD)" != NEWPW && "$(env_get ABS_ADMIN_PASSWORD)" == "$(cat "$T/abs-pw")" ]] \
    || fail_ "the unlink rotates root's password (ends its sessions) and stores the new one"; pass
ABS_PW_REFUSE=true; rm -f "$T/calls"
out=$(abs_root_unlink tok 2>&1) || true
[[ "$out" == *"NOT rotated"*"set-credentials audiobookshelf"* ]] || fail_ "an unlink whose rotation fails says sessions stay open, and the fix"; pass
ABS_PW_REFUSE=false; ABS_ROOT_LINK=false; rm -f "$T/calls"
abs_root_unlink tok >/dev/null && ! grep -q '^PATCH' "$T/calls" || fail_ "an unlinked root: nothing to do"; pass

# ---- sign-up: a username the apps would confuse is refused ----
grep -q 'MEDIASTACK_RESERVED_USERNAMES: ${AUTHENTIK_RESERVED_USERNAMES:-} ' services/authentik/compose.yml \
    && grep -q 'env_set AUTHENTIK_RESERVED_USERNAMES "$(logins_reserved)"' <<<"$(awk '/^authentik_prepare\(\)/,/^}/' services/authentik/authentik.sh)" \
    || fail_ "the worker gets the stack's own logins marked reserve (lib/logins.sh), written by up"; pass
grep -q '!KeyOf policy-join-username' <<<"$(sed -n '/name: mediastack-join-credentials/,/fields:/p' services/authentik/blueprints/mediastack-portal.yaml)" \
    || fail_ "the sign-up page validates the username with the policy"; pass
# the policy's own expression, run with authentik's context stubbed: reserved names
# (any case, padded), and another person's name in another case
awk '/name: mediastack-join-username-free/{f=1} f&&/^        - \|/{e=1; next} e&&/^        - !Env/{exit} e{sub(/^          /,""); print}' \
    services/authentik/blueprints/mediastack-portal.yaml > "$T/expr.py"
[[ -s "$T/expr.py" ]] || fail_ "the policy's expression was not found"
python3 - "$T/expr.py" <<'PY' || fail_ "the sign-up username policy's verdicts"
import sys, types
src = open(sys.argv[1]).read() % "mediastack, jfadmin,"
existing = ["test-thio"]
class Q:
    def __init__(s, n): s.n = n
    def exists(s): return any(e.lower() == s.n.lower() for e in existing)
class Objects:
    @staticmethod
    def filter(username__iexact): return Q(username__iexact)
models = types.ModuleType("authentik.core.models"); models.User = type("User", (), {"objects": Objects})
for m in ("authentik", "authentik.core"): sys.modules[m] = types.ModuleType(m)
sys.modules["authentik.core.models"] = models
def verdict(name):
    msgs = []
    ns = {"request": types.SimpleNamespace(context={"prompt_data": {"username": name}}), "ak_message": msgs.append}
    exec("def policy():\n" + "".join("    " + l + "\n" for l in src.splitlines()), ns)
    ok = ns["policy"]()
    assert ok or msgs == ["That username is taken. Please choose another."], msgs
    return ok
for name, want in [("mediastack", False), ("MediaStack", False), (" jfadmin ", False), ("Test-Thio", False),
                   ("alice", True), ("mediastack2", True)]:
    assert verdict(name) is want, (name, want)
PY
pass

# ---- Kavita: the stack's admin, sign-in through the portal, admin sync ----
grep -q '"127.0.0.1:${KAVITA_PORT:-5000}:5000"' services/kavita/compose.yml || fail_ "Kavita is published on 127.0.0.1 only (the script's way in)"; pass
grep -q 'MEDIASTACK_KAVITA_CLIENT_SECRET: ${AUTHENTIK_KAVITA_CLIENT_SECRET}$' services/authentik/compose.yml \
    && grep -q 'MEDIASTACK_KAVITA_URL: https://${KAVITA_HOST:-books}.' services/authentik/compose.yml \
    && grep -q 'AUTHENTIK_KAVITA_CLIENT_SECRET; do' services/authentik/authentik.sh \
    || fail_ "Kavita's client secret: generated, and handed to the blueprint with its address"; pass
sed -n '/name: mediastack-oidc-kavita/,/^  - model/p' services/authentik/blueprints/mediastack-portal.yaml > "$T/kav"
grep -q 'client_id: mediastack-kavita' "$T/kav" && grep -q 'signing_key: !Find' "$T/kav" \
   && grep -q '"%s/signin-oidc"' "$T/kav" && grep -q '"%s/signout-callback-oidc"' "$T/kav" \
   && grep -q 'grant_types: \[authorization_code, refresh_token\]' "$T/kav" \
   && grep -q 'scope-offline_access' "$T/kav" \
    || fail_ "Kavita's OIDC provider: client ID, RS256 key, its callbacks, the code grant, offline_access"; pass
printf 'STACK_DOMAIN=media.example.com\nPORTAL_TITLE=Home\nAUTHENTIK_KAVITA_CLIENT_SECRET=KSEC\n' > "$ENV_FILE"
w=$(kav_oidc_want '[3,1]')
[[ "$(jq -r '.authority' <<<"$w")" == "https://portal.media.example.com/application/o/mediastack-app-kavita/" ]] || fail_ "Kavita's authority is its card's issuer: $w"; pass
[[ "$(jq -c '[.clientId, .provisionAccounts, .requireVerifiedEmail, .syncUserSettings, .autoLogin, .disablePasswordAuthentication, .providerName]' <<<"$w")" \
   == '["mediastack-kavita",true,false,false,true,false,"Home"]' ]] \
    || fail_ "created on first sign-in, no verified-email demand (authentik sends false), rights Kavita-side, straight to the portal, password form kept"; pass
[[ "$(jq -c '[.defaultLibraries, .defaultRoles, .defaultAgeRestriction, .defaultIncludeUnknowns]' <<<"$w")" == '[[1,3],["Login","Download","Bookmark"],-1,true]' ]] \
    || fail_ "new people: every current library, login/download/bookmark, no age limit"; pass
# first run: a fresh Kavita gets the stack's admin with an email nobody can sign up with
state_get() { cat "$T/state-$1" 2>/dev/null || true; }; state_set() { printf '%s\n' "$2" > "$T/state-$1"; }
svc_enabled() { [[ " kavita authentik " == *" $1 "* ]]; }; wire_gate() { :; }; http_ready() { :; }; kav_url() { echo http://kav; }
KAV_EXISTS=false
kav_api() { echo "$1 $2 ${4:-}" >> "$T/calls"
    case "$1 $2" in
        "GET /api/admin/exists") echo "$KAV_EXISTS" ;;
        "POST /api/account/register") echo '{}' ;;
        "POST /api/account/login") echo '{"token":"KTOK"}' ;;
        *) echo '{}' ;;
    esac; }
kav_stubbed() { ( kav_admin_email_check() { :; }; kav_oidc() { echo "KAV_OIDC" >> "$T/calls"; }; kav_admin_sync() { :; }; wire_kavita ); }
rm -f "$T/calls"; printf 'STACK_DOMAIN=media.example.com\nKAVITA_ADMIN_USER=admin\nKAVITA_ADMIN_PASSWORD=Pw0123456789ab\n' > "$ENV_FILE"
kav_stubbed >/dev/null
grep -q '^POST /api/account/register {"username":"admin","password":"Pw0123456789ab","email":"admin@[a-z0-9]*\.invalid"}' "$T/calls" \
    && [[ "$(env_get KAVITA_ADMIN_EMAIL)" == admin@*.invalid ]] \
    || fail_ "a fresh Kavita: the stack's admin as configure recorded it, with an unclaimable email (Kavita's default is the username)"; pass
grep -q '^KAV_OIDC' "$T/calls" || fail_ "then sign-in through the portal"; pass
rm -f "$T/calls"; printf '' > "$ENV_FILE"; KAV_EXISTS=true; WIRE_FAILS=0
out=$(kav_stubbed 2>&1) || true
! grep -q '^POST /api/account/register' "$T/calls" && [[ "$out" == *"set up by hand"*"KAVITA_ADMIN_USER"* ]] || fail_ "one set up by hand is never taken over — it says what to do"; pass
# its sign-in settings: merged into its settings with the secret, read back, one restart when its start-up part changes
printf 'STACK_DOMAIN=media.example.com\nAUTHENTIK_KAVITA_CLIENT_SECRET=KSEC\n' > "$ENV_FILE"; rm -f "$T"/state-*
echo '{"oidcConfig":{"authority":"","clientId":"","secret":"","defaultLibraries":[]},"other":1}' > "$T/kav-settings"
KAV_KEEP=true; KAV_LIVE=false
kav_api() { echo "$1 $2" >> "$T/calls"
    case "$1 $2" in
        "GET /api/settings") cat "$T/kav-settings" ;;
        "POST /api/settings") echo "$4" > "$T/kav-posted"; $KAV_KEEP && jq -c '.oidcConfig.secret = ("*" * (.oidcConfig.secret|length))' <<<"$4" > "$T/kav-settings"; echo '{}' ;;
        "GET /api/library/libraries") echo '[{"id":2,"name":"Comics"},{"id":1,"name":"Books"}]' ;;
        "GET /api/settings/oidc") echo "{\"enabled\":$KAV_LIVE}" ;;
        *) echo '{}' ;;
    esac; }
notify_interruption() { echo "NOTIFY $1" >> "$T/calls"; }
DC() { echo "DC $*" >> "$T/calls"; KAV_LIVE=true; }
rm -f "$T/calls"; WIRE_FAILS=0
kav_oidc tok >/dev/null || fail_ "kav_oidc failed"
[[ "$(jq -c '[.other, .oidcConfig.secret, .oidcConfig.clientId, .oidcConfig.defaultLibraries]' "$T/kav-posted")" == '[1,"KSEC","mediastack-kavita",[1,2]]' ]] \
    || fail_ "the whole settings go back with the sign-in merged in, the secret included, every library"; pass
grep -q '^NOTIFY ' "$T/calls" && grep -q '^DC restart kavita$' "$T/calls" \
    && [[ "$(grep -n '^NOTIFY' "$T/calls" | cut -d: -f1)" -lt "$(grep -n '^DC restart' "$T/calls" | cut -d: -f1)" ]] \
    || fail_ "a new authority: the household warned, then one restart (its OIDC is set up at start-up)"; pass
rm -f "$T/calls"
kav_oidc tok >/dev/null && ! grep -qE '^(POST /api/settings|DC )' "$T/calls" || fail_ "already right and live: no write, no restart"; pass
printf 'STACK_DOMAIN=media.example.com\nAUTHENTIK_KAVITA_CLIENT_SECRET=ROTATED\n' > "$ENV_FILE"; rm -f "$T/calls"
kav_oidc tok >/dev/null && grep -q '^POST /api/settings' "$T/calls" && grep -q '^DC restart kavita$' "$T/calls" \
    || fail_ "a new client secret (read back masked) is noticed by its digest: written, and one restart"; pass
KAV_LIVE=false; rm -f "$T/calls"
kav_oidc tok >/dev/null && ! grep -q '^POST /api/settings' "$T/calls" && grep -q '^DC restart kavita$' "$T/calls" \
    || fail_ "settings right but not live: a restart only"; pass
echo '{"oidcConfig":{"authority":"","clientId":"","secret":"","defaultLibraries":[]}}' > "$T/kav-settings"; KAV_KEEP=false; rm -f "$T/calls"; WIRE_FAILS=0
out=$(kav_oidc tok 2>&1) && fail_ "a setting it answered 200 to but did not keep must fail"
[[ "$out" == *"did not keep"*"authority"*".well-known/openid-configuration"* ]] && ! grep -q '^DC ' "$T/calls" \
    || fail_ "it names the setting and why the authority can be refused, and does not restart: $out"; pass
KAV_KEEP=true
# admin sync: portal accounts only, the whole record back with only the roles changed; includePending
ak_api() { echo '{"results":[{"username":"akadmin"}]}'; }
KAV_USERS='[
 {"id":1,"username":"mediastack","email":"mediastack@x.invalid","identityProvider":0,"roles":["Admin","Login"],"libraries":[],"ageRestriction":{"ageRating":-1,"includeUnknowns":true}},
 {"id":2,"username":"akadmin","email":"a@b.c","identityProvider":1,"roles":["Login"],"libraries":[{"id":1},{"id":2}],"ageRestriction":{"ageRating":5,"includeUnknowns":false}},
 {"id":3,"username":"test-thio","email":"t@b.c","identityProvider":1,"roles":["Admin","Login","Download"],"libraries":[{"id":1}],"ageRestriction":{"ageRating":-1,"includeUnknowns":true}},
 {"id":4,"username":"local-bob","email":"l@b.c","identityProvider":0,"roles":["Login"],"libraries":[],"ageRestriction":null}]'
echo "$KAV_USERS" > "$T/kav-users"
kav_api() { echo "$1 $2 ${4:-}" >> "$T/calls"
    case "$1 $2" in
        "GET /api/users?includePending=true") cat "$T/kav-users" ;;
        "POST /api/account/update") jq -c --argjson b "$4" 'map(if .id == $b.userId then .roles = $b.roles else . end)' "$T/kav-users" > "$T/kav-users.n" && mv "$T/kav-users.n" "$T/kav-users"; echo '{}' ;;
        *) echo '[]' ;;
    esac; }
rm -f "$T/calls"; WIRE_FAILS=0
kav_admin_sync tok >/dev/null
grep -q '^POST /api/account/update {"userId":2,"username":"akadmin","email":"a@b.c","identityProvider":1,"roles":\["Admin","Login"\],"libraries":\[1,2\],"ageRestriction":{"ageRating":5,"includeUnknowns":false}}$' "$T/calls" \
    || fail_ "an admin in the portal becomes Kavita admin; everything else goes back as it was: $(grep update "$T/calls")"; pass
grep -q '^POST /api/account/update {"userId":3,.*"roles":\["Login","Download"\]' "$T/calls" || fail_ "a portal account not in admins loses Admin"; pass
! grep -qE '"userId":(1|4),' "$T/calls" || fail_ "the stack's admin and local accounts are never touched"; pass
! grep -q '^GET /api/users ' "$T/calls" && grep -q '^GET /api/users?includePending=true' "$T/calls" \
    || fail_ "people made through the portal are unconfirmed: listed only with includePending"; pass
# the stack's admin with a claimable email: a warning that says why and how
printf 'KAVITA_ADMIN_USER=mediastack\n' > "$ENV_FILE"
jq -c '.[0].email = "me@home.lan"' <<<"$KAV_USERS" > "$T/kav-users"
[[ "$(kav_admin_email_check tok 2>&1)" == *"me@home.lan"*"anyone who signs up with it becomes this admin"*".invalid"* ]] || fail_ "a claimable admin email is warned about"; pass
echo "$KAV_USERS" > "$T/kav-users"
[[ -z "$(kav_admin_email_check tok 2>&1)" ]] || fail_ "an .invalid admin email: nothing to say"; pass
# doctor: who among the portal's people lacks a library — reported, never changed
kav_api() { case "$1 $2" in
        "GET /api/admin/exists") echo true ;;
        "POST /api/account/login") echo '{"token":"K"}' ;;
        "GET /api/library/libraries") echo '[{"id":1,"name":"Books"},{"id":2,"name":"Comics"}]' ;;
        "GET /api/users?includePending=true") echo "$KAV_USERS" ;;
    esac; }
printf 'KAVITA_ADMIN_USER=mediastack\nKAVITA_ADMIN_PASSWORD=p\n' > "$ENV_FILE"
out=$(kavita_doctor 2>&1)
[[ "$out" != *WARN* && "$out" != *FAIL* ]] \
    || fail_ "doctor: akadmin has every library and test-thio is an admin (sees all) — no gap: $out"; pass
KAV_USERS=$(jq -c '.[2].roles = ["Login"]' <<<"$KAV_USERS")
[[ "$(kavita_doctor 2>&1)" == *"test-thio: Comics — not granted (fine if on purpose"* ]] || fail_ "doctor names the person and the missing library, and how to grant it"; pass
# set-credentials kavita: changed with the old password, stored, proven
printf 'KAVITA_ADMIN_USER=mediastack\nKAVITA_ADMIN_PASSWORD=OLDK\n' > "$ENV_FILE"; echo OLDK > "$T/kav-pw"
kav_api() { echo "$1 $2 ${4:-}" >> "$T/calls"
    case "$1 $2" in
        "POST /api/account/login") [[ "$(jq -r .password <<<"$4")" == "$(cat "$T/kav-pw")" ]] || return 1; echo '{"token":"K"}' ;;
        "POST /api/account/reset-password") jq -r .password <<<"$4" > "$T/kav-pw"; echo '{}' ;;
    esac; }
rm -f "$T/calls"
( sc_rotate_kavita NEWK >/dev/null ) || fail_ "set-credentials kavita failed"
grep -q '^POST /api/account/reset-password {"userName":"mediastack","oldPassword":"OLDK","password":"NEWK"}' "$T/calls" \
    && [[ "$(env_get KAVITA_ADMIN_PASSWORD)" == NEWK && "$(grep -c '^POST /api/account/login' "$T/calls")" == 2 ]] \
    || fail_ "Kavita's admin password: changed with the old one, stored, verified by signing in"; pass

# ---- link-account: existing local accounts become portal accounts ----
printf 'JELLYFIN_ADMIN_USER=mediastack\nKAVITA_ADMIN_USER=mediastack\n' > "$ENV_FILE"
JU='[{"Name":"mediastack","Id":"s","Policy":{"AuthenticationProviderId":"Jellyfin.Server.Implementations.Users.DefaultAuthenticationProvider","IsAdministrator":true}},
     {"Name":"Bob","Id":"b","Policy":{"AuthenticationProviderId":"Jellyfin.Server.Implementations.Users.DefaultAuthenticationProvider","IsAdministrator":true}},
     {"Name":"test-thio","Id":"t","Policy":{"AuthenticationProviderId":"'"$JF_LDAP_PROVIDER"'","IsAdministrator":false}}]'
[[ "$(link_jf_candidates "$JU" | jq -c '[.[].name]')" == '["Bob"]' ]] || fail_ "jellyfin: only local accounts are offered, never the stack's admin or a portal account"; pass
[[ "$(link_jf_conflict "$JU" '{"id":"b"}' TEST-THIO)" == test-thio && -z "$(link_jf_conflict "$JU" '{"id":"b"}' bob)" ]] \
    || fail_ "jellyfin: another account already named like the portal user is a conflict (names are case-insensitive); the chosen one is not"; pass
# the picker: the account named like the person is the default, 0 leaves the app alone
link_pick jellyfin "$(link_jf_candidates "$JU")" bob <<<"" >/dev/null; [[ "$(jq -r .id <<<"$LINK_PICK")" == b ]] || fail_ "the same name (any case) is the default choice"; pass
link_pick jellyfin "$(link_jf_candidates "$JU")" robert <<<"" >/dev/null; [[ -z "$LINK_PICK" ]] || fail_ "no same-named account: the default is none"; pass
# jellyfin: renamed, then its login method becomes the plugin's — the same user
echo '{"Name":"Bob","Id":"b","Configuration":{"x":1},"Policy":{"AuthenticationProviderId":"D","PasswordResetProviderId":"DR","IsAdministrator":true}}' > "$T/jf-b"
jf_code() { echo 204; }
jf_api() { echo "$1 $2 ${4:-}" >> "$T/calls"
    case "$1 $2" in
        "GET /Users/b") cat "$T/jf-b" ;;
        "POST /Users?userId=b") jq -c --argjson b "$4" '.Name = $b.Name' "$T/jf-b" > "$T/jf-b.n" && mv "$T/jf-b.n" "$T/jf-b" ;;
        "POST /Users/b/Policy") jq -c --argjson p "$4" '.Policy = $p' "$T/jf-b" > "$T/jf-b.n" && mv "$T/jf-b.n" "$T/jf-b" ;;
    esac; }
rm -f "$T/calls"
link_jf_do tok '{"id":"b","name":"Bob"}' robert >/dev/null || fail_ "jellyfin link failed"
grep -q '^POST /Users?userId=b {"Name":"robert","Id":"b","Configuration":{"x":1}' "$T/calls" || fail_ "jellyfin: renamed, the rest of the account sent back as it was"; pass
[[ "$(jq -c '.Policy | [.AuthenticationProviderId, .PasswordResetProviderId, .IsAdministrator]' "$T/jf-b")" == "[\"$JF_LDAP_PROVIDER\",\"$JF_LDAP_PROVIDER\",true]" ]] \
    || fail_ "jellyfin: its login method and password reset become the LDAP plugin's (then the plugin adopts it by name); nothing else in the policy changes"; pass
# kavita: local accounts only; a name or email collision is refused
KU='[{"id":1,"username":"mediastack","email":"m@x.invalid","identityProvider":0,"roles":["Admin"],"libraries":[],"ageRestriction":null},
     {"id":5,"username":"bob","email":"bob@home.lan","identityProvider":0,"roles":["Login","Bookmark"],"libraries":[{"id":1},{"id":3}],"ageRestriction":{"ageRating":4,"includeUnknowns":false}},
     {"id":6,"username":"test-thio","email":"t@b.c","identityProvider":1,"roles":["Login"],"libraries":[],"ageRestriction":null}]'
[[ "$(link_kav_candidates "$KU" | jq -c '[.[].name]')" == '["bob"]' ]] || fail_ "kavita: only local accounts, never the stack's admin"; pass
[[ "$(link_kav_conflict "$KU" '{"id":5}' robert T@B.C)" == *"test-thio already has t@b.c"* && -z "$(link_kav_conflict "$KU" '{"id":5}' robert r@b.c)" ]] \
    || fail_ "kavita: the portal email on another account is refused (it would link that one)"; pass
echo "$KU" > "$T/kav-users"
kav_api() { echo "$1 $2 ${4:-}" >> "$T/calls"
    case "$1 $2" in
        "GET /api/users?includePending=true") cat "$T/kav-users" ;;
        "POST /api/account/update") jq -c --argjson b "$4" 'map(if .id == $b.userId then .username = $b.username | .email = $b.email | .identityProvider = $b.identityProvider else . end)' "$T/kav-users" > "$T/kav-users.n" && mv "$T/kav-users.n" "$T/kav-users" ;;
        *) echo '{}' ;;
    esac; }
rm -f "$T/calls"
link_kav_do tok '{"id":5,"name":"bob"}' robert Robert@Home.lan >/dev/null || fail_ "kavita link failed"
grep -q '^POST /api/account/update {"userId":5,"username":"robert","email":"Robert@Home.lan","identityProvider":1,"roles":\["Login","Bookmark"\],"libraries":\[1,3\],"ageRestriction":{"ageRating":4,"includeUnknowns":false}}$' "$T/calls" \
    || fail_ "kavita: renamed, the portal email, marked a portal account — roles, libraries and age rating exactly as they were"; pass
grep -q '^POST /api/account/reset-password {"userName":"robert","password":"[A-Za-z0-9]\{24\}"}$' "$T/calls" || fail_ "kavita: its own password replaced with a random one"; pass
# audiobookshelf: the window is refused while any other unlinked account could be claimed
AU='{"users":[{"id":"r","username":"mediastack","type":"root","hasOpenIDLink":false},
             {"id":"b","username":"bob","type":"user","hasOpenIDLink":false},
             {"id":"c","username":"Carol","type":"user","hasOpenIDLink":false},
             {"id":"t","username":"test-thio","type":"user","hasOpenIDLink":true}]}'
[[ "$(link_abs_candidates "$AU" | jq -c '[.[].name]')" == '["bob","Carol"]' ]] || fail_ "audiobookshelf: unlinked accounts, never root"; pass
[[ -z "$(link_abs_conflict "$AU" '{"id":"b"}' robert '["robert","test-thio","akadmin"]')" ]] || fail_ "no other account claimable: the window may open"; pass
[[ "$(link_abs_conflict "$AU" '{"id":"b"}' robert '["robert","carol"]')" == *"Carol is unlinked and a portal account has that name"* ]] \
    || fail_ "another unlinked account a portal name matches (any case) refuses the window"; pass
[[ "$(link_abs_conflict "$AU" '{"id":"b"}' robert '["robert","MediaStack"]')" == *"mediastack is unlinked"* ]] || fail_ "root is covered too"; pass
# audiobookshelf: renamed, own password replaced, matching on, linked at their sign-in, matching off
echo "$AU" > "$T/abs-users"; echo '{"authOpenIDMatchExistingBy":null}' > "$T/abs-auth"; echo 0 > "$T/abs-polls"
abs_api() { echo "$1 $2 ${4:-}" >> "$T/calls"
    case "$1 $2" in
        "GET /api/users") echo $(( $(cat "$T/abs-polls") + 1 )) > "$T/abs-polls"   # a file: each call runs in a subshell
                          [[ "$(cat "$T/abs-polls")" -ge 2 && "$(jq -r .authOpenIDMatchExistingBy "$T/abs-auth")" == username ]] \
                             && jq -c '.users |= map(if .id == "b" then .hasOpenIDLink = true else . end)' "$T/abs-users" > "$T/abs-users.n" && mv "$T/abs-users.n" "$T/abs-users"
                          cat "$T/abs-users" ;;
        "PATCH /api/auth-settings") jq -c --argjson b "$4" '. + $b' "$T/abs-auth" > "$T/abs-auth.n" && mv "$T/abs-auth.n" "$T/abs-auth" ;;
        "GET /api/auth-settings") cat "$T/abs-auth" ;;
        *) echo '{}' ;;
    esac; }
sleep() { :; }
rm -f "$T/calls"
link_abs_do tok '{"id":"b","name":"bob"}' robert >/dev/null || fail_ "audiobookshelf link failed"
grep -q '^PATCH /api/users/b {"username":"robert"}' "$T/calls" && grep -q '^PATCH /api/users/b {"password":"[A-Za-z0-9]\{24\}"}' "$T/calls" \
    || fail_ "audiobookshelf: renamed, its own password replaced"; pass
[[ "$(grep '^PATCH /api/auth-settings' "$T/calls" | sed 's/.* //' | tr '\n' ' ')" == '{"authOpenIDMatchExistingBy":"username"} {"authOpenIDMatchExistingBy":null} ' \
   && "$(jq -r .authOpenIDMatchExistingBy "$T/abs-auth")" == null ]] \
    || fail_ "audiobookshelf: matching opens for the sign-in and is off again once linked"; pass
# nobody signs in: the window still closes, and it says what to do
echo "$AU" > "$T/abs-users"; echo -1000 > "$T/abs-polls"; LINK_ABS_WAIT=10; rm -f "$T/calls"
out=$(link_abs_do tok '{"id":"b","name":"bob"}' robert 2>&1) && fail_ "no sign-in must fail"
[[ "$out" == *"did not sign in within"*"run link-account again"* && "$(jq -r .authOpenIDMatchExistingBy "$T/abs-auth")" == null ]] \
    || fail_ "audiobookshelf: on a timeout the window closes too: $out"; pass
LINK_ABS_WAIT=600; unset -f sleep
[[ "$(trap -p EXIT)" == *'rm -rf'* ]] || fail_ "the window's safety net never touches the caller's traps (here: this test's clean-up)"; pass

# ---- the portal's admin, and a locked-out person's way back ----
printf 'AUTHENTIK_ADMIN_PASSWORD=OLDAK\nSTACK_DOMAIN=media.example.com\n' > "$ENV_FILE"
AK_TYPE=internal; AK_ACTIVE=true
ak_api() { echo "$1 $2 ${3:-}" >> "$T/calls"
    case "$1 $2" in
        "GET /core/users/?username=akadmin") echo '{"results":[{"pk":7,"username":"akadmin"}]}' ;;
        "GET /core/users/?username=jo%20ann") echo "{\"results\":[{\"pk\":9,\"username\":\"jo ann\",\"type\":\"$AK_TYPE\",\"is_active\":$AK_ACTIVE}]}" ;;
        "GET /core/users/?username=nobody") echo '{"results":[]}' ;;
        "GET /policies/reputation/scores/?identifier=jo%20ann&page_size=100") echo '{"results":[{"pk":"a1"},{"pk":"b2"}]}' ;;
        *) echo '{}' ;;
    esac; }
sudo() { echo "SUDO $*" >> "$T/calls"
    echo "Store this link safely, as it will allow anyone to access authentik as jo ann."
    echo "This recovery token is valid for 1 day."
    echo "/recovery/use-token/KEY123/"; }
svc_cname() { echo "ms-$1"; }
rm -f "$T/calls"
authentik_admin_rotate NEWAK >/dev/null && grep -q '^POST /core/users/7/set_password/ {"password":"NEWAK"}' "$T/calls" \
    && [[ "$(env_get AUTHENTIK_ADMIN_PASSWORD)" == NEWAK ]] \
    || fail_ "akadmin's password is set through authentik's API, then stored (the bootstrap value is read only once)"; pass
# set-credentials portal leaves no pending change: the worker (which carries the value) is recreated
rm -f "$T/calls"
( svc_enabled() { [[ "$1" == authentik ]]; }; c_health() { echo healthy; }; DC() { echo "DC $*" >> "$T/calls"; }
  sc_rotate_portal NEWER >/dev/null ) || fail_ "set-credentials portal failed"
grep -q '^DC up -d --no-deps authentik-worker$' "$T/calls" || fail_ "set-credentials portal recreates the worker (found live: 'up' reported it pending)"; pass
rm -f "$T/calls"
out=$(authentik_recover "jo ann" 2>&1)
grep -q '^DELETE /policies/reputation/scores/a1/' "$T/calls" && grep -q '^DELETE /policies/reputation/scores/b2/' "$T/calls" \
    || fail_ "every login-throttle entry for the user is cleared"; pass
grep -q '^SUDO docker exec -e USER=mediastack ms-authentik-worker ak create_recovery_key 1440 jo ann$' "$T/calls" \
    && [[ "$out" == *"https://portal.media.example.com/recovery/use-token/KEY123/"*"Works once, for 24 hours"*"Change password"* ]] \
    || fail_ "a single-use, 24-hour sign-in link on the portal's address, with what to do next: $out"; pass
# a failed command: the error line, not authentik's config logging ahead of it
sudo() { echo '{"event": "Loaded config", "level": "debug", "logger": "authentik.lib.config"}'
    echo '  File "/usr/local/lib/python3.14/getpass.py", line 239, in getuser'
    echo "OSError: No username set in the environment"; return 1; }
out=$( (authentik_recover "jo ann") 2>&1) && fail_ "a failed command must fail"
[[ "$out" == *"could not make a sign-in link: OSError: No username set in the environment"* && "$out" != *"Loaded config"* ]] \
    || fail_ "a failed command reports its error line, not its logging: $out"; pass
for who in akadmin mediastack-ldap-search nobody; do
    rm -f "$T/calls"
    out=$( (authentik_recover "$who") 2>&1) && fail_ "$who: must be refused"
    ! grep -q 'create_recovery_key' "$T/calls" 2>/dev/null || fail_ "$who: no link minted"
done
[[ "$( (authentik_recover akadmin) 2>&1)" == *"set-credentials portal"* ]] || fail_ "akadmin is pointed at set-credentials portal"; pass
AK_TYPE=service_account; out=$( (authentik_recover "jo ann") 2>&1) && fail_ "a service account is refused"
[[ "$out" == *"not a person's"* ]] || fail_ "a service account: says why"; pass
AK_TYPE=internal; AK_ACTIVE=false; rm -f "$T/calls"; out=$( (authentik_recover "jo ann") 2>&1) && fail_ "a deactivated account is refused"
[[ "$out" == *"deactivated"* ]] && ! grep -q '^DELETE' "$T/calls" || fail_ "a deactivated account: deliberate, not a lockout — nothing cleared, no link"; pass

# the blueprint's OIDC provider for it
sed -n '/name: mediastack-oidc-audiobookshelf/,/^  - model/p' services/authentik/blueprints/mediastack-portal.yaml > "$T/abs"
grep -q 'client_id: mediastack-audiobookshelf' "$T/abs" && grep -q 'signing_key: !Find' "$T/abs" \
   && grep -q '/auth/openid/callback' "$T/abs" && grep -q '/auth/openid/mobile-redirect' "$T/abs" \
    || fail_ "the OIDC provider: its client ID, a signing key (RS256), web and app redirects"; pass
grep -q 'grant_types: \[authorization_code, refresh_token\]' "$T/abs" || fail_ "the provider allows the code grant (empty by default: every login refused, found live)"; pass

# ---- configure: the account model is a question of its own ----
acc() { # acc PROFILES ANSWERS -> the wizard's output, then "P=<COMPOSE_PROFILES>" and "SAME" when .env is byte-identical
    ( ENV_FILE=$T/acc.env; printf 'COMPOSE_PROFILES=%s\nPORTAL_TITLE=Mediastack\n' "$1" > "$ENV_FILE"; cp "$ENV_FILE" "$T/acc.before"
      render() { :; }; svc_managed() { printf '%s\n' gluetun jellyfin sonarr wizarr authentik; }
      svc_managed_where() { [[ "$1 $2" == "mediastack.preset standard" ]] && printf '%s\n' gluetun jellyfin sonarr; return 0; }
      svc_label() { [[ "$2" == mediastack.desc ]] && echo "desc"; return 0; }; conflicts_in() { [[ " $* " == *" authentik "* && " $* " == *" wizarr "* ]] && echo "authentik wizarr" || true; }
      resolve_deps() { local x; for x in "$@"; do echo "$x"; [[ "$x" == wizarr ]] && echo jellyfin; done | awk '!seen[$0]++'; }
      hr() { echo "== $*"; }; ok() { echo "OK $*"; }; info() { echo ":: $*"; }; warn() { echo "WARN $*"; }; fail() { echo "FAIL $*"; }
      printf '%b' "$2" | _configure_services 2>&1
      echo "P=$(env_get COMPOSE_PROFILES)"; cmp -s "$ENV_FILE" "$T/acc.before" && echo SAME || true )
}
has() { [[ ",$(sed -n 's/^P=//p' <<<"$1")," == *",$2,"* ]]; }
out=$(acc "" '1\n\n'); has "$out" wizarr || has "$out" authentik && fail_ "first run, standard, Enter: none — neither runs: $out"
[[ "$out" == *"== Accounts"*"1) none"*"2) Wizarr"*"3) authentik"*"OK Accounts: none"* && "$out" != *"0) keep current"* ]] || fail_ "the question, with none as the first run's default: $out"; pass
[[ "$out" == *"2) everything  every service (sign-in is picked next)"* ]] || fail_ "'everything' states no count (it would count both account models): $out"; pass
out=$(acc "" '2\n3\n'); has "$out" authentik && ! has "$out" wizarr && [[ "$out" != *"Choose one"* && "$out" != *"portal's name"* ]] \
    || fail_ "everything + authentik: no either/or prompt; its name is the portal's own question (authentik_questions): $out"; pass
out=$(acc "" '2\n2\n'); has "$out" wizarr && ! has "$out" authentik && has "$out" jellyfin || fail_ "everything + Wizarr (Jellyfin with it): $out"; pass
out=$(acc "" '2\n1\n'); ! has "$out" wizarr && ! has "$out" authentik || fail_ "everything + none: neither: $out"; pass
out=$(acc "" '3\ny\ny\ny\n3\n\n'); [[ "$out" != *"wizarr — "* && "$out" != *"authentik — "* ]] && has "$out" authentik && has "$out" sonarr \
    || fail_ "custom: no yes/no for the two models — the Accounts question decides: $out"; pass
out=$(acc "sonarr,authentik,jellyfin" '\n\n'); [[ "$out" == *"0) keep current: authentik"*"Keeping the current 3 service(s)"*SAME ]] \
    || fail_ "a re-run keeping services and model: .env byte-identical: $out"; pass
out=$(acc "sonarr,authentik,jellyfin" '0\n1\n'); ! has "$out" authentik && [[ "$out" == *"WARN Leaving the portal"* ]] || fail_ "authentik -> none: out, with the warning: $out"; pass
out=$(acc "sonarr,jellyfin" '0\n3\n\n'); has "$out" authentik && [[ "$out" == *"0) keep current: none"*"link-account"* ]] || fail_ "none -> authentik: in, pointed at link-account: $out"; pass
out=$(acc "sonarr,wizarr,jellyfin" '0\n3\n\n'); has "$out" authentik && ! has "$out" wizarr || fail_ "Wizarr -> authentik: one model, never both: $out"; pass
out=$(acc "" '1\n7\n0\n1\n'); [[ "$out" == *"FAIL Pick 1-3."*"FAIL Nothing to keep."*"OK Accounts: none"* ]] || fail_ "a bad choice, and 0 with nothing to keep, are asked again: $out"; pass

# ---- a person's email is theirs: Kavita (and ROMM) sign people in by it (8 Oct 2026) ----
grep -q 'User.objects.filter(email__iexact=email).exists()' services/authentik/blueprints/mediastack-portal.yaml \
    || fail_ "sign-up refuses an email another account has"; pass
# self-service: email and username stay admin-only
idw() { SET=$1; rm -f "$T/calls"; ak_api() { echo "$1 $2 ${3:-}" >> "$T/calls"; [[ "$1" == GET ]] && echo "$SET"; return 0; }
        WIRE_DRY=0; wire_authentik_identity >/dev/null; grep '^PATCH' "$T/calls" | cut -d' ' -f3- || echo none; }
[[ "$(idw '{"default_user_change_email":true,"default_user_change_username":false}')" == '{"default_user_change_email":false,"default_user_change_username":false}' ]] \
    || fail_ "self-service email change on: wire turns both off"; pass
[[ "$(idw '{"default_user_change_email":false,"default_user_change_username":false}')" == none ]] || fail_ "already off: no write"; pass
# duplicates among people (service accounts and empty emails are not people's)
ak_api() { echo '{"results":[{"username":"ana","type":"internal","email":"Ana@Home.lan"},{"username":"tom","type":"internal","email":"ana@home.lan"},
  {"username":"bo","type":"internal","email":"bo@home.lan"},{"username":"x","type":"internal","email":""},{"username":"y","type":"internal","email":""},
  {"username":"ak-outpost","type":"internal_service_account","email":"bo@home.lan"}]}'; }
[[ "$(authentik_email_dupes)" == "ana@home.lan: ana tom" ]] || fail_ "dupes: case-insensitive, people only, empty ignored: $(authentik_email_dupes)"; pass
# set-email: a shared address warns and needs a decision; --yes overrides; Kavita follows
USERS='{"results":[{"pk":1,"username":"ana","type":"internal","email":"ana@home.lan"},{"pk":2,"username":"tom","type":"internal","email":"tom@home.lan"},
  {"pk":3,"username":"svc","type":"service_account","email":""}]}'
ak_api() { echo "$1 $2 ${3:-}" >> "$T/calls"
    case "$1 $2" in
        "GET /core/users/?username=ana") jq -c '{results:[.results[0]]}' <<<"$USERS" ;;
        "GET /core/users/?username=svc") jq -c '{results:[.results[2]]}' <<<"$USERS" ;;
        "GET /core/users/?username=nobody") echo '{"results":[]}' ;;
        "GET /core/users/?page_size=1000") echo "$USERS" ;;
        "PATCH /core/users/1/") jq -c '{email}' <<<"$3" ;;
    esac; }
authentik_portal() { echo https://portal.example; }; svc_enabled() { [[ "$1" == authentik ]]; }
se() { rm -f "$T/calls"; ( ok() { echo "OK $*"; }; warn() { echo "WARN $*"; }; info() { echo ":: $*"; }; authentik_set_email "$@" ) 2>&1 </dev/null; }
out=$(se ana not-an-email 0) && fail_ "a malformed address must refuse"; [[ "$out" == *"not an email address"* ]] || fail_ "malformed: $out"; pass
out=$(se nobody a@b.c 0) && fail_ "an unknown user must refuse"; pass
out=$(se svc a@b.c 0) && fail_ "a service account is not a person's"; pass
out=$(se ana ANA@home.lan 0); [[ "$out" == *"already has"* ]] && ! grep -q '^PATCH' "$T/calls" || fail_ "the same address (any case): no write: $out"; pass
out=$(se ana new@home.lan 0); [[ "$out" == *"now new@home.lan (was ana@home.lan)"* && "$out" != *WARN* ]] && grep -q '^PATCH /core/users/1/ {"email":"new@home.lan"}' "$T/calls" \
    || fail_ "a free address: changed, no warning: $out"; pass
out=$(se ana Tom@home.lan 0) && fail_ "a shared address without a terminal or --yes must stop"
[[ "$out" == *"already the email of: tom"*"should be their own"*"add --yes"* ]] && ! grep -q '^PATCH' "$T/calls" \
    || fail_ "shared: warned, says why, nothing written: $out"; pass
out=$(se ana Tom@home.lan 1); [[ "$out" == *WARN*"tom"* && "$out" == *"now Tom@home.lan"* ]] && grep -q '^PATCH' "$T/calls" \
    || fail_ "shared with --yes: warned, then the admin's decision stands: $out"; pass
# Kavita follows: the account holding the old email answers to the new one, nothing else changes
echo "$KAV_USERS" > "$T/kav-users"
kav_api() { echo "$1 $2 ${4:-}" >> "$T/calls"
    case "$1 $2" in
        "POST /api/account/login") echo '{"token":"K"}' ;;
        "GET /api/users?includePending=true") cat "$T/kav-users" ;;
        "POST /api/account/update") jq -c --argjson b "$4" 'map(if .id == $b.userId then .email = $b.email else . end)' "$T/kav-users" > "$T/kav-users.n" && mv "$T/kav-users.n" "$T/kav-users"; echo '{}' ;;
    esac; }
printf 'KAVITA_ADMIN_USER=mediastack\nKAVITA_ADMIN_PASSWORD=p\n' > "$ENV_FILE"; rm -f "$T/calls"
ok() { echo "OK $*"; }; info() { echo ":: $*"; }
want=$(kav_account_body "$(jq -c '.[] | select(.id == 3)' "$T/kav-users")" | jq -c '.email = "new@b.c"')
out=$(kav_email_move T@B.C new@b.c 2>&1)
grep -qxF "POST /api/account/update $want" "$T/calls" && [[ "$out" == *"test-thio now answers to new@b.c"* ]] \
    || fail_ "kavita: the matched account (email any case), only its email changed: $out / $(grep update "$T/calls")"; pass
rm -f "$T/calls"; out=$(kav_email_move gone@b.c x@b.c 2>&1)
[[ "$out" == *"nothing to move"* ]] && ! grep -q update "$T/calls" || fail_ "no account with the old email: nothing written: $out"; pass

# ---- password reset by email: the flow, its email, and a link only while email works ----
bp=services/authentik/blueprints/mediastack-portal.yaml
grep -q "^      slug: $AUTHENTIK_RECOVERY_FLOW\$" "$bp" && grep -q 'designation: recovery' <<<"$(sed -n '/slug: mediastack-recovery$/,/^  - /p' "$bp")" \
    || fail_ "the blueprint's recovery flow is AUTHENTIK_RECOVERY_FLOW, designated recovery"; pass
sed -n '/name: mediastack-recovery-identification$/,/^  - /p' "$bp" > "$T/rid"
grep -q 'pretend_user_exists: true' "$T/rid" && grep -q 'show_matched_user: false' "$T/rid" \
    || fail_ "an unknown name gets the same answer: no account revealed"; pass
grep -q 'user_creation_mode: never_create' <<<"$(sed -n '/name: mediastack-recovery-write$/,/^  - /p' "$bp")" || fail_ "a reset never creates an account"; pass
grep -q 'denied_action: continue' <<<"$(sed -n '/slug: mediastack-recovery$/,/^  - /p' "$bp")" \
    || fail_ "someone signed in who opens a reset link lands on the dashboard, not an error (found live)"; pass
sed -n '/name: mediastack-recovery-email$/,/^  - /p' "$bp" > "$T/rem"
grep -q 'activate_user_on_success: false' "$T/rem" || fail_ "a deactivated account stays deactivated"; pass
tpl=$(sed -n 's/^ *template: //p' "$T/rem")
[[ -f "services/authentik/templates/$tpl" && -f "services/authentik/templates/${tpl%.html}.txt" ]] \
    || fail_ "the email stage's template ($tpl) and its text part ship in services/authentik/templates/"; pass
grep -q 'evaluate_on_plan: false' <<<"$(sed -n '/id: binding-recovery-login$/,/^  - /p' "$bp")" \
    && grep -q 'policy: !KeyOf policy-recovery-clear-throttle' <<<"$(grep -B1 -A2 'target: !KeyOf binding-recovery-login' "$bp")" \
    && grep -q 'Reputation.objects.filter(identifier=user.username).delete()' <<<"$(sed -n '/name: mediastack-recovery-clear-throttle$/,/^  - /p' "$bp")" \
    || fail_ "the login throttle is cleared at the sign-in, after the new password (as reset-password does)"; pass
# the email: no inline logo (Gmail: a broken image and a file), the name as data
! grep -rq 'cid:' services/authentik/templates/ || fail_ "a template must not use an inline (cid:) image"; pass
! grep -q 'extends' services/authentik/templates/*.html || fail_ "the template is self-contained (authentik's base.html carries the inline logo)"; pass
h=$(authentik_template_render services/authentik/templates/mediastack-password-reset.html 'Tom & Jerry "<b>" {{ x }}')
[[ "$h" == *'Tom &amp; Jerry &quot;&lt;b&gt;&quot; &#123;&#123; x &#125;&#125;'* && "$h" != *@@PORTAL_TITLE@@* ]] \
    || fail_ "html: the name escaped, braces never template code"; pass
[[ "$(authentik_template_render services/authentik/templates/mediastack-password-reset.html X | sha256sum)" == \
   "$(authentik_template_render services/authentik/templates/mediastack-password-reset.html X | sha256sum)" ]] || fail_ "rendering is byte-stable"; pass
t=$(authentik_template_render services/authentik/templates/mediastack-password-reset.txt 'A {% b %}')
[[ "$t" == *'A {% templatetag openbrace %}% b %{% templatetag closebrace %}'* ]] || fail_ "txt: braces reach Django as literals: $t"; pass
grep -q '{% autoescape off %}' services/authentik/templates/mediastack-password-reset.txt || fail_ "txt: no HTML escaping in plain text (a link's & stays &)"; pass
grep -q -- '- ${CONFIG_ROOT}/authentik/templates:/templates' "$T/worker" || fail_ "the worker mounts the templates"; pass
# the sync: rendered in, unchanged files untouched, ours that left removed, yours kept, a change restarts
( ENV_FILE=$T/tenv; printf 'CONFIG_ROOT=%s/cfg\nAUTHENTIK_UID=1000\nPORTAL_TITLE=Our Place\n' "$T" > "$ENV_FILE"
  sudo() { if [[ "$1 $2" == "docker restart" ]]; then echo "RESTART $3" >> "$T/tcalls"; return 0; fi
           if [[ "$1" == install ]]; then local a=() x; for x in "$@"; do [[ "$x" == -o || "$x" == -g || "$x" == 1000 || "$x" == mediacenter ]] || a+=("$x"); done; "${a[@]}"; return; fi
           "$@"; }
  c_state() { echo running; }; svc_cname() { echo "c-$1"; }; info() { echo ":: $*"; }
  rm -f "$T/tcalls"; authentik_templates_sync > "$T/tout"
  grep -q 'Our Place' "$T/cfg/authentik/templates/mediastack-password-reset.html" && grep -q 'Our Place' "$T/cfg/authentik/templates/mediastack-password-reset.txt" \
      || fail_ "sync: both parts rendered with the portal's name"
  grep -qx 'RESTART c-authentik' "$T/tcalls" && grep -qx 'RESTART c-authentik-worker' "$T/tcalls" || fail_ "sync: a change restarts the server (renders) and the worker (sends)"
  touch "$T/cfg/authentik/templates/my-own.html" "$T/cfg/authentik/templates/mediastack-gone.html"; rm -f "$T/tcalls"
  authentik_templates_sync > "$T/tout"
  [[ ! -e "$T/cfg/authentik/templates/mediastack-gone.html" && -e "$T/cfg/authentik/templates/my-own.html" ]] || fail_ "sync: ours that left removed, yours kept"
  rm -f "$T/tcalls"; authentik_templates_sync > "$T/tout"
  [[ ! -s "$T/tout" && ! -e "$T/tcalls" ]] || fail_ "sync: nothing changed, nothing touched: $(cat "$T/tout")" ) || exit 1; pass
grep -q 'authentik_templates_sync' <(awk '/^authentik_prepare\(\)/,/^}/' services/authentik/authentik.sh) || fail_ "the templates sync before authentik starts"; pass
# the link: only while email works, never over a flow set in authentik's UI
rec() { # rec READY SIGNIN BRAND [DRY] -> the PATCH calls made
    ( printf 'SMTP_HOST=smtp.example.com\nSMTP_PORT=587\nSMTP_FROM=a@example.com\n' > "$T/renv"; ENV_FILE=$T/renv
      if [[ "$1" == yes ]]; then echo "$(smtp_fingerprint)" > "$T/st-SMTP_TESTED"; else rm -f "$T/st-SMTP_TESTED"; fi
      state_get() { cat "$T/st-$1" 2>/dev/null || true; }
      SIGNIN=$2; BRAND=$3; WIRE_DRY=${4:-0}; rm -f "$T/calls"
      ak_api() { echo "$1 $2 ${3:-}" >> "$T/calls"
          case "$1 $2" in
              "GET /flows/instances/?slug=mediastack-recovery") echo '{"results":[{"pk":"F-OURS"}]}' ;;
              "GET /stages/identification/?name=default-authentication-identification")
                  jq -cn --arg c "$SIGNIN" '{results:[{pk:"S1", name:"default-authentication-identification", user_fields:["username","email"], sources:[], recovery_flow:(if $c == "" then null else $c end)}]}' ;;
              "GET /core/brands/?domain=authentik-default") jq -cn --arg c "$BRAND" '{results:[{brand_uuid:"B1", flow_recovery:(if $c == "" then null else $c end)}]}' ;;
              "PATCH /stages/identification/S1/")
                  # authentik 2026.8: an update without user_fields or sources is refused (found live)
                  if [[ -n "${REFUSE:-}" ]] || ! jq -e '(.user_fields | length) > 0 or (.sources | length) > 0' <<<"$3" >/dev/null 2>&1; then
                      echo '{"non_field_errors":["When no user fields are selected, at least one source must be selected"]}'; return 1; fi
                  echo '{}' ;;
              PATCH*) echo '{}' ;;
          esac; }
      wire_authentik_recovery > "$T/rout"; grep '^PATCH' "$T/calls" || true )
}
[[ "$(rec yes "" "")" == $'PATCH /stages/identification/S1/ {"user_fields":["username","email"],"sources":[],"recovery_flow":"F-OURS"}\nPATCH /core/brands/B1/ {"flow_recovery":"F-OURS"}' ]] \
    || fail_ "email tested: the sign-in page (its user_fields and sources sent back as they are) and the brand link the reset flow: $(rec yes "" "")"; pass
grep -q 'Forgot password' "$T/rout" && ! grep -q '^FAIL' "$T/rout" || fail_ "linked: says so, no failure"; pass
REFUSE=1 rec yes "" "" >/dev/null
grep -q 'FAIL authentik rejected the password-reset link on the sign-in-page: {"non_field_errors":\["When no user fields' "$T/rout" \
    && ! grep -q 'Forgot password?\" on the sign-in page' "$T/rout" \
    || fail_ "a refused write names authentik's answer and never reports the link as set: $(cat "$T/rout")"; pass
[[ -z "$(rec yes F-OURS F-OURS)" ]] || fail_ "already linked: no write"; pass
[[ "$(rec no F-OURS F-OURS)" == $'PATCH /stages/identification/S1/ {"user_fields":["username","email"],"sources":[],"recovery_flow":null}\nPATCH /core/brands/B1/ {"flow_recovery":null}' ]] \
    || fail_ "email untested (or gone): the link comes off — never a dead link"; pass
[[ -z "$(rec no "" "")" ]] || fail_ "no email, no link: nothing to do"; pass
[[ -z "$(rec yes F-THEIRS F-THEIRS)" && -z "$(rec no F-THEIRS F-THEIRS)" ]] || fail_ "a recovery flow set in authentik's UI is never touched"; pass
[[ -z "$(rec yes "" "" 1)" ]] || fail_ "a dry run writes nothing"; pass
grep -q 'wire_authentik_recovery' <(awk '/^wire_authentik\(\)/,/^}/' services/authentik/authentik.sh) || fail_ "wire authentik sets the link"; pass
grep -q 'authentik_recovery_refresh' <(awk '/^cmd_email\(\)/,/^}/' services/authentik/email.sh) \
    && [[ "$(awk '/^authentik_configure_email\(\)/,/^}/' services/authentik/email.sh | grep -cw 'email_changed')" == 2 ]] \
    && grep -q '^email_changed() { state_set "$EMAIL_STATE" yes; }' services/authentik/email.sh \
    && ! grep -q authentik_recovery_refresh <<<"$(awk '/^authentik_configure_email\(\)/,/^}/' services/authentik/email.sh)" \
    && grep -q 'state_get "$EMAIL_STATE".*authentik_recovery_refresh' <<<"$(awk '/^cmd_configure\(\)/,/^}/' lib/configure.sh)" \
    || fail_ "a passed test shows the link at once; removing or changing email takes it off at once"; pass
# ---- invite --email: the portal sends the link, in mediastack's template ----
grep -q '{% autoescape off %}' services/authentik/templates/mediastack-invitation.txt || fail_ "invitation txt: no HTML escaping in plain text"; pass
( printf 'AUTHENTIK_HOST=portal\nSTACK_DOMAIN=media.example.com\nAUTHENTIK_API_TOKEN=TOK\n' > "$T/ienv"; ENV_FILE=$T/ienv
  authentik_url() { echo http://127.0.0.1:9000; }; authentik_portal() { echo https://portal.media.example.com; }
  curl() { printf '%s\n' "$@" > "$T/curl"; printf '\n%s' "${CURL_CODE:-204}"; }
  CURL_CODE=204 out=$(authentik_invite_email inv-1 milo@example.com 2>&1) || fail_ "a 204 is a send: $out"
  grep -qx 'Host: portal.media.example.com' "$T/curl" && grep -qx 'X-Forwarded-Proto: https' "$T/curl" \
      || fail_ "asked as the portal over https (authentik builds the link from the request's address)"
  grep -qx 'http://127.0.0.1:9000/api/v3/stages/invitation/invitations/inv-1/send_email/' "$T/curl" \
      && grep -qxF '{"email_addresses":["milo@example.com"],"template":"mediastack-invitation.html"}' "$T/curl" \
      || fail_ "authentik's send endpoint, one address, mediastack's template: $(cat "$T/curl")"
  [[ "$out" == *"Emailed to milo@example.com"* ]] || fail_ "says it was handed over: $out"
  out=$( (CURL_CODE=500; authentik_invite_email inv-1 milo@example.com) 2>&1) && fail_ "a refusal must stop"
  [[ "$out" == *"refused to email the invitation [HTTP 500]"*"the link above works"* ]] || fail_ "a refusal says so, and that the printed link still works: $out" ) || exit 1; pass
[[ -f services/authentik/templates/mediastack-invitation.html && -f services/authentik/templates/mediastack-invitation.txt ]] || fail_ "the invitation template and its text part ship"; pass
# the verb: --email needs tested email, checked before anything is minted; Wizarr cannot send
inv() { ( load_env() { :; }; render() { :; }; svc_enabled() { [[ " $SVCS " == *" $1 "* ]]; }
          authentik_email_ready() { [[ "$READY" == yes ]]; }; authentik_invite() { echo "MINT $*"; }
          cmd_invite "$@" ) 2>&1; }
SVCS=authentik READY=no; out=$(inv --email milo@example.com) && fail_ "--email without tested email must stop"
[[ "$out" == *"needs the portal's email working"* && "$out" != *MINT* ]] || fail_ "--email without tested email: refused before minting: $out"; pass
READY=yes; [[ "$(inv --expires 30 --email milo@example.com)" == "MINT 30 milo@example.com" ]] || fail_ "--email with tested email: minted and sent"; pass
[[ "$(inv)" == "MINT 7 " ]] || fail_ "no --email: the link only, as before"; pass
out=$(inv --email not-an-address) && fail_ "a bad address must stop"; [[ "$out" == *"is not an email address"* ]] || fail_ "a bad address says so: $out"; pass
SVCS=wizarr; out=$(inv --email milo@example.com) && fail_ "Wizarr cannot send"; [[ "$out" == *"needs the portal (authentik)"* ]] || fail_ "Wizarr + --email says why: $out"; pass

# the sign-in page's show-password button: set once, never over "off" in authentik's UI
showpw() { # showpw CURRENT SEEDED -> the PATCH calls made, then the state
    ( state_get() { cat "$T/st-$1" 2>/dev/null || true; }; state_set() { echo "$2" > "$T/st-$1"; }
      if [[ -n "$2" ]]; then echo 1 > "$T/st-AUTHENTIK_SHOW_PASSWORD"; else rm -f "$T/st-AUTHENTIK_SHOW_PASSWORD"; fi
      CUR=$1; WIRE_DRY=0; rm -f "$T/calls" "$T/late"
      ak_api() { echo "$1 $2 ${3:-}" >> "$T/calls"; [[ "$1" != PATCH ]] || echo "${API_TIMEOUT:-20}" > "$T/patch-wait"
          case "$1 $2" in
              "GET /stages/password/?name=default-authentication-password") [[ -e "$T/late" ]] && CUR=$(cat "$T/late")
                  jq -cn --argjson c "$CUR" '{results:[{pk:"P1", name:"default-authentication-password", allow_show_password:$c}]}' ;;
              PATCH*) if [[ -n "${PATCH_LATE:-}" ]]; then echo "$PATCH_LATE" > "$T/late"; echo "no answer within 90s"; return 1; fi; echo '{}' ;;
          esac; }
      wfail() { echo "WFAIL $*" >> "$T/calls"; }
      wire_authentik_show_password >/dev/null; grep -E '^(PATCH|WFAIL)' "$T/calls" || true; echo "seeded=$(state_get AUTHENTIK_SHOW_PASSWORD)" )
}
[[ "$(showpw false "")" == $'PATCH /stages/password/P1/ {"allow_show_password":true}\nseeded=1' ]] || fail_ "show password: set once, remembered: $(showpw false "")"; pass
[[ "$(showpw false 1)" == "seeded=1" ]] || fail_ "show password: turned off in authentik's UI after we set it — never set again"; pass
[[ "$(showpw true "")" == "seeded=1" ]] || fail_ "show password: already on — no write, remembered (so a later 'off' stays off)"; pass
# the write timed out: unknown, so read back (found live Nov 2026: made, but reported "rejected")
[[ "$(PATCH_LATE=true showpw false "")" == $'PATCH /stages/password/P1/ {"allow_show_password":true}\nseeded=1' ]] \
    || fail_ "show password: no answer, read back as made — no failure, remembered: $(PATCH_LATE=true showpw false "")"; pass
[[ "$(PATCH_LATE=false showpw false "")" == *"WFAIL authentik did not take the show-password button: no answer within 90s"*"seeded=" ]] \
    || fail_ "show password: no answer, read back as not made — a failure, not called rejected: $(PATCH_LATE=false showpw false "")"; pass
grep -q 'wire_authentik_show_password' <(awk '/^wire_authentik\(\)/,/^}/' services/authentik/authentik.sh) || fail_ "wire authentik sets the show-password button"; pass
# the portal's website refuses app passwords (docs/design-access.md, decision 1; found live 15 Nov 2026: a TV's app password signed into the website)
webtok() { # webtok BACKENDS-JSON|none|unreadable [DRY] -> the PATCH bodies sent, WFAIL lines, then the step's backends after
    ( echo "$1" > "$T/wt-cur"; rm -f "$T/calls"; WIRE_DRY=${2:-0}
      ak_api() { echo "$1 $2 ${3:-}" >> "$T/calls"
          case "$1 $2" in
              "GET /stages/password/?name=default-authentication-password")
                  case "$(cat "$T/wt-cur")" in
                      none) echo '{"results":[{"pk":"OTHER","name":"someone-elses","backends":[]}]}' ;;
                      unreadable) echo "connection refused"; return 1 ;;
                      *) jq -cn --argjson b "$(cat "$T/wt-cur")" '{results:[{pk:"P1", name:"default-authentication-password", backends:$b}]}' ;;
                  esac ;;
              "PATCH /stages/password/P1/")
                  [[ -n "${PATCH_DROP:-}" ]] && { echo "no answer within 90s"; return 1; }
                  jq -c '.backends' <<<"$3" > "$T/wt-cur"
                  [[ -n "${PATCH_LATE:-}" ]] && { echo "no answer within 90s"; return 1; }
                  echo '{}' ;;
          esac; }
      wfail() { echo "WFAIL $*" >> "$T/calls"; }
      wire_authentik_web_tokens >/dev/null 2>&1
      { grep -E '^(PATCH|WFAIL)' "$T/calls" || true; } | sed 's#^PATCH /stages/password/P1/ #PATCH #'
      echo "after=$(cat "$T/wt-cur")" )
}
WT='["authentik.core.auth.InbuiltBackend","authentik.sources.kerberos.auth.KerberosBackend","authentik.sources.ldap.auth.LDAPBackend","authentik.core.auth.TokenBackend"]'
WN='["authentik.core.auth.InbuiltBackend","authentik.sources.kerberos.auth.KerberosBackend","authentik.sources.ldap.auth.LDAPBackend"]'
[[ "$(webtok "$WT")" == "PATCH {\"backends\":$WN}"$'\n'"after=$WN" ]] || fail_ "web sign-in with TokenBackend: only it removed, the rest kept in order: $(webtok "$WT")"; pass
[[ "$(webtok "$WN")" == "after=$WN" ]] || fail_ "web sign-in already refusing app passwords: nothing written"; pass
[[ "$(webtok none)" == "after=none" ]] || fail_ "no sign-in password step of authentik's own: said, nothing written, no failure"; pass
[[ "$(webtok unreadable)" == "WFAIL "*"unreadable"*"after=unreadable" ]] || fail_ "the step unreadable: a failure, never assumed fine: $(webtok unreadable)"; pass
[[ "$(webtok "$WT" 1)" == "after=$WT" ]] || fail_ "a dry run writes nothing"; pass
[[ "$(PATCH_LATE=1 webtok "$WT")" == "PATCH {\"backends\":$WN}"$'\n'"after=$WN" ]] || fail_ "no answer, read back as made: no failure: $(PATCH_LATE=1 webtok "$WT")"; pass
[[ "$(PATCH_DROP=1 webtok "$WT")" == *"WFAIL authentik did not stop its website taking app passwords: no answer within 90s"*"after=$WT" ]] \
    || fail_ "no answer, read back as not made: a failure: $(PATCH_DROP=1 webtok "$WT")"; pass
grep -q 'wire_authentik_web_tokens' <(awk '/^wire_authentik\(\)/,/^}/' services/authentik/authentik.sh) || fail_ "wire authentik makes the website refuse app passwords"; pass
grep -q 'an app password signs into the portal.s website' <(awk '/^_doctor_accounts\(\)/,/^}/' services/authentik/authentik.sh) || fail_ "doctor fails while the website takes app passwords"; pass
# our blueprint applies authentik's default brand, which applies its default sign-in flow and with it
# TokenBackend on the website (found live 15 Nov 2026): our blueprint takes it out again, after that
bpf=services/authentik/blueprints/mediastack-portal.yaml
wpw=$(awk '/name: default-authentication-password/{f=1} f && /^  - model:/{exit} f' "$bpf")
[[ -n "$wpw" ]] && ! grep -q 'TokenBackend' <<<"$wpw" && grep -q 'authentik.core.auth.InbuiltBackend' <<<"$wpw" \
    || fail_ "our blueprint sets the website's password step without TokenBackend: $wpw"; pass
(( $(grep -n 'name: default-authentication-password' "$bpf" | cut -d: -f1) > $(grep -n 'path: default/default-brand.yaml' "$bpf" | cut -d: -f1) )) \
    || fail_ "...after the default brand is applied (which puts it back)"; pass

# ---- LDAP_APP_PASSWORDS (docs/design-access.md, slice 2) ----
# the blueprint: the LDAP bind's step takes app passwords only with the switch, read through !If on the value up writes
bp=$(awk '/id: stage-ldap-password/,/model: authentik_stages_identification/' services/authentik/blueprints/mediastack-portal.yaml)
grep -q 'backends: !If' <<<"$bp" && grep -q '!Env \[MEDIASTACK_LDAP_APP_PASSWORDS, ""\]' <<<"$bp" \
    && grep -qF '[authentik.core.auth.InbuiltBackend, authentik.core.auth.TokenBackend]' <<<"$bp" \
    && grep -qxF '        - [authentik.core.auth.InbuiltBackend]' <<<"$bp" \
    || fail_ "the LDAP bind's backends follow MEDIASTACK_LDAP_APP_PASSWORDS (token backend only when set): $bp"; pass
grep -q 'MEDIASTACK_LDAP_APP_PASSWORDS: ${AUTHENTIK_LDAP_APP_PASSWORDS:-}' services/authentik/compose.yml \
    || fail_ "the worker gets the switch as a blueprint input"; pass
# up writes the blueprint's input: "yes", or empty — !If reads any text as true, "no" included
ap() { ( E=$1; env_get() { [[ "$1" == LDAP_APP_PASSWORDS ]] && echo "$E"; }; env_set() { [[ "$1" == AUTHENTIK_LDAP_APP_PASSWORDS ]] && echo "[$2]"; }
         eval "$(awk '/^authentik_prepare\(\)/,/^}/' services/authentik/authentik.sh | grep 'AUTHENTIK_LDAP_APP_PASSWORDS')" ) }
[[ "$(ap yes)" == "[yes]" && "$(ap no)" == "[]" && "$(ap "")" == "[]" ]] || fail_ "the input: yes, else empty: $(ap yes) $(ap no) $(ap '')"; pass
# wire: the groups' app-password lifetime, merged into what an admin set, read back
alt() { # alt SWITCH ATTRS-frontend ATTRS-admin [DRY] -> PATCH bodies, WFAIL, then both groups' attributes after
    ( echo "$2" > "$T/g-frontend"; echo "$3" > "$T/g-admin"; rm -f "$T/calls"; WIRE_DRY=${4:-0}; SW=$1
      env_get() { [[ "$1" == LDAP_APP_PASSWORDS ]] && echo "$SW"; }
      ak_api() { echo "$1 $2 ${3:-}" >> "$T/calls"
          local g
          case "$1 $2" in
              "GET /core/groups/?name="*) g=${2#*name=}; g=${g%%&*}
                  jq -cn --arg n "$g" --argjson a "$(cat "$T/g-$g")" '{results:[{name:$n, pk:("pk-"+$n), attributes:$a}]}' ;;
              "GET /core/groups/pk-"*) g=${2#/core/groups/pk-}; g=${g%%/*}
                  jq -cn --arg n "$g" --argjson a "$(cat "$T/g-$g")" '{name:$n, pk:("pk-"+$n), attributes:$a}' ;;
              "PATCH /core/groups/pk-"*) g=${2#/core/groups/pk-}; g=${g%/}
                  [[ -n "${PATCH_DROP:-}" ]] && { echo "no answer"; return 1; }
                  jq -c '.attributes' <<<"$3" > "$T/g-$g"; echo '{}' ;;
          esac; }
      wfail() { echo "WFAIL $*" >> "$T/calls"; }; ok() { :; }
      wire_authentik_app_password_lifetime >/dev/null 2>&1
      { grep -E '^(PATCH|WFAIL)' "$T/calls" || true; } | sed 's# /core/groups/pk-# #'
      echo "after=$(cat "$T/g-frontend") $(cat "$T/g-admin")" )
}
L='goauthentik.io/user/token-maximum-lifetime'
r=$(alt yes '{"theme":"dark"}' '{}')
[[ "$r" == *"after={\"theme\":\"dark\",\"$L\":\"days=365\"} {\"$L\":\"days=365\"}" && "$r" != *WFAIL* ]] \
    || fail_ "yes: a year on both groups, an admin's own attribute kept: $r"; pass
r=$(alt no "{\"theme\":\"dark\",\"$L\":\"days=365\"}" "{\"$L\":\"days=365\"}")
[[ "$r" == *"after={\"theme\":\"dark\"} {}" && "$r" != *WFAIL* ]] || fail_ "no: the lifetime removed, nothing else: $r"; pass
r=$(alt yes "{\"$L\":\"days=365\"}" "{\"$L\":\"days=365\"}")
[[ "$r" != *PATCH* && "$r" != *WFAIL* ]] || fail_ "already as wanted: nothing written: $r"; pass
r=$(alt no '{}' '{}'); [[ "$r" != *PATCH* ]] || fail_ "no and nothing set: nothing written: $r"; pass
r=$(alt yes '{}' '{}' 1); [[ "$r" != *PATCH* && "$r" != *WFAIL* && "$r" == *"after={} {}" ]] || fail_ "a dry run writes nothing, fails nothing: $r"; pass
r=$(PATCH_DROP=1 alt yes '{}' '{}'); [[ "$r" == *"WFAIL authentik did not take the app-password lifetime on frontend,admin"* ]] \
    || fail_ "a write not made: a failure naming the groups: $r"; pass
grep -q 'wire_authentik_app_password_lifetime' <(awk '/^wire_authentik\(\)/,/^}/' services/authentik/authentik.sh) || fail_ "wire authentik sets the lifetime"; pass
grep -q 'authentik_app_passwords_doctor' <(awk '/^_doctor_accounts\(\)/,/^}/' services/authentik/authentik.sh) || fail_ "doctor checks the switch against authentik"; pass
# doctor: the live step and groups against the switch
apd() { # apd SWITCH LDAP-BACKENDS-JSON LIFETIME(-|days=365) -> doctor's word
    ( SW=$1 LB=$2 LT=$3; env_get() { [[ "$1" == LDAP_APP_PASSWORDS ]] && echo "$SW"; }
      authentik_ldap_backends() { echo "$LB"; }; authentik_group_lifetimes() { printf 'frontend\tp1\t%s\nadmin\tp2\t%s\n' "$LT" "$LT"; }
      ok() { echo "OK $*"; }; warn() { echo "WARN $*"; }; d_fail() { echo "FAIL $1"; }; authentik_app_passwords_doctor )
}
TB='["authentik.core.auth.InbuiltBackend","authentik.core.auth.TokenBackend"]'; IB='["authentik.core.auth.InbuiltBackend"]'
[[ "$(apd no "$IB" -)" == "OK authentik: app passwords refused by Jellyfin (LDAP_APP_PASSWORDS=no)" ]] || fail_ "doctor: no, as applied: OK"; pass
[[ "$(apd yes "$TB" days=365)" == "OK authentik: app passwords taken by Jellyfin, for up to a year" ]] || fail_ "doctor: yes, as applied: OK"; pass
[[ "$(apd no "$TB" -)" == "FAIL authentik: Jellyfin's sign-in takes app passwords, but LDAP_APP_PASSWORDS=no" ]] || fail_ "doctor: no, but the bind takes them: $(apd no "$TB" -)"; pass
[[ "$(apd yes "$IB" days=365)" == "FAIL authentik: Jellyfin's sign-in refuses app passwords, but LDAP_APP_PASSWORDS=yes" ]] || fail_ "doctor: yes, not applied yet"; pass
[[ "$(apd yes "$TB" -)" == "FAIL authentik: how long an app password may last does not match LDAP_APP_PASSWORDS=yes" ]] || fail_ "doctor: yes, a day only"; pass

# authentik took 22s to save the stage on a first start (found live Nov 2026): the write waits longer than a read
showpw false "" >/dev/null; [[ "$(cat "$T/patch-wait")" == "$AUTHENTIK_STAGE_WAIT" ]] && (( AUTHENTIK_STAGE_WAIT >= 60 )) \
    || fail_ "show password: its write waits AUTHENTIK_STAGE_WAIT ($(cat "$T/patch-wait"))"; pass
: > "$T/mt"
( curl() { local a prev=""; for a in "$@"; do [[ "$prev" == -m ]] && echo "$a" >> "$T/mt"; prev=$a; done; printf '{}\n200'; }
  eval "$(awk '/^ak_api\(\)/,/^}/' services/authentik/authentik.sh)"   # the real one: earlier checks stub it
  env_get() { :; }; authentik_url() { echo http://x; }; API_TIMEOUT=77 ak_api GET /x >/dev/null; ak_api GET /y >/dev/null )
mt=$(paste -sd' ' "$T/mt")
[[ "$mt" == "77 20" ]] || fail_ "ak_api waits API_TIMEOUT for one call, 20s otherwise ($mt)"; pass

# doctor: a link without working email is a failure (people get no email)
( printf 'SMTP_HOST=\n' > "$T/denv"; ENV_FILE=$T/denv; D_FAILS=0; fail() { echo "FAIL $*"; }
  ak_api() { case "$1 $2" in
      "GET /flows/instances/?slug=mediastack-recovery") echo '{"results":[{"pk":"F-OURS"}]}' ;;
      "GET /stages/identification/?name=default-authentication-identification") echo '{"results":[{"pk":"S1","name":"default-authentication-identification","recovery_flow":"F-OURS"}]}' ;;
      "GET /core/brands/?domain=authentik-default") echo '{"results":[{"brand_uuid":"B1","flow_recovery":"F-OURS"}]}' ;;
  esac; }
  out=$(authentik_recovery_doctor); [[ "$out" == *'FAIL authentik: "Forgot password?" shows, but email'* ]] || fail_ "doctor: a link without working email: $out" ) || exit 1; pass
grep -q 'authentik_recovery_doctor' services/authentik/authentik.sh || fail_ "doctor checks the reset link"; pass

# ---- the account model is asked once (signin_model), the admins list read once (signin_admins) ----
# Outside the providers' folders nothing asks "is authentik/wizarr enabled?"
# but signin_model itself, and authentik's own upkeep (its release record, the
# blueprint-change notice) — those are about the service, not who signs in.
leak=$(grep -rnE 'svc_enabled (authentik|wizarr)' mediastack.sh lib services --include=*.sh \
        | grep -vE '^services/(authentik|wizarr)/' \
        | grep -vE '^lib/access\.sh:[0-9]+:\s+(el)?if svc_enabled (authentik|wizarr); then echo (authentik|wizarr)$' \
        | grep -vE '^mediastack\.sh:[0-9]+:.*authentik_release_record|^lib/lifecycle\.sh:[0-9]+:.*services/authentik/\(blueprints' || true)
[[ -z "$leak" ]] || fail_ "the account model asked by a service's name (use signin_is): $leak"; pass
copies=$(grep -rn 'groups_by_name=' mediastack.sh lib services --include=*.sh | grep -vc '^services/authentik/' || true)
[[ "$copies" == 0 ]] || fail_ "the admin group lookup is copied outside signin_admins ($copies)"; pass
olds=$(grep -rnE "[\"'(\[ ]media-users[\"') ,]|[\"'(\[ ]admins[\"') ,\]]|cn=admins|cn=media-users" mediastack.sh lib services --include=*.sh --include=*.yml \
       | grep -vE 'lib/migrations\.sh|# |blueprints/' || true)
[[ -z "$olds" ]] || fail_ "the old group names read in code (use PORTAL_FRONTEND / PORTAL_ADMIN): $olds"; pass
api=$(grep -rnE '\bak_api\b|wizarr_url|/api/invitations' mediastack.sh lib --include=*.sh || true)
[[ -z "$api" ]] || fail_ "a sign-in provider's API spoken from lib/ (it belongs in services/authentik or services/wizarr): $api"; pass
for m in authentik wizarr none; do
    got=$(svc_enabled() { case "$1" in authentik) [[ $m == authentik ]] ;; wizarr) [[ $m != none ]] ;; *) return 1 ;; esac; }; signin_model)
    [[ "$got" == "$m" ]] || fail_ "signin_model: $m expected, got $got"; pass
done

# ---- a Jellyfin lockout tells ops: the rule's transport is the hub, at its address now ----
lk() { # lk HUB(1|0) TRANSPORT_URL('' = none) DRY -> the authentik API writes, one per line
    ( ak_api() { echo "$1 $2 ${3:-}" >> "$T/lk-calls"
        case "$1 $2" in
          "GET /events/rules/?name=mediastack-jellyfin-lockout") echo '{"results":[{"pk":"R1","transports":["T9"]}]}' ;;
          "GET /propertymappings/notification/?name=mediastack-hub-ops") echo '{"results":[{"pk":"M1"}]}' ;;
          "GET /events/transports/?name=mediastack-hub-ops") [[ -n "$LK_URL" ]] && echo "{\"results\":[{\"pk\":\"T1\",\"webhook_url\":\"$LK_URL\"}]}" || echo '{"results":[]}' ;;
          "POST /events/transports/") echo '{"pk":"T1"}' ;;
          "GET /events/rules/R1/") echo '{"transports":["T9"]}' ;;
          *) echo '{}' ;;
        esac; }
      hub_enabled() { (( LK_HUB )); }; svc_addr() { echo "apprise:8000"; }
      LK_HUB=$1 LK_URL=$2 WIRE_DRY=$3; : > "$T/lk-calls"
      wire_authentik_lockout_alerts >/dev/null 2>&1 )
    grep -vE '^GET ' "$T/lk-calls" || true
}
w=$(lk 1 "" 0)
grep -q '^POST /events/transports/ .*"webhook_url":"http://apprise:8000/notify/mediastack".*"webhook_mapping_body":"M1".*"send_once":true' <<<"$w" \
    || fail_ "no transport yet: one is made, posting to the hub's address with the hub's message shape: $w"; pass
grep -q '^PATCH /events/rules/R1/ {"transports":\["T1"\]}' <<<"$w" || fail_ "the rule gets the hub's transport: $w"; pass
w=$(lk 1 "http://gluetun:8000/notify/mediastack" 0)
grep -q '^PATCH /events/transports/T1/ .*"webhook_url":"http://apprise:8000/notify/mediastack"' <<<"$w" || fail_ "the hub moved (VPN): the transport is re-pointed: $w"; pass
[[ -z "$(lk 1 "" 1)" ]] || fail_ "--verify writes nothing"; pass
grep -q '^PATCH /events/rules/R1/ {"transports":\[\]}' <<<"$(lk 0 "" 0)" || fail_ "no hub: the rule's transports are emptied (no send to nowhere)"; pass
grep -q 'hub_notify_url' services/authentik/authentik.sh && ! grep -q '/notify/mediastack' services/authentik/authentik.sh \
    || fail_ "authentik posts to the hub through the hub interface (hub_notify_url), not a written-out address"; pass

# ---- tiers: .env's <SVC>_TIER over the service's mediastack.tier label over its kind ----
tr_() { ( E=$2 L=$3 G=$4; env_get() { [[ "$1" == "$(uvar "$S")_TIER" ]] && echo "$E"; return 0; }
          svc_label() { case "$2" in mediastack.tier) echo "$L" ;; mediastack.auth.group) echo "$G" ;; esac; return 0; }
          S=$1; svc_tier "$1" ) }
[[ "$(tr_ sonarr '' '' '')" == admin && "$(tr_ navidrome '' '' frontend)" == frontend ]] || fail_ "a tool is admin, a household gate's app frontend, by default"; pass
[[ "$(tr_ sonarr '' frontend '')" == frontend ]] || fail_ "a service's label sets its default tier"; pass
[[ "$(tr_ sonarr-anime frontend '' '')" == frontend && "$(tr_ navidrome admin '' frontend)" == admin ]] || fail_ ".env's <SVC>_TIER wins (a hyphenated name too)"; pass

# ---- access: list, one person, tier moves (docs/design-access.md decision 8) ----
AP='{"results":[
 {"pk":1,"username":"alice","type":"internal","is_active":true,"groups_obj":[{"name":"admin"}]},
 {"pk":2,"username":"bob","type":"internal","is_active":true,"groups_obj":[{"name":"frontend"}]},
 {"pk":3,"username":"carol","type":"internal","is_active":true,"groups_obj":[{"name":"frontend"},{"name":"app-sonarr"}]},
 {"pk":4,"username":"dave","type":"internal","is_active":false,"groups_obj":[]},
 {"pk":5,"username":"erin","type":"internal","is_active":true,"groups_obj":[{"name":"frontend"},{"name":"admin"}]},
 {"pk":6,"username":"fay","type":"internal","is_active":true,"groups_obj":[{"name":"frontend"},{"name":"app-navidrome"}]},
 {"pk":7,"username":"bot","type":"service_account","is_active":true,"groups_obj":[]},
 {"pk":8,"username":"gina","type":"internal","is_active":true,"groups_obj":[{"name":"frontend"},{"name":"admin"},{"name":"authentik Admins"}]}]}'
acc() { # acc FUNCTION ARGS... -> its output and rc; .env in $T/aenv, calls in $T/acalls
    ( signin_people() { echo "$AP"; }
      authentik_gate_apps() { printf '%s\n' sonarr navidrome; }
      authentik_native_ruled() { echo jellyfin; }   # signs people in itself, under the rule (its tier label)
      people_follow_now() { echo "follow $1" >> "$T/acalls"; }
      svc_url() { echo "https://$1.x"; }
      svc_label() { case "$1:$2" in navidrome:mediastack.auth.group|jellyfin:mediastack.tier) echo frontend ;; esac; return 0; }
      env_get() { awk -F= -v k="$1" '$1==k{print substr($0, index($0,"=")+1)}' "$T/aenv"; }
      env_set() { env_del "$1"; echo "$1=$2" >> "$T/aenv"; echo "env_set $1=$2" >> "$T/acalls"; }
      env_del() { awk -F= -v k="$1" '$1!=k' "$T/aenv" > "$T/aenv.n"; mv "$T/aenv.n" "$T/aenv"; echo "env_del $1" >> "$T/acalls"; }
      wire_authentik_cards() { echo "wire cards (sonarr $(svc_tier sonarr), navidrome $(svc_tier navidrome))" >> "$T/acalls"; (( ${WFAIL:-0} )) && WIRE_FAILS=1; return 0; }
      ak_api() { echo "$1 $2" >> "$T/acalls"; echo "{\"deleted\":${DEL:-3}}"; }
      signin_app_group_ready() { [[ -z "${NOTREADY:-}" ]] || { echo "the group app-$1 does not exist yet"; return 1; }; }
      signin_group_change() { echo "group $1 $2 $3" >> "$T/acalls"; [[ -z "${GCFAIL:-}" ]] || { echo "refused"; return 1; }; }
      signin_supergroup() { [[ -z "${SGFAIL:-}" ]] || { echo "authentik has 2 superuser groups (a, b) — which one is meant is not guessed; keep one"; return 1; }; echo "authentik Admins"; }
      confirm() { echo "asked: $1" >> "$T/acalls"; [[ "${ANS:-n}" == y ]]; }
      warn() { echo "WARN $*"; }; ok() { echo "OK $*"; }; info() { echo ":: $*"; }
      rc=0; ( "$@" ) 2>&1 || rc=$?; echo "rc=$rc" )
}
: > "$T/aenv"; rm -f "$T/acalls"
o=$(acc access_list)
grep -qE '^sonarr +admin +carol +https://sonarr.x$' <<<"$o" && grep -qE '^navidrome +frontend +fay +https://navidrome.x$' <<<"$o" \
    || fail_ "access list: each app's tier, who has it on its own, its address: $o"; pass
[[ "$(acc access_list_user alice | grep -cE '^(sonarr|navidrome) +admin ')" == 2 ]] || fail_ "an admin may open every app: $(acc access_list_user alice)"; pass
o=$(acc access_list_user CAROL)
grep -qE '^sonarr +given on its own \(app-sonarr\)' <<<"$o" && grep -qE '^navidrome +frontend \(its tier\)' <<<"$o" \
    || fail_ "carol (any case): sonarr given on its own, navidrome by her tier: $o"; pass
o=$(acc access_list_user bob); grep -qE '^navidrome ' <<<"$o" && ! grep -qE '^sonarr ' <<<"$o" && ! grep -q 'may open none' <<<"$o" \
    || fail_ "bob: navidrome only — and not also told he may open none (seen live): $o"; pass
o=$(acc access_list_user dave); grep -q 'may open none' <<<"$o" && grep -q "account is off" <<<"$o" && ! grep -q '^APP' <<<"$o" \
    || fail_ "dave: nothing (no empty table), and his account is off: $o"; pass
o=$(acc access_list_user nobody); grep -q "the portal has no user 'nobody'" <<<"$o" && grep -q 'rc=1' <<<"$o" || fail_ "an unknown name stops: $o"; pass
# tier: the checks before anything changes
o=$(acc access_tier sonarr everyone); grep -q "frontend (the household and its admins) or admin" <<<"$o" && grep -q rc=1 <<<"$o" || fail_ "an unknown tier stops: $o"; pass
o=$(acc access_tier kavita admin); grep -q "not an app access covers — those are: sonarr navidrome jellyfin" <<<"$o" || fail_ "an app access does not cover stops, those it covers named: $o"; pass
o=$(acc access_tier sonarr admin); grep -q "sonarr is admin already" <<<"$o" && [[ ! -f "$T/acalls" ]] || fail_ "already there: nothing done: $o"; pass
# to frontend: warned and asked; no means nothing changes
o=$(acc access_tier sonarr frontend); grep -q "nothing changed: sonarr stays admin" <<<"$o" && ! grep -q 'env_set\|wire' "$T/acalls" \
    || fail_ "opening a tool to the household asks first; no changes nothing: $o $(cat "$T/acalls")"; pass
rm -f "$T/acalls"; o=$(ANS=y acc access_tier sonarr frontend)
grep -qx 'env_set SONARR_TIER=frontend' "$T/acalls" && grep -qx 'wire cards (sonarr frontend, navidrome frontend)' "$T/acalls" \
    && ! grep -q bulk_delete "$T/acalls" && grep -q 'OK access: sonarr is frontend now' <<<"$o" \
    || fail_ "yes: kept in .env (it differs from the default), the rule applied, nobody signed out: $o $(cat "$T/acalls")"; pass
rm -f "$T/acalls"; o=$(acc access_tier sonarr admin --yes)
grep -qx 'env_del SONARR_TIER' "$T/acalls" || fail_ "back to its default: the .env line goes: $(cat "$T/acalls")"; pass
# to admin: who loses it (the household, not admins, not those given it) signed out
rm -f "$T/acalls"; : > "$T/aenv"; o=$(acc access_tier navidrome admin)
grep -qx 'env_set NAVIDROME_TIER=admin' "$T/acalls" && grep -qx 'DELETE /core/authenticated_sessions/bulk_delete/?user_pks=2&user_pks=3' "$T/acalls" \
    && grep -q '2 of the household lost it (bob,carol); their portal sessions ended (3)' <<<"$o" && ! grep -q asked "$T/acalls" \
    || fail_ "navidrome to admin: no question, bob and carol signed out of the portal, alice and erin (an admin, in both groups) and fay (granted) kept: $o $(cat "$T/acalls")"; pass
b=$(grep -n '^wire cards' "$T/acalls" | cut -d: -f1); d=$(grep -n bulk_delete "$T/acalls" | cut -d: -f1)
(( b < d )) || fail_ "the rule first, then the sessions (a new sign-in must already hear no)"; pass
rm -f "$T/acalls"; : > "$T/aenv"; o=$(WFAIL=1 acc access_tier navidrome admin)
grep -q "navidrome's rule did not take" <<<"$o" && grep -q rc=1 <<<"$o" && ! grep -q bulk_delete "$T/acalls" \
    || fail_ "the rule refused: stop, say so, nobody signed out: $o"; pass
rm -f "$T/acalls"; : > "$T/aenv"; o=$(DEL=0 acc access_tier navidrome admin)
grep -q '2 of the household lost it (bob,carol); no portal session of theirs was open' <<<"$o" \
    || fail_ "nobody's session was open: said so, not 'ended (0)': $o"; pass
: > "$T/aenv"
# grant: into app-<svc>, the person saved (their dashboard follows) — no session to end
rm -f "$T/acalls"; o=$(acc access_grant BOB sonarr)
grep -qx 'group add 2 app-sonarr' "$T/acalls" && grep -q 'OK access: bob can now open sonarr (granted)' <<<"$o" && ! grep -q bulk_delete "$T/acalls" \
    || fail_ "grant: bob (any case) into app-sonarr, said so, nobody signed out: $o $(cat "$T/acalls")"; pass
rm -f "$T/acalls"; o=$(acc access_grant carol sonarr); grep -q 'carol has sonarr granted already' <<<"$o" && [[ ! -f "$T/acalls" ]] \
    || fail_ "granted already: nothing done: $o"; pass
o=$(acc access_grant bob navidrome); grep -q 'they could already open it through frontend (its tier); the grant keeps it if that changes' <<<"$o" \
    || fail_ "a grant beside the tier: made, and said what it adds: $o"; pass
o=$(acc access_grant dave sonarr); grep -q "dave's portal account is off" <<<"$o" && grep -q rc=0 <<<"$o" || fail_ "a grant to an account that is off: made, and warned: $o"; pass
for a in "bot sonarr:is not a person's account" "bob kavita:not an app access covers" "nobody sonarr:the portal has no user 'nobody'" "bob:usage: access grant"; do
    rm -f "$T/acalls"; read -ra w <<<"${a%%:*}"; o=$(acc access_grant "${w[@]}")
    grep -q "${a#*:}" <<<"$o" && grep -q rc=1 <<<"$o" && ! grep -q '^group' "$T/acalls" 2>/dev/null || fail_ "grant ${a%%:*}: stops (${a#*:}), nothing changed: $o"; pass
done
rm -f "$T/acalls"; o=$(NOTREADY=1 acc access_grant bob sonarr)
grep -q 'the group app-sonarr does not exist yet — ./mediastack.sh wire authentik makes it' <<<"$o" && grep -q rc=1 <<<"$o" && ! grep -q '^group' "$T/acalls" 2>/dev/null \
    || fail_ "the app's group or its card's rule missing: stop before changing anyone: $o"; pass
o=$(GCFAIL=1 acc access_grant bob sonarr); grep -q 'authentik did not grant bob sonarr: refused' <<<"$o" && grep -q rc=1 <<<"$o" || fail_ "a refused grant stops, authentik's answer shown: $o"; pass
# revoke: out of app-<svc>; when that takes the app away, their portal sessions end — after the change
rm -f "$T/acalls"; o=$(acc access_revoke carol sonarr)
grep -qx 'group remove 3 app-sonarr' "$T/acalls" && grep -qx 'DELETE /core/authenticated_sessions/bulk_delete/?user_pks=3' "$T/acalls" \
    && grep -q 'carol can no longer open sonarr — their portal sessions ended (3)' <<<"$o" \
    || fail_ "revoke: carol out of app-sonarr, her portal sessions ended: $o $(cat "$T/acalls")"; pass
[[ "$(grep -n '^group remove' "$T/acalls" | cut -d: -f1)" -lt "$(grep -n bulk_delete "$T/acalls" | cut -d: -f1)" ]] \
    || fail_ "the group first, then the sessions (a new sign-in must already hear no)"; pass
o=$(DEL=0 acc access_revoke carol sonarr); grep -q 'no portal session of theirs was open' <<<"$o" || fail_ "revoke, no session open: said so: $o"; pass
rm -f "$T/acalls"; o=$(acc access_revoke fay navidrome)
grep -qx 'group remove 6 app-navidrome' "$T/acalls" && ! grep -q bulk_delete "$T/acalls" && grep -q 'still open it through frontend (its tier)' <<<"$o" \
    || fail_ "a grant beside the tier: removed, nobody signed out, told they keep it: $o $(cat "$T/acalls")"; pass
rm -f "$T/acalls"; o=$(acc access_revoke bob sonarr); grep -q 'bob has no grant of sonarr — nothing to take away' <<<"$o" && grep -q rc=0 <<<"$o" && [[ ! -f "$T/acalls" ]] \
    || fail_ "no grant: nothing done: $o"; pass
o=$(acc access_revoke alice sonarr); grep -q "alice opens sonarr as one of 'admin', not by a grant — ./mediastack.sh access admin alice off" <<<"$o" && grep -q rc=1 <<<"$o" \
    || fail_ "an admin: refused, and said how: $o"; pass
o=$(acc access_revoke bob navidrome); grep -q 'through its tier (frontend), not by a grant — for admins only: ./mediastack.sh access tier navidrome admin' <<<"$o" && grep -q rc=1 <<<"$o" \
    || fail_ "the household's tier: refused, and said how: $o"; pass
rm -f "$T/acalls"; o=$(GCFAIL=1 acc access_revoke carol sonarr); grep -q 'authentik did not take sonarr from carol' <<<"$o" && grep -q rc=1 <<<"$o" && ! grep -q bulk_delete "$T/acalls" \
    || fail_ "a refused revoke stops before ending anyone's session: $o"; pass

# admin: into or out of the portal's admin group; the apps with accounts of their own follow, losing it ends portal sessions
rm -f "$T/acalls"; o=$(acc access_admin BOB on)
grep -qx 'group add 2 admin' "$T/acalls" && ! grep -q bulk_delete "$T/acalls" && grep -q 'OK access: bob is an admin — every app behind the gate' <<<"$o" \
    && [[ "$(grep '^follow' "$T/acalls" | paste -sd' ' -)" == "follow jellyfin follow kavita follow audiobookshelf follow navidrome" ]] \
    || fail_ "admin on: bob (any case) into admin, nobody signed out, every app with accounts of its own follows: $o $(cat "$T/acalls")"; pass
rm -f "$T/acalls"; o=$(acc access_admin alice on); grep -q 'alice is an admin already' <<<"$o" && grep -q rc=0 <<<"$o" && [[ ! -f "$T/acalls" ]] \
    || fail_ "admin on, an admin already: nothing done: $o"; pass
o=$(acc access_admin dave on); grep -q "dave's portal account is off" <<<"$o" && grep -q rc=0 <<<"$o" || fail_ "admin on, an account that is off: made, and warned: $o"; pass
rm -f "$T/acalls"; o=$(acc access_admin erin off)
grep -qx 'group remove 5 admin' "$T/acalls" && grep -qx 'DELETE /core/authenticated_sessions/bulk_delete/?user_pks=5' "$T/acalls" \
    && grep -q 'erin is no longer an admin — their portal sessions ended (3), so their next visit asks again; what they keep: ./mediastack.sh access list erin' <<<"$o" \
    && [[ "$(grep -c '^follow' "$T/acalls")" == 4 ]] \
    || fail_ "admin off: erin out of admin, her portal sessions ended, the apps follow: $o $(cat "$T/acalls")"; pass
g=$(grep -n '^group remove' "$T/acalls" | cut -d: -f1); d=$(grep -n bulk_delete "$T/acalls" | cut -d: -f1); f=$(grep -n '^follow' "$T/acalls" | sed -n 1p | cut -d: -f1)
(( g < d && d < f )) || fail_ "admin off: the group first, then the sessions, then the apps"; pass
o=$(DEL=0 acc access_admin erin off); grep -q 'no portal session of theirs was open' <<<"$o" || fail_ "admin off, no session open: said so: $o"; pass
rm -f "$T/acalls"; o=$(acc access_admin bob off); grep -q 'bob is not an admin — nothing to take away' <<<"$o" && grep -q rc=0 <<<"$o" && [[ ! -f "$T/acalls" ]] \
    || fail_ "admin off, not an admin: nothing done: $o"; pass
rm -f "$T/acalls"; o=$(GCFAIL=1 acc access_admin erin off); grep -q "authentik did not take erin out of 'admin': refused" <<<"$o" && grep -q rc=1 <<<"$o" \
    && ! grep -q bulk_delete "$T/acalls" && ! grep -q '^follow' "$T/acalls" \
    || fail_ "admin off refused: stop before ending sessions or following: $o"; pass
AKP='{"results":[{"pk":9,"username":"akadmin","type":"internal","is_active":true,"groups_obj":[{"name":"admin"}]}]}'
rm -f "$T/acalls"; o=$(AP=$AKP acc access_admin akadmin off); grep -q "akadmin is authentik's own superuser and stays an admin" <<<"$o" && grep -q rc=1 <<<"$o" && [[ ! -f "$T/acalls" ]] \
    || fail_ "akadmin: refused, kept as it is: $o"; pass
for a in "bot on:is not a person's account" "bob yes:access admin: 'yes' — on or off" "nobody on:the portal has no user 'nobody'" "bob:usage: access admin"; do
    rm -f "$T/acalls"; read -ra w <<<"${a%%:*}"; o=$(acc access_admin "${w[@]}")
    grep -q "${a#*:}" <<<"$o" && grep -q rc=1 <<<"$o" && [[ ! -f "$T/acalls" ]] || fail_ "admin ${a%%:*}: stops (${a#*:}), nothing changed: $o"; pass
done

# admin off also takes authentik's superuser group: nobody keeps it after losing admin
rm -f "$T/acalls"; o=$(acc access_admin gina off)
[[ "$(grep -E '^(group|DELETE)' "$T/acalls" | paste -sd'|' -)" == "group remove 8 authentik Admins|group remove 8 admin|DELETE /core/authenticated_sessions/bulk_delete/?user_pks=8" ]] \
    && grep -q "gina no longer manages the portal ('authentik Admins')" <<<"$o" \
    || fail_ "admin off, a portal manager: out of the superuser group, then admin, then signed out: $o $(cat "$T/acalls")"; pass
rm -f "$T/acalls"; o=$(SGFAIL=1 acc access_admin erin off); grep -q "nothing changed: whether erin manages the portal is unknown" <<<"$o" && grep -q rc=1 <<<"$o" && ! grep -q '^group' "$T/acalls" 2>/dev/null \
    || fail_ "admin off, the superuser group not found: stop before changing anything: $o"; pass
o=$(acc access_list_user gina); grep -q "gina also manages the portal itself ('authentik Admins'" <<<"$o" || fail_ "access list <user>: says who manages the portal: $o"; pass
o=$(acc access_list_user erin); ! grep -q 'manages the portal' <<<"$o" || fail_ "access list <user>: an admin who does not manage the portal is not said to: $o"; pass
# portal: authentik's own superuser group, a separate choice, for an admin only
rm -f "$T/acalls"; o=$(acc access_portal erin on)
grep -q 'asked: Let erin manage the portal?' "$T/acalls" && ! grep -q '^group' "$T/acalls" && grep -q 'nothing changed: erin does not manage the portal' <<<"$o" \
    && grep -q 'WARN access: erin gets authentik.s admin screens' <<<"$o" \
    || fail_ "portal on: warned and asked; no changes nothing: $o $(cat "$T/acalls")"; pass
rm -f "$T/acalls"; o=$(ANS=y acc access_portal ERIN on)
grep -qx 'group add 5 authentik Admins' "$T/acalls" && ! grep -q bulk_delete "$T/acalls" && grep -q 'OK access: erin manages the portal' <<<"$o" \
    || fail_ "portal on, yes: erin (any case) into the superuser group, nobody signed out: $o $(cat "$T/acalls")"; pass
rm -f "$T/acalls"; o=$(acc access_portal erin on --yes); ! grep -q asked "$T/acalls" && grep -qx 'group add 5 authentik Admins' "$T/acalls" || fail_ "portal on --yes: no question: $(cat "$T/acalls")"; pass
rm -f "$T/acalls"; o=$(acc access_portal gina on); grep -q "gina manages the portal already ('authentik Admins')" <<<"$o" && [[ ! -f "$T/acalls" ]] || fail_ "portal on, already: nothing done: $o"; pass
rm -f "$T/acalls"; o=$(ANS=y acc access_portal bob on); grep -q "bob is not an admin — the portal's management goes only to an admin: ./mediastack.sh access admin bob on" <<<"$o" && grep -q rc=1 <<<"$o" && ! grep -q '^group\|asked' "$T/acalls" 2>/dev/null \
    || fail_ "portal on, not an admin: refused before asking, said how: $o"; pass
rm -f "$T/acalls"; o=$(acc access_portal gina off)
grep -qx 'group remove 8 authentik Admins' "$T/acalls" && grep -qx 'DELETE /core/authenticated_sessions/bulk_delete/?user_pks=8' "$T/acalls" && ! grep -q 'group remove 8 admin' "$T/acalls" \
    && grep -q 'gina no longer manages the portal — their portal sessions ended (3), so their next visit asks again; they stay an admin' <<<"$o" \
    || fail_ "portal off: out of the superuser group, signed out, still an admin: $o $(cat "$T/acalls")"; pass
rm -f "$T/acalls"; o=$(acc access_portal erin off); grep -q 'erin does not manage the portal — nothing to take away' <<<"$o" && grep -q rc=0 <<<"$o" && [[ ! -f "$T/acalls" ]] \
    || fail_ "portal off, not a manager: nothing done: $o"; pass
rm -f "$T/acalls"; o=$(GCFAIL=1 acc access_portal gina off); grep -q "authentik did not take gina out of 'authentik Admins': refused" <<<"$o" && grep -q rc=1 <<<"$o" && ! grep -q bulk_delete "$T/acalls" \
    || fail_ "portal off refused: stop before ending sessions: $o"; pass
rm -f "$T/acalls"; o=$(SGFAIL=1 ANS=y acc access_portal erin on); grep -q 'authentik has 2 superuser groups (a, b)' <<<"$o" && grep -q rc=1 <<<"$o" && ! grep -q '^group' "$T/acalls" 2>/dev/null \
    || fail_ "portal, the superuser group not found: stop, say why: $o"; pass
o=$(AP=$AKP acc access_portal akadmin off); grep -q "akadmin is authentik's own superuser and stays one" <<<"$o" && grep -q rc=1 <<<"$o" || fail_ "portal, akadmin: refused: $o"; pass
for a in "bot on:is not a person's account" "erin maybe:access portal: 'maybe' — on or off" "nobody on:the portal has no user 'nobody'" "erin:usage: access portal" "erin on --force:Unknown access portal arg '--force'"; do
    rm -f "$T/acalls"; read -ra w <<<"${a%%:*}"; o=$(ANS=y acc access_portal "${w[@]}")
    grep -q "${a#*:}" <<<"$o" && grep -q rc=1 <<<"$o" && ! grep -q '^group' "$T/acalls" 2>/dev/null || fail_ "portal ${a%%:*}: stops (${a#*:}), nothing changed: $o"; pass
done

# Jellyfin signs people in itself (slice B): no portal session decides it —
# its own switch does, through its accounts' follow, after the rule changed
: > "$T/aenv"; o=$(acc access_list)
grep -qE '^jellyfin +frontend +- +https://jellyfin.x$' <<<"$o" && grep -q 'Seerr signs people in through Jellyfin and follows its rule (./mediastack.sh users)' <<<"$o" \
    || fail_ "access list: Jellyfin with its tier; Seerr said to follow it: $o"; pass
rm -f "$T/acalls"; o=$(acc access_tier jellyfin admin)
grep -qx 'env_set JELLYFIN_TIER=admin' "$T/acalls" && ! grep -q bulk_delete "$T/acalls" && grep -qx 'follow jellyfin' "$T/acalls" \
    && grep -q 'OK access: jellyfin is admin-only — 3 of the household lost it (bob,carol,fay)$' <<<"$o" \
    || fail_ "jellyfin to admin: no portal session ended, its accounts follow (they turn its own switch): $o $(cat "$T/acalls")"; pass
b=$(grep -n '^wire cards' "$T/acalls" | cut -d: -f1); d=$(grep -n '^follow jellyfin' "$T/acalls" | cut -d: -f1)
(( b < d )) || fail_ "the rule first, then the accounts"; pass
: > "$T/aenv"; rm -f "$T/acalls"; o=$(acc access_grant bob jellyfin)
grep -qx 'group add 2 app-jellyfin' "$T/acalls" && grep -qx 'follow jellyfin' "$T/acalls" || fail_ "grant jellyfin: into app-jellyfin, then its accounts follow (back on, if the stack turned them off): $o"; pass
rm -f "$T/acalls"; o=$(acc access_revoke carol jellyfin); grep -q "carol opens jellyfin through its tier (frontend), not by a grant" <<<"$o" && ! grep -q '^follow' "$T/acalls" 2>/dev/null \
    || fail_ "revoke where the tier gives it: refused, said how, nothing followed: $o"; pass
AP=${AP/'{"name":"app-sonarr"}'/'{"name":"app-sonarr"},{"name":"app-jellyfin"}'}; echo 'JELLYFIN_TIER=admin' > "$T/aenv"
rm -f "$T/acalls"; o=$(acc access_revoke carol jellyfin)
grep -qx 'group remove 3 app-jellyfin' "$T/acalls" && ! grep -q bulk_delete "$T/acalls" && grep -qx 'follow jellyfin' "$T/acalls" \
    && grep -q 'OK access: carol can no longer open jellyfin$' <<<"$o" \
    || fail_ "revoke jellyfin: out of app-jellyfin, no portal session ended, its accounts follow: $o $(cat "$T/acalls")"; pass
: > "$T/aenv"

# ---- signin_group_change: the membership changed, read back, then the person saved ----
gc() { # gc add|remove USER GROUP -> rc and the calls; HAS: what the read-back shows
    ( ak_api() { echo "$1 $2 ${3:-}" >> "$T/gcalls"
        case "$1 $2" in
          "GET /core/groups/?search=app-sonarr") echo '{"results":[{"name":"app-sonarr","pk":"g-s"},{"name":"app-sonarr-anime","pk":"g-sa"}]}' ;;
          "GET /core/groups/?search="*) echo '{"results":[]}' ;;
          "POST /core/groups/"*) [[ -z "${REF:-}" ]] || { echo '{"detail":"no"}'; return 1; }; echo '' ;;
          "GET /core/users/2/") echo "{\"pk\":2,\"name\":\"Bob B\",\"groups_obj\":[${HAS:-}]}" ;;
          "PATCH /core/users/2/") echo '{}' ;;
        esac; }
      rm -f "$T/gcalls"; rc=0; signin_group_change "$@" || rc=$?; echo "rc=$rc" )
}
o=$(HAS='{"name":"app-sonarr"}' gc add 2 app-sonarr)
[[ "$o" == rc=0 ]] && grep -qx 'POST /core/groups/g-s/add_user/ {"pk":2}' "$T/gcalls" && grep -qx 'PATCH /core/users/2/ {"name":"Bob B"}' "$T/gcalls" \
    || fail_ "add: the exact group (not a lookalike), read back, then the person saved as they are: $o $(cat "$T/gcalls")"; pass
o=$(HAS='' gc remove 2 app-sonarr); [[ "$o" == rc=0 ]] && grep -q '^POST /core/groups/g-s/remove_user/' "$T/gcalls" || fail_ "remove: read back gone: $o"; pass
o=$(HAS='' gc add 2 app-sonarr); grep -q 'their groups did not change' <<<"$o" && grep -q rc=1 <<<"$o" && ! grep -q '^PATCH' "$T/gcalls" \
    || fail_ "authentik said yes but nothing changed: a failure, not assumed: $o"; pass
o=$(REF=1 gc add 2 app-sonarr); grep -q '"detail":"no"' <<<"$o" && grep -q rc=1 <<<"$o" || fail_ "refused: authentik's answer shown: $o"; pass
o=$(gc add 2 app-nothing); grep -q "there is no group 'app-nothing'" <<<"$o" && ! grep -q '^POST' "$T/gcalls" || fail_ "no such group: stop before writing: $o"; pass
o=$( ( ak_api() { echo "$1 $2" >> "$T/gcalls"; echo '{"results":[{"name":"authentik Admins","pk":"g-ak"}]}'; }; rm -f "$T/gcalls"; ak_group_pk "authentik Admins" ) )
[[ "$o" == g-ak ]] && grep -qx 'GET /core/groups/?search=authentik%20Admins' "$T/gcalls" || fail_ "a group name with a space is sent encoded: $o $(cat "$T/gcalls")"; pass

# ---- signin_supergroup: authentik's own superuser group, by its flag, exactly one ----
sgq() { ( ak_api() { echo "$1 $2" >> "$T/sgcalls"; [[ -z "${SGREF:-}" ]] || { echo '{"detail":"no"}'; return 1; }; echo "$SGR"; }
          rm -f "$T/sgcalls"; rc=0; signin_supergroup || rc=$?; echo "rc=$rc" ); }
o=$(SGR='{"results":[{"name":"authentik Admins","is_superuser":true}]}' sgq)
[[ "$o" == $'authentik Admins\nrc=0' ]] && grep -qx 'GET /core/groups/?is_superuser=true&page_size=500' "$T/sgcalls" || fail_ "one superuser group: its name, asked by its flag: $o"; pass
o=$(SGR='{"results":[{"name":"admin","is_superuser":false},{"name":"frontend","is_superuser":false},{"name":"authentik Admins","is_superuser":true}]}' sgq)
[[ "$o" == $'authentik Admins\nrc=0' ]] || fail_ "the filter ignored: a plain group never passes for the superuser one: $o"; pass
o=$(SGR='{"results":[{"name":"admin","is_superuser":false}]}' sgq); grep -q 'authentik has no superuser group' <<<"$o" && grep -q rc=1 <<<"$o" || fail_ "none: said so: $o"; pass
o=$(SGR='{"results":[{"name":"authentik Admins","is_superuser":true},{"name":"ops","is_superuser":true}]}' sgq)
grep -q 'authentik has 2 superuser groups (authentik Admins, ops) — which one is meant is not guessed' <<<"$o" && grep -q rc=1 <<<"$o" || fail_ "two: not guessed: $o"; pass
o=$(SGREF=1 SGR='' sgq); grep -q "authentik's groups are unreadable" <<<"$o" && grep -q rc=1 <<<"$o" || fail_ "unreadable: said so: $o"; pass

# ---- ak_card: AK_CARDS_QUIET=1 reports only a card that changed (access tier) ----
kc() { # kc QUIET URL -> ak_card's output for a card whose stored address is https://s.x, its group bound
    ( AK_CARDS_QUIET=$1 WIRE_DRY=0
      ak_api() { case "$1 $2" in "GET /policies/bindings/"*) echo '{"results":[{"group":"g1"}]}' ;; *) echo '{"pk":"a1"}' ;; esac; }
      ok() { echo "OK $*"; }; info() { :; }
      ak_card '{"results":[{"slug":"mediastack-app-s","pk":"a1","meta_launch_url":"https://s.x","provider":5,"group":"Media"}]}' \
          mediastack-app-s s "$2" d Media 5 g1 )
}
[[ -z "$(kc 1 https://s.x)" ]] || fail_ "quiet: an unchanged card says nothing: $(kc 1 https://s.x)"; pass
[[ "$(kc 1 https://new.x)" == "OK authentik: s card (Media)" ]] || fail_ "quiet: a changed card is reported: $(kc 1 https://new.x)"; pass
[[ "$(kc 0 https://s.x)" == "OK authentik: s card (Media)" ]] || fail_ "wire: every card reported, as before: $(kc 0 https://s.x)"; pass
: > "$T/aenv"

# ---- doctor: each gated app on a gate of its own; a card with a gate and no rule fails ----
gd() { # gd OUTPOST-PROVIDERS-JSON APPS-JSON UNBOUND-PK -> doctor's lines
    ( OP=$1 APPS=$2 UNB=$3
      authentik_gated() { echo sonarr; }; authentik_household() { echo navidrome; echo jellyfin; }
      svc_label() { [[ "$1:$2" == navidrome:mediastack.auth.group ]] && echo frontend; return 0; }
      ok() { echo "OK $*"; }; warn() { echo "WARN $*"; }; d_fail() { echo "FAIL $1"; }
      ak_api() { case "$1 $2" in
          "GET /outposts/instances/"*) echo "{\"results\":[{\"providers\":$OP}]}" ;;
          "GET /core/applications/"*) echo "$APPS" ;;
          "GET /policies/bindings/?target=$UNB") echo '{"results":[]}' ;;
          "GET /policies/bindings/"*) echo '{"results":[{"group":"g"}]}' ;;
        esac; }
      authentik_app_gates_doctor )
}
GA='{"results":[{"slug":"mediastack-app-sonarr","pk":"a-s","provider":50},{"slug":"mediastack-app-navidrome","pk":"a-n","provider":42},{"slug":"mediastack-app-jellyfin","pk":"a-j"}]}'
[[ "$(gd '[6,50,42]' "$GA" none)" == "OK authentik: every gated app has a gate of its own, its card saying who may open it" ]] \
    || fail_ "doctor: every gated app on its own gate: $(gd '[6,50,42]' "$GA" none)"; pass
[[ "$(gd '[6,50]' "$GA" none)" == "FAIL authentik: not on a gate of their own: navidrome" ]] \
    || fail_ "doctor: a gate missing from the outpost fails, named: $(gd '[6,50]' "$GA" none)"; pass
[[ "$(gd '[6,50,42]' "$GA" a-s | sed -n 1p)" == "FAIL authentik: cards with no rule: mediastack-app-sonarr" ]] \
    || fail_ "doctor: our card with a gate and no binding (open to everyone signed in) fails: $(gd '[6,50,42]' "$GA" a-s)"; pass
grep -q 'authentik_app_gates_doctor' <(awk '/^_doctor_accounts\(\)/,/^}/' services/authentik/authentik.sh) || fail_ "doctor runs the per-app gate check"; pass

echo "OK authentik: $checks checks"
