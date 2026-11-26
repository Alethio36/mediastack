#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-secrets.sh — every value .env holds reads the same in both its readers
# (compose and the script), and every secret follows one rule (env_encode,
# secret_ok: lib/common.sh).
#   * the round trip: every printable ASCII character, spaces at either end,
#     quotes, $, \ and non-ASCII, written by env_set, read back identical by
#     env_get and by compose (docker compose config; skipped with a note
#     where compose is missing — CI has it)
#   * an ordinary value stays bare (no churn in an existing .env); only one
#     compose would misread is quoted
#   * a hand-written form: double quotes with \\ \" \$ are read as compose
#     reads them; single quotes, a bare $, an unknown escape, an unclosed
#     quote, a comment after a value and a space at an end are refused, named
#   * the rule: one line, no control characters — a newline is refused for
#     every key (it would start a key of its own), a tab too; nothing else is
#   * one rule, everywhere: the secret type, a typed password (ask_secret), a
#     pasted one (ask_secret_token), the stack's logins and the mail password
#   * the answers file takes .env's forms, and a flag's value is literal
#   * env_get prints a value such as -n as itself
#
#   scripts/test-secrets.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-secrets.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"
logins_list() { printf 'a login\tU\tP\tpw_max=128\n'; }   # no render here: the stack's logins are a fixture (a die inside $( ) would pass a check unseen)

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

PRINTABLE=$(printf "$(printf '\\%03o' $(seq 32 126))")   # every printable ASCII character, the space first
VALUES=("$PRINTABLE" ' lead and trail ' 'a\' '\n' '\\"$x' "it's" 'ab #c' '${V}' 'ü€ñ' '"' "'" '$' '\' '-n' '-e' 'plain' 'Tue 04:00')

# ---- the round trip ----
ENV_FILE=$T/.env; : > "$ENV_FILE"
env_defaults_load
for v in "${VALUES[@]}"; do
    env_set ARR_PASSWORD "$v"
    [[ "$(env_get ARR_PASSWORD)" == "$v" ]] || fail_ "env_set then env_get: [$v] came back [$(env_get ARR_PASSWORD)]"; pass
    [[ -z "$(env_value_problem ARR_PASSWORD "$(grep '^ARR_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)" secret ok)" ]] \
        || fail_ "the form env_set writes passes .env's own check: [$v]"; pass
done
if docker compose version >/dev/null 2>&1; then
    printf 'services:\n  t:\n    image: scratch\n    environment:\n      V: ${ARR_PASSWORD}\n' > "$T/compose.yml"
    for v in "${VALUES[@]}"; do
        env_set ARR_PASSWORD "$v"
        got=$(cd "$T" && docker compose -f compose.yml --env-file .env config --format json 2>/dev/null | jq -r '.services.t.environment.V')
        [[ "$got" == "${v//\$/\$\$}" ]] || fail_ "compose reads [$got], the script [$v] (compose prints a \$ as \$\$)"; pass
    done
else
    echo "note: docker compose is not here — the compose half of the round trip is CI's"
fi

# ---- an ordinary value stays bare ----
for v in plain 'Tue 04:00' 'a"b' "it's" 'a\b' 'x#y' 'ü€ñ'; do
    [[ "$(env_encode "$v")" == "$v" ]] || fail_ "[$v] is read alike bare: written bare, not $(env_encode "$v")"; pass
done
for v in 'a$b' '"x' "'x" ' x' 'x ' 'a #b'; do
    [[ "$(env_encode "$v")" == \"*\" ]] || fail_ "[$v] would be misread bare: written quoted"; pass
done

# ---- a hand-written form ----
form_ok()  { [[ -z "$(env_raw_problem K "$1")" ]] || fail_ "[$1] is a form both readers read alike: $(env_raw_problem K "$1")"; [[ "$(env_decode "$1")" == "$2" ]] || fail_ "[$1] stands for [$2], not [$(env_decode "$1")]"; pass; }
form_bad() { [[ "$(env_raw_problem K "$1")" == *"$2"* ]] || fail_ "[$1] is refused, saying '$2': got [$(env_raw_problem K "$1")]"; pass; }
form_ok plain plain; form_ok '"a b"' 'a b'; form_ok '"a\$b"' 'a$b'; form_ok '"a\"b"' 'a"b'; form_ok '"a\\b"' 'a\b'; form_ok '""' ''
form_ok 'a"b' 'a"b'; form_ok 'a\b' 'a\b'
form_bad "'single'" 'single quotes'; form_bad 'a$b' 'variable'; form_bad '"a\nb"' 'escape'; form_bad '"abc' 'never closes'
form_bad '"abc\"' 'never closes'; form_bad '"a"b"' 'inside its quotes'; form_bad '"a$b"' 'variable'; form_bad 'skip   # note' 'comment'
form_bad ' lead' 'space'; form_bad 'trail ' 'space'; form_bad '"x" # note' 'after its closing quote'
[[ "$(env_value_problem ARR_PASSWORD "'s3cret'" secret ok)" != *s3cret* ]] || fail_ "a refused secret is never shown"; pass

# ---- the rule: one line, no control characters ----
secret_ok "$PRINTABLE" || fail_ "every printable character passes"; pass
secret_ok 'ü€ñ pass' || fail_ "non-ASCII and spaces pass"; pass
if secret_ok $'a\tb'; then fail_ "a tab is refused"; fi; pass
if secret_ok $'a\nb'; then fail_ "a newline is refused"; fi; pass
if ( env_set PORTAL_TITLE $'x\nARR_PASSWORD=injected' ) 2>/dev/null; then fail_ "a newline in any value is refused (it would be a key of its own)"; fi; pass
grep -q injected "$ENV_FILE" && fail_ "nothing of a refused value is written"; pass

# ---- one rule, everywhere ----
env_type_ok secret "$PRINTABLE" || fail_ "the secret type takes every printable character"; pass
if env_type_ok secret $'a\nb'; then fail_ "the secret type refuses a newline"; fi; pass
[[ -z "$(login_pass_problem "abcdefghijkl$PRINTABLE")" ]] || fail_ "a stack login takes every printable character"; pass
[[ "$(login_pass_problem "$(printf 'a%.0s' {1..129})")" == *"at most 128"* ]] || fail_ "a stack login's own limits still apply after the rule"; pass
[[ -n "$(login_pass_problem $'abcdefghijk\tl')" ]] || fail_ "a stack login refuses a tab (the rule)"; pass
[[ -z "$(smtp_password_problem 'pa$word "quoted"')" ]] || fail_ "the mail password takes \$ and quotes"; pass
[[ -n "$(smtp_password_problem $'abcd\x01efgh')" ]] || fail_ "the mail password refuses a control character (the rule)"; pass
others=$(grep -rnE --include=*.sh -e 'LOGIN_FORBIDDEN' -e '\[\[:space:\]\$"' lib services mediastack.sh || true)
[[ -z "$others" ]] || fail_ "a second list of forbidden characters: $others"; pass

# ---- a typed password: kept as typed, a space at either end included ----
out=$(printf ' Kj"7$ m\\Q2 \n Kj"7$ m\\Q2 \n' | { ask_secret "pw" "GEN"; printf 'GOT:[%s]' "$REPLY_VAL"; } 2>&1) || fail_ "ask_secret ended: $out"
[[ "$out" == *'GOT:[ Kj"7$ m\Q2 ]'* ]] || fail_ "ask_secret keeps every character, the spaces at its ends too: $out"; pass
out=$(printf 'tok$en "x"\n' | { ask_secret_token "pw" ""; printf 'GOT:[%s]' "$REPLY_VAL"; } 2>&1) || fail_ "ask_secret_token ended: $out"
[[ "$out" == *'GOT:[tok$en "x"]'* ]] || fail_ "a pasted secret is taken as pasted: $out"; pass

# ---- the answers file: .env's forms; a flag's value is literal ----
[[ -z "$(env_decoded_problem STACK_DOMAIN 'media.example.com' domain no)" ]] || fail_ "a flag's literal value is checked as it is"; pass

# ---- env_get: a value is never an option ----
env_set ARR_PASSWORD -n; [[ "$(env_get ARR_PASSWORD)" == -n ]] || fail_ "env_get prints -n as itself"; pass

# ---- a secret never on a command line sudo logs (it writes COMMAND= with every argument) ----
KEY=s3cr3t-$RANDOM$RANDOM
( sudo() { printf '%s\n' "$*" >> "$T/sudo.argv"; cat >/dev/null; echo 200; }
  svc_cname() { echo "c-$1"; }
  : > "$T/sudo.argv"
  meili_key_code "$KEY" >/dev/null; gluetun_control_code "$KEY" >/dev/null
  ! grep -F "$KEY" "$T/sudo.argv" ) || fail_ "the Meilisearch and gluetun key checks keep the key out of sudo's command line: $(cat "$T/sudo.argv")"; pass
( sudo() { case "$1" in test) return 0 ;; stat) echo 1000:1000 ;; sed) printf '%s\n' "$*" >> "$T/sudo.argv"; cat >> "$T/sed.script" ;; *) printf '%s\n' "$*" >> "$T/sudo.argv" ;; esac; }
  DC() { :; }; http_ready() { :; }; ll_url() { echo http://ll; }; env_get() { echo /cfg; }
  : > "$T/sudo.argv"; : > "$T/sed.script"
  ll_api_enable "$KEY" >/dev/null 2>&1 || true
  ! grep -F "$KEY" "$T/sudo.argv" && grep -F "api_key = $KEY" "$T/sed.script" >/dev/null ) \
    || fail_ "LazyLibrarian's key goes into sed's script on stdin, never sudo's command line: $(cat "$T/sudo.argv")"; pass
# env_set: the value is not on sed's command line either (ps shows it)
( sed() { printf '%s\n' "$*" >> "$T/sed.argv"; command sed "$@"; }
  : > "$T/sed.argv"; env_set ARR_PASSWORD first; env_set ARR_PASSWORD "$KEY"
  [[ "$(env_get ARR_PASSWORD)" == "$KEY" ]] && ! grep -F "$KEY" "$T/sed.argv" ) || fail_ "env_set rewrites a value with the value off sed's command line"; pass

# ---- .env is private from the start, and doctor says when it is not ----
( ENV_FILE=$T/fresh.env; repo_owned() { :; }; umask 022; env_set K v; [[ "$(stat -c %a "$ENV_FILE")" == 600 ]] ) || fail_ "a .env env_set creates is 600, whatever the umask"; pass
( ENV_FILE=$T/open.env; : > "$ENV_FILE"; chmod 644 "$ENV_FILE"; DOCTOR_FAILS=(); hr() { :; }; ok() { :; }; warn() { :; }; env_unknown() { :; }
  d_fail() { echo "FAIL $1 | $2" >> "$T/doc"; }; : > "$T/doc"; _doctor_env
  grep -F "FAIL .env can be read by others (mode 644)" "$T/doc" >/dev/null ) || fail_ "doctor fails a .env others can read: $(cat "$T/doc")"; pass
grep -nE 'chmod 600 "\$ENV_FILE" \|\| true' lib/*.sh >/dev/null && fail_ "making .env private is never || true"; pass

echo "OK secrets: $checks checks"
