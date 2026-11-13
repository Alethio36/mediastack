#!/usr/bin/env bash
# services/navidrome/people.sh — with the portal, Navidrome's people follow it.
# The portal signs people in to Navidrome's web page, but its music apps use a
# password each person sets in Navidrome, which the portal never checks: a
# person whose portal account was deactivated or deleted kept their music apps.
# Navidrome has no "disabled" state, so this takes them away:
#   deactivated  their password is replaced by a random one (Navidrome's own
#                "not set yet" kind, so if they come back they set a new one
#                without the old) and admin rights go; their music and
#                history stay. Reactivated, they sign in through the portal
#                and set a new password for their apps.
#   deleted      the same, and the account is renamed removed-<name>-<date>:
#                someone joining later under that name starts fresh instead
#                of inheriting it.
# Only accounts the portal was seen behind are touched (recorded in
# NAVIDROME_PEOPLE); a Navidrome account of its own (made before the portal,
# or by hand) is reported and left alone, as is the stack's admin. Admin
# rights follow the portal's `admins` group. Runs in `wire navidrome` and
# every 15 minutes (people-sync, mediastack-people.timer).
# Sourced by the entrypoint; relies on navidrome.sh, the portal's
# signin_people and the entrypoint's helpers at call time.

NAVIDROME_PEOPLE="$LOCAL_DIR/navidrome-people"   # name<TAB>on|off|removed — accounts the portal was seen behind
ND_AUTOGEN=__NAVIDROME_AUTOGEN__                  # Navidrome's prefix for a password nobody chose: its owner may replace it without the old one

nd_people_get() { awk -F'\t' -v n="${1,,}" 'tolower($1) == n { print $2; exit }' "$NAVIDROME_PEOPLE" 2>/dev/null || true; }
nd_people_set() { # nd_people_set NAME STATE — record it (STATE "": forget it)
    local tmp; tmp=$(mktemp)
    awk -F'\t' -v n="${1,,}" 'tolower($1) != n' "$NAVIDROME_PEOPLE" 2>/dev/null > "$tmp" || true
    [[ -z "$2" ]] || printf '%s\t%s\n' "$1" "$2" >> "$tmp"
    mkdir -p "$LOCAL_DIR"; mv -f "$tmp" "$NAVIDROME_PEOPLE"; chmod 600 "$NAVIDROME_PEOPLE"; repo_owned "$LOCAL_DIR" "$NAVIDROME_PEOPLE"
}

nd_user_change() { # nd_user_change TOKEN USER-JSON JQ-FILTER [jq args...] — write the whole account with the filter applied, then read it back
    local tok=$1 u=$2 f=$3 id body out back; shift 3
    id=$(jq -r '.id' <<<"$u")
    body=$(jq -c "$@" "$f" <<<"$u")
    out=$(nd_api PUT "/api/user/$id" "$tok" "$body") || { echo "Navidrome refused it: $(oneline "$out")"; return 1; }
    back=$(nd_api GET "/api/user/$id" "$tok") || { echo "it answered, but the account is unreadable now: $(oneline "$back")"; return 1; }
    # what can be read back must hold; a password cannot be read, but its write moves updatedAt
    jq -e --argjson want "$body" --argjson was "$u" \
        '.userName == $want.userName and .isAdmin == $want.isAdmin and ($want.password == null or .updatedAt != $was.updatedAt)' <<<"$back" >/dev/null \
        || { echo "it answered, but the change did not hold"; return 1; }
}

navidrome_people_sync() { # navidrome_people_sync TOKEN — Navidrome's people follow the portal (see the top of this file)
    local tok=$1 portal nd stack u name pu st want has why new
    portal=$(signin_people) || { wfail "authentik: its people are unreadable — Navidrome's not checked: $(oneline "$portal")"; return 0; }
    nd=$(nd_api GET /api/user "$tok") || { wfail "navidrome: its users are unreadable: $(oneline "$nd")"; return 0; }
    stack=$(env_get NAVIDROME_ADMIN_USER)
    while IFS= read -r u; do
        [[ -n "$u" ]] || continue
        name=$(jq -r '.userName' <<<"$u")
        [[ "${name,,}" == "${stack,,}" ]] && continue   # the stack's own: never touched
        st=$(nd_people_get "$name")
        [[ "$st" == removed ]] && continue
        pu=$(jq -c --arg n "${name,,}" '[.results[]? | select((.username | ascii_downcase) == $n)][0] // empty' <<<"$portal")
        if [[ -n "$pu" && "$(jq -r '.is_active' <<<"$pu")" == true ]]; then
            if [[ "$st" != on ]]; then
                [[ "$st" == off ]] && ok "navidrome: '$name' is back on the portal — signs in again; their music apps need a new password (set in Navidrome)"
                (( WIRE_DRY )) || nd_people_set "$name" on
            fi
            want=$(jq '[.groups_obj[]?.name] | index("admins") != null' <<<"$pu"); has=$(jq '.isAdmin' <<<"$u")
            [[ "$want" == "$has" ]] && continue
            w_would "navidrome: '$name' $( [[ $want == true ]] && echo becomes || echo 'is no longer' ) admin (the portal's admins group)" || continue
            if why=$(nd_user_change "$tok" "$u" '.isAdmin = $w' --argjson w "$want"); then
                ok "navidrome: '$name' $( [[ $want == true ]] && echo 'is admin' || echo 'is no longer admin' )"
            else wfail "navidrome: '$name' admin rights — $why"; fi
        elif [[ -z "$st" ]]; then
            info "navidrome: '$name' is not tied to a portal account (made before the portal, or by hand) — left alone"
        elif [[ -n "$pu" ]]; then   # deactivated on the portal
            [[ "$st" == off ]] && continue
            w_would "navidrome: '$name' (portal account deactivated) loses their music apps — their music and history stay" || continue
            if why=$(nd_user_change "$tok" "$u" '.password = $p | .isAdmin = false' --arg p "$ND_AUTOGEN$(gen_secret 32)"); then
                nd_people_set "$name" off
                ok "navidrome: '$name' can no longer play music (portal account deactivated)"
                notify ops "Navidrome" "$name's music apps are stopped: their portal account was deactivated. Reactivated, they set a new password in Navidrome." info
            else wfail "navidrome: '$name' (portal account deactivated) still plays music — $why"; fi
        else   # deleted from the portal
            new="removed-$name-$(date +%Y%m%d)"
            w_would "navidrome: '$name' (portal account deleted) loses their music apps; the account becomes '$new' (history kept, the name free for someone new)" || continue
            if why=$(nd_user_change "$tok" "$u" '.password = $p | .isAdmin = false | .userName = $n' --arg p "$ND_AUTOGEN$(gen_secret 32)" --arg n "$new"); then
                nd_people_set "$name" ""; nd_people_set "$new" removed
                ok "navidrome: '$name' can no longer play music (portal account deleted) — kept as '$new'"
                notify ops "Navidrome" "$name's music apps are stopped: their portal account was deleted. Their Navidrome account is kept as $new." info
            else wfail "navidrome: '$name' (portal account deleted) still plays music — $why"; fi
        fi
    done < <(jq -c '.[]?' <<<"$nd")
    return 0
}

# ---- every 15 minutes: people-sync (mediastack-people.timer) ----
PEOPLE_TIMER=mediastack-people
people_timer_ensure() { # write, enable and start the timer; reloads systemd only when a file changed (wire navidrome, once the stack's admin signs in)
    local svc tim changed=0
    svc=$(mktemp); tim=$(mktemp)
    timer_service_render "Mediastack: Navidrome follows the portal" people-sync > "$svc"
    timer_timer_render "Mediastack: Navidrome follows the portal" "*:0/15" > "$tim"
    sudo cmp -s "$svc" "$SYSTEMD_DIR/$PEOPLE_TIMER.service" 2>/dev/null || { sudo install -m 644 "$svc" "$SYSTEMD_DIR/$PEOPLE_TIMER.service"; changed=1; }
    sudo cmp -s "$tim" "$SYSTEMD_DIR/$PEOPLE_TIMER.timer" 2>/dev/null || { sudo install -m 644 "$tim" "$SYSTEMD_DIR/$PEOPLE_TIMER.timer"; changed=1; }
    rm -f "$svc" "$tim"
    (( changed )) || return 0
    failure_unit_ensure
    sudo systemctl daemon-reload
    sudo systemctl enable --now "$PEOPLE_TIMER.timer" >/dev/null 2>&1 \
        || die "could not enable $PEOPLE_TIMER.timer — check: systemctl status $PEOPLE_TIMER.timer"
    info "Navidrome follows the portal every 15 minutes (a person removed there loses their music apps)"
}

cmd_people_sync() { # the timer's run; a failure goes to ops through the unit's failure hook
    load_env; render
    { signin_is authentik && svc_enabled navidrome; } || return 0   # nothing to follow
    [[ "$(c_state "$(svc_cname navidrome)")" == running ]] || { info "navidrome is not running — nothing checked"; return 0; }
    WIRE_FAILS=0; WIRE_DRY=0
    local tok
    tok=$(nd_login) || die "navidrome: the stack's admin does not sign in ($(oneline "$tok")) — ./mediastack.sh wire navidrome says why"
    navidrome_people_sync "$tok"
    (( ! WIRE_FAILS )) || die "people-sync: $WIRE_FAILS change(s) failed (above)"
}

support_navidrome() { # support: who the portal is followed for, and whether the stack's admin signs in
    local tok
    sp_running navidrome || return 0
    if tok=$(nd_login); then echo "the stack's admin signs in"; else echo "the stack's admin does NOT sign in: $(oneline "$tok")"; fi
    if [[ -s "$NAVIDROME_PEOPLE" ]]; then awk -F'\t' '{ print "person " $1 ": " $2 }' "$NAVIDROME_PEOPLE"
    else echo "people followed: none yet"; fi
    return 0
}
