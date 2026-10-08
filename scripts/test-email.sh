#!/usr/bin/env bash
# test-email.sh — the portal's outgoing email (lib/email.sh) and `users`:
# what makes SMTP settings unusable, that `email test` never runs against
# settings authentik has not started with, what a server's refusal is said to
# mean, the 30 -> 31 migration, configure's email step, and the people list.
#
#   scripts/test-email.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
lib=$(mktemp .test-email.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"
ENV_FILE=$T/.env; STATE_DIR=$T/state; mkdir -p "$STATE_DIR"

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "OK $*"; }; warn() { echo "WARN $*"; }; fail() { echo "FAIL $*"; }; info() { echo ":: $*"; }
load_env() { :; }; render() { :; }; repo_owned() { :; }; svc_cname() { echo "c-$1"; }
svc_enabled() { [[ "$1" == authentik ]]; }

smtp() { : > "$ENV_FILE"; local kv; for kv in "$@"; do echo "$kv" >> "$ENV_FILE"; done; }
GOOD=(SMTP_HOST=smtp.example.com SMTP_PORT=587 SMTP_STARTTLS=true SMTP_TLS=false SMTP_USER=me@example.com SMTP_PASSWORD=abcd1234 SMTP_FROM=me@example.com)

# ---- what makes settings unusable ----
smtp "${GOOD[@]}"; [[ -z "$(smtp_problems)" ]] || fail_ "good settings: no problems: $(smtp_problems)"; pass
smtp "${GOOD[@]}" SMTP_TLS=true; [[ "$(smtp_problems)" == *"both true"* ]] || fail_ "STARTTLS and TLS at once"; pass
smtp "${GOOD[@]}" 'SMTP_PASSWORD=pa$word'; [[ "$(smtp_problems)" == *'holds a $'* ]] || fail_ "a \$ compose would rewrite"; pass
smtp "${GOOD[@]}" SMTP_FROM=; [[ "$(smtp_problems)" == *"SMTP_FROM is empty"* ]] || fail_ "no sender"; pass
smtp "${GOOD[@]}" SMTP_PASSWORD=; [[ "$(smtp_problems)" == *"SMTP_PASSWORD is empty"* ]] || fail_ "a login without a password"; pass
smtp SMTP_HOST=relay.lan SMTP_PORT=25 SMTP_FROM=box@home.lan; [[ -z "$(smtp_problems)" ]] || fail_ "an unauthenticated LAN relay is fine"; pass

# ---- what a refusal usually means ----
[[ "$(smtp_hint '535 5.7.8 Username and Password not accepted')" == *"app password"* ]] || fail_ "hint: login"; pass
[[ "$(smtp_hint 'ssl.SSLError: [SSL: WRONG_VERSION_NUMBER] wrong version number')" == *"587 takes STARTTLS"* ]] || fail_ "hint: TLS mismatch"; pass
[[ "$(smtp_hint 'TimeoutError: timed out')" == *"block port 25"* ]] || fail_ "hint: unreachable"; pass
[[ "$(smtp_hint '553 5.7.1 Sender address rejected: not owned by user')" == *"SMTP_FROM must be"* ]] || fail_ "hint: sender"; pass

# ---- email test: never against settings authentik has not started with ----
LIVE=""; EXEC_OUT="Test email sent to you@example.com"; EXEC_RC=0
c_state() { echo running; }
sudo() {
    case "$1 $2" in
        "docker inspect") printf '%s\n' "$LIVE" ;;
        "docker exec") echo "EXEC $*" >> "$T/log"; echo "$EXEC_OUT"; return "$EXEC_RC" ;;
        *) "$@" ;;
    esac; }
live_from_env() { # what compose would hand authentik for the current .env
    LIVE=$(printf 'AUTHENTIK_EMAIL__HOST=%s\nAUTHENTIK_EMAIL__PORT=%s\nAUTHENTIK_EMAIL__USERNAME=%s\nAUTHENTIK_EMAIL__PASSWORD=%s\nAUTHENTIK_EMAIL__USE_TLS=%s\nAUTHENTIK_EMAIL__USE_SSL=%s\nAUTHENTIK_EMAIL__FROM=%s\n' \
        "$(env_get SMTP_HOST)" "$(env_get SMTP_PORT)" "$(env_get SMTP_USER)" "$(env_get SMTP_PASSWORD)" \
        "$(env_get SMTP_STARTTLS)" "$(env_get SMTP_TLS)" "$(env_get SMTP_FROM)"); }
et() { rm -f "$T/log"; ( cmd_email "$@" ) 2>&1; }

smtp; out=$(et test you@example.com) && fail_ "not set up: refuse"; [[ "$out" == *"not set up"* ]] || fail_ "not set up: $out"; pass
smtp "${GOOD[@]}"; out=$(et test nobody) && fail_ "no address: refuse"; [[ "$out" == *"usage: email test"* ]] || fail_ "usage: $out"; pass
smtp "${GOOD[@]}" SMTP_TLS=true; live_from_env
out=$(et test you@example.com) && fail_ "unusable settings: refuse"; [[ "$out" == *"cannot work yet"*"both true"* && ! -e "$T/log" ]] || fail_ "problems named, nothing sent: $out"; pass
smtp "${GOOD[@]}"; live_from_env; smtp "${GOOD[@]}" SMTP_PORT=465 SMTP_STARTTLS=false SMTP_TLS=true
out=$(et test you@example.com) && fail_ "older settings in the running authentik: refuse"
[[ "$out" == *"older email settings (SMTP_PORT SMTP_STARTTLS SMTP_TLS)"*"./mediastack.sh up"* && ! -e "$T/log" ]] \
    || fail_ "stale: which settings (names, never values), what to do, nothing sent: $out"; pass
[[ "$out" != *abcd1234* ]] || fail_ "the password never appears"; pass
smtp "${GOOD[@]}"; live_from_env; rm -f "$STATE_DIR/SMTP_TESTED"
out=$(et test you@example.com); [[ "$out" == *"OK sent"* ]] && grep -q 'ak test_email you@example.com' "$T/log" \
    && [[ "$(state_get SMTP_TESTED)" == "$(smtp_fingerprint)" ]] || fail_ "sent through authentik's own test; recorded as tested: $out"; pass
[[ "$(et status)" == *"passed a test"* ]] || fail_ "status: these settings passed"; pass
smtp "${GOOD[@]}" SMTP_PASSWORD=changed99; [[ "$(et status)" == *"have not passed a test yet"* ]] || fail_ "a changed setting is untested again"; pass
smtp "${GOOD[@]}"; live_from_env; EXEC_OUT=$'{"event":"x"}\nsmtplib.SMTPAuthenticationError: (535, b"5.7.8 Username and Password not accepted")'; EXEC_RC=1
rm -f "$STATE_DIR/SMTP_TESTED"; out=$(et test you@example.com) && fail_ "a refusal must fail"
[[ "$out" == *"did not take it"*"SMTPAuthenticationError"*"app password"* && ! -e "$STATE_DIR/SMTP_TESTED" ]] \
    || fail_ "the server's own words, then the likely cause; not recorded as tested: $out"; pass
EXEC_OUT="Test email sent to you@example.com"; EXEC_RC=0

# ---- the 30 -> 31 migration: the keys, empty; set ones kept ----
printf 'TZ=America/Los_Angeles\nSMTP_HOST=keep.example.com\n' > "$ENV_FILE"; migrate_env_30_to_31 >/dev/null
[[ "$(env_get SMTP_HOST)" == keep.example.com ]] && grep -qx 'SMTP_PASSWORD=' "$ENV_FILE" && grep -qx 'SMTP_FROM=' "$ENV_FILE" \
    || fail_ "migration adds the keys empty, keeps a value: $(cat "$ENV_FILE")"; pass

# ---- configure's email step ----
explain() { :; }; hr() { :; }
cfg() { printf '%b' "$1" | _configure_email >/dev/null 2>&1; }
: > "$ENV_FILE"; cfg 'n\n'; [[ -z "$(env_get SMTP_HOST)" ]] || fail_ "skipped: nothing set"; pass
: > "$ENV_FILE"; cfg 'y\nSMTP.Example.com\n1\n\nme@example.com\npa$s\nabcd1234\n\n'
[[ "$(env_get SMTP_HOST)" == smtp.example.com && "$(env_get SMTP_PORT)" == 587 && "$(env_get SMTP_STARTTLS)" == true \
   && "$(env_get SMTP_TLS)" == false && "$(env_get SMTP_PASSWORD)" == abcd1234 && "$(env_get SMTP_FROM)" == me@example.com ]] \
    || fail_ "STARTTLS on 587, a \$ password refused then a good one, the login as sender: $(cat "$ENV_FILE")"; pass
cfg 'c\nsmtp.example.com\n2\n\n\n\n\n'
[[ "$(env_get SMTP_PORT)" == 465 && "$(env_get SMTP_TLS)" == true && "$(env_get SMTP_STARTTLS)" == false && "$(env_get SMTP_PASSWORD)" == abcd1234 ]] \
    || fail_ "change to TLS: 465 suggested, Enter keeps the password: $(cat "$ENV_FILE")"; pass
cfg 'r\n'; [[ -z "$(env_get SMTP_HOST)" && -z "$(env_get SMTP_PASSWORD)" ]] || fail_ "remove: every key emptied"; pass

# ---- users: the portal's people (not the stack's own, not service accounts) ----
c_health() { echo healthy; }
ak_api() { echo '{"results":[
  {"username":"akadmin","type":"internal","name":"authentik Default Admin","email":"","is_active":true,"groups_obj":[{"name":"authentik Admins"}]},
  {"username":"ana","type":"internal","name":"Ana","email":"ana@home.lan","is_active":true,"groups_obj":[{"name":"media-users"},{"name":"admins"}]},
  {"username":"tom","type":"internal","name":"","email":"","is_active":false,"groups_obj":[]},
  {"username":"mediastack-ldap-search","type":"internal","name":"mediastack LDAP search (Jellyfin)","email":"","is_active":true,"groups_obj":[]},
  {"username":"ak-outpost-x","type":"internal_service_account","name":"","email":"","is_active":true,"groups_obj":[]}]}'; }
out=$(cmd_users)
[[ "$out" == *USERNAME*EMAIL*GROUPS* && "$out" == *"ana"*"ana@home.lan"*"media-users,admins"*"yes"* && "$out" == *"tom"*"-"*"off"* ]] \
    || fail_ "people listed with email and groups, blanks as -, a deactivated one 'off': $out"; pass
[[ "$out" != *"ak-outpost-x"* && "$out" != *"mediastack-ldap-search  "* && "$(grep -c '^akadmin' <<<"$out")" == 0 ]] \
    || fail_ "the stack's own accounts and service accounts left out: $out"; pass

echo "OK email: $checks checks"
