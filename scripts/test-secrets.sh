#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-secrets.sh — one rule for every secret (docs/design-install.md, "The
# stack's own logins"; the rule: secret_ok in lib/common.sh).
#   * the rule: printable ASCII with no whitespace and none of $ " ' \ or the
#     backtick — every other symbol passes
#   * one rule, everywhere: the schema's secret type, a typed password
#     (ask_secret), the stack's logins and the mail password all answer with
#     it; no second list of forbidden characters exists in the code
#   * the backstop: env_set refuses to write a secret that breaks it
#   * every key: a $ is refused in any .env value (compose reads a variable,
#     the script text)
#   * what passes is what both readers see: every allowed symbol, written by
#     env_set, reads back the same through env_get and through compose
#     (docker compose config; skipped with a note where compose is missing)
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

logins_list() { printf 'a login\tU\tP\tpw_max=64\n'; }   # no render here: the stack's logins are a fixture (a die inside $( ) would pass a check unseen)

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

# every printable ASCII symbol the rule allows, with letters and digits
ALLOWED='Aa0!#%&()*+,-./:;<=>?@[]^_{|}~'

# ---- the rule ----
ok_()  { secret_ok "$1" || fail_ "the rule must accept '$1'"; pass; }
no_()  { if secret_ok "$1"; then fail_ "the rule must refuse '$1'"; fi; pass; }
ok_ "$ALLOWED"; ok_ abcdefghijkl; ok_ 'Kj7#mQ2&vL9!'; ok_ 'a=b+c/d'
no_ 'ab$cd'; no_ 'ab"cd'; no_ "ab'cd"; no_ 'ab\cd'; no_ 'ab`cd'
no_ 'ab cd'; no_ ' abcd'; no_ 'abcd '; no_ $'ab\tcd'; no_ 'pässword'
[[ "$(secret_problem 'ab$cd')" == *'$'* ]] || fail_ "the reason names what is refused"; pass
[[ -z "$(secret_problem "$ALLOWED")" ]] || fail_ "no reason for a secret that passes"; pass

# ---- one rule, everywhere ----
env_type_ok secret "$ALLOWED" || fail_ "the secret type accepts what the rule accepts"; pass
if env_type_ok secret 'ab$cd'; then fail_ "the secret type refuses what the rule refuses"; fi; pass
[[ "$(env_type_expect secret)" == *'$'* ]] || fail_ "the secret type's message says what it may not hold"; pass
[[ -n "$(login_pass_problem 'abcdefghijk$l')" ]] || fail_ "a stack login refuses a \$ (the rule)"; pass
[[ -z "$(login_pass_problem "abcdefghijkl$ALLOWED")" ]] || fail_ "a stack login takes every allowed symbol"; pass
[[ "$(login_pass_problem "$(printf 'a%.0s' {1..65})")" == *"at most 64"* ]] || fail_ "a stack login's own limits still apply after the rule"; pass
[[ -n "$(smtp_password_problem 'abcd$efgh')" ]] || fail_ "the mail password refuses a \$ (the rule)"; pass
[[ -z "$(smtp_password_problem 'abcd efgh ijkl mnop')" ]] || fail_ "the mail password's spaces are dropped first (Gmail shows them in fours)"; pass
# no second list: the rule's characters are written in one place
others=$(grep -rnE --include=*.sh -e '\[\[:space:\]\$"' -e 'LOGIN_FORBIDDEN' -e "\\\$\\\\\$\[:space:\]\]" lib services mediastack.sh | grep -v '^lib/common.sh:' || true)
[[ -z "$others" ]] || fail_ "a second list of forbidden characters: $others"; pass

# ---- a typed password: ask_secret refuses, names why, and asks again ----
out=$(printf 'ab$cdefghijkl\nab$cdefghijkl\nKj7#mQ2&vL9!\nKj7#mQ2&vL9!\n' | { ask_secret "pw" "GEN"; echo "GOT:$REPLY_VAL"; } 2>&1) \
    || fail_ "ask_secret ended instead of asking again"
[[ "$out" == *'GOT:Kj7#mQ2&vL9!'* ]] || fail_ "ask_secret takes the second, valid password: $out"; pass
[[ "$out" == *'$'* ]] || fail_ "ask_secret says why it refused the first"; pass

# ---- the backstop: env_set never stores a secret that breaks the rule ----
ENV_FILE=$T/.env; : > "$ENV_FILE"
env_defaults_load
[[ -n "${ENV_SECRET[ARR_PASSWORD]-}" ]] || fail_ "the schema's secrets are known to env_set (ENV_SECRET)"; pass
if ( env_set ARR_PASSWORD 'ab$cd' ) 2>/dev/null; then fail_ "env_set must refuse a secret that breaks the rule"; fi; pass
grep -q 'ab\$cd' "$ENV_FILE" && fail_ "a refused secret is not written"; pass
env_set PORTAL_TITLE 'My Media'; [[ "$(env_get PORTAL_TITLE)" == 'My Media' ]] || fail_ "a text value keeps its spaces"; pass

# ---- every key: no $ in any .env value ----
[[ "$(env_value_problem PORTAL_TITLE 'Bob$s' text ok)" == *'$'* ]] || fail_ "a \$ in a text value is refused too"; pass
[[ "$(env_value_problem ARR_PASSWORD 'ab$cd' secret ok)" != *'ab$cd'* ]] || fail_ "a refused secret is never shown"; pass

# ---- what passes is what both readers see ----
env_set ARR_PASSWORD "$ALLOWED"
[[ "$(env_get ARR_PASSWORD)" == "$ALLOWED" ]] || fail_ "env_set then env_get: '$(env_get ARR_PASSWORD)'"; pass
if docker compose version >/dev/null 2>&1; then
    printf 'services:\n  t:\n    image: scratch\n    environment:\n      V: ${ARR_PASSWORD}\n' > "$T/compose.yml"
    got=$(cd "$T" && docker compose -f compose.yml --env-file .env config --format json 2>/dev/null | jq -r '.services.t.environment.V')
    [[ "$got" == "$ALLOWED" ]] || fail_ "compose reads '$got', the script '$ALLOWED'"; pass
else
    echo "note: docker compose is not here — the compose half of the round trip is CI's"
fi

echo "OK secrets: $checks checks"
