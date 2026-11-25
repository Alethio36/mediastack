#!/usr/bin/env bash
# test-schema-bump.sh — scripts/check-schema-bump.sh, on a scratch repo:
#   * a settings change without ENV_SCHEMA fails; with it, passes
#   * a new service's own lines (its UID, update flag, env.tsv keys) need no bump
#   * anything else beside them, an existing service's new key, a removed
#     line, or a key of the new service it does not declare still fails
#   * comments never count
#
#   scripts/test-schema-bump.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
repo=$PWD
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

g() { git -C "$T/r" -c user.name=t -c user.email=t@t "$@"; }
mkdir -p "$T/r/scripts" "$T/r/services/old"
cp "$repo/scripts/check-schema-bump.sh" "$T/r/scripts/"
printf 'ENV_SCHEMA=1\nOLD_UID=13001\nOLD_UPDATE=true\n' > "$T/r/.env.example"
printf 'services: {}\n' > "$T/r/services/old/compose.yml"
g init -q; g add -A; g commit -qm base
base=$(g rev-parse HEAD)

case_() { # case_ WANT(pass|fail) "WHAT" SHELL-EDIT — on a fresh branch from base
    local want=$1 what=$2 out rc=0
    g checkout -q -B "c$checks" "$base"
    (cd "$T/r" && eval "$3")
    g add -A; g commit -qm "$what"
    out=$("$T/r/scripts/check-schema-bump.sh" "$base" 2>&1) || rc=$?
    if [[ $want == pass ]]; then (( rc == 0 )) || fail_ "$what: should pass: $out"
    else (( rc != 0 )) && grep -q 'without bumping ENV_SCHEMA' <<<"$out" || fail_ "$what: should fail: $out"; fi
    pass
}
newsvc='mkdir -p services/new-tv && printf "services: {}\n" > services/new-tv/compose.yml && printf "# rows\nNEW_TV_ADMIN_USER\ttext\tok\tscript\t-\t-\tx\n" > services/new-tv/env.tsv'

case_ pass "a comment only" 'printf "# a note\n" >> .env.example'
case_ fail "a setting, no bump" 'printf "SOMETHING=1\n" >> .env.example'
case_ pass "a setting with the bump" 'sed -i s/ENV_SCHEMA=1/ENV_SCHEMA=2/ .env.example && printf "SOMETHING=1\n" >> .env.example'
case_ pass "a new service's UID, update flag and env.tsv key" "$newsvc"' && printf "NEW_TV_UID=13002\nNEW_TV_UPDATE=true\nNEW_TV_ADMIN_USER=\n" >> .env.example'
case_ fail "a new service, and another setting beside it" "$newsvc"' && printf "NEW_TV_UID=13002\nSOMETHING=1\n" >> .env.example'
case_ fail "a new service's key it does not declare" "$newsvc"' && printf "NEW_TV_PORT=1\n" >> .env.example'
case_ fail "an existing service's new key" 'printf "OLD_ADMIN_USER=\n" >> .env.example'
case_ fail "a new service, and a line removed" "$newsvc"' && sed -i /OLD_UPDATE/d .env.example && printf "NEW_TV_UID=13002\n" >> .env.example'
case_ fail "a new service's line, the folder not added" 'printf "NEW_TV_UID=13002\n" >> .env.example'

echo "OK schema bump: $checks checks"
