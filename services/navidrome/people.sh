#!/usr/bin/env bash
# services/navidrome/people.sh — with the portal, Navidrome's people follow it
# (lib/people.sh runs it: in wire navidrome, every 15 minutes, and at once
# after an `access` command on Navidrome). The portal signs people in to
# Navidrome's web page, but its music apps use a password each person sets in
# Navidrome, which the portal never checks: a person the portal no longer
# lets open Navidrome kept their music apps (proven live, 16 Nov 2026).
# Navidrome has no "disabled" state, so this takes them away:
#   may not open it   their portal account deactivated, or on but no longer
#                     allowed Navidrome (its tier, a grant taken away —
#                     people_may): their password is replaced by a random one
#                     (Navidrome's own "not set yet" kind, so if they come back
#                     they set a new one without the old) and admin rights go;
#                     their music and history stay. Allowed again, they sign in
#                     through the portal and set a new password for their apps.
#   deleted           the same, and the account is renamed
#                     removed-<name>-<date>: someone joining later under that
#                     name starts fresh instead of inheriting it.
# Only accounts the portal was seen behind are touched (recorded in
# local/navidrome-people); a Navidrome account of its own (made before the
# portal, or by hand) is reported and left alone, as is the stack's admin.
# Admin rights follow the portal's admin group. Sourced by the entrypoint;
# relies on navidrome.sh, lib/people.sh, the portal's signin_people and the
# entrypoint's helpers at call time.

ND_AUTOGEN=__NAVIDROME_AUTOGEN__                  # Navidrome's prefix for a password nobody chose: its owner may replace it without the old one

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

nd_person_off() { # nd_person_off TOKEN USER-JSON NAME WHY NOTE — their music apps stop: a password nobody chose, no admin; recorded off
    local out
    w_would "navidrome: '$3' ($4) loses their music apps — their music and history stay" || return 0
    if out=$(nd_user_change "$1" "$2" '.password = $p | .isAdmin = false' --arg p "$ND_AUTOGEN$(gen_secret 32)"); then
        people_set navidrome "$3" off
        ok "navidrome: '$3' can no longer play music ($4)"
        notify ops "Navidrome" "$3's music apps are stopped: $5" info
    else wfail "navidrome: '$3' ($4) still plays music — $out"; fi
}

navidrome_people_sync() { # navidrome_people_sync TOKEN — Navidrome's people follow the portal (see the top of this file)
    local tok=$1 portal nd stack u name pu st want has why new rule=1
    portal=$(signin_people) || { wfail "authentik: its people are unreadable — Navidrome's not checked: $(oneline "$portal")"; return 0; }
    # the rule reads the admin and frontend groups: with one missing (an
    # upgrade whose rename is not applied yet) nobody would be in it —
    # everyone cut off or demoted, unasked. So access and rights move only
    # while both exist; a deactivated or deleted account still loses its apps.
    if ! why=$(people_rule_ready); then rule=0; wfail "$why — Navidrome's access and admin rights left as they are"; fi
    nd=$(nd_api GET /api/user "$tok") || { wfail "navidrome: its users are unreadable: $(oneline "$nd")"; return 0; }
    stack=$(env_get NAVIDROME_ADMIN_USER)
    while IFS= read -r u; do
        [[ -n "$u" ]] || continue
        name=$(jq -r '.userName' <<<"$u")
        [[ "${name,,}" == "${stack,,}" ]] && continue   # the stack's own: never touched
        st=$(people_get navidrome "$name")
        [[ "$st" == removed ]] && continue
        pu=$(jq -c --arg n "${name,,}" '[.results[]? | select((.username | ascii_downcase) == $n)][0] // empty' <<<"$portal")
        if [[ -n "$pu" && "$(jq -r '.is_active' <<<"$pu")" == true ]]; then
            if (( ! rule )); then   # tied to the portal, nothing judged
                [[ -n "$st" ]] || (( WIRE_DRY )) || people_set navidrome "$name" on
                continue
            fi
            if ! people_may "$pu" navidrome; then
                [[ "$st" == off ]] && continue
                nd_person_off "$tok" "$u" "$name" "may no longer open Navidrome" \
                    "they may no longer open Navidrome (its tier, or a grant taken away). Given it again, they set a new password in Navidrome."
                continue
            fi
            if [[ "$st" != on ]]; then
                [[ "$st" == off ]] && ok "navidrome: '$name' may open Navidrome again — signs in through the portal; their music apps need a new password (set in Navidrome)"
                (( WIRE_DRY )) || people_set navidrome "$name" on
            fi
            want=$(jq --arg g "$PORTAL_ADMIN" '[.groups_obj[]?.name] | index($g) != null' <<<"$pu"); has=$(jq '.isAdmin' <<<"$u")
            [[ "$want" == "$has" ]] && continue
            w_would "navidrome: '$name' $( [[ $want == true ]] && echo becomes || echo 'is no longer' ) admin (the portal's $PORTAL_ADMIN group)" || continue
            if why=$(nd_user_change "$tok" "$u" '.isAdmin = $w' --argjson w "$want"); then
                ok "navidrome: '$name' $( [[ $want == true ]] && echo 'is admin' || echo 'is no longer admin' )"
            else wfail "navidrome: '$name' admin rights — $why"; fi
        elif [[ -z "$st" ]]; then
            info "navidrome: '$name' is not tied to a portal account (made before the portal, or by hand) — left alone"
        elif [[ -n "$pu" ]]; then   # deactivated on the portal
            [[ "$st" == off ]] && continue
            nd_person_off "$tok" "$u" "$name" "portal account deactivated" \
                "their portal account was deactivated. Reactivated, they set a new password in Navidrome."
        else   # deleted from the portal
            new="removed-$name-$(date +%Y%m%d)"
            w_would "navidrome: '$name' (portal account deleted) loses their music apps; the account becomes '$new' (history kept, the name free for someone new)" || continue
            if why=$(nd_user_change "$tok" "$u" '.password = $p | .isAdmin = false | .userName = $n' --arg p "$ND_AUTOGEN$(gen_secret 32)" --arg n "$new"); then
                people_set navidrome "$name" ""; people_set navidrome "$new" removed
                ok "navidrome: '$name' can no longer play music (portal account deleted) — kept as '$new'"
                notify ops "Navidrome" "$name's music apps are stopped: their portal account was deleted. Their Navidrome account is kept as $new." info
            else wfail "navidrome: '$name' (portal account deleted) still plays music — $why"; fi
        fi
    done < <(jq -c '.[]?' <<<"$nd")
    return 0
}

navidrome_people_follow() { # lib/people.sh: the stack's admin signs in, then the people follow
    local tok
    tok=$(nd_login) || { wfail "navidrome: the stack's admin does not sign in ($(oneline "$tok")) — ./mediastack.sh wire navidrome says why"; return 0; }
    navidrome_people_sync "$tok"
}

support_navidrome() { # support: who the portal is followed for, and whether the stack's admin signs in
    local tok
    sp_running navidrome || return 0
    if tok=$(nd_login); then echo "the stack's admin signs in"; else echo "the stack's admin does NOT sign in: $(oneline "$tok")"; fi
    if [[ -s "$(people_file navidrome)" ]]; then awk -F'\t' '{ print "person " $1 ": " $2 }' "$(people_file navidrome)"
    else echo "people followed: none yet"; fi
    return 0
}
