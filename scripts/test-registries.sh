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

# set-credentials: every declared login has its rotation; nothing without a login
broken "a login without its rotation" \
    "sed -i 's/^sc_rotate_kavita() {/kav_rotate_gone() {/' services/kavita/kavita.sh" \
    "FAIL set-credentials (kavita_logins): 0 definitions of sc_rotate_kavita()"
broken "a target renamed on the login, not on its rotation" \
    "sed -i 's/target=qbit /target=qbt /' services/qbittorrent/qbittorrent.sh" \
    "FAIL set-credentials (qbittorrent_logins): 0 definitions of sc_rotate_qbt()"
broken "a rotation nobody's login names" \
    "printf 'sc_rotate_ghost() { :; }\\n' >> services/kavita/kavita.sh" \
    "sc_rotate_ghost() exists, but no login names the target ghost"
broken "an explanation for no target" \
    "printf 'sc_explain_ghost() { :; }\\n' >> services/kavita/kavita.sh" \
    "sc_explain_ghost() exists, but no login names the target ghost"
broken "a companion key for no service" \
    "printf 'ghost_api_key() { :; }\\n' >> services/kavita/kavita.sh" \
    "ghost_api_key() exists, but there is no service ghost"
broken "a credentials note for no service" \
    "printf 'ghost_credentials() { :; }\\n' >> services/kavita/kavita.sh" \
    "ghost_credentials() exists, but there is no service ghost"

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

# a route that adds a tool's login past the gate names a middleware its hook defines
broken "a route adds a login no hook defines" \
    "sed -i '/^transmission_login_middleware()/,/^}/d' services/transmission/transmission.sh" \
    "mediastack.auth.inject transmission: 0 definitions of transmission_login_middleware() under services/"
broken "a hook no route uses" \
    "sed -i '/mediastack.auth.inject/d' services/transmission/compose.yml" \
    "transmission_login_middleware() exists, but transmission has no mediastack.auth.inject"
broken "a card path that does not follow the address" \
    "sed -i 's|mediastack.card.path: \"/oidc/login\"|mediastack.card.path: \"oidc/login\"|' services/kavita/compose.yml" \
    "mediastack.card.path in services/kavita/compose.yml is \"oidc/login\": it follows the app's address, so it starts with /"

# a service's hooks live in its folder, and a hook found by name needs that name
broken "a hook in another service's folder" \
    "sed -i '/^dispatcharr_provision()/,/^}/d' services/dispatcharr/dispatcharr.sh && printf 'dispatcharr_provision() { :; }\\n' >> services/kavita/kavita.sh" \
    "dispatcharr_provision() is dispatcharr's hook, but lives in services/kavita/kavita.sh"
broken "a hook in lib/ instead of its folder" \
    "printf 'kavita_questions() { :; }\\n' >> lib/common.sh" \
    "kavita_questions() is kavita's hook, but lives in lib/common.sh"
broken "a hook named for no service (a typo)" \
    "sed -i 's/^dispatcharr_provision()/dispatchar_provision()/' services/dispatcharr/dispatcharr.sh" \
    "dispatchar_provision() is a hook found by its service's name, but no service is named dispatchar"
# an app behind the portal ships its icon, and its icon says where it is from
broken "an app behind the portal without its icon" \
    "rm services/dispatcharr/icon.png" \
    "dispatcharr is behind the portal but ships no icon.png"
broken "an icon without its licence" \
    "python3 -I -c 'import sys; p=sys.argv[1]; d=open(p,\"rb\").read(); open(p,\"wb\").write(d.replace(b\"tEXtLicense\", b\"tEXtLicensX\"))' services/kavita/icon.png" \
    "services/kavita/icon.png carries no License text field"

echo "OK registries: $checks checks"
