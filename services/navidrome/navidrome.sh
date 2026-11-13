#!/usr/bin/env bash
# services/navidrome/navidrome.sh — Navidrome's API client, the stack's own
# admin there, and its `wire navidrome` role. Who keeps their account when
# their portal account goes is people.sh, beside this file.
# Sourced by the entrypoint; relies on lib/wire.sh and the entrypoint's
# helpers at call time.

navidrome_logins() { printf "Navidrome's admin\tNAVIDROME_ADMIN_USER\tNAVIDROME_ADMIN_PASSWORD\treserve\n"; }   # lib/logins.sh

# ---- the API (Navidrome's own, as its web UI uses it: checked against its source, Nov 2026) ----
#   POST /auth/createAdmin {username,password}   only while it has no account at all (403 after)
#   POST /auth/login {username,password}          -> {token,…}; the token goes in X-ND-Authorization
#   GET /api/user, GET|PUT /api/user/<id>         an admin's; a PUT writes the whole account
nd_url() { local p; p=$(svc_hostport navidrome) || return 1; echo "http://127.0.0.1:$p"; }
nd_api() { # nd_api METHOD PATH TOKEN [json] -> body; rc from HTTP (2xx)
    local out code
    out=$(curl -sS -m 30 -X "$1" -H "Content-Type: application/json" ${3:+-H "X-ND-Authorization: Bearer $3"} \
          ${4:+-d "$4"} -w '\n%{http_code}' "$(nd_url)$2" 2>&1) || { api_timed_out $? && api_unanswered "$1" 30 || echo "$out"; return 1; }
    code=${out##*$'\n'}; echo "${out%$'\n'*}"
    [[ "$code" =~ ^2 ]]
}
nd_ready() { http_ready navidrome "$(nd_url)/ping" '^200$'; }
nd_creds() { jq -cn --arg u "$(env_get NAVIDROME_ADMIN_USER)" --arg p "$(env_get NAVIDROME_ADMIN_PASSWORD)" '{username:$u, password:$p}'; }
nd_login() { # -> a token for the stack's admin; rc 1 + Navidrome's answer when refused
    local out tok
    out=$(nd_api POST /auth/login "" "$(nd_creds)") || { echo "$out"; return 1; }
    tok=$(jq -r '.token // empty' <<<"$out" 2>/dev/null || true)
    [[ -n "$tok" ]] || { echo "no token in its answer"; return 1; }
    echo "$tok"
}

ND_TOKEN=""   # nd_admin_ensure's token for the stack's admin (a global: it reports through wfail, which a $( ) would lose)
nd_admin_ensure() { # sign the stack's admin in, making it on a fresh install -> ND_TOKEN; rc 1 after saying why
    local user out
    ND_TOKEN=""; user=$(env_get NAVIDROME_ADMIN_USER)
    [[ -n "$user" && -n "$(env_get NAVIDROME_ADMIN_PASSWORD)" ]] \
        || { wfail "navidrome's admin login is not in .env (NAVIDROME_ADMIN_USER / NAVIDROME_ADMIN_PASSWORD) — ./mediastack.sh up records one, then re-run wire"; return 1; }
    if ND_TOKEN=$(nd_login); then return 0; fi
    ND_TOKEN=""
    # refused: either nobody exists yet (a fresh install) or the stack's admin is not one of them
    if (( WIRE_DRY )); then
        info "navidrome: the stack's admin does not sign in — the real run creates it if Navidrome has no account yet"
        return 1
    fi
    if out=$(nd_api POST /auth/createAdmin "" "$(nd_creds)"); then
        ND_TOKEN=$(jq -r '.token // empty' <<<"$out" 2>/dev/null || true)
        [[ -n "$ND_TOKEN" ]] || { wfail "navidrome made its admin but gave no token: $(oneline "$out")"; return 1; }
        ok "navidrome: admin '$user' created (the stack's own — people sign in with their own accounts)"
        return 0
    fi
    wfail "navidrome already has accounts and the stack's admin is not one of them (its first visitor became its admin). As that admin, add the user '$user' in Navidrome (Settings → Users) with the password from ./mediastack.sh credentials and admin on, then: ./mediastack.sh wire navidrome"
    return 1
}

wire_navidrome() {
    hr "wire: navidrome"
    svc_enabled navidrome || { info "navidrome not enabled — skipped"; return 0; }
    wire_gate navidrome
    nd_ready || return 0
    nd_admin_ensure || return 0
    ok "navidrome: admin login works"
    signin_is authentik || return 0
    # the timer starts only once the stack's admin signs in: started by up, its
    # first run beat this wire's createAdmin and told ops of a failure (found live)
    (( WIRE_DRY )) || people_timer_ensure
    navidrome_people_sync "$ND_TOKEN"
}
