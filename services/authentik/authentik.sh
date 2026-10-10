#!/usr/bin/env bash
# services/authentik/authentik.sh — the `wire authentik` role: the gate,
# identity rules, the LDAP outpost's token and the dashboard cards. The
# shard's upkeep (blueprints, doctor, accounts) is lib/authentik.sh for now.
# Sourced by the entrypoint; relies on lib/wire.sh, lib/addr.sh and the
# entrypoint's helpers at call time.

wire_authentik() {
    hr "wire: authentik"
    svc_enabled authentik || { info "authentik not enabled — skipped"; return 0; }
    wire_gate authentik
    http_ready authentik "$(authentik_url)/-/health/ready/" '^2' || return 1
    # its base URL: the address in links it generates (invitations included).
    # Set when unset, or when it is still the one mediastack last wrote (a
    # renamed host); a URL you set in authentik's UI is left alone.
    local want cur mine
    want=$(authentik_portal); mine=$(state_get AUTHENTIK_BASE_URL)
    cur=$(ak_api GET /admin/settings/ | jq -r '.base_url // ""') \
        || { wfail "authentik: its settings are unreadable — is AUTHENTIK_API_TOKEN the one it started with?"; return 1; }
    if [[ "$cur" == "$want" ]]; then
        ok "authentik: base URL $want"
    elif [[ -n "$cur" && "$cur" != "$mine" ]]; then
        ok "authentik: base URL $cur was set in its UI — untouched"
    elif w_would "authentik: set its base URL to $want (the address in the links it generates)"; then
        if ak_api PATCH /admin/settings/ "$(jq -cn --arg u "$want" '{base_url:$u}')" >/dev/null; then
            state_set AUTHENTIK_BASE_URL "$want"; ok "authentik: base URL set"
        else wfail "authentik rejected the base URL $want"; fi
    fi
    local st; st=$(authentik_blueprint_status)
    # a first start: authentik discovers the blueprint on its own schedule, and
    # the gate, the cards and the LDAP token all need it — wait, don't skip
    if [[ -z "$st" ]] && ! (( WIRE_DRY )); then
        info "authentik: waiting for it to discover mediastack's portal setup (a first start; up to $((AUTHENTIK_DISCOVER_WAIT / 60)) minutes)"
        st=$(authentik_blueprint_discovered)
    fi
    local applied=0
    # why it is not current: never applied (a first start), a failed apply, or an older file
    local why="an earlier version is in place"
    [[ "$st" == error ]] && why="its last apply failed"
    [[ "$st" == outdated && -z "$(authentik_blueprint_instance 2>/dev/null | jq -r '.last_applied_hash // ""' 2>/dev/null)" ]] \
        && why="authentik has not applied it yet"
    if [[ "$st" == outdated || "$st" == error ]] && w_would "authentik: apply mediastack's current portal setup now ($why)"; then
        st=$(authentik_blueprint_apply); applied=1
    fi
    # the LDAP outpost caches bind results: a changed setup starts it afresh,
    # so an answer from before the change cannot outlive it (found live)
    if (( applied )) && [[ "$st" == successful && "$(c_state "$(svc_cname authentik-ldap)")" == running ]]; then
        sudo docker restart "$(svc_cname authentik-ldap)" >/dev/null && ok "authentik: LDAP outpost restarted on the new setup (its bind cache cleared)"
    fi
    case "$st" in
        successful) ok "authentik: mediastack's portal setup applied (media-users, admins, sign-up by invitation)" ;;
        "") if (( WIRE_DRY )); then info "authentik: mediastack's portal setup not discovered yet — the real run waits for it"
            else wfail "authentik: mediastack's portal setup was not discovered within $((AUTHENTIK_DISCOVER_WAIT / 60)) minutes — ./mediastack.sh logs authentik --no-follow | grep -i blueprint"; fi
            return 0 ;;
        outdated) wfail "authentik: an earlier version of mediastack's portal setup is still in place — ./mediastack.sh logs authentik --no-follow | grep -i blueprint"; return 0 ;;
        *) wfail "authentik rejected mediastack's portal setup ($st). Its validator says:"
           authentik_blueprint_why | sed 's/^/       /'
           return 0 ;;
    esac
    wire_authentik_identity
    wire_authentik_gate
}

wire_authentik_identity() { # people cannot change their own email or username: apps find their account by them
    local cur
    cur=$(ak_api GET /admin/settings/) || { wfail "authentik: its settings are unreadable"; return 1; }
    if jq -e '.default_user_change_email == false and .default_user_change_username == false' <<<"$cur" >/dev/null; then
        ok "authentik: people cannot change their own email or username (an admin can: ./mediastack.sh set-email)"
        return 0
    fi
    w_would "authentik: stop people changing their own email and username (the apps find their account by them)" || return 0
    ak_api PATCH /admin/settings/ '{"default_user_change_email":false,"default_user_change_username":false}' >/dev/null \
        && ok "authentik: people can no longer change their own email or username" \
        || wfail "authentik rejected the change to its self-service settings"
}

wire_authentik_gate() { # the gate on the built-in outpost, the first admin in `admins`, the dashboard cards
    # 1. the gate's provider on the built-in outpost — added to what is there, never replacing it
    local out prov
    out=$(ak_api GET "/providers/proxy/?name__iexact=mediastack-gate") || { wfail "authentik: gate provider unreadable"; return 0; }
    prov=$(jq -r '.results[0].pk // empty' <<<"$out")
    [[ -n "$prov" ]] || { wfail "authentik: the gate provider (mediastack-gate) is missing — the blueprint creates it: ./mediastack.sh logs authentik --no-follow | grep -i blueprint"; return 0; }
    if authentik_gate_attached; then ok "authentik: the gate is on its built-in outpost"
    else authentik_outpost_add "$prov" "the gate"; fi
    # 2. the first admin joins `admins` once — after that, membership is yours to manage
    if [[ -z "$(state_get AUTHENTIK_ADMINS_SEEDED)" ]] && w_would "authentik: put akadmin in 'admins' (the gate lets admins through)"; then
        local g u
        g=$(ak_api GET "/core/groups/?search=admins") && g=$(jq -r '[.results[] | select(.name == "admins") | .pk][0] // empty' <<<"$g")
        u=$(ak_api GET "/core/users/?username=akadmin") && u=$(jq -r '.results[0].pk // empty' <<<"$u")
        if [[ -n "$g" && -n "$u" ]] && ak_api POST "/core/groups/$g/add_user/" "$(jq -cn --argjson u "$u" '{pk:$u}')" >/dev/null; then
            state_set AUTHENTIK_ADMINS_SEEDED 1; ok "authentik: akadmin is in 'admins'"
        else wfail "authentik: could not add akadmin to 'admins'"; fi
    fi
    # 3. dashboard cards: admin tools (admins), household apps (media-users) — slugs mediastack-*: ours
    wire_authentik_cards
    # 4. the LDAP outpost's token: the outpost can only start with it
    wire_authentik_ldap_token
}

wire_authentik_ldap_token() { # fetch the mediastack-ldap outpost's token into .env; restart the outpost on a change
    local out pk key
    out=$(ak_api GET "/outposts/instances/?name__iexact=mediastack-ldap") || { wfail "authentik: outposts unreadable"; return 0; }
    pk=$(jq -r '.results[0].pk // empty' <<<"$out")
    [[ -n "$pk" ]] || { wfail "authentik: the LDAP outpost (mediastack-ldap) is missing — the blueprint creates it"; return 0; }
    out=$(ak_api GET "/core/tokens/ak-outpost-$pk-api/view_key/") || { wfail "authentik: the LDAP outpost's token is unreadable"; return 0; }
    key=$(jq -r '.key // empty' <<<"$out")
    [[ -n "$key" ]] || { wfail "authentik answered without the LDAP outpost's token"; return 0; }
    if [[ "$(env_get AUTHENTIK_LDAP_TOKEN)" == "$key" ]]; then ok "authentik: the LDAP outpost has its token"; return 0; fi
    w_would "authentik: give the LDAP outpost its token, then start it" || return 0
    env_set AUTHENTIK_LDAP_TOKEN "$key"
    # shellcheck disable=SC2034  # the render cache lives in the entrypoint (read by DC's callers)
    RENDERED_JSON=""
    DC up -d --no-deps authentik-ldap >/dev/null && ok "authentik: LDAP outpost started with its token" \
        || wfail "the LDAP outpost did not start: ./mediastack.sh logs authentik"
}

ak_group_pk() { # ak_group_pk NAME -> its pk (exact name, not a lookalike)
    local g; g=$(ak_api GET "/core/groups/?search=$1") || return 1
    jq -r --arg n "$1" '[.results[]? | select(.name == $n) | .pk][0] // empty' <<<"$g"
}

ak_flow_pk() { # ak_flow_pk SLUG -> its pk
    local f; f=$(ak_api GET "/flows/instances/?slug=$1") || return 1
    jq -r '.results[0].pk // empty' <<<"$f"
}

authentik_outpost_add() { # authentik_outpost_add PROVIDER-PK LABEL — beside what is on the built-in outpost, never replacing it
    local out outpost provs
    out=$(ak_api GET "/outposts/instances/?managed__iexact=goauthentik.io/outposts/embedded") || { wfail "authentik: built-in outpost unreadable"; return 1; }
    outpost=$(jq -r '.results[0].pk // empty' <<<"$out"); provs=$(jq -c '.results[0].providers // []' <<<"$out")
    [[ -n "$outpost" ]] || { wfail "authentik: its built-in outpost is missing"; return 1; }
    jq -e --argjson p "$1" 'index($p) != null' <<<"$provs" >/dev/null && return 0
    w_would "authentik: put $2 on its built-in outpost" || return 0
    ak_api PATCH "/outposts/instances/$outpost/" "$(jq -cn --argjson ps "$provs" --argjson p "$1" '{providers: ($ps + [$p])}')" >/dev/null \
        && ok "authentik: $2 attached" || { wfail "authentik refused to attach $2 to its outpost"; return 1; }
}

authentik_house_provider() { # authentik_house_provider SVC -> HOUSE_PK: its household gate (forward auth for its one address)
    # the pk comes back in HOUSE_PK (not stdout: a $(…) subshell would lose wire's failure count)
    HOUSE_PK=""
    local s="$1" name="mediastack-house-$1" url out pk az inv
    url=$(svc_url "$s")
    out=$(ak_api GET "/providers/proxy/?name__iexact=$name") || { wfail "authentik: providers unreadable"; return 1; }
    pk=$(jq -r '.results[0].pk // empty' <<<"$out")
    if [[ -z "$pk" ]]; then
        w_would "authentik: a household gate for $s ($url — media-users get through)" || return 1
        az=$(ak_flow_pk default-provider-authorization-implicit-consent); inv=$(ak_flow_pk default-provider-invalidation-flow)
        [[ -n "$az" && -n "$inv" ]] || { wfail "authentik: its default provider flows are missing"; return 1; }
        out=$(ak_api POST /providers/proxy/ "$(jq -cn --arg n "$name" --arg u "$url" --arg a "$az" --arg i "$inv" \
            '{name:$n, mode:"forward_single", external_host:$u, authorization_flow:$a, invalidation_flow:$i}')") \
            || { wfail "authentik refused $s's household gate: $(head -c160 <<<"$out")"; return 1; }
        pk=$(jq -r '.pk' <<<"$out")
    elif [[ "$(jq -r '.results[0].external_host' <<<"$out")" != "$url" ]]; then
        w_would "authentik: move $s's household gate to $url (its address changed)" || return 1
        ak_api PATCH "/providers/proxy/$pk/" "$(jq -cn --arg u "$url" '{external_host:$u}')" >/dev/null \
            || { wfail "authentik refused to update $s's household gate"; return 1; }
    fi
    authentik_outpost_add "$pk" "$s's household gate" || return 1
    HOUSE_PK=$pk
}

ak_card() { # ak_card ALL SLUG NAME URL DESC SECTION PROVIDER GROUP-PK... — a dashboard card only those groups see
    local all="$1" slug="$2" name="$3" url="$4" desc="$5" section="$6" prov="$7" have body app bind g
    shift 7
    body=$(jq -cn --arg n "$name" --arg sl "$slug" --arg u "$url" --arg d "$desc" --arg sec "$section" --arg p "$prov" \
        '{name:$n, slug:$sl, meta_launch_url:$u, meta_description:$d, meta_publisher:"mediastack", group:$sec,
          open_in_new_tab:true, policy_engine_mode:"any"} + (if $p != "" then {provider: ($p|tonumber)} else {} end)')
    have=$(jq -c --arg sl "$slug" '[.results[] | select(.slug == $sl)][0] // empty' <<<"$all")
    if [[ -z "$have" ]]; then
        w_would "authentik: add the $section card for $name" || return 0
        app=$(ak_api POST /core/applications/ "$body") || { wfail "authentik refused the card for $name: $(head -c160 <<<"$app")"; return 0; }
    elif [[ "$(jq -r '.meta_launch_url' <<<"$have")" != "$url" || "$(jq -r '.provider // "" | tostring' <<<"$have" | sed 's/^null$//')" != "$prov" ]]; then
        w_would "authentik: update $name's card" || return 0
        app=$(ak_api PATCH "/core/applications/$slug/" "$body") || { wfail "authentik refused to update $name's card"; return 0; }
    else
        app=$have
    fi
    bind=$(ak_api GET "/policies/bindings/?target=$(jq -r '.pk' <<<"$app")") || { wfail "authentik: bindings unreadable"; return 0; }
    for g in "$@"; do
        jq -e --arg g "$g" '.results[] | select(.group == $g)' <<<"$bind" >/dev/null && continue
        ak_api POST /policies/bindings/ "$(jq -cn --arg t "$(jq -r '.pk' <<<"$app")" --arg g "$g" '{target:$t, group:$g, order:0}')" >/dev/null \
            || { wfail "authentik: could not limit $name's card"; return 0; }
    done
    ok "authentik: $name card ($section)"
}

ak_card_prune() { # ak_card_prune ALL PREFIX WANTED... — cards mediastack made for services no longer wanted leave
    local all="$1" prefix="$2" slug; shift 2
    for slug in $(jq -r --arg p "$prefix" '.results[].slug | select(startswith($p))' <<<"$all"); do
        [[ " $* " == *" ${slug#"$prefix"} "* ]] && continue
        w_would "authentik: remove the card for ${slug#"$prefix"}" || continue
        ak_api DELETE "/core/applications/$slug/" >/dev/null && ok "authentik: ${slug#"$prefix"} card removed" \
            || wfail "authentik refused to remove ${slug#"$prefix"}'s card"
    done
}

wire_authentik_cards() { # admin tools for admins; household apps for media-users (and admins); ours only, by slug prefix
    local all adm mu s prov
    all=$(ak_api GET "/core/applications/?superuser_full_list=true&page_size=500") || { wfail "authentik: applications unreadable"; return 0; }
    adm=$(ak_group_pk admins); mu=$(ak_group_pk media-users)
    [[ -n "$adm" && -n "$mu" ]] || { wfail "authentik: groups 'admins'/'media-users' missing (the blueprint creates them)"; return 0; }
    for s in $(authentik_gated); do
        ak_card "$all" "mediastack-tool-$s" "$s" "$(svc_url "$s")" "$(svc_label "$s" mediastack.desc)" "Admin tools" "" "$adm"
    done
    for s in $(authentik_household); do
        prov=""
        # a household app behind the household gate: its card carries the gate's rule
        if [[ -n "$(svc_label "$s" mediastack.auth.group)" ]]; then authentik_house_provider "$s" || continue; prov=$HOUSE_PK
        else
            # an app that logs in through OIDC: its card is the provider's application
            local op; op=$(ak_api GET "/providers/oauth2/?client_id=mediastack-$s") || { wfail "authentik: providers unreadable"; continue; }
            prov=$(jq -r '.results[0].pk // empty' <<<"$op")
        fi
        ak_card "$all" "mediastack-app-$s" "$s" "$(svc_url "$s")" "$(svc_label "$s" mediastack.desc)" "Media" "$prov" "$mu" "$adm"
    done
    # shellcheck disable=SC2046  # service names, one word each
    ak_card_prune "$all" mediastack-tool- $(authentik_gated)
    # shellcheck disable=SC2046
    ak_card_prune "$all" mediastack-app- $(authentik_household)
    return 0
}
