#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-answers.sh — configure's answers file (lib/answers.sh, docs/design-answers.md):
#   * the file itself: KEY=value lines only, keys configure asks, each value
#     its type (never/auto for an empty one), 0600 — every problem listed at
#     once, nothing asked, .env and local/state untouched
#   * the same answers typed and written give a byte-identical .env and
#     local/state (generated passwords aside)
#   * with no terminal, every answer that would be asked is missing; with one,
#     only the gaps are asked
#   * a re-run: a blank keeps what is set, only what is written changes
#   * refused: a service SIGNIN picks or its own command sets up, both of a
#     conflicting pair, a download client that does not run, a token for
#     another provider, full mode with no one to ask, a password for the wrong
#     mode, a folder that moves with its contents, a token Cloudflare refuses
#   * the flags (--domain, --services, --signin) are answers too, over the
#     file's; START answers configure's closing question; with answers and no
#     terminal, sudo that wants a password is refused before anything starts
#   * the check pass asks nothing: a question without its guard stops loud
# The entrypoint is sourced (minus main "$@"); the catalogue is a fixture.
#
#   scripts/test-answers.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
lib=$(mktemp .test-answers.XXXXXX)
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
  "gluetun":     {"labels":{"mediastack.managed":"true","mediastack.preset":"standard","mediastack.desc":"VPN"}},
  "qbittorrent": {"labels":{"mediastack.managed":"true","mediastack.preset":"standard","mediastack.desc":"torrents"},"depends_on":{"gluetun":{}}},
  "deluge":      {"labels":{"mediastack.managed":"true","mediastack.desc":"torrents"},"depends_on":{"gluetun":{}}},
  "olivetin":    {"labels":{"mediastack.managed":"true","mediastack.desc":"web panel","mediastack.installer":"frontdoor-install"}},
  "sonarr":      {"labels":{"mediastack.managed":"true","mediastack.preset":"standard","mediastack.desc":"series","mediastack.logins":"arr"}},
  "radarr":      {"labels":{"mediastack.managed":"true","mediastack.preset":"standard","mediastack.desc":"films","mediastack.logins":"arr"}},
  "prowlarr":    {"labels":{"mediastack.managed":"true","mediastack.preset":"standard","mediastack.desc":"indexers","mediastack.logins":"arr"}},
  "kavita":      {"labels":{"mediastack.managed":"true","mediastack.desc":"books"}},
  "jellyfin":    {"labels":{"mediastack.managed":"true","mediastack.preset":"standard","mediastack.desc":"media"}},
  "meilisearch": {"labels":{"mediastack.managed":"true","mediastack.preset":"standard","mediastack.desc":"index"}},
  "jellysearch": {"labels":{"mediastack.managed":"true","mediastack.preset":"standard","mediastack.desc":"search"},"depends_on":{"meilisearch":{}}},
  "seerr":       {"labels":{"mediastack.managed":"true","mediastack.preset":"standard","mediastack.desc":"requests"}},
  "traefik":     {"labels":{"mediastack.managed":"true","mediastack.desc":"https","mediastack.conflicts":"npm"}},
  "npm":         {"labels":{"mediastack.managed":"true","mediastack.desc":"gui proxy","mediastack.conflicts":"traefik"}},
  "authentik":   {"labels":{"mediastack.managed":"true","mediastack.desc":"portal","mediastack.conflicts":"wizarr"}},
  "wizarr":      {"labels":{"mediastack.managed":"true","mediastack.desc":"invites","mediastack.conflicts":"authentik"}}}}'
STD=gluetun,jellyfin,jellysearch,meilisearch,prowlarr,qbittorrent,radarr,seerr,sonarr
: > "$T/fstab"

# a .env in its own directory, fresh from .env.example
fresh() { rm -rf "$T/w"; mkdir -p "$T/w/local/state"; cp .env.example "$T/w/.env"; }
# typed STDIN [ARGS] — the questionnaire asked; filed FILE STDIN [ARGS] — the answers file (no terminal unless Q_TERMINAL)
typed() { ( ENV_FILE=$T/w/.env STATE_DIR=$T/w/local/state LOCAL_DIR=$T/w/local FSTAB=$T/fstab PATH=$SHIMS
            printf '%b' "$1" | questionnaire_run "${@:2}" ) > "$T/out" 2>&1; }
filed() { ( ENV_FILE=$T/w/.env STATE_DIR=$T/w/local/state LOCAL_DIR=$T/w/local FSTAB=$T/fstab PATH=$SHIMS
            printf '%b' "$2" | questionnaire_answers_run --answers "$1" -- "${@:3}" ) > "$T/out" 2>&1; }
answers() { printf '%b' "$1" > "$T/a.env"; chmod 600 "$T/a.env"; }   # answers LINES — the file, 0600
masked() { sed -E 's/^([A-Z_]*(PASSWORD|MASTER_KEY))=.+/\1=<generated>/' "$1"; }
snapshot() { masked "$T/w/.env" > "$1.env"; cp -r "$T/w/local/state" "$1.state"; }
envv() { ENV_FILE=$T/w/.env env_get "$1"; }
problems() { grep -c '^  \* ' "$T/out" || true; }
has() { grep -qF -- "$1" "$T/out"; }

# ---- the file itself: every problem at once, nothing asked or written ----
fresh; cp "$T/w/.env" "$T/before.env"
answers 'FOO=1\nCOMPOSE_PROFILES=sonarr\nnot a line\nTZ=Nowhere/Land\nSIGNIN="none"\nSIGNIN=none\nUPDATE_SCHEDULE=never\n\n# a comment\nVPN_SERVER_COUNTRIES=\n'
filed "$T/a.env" '' --fresh; rc=$?
(( rc == 4 )) || fail_ "a file with problems: exit 4 (got $rc)"; pass
has "FOO is no question configure asks" && has "COMPOSE_PROFILES is no question configure asks" && has "line 3 is not KEY=value" \
    && has "TZ='Nowhere/Land' is not a time zone" && has "SIGNIN='\"none\"' is quoted" && has "SIGNIN is answered twice" \
    || fail_ "each problem with the file is named"; pass
[[ "$(problems)" == 6 ]] || fail_ "all six listed at once, the word 'never' and a blank are no problem: $(problems)"; pass
cmp -s "$T/w/.env" "$T/before.env" && [[ -z "$(ls -A "$T/w/local/state")" ]] || fail_ "nothing written"; pass
[[ ! -s "$T/calls" ]] || fail_ "nothing run: $(cat "$T/calls")"; pass
answers 'SIGNIN=none\n'; chmod 644 "$T/a.env"
filed "$T/a.env" '' --fresh; [[ $? == 4 ]] && has "can be read by others (644)" || fail_ "a file others can read is refused"; pass
( ANSWERS_PASS=check; ANSWERS_PROBLEMS=$T/p; ANSWER=(); : > "$T/p"; answers 'UPDATE_SCHEDULE=never\nVPN_SERVER_COUNTRIES=auto\n'
  answers_load "$T/a.env"; [[ ! -s "$T/p" ]] && answer UPDATE_SCHEDULE && [[ -z "$REPLY_VAL" ]] && answer VPN_SERVER_COUNTRIES && [[ -z "$REPLY_VAL" ]] ) \
    || fail_ "never and auto are written answers for an empty value"; pass

# ---- yes or no: yes, no, y, n, true, false in any case, kept in the form the key keeps ----
( ANSWERS_PASS=check; ANSWERS_PROBLEMS=$T/p; ANSWER=(); : > "$T/p"
  answers 'ENABLE_SONARR=Y\nENABLE_RADARR=no\nPANEL=TRUE\nSTART=n\nSMTP_STARTTLS=yes\nSMTP_TLS=False\n'; answers_load "$T/a.env"
  [[ ! -s "$T/p" && "${ANSWER[ENABLE_SONARR]} ${ANSWER[ENABLE_RADARR]} ${ANSWER[PANEL]} ${ANSWER[START]} ${ANSWER[SMTP_STARTTLS]} ${ANSWER[SMTP_TLS]}" == "yes no yes no true false" ]] \
    || { cat "$T/p"; exit 1; } ) || fail_ "every yes/no word, recorded as its key keeps it"; pass
( ANSWERS_PASS=check; ANSWERS_PROBLEMS=$T/p; ANSWER=(); : > "$T/p"
  answers 'PANEL=on\nSMTP_TLS=1\n'; answers_load "$T/a.env"
  grep -qF "PANEL='on' is not yes or no (yes, no, y, n, true, false)" "$T/p" && grep -qF "SMTP_TLS='1' is not yes or no" "$T/p" \
    && [[ -z "${ANSWER[PANEL]+set}" ]] ) || fail_ "on, 1 and the like are refused, named, never stored"; pass

# ---- no terminal: compose prints no per-layer progress ----
dc_args() { ( sudo() { echo "$*" > "$T/dc"; }; user_compose_files() { USER_FILES=(); }; leak_gate_guards() { :; }; stack_down_since() { :; }
              DC "$@" > /dev/null; cat "$T/dc" ) }
[[ "$(dc_args up -d sonarr)" == *" up --quiet-pull -d sonarr" ]] || fail_ "up, no terminal: --quiet-pull — $(dc_args up -d sonarr)"; pass
[[ "$(dc_args pull sonarr)" == *" pull --quiet sonarr" ]] || fail_ "pull, no terminal: --quiet — $(dc_args pull sonarr)"; pass
[[ "$(dc_args ps)" == *" ps" ]] || fail_ "anything else is passed as given"; pass

# ---- a written path is read as a typed one: ~ is your home, a relative one is the repo's ----
( ANSWERS_PASS=check; ANSWERS_PROBLEMS=$T/p; ANSWER=(); : > "$T/p"
  answers 'TLS_CERT_FILE=~/certs/fullchain.pem\nTLS_KEY_FILE=certs/privkey.pem\nDATA_ROOT=~/media\n'; answers_load "$T/a.env"
  [[ ! -s "$T/p" && "${ANSWER[TLS_CERT_FILE]}" == "$HOME/certs/fullchain.pem" && "${ANSWER[TLS_KEY_FILE]}" == "$PWD/certs/privkey.pem" \
     && "${ANSWER[DATA_ROOT]}" == "$HOME/media" ]] || { cat "$T/p"; declare -p ANSWER; exit 1; } ) \
    || fail_ "a written path is expanded as a typed one (~ = home, relative = the repo's)"; pass

# ---- typed and written: the same .env and local/state ----
fresh; typed '1\n1\n1\n\nTOKEN\n' --fresh || fail_ "typed quick, fresh"
snapshot "$T/typed"
fresh; answers 'ENABLE_SONARR=y\nSIGNIN=none\nNORDVPN_TOKEN=TOKEN\n'
filed "$T/a.env" '' --fresh || fail_ "the same answers, written, with no terminal: $(cat "$T/out")"
snapshot "$T/filed"
diff "$T/typed.env" "$T/filed.env" >&2 && diff -r "$T/typed.state" "$T/filed.state" >&2 || fail_ "typed and written answers give the same .env and local/state"; pass
has "Services: " && has "Accounts: none (from the answers file)" && ! has "== Accounts" || fail_ "written answers are said, not asked"; pass
[[ ! -s "$T/calls" ]] || fail_ "nothing run: $(cat "$T/calls")"; pass

# ---- with no terminal, what would be asked is missing; with one, only the gaps ----
fresh; cp "$T/w/.env" "$T/before.env"; answers 'ENABLE_SONARR=y\n'
filed "$T/a.env" '' --fresh; [[ $? == 4 ]] || fail_ "missing answers with no terminal: exit 4"
has "Sign-in is not answered — set SIGNIN" && has "VPN is not answered" && [[ "$(problems)" == 2 ]] || fail_ "each missing answer named, nothing else: $(cat "$T/out")"; pass
cmp -s "$T/w/.env" "$T/before.env" || fail_ "missing answers: nothing written"; pass
fresh; answers 'ENABLE_SONARR=y\nSIGNIN=none\n'
Q_TERMINAL=1 filed "$T/a.env" '\nTOKEN\n' --fresh || fail_ "a partial file with a terminal: $(cat "$T/out")"
snapshot "$T/partial"
diff "$T/typed.env" "$T/partial.env" >&2 || fail_ "only the gaps asked — the same .env"; pass
! has "== Accounts" && has "NordVPN token" || fail_ "the file's answers are not asked, the gaps are"; pass

# ---- a re-run: a blank keeps what is set ----
fresh; answers 'ENABLE_SONARR=y\nSIGNIN=none\nNORDVPN_TOKEN=TOKEN\n'; filed "$T/a.env" '' --fresh || fail_ "first run"
cp "$T/w/.env" "$T/run1.env"; answers 'TZ=Europe/Berlin\n'
filed "$T/a.env" '' || fail_ "re-run with one answer: $(cat "$T/out")"
[[ "$(diff "$T/run1.env" "$T/w/.env" | grep -c '^[<>]')" == 2 && "$(envv TZ)" == Europe/Berlin ]] || fail_ "only TZ changed: $(diff "$T/run1.env" "$T/w/.env")"; pass

# ---- refused answers ----
refused() { # refused LINES WHAT... — each WHAT is in the list, and nothing was written
    fresh; cp "$T/w/.env" "$T/before.env"; answers "$1"; shift
    filed "$T/a.env" '' --fresh; [[ $? == 4 ]] || fail_ "refused: exit 4 — $(cat "$T/out")"
    local w; for w in "$@"; do has "$w" || fail_ "refused: '$w' named — $(cat "$T/out")"; done
    cmp -s "$T/w/.env" "$T/before.env" || fail_ "refused: nothing written"
}
refused 'SIGNIN=none\nNORDVPN_TOKEN=TOKEN\nENABLE_WIZARR=y\nENABLE_OLIVETIN=y\n' \
    "ENABLE_OLIVETIN: no service is switched on that way" "ENABLE_WIZARR: no service is switched on that way"; pass
refused 'SIGNIN=none\nNORDVPN_TOKEN=TOKEN\nENABLE_TRAEFIK=y\nENABLE_NPM=y\nSTACK_DOMAIN=media.example.com\nACME_EMAIL=a@b.co\nCF_DNS_API_TOKEN=CFTOK\n' \
    "npm and traefik cannot both run"; pass
refused 'SIGNIN=none\nNORDVPN_TOKEN=TOKEN\nDOWNLOAD_CLIENT=deluge\n' "DOWNLOAD_CLIENT=deluge is not among the download clients that run"; pass
refused 'SIGNIN=none\nENABLE_SONARR=y\nVPN_PROVIDER=mullvad\nNORDVPN_TOKEN=TOKEN\n' "NORDVPN_TOKEN is NordVPN's"; pass
refused 'SIGNIN=none\nENABLE_SONARR=y\nVPN_PROVIDER=mullvad\n' "the VPN has no key — set WIREGUARD_PRIVATE_KEY"; pass
refused 'CONFIGURE_MODE=full\nSIGNIN=none\nNORDVPN_TOKEN=TOKEN\n' "CONFIGURE_MODE=full asks every question — it needs a terminal"; pass
refused 'SIGNIN=none\nNORDVPN_TOKEN=TOKEN\nSTACK_PASSWORD=Sh4red-pass-1\n' "STACK_PASSWORD is the one password of STACK_LOGINS=unified"; pass
refused 'SIGNIN=authentik\nNORDVPN_TOKEN=TOKEN\nSTACK_DOMAIN=media.example.com\nACME_EMAIL=a@b.co\nCF_DNS_API_TOKEN=WRONG\n' \
    "CF_DNS_API_TOKEN: Cloudflare refused the token"; pass
# a folder that moves with its contents is configure's question
fresh; mkdir -p "$T/olddata"; touch "$T/olddata/movie.mkv"; sed -i "s|^DATA_ROOT=.*|DATA_ROOT=$T/olddata|" "$T/w/.env"
answers "SIGNIN=none\nNORDVPN_TOKEN=TOKEN\nENABLE_SONARR=y\nDATA_ROOT=$T/newdata\n"
filed "$T/a.env" ''; [[ $? == 4 ]] && has "DATA_ROOT moves ($T/olddata -> $T/newdata) and $T/olddata is not empty" || fail_ "a folder moving with its contents: $(cat "$T/out")"; pass

# ---- every hook takes its written answer ----
RENDERED_JSON=$(jq '.services.apprise = {labels:{"mediastack.managed":"true","mediastack.desc":"hub"}}
                  | .services.cloudflared = {labels:{"mediastack.managed":"true","mediastack.desc":"tunnel"}}' <<<"$RENDERED_JSON")
all='ENABLE_SONARR=y\nENABLE_TRAEFIK=y\nENABLE_APPRISE=y\nENABLE_CLOUDFLARED=y\nSIGNIN=authentik\nNORDVPN_TOKEN=TOKEN\nVPN_SERVER_COUNTRIES=Sweden\n'
all+='TZ=Europe/Berlin\nSTACK_DOMAIN=Media.Example.com\nACME_EMAIL=a@b.co\nCF_DNS_API_TOKEN=CFTOK\nPORTAL_TITLE=Home\nJELLYFIN_SERVER_NAME=Den\n'
all+='SMTP_HOST=SMTP.x.co\nSMTP_PORT=587\nSMTP_STARTTLS=true\nSMTP_TLS=false\nSMTP_USER=me@x.co\nSMTP_PASSWORD=ab cd ef\nSMTP_FROM=me@x.co\n'
all+='NOTIFY_OPS=ntfy://ntfy.sh/ops\nCLOUDFLARE_TUNNEL_TOKEN=TUN\nSTACK_USER=boss\nUPDATE_SCHEDULE=Sun 03:00\nPANEL=no\n'
fresh; answers "$all"
filed "$T/a.env" '' --fresh || fail_ "every hook answered: $(cat "$T/out")"
for kv in TZ=Europe/Berlin STACK_DOMAIN=media.example.com ACME_EMAIL=a@b.co CF_DNS_API_TOKEN=CFTOK PORTAL_TITLE=Home JELLYFIN_SERVER_NAME=Den \
          SMTP_HOST=smtp.x.co SMTP_PASSWORD=abcdef SMTP_FROM=me@x.co CLOUDFLARE_TUNNEL_TOKEN=TUN STACK_USER=boss VPN_SERVER_COUNTRIES=Sweden \
          "UPDATE_SCHEDULE=Sun 03:00" "BACKUP_SCHEDULE=*-*-* 04:00"; do
    [[ "$(envv "${kv%%=*}")" == "${kv#*=}" ]] || fail_ "${kv%%=*}: '$(envv "${kv%%=*}")', not '${kv#*=}'"
done; pass
[[ "$(ENV_FILE=$T/w/.env STATE_DIR=$T/w/local/state state_get "$NOTIFY_URLS_STATE")" == $'ops\tntfy://ntfy.sh/ops' ]] || fail_ "Apprise's URLs held for wire"; pass
[[ -z "$(ENV_FILE=$T/w/.env STATE_DIR=$T/w/local/state state_get "$PANEL_STATE")" ]] || fail_ "PANEL=no: no panel"; pass
fresh; answers "$(sed 's/CLOUDFLARE_TUNNEL_TOKEN=TUN/CLOUDFLARE_TUNNEL_TOKEN=/' <<<"$all")"
filed "$T/a.env" '' --fresh || fail_ "the tunnel left blank: $(cat "$T/out")"
[[ ",$(envv COMPOSE_PROFILES)," != *,cloudflared,* ]] || fail_ "no one to ask for an optional token: the tunnel stays off"; pass

# ---- full mode with a terminal: the check pass reaches every question and asks none ----
fresh; answers "CONFIGURE_MODE=full\n$all"
Q_TERMINAL=1 filed "$T/a.env" '' --fresh
! has "the check stopped" && ! has "reached the question" || fail_ "a question the check pass reached unguarded: $(cat "$T/out")"; pass
fresh; answers 'CONFIGURE_MODE=full\nENABLE_SONARR=y\nENABLE_TRAEFIK=y\nSIGNIN=authentik\n'
Q_TERMINAL=1 filed "$T/a.env" '' --fresh
! has "the check stopped" && ! has "reached the question" || fail_ "full, little answered: every unanswered question guarded: $(cat "$T/out")"; pass

# ---- the flags: into the same answers, over the file's ----
fresh; answers 'NORDVPN_TOKEN=TOKEN\nENABLE_RADARR=y\nENABLE_JELLYFIN=y\n'
( ENV_FILE=$T/w/.env STATE_DIR=$T/w/local/state LOCAL_DIR=$T/w/local FSTAB=$T/fstab PATH=$SHIMS
  questionnaire_answers_run --answers "$T/a.env" --signin none --services sonarr,qbittorrent -- --fresh </dev/null ) > "$T/out" 2>&1 \
    || fail_ "file and flags together: $(cat "$T/out")"
[[ "$(envv COMPOSE_PROFILES)" == gluetun,qbittorrent,sonarr ]] || fail_ "--services: exactly those (and what they need): $(envv COMPOSE_PROFILES)"; pass
has "--services: the file's ENABLE_ lines give way to it" || fail_ "the file's ENABLE_ lines give way, and it says so"; pass
fresh
( ENV_FILE=$T/w/.env STATE_DIR=$T/w/local/state LOCAL_DIR=$T/w/local FSTAB=$T/fstab PATH=$SHIMS
  questionnaire_answers_run --signin wizard --services 'a b' --domain 'not a domain' -- --fresh </dev/null ) > "$T/out" 2>&1
[[ $? == 4 && "$(problems)" == 3 ]] && has "--signin: SIGNIN='wizard' is not one of: none, wizarr, authentik" \
    && has "--domain: STACK_DOMAIN='not a domain' is not a domain" && has "--services: 'a b' is not service names" \
    && has "the answers and --signin wizard" || fail_ "flags alone, each refused value named: $(cat "$T/out")"; pass
fresh
( ENV_FILE=$T/w/.env STATE_DIR=$T/w/local/state LOCAL_DIR=$T/w/local FSTAB=$T/fstab PATH=$SHIMS
  questionnaire_answers_run --signin none --services sonarr,olivetin,nosuch -- --fresh </dev/null ) > "$T/out" 2>&1
[[ $? == 4 ]] && has "--services: olivetin is no service to switch on that way" && has "--services: nosuch is no service" \
    || fail_ "--services names only services it can switch on: $(cat "$T/out")"; pass
fresh
( ENV_FILE=$T/w/.env STATE_DIR=$T/w/local/state LOCAL_DIR=$T/w/local FSTAB=$T/fstab PATH=$SHIMS
  questionnaire_answers_run --signin none --services sonarr,qbittorrent -- --fresh </dev/null ) > "$T/out" 2>&1
[[ $? == 4 && "$(problems)" == 1 ]] && has "VPN is not answered" || fail_ "flags alone, no terminal: only the VPN is missing (qBittorrent brings it): $(cat "$T/out")"; pass
( CALLER_DIR=$T; answers 'SIGNIN=none\n'; cd /; answers_opts --answers a.env --fresh --signin none
  [[ "${ANSWERS_OPTS[*]}" == "--answers $T/a.env --signin none" && "${ANSWERS_REST[*]}" == --fresh ]] ) \
    || fail_ "the options are taken out, a relative file found from where it was run, the rest kept in order"; pass
out=$( (answers_opts --signin) 2>&1 ) && fail_ "an option needs its value"
[[ "$out" == *"--signin: give it a value"* ]] || fail_ "and says so: $out"; pass

# ---- START: configure's closing question, answered ahead ----
fresh; answers 'ENABLE_SONARR=y\nSIGNIN=none\nNORDVPN_TOKEN=TOKEN\nSTART=no\n'; filed "$T/a.env" '' --fresh || fail_ "START=no: $(cat "$T/out")"
( ENV_FILE=$T/w/.env STATE_DIR=$T/w/local/state WIRED_FILE=$T/none; out=$(chain_wanted </dev/null 2>&1); rc=$?
  (( rc == 1 )) && [[ "$out" == *"Start: no (from the answers)"* && -z "$(state_get "$START_STATE")" ]] ) || fail_ "START=no: nothing started, nothing asked, the answer used once"; pass
answers 'START=yes\n'; filed "$T/a.env" '' || fail_ "START=yes on a re-run"
( ENV_FILE=$T/w/.env STATE_DIR=$T/w/local/state WIRED_FILE=$T/w/.env; chain_wanted </dev/null >/dev/null 2>&1 ) || fail_ "START=yes: applied without asking, even on a live stack"; pass
answers 'TZ=Europe/Berlin\n'; filed "$T/a.env" '' || fail_ "blank START"
[[ -z "$(ENV_FILE=$T/w/.env STATE_DIR=$T/w/local/state state_get "$START_STATE")" ]] || fail_ "a blank START keeps configure's own default"; pass

# ---- sudo with no one to type its password ----
nosudo() { ( id() { [[ "$1" == -u ]] && echo 1000; }; sudo() { [[ "$*" == "-n true" ]] && return "$1"; }; ANSWERS_OPTS=("${@:2}")
             sudo() { return "$SUDO_RC"; }; SUDO_RC=$1 sudo_unattended_check </dev/null ) 2>&1; }
out=$(nosudo 1 --signin none) && fail_ "answers, no terminal, sudo wants a password: refused up front"
[[ "$out" == *"sudo needs its password, and with no terminal nothing can ask for it — run 'sudo -v' first"* ]] || fail_ "and says what to do: $out"; pass
nosudo 0 --signin none >/dev/null || fail_ "sudo already open (sudo -v, or NOPASSWD): carries on"; pass
nosudo 1 >/dev/null || fail_ "no answers given: no check (the questionnaire says it needs a terminal)"; pass
grep -q 'exec bash "$SCRIPT_DIR/mediastack.sh" configure "${ANSWERS_OPTS\[@\]}"' lib/lifecycle.sh \
    && grep -q '^    sudo_unattended_check' <(awk '/^cmd_install\(\)/,/^}/' lib/lifecycle.sh) || fail_ "install checks sudo first and hands its answers to configure"; pass

# ---- answers.example: every line a question configure asks, every question in it ----
cp answers.example "$T/ex.env"; chmod 600 "$T/ex.env"
( ANSWERS_PASS=check; ANSWERS_PROBLEMS=$T/p; ANSWER=(); : > "$T/p"; answers_load "$T/ex.env"
  [[ ! -s "$T/p" && ${#ANSWER[@]} == 0 ]] ) || fail_ "answers.example loads clean, every answer blank: $(cat "$T/p")"; pass
missing=$(env_schema_rows | awk -F'\t' '$6 != "-" && $1 !~ /</ { print $1 }' | while read -r k; do grep -q "^$k=$" answers.example || echo "$k"; done)
[[ -z "$missing" ]] || fail_ "answers.example lacks questions configure asks (run scripts/gen-answers.sh): $missing"; pass
grep -q '^ENABLE_SONARR=$' answers.example && grep -q '^TRASH_PROFILE_RADARR=$' answers.example && ! grep -q '^ENABLE_OLIVETIN=' answers.example \
    && ! grep -q '^ENABLE_WIZARR=' answers.example || fail_ "the families: a line per service it can switch on, per arr TRaSH manages"; pass
fresh; sed 's/^SIGNIN=$/SIGNIN=none/; s/^NORDVPN_TOKEN=$/NORDVPN_TOKEN=TOKEN/; s/^ENABLE_SONARR=$/ENABLE_SONARR=y/' answers.example > "$T/a.env"; chmod 600 "$T/a.env"
filed "$T/a.env" '' --fresh || fail_ "answers.example with three lines filled runs unattended: $(cat "$T/out")"
snapshot "$T/template"; diff "$T/typed.env" "$T/template.env" >&2 || fail_ "and gives what typing the same three answers gives"; pass
grep -q '^/answers\*\.env$' .gitignore || fail_ "your answers (answers*.env) are git-ignored"; pass

# ---- configure's own arguments ----
out=$( (need_cmd() { :; }; cmd_configure x) 2>&1 ) && fail_ "configure refuses what it does not take"
[[ "$out" == *"unknown argument 'x' for 'configure' (accepts: --answers FILE, --domain D, --services a,b, --signin none|wizarr|authentik)"* ]] || fail_ "and says what it takes: $out"; pass
out=$( (need_cmd() { :; }; CALLER_DIR=$T; cmd_configure --answers nosuch.env) 2>&1 ) && fail_ "a file that is not there stops configure"
[[ "$out" == *"--answers: nosuch.env is not a file"* ]] || fail_ "named as given, looked for where configure was run: $out"; pass

# ---- the check pass asks nothing ----
out=$( (ANSWERS_PASS=check; ask X "A question" "" </dev/null) 2>&1 ) && fail_ "a question reached in the check pass must stop"
[[ "$out" == *"configure's check reached the question 'A question'"* ]] || fail_ "and say which: $out"; pass

echo "OK answers: $checks checks"
