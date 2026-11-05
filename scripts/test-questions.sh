#!/usr/bin/env bash
# test-questions.sh — the questionnaire (lib/questionnaire.sh) asks and
# records, and does nothing else (docs/design-install.md):
#   * whole runs, quick and full, with sudo, docker, useradd, groupadd,
#     systemctl, rsync and mount on PATH as shims that log and fail: none is
#     called, and nothing but .env and local/state is written
#   * quick asks only what has no recommended answer; Enter through a full
#     run gives what quick takes; quick on a configured stack asks nothing and
#     keeps a schedule set to never
#   * with the portal: email is left as it is, the panel is recorded for
#     configure to install
#   * each enabled service's <name>_questions, found by name, the platform's
#     first; the core never names one, and wire no longer asks Jellyfin's names
#   * Traefik's: a refused token is said and pasted again, a domain with no
#     zone for the token asked again, Cloudflare unreachable stops loud; the
#     token reaches curl on stdin only
#   * its source names no sudo, Docker, users or folders
#   * exit codes: 3 without a terminal; configure stops on 130 (Ctrl-C reaches
#     both processes and configure survives to say so), passes 3 on, and stops
#     on anything else
#   * configure applies the folders: made, recorded with their mount, a move
#     done as answered, contents it never saw asked about again
# The entrypoint is sourced (minus main "$@"); the rendered catalogue is a
# small fixture, so no Docker is needed.
#
#   scripts/test-questions.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
lib=$(mktemp .test-questions.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"
set +e +E; trap - ERR   # each check reads its own status

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; [[ -f "$T/out" ]] && { echo "--- output:" >&2; cat "$T/out" >&2; }; exit 1; }

# what the questionnaire may not run: each logs its call and fails
mkdir -p "$T/bin"
for c in sudo docker useradd groupadd systemctl rsync mount; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\nexit 1\n' "$c" "$T" > "$T/bin/$c"; chmod +x "$T/bin/$c"
done
SHIMS=$T/bin:$PATH

render() { :; }
# NordVPN's and Cloudflare's APIs: CFTOK is a live token for the zone example.com
curl() {
    local in; in=$(cat); printf '%s\n' "$*" >> "$T/curl.args"; printf '%s\n' "$in" >> "$T/curl.stdin"
    [[ -z "${CURL_DOWN:-}" ]] || return 7
    case "$*" in
        *nordvpn*)        echo '{"nordlynx_private_key":"KEY"}' ;;
        *tokens/verify*)  if [[ "$in" == *"Bearer CFTOK\""* ]]; then echo '{"success":true,"result":{"status":"active"}}'
                          else echo '{"success":false,"errors":[{"code":1000,"message":"Invalid API Token"}]}'; fi ;;
        *zones?name=example.com*) echo '{"success":true,"result":[{"id":"z1","name":"example.com","status":"active"}]}' ;;
        *zones?name=*)    echo '{"success":true,"result":[]}' ;;
    esac
}
# shellcheck disable=SC2034  # read by the sourced entrypoint's svc_* helpers
RENDERED_JSON='{"services":{
  "gluetun":     {"labels":{"mediastack.managed":"true","mediastack.desc":"VPN"}},
  "qbittorrent": {"labels":{"mediastack.managed":"true","mediastack.desc":"torrents"},"depends_on":{"gluetun":{}}},
  "deluge":      {"labels":{"mediastack.managed":"true","mediastack.desc":"torrents"},"depends_on":{"gluetun":{}}},
  "olivetin":    {"labels":{"mediastack.managed":"true","mediastack.desc":"web panel","mediastack.installer":"frontdoor-install"}},
  "sonarr":      {"labels":{"mediastack.managed":"true","mediastack.desc":"series","mediastack.logins":"arr"}},
  "radarr":      {"labels":{"mediastack.managed":"true","mediastack.desc":"films","mediastack.logins":"arr"}},
  "prowlarr":    {"labels":{"mediastack.managed":"true","mediastack.desc":"indexers","mediastack.logins":"arr"}},
  "kavita":      {"labels":{"mediastack.managed":"true","mediastack.desc":"books"}},
  "jellyfin":    {"labels":{"mediastack.managed":"true","mediastack.desc":"media"}},
  "meilisearch": {"labels":{"mediastack.managed":"true","mediastack.desc":"index"}},
  "jellysearch": {"labels":{"mediastack.managed":"true","mediastack.desc":"search"},"depends_on":{"meilisearch":{}}},
  "seerr":       {"labels":{"mediastack.managed":"true","mediastack.desc":"requests"}},
  "traefik":     {"labels":{"mediastack.managed":"true","mediastack.desc":"https","mediastack.conflicts":"npm"}},
  "npm":         {"labels":{"mediastack.managed":"true","mediastack.desc":"gui proxy","mediastack.conflicts":"traefik"}},
  "authentik":   {"labels":{"mediastack.managed":"true","mediastack.desc":"portal","mediastack.conflicts":"wizarr"}},
  "wizarr":      {"labels":{"mediastack.managed":"true","mediastack.desc":"invites","mediastack.conflicts":"authentik"}}}}'
STD=gluetun,jellyfin,jellysearch,meilisearch,prowlarr,qbittorrent,radarr,seerr,sonarr

# run STDIN [--fresh] — a whole questionnaire in its own directory: .env (a
# fresh one from .env.example unless one is there), local/state, the shims
run() {
    [[ -f "$T/w/.env" ]] || { mkdir -p "$T/w"; cp .env.example "$T/w/.env"; }
    : > "$T/calls"
    # shellcheck disable=SC2034  # read by the questionnaire
    ( ENV_FILE=$T/w/.env STATE_DIR=$T/w/local/state LOCAL_DIR=$T/w/local FSTAB=$T/fstab PATH=$SHIMS
      printf '%b' "$1" | questionnaire_run "${@:2}" ) > "$T/out" 2>&1
}
envv() { ENV_FILE=$T/w/.env env_get "$1"; }
clean() { rm -rf "$T/w"; }
written() { (cd "$T/w" && find . -type f | sort | tr '\n' ' '); }
: > "$T/fstab"

# ---- quick, fresh: the services, sign-in and the VPN — nothing else ----
clean; run '1\n1\n1\n\nTOKEN\n' --fresh || fail_ "quick on a fresh .env runs"
[[ ! -s "$T/calls" ]] || fail_ "quick ran what it may not: $(cat "$T/calls")"; pass
[[ "$(written)" == "./.env ./local/state/roots " ]] || fail_ "only .env and local/state are written: $(written)"; pass
[[ "$(envv COMPOSE_PROFILES | tr ',' '\n' | sort | paste -sd, -)" == "$STD" ]] || fail_ "standard: $(envv COMPOSE_PROFILES)"; pass
[[ "$(envv WIREGUARD_PRIVATE_KEY)" == KEY && "$(envv VPN_PROVIDER)" == nordvpn ]] || fail_ "the VPN key fetched"; pass
[[ "$(envv UPDATE_SCHEDULE)" == "Tue 04:00" && "$(envv BACKUP_SCHEDULE)" == "*-*-* 05:00" ]] \
    || fail_ "the recommended schedules: $(envv UPDATE_SCHEDULE) / $(envv BACKUP_SCHEDULE)"; pass
grep -q 'Timezone: .* (recommended)' "$T/out" && grep -q 'Updates: .* (recommended)' "$T/out" \
    || fail_ "what quick took is said"; pass
[[ "$(grep -c "^[A-Z_]*_ROOT	$SCRIPT_DIR/[a-z]*	$" "$T/w/local/state/roots")" == 5 ]] \
    || fail_ "every folder recorded for configure, none in .env yet: $(cat "$T/w/local/state/roots")"; pass
grep -qx 'CONFIG_ROOT=./config' "$T/w/.env" || fail_ "a folder answer is not written to .env by the questions"; pass
# generated values differ run to run: compared by their presence
gen_keys='^(MEILI_MASTER_KEY|[A-Z_]*_PASSWORD)='
quick_env=$(sed -E "s/$gen_keys.+/\1<generated>/" "$T/w/.env")

# ---- full, fresh: Enter through every question gives what quick takes ----
clean; run '2\n\n\n\n\n\n\n1\n1\n\nTOKEN\n\n\n\n\n\n\n\n\n\n\n' --fresh || fail_ "full on a fresh .env runs"
[[ ! -s "$T/calls" ]] || fail_ "full ran what it may not: $(cat "$T/calls")"; pass
[[ "$(sed -E "s/$gen_keys.+/\1<generated>/" "$T/w/.env")" == "$quick_env" ]] \
    || fail_ "Enter through full = quick: $(diff <(echo "$quick_env") <(sed -E "s/$gen_keys.+/\1<generated>/" "$T/w/.env"))"; pass

# ---- quick on a configured stack: nothing asked, a "never" kept ----
sed -i 's/^UPDATE_SCHEDULE=.*/UPDATE_SCHEDULE=/' "$T/w/.env"; before=$(cat "$T/w/.env")
run '1\n' || fail_ "quick re-run asks nothing beyond the mode"
[[ "$(cat "$T/w/.env")" == "$before" ]] || fail_ "quick re-run changes nothing: $(diff <(echo "$before") "$T/w/.env")"; pass
grep -q 'Services: keep the current' "$T/out" && grep -q 'VPN: keep nordvpn' "$T/out" || fail_ "and says what it kept"; pass

# ---- quick with the portal: email left alone, the panel recorded ----
clean; run '1\n2\n3\n\nTOKEN\nmedia.example.com\nme@example.com\nCFTOK\n' --fresh || fail_ "quick, everything, the portal runs"
[[ ! -s "$T/calls" ]] || fail_ "ran what it may not: $(cat "$T/calls")"; pass
[[ ",$(envv COMPOSE_PROFILES)," == *,traefik,* && ",$(envv COMPOSE_PROFILES)," == *,authentik,* && ",$(envv COMPOSE_PROFILES)," != *,npm,* \
   && ",$(envv COMPOSE_PROFILES)," != *,deluge,* ]] || fail_ "one client, traefik for the portal: $(envv COMPOSE_PROFILES)"; pass
[[ "$(cat "$T/w/local/state/$PANEL_STATE")" == yes && -z "$(envv SMTP_HOST)" ]] && grep -q 'Email: not set' "$T/out" \
    || fail_ "the panel recorded, email left as it is"; pass
[[ "$(envv PORTAL_TITLE)" == Mediastack ]] || fail_ "the portal's name taken: $(envv PORTAL_TITLE)"; pass
[[ "$(envv STACK_DOMAIN)" == media.example.com && "$(envv CF_DNS_API_TOKEN)" == CFTOK && "$(envv ACME_ENV)" == production ]] \
    || fail_ "Traefik's answers recorded, production certificates taken: $(grep -E '^(STACK_DOMAIN|ACME_ENV)=' "$T/w/.env")"; pass
grep -q 'the token is live and holds the zone example.com' "$T/out" || fail_ "the token checked with Cloudflare when pasted"; pass

# ---- each enabled service's hook, the platform's first, found by name ----
order=$( ( ENV_FILE=$T/w/.env
           traefik_questions() { echo T; }; authentik_questions() { echo A; }; jellyfin_questions() { echo J; }; meilisearch_questions() { echo M; }
           svc_hooks questions ) 2>&1 | paste -sd' ' -)
[[ "$order" == "T A J M" ]] || fail_ "platform first, then by name, enabled only: $order"; pass
# a <service>_questions / _logins / _summary named anywhere in the core (comments aside)
bad=""
for f in $(grep -hvE '^\s*#' mediastack.sh lib/*.sh | grep -oE '\b[a-z0-9_]+_(questions|logins|summary)\b' | sort -u); do
    stem=${f%_*}
    if [[ -d "services/${stem//_/-}" || -d "services/_$stem" ]]; then bad+="$f "; fi
done
[[ -z "$bad" ]] || fail_ "the core calls a service's questions, logins or summary by name: $bad"; pass
! grep -nE 'ask JF_SRVNAME|ask JF_LN|name asked on the real run' services/jellyfin/jellyfin.sh \
    || fail_ "wire asks Jellyfin's server or library names again"; pass

# ---- Traefik's questions: the token checked with Cloudflare, never on curl's command line ----
# shellcheck disable=SC2034  # read by traefik_questions
tq() { ( ENV_FILE=$T/t.env Q_MODE=${2:-full}; printf '%b' "$1" | traefik_questions ) > "$T/out" 2>&1; }
tv() { ENV_FILE=$T/t.env env_get "$1"; }
printf 'COMPOSE_PROFILES=traefik\n' > "$T/t.env"; : > "$T/curl.args"; : > "$T/curl.stdin"
tq 'media.example.com\nme@example.com\nBAD\n\nCFTOK\n\n' || fail_ "a refused token, then a live one, runs"
grep -q 'Cloudflare refused the token (Invalid API Token)' "$T/out" && grep -q 'this value is required' "$T/out" && [[ "$(tv CF_DNS_API_TOKEN)" == CFTOK ]] \
    || fail_ "a refused token is said, Enter cannot keep it, the next one counts: $(tv CF_DNS_API_TOKEN)"; pass
! grep -q 'CFTOK\|BAD' "$T/curl.args" && grep -q 'header = "Authorization: Bearer CFTOK"' "$T/curl.stdin" \
    || fail_ "the token reaches curl on stdin, never its command line: $(cat "$T/curl.args")"; pass
printf 'COMPOSE_PROFILES=traefik,authentik\n' > "$T/t.env"
tq 'media.example.om\nme@example.com\nCFTOK\nmedia.example.com\n\n\n' || fail_ "a domain without a zone, then the right one, runs"
grep -q 'the token sees no Cloudflare zone for media.example.om (looked for: media.example.om, example.om)' "$T/out" && [[ "$(tv STACK_DOMAIN)" == media.example.com ]] \
    || fail_ "a typo in the domain is caught by its zone and asked again, the token kept: $(tv STACK_DOMAIN)"; pass
[[ -z "$(tv TRAEFIK_DASH_USER)" ]] || fail_ "Traefik's questions leave the dashboard's login to the logins"; pass
before=$(cat "$T/t.env"); tq '' quick || fail_ "quick with Traefik answered asks nothing"
[[ "$(cat "$T/t.env")" == "$before" ]] && grep -q 'HTTPS: keep media.example.com' "$T/out" || fail_ "and keeps it, saying so"; pass
printf 'COMPOSE_PROFILES=traefik\n' > "$T/t.env"
( CURL_DOWN=1; tq 'media.example.com\nme@example.com\nCFTOK\n' ) && fail_ "Cloudflare unreachable stops the questions"
grep -q "Could not reach Cloudflare's API" "$T/out" && [[ -z "$(tv CF_DNS_API_TOKEN)" ]] || fail_ "loud, nothing recorded"; pass

# ---- its source names no sudo, Docker, users or folders ----
# a command where a command goes (a line's start, after ; & | ( or $( ); the one
# prose line that starts with one is root_problem's advice to mount a share
bad=$(grep -nE '(^|[;&|(]|\$\()[[:space:]]*(sudo|DC|docker|useradd|groupadd|chown|chmod|mkdir|rsync|provision|cmd_[a-z_]+_install)\b' lib/questionnaire.sh \
      | grep -vF "sudo mount '\$val'   (then re-enter the path here)" || true)
[[ -z "$bad" ]] || fail_ "the questionnaire acts instead of asking: $bad"; pass

# ---- exit codes ----
( cmd_questionnaire ) </dev/null > "$T/out" 2>&1; rc=$?
[[ "$rc" == 3 ]] && grep -q 'configure asks questions — run it in a terminal' "$T/out" || fail_ "no terminal: exit 3 ($rc)"; pass
mkdir -p "$T/fake"
child() { printf '#!/usr/bin/env bash\n%s\n' "$1" > "$T/fake/mediastack.sh"; chmod +x "$T/fake/mediastack.sh"; }
asked() { setsid -w bash -c 'source "$1"; set +e +E; trap - ERR; SCRIPT_DIR=$2; questionnaire_ask; echo CONTINUED' _ "$lib" "$T/fake" > "$T/out" 2>&1; }
child 'kill -INT 0; sleep 2'   # Ctrl-C: the whole process group, configure included
asked; rc=$?
[[ "$rc" == 130 ]] && grep -q 'Cancelled — nothing was applied' "$T/out" && ! grep -q CONTINUED "$T/out" \
    || fail_ "Ctrl-C: configure survives to say so, then stops with 130 ($rc)"; pass
child 'exit 3'; asked; rc=$?
[[ "$rc" == 3 ]] && ! grep -q CONTINUED "$T/out" || fail_ "no terminal: configure stops with 3 ($rc)"; pass
child 'exit 1'; asked; rc=$?
[[ "$rc" == 1 ]] && grep -q 'the questions stopped (exit 1, above) — nothing was applied' "$T/out" && ! grep -q CONTINUED "$T/out" \
    || fail_ "a failed question: configure stops ($rc)"; pass
child 'exit 0'; asked; rc=$?
[[ "$rc" == 0 ]] && grep -q CONTINUED "$T/out" || fail_ "every question answered: configure carries on ($rc)"; pass

# ---- configure applies the folders ----
sudo() { "$@"; }   # as this user, on the test's folders
# shellcheck disable=SC2034  # read by root_move_apply
c_inspect_all() { INSPECT_JSON='[]'; }
mkdir -p "$T/a/old" "$T/a/keep"; echo x > "$T/a/old/file"; echo y > "$T/a/keep/file"
# shellcheck disable=SC2034  # read by state_set and roots_apply
apply() { ( ENV_FILE=$T/a/.env STATE_DIR=$T/a/state LOCAL_DIR=$T/a; state_set "$ROOTS_STATE" "$1"; roots_apply ) > "$T/out" 2>&1; }
printf 'CONFIG_ROOT=%s\nCACHE_ROOT=%s\n' "$T/a/old" "$T/a/keep" > "$T/a/.env"
apply "CONFIG_ROOT	$T/a/new	move" || fail_ "a move applies"
[[ -f "$T/a/new/file" && ! -e "$T/a/old/file" ]] && grep -qx "CONFIG_ROOT=$T/a/new" "$T/a/.env" && grep -q '^CONFIG_ROOT_SOURCE=.' "$T/a/.env" \
    || fail_ "moved, recorded with its mount: $(cat "$T/a/.env")"; pass
[[ ! -e "$T/a/state/$ROOTS_STATE" ]] || fail_ "the answers are gone once applied"; pass
apply "CACHE_ROOT	$T/a/other	" && fail_ "contents the questions never saw stop configure"
grep -qx "CACHE_ROOT=$T/a/keep" "$T/a/.env" && grep -q 'configure did not see when it asked' "$T/out" \
    || fail_ "and leave that folder as it was: $(cat "$T/a/.env")"; pass
apply "CACHE_ROOT	$T/a/other	leave" || fail_ "leave applies"
grep -qx "CACHE_ROOT=$T/a/other" "$T/a/.env" && grep -qx "CACHE_ROOT_PREVIOUS=$T/a/keep" "$T/a/.env" && [[ -f "$T/a/keep/file" ]] \
    || fail_ "leave: the new folder, the old one noted for doctor: $(cat "$T/a/.env")"; pass

# ---- the stack's own logins (lib/logins.sh) ----
# quick, standard (the first run above): every login of the enabled services, generated, one username
clean; run '1\n1\n1\n\nTOKEN\n' --fresh || fail_ "quick, fresh, for the logins"
for k in ARR JELLYFIN_ADMIN QBITTORRENT; do
    [[ "$(envv "${k}_USER")" == admin && "$(envv "${k}_PASSWORD")" =~ ^[A-Za-z0-9]{16}$ ]] || fail_ "$k: admin and a generated password ($(envv "${k}_USER"))"
done; pass
[[ "$(printf '%s\n' "$(envv ARR_PASSWORD)" "$(envv JELLYFIN_ADMIN_PASSWORD)" "$(envv QBITTORRENT_PASSWORD)" | sort -u | wc -l)" == 3 ]] \
    || fail_ "generated: a different password for each"; pass
grep -q 'Logins: admin, passwords generated (recommended)' "$T/out" || fail_ "quick says what it took"; pass
before=$(cat "$T/w/.env"); run '2\n\n\n\n\n\n\n0\n0\n\nn\n\n\n\n\n\n\n\n' || fail_ "full re-run, everything kept"
[[ "$(cat "$T/w/.env")" == "$before" ]] && ! grep -q 'Username for all of them' "$T/out" || fail_ "every login made: no logins question, nothing changed"; pass
# full, unified: one typed password for all; a short one and a mismatch refused first
clean; run '2\n\n\n\n\n\n\n1\n1\n\nTOKEN\n\n\nab\nops\n2\nshort\nshort\nAbcdefghijkl1\nAbcdefghijkX\nAbcdefghijkl1\nAbcdefghijkl1\n\n\n\n\n\n\n' --fresh || fail_ "full, unified"
grep -q "'ab' won't do: qBittorrent's WebUI needs at least 3 characters" "$T/out" && grep -q "That password won't do: at least 12 characters" "$T/out" \
    && grep -q 'Passwords do not match' "$T/out" || fail_ "a name and a password the logins refuse are said, and asked again"; pass
[[ "$(envv ARR_USER)/$(envv QBITTORRENT_USER)/$(envv JELLYFIN_ADMIN_USER)" == ops/ops/ops && "$(envv STACK_LOGINS)" == unified ]] \
    && [[ "$(envv ARR_PASSWORD)$(envv QBITTORRENT_PASSWORD)$(envv JELLYFIN_ADMIN_PASSWORD)" == Abcdefghijkl1Abcdefghijkl1Abcdefghijkl1 ]] \
    || fail_ "unified: one name, one password: $(grep -E '_(USER|PASSWORD)=' "$T/w/.env" | paste -sd' ')"; pass
login_problem() { ( ENV_FILE=$T/w/.env; login_pass_problem "$@" ); }
[[ -n "$(login_problem 'Abc defghijkl1')" && -n "$(login_problem 'Abcdefghij$kl1')" && -z "$(login_problem 'Abcdefghijkl1')" ]] \
    || fail_ "a typed password: no whitespace, no \$"; pass
# a service enabled later is filled the way configure made the others, without asking
sed -i 's/^COMPOSE_PROFILES=.*/&,kavita/' "$T/w/.env"
( ENV_FILE=$T/w/.env; logins_fill ) </dev/null > "$T/out" 2>&1 || fail_ "unified: a later login filled without asking"
[[ "$(envv KAVITA_ADMIN_USER)/$(envv KAVITA_ADMIN_PASSWORD)" == ops/Abcdefghijkl1 ]] || fail_ "with the shared name and password"; pass
[[ -n "$(login_problem "$(printf 'A%.0s' {1..300})" KAVITA_ADMIN_PASSWORD)" ]] || fail_ "Kavita's own limit (256) holds"; pass
[[ "$( ENV_FILE=$T/w/.env; logins_reserved )" == ops ]] || fail_ "the names marked reserve, once: $( ENV_FILE=$T/w/.env; logins_reserved )"; pass
sed -i 's/^KAVITA_ADMIN_PASSWORD=.*/KAVITA_ADMIN_PASSWORD=/; s/^ARR_PASSWORD=.*/ARR_PASSWORD=Different12345/' "$T/w/.env"
( ENV_FILE=$T/w/.env; logins_fill ) </dev/null > "$T/out" 2>&1 && fail_ "unified, passwords that differ: no one password to share"
grep -q 'set-credentials all' "$T/out" || fail_ "and it says how to make them one"; pass
sed -i 's/^STACK_LOGINS=.*/STACK_LOGINS=each/' "$T/w/.env"
# shellcheck disable=SC2034  # read by logins_fill
( ENV_FILE=$T/w/.env; logins_fill ) </dev/null > "$T/out" 2>&1 && fail_ "each: a missing login is never made up"
grep -q 'STACK_LOGINS=each types every one — run: ./mediastack.sh configure' "$T/out" || fail_ "it says configure asks it"; pass
! grep -nE '\bask_secret\b' services/*/*.sh || fail_ "a service asks for a password itself — a login is declared (<name>_logins) and recorded by configure"; pass
awk '/^provision\(\)/,/^}/' mediastack.sh | grep -q '^ *logins_fill' || fail_ "provision (configure, up, enable) fills a login enabled since configure"; pass
# every password the schema knows is a stack login some service declares — a
# missing hook would drop its login silently — or one of these, which are not
NOT_LOGINS="AUTHENTIK_DB_PASSWORD AUTHENTIK_ADMIN_PASSWORD AUTHENTIK_LDAP_BIND_PASSWORD SMTP_PASSWORD"   # a database's, the portal's own admin, its LDAP bind, the mail server's
declared=$(for f in $(declare -F | awk '{print $3}' | grep '_logins$'); do "$f"; done | cut -f3)
bad=""
for k in $(cut -f1 services/*/env.tsv lib/env.schema.tsv | grep -E '_PASSWORD$'); do
    grep -qx "$k" <<<"$declared" || [[ " $NOT_LOGINS " == *" $k "* ]] || bad+="$k "
done
[[ -z "$bad" ]] || fail_ "a password no service declares as a login (add its <name>_logins, or say why it is not one): $bad"; pass

echo "OK questions: $checks checks"
