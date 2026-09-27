# shellcheck shell=bash
# link.sh — `link-account`: a person's existing local accounts in Jellyfin,
# Kavita and Audiobookshelf become their portal account, history kept.
#
# Never by name or email matching on its own: the operator confirms which local
# account is whose, and each app is linked through its own mechanism —
#   Jellyfin        the account's login method becomes the LDAP plugin (which
#                   then adopts it by name): same user, watch history kept
#   Kavita          its email becomes the portal account's (Kavita links a
#                   portal sign-in by email): reading progress kept
#   Audiobookshelf  its API cannot set the link, so username matching opens
#                   for one sign-in, fenced: no other account could match,
#                   closed by a subshell's EXIT trap (the caller's traps untouched)
# The stack's own accounts are never offered.

LINK_ABS_WAIT=600   # seconds the Audiobookshelf window stays open for the person's sign-in

link_secret() { head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24; }

link_pick() { # link_pick APP CANDIDATES-JSON PORTAL-USER -> LINK_PICK: the chosen candidate ("" = leave the app)
    local app="$1" cands="$2" who="$3" n i def
    LINK_PICK=""
    n=$(jq length <<<"$cands")
    (( n )) || { info "$app: no local accounts to link"; return 0; }
    def=$(jq -r --arg w "${who,,}" '(map(.name | ascii_downcase) | index($w)) as $i | if $i == null then 0 else $i + 1 end' <<<"$cands")
    echo "  $app — local accounts:"
    echo "    0) none — leave $app as it is"
    for ((i = 0; i < n; i++)); do printf '    %d) %s\n' $((i + 1)) "$(jq -r --argjson i "$i" '.[$i].name' <<<"$cands")"; done
    ask LINK_N "  Which is $who's?" "$def"
    [[ "$REPLY_VAL" =~ ^[0-9]+$ ]] && (( REPLY_VAL <= n )) || die "expected a number from 0 to $n"
    (( REPLY_VAL )) && LINK_PICK=$(jq -c --argjson i "$((REPLY_VAL - 1))" '.[$i]' <<<"$cands")
    return 0
}

link_admin_note() { # link_admin_note APP CANDIDATE PORTAL-USER — what the next admin sync does to them
    local was; was=$(jq -r '.admin' <<<"$2")
    if [[ "$was" == true && "$LINK_ADMINS" != *" $3 "* ]]; then
        warn "    '$(jq -r '.name' <<<"$2")' is a $1 admin and $3 is not in the portal's admins — they lose admin (add $3 to admins first to keep it)"
    elif [[ "$was" != true && "$LINK_ADMINS" == *" $3 "* ]]; then
        info "    $3 is in the portal's admins — they become a $1 admin"
    fi
}

# ---- Jellyfin ----
link_jf_candidates() { # USERS-JSON -> its local accounts, the stack's admin left out
    jq -c --arg p "$JF_LDAP_PROVIDER" --arg s "$(env_get JELLYFIN_ADMIN_USER)" '[.[]
        | select(.Policy.AuthenticationProviderId != $p and (.Name | ascii_downcase) != ($s | ascii_downcase))
        | {name: .Name, id: .Id, admin: .Policy.IsAdministrator}]' <<<"$1"
}
link_jf_conflict() { # USERS-JSON CANDIDATE PORTAL-USER -> the name of another account already called that (Jellyfin names are case-insensitive)
    jq -r --arg id "$(jq -r '.id' <<<"$2")" --arg w "${3,,}" '[.[] | select(.Id != $id and (.Name | ascii_downcase) == $w) | .Name] | first // empty' <<<"$1"
}
link_jf_do() { # TOKEN CANDIDATE PORTAL-USER
    local tok="$1" id who="$3" u
    id=$(jq -r '.id' <<<"$2")
    u=$(jf_api GET "/Users/$id" "$tok") || { fail "jellyfin: the account is unreadable [HTTP $(jf_code)]"; return 1; }
    if [[ "$(jq -r '.Name' <<<"$u")" != "$who" ]]; then
        jf_api POST "/Users?userId=$id" "$tok" "$(jq -c --arg n "$who" '.Name = $n' <<<"$u")" >/dev/null \
            || { fail "jellyfin refused the rename to '$who' [HTTP $(jf_code)]"; return 1; }
    fi
    # the plugin adopts an existing account by name only when its login method is the plugin's
    jf_api POST "/Users/$id/Policy" "$tok" "$(jq -c --arg p "$JF_LDAP_PROVIDER" '.Policy | .AuthenticationProviderId = $p | .PasswordResetProviderId = $p' <<<"$u")" >/dev/null \
        || { fail "jellyfin refused the login-method change [HTTP $(jf_code)]"; return 1; }
    u=$(jf_api GET "/Users/$id" "$tok") \
        && jq -e --arg n "$who" --arg p "$JF_LDAP_PROVIDER" '.Name == $n and .Policy.AuthenticationProviderId == $p' <<<"$u" >/dev/null \
        || { fail "jellyfin answered, but the account is not '$who' on the portal's login"; return 1; }
    ok "jellyfin: '$who' signs in with the portal password from now on (same account: history kept)"
}

# ---- Kavita ----
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

# ---- Audiobookshelf ----
link_abs_candidates() { # USERS-JSON -> its unlinked accounts, root left out
    jq -c '[.users[] | select(.type != "root" and .hasOpenIDLink != true) | {name: .username, id: .id, admin: (.type == "admin")}]' <<<"$1"
}
link_abs_conflict() { # USERS-JSON CANDIDATE PORTAL-USER PORTAL-NAMES-JSON -> why the window is unsafe ("" = none)
    # while username matching is on, an unlinked account whose name any portal
    # account has would be claimed by it (Audiobookshelf compares in lower case)
    jq -r --arg id "$(jq -r '.id' <<<"$2")" --arg w "${3,,}" --argjson p "$4" '
        ($p | map(ascii_downcase)) as $pl | [.users[] | select(.id != $id) |
        if (.username | ascii_downcase) == $w then "Audiobookshelf already has an account named \(.username)"
        elif .hasOpenIDLink != true and ((.username | ascii_downcase) as $u | $pl | index($u)) != null
            then "Audiobookshelf account \(.username) is unlinked and a portal account has that name — it would be claimed while the window is open"
        else empty end] | first // empty' <<<"$1"
}
link_abs_match() { # TOKEN "username"|null — set username matching, and read it back
    local tok="$1" v="$2" cur
    abs_api PATCH /api/auth-settings "$tok" "$(jq -cn --argjson v "$v" '{authOpenIDMatchExistingBy: $v}')" >/dev/null || return 1
    cur=$(abs_api GET /api/auth-settings "$tok") && jq -e --argjson v "$v" '.authOpenIDMatchExistingBy == $v' <<<"$cur" >/dev/null
}
link_abs_close() { # TOKEN — the window shuts, whatever happened
    link_abs_match "$1" null && info "audiobookshelf: username matching is off again" \
        || fail "audiobookshelf: username matching could NOT be turned off — do it now: ./mediastack.sh wire audiobookshelf"
}
link_abs_do() { # TOKEN CANDIDATE PORTAL-USER
    local tok="$1" id who="$3" out
    id=$(jq -r '.id' <<<"$2")
    if [[ "$(jq -r '.name' <<<"$2")" != "$who" ]]; then
        out=$(abs_api PATCH "/api/users/$id" "$tok" "$(jq -cn --arg n "$who" '{username:$n}')") \
            || { fail "audiobookshelf refused the rename to '$who': $(oneline "$out")"; return 1; }
    fi
    out=$(abs_api PATCH "/api/users/$id" "$tok" "$(jq -cn --arg p "$(link_secret)" '{password:$p}')") \
        || { fail "audiobookshelf refused to replace the account's own password: $(oneline "$out")"; return 1; }
    # the window lives in a subshell whose EXIT trap closes it — on a link, a
    # timeout, Ctrl-C or any exit — and leaves the caller's traps alone
    (
        trap 'link_abs_close "$tok"' EXIT
        trap 'exit 130' INT TERM
        link_abs_match "$tok" '"username"' || { fail "audiobookshelf did not accept username matching"; exit 1; }
        info "audiobookshelf: ask $who to sign in to Audiobookshelf now (web or app, with the portal button) — waiting up to $((LINK_ABS_WAIT / 60)) minutes (Ctrl-C closes the window)"
        waited=0
        while :; do
            out=$(abs_api GET /api/users "$tok") || out='{"users":[]}'
            jq -e --arg i "$id" '.users[] | select(.id == $i) | .hasOpenIDLink == true' <<<"$out" >/dev/null && exit 0
            if (( waited >= LINK_ABS_WAIT )); then
                fail "audiobookshelf: $who did not sign in within $((LINK_ABS_WAIT / 60)) minutes — the account is renamed and ready; run link-account again when they can sign in"
                exit 1
            fi
            sleep 5; waited=$((waited + 5))
        done
    ) || return 1
    ok "audiobookshelf: '$who' is linked (same account: listening progress kept)"
}

# ---- the verb ----
cmd_link_account() {
    load_env; render
    local who="${1:-}" enc out pu email portal names jtok ktok atok jf kv ab
    [[ -n "$who" ]] || die "usage: link-account <portal-user>"
    svc_enabled authentik || die "link-account ties local accounts to portal accounts — the portal (authentik) is not enabled"
    [[ -t 0 ]] || die "link-account is interactive — run it at a terminal."
    [[ "$(c_health "$(svc_cname authentik)")" == healthy ]] || die "authentik is not healthy yet — ./mediastack.sh status authentik"
    enc=$(jq -rn --arg u "$who" '$u|@uri')
    out=$(ak_api GET "/core/users/?username=$enc") || die "authentik refused the user lookup: $(oneline "$out")"
    pu=$(jq -c '.results[0] // empty' <<<"$out")
    [[ -n "$pu" && "$(jq -r '.type' <<<"$pu")" == internal ]] || die "no portal account named '$who' — they join first (./mediastack.sh invite), then link"
    email=$(jq -r '.email // ""' <<<"$pu")
    portal=$(ak_api GET "/core/users/?type=internal&page_size=500") || die "authentik refused the user list: $(oneline "$portal")"
    names=$(jq -c '[.results[].username]' <<<"$portal")
    out=$(ak_api GET "/core/users/?groups_by_name=admins&page_size=500") || die "authentik refused the admins lookup"
    LINK_ADMINS=" $(jq -r '[.results[].username] | join(" ")' <<<"$out") "

    hr "link-account: which accounts are $who's"
    local jusers kusers ausers
    if svc_enabled jellyfin && [[ -n "$(env_get JELLYFIN_API_KEY)" ]]; then
        jtok=$(env_get JELLYFIN_API_KEY)
        jusers=$(jf_api GET /Users "$jtok") || die "jellyfin: users unreadable [HTTP $(jf_code)]"
        link_pick jellyfin "$(link_jf_candidates "$jusers")" "$who"; jf=$LINK_PICK
        if [[ -n "$jf" ]]; then out=$(link_jf_conflict "$jusers" "$jf" "$who")
            [[ -z "$out" ]] || die "jellyfin already has an account named '$out' (made when $who signed in through the portal?). If it holds nothing, delete it in Jellyfin's dashboard, then run this again."; fi
    fi
    if svc_enabled kavita && [[ -n "$(env_get KAVITA_ADMIN_PASSWORD)" ]]; then
        out=$(kav_api POST /api/account/login "" "$(jq -cn --arg u "$(env_get KAVITA_ADMIN_USER)" --arg p "$(env_get KAVITA_ADMIN_PASSWORD)" '{username:$u, password:$p}')") \
            || die "kavita rejected the stored admin login: $(oneline "$out")"
        ktok=$(jq -r '.token // empty' <<<"$out")
        kusers=$(kav_api GET "/api/users?includePending=true" "$ktok") || die "kavita: users unreadable"
        link_pick kavita "$(link_kav_candidates "$kusers")" "$who"; kv=$LINK_PICK
        if [[ -n "$kv" ]]; then
            [[ -n "$email" ]] || die "$who's portal account has no email — Kavita links a sign-in by email"
            [[ "$(jq --arg e "${email,,}" '[.results[] | select(((.email // "") | ascii_downcase) == $e)] | length' <<<"$portal")" == 1 ]] \
                || die "more than one portal account has the email $email — Kavita would link whichever signs in first. Give each their own in authentik (Directory → Users)."
            out=$(link_kav_conflict "$kusers" "$kv" "$who" "$email"); [[ -z "$out" ]] || die "$out — resolve it in Kavita first."
        fi
    fi
    if svc_enabled audiobookshelf && [[ -n "$(env_get ABS_ADMIN_PASSWORD)" ]]; then
        out=$(abs_api POST /login "" "$(jq -cn --arg u "$(env_get ABS_ADMIN_USER)" --arg p "$(env_get ABS_ADMIN_PASSWORD)" '{username:$u, password:$p}')") \
            || die "audiobookshelf rejected the root login from .env: $(oneline "$out")"
        atok=$(jq -r '.user.accessToken // .user.token // empty' <<<"$out")
        ausers=$(abs_api GET /api/users "$atok") || die "audiobookshelf: users unreadable"
        link_pick audiobookshelf "$(link_abs_candidates "$ausers")" "$who"; ab=$LINK_PICK
        if [[ -n "$ab" ]]; then out=$(link_abs_conflict "$ausers" "$ab" "$who" "$names"); [[ -z "$out" ]] || die "$out."; fi
    fi
    [[ -n "$jf$kv$ab" ]] || { info "nothing chosen — nothing changes"; return 0; }

    hr "The plan"
    [[ -n "$jf" ]] && { echo "  jellyfin: '$(jq -r .name <<<"$jf")' → $who — renamed, signs in with the portal password; history kept"; link_admin_note jellyfin "$jf" "$who"; }
    [[ -n "$kv" ]] && { echo "  kavita: '$(jq -r .name <<<"$kv")' → $who — renamed, email set to $email, its own password replaced; linked at $who's next portal sign-in"; link_admin_note kavita "$kv" "$who"; }
    [[ -n "$ab" ]] && { echo "  audiobookshelf: '$(jq -r .name <<<"$ab")' → $who — renamed, its own password replaced; linked when $who signs in during a $((LINK_ABS_WAIT / 60))-minute window"; link_admin_note audiobookshelf "$ab" "$who"; }
    echo "  Their old passwords stop working in these apps; the portal password is the one."
    confirm "Go ahead?" || { info "nothing changed"; return 0; }

    local fails=0 WIRE_FAILS=0
    [[ -n "$jf" ]] && { link_jf_do "$jtok" "$jf" "$who" || fails=$((fails + 1)); }
    [[ -n "$kv" ]] && { link_kav_do "$ktok" "$kv" "$who" "$email" || fails=$((fails + 1)); }
    [[ -n "$ab" ]] && { link_abs_do "$atok" "$ab" "$who" || fails=$((fails + 1)); }
    # admin rights in step with the portal now, as the plan said
    [[ -n "$jf" ]] && jf_admin_sync "$jtok"
    [[ -n "$kv" ]] && kav_admin_sync "$ktok"
    [[ -n "$ab" ]] && abs_admin_sync "$atok"
    (( fails + WIRE_FAILS )) && die "link-account finished with failures — see the FAIL lines above"
    ok "$who's accounts are linked to the portal"
}
