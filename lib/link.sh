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
# The stack's own accounts are never offered. Each app's part (candidates,
# conflicts, the link itself) is link_<app>_* in its service's folder; this
# file keeps the verb, its order and its questions.

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
