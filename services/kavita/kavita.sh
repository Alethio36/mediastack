#!/usr/bin/env bash
# services/kavita/kavita.sh — Kavita's API client, portal sign-in (OIDC)
# and its `wire kavita` role.
# Sourced by the entrypoint; relies on lib/wire.sh, lib/addr.sh and the
# entrypoint's helpers at call time.

kavita_logins() { printf "Kavita's admin\tKAVITA_ADMIN_USER\tKAVITA_ADMIN_PASSWORD\treserve pw_max=256 user_re=^[A-Za-z0-9._@+/-]+$\n"; }   # lib/logins.sh; Kavita's own limits

# ---- Kavita: the stack's own admin, then sign-in through the portal ----
# Its OIDC is set up once at start-up (from its appsettings.json): a change to
# the authority, client or secret needs one restart; the rest (defaults,
# auto-login) is read per request.
KAV_ADMIN_ROLE="Admin"
kav_url() { local p; p=$(svc_hostport kavita) || return 1; echo "http://127.0.0.1:$p"; }
kav_api() { # kav_api METHOD PATH TOKEN [json] -> body; rc from HTTP
    local out code
    out=$(curl -sS -m 30 -X "$1" -H "Content-Type: application/json" ${3:+-H "Authorization: Bearer $3"} \
          ${4:+-d "$4"} -w '\n%{http_code}' "$(kav_url)$2" 2>&1) || { api_timed_out $? && api_unanswered "$1" 30 || echo "$out"; return 1; }
    code=${out##*$'\n'}; echo "${out%$'\n'*}"
    [[ "$code" =~ ^2 ]]
}
kav_ready() { http_ready kavita "$(kav_url)/api/health" '^200$'; }
kav_login() { # kav_login [USER PASS] -> a token for the stack's own admin (or USER); rc 1, the reason in its place — the one way in (wire, doctor, people-sync, link-account, rotation)
    local u=${1-$(env_get KAVITA_ADMIN_USER)} p=${2-$(env_get KAVITA_ADMIN_PASSWORD)} out tok
    out=$(kav_api POST /api/account/login "" "$(jq -cn --arg u "$u" --arg p "$p" '{username:$u, password:$p}')") \
        || { echo "kavita rejected the stored admin login: $(oneline "$out")"; return 1; }
    tok=$(jq -r '.token // empty' <<<"$out")
    [[ -n "$tok" ]] || { echo "kavita's login returned no token"; return 1; }
    echo "$tok"
}

kav_oidc_want() { # kav_oidc_want LIBRARY-IDS-JSON -> the sign-in settings mediastack manages (Kavita's oidcConfig keys)
    jq -cn --arg i "$(authentik_oidc_issuer kavita)" --arg t "$(env_get PORTAL_TITLE)" --argjson l "$1" '{
        authority: $i, clientId: "mediastack-kavita",
        # created on first sign-in; authentik sends email_verified false until
        # it can send mail, so a verified-email requirement would refuse everyone
        provisionAccounts: true, requireVerifiedEmail: false,
        # rights stay Kavita-side: new people get these, wire keeps Admin in
        # step with the portal admin group, restrictions set in its UI are kept
        syncUserSettings: false,
        defaultRoles: ["Login", "Download", "Bookmark"],
        defaultLibraries: ($l | sort), defaultAgeRestriction: -1, defaultIncludeUnknowns: true,
        # its login page goes straight to the portal; the password form (the
        # stack admin: the script and the way in with the portal down) stays
        # at /login?skipAutoLogin=true — password sign-in stays on for that
        autoLogin: true, disablePasswordAuthentication: false,
        providerName: $t }'
}
kav_oidc_holds() { # kav_oidc_holds SETTINGS-JSON WANT-JSON -> 0 when every managed key is as wanted
    jq -e --argjson w "$2" '.oidcConfig as $c | $w | to_entries
        | all(if .key == "defaultLibraries" then ((.value | sort) == (($c[.key] // []) | sort)) else .value == $c[.key] end)' <<<"$1" >/dev/null 2>&1
}
kav_secret_mark() { sha256sum <<<"$(env_get AUTHENTIK_KAVITA_CLIENT_SECRET)" | cut -c1-16; }

kav_stats_off() { # TOKEN — Kavita's anonymous stats (sent daily), off once: turned back on in its UI, they stay on
    local tok="$1" cur out
    cur=$(kav_api GET /api/settings "$tok") || { wfail "kavita: its settings are unreadable: $(oneline "$cur")"; return 0; }
    case "$(jq -r '.allowStatCollection' <<<"$cur")" in
        false) [[ -n "$(state_get KAVITA_STATS_OFF)" ]] || state_set KAVITA_STATS_OFF 1; ok "kavita: no usage stats sent"; return 0 ;;
        true)  [[ -z "$(state_get KAVITA_STATS_OFF)" ]] || { ok "kavita: usage stats were turned on in its UI — untouched"; return 0; } ;;
        *)     wfail "kavita: its stats setting is unreadable: $(oneline "$cur")"; return 0 ;;
    esac
    # Kavita tells its stats server once that this install opted out (its own behaviour)
    w_would "kavita: stop its anonymous usage stats (sent daily to Kavita's server)" || return 0
    # the whole settings object goes back: Kavita keeps a masked OIDC secret as it was
    out=$(kav_api POST /api/settings "$tok" "$(jq -c '.allowStatCollection = false' <<<"$cur")") \
        || { wfail "kavita refused to stop its usage stats: $(oneline "$out")"; return 0; }
    cur=$(kav_api GET /api/settings "$tok") || { wfail "kavita: its settings are unreadable after the change: $(oneline "$cur")"; return 0; }
    [[ "$(jq -r '.allowStatCollection' <<<"$cur")" == false ]] || { wfail "kavita answered but still sends usage stats"; return 0; }
    state_set KAVITA_STATS_OFF 1; ok "kavita: usage stats stopped"
}

kav_oidc() { # Kavita signs people in through the portal; one restart when its start-up settings change
    local tok="$1" cur libs want new restart=0 miss pub
    cur=$(kav_api GET /api/settings "$tok") || { wfail "kavita: its settings are unreadable: $(oneline "$cur")"; return 1; }
    libs=$(kav_api GET /api/library/libraries "$tok") || { wfail "kavita: its libraries are unreadable: $(oneline "$libs")"; return 1; }
    want=$(kav_oidc_want "$(jq -c '[.[].id]' <<<"$libs")")
    # its secret reads back masked: what was applied is remembered by a digest
    if kav_oidc_holds "$cur" "$want" && [[ "$(state_get KAVITA_OIDC_SECRET)" == "$(kav_secret_mark)" ]]; then
        ok "kavita: sign-in through the portal ($(jq length <<<"$libs") librar$( (( $(jq length <<<"$libs") == 1 )) && echo y || echo ies) for new people)"
    else
        jq -e --argjson w "$want" '.oidcConfig.authority == $w.authority and .oidcConfig.clientId == $w.clientId' <<<"$cur" >/dev/null \
            && [[ "$(state_get KAVITA_OIDC_SECRET)" == "$(kav_secret_mark)" ]] || restart=1
        w_would "kavita: sign in through the portal (new people get every current library)$( ((restart)) && echo ' — one restart')" || return 0
        new=$(jq -c --argjson w "$want" --arg s "$(env_get AUTHENTIK_KAVITA_CLIENT_SECRET)" '.oidcConfig = (.oidcConfig + $w + {secret: $s})' <<<"$cur")
        cur=$(kav_api POST /api/settings "$tok" "$new") || { wfail "kavita rejected its sign-in settings: $(oneline "$cur")"; return 1; }
        # it can answer 200 after rolling back (its authority check reaches the portal from inside the stack)
        cur=$(kav_api GET /api/settings "$tok") || { wfail "kavita: its settings are unreadable after the change"; return 1; }
        if ! kav_oidc_holds "$cur" "$want"; then
            miss=$(jq -r --argjson w "$want" '.oidcConfig as $c | $w | to_entries | map(select(.value != $c[.key]) | .key) | join(", ")' <<<"$cur")
            wfail "kavita did not keep these sign-in settings: $miss — if 'authority' is among them, Kavita could not reach $(authentik_oidc_issuer kavita).well-known/openid-configuration (production certificates are required): ./mediastack.sh logs kavita --no-follow"
            return 1
        fi
        state_set KAVITA_OIDC_SECRET "$(kav_secret_mark)"
        ok "kavita: sign-in through the portal set up"
    fi
    # set up at start-up: a restart when that part changed, or when it is not live yet
    pub=$(kav_api GET /api/settings/oidc "") || { wfail "kavita: its public sign-in settings are unreadable"; return 1; }
    [[ "$(jq -r '.enabled' <<<"$pub")" == true ]] || restart=1
    (( restart )) || return 0
    w_would "kavita: restart once (its sign-in through the portal starts with it)" || return 0
    notify_interruption "Books: a quick restart" "Kavita restarts to switch on sign-in through $(env_get PORTAL_TITLE) — back in about a minute."
    DC restart kavita >/dev/null || { wfail "kavita did not restart — ./mediastack.sh logs kavita"; return 1; }
    kav_ready || return 1
    pub=$(kav_api GET /api/settings/oidc "") || { wfail "kavita: its public sign-in settings are unreadable after the restart"; return 1; }
    [[ "$(jq -r '.enabled' <<<"$pub")" == true ]] \
        && ok "kavita: restarted — the portal button is live" \
        || { wfail "kavita restarted but sign-in through the portal is not live (it checks the portal at start-up) — inspect: ./mediastack.sh logs kavita --no-follow | grep -i openid"; return 1; }
}

kav_account_body() { # kav_account_body USER-JSON -> its account update, everything as it is (callers change one field)
    # Kavita's update takes the whole account: whatever is left out is reset
    jq -c '{
        userId: .id, username: .username, email: .email, identityProvider: .identityProvider,
        roles: [.roles[]?], libraries: [.libraries[]?.id],
        # no restriction recorded = none; a recorded one goes back exactly (not //: it drops false)
        ageRestriction: (if .ageRestriction == null then {ageRating: -1, includeUnknowns: true}
                         else {ageRating: .ageRestriction.ageRating, includeUnknowns: .ageRestriction.includeUnknowns} end) }' <<<"$1"
}

kav_email_move() { # kav_email_move OLD NEW — the Kavita account signed in by OLD now answers to NEW; rc 1 after saying why
    local out tok u back
    tok=$(kav_login) || { fail "$tok"; return 1; }
    out=$(kav_api GET "/api/users?includePending=true" "$tok") || { fail "kavita: users unreadable: $(oneline "$out")"; return 1; }
    u=$(jq -c --arg e "${1,,}" '[.[] | select((.email // "" | ascii_downcase) == $e)] | first // empty' <<<"$out")
    [[ -n "$u" ]] || { info "kavita: no account answers to the old email — nothing to move"; return 0; }
    out=$(kav_api POST /api/account/update "$tok" "$(kav_account_body "$u" | jq -c --arg e "$2" '.email = $e')") \
        || { fail "kavita rejected the new email for $(jq -r '.username' <<<"$u"): $(oneline "$out")"; return 1; }
    back=$(kav_api GET "/api/users?includePending=true" "$tok") \
        && jq -e --argjson i "$(jq '.id' <<<"$u")" --arg e "$2" '.[] | select(.id == $i) | .email == $e' <<<"$back" >/dev/null \
        || { fail "kavita answered for $(jq -r '.username' <<<"$u") but the email did not change"; return 1; }
    ok "kavita: $(jq -r '.username' <<<"$u") now answers to $2 (same account, same reading progress)"
}

kav_admin_sync() { # portal accounts follow the admin group; the stack's admin and local accounts are never touched
    local tok="$1" out admins u body want has back
    out=$(signin_admins) || { wfail "authentik: the $PORTAL_ADMIN group is unreadable — Kavita rights not synced: $(oneline "$out")"; return 0; }
    admins=" $(jq -r '[.results[].username] | join(" ")' <<<"$out") "
    # people made through the portal have no confirmed email (authentik cannot
    # vouch for one yet): Kavita lists them only with includePending
    out=$(kav_api GET "/api/users?includePending=true" "$tok") || { wfail "kavita: users unreadable: $(oneline "$out")"; return 0; }
    while IFS= read -r u; do
        [[ -n "$u" ]] || continue
        want=false; [[ "$admins" == *" $(jq -r '.username' <<<"$u") "* ]] && want=true
        has=$(jq --arg a "$KAV_ADMIN_ROLE" '[.roles[]?] | index($a) != null' <<<"$u")
        [[ "$has" == "$want" ]] && continue
        w_would "kavita: $(jq -r '.username' <<<"$u") $( [[ $want == true ]] && echo becomes || echo 'is no longer' ) admin" || continue
        body=$(kav_account_body "$u" | jq -c --arg a "$KAV_ADMIN_ROLE" --argjson w "$want" \
            '.roles = (if $w then (.roles + [$a] | unique) else [.roles[] | select(. != $a)] end)')
        out=$(kav_api POST /api/account/update "$tok" "$body") \
            || { wfail "kavita rejected the change for $(jq -r '.username' <<<"$u"): $(oneline "$out")"; continue; }
        back=$(kav_api GET "/api/users?includePending=true" "$tok") \
            && jq -e --argjson i "$(jq '.id' <<<"$u")" --arg a "$KAV_ADMIN_ROLE" --argjson w "$want" \
                '.[] | select(.id == $i) | ([.roles[]?] | index($a) != null) == $w' <<<"$back" >/dev/null \
            && ok "kavita: $(jq -r '.username' <<<"$u") $( [[ $want == true ]] && echo 'is admin' || echo 'is no longer admin' )" \
            || wfail "kavita answered for $(jq -r '.username' <<<"$u") but the change did not hold"
    done < <(jq -c '.[] | select(.identityProvider == 1)' <<<"$out")
    return 0
}

kav_admin_email_check() { # the stack's admin must carry an email nobody can sign up with (Kavita matches by email)
    local tok="$1" out email
    out=$(kav_api GET "/api/users?includePending=true" "$tok") || return 0   # admin sync reports the same read
    email=$(jq -r --arg u "$(env_get KAVITA_ADMIN_USER)" '.[] | select((.username | ascii_downcase) == ($u | ascii_downcase)) | .email // ""' <<<"$out")
    [[ "$email" == *.invalid ]] && return 0
    warn "kavita: the stack's admin has the email '$email' — Kavita signs a portal user in as whichever account has their email, so anyone who signs up with it becomes this admin. Change it in Kavita (as this admin: Settings → Account) to one nobody else has, e.g. $(env_or_note KAVITA_ADMIN_USER mediastack)@$(gen_secret 12 | tr '[:upper:]' '[:lower:]').invalid"
}

wire_kavita() {
    hr "wire: kavita"
    svc_enabled kavita || { info "kavita not enabled — skipped"; return 0; }
    wire_gate kavita
    kav_ready || return 0
    local exists user pass email out tok
    exists=$(kav_api GET /api/admin/exists "") || { wfail "kavita: first-run state unreadable: $(oneline "$exists")"; return 0; }
    user=$(env_get KAVITA_ADMIN_USER); pass=$(env_get KAVITA_ADMIN_PASSWORD)
    if [[ "$exists" != true ]]; then
        w_would "create Kavita's admin — the stack's own (see: credentials)" || return 0
        [[ -n "$user" && -n "$pass" ]] \
            || { wfail "kavita's admin login is not in .env (KAVITA_ADMIN_USER / KAVITA_ADMIN_PASSWORD) — ./mediastack.sh up records one, then re-run wire"; return 0; }
        # never the username (its default): Kavita matches a portal sign-in by email
        email=$(env_get KAVITA_ADMIN_EMAIL); [[ -n "$email" ]] || email="$user@$(gen_secret 12 | tr '[:upper:]' '[:lower:]').invalid"
        out=$(kav_api POST /api/account/register "" "$(jq -cn --arg u "$user" --arg p "$pass" --arg e "$email" '{username:$u, password:$p, email:$e}')") \
            || { wfail "kavita refused its first-run setup: $(oneline "$out")"; return 0; }
        env_set KAVITA_ADMIN_EMAIL "$email"
        ok "kavita: admin '$user' created (the stack's own — people sign in with their own accounts)"
    elif [[ -z "$user" || -z "$pass" ]]; then
        wfail "kavita was set up by hand and its admin login is not in .env. Either put it there (KAVITA_ADMIN_USER / KAVITA_ADMIN_PASSWORD), or start it fresh — this deletes its users, libraries and reading progress:
       ./mediastack.sh disable kavita && sudo mv \"$(env_get CONFIG_ROOT)/kavita\" \"$(env_get CONFIG_ROOT)/kavita.old\" && ./mediastack.sh enable kavita && ./mediastack.sh wire kavita"
        return 0
    fi
    (( WIRE_DRY )) && [[ -z "$(env_get KAVITA_ADMIN_PASSWORD)" ]] && return 0
    tok=$(kav_login) || { wfail "$tok — set up by hand? Put its admin login in .env (KAVITA_ADMIN_USER / KAVITA_ADMIN_PASSWORD)"; return 0; }
    ok "kavita: admin login works"
    kav_stats_off "$tok"
    signin_is authentik || return 0
    kav_admin_email_check "$tok"
    if ! certs_trusted; then
        # Kavita checks the portal's address over TLS and refuses the staging
        # certificate (SslStream handshake in IsValidAuthority, seen live)
        warn "kavita: sign-in through the portal needs real certificates — Kavita refuses the staging one. Skipped; after: ./mediastack.sh traefik-setup --certs, run: ./mediastack.sh wire kavita"
        return 0
    fi
    kav_oidc "$tok" || return 0
    people_follow_on kavita
    kav_admin_sync "$tok"
}

kavita_people_follow() { # lib/people.sh: the stack's admin signs in, then who may sign in, then admin rights
    local tok
    tok=$(kav_login) || { wfail "$tok — ./mediastack.sh wire kavita says why"; return 0; }
    kav_people_access "$tok"
    kav_admin_sync "$tok"
}

# who may sign in (docs/design-access.md, decisions 11-12): the portal refuses
# a sign-in first (Kavita's card is its OIDC application, bound by the rule).
# Its Login role goes too, so Kavita refuses them wherever they come from —
# and Kavita never syncs roles from the portal (syncUserSettings off), so the
# change holds. A tab already open keeps reading until it reloads: Kavita
# re-checks no role while it runs (15 minutes and more, proven live) and lets
# an admin end no one else's session (decision 15, a known gap kept). Allowed again, only someone the
# stack took it from (local/kavita-people) gets Login back; someone an admin
# shut out by hand stays out. A person deleted from the portal is also renamed
# removed-<name>-<date> and given an email nobody can sign up with: Kavita
# links a portal sign-in by email, so a newcomer with that email would
# otherwise take the old account over. Portal accounts only (identityProvider
# 1); the stack's admin and local accounts are never touched.
KAV_LOGIN_ROLE="Login"
kav_person_set() { # kav_person_set TOKEN USER-JSON JQ-EDIT CHECK — the account changed (KAV_BODY's edit), then read back (CHECK on it)
    local out back
    out=$(kav_api POST /api/account/update "$1" "$(kav_account_body "$2" | jq -c "$3")") || { echo "Kavita refused it: $(oneline "$out")"; return 1; }
    back=$(kav_api GET "/api/users?includePending=true" "$1") || { echo "it answered, but its people are unreadable now"; return 1; }
    jq -e --argjson i "$(jq '.id' <<<"$2")" ".[] | select(.id == \$i) | $4" <<<"$back" >/dev/null || { echo "it answered, but the change did not hold"; return 1; }
}

kav_people_access() { # kav_people_access TOKEN — portal accounts follow the rule (see above)
    local tok=$1 portal users u name pu st why out new lr=$KAV_LOGIN_ROLE has
    portal=$(signin_people) || { wfail "authentik: its people are unreadable — Kavita's sign-ins not checked: $(oneline "$portal")"; return 0; }
    # a group the rule reads missing: nobody would be in it — everyone shut out, unasked
    why=$(people_rule_ready) || { wfail "$why — Kavita's sign-ins left as they are"; return 0; }
    users=$(kav_api GET "/api/users?includePending=true" "$tok") || { wfail "kavita: users unreadable: $(oneline "$users")"; return 0; }
    while IFS= read -r u; do
        [[ -n "$u" ]] || continue
        name=$(jq -r '.username' <<<"$u")
        st=$(people_get kavita "$name")
        [[ "$st" == removed ]] && continue   # a deleted person's, renamed: never looked at again
        has=$(jq --arg r "$lr" '[.roles[]?] | index($r) != null' <<<"$u")
        pu=$(jq -c --arg n "${name,,}" '[.results[]? | select((.username | ascii_downcase) == $n)][0] // empty' <<<"$portal")
        if [[ -n "$pu" ]] && people_may "$pu" kavita; then
            [[ "$st" == off ]] || continue
            if [[ "$has" == true ]]; then (( WIRE_DRY )) || people_set kavita "$name" ""; continue; fi   # an admin gave it back already
            w_would "kavita: '$name' may sign in again" || continue
            if out=$(kav_person_set "$tok" "$u" ".roles = (.roles + [\"$lr\"] | unique)" "([.roles[]?] | index(\"$lr\") != null)"); then
                people_set kavita "$name" ""
                ok "kavita: '$name' may sign in again — through the portal, their reading as they left it"
            else wfail "kavita: '$name' may open Kavita again, but still cannot sign in — $out"; fi
            continue
        fi
        if [[ -z "$pu" ]]; then   # deleted from the portal: shut out, then renamed with an email nobody can sign up with
            new="removed-$name-$(date +%Y%m%d)"
            w_would "kavita: '$name' (portal account deleted) cannot sign in, kept as '$new' — their reading stays, the name and email free for someone new" || continue
            if ! out=$(kav_person_set "$tok" "$u" ".roles = [.roles[] | select(. != \"$lr\" and . != \"$KAV_ADMIN_ROLE\")] | .username = \"$new\" | .email = \"$new@removed.invalid\"" \
                       ".username == \"$new\" and .email == \"$new@removed.invalid\" and ([.roles[]?] | index(\"$lr\") == null)"); then
                wfail "kavita: '$name' (portal account deleted) still signs in — $out"; continue
            fi
            people_set kavita "$name" ""; people_set kavita "$new" removed
            ok "kavita: '$name' can no longer sign in (portal account deleted) — kept as '$new'"
            notify ops "Kavita" "$name can no longer sign in to Kavita: their portal account was deleted. Their Kavita account is kept as $new." info
            continue
        fi
        [[ "$has" == true ]] || continue   # shut out already: the stack's (recorded) or an admin's (left)
        if [[ "$(jq -r '.is_active' <<<"$pu")" != true ]]; then why="portal account deactivated"
        else why="may no longer open Kavita"; fi
        w_would "kavita: '$name' ($why) cannot sign in from now on — an open tab ends at its next reload; their reading stays" || continue
        if ! out=$(kav_person_set "$tok" "$u" ".roles = [.roles[] | select(. != \"$lr\")]" "([.roles[]?] | index(\"$lr\") == null)"); then
            wfail "kavita: '$name' ($why) still signs in — $out"; continue
        fi
        people_set kavita "$name" off
        ok "kavita: '$name' can no longer sign in ($why) — an open tab ends at its next reload"
        notify ops "Kavita" "$name can no longer sign in to Kavita: $why. Allowed again, they sign in through the portal as before." info
    done < <(jq -c '.[] | select(.identityProvider == 1)' <<<"$users")
    return 0
}

sc_explain_kavita() { echo "The admin is the stack's own account (people sign in with their own).
Only this password and .env move."; }   # set-credentials kavita (lib/access.sh)
kavita_credentials() { # credentials (lib/access.sh): where its admin signs in, past the portal's redirect
    signin_is authentik && printf 'at\t%s\n' "$(svc_url kavita)/login?skipAutoLogin=true   (its login page otherwise goes straight to the portal)"
    return 0
}
sc_rotate_kavita() { # PASS — its admin (the stack's own), changed with the old one, then proven
        svc_enabled kavita || { info "kavita not enabled — skipped"; return 0; }
        local new="$1" user old out tok
        user=$(env_get KAVITA_ADMIN_USER); old=$(env_get KAVITA_ADMIN_PASSWORD)
        [[ -n "$user" && -n "$old" ]] || die "no Kavita admin stored — run 'wire kavita' first"
        tok=$(kav_login "$user" "$old") || die "$tok — is .env stale?"
        out=$(kav_api POST /api/account/reset-password "$tok" "$(jq -cn --arg u "$user" --arg c "$old" --arg n "$new" '{userName:$u, oldPassword:$c, password:$n}')") \
            || die "Kavita refused the password change: $(oneline "$out")"
        env_set KAVITA_ADMIN_PASSWORD "$new"   # changed: the new one is the truth from here, verified or not
        kav_login "$user" "$new" >/dev/null \
            || die "Kavita's admin password changed (stored in .env), but signing in with it failed"
        ok "Kavita admin password rotated and verified"
}

kavita_doctor() { # claimed; with the portal, who among its people lacks a library (maybe on purpose)
    local ex out tok libs users gaps
    ex=$(kav_api GET /api/admin/exists "" 2>/dev/null) || { warn "kavita first-run state unreadable — API may still be warming up"; return 0; }
    [[ "$ex" == true ]] || { d_fail "kavita has no admin yet" "an unclaimed Kavita lets any visitor create the admin account" "./mediastack.sh wire kavita"; return 0; }
    ok "kavita has its admin"
    signin_is authentik && [[ -n "$(env_get KAVITA_ADMIN_PASSWORD)" ]] || return 0
    tok=$(kav_login) || { d_fail "kavita rejects the stored admin login" "wire and doctor cannot manage it" "./mediastack.sh credentials  # then check the admin in Kavita"; return 0; }
    libs=$(kav_api GET /api/library/libraries "$tok") && users=$(kav_api GET "/api/users?includePending=true" "$tok") \
        || { warn "kavita: libraries or users unreadable"; return 0; }
    # a library added after someone joined reaches only admins until granted —
    # reported, never changed: a missing library may be a restriction you set
    gaps=$(jq -r --argjson l "$libs" '.[] | select(.identityProvider == 1 and ([.roles[]?] | index("Admin") == null))
        | . as $u | [$l[] | select(.id as $i | [$u.libraries[]?.id] | index($i) == null) | .name]
        | select(length > 0) | "\($u.username): \(join(", "))"' <<<"$users")
    if [[ -z "$gaps" ]]; then ok "kavita: every portal user has every library"
    else
        while IFS= read -r g; do warn "kavita: $g — not granted (fine if on purpose; otherwise Kavita → Settings → Users → edit → libraries)"; done <<<"$gaps"
    fi
}

# ---- link-account: Kavita's part (the verb: lib/link.sh) ----
link_kav_candidates() { # USERS-JSON -> its local accounts, the stack's admin left out
    jq -c --arg s "$(env_get KAVITA_ADMIN_USER)" '[.[] | select(.identityProvider == 0 and (.username | ascii_downcase) != ($s | ascii_downcase))
        | {name: .username, id: .id, admin: ([.roles[]?] | index("Admin") != null)}]' <<<"$1"
}
link_kav_conflict() { # USERS-JSON CANDIDATE PORTAL-USER EMAIL -> why the link would collide ("" = none)
    jq -r --argjson id "$(jq '.id' <<<"$2")" --arg w "${3,,}" --arg e "${4,,}" '[.[] | select(.id != $id) |
        if (.username | ascii_downcase) == $w then "Kavita already has an account named \(.username)"
        elif ((.email // "") | ascii_downcase) == $e then "Kavita account \(.username) already has \($e)"
        else empty end] | first // empty' <<<"$1"
}
link_kav_do() { # TOKEN CANDIDATE PORTAL-USER EMAIL
    local tok="$1" id who="$3" email="$4" users u body
    id=$(jq '.id' <<<"$2")
    users=$(kav_api GET "/api/users?includePending=true" "$tok") || { fail "kavita: users unreadable: $(oneline "$users")"; return 1; }
    u=$(jq -c --argjson i "$id" '.[] | select(.id == $i)' <<<"$users")
    # the whole record goes back: the name, the portal email and the portal flag change, nothing else
    body=$(jq -c --arg n "$who" --arg e "$email" '{
        userId: .id, username: $n, email: $e, identityProvider: 1,
        roles: [.roles[]?], libraries: [.libraries[]?.id],
        ageRestriction: (if .ageRestriction == null then {ageRating: -1, includeUnknowns: true}
                         else {ageRating: .ageRestriction.ageRating, includeUnknowns: .ageRestriction.includeUnknowns} end) }' <<<"$u")
    u=$(kav_api POST /api/account/update "$tok" "$body") || { fail "kavita refused the change: $(oneline "$u")"; return 1; }
    # its own password is of no use now: replaced, so only the portal signs in
    u=$(kav_api POST /api/account/reset-password "$tok" "$(jq -cn --arg n "$who" --arg p "$(link_secret)" '{userName:$n, password:$p}')") \
        || { fail "kavita refused to replace the account's own password: $(oneline "$u")"; return 1; }
    users=$(kav_api GET "/api/users?includePending=true" "$tok") \
        && jq -e --argjson i "$id" --arg n "$who" --arg e "${email,,}" \
            '.[] | select(.id == $i) | .username == $n and ((.email // "") | ascii_downcase) == $e and .identityProvider == 1' <<<"$users" >/dev/null \
        || { fail "kavita answered, but the account does not read back as '$who' with the portal email"; return 1; }
    ok "kavita: '$who' is linked at their next sign-in through the portal (same account: reading progress kept)"
}
