#!/usr/bin/env bash
# test-registries.sh — scripts/check-registries.sh catches what it is there for.
# Each case breaks one thing in a scratch copy of the repo and expects the
# check to fail, naming it; the real tree must pass.
#
#   scripts/test-registries.sh     run (exit 1 on the first case it misses)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

scripts/check-registries.sh >/dev/null || fail_ "the real tree fails the check: $(scripts/check-registries.sh || true)"; pass

broken() { # broken "WHAT" "SHELL EDIT" "EXPECTED FAIL TEXT" — the check, run on a copy with one thing broken
    local d out
    d=$(mktemp -d)
    cp -r services scripts lib mediastack.sh "$d"/
    (cd "$d" && eval "$2")
    if out=$(cd "$d" && scripts/check-registries.sh 2>&1); then rm -rf "$d"; fail_ "$1: the check passed"; fi
    rm -rf "$d"
    grep -qF "$3" <<<"$out" || fail_ "$1: failed, but not saying '$3': $out"
    pass
}

# mediastack.people: every app people sign in to says what happens to their accounts
broken "an app under the rule loses its label" \
    "sed -i '/mediastack.people/d' services/kavita/compose.yml" \
    "people sign in to kavita, but it does not say what happens to their accounts"
broken "a new app with its own login, unlabelled" \
    "mkdir services/newapp && printf 'services:\n  newapp:\n    labels:\n      mediastack.auth: \"native\"\n' > services/newapp/compose.yml" \
    "people sign in to newapp, but it does not say what happens to their accounts"
broken "none without a reason" \
    "sed -i 's|mediastack.people: \"none\".*|mediastack.people: \"none\"|' services/seerr/compose.yml" \
    "seerr says none without a comment saying why"
broken "a value that is not one" \
    "sed -i 's|mediastack.people: \"follow\"|mediastack.people: \"follows\"|' services/navidrome/compose.yml" \
    "navidrome says 'follows' — follow, none or source"
broken "follow without its function" \
    "sed -i 's|mediastack.people: \"source\"|mediastack.people: \"follow\"|' services/wizarr/compose.yml" \
    "0 definitions of wizarr_people_follow() under services/"
broken "a follow function without the label" \
    "printf 'wizarr_people_follow() { :; }\n' >> services/wizarr/wizarr.sh" \
    "wizarr_people_follow() exists, but no service named wizarr is labelled follow"

# disable authentik: a tool that drops its login behind the gate brings <svc>_gate_login
broken "a tool drops its login behind the gate, with no way back" \
    "sed -i '/^bazarr_gate_login()/d' services/bazarr/bazarr.sh" \
    "gate_trusted/planned bazarr: 0 definitions of bazarr_gate_login() under services/"

echo "OK registries: $checks checks"
