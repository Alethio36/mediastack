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
quick_env=$(grep -vE '^(MEILI_MASTER_KEY)=' "$T/w/.env")

# ---- full, fresh: Enter through every question gives what quick takes ----
clean; run '2\n\n\n\n\n\n\n1\n1\n\nTOKEN\n\n\n\n\n\n\n\n\n' --fresh || fail_ "full on a fresh .env runs"
[[ ! -s "$T/calls" ]] || fail_ "full ran what it may not: $(cat "$T/calls")"; pass
[[ "$(grep -vE '^(MEILI_MASTER_KEY)=' "$T/w/.env")" == "$quick_env" ]] \
    || fail_ "Enter through full = quick: $(diff <(echo "$quick_env") <(grep -vE '^MEILI_MASTER_KEY=' "$T/w/.env"))"; pass

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
           questions_hooks ) 2>&1 | paste -sd' ' -)
[[ "$order" == "T A J M" ]] || fail_ "platform first, then by name, enabled only: $order"; pass
bad=$(grep -nE '\b[a-z0-9_]+_questions\b' mediastack.sh lib/*.sh | grep -vE 'questions_hooks|questionnaire|^lib/questionnaire\.sh:[0-9]+:\s*#' || true)
[[ -z "$bad" ]] || fail_ "the core calls a service's questions by name: $bad"; pass
! grep -nE 'ask JF_SRVNAME|ask JF_LN|name asked on the real run' services/jellyfin/jellyfin.sh \
    || fail_ "wire asks Jellyfin's server or library names again"; pass

# ---- Traefik's questions: the token checked with Cloudflare, never on curl's command line ----
# shellcheck disable=SC2034  # read by traefik_questions
tq() { ( ENV_FILE=$T/t.env Q_MODE=${2:-full}; printf '%b' "$1" | traefik_questions ) > "$T/out" 2>&1; }
tv() { ENV_FILE=$T/t.env env_get "$1"; }
printf 'COMPOSE_PROFILES=traefik\n' > "$T/t.env"; : > "$T/curl.args"; : > "$T/curl.stdin"
tq 'media.example.com\nme@example.com\nBAD\n\nCFTOK\n\n\n\n' || fail_ "a refused token, then a live one, runs"
grep -q 'Cloudflare refused the token (Invalid API Token)' "$T/out" && grep -q 'this value is required' "$T/out" && [[ "$(tv CF_DNS_API_TOKEN)" == CFTOK ]] \
    || fail_ "a refused token is said, Enter cannot keep it, the next one counts: $(tv CF_DNS_API_TOKEN)"; pass
! grep -q 'CFTOK\|BAD' "$T/curl.args" && grep -q 'header = "Authorization: Bearer CFTOK"' "$T/curl.stdin" \
    || fail_ "the token reaches curl on stdin, never its command line: $(cat "$T/curl.args")"; pass
[[ "$(tv TRAEFIK_DASH_USER)" == admin && -n "$(tv TRAEFIK_DASH_PASSWORD)" ]] || fail_ "no portal: Enter at the dashboard login: admin, generated"; pass
printf 'COMPOSE_PROFILES=traefik,authentik\n' > "$T/t.env"
tq 'media.example.om\nme@example.com\nCFTOK\nmedia.example.com\n\n\n' || fail_ "a domain without a zone, then the right one, runs"
grep -q 'the token sees no Cloudflare zone for media.example.om (looked for: media.example.om, example.om)' "$T/out" && [[ "$(tv STACK_DOMAIN)" == media.example.com ]] \
    || fail_ "a typo in the domain is caught by its zone and asked again, the token kept: $(tv STACK_DOMAIN)"; pass
[[ -z "$(tv TRAEFIK_DASH_USER)" ]] || fail_ "with the portal the dashboard login is not asked"; pass
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

echo "OK questions: $checks checks"
