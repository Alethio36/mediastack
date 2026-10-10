#!/usr/bin/env bash
# services/audiobookshelf/audiobookshelf.sh — Audiobookshelf's API client,
# portal sign-in (OIDC) and its `wire audiobookshelf` role.
# Sourced by the entrypoint; relies on lib/wire.sh, lib/addr.sh and the
# entrypoint's helpers at call time.

# ---- Audiobookshelf: the stack's own root account, then sign-in through the portal ----
abs_url() { local p; p=$(svc_hostport audiobookshelf) || return 1; echo "http://127.0.0.1:$p"; }
abs_api() { # abs_api METHOD PATH TOKEN [json] -> body; rc from HTTP
    local out code
    out=$(curl -sS -m 20 -X "$1" -H "Content-Type: application/json" ${3:+-H "Authorization: Bearer $3"} \
          ${4:+-d "$4"} -w '\n%{http_code}' "$(abs_url)$2" 2>&1) || { echo "$out"; return 1; }
    code=${out##*$'\n'}; echo "${out%$'\n'*}"
    [[ "$code" =~ ^2 ]]
}

abs_oidc_want() { # the sign-in settings mediastack manages in Audiobookshelf (JSON)
    local base issuer
    base=$(authentik_portal); issuer=$(authentik_oidc_issuer audiobookshelf)
    jq -cn --arg b "$base" --arg i "$issuer" --arg s "$(env_get AUTHENTIK_ABS_CLIENT_SECRET)" --arg t "$(env_get PORTAL_TITLE Mediastack)" '{
        authActiveAuthMethods: ["local", "openid"],
        authOpenIDIssuerURL: $i,
        authOpenIDAuthorizationURL: ($b + "/application/o/authorize/"),
        authOpenIDTokenURL: ($b + "/application/o/token/"),
        authOpenIDUserInfoURL: ($b + "/application/o/userinfo/"),
        authOpenIDJwksURL: ($i + "jwks/"),
        authOpenIDLogoutURL: ($i + "end-session/"),
        authOpenIDClientID: "mediastack-audiobookshelf",
        authOpenIDClientSecret: $s,
        authOpenIDTokenSigningAlgorithm: "RS256",
        authOpenIDButtonText: ("Log in with " + $t),
        authOpenIDAutoRegister: true,
        # its login page goes straight to the portal; the password form (the
        # root account: the script and the way in with the portal down) stays
        # behind /audiobookshelf/login?autoLaunch=0 — removing "local" instead
        # would switch off POST /login, which wire signs in with
        authOpenIDAutoLaunch: true,
        # no matching: by username it links a portal sign-in to any unlinked
        # account of that name, the root account included (sign up as its name
        # and you are root). Accounts are made on first sign-in, linked by sub.
        authOpenIDMatchExistingBy: null,
        authOpenIDMobileRedirectURIs: ["audiobookshelf://oauth"],
        # its own subdomain: no subfolder. Unset, Audiobookshelf builds its
        # callback as "undefined/auth/openid/callback" (found live)
        authOpenIDSubfolderForRedirectURLs: "" }'
}

abs_oidc_holds() { # abs_oidc_holds CURRENT-JSON WANT-JSON -> 0 when every managed setting is as wanted
    jq -e --argjson w "$2" '. as $c | $w | to_entries | all(.value == $c[.key])' <<<"$1" >/dev/null 2>&1
}

abs_oidc() { # Audiobookshelf signs people in through the portal (its own login stays for the stack's root account)
    local tok="$1" cur want
    cur=$(abs_api GET /api/auth-settings "$tok") || { wfail "audiobookshelf: its sign-in settings are unreadable"; return 1; }
    want=$(abs_oidc_want)
    if abs_oidc_holds "$cur" "$want"; then
        ok "audiobookshelf: sign-in through the portal"; return 0
    fi
    w_would "audiobookshelf: sign in through the portal (accounts made on first sign-in, never matched to an existing one)" || return 0
    abs_api PATCH /api/auth-settings "$tok" "$want" >/dev/null || { wfail "audiobookshelf rejected its sign-in settings"; return 1; }
    # it answers 200 while skipping a value it doesn't accept: read back
    cur=$(abs_api GET /api/auth-settings "$tok") || { wfail "audiobookshelf: its sign-in settings are unreadable after the change"; return 1; }
    abs_oidc_holds "$cur" "$want" || { wfail "audiobookshelf did not keep these sign-in settings: $(jq -r --argjson w "$want" '. as $c | $w | to_entries | map(select(.value != $c[.key]) | .key) | join(", ")' <<<"$cur")"; return 1; }
    ok "audiobookshelf: sign-in through the portal set up"
}

abs_root_rotate() { # abs_root_rotate NEW-PASSWORD — root's password, and with it every root session ends
    # Audiobookshelf ends a user's sessions only on a password change (not on
    # an unlink): refresh sessions go at once, an issued access token lasts
    # its hour. rc 1 after printing why.
    local new="$1" user old out tok
    user=$(env_get ABS_ADMIN_USER); old=$(env_get ABS_ADMIN_PASSWORD)
    [[ -n "$user" && -n "$old" ]] || { fail "no Audiobookshelf root login in .env — run: ./mediastack.sh wire audiobookshelf"; return 1; }
    out=$(abs_api POST /login "" "$(jq -cn --arg u "$user" --arg p "$old" '{username:$u, password:$p}')") \
        || { fail "audiobookshelf rejected the root login from .env: $(oneline "$out")"; return 1; }
    tok=$(jq -r '.user.accessToken // .user.token // empty' <<<"$out")
    [[ -n "$tok" ]] || { fail "audiobookshelf login returned no token"; return 1; }
    out=$(abs_api PATCH /api/me/password "$tok" "$(jq -cn --arg c "$old" --arg n "$new" '{password:$c, newPassword:$n}')") \
        || { fail "audiobookshelf refused the password change: $(oneline "$out")"; return 1; }
    env_set ABS_ADMIN_PASSWORD "$new"   # changed: the new one is the truth from here, verified or not
    out=$(abs_api POST /login "" "$(jq -cn --arg u "$user" --arg p "$new" '{username:$u, password:$p}')") \
        || { fail "audiobookshelf's root password changed (stored in .env), but signing in with it failed: $(oneline "$out")"; return 1; }
    return 0
}

abs_root_unlink() { # the root account is the stack's, never a portal identity — undo a link a username match made
    local tok="$1" out id
    out=$(abs_api GET /api/users "$tok") || { wfail "audiobookshelf: users unreadable"; return 1; }
    for id in $(jq -r '.users[] | select(.type == "root" and .hasOpenIDLink == true) | .id' <<<"$out"); do
        w_would "audiobookshelf: unlink the root account from the portal identity it was matched to, and rotate its password (ends every root session)" || continue
        abs_api PATCH "/api/users/$id/openid-unlink" "$tok" >/dev/null \
            || { wfail "audiobookshelf refused to unlink its root account from the portal — unlink it in its UI (Users → root)"; return 1; }
        if abs_root_rotate "$(authentik_secret 24)"; then
            wfail "audiobookshelf: its root account had been linked to a portal sign-in (a username match) — unlinked, and its password rotated: every root session has ended (a page already open keeps working up to an hour). Someone may have signed in as root: check authentik's events for logins to Audiobookshelf"
        else
            wfail "audiobookshelf: its root account had been linked to a portal sign-in — unlinked, but its password was NOT rotated, so anyone signed in as root stays signed in: ./mediastack.sh set-credentials audiobookshelf"
        fi
    done
    return 0
}

abs_admin_sync() { # portal-linked accounts follow `admins`; the root account (the stack's) is never touched
    local tok="$1" out admins u want
    out=$(ak_api GET "/core/users/?groups_by_name=admins&page_size=500") || { wfail "authentik: admins unreadable — Audiobookshelf rights not synced"; return 1; }
    admins=" $(jq -r '[.results[].username] | join(" ")' <<<"$out") "
    out=$(abs_api GET /api/users "$tok") || { wfail "audiobookshelf: users unreadable"; return 1; }
    while IFS= read -r u; do
        [[ -n "$u" ]] || continue
        if [[ "$admins" == *" $(jq -r '.username' <<<"$u") "* ]]; then want="admin"
        elif [[ "$(jq -r '.type' <<<"$u")" == guest ]]; then continue   # below user by the operator's choice: kept
        else want="user"; fi
        [[ "$(jq -r '.type' <<<"$u")" == "$want" ]] && continue
        w_would "audiobookshelf: $(jq -r '.username' <<<"$u") becomes $want" || continue
        abs_api PATCH "/api/users/$(jq -r '.id' <<<"$u")" "$tok" "$(jq -cn --arg t "$want" '{type:$t}')" >/dev/null \
            && ok "audiobookshelf: $(jq -r '.username' <<<"$u") is $want" || wfail "audiobookshelf rejected the change for $(jq -r '.username' <<<"$u")"
    done < <(jq -c '.users[] | select(.hasOpenIDLink == true and .type != "root")' <<<"$out")
    return 0
}

wire_audiobookshelf() {
    hr "wire: audiobookshelf"
    svc_enabled audiobookshelf || { info "audiobookshelf not enabled — skipped"; return 0; }
    wire_gate audiobookshelf
    http_ready audiobookshelf "$(abs_url)/healthcheck" '^2' || return 1
    local st user pass out tok
    st=$(abs_api GET /status "") || { wfail "audiobookshelf: status unreadable"; return 1; }
    user=$(env_get ABS_ADMIN_USER); pass=$(env_get ABS_ADMIN_PASSWORD)
    if [[ "$(jq -r '.isInit' <<<"$st")" != true ]]; then
        w_would "create Audiobookshelf's root account — the stack's own (see: credentials)" || return 0
        [[ -n "$user" ]] || user=mediastack
        [[ -n "$pass" ]] || pass=$(authentik_secret 24)
        abs_api POST /init "" "$(jq -cn --arg u "$user" --arg p "$pass" '{newRoot:{username:$u, password:$p}}')" >/dev/null \
            || { wfail "audiobookshelf refused its first-run setup"; return 1; }
        env_set ABS_ADMIN_USER "$user"; env_set ABS_ADMIN_PASSWORD "$pass"
        ok "audiobookshelf: root account '$user' created (the stack's own — people sign in with their own accounts)"
    elif [[ -z "$user" || -z "$pass" ]]; then
        wfail "audiobookshelf was set up by hand and its root login is not in .env. Either put it there (ABS_ADMIN_USER / ABS_ADMIN_PASSWORD), or start it fresh — this deletes its users, libraries and progress:
       ./mediastack.sh disable audiobookshelf && sudo mv \"$(env_get CONFIG_ROOT)/audiobookshelf\" \"$(env_get CONFIG_ROOT)/audiobookshelf.old\" && ./mediastack.sh enable audiobookshelf && ./mediastack.sh wire audiobookshelf"
        return 1
    fi
    (( WIRE_DRY )) && [[ -z "$(env_get ABS_ADMIN_PASSWORD)" ]] && return 0
    out=$(abs_api POST /login "" "$(jq -cn --arg u "$(env_get ABS_ADMIN_USER)" --arg p "$(env_get ABS_ADMIN_PASSWORD)" '{username:$u, password:$p}')") \
        || { wfail "audiobookshelf rejected the root login from .env"; return 1; }
    tok=$(jq -r '.user.accessToken // .user.token // empty' <<<"$out")
    [[ -n "$tok" ]] || { wfail "audiobookshelf login returned no token"; return 1; }
    ok "audiobookshelf: root login works"
    svc_enabled authentik || return 0
    abs_oidc "$tok" || return 1
    abs_root_unlink "$tok"
    abs_admin_sync "$tok"
}
