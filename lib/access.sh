#!/usr/bin/env bash
# lib/access.sh — who can get in: the logins the stack created or stores
# (`credentials`), rotating one everywhere it lives (`set-credentials`), and
# household invitations (`invite`: authentik_invite or wizarr_invite, each in
# its provider's folder — no provider's API is spoken here). The account model — which provider signs
# people in — is asked here once (signin_model), never by a service's name. Each target's rotation is
# sc_rotate_<target> in its service's folder (services/<name>/*.sh); this file
# keeps the verbs, their order and their words. Sourced by the entrypoint;
# relies on lib/common.sh, the entrypoint's helpers and the services' own
# API helpers at call time.

signin_model() { # -> authentik | wizarr | none: who signs people in (the installer allows one; the portal wins if both)
    if svc_enabled authentik; then echo authentik
    elif svc_enabled wizarr; then echo wizarr
    else echo none; fi
}
signin_is() { [[ "$(signin_model)" == "$1" ]]; }   # signin_is MODEL

# ---- the stack's own logins, as their services declare them ----
# Every login is a service's `<stem>_logins` line (lib/logins.sh): its title,
# its keys, and options — `target=NAME` (its set-credentials target; else the
# stem) and `ask_user` (set-credentials asks its username too). Its rotation
# is sc_rotate_<target> in the service's folder, taking the new password —
# with ask_user, the username first. A service may add, found by name:
#   sc_explain_<target>       what a rotation moves, printed before the question
#   <service>_credentials     lines under its logins in `credentials`
# (docs/design-install.md, "The service contract"). The portal's admin
# (akadmin) is not one of these logins: its own target, kept out of `all`.
# No app is named here but in the companion apps' API keys
# (credentials_api_keys — filed, docs/roadmap.md step 11).

sc_lines() { # [enabled] -> target<TAB>LINE, one per login of the catalogue (with "enabled": of the enabled services), a shared one once
    local s stem l t
    local -A seen=()
    for s in $( if [[ "${1:-}" == enabled ]]; then svc_enabled_managed; else svc_managed; fi ); do
        stem=$(svc_label "$s" mediastack.logins); stem=${stem:-$s}
        [[ -z "${seen[$stem]:-}" ]] || continue; seen[$stem]=1
        while IFS= read -r l; do
            [[ -n "$l" ]] || continue
            t=$(login_opt "$l" target); t=${t:-${stem//-/_}}
            printf '%s\t%s\n' "$t" "$l"
        done < <(logins_of "$s")
    done
}

cmd_credentials() {
    load_env; render   # once, here: every $(svc_url) below would render again in its subshell
    hr "Credentials (stored in .env)"
    local s stem l f
    local -A seen=()
    for s in $(svc_enabled_managed); do
        stem=$(svc_label "$s" mediastack.logins); stem=${stem:-$s}
        if [[ -z "${seen[$stem]:-}" ]]; then
            seen[$stem]=1
            while IFS= read -r l; do [[ -n "$l" ]] && credentials_login "$l"; done < <(logins_of "$s")
        fi
        f="${s//-/_}_credentials"
        if declare -F "$f" >/dev/null; then "$f"; fi
    done
    credentials_api_keys
}

credentials_login() { # LINE — one login: its title, then its username and password (or what records them)
    local ukey pkey none='(not recorded yet — ./mediastack.sh up records it)'
    ukey=$(cut -f2 <<<"$1"); pkey=$(cut -f3 <<<"$1")
    echo "$(cut -f1 <<<"$1")"
    [[ "$ukey" == - ]] || printf '  %-10s %s\n' user "$(env_or_note "$ukey" "$none")"
    printf '  %-10s %s\n' password "$(env_or_note "$pkey" "$none")"
}

credentials_api_keys() { # the keys companion apps (nzb360, LunaSea, Home Assistant…) ask for, with the address to give them
    local s k rows=""
    for s in $(arr_instances) prowlarr bazarr seerr; do
        svc_enabled "$s" || continue
        case "$s" in
            bazarr) k=$(bazarr_key) ;;
            seerr)  k=$(env_get SEERR_API_KEY) ;;
            *)      k=$(arr_key "$s") ;;
        esac
        rows+=$(printf '%-14s %-44s %s' "$s" "$(svc_url "$s")" "${k:-(not created yet — start it once)}")$'\n'
    done
    [[ -n "$rows" ]] || return 0
    hr "API keys (companion apps)"
    printf '%s' "$rows"
    if signin_is authentik; then
        info "Give an app the https address and the key. Behind the portal the arrs', Prowlarr's and Bazarr's API pass the gate too: the app also sends a device password as a header (README: \"A phone app for the arrs\"). Seerr's API is not behind the gate."
    fi
}

sc_usage() { # every target the catalogue has, and what it changes
    local t l
    echo "usage: set-credentials <target|all>"
    while IFS=$'\t' read -r t l; do printf '  %-15s %s\n' "$t" "$(cut -f1 <<<"$l")"; done < <(sc_lines)
    printf '  %-15s %s\n' portal "the portal's admin (akadmin) — kept out of all: it guards the rest"
    printf '  %-15s %s\n' all "ONE password across every login above that is set up (usernames stay put)"
    echo "Someone else locked out of the portal: ./mediastack.sh reset-password <username>"
}

cmd_set_credentials() { # rotate a stored credential in the app(s) AND .env, atomically
    load_env; render
    local target="${1:-}" line=""
    if [[ -n "$target" && "$target" != portal && "$target" != all ]]; then
        line=$(sc_lines | awk -F'\t' -v t="$target" '$1 == t && !f { sub(/^[^\t]*\t/, ""); print; f = 1 }')
    fi
    [[ "$target" == portal || "$target" == all || -n "$line" ]] || die "$(sc_usage)"
    [[ -t 0 ]] || die "set-credentials is interactive — run it at a terminal."
    case "$target" in
        portal) sc_portal ;;
        all)    sc_all ;;
        *)      sc_one "$target" "$line" ;;
    esac
}

sc_one() { # TARGET LINE — explained, asked, then its own rotation
    local t=$1 l=$2 user pass
    if declare -F "sc_explain_$t" >/dev/null; then explain "Rotate $(cut -f1 <<<"$l")" "$("sc_explain_$t")"; fi
    if [[ "$(login_opt "$l" ask_user)" == yes ]]; then
        user=$(env_get "$(cut -f2 <<<"$l")"); ask SC_U "Username" "${user:-admin}"; user="$REPLY_VAL"
        login_pass_ask "New password" "$(cut -f3 <<<"$l")"; pass="$REPLY_VAL"
        "sc_rotate_$t" "$user" "$pass"
    else
        login_pass_ask "New password for $(cut -f1 <<<"$l")" "$(cut -f3 <<<"$l")"; pass="$REPLY_VAL"
        "sc_rotate_$t" "$pass"
    fi
}

sc_portal() {
    local pass
    explain "Rotate the portal's admin password" \
"akadmin guards every admin tool behind the portal. Set here, through
authentik's API, and stored in .env (AUTHENTIK_ADMIN_PASSWORD is otherwise
read only at authentik's first start). Kept out of 'all' on purpose: the
shared password also sits in the arrs' and qBittorrent's settings."
    login_pass_ask "New password" AUTHENTIK_ADMIN_PASSWORD; pass="$REPLY_VAL"
    sc_rotate_portal "$pass"
}

sc_all() { # one password on every login of an enabled service that is set up (its password stored)
    local t l pass ukey u titles="" done_=()
    while IFS=$'\t' read -r t l; do titles+="  - $(cut -f1 <<<"$l")"$'\n'; done < <(sc_lines enabled)
    explain "One password across the stack" \
"Sets a single password on each of these that is set up:
${titles}Usernames stay as they are. Deliberate trade-off: one reused password
means one leak opens everything — use a strong, stack-unique one.
NOT covered: the portal's admin (set-credentials portal — it guards the
rest), and an app's own admin that is not one of the stack's logins
(Wizarr's — credentials says which): rotate those in the app's UI."
    login_pass_ask "New stack password"; pass="$REPLY_VAL"
    while IFS=$'\t' read -r t l; do
        if [[ -z "$(env_get "$(cut -f3 <<<"$l")")" ]]; then info "$(cut -f1 <<<"$l"): not set up yet — skipped"; continue; fi
        if [[ "$(login_opt "$l" ask_user)" == yes ]]; then
            ukey=$(cut -f2 <<<"$l"); u=$(env_get "$ukey")
            "sc_rotate_$t" "${u:-admin}" "$pass"
        else "sc_rotate_$t" "$pass"; fi
        done_+=("$t")
    done < <(sc_lines enabled)
    signin_is authentik && info "the portal's admin keeps its own password: ./mediastack.sh set-credentials portal"
    ok "one password now covers: ${done_[*]:-nothing (none set up)} — view: ./mediastack.sh credentials"
}


cmd_reset_password() { # someone locked out: a single-use link — the portal's sign-in link, or (Wizarr) Wizarr's reset link
    load_env; render
    local user="${1:-}"
    [[ -n "$user" ]] || die "usage: reset-password <username>"
    if signin_is wizarr; then
        [[ "$(c_health "$(svc_cname jellyfin)")" == healthy ]] || die "jellyfin is not healthy yet — ./mediastack.sh status jellyfin"
        wizarr_reset_link "$user"; return 0
    fi
    signin_is authentik || die "Neither account model is enabled — there are no accounts to reset."
    [[ "$(c_health "$(svc_cname authentik)")" == healthy ]] || die "authentik is not healthy yet — ./mediastack.sh status authentik"
    authentik_recover "$user"
}

cmd_signout() { # someone's Jellyfin sign-ins end on every device (any account model); the password is not changed
    load_env; render
    local user="${1:-}"
    [[ -n "$user" ]] || die "usage: signout <username>"
    svc_enabled jellyfin || die "signout ends Jellyfin sign-ins, and Jellyfin is not enabled"
    [[ "$(c_health "$(svc_cname jellyfin)")" == healthy ]] || die "jellyfin is not healthy yet — ./mediastack.sh status jellyfin"
    jellyfin_signout "$user"
    if signin_is authentik; then info "their portal password and any device password still sign in — delete a device's password first (the portal: Settings → Credentials → Tokens and App passwords)"
    elif signin_is wizarr; then info "their password still signs in — a new one: ./mediastack.sh reset-password $user"
    else info "their password still signs in — change it in Jellyfin's dashboard → Users"; fi
}

cmd_users() { # the portal's people, as authentik has them
    load_env; render
    signin_is authentik || die "the portal (authentik) is not enabled — with Wizarr, people are Jellyfin's own (its dashboard → Users)"
    [[ "$(c_health "$(svc_cname authentik)")" == healthy ]] || die "authentik is not healthy yet — ./mediastack.sh status authentik"
    local out
    out=$(signin_people) || die "authentik refused the user list: $(oneline "$out")"
    { printf 'USERNAME\tNAME\tEMAIL\tGROUPS\tSIGN-IN\n'
      jq -r '.results[] | select(.type == "internal" and .username != "akadmin" and .username != "mediastack-ldap-search")
        | [.username, (.name // "-" | if . == "" then "-" else . end), (.email // "" | if . == "" then "-" else . end),
           ([.groups_obj[]?.name] | if length == 0 then "-" else join(",") end), (if .is_active then "yes" else "off" end)] | @tsv' <<<"$out"
    } | table_print
    info "the stack's own accounts (akadmin, mediastack-ldap-search) are left out; change an email: ./mediastack.sh set-email <user> <address>"
}

# ---- access: who may open which app behind the portal's gate (docs/design-access.md) ----
ACCESS_USAGE="access [list [user]]  |  access tier <app> frontend|admin [--yes]  |  access grant|revoke <user> <app>  |  access admin <user> on|off  |  access portal <user> on|off [--yes]"
cmd_access() { # access [list [user]] | access tier <app> frontend|admin [--yes] | access grant|revoke <user> <app> | access admin <user> on|off | access portal <user> on|off [--yes]
    load_env; render
    signin_is authentik || die "access is the portal's (authentik), and it is not enabled — with Wizarr, each app keeps its own login"
    [[ "$(c_health "$(svc_cname authentik)")" == healthy ]] || die "authentik is not healthy yet — ./mediastack.sh status authentik"
    local sub="${1:-list}"; (( $# )) && shift
    case "$sub" in
        list) (( $# <= 1 )) || die "usage: access list [user]"
              if (( $# )); then access_list_user "$1"; else access_list; fi ;;
        tier) access_tier "$@" ;;
        grant) access_grant "$@" ;;
        revoke) access_revoke "$@" ;;
        admin) access_admin "$@" ;;
        portal) access_portal "$@" ;;
        *) die "usage: ./mediastack.sh $ACCESS_USAGE" ;;
    esac
}

access_people() { # -> the portal's people (authentik's user list), or the stop says why
    local out; out=$(signin_people) || die "authentik refused the user list: $(oneline "$out")"
    echo "$out"
}

access_person() { # access_person NAME -> ACC_PERSON: that person's entry (the name in any case); stops when there is none
    local people
    people=$(access_people)
    ACC_PERSON=$(jq -c --arg n "${1,,}" 'first(.results[] | select((.username | ascii_downcase) == $n)) // empty' <<<"$people")
    [[ -n "$ACC_PERSON" ]] || die "the portal has no user '$1' (its people: ./mediastack.sh users)"
}

access_in() { jq -e --arg g "$2" 'any(.groups_obj[]?; .name == $g)' <<<"$1" >/dev/null; }   # access_in PERSON GROUP

access_why() { # access_why PERSON SVC -> the group that gives them the app, a grant aside; nothing when none does
    if access_in "$1" "$PORTAL_ADMIN"; then echo "$PORTAL_ADMIN"
    elif [[ "$(svc_tier "$2")" == frontend ]] && access_in "$1" "$PORTAL_FRONTEND"; then echo "$PORTAL_FRONTEND (its tier)"; fi
    return 0
}

access_apps() { authentik_gate_apps; authentik_native_ruled; }   # every app access covers: behind the gate, then those that sign people in themselves
access_native() { [[ " $(authentik_native_ruled | tr '\n' ' ') " == *" $1 "* ]]; }   # access_native SVC — it signs people in itself (its own switch, not the portal's sessions)
access_app() { # access_app SVC — stops unless access covers it
    [[ " $(access_apps | tr '\n' ' ') " == *" $1 "* ]] \
        || die "'$1' is not an app access covers — those are: $(access_apps | paste -sd' ' -) (Seerr follows Jellyfin's rule)"
}

access_sessions_said() { # access_sessions_said N -> the sentence for N portal sessions ended
    if [[ "$1" == 0 ]]; then echo "no portal session of theirs was open"
    else echo "their portal sessions ended ($1), so their next visit asks again"; fi
}

access_list() { # every app behind the gate: its tier, who has it on its own, its address
    local people s
    people=$(access_people)
    { printf 'APP\tTIER\tGIVEN ON ITS OWN TO\tADDRESS\n'
      for s in $(access_apps); do
          printf '%s\t%s\t%s\t%s\n' "$s" "$(svc_tier "$s")" \
              "$(jq -r --arg g "app-$s" '[.results[] | select(any(.groups_obj[]?; .name == $g)) | .username] | if length == 0 then "-" else join(",") end' <<<"$people")" \
              "$(svc_url "$s")"
      done
    } | table_print
    info "frontend: the household and its admins; admin: admins only (the portal's '$PORTAL_ADMIN' group). Move one: ./mediastack.sh access tier <app> frontend|admin"
    info "Give one person one app: ./mediastack.sh access grant <user> <app> (take it back: access revoke)"
    info "Seerr signs people in through Jellyfin and follows its rule (./mediastack.sh users)"
}

access_list_user() { # access_list_user NAME — what that person may open of the apps access covers, and why
    local u s why rows="" name
    access_person "$1"; u=$ACC_PERSON; name=$(jq -r .username <<<"$u")
    # the rows gathered first: a count kept inside a pipe's block stays there (a subshell)
    for s in $(access_apps); do
        why=$(access_why "$u" "$s")
        if [[ -z "$why" ]] && access_in "$u" "app-$s"; then why="given on its own (app-$s)"; fi
        [[ -n "$why" ]] || continue
        rows+="$s"$'\t'"$why"$'\t'"$(svc_url "$s")"$'\n'
    done
    if [[ -n "$rows" ]]; then printf 'APP\tWHY\tADDRESS\n%s' "$rows" | table_print
    else info "$name may open none of the apps access covers"; fi
    jq -e '.is_active' <<<"$u" >/dev/null || warn "$name's portal account is off — they sign in to nothing"
    local sg
    if sg=$(signin_supergroup); then
        if access_in "$u" "$sg"; then info "$name also manages the portal itself ('$sg' — authentik's admin screens; take it back: access portal $name off)"; fi
    else warn "whether $name manages the portal is unknown: $sg"; fi
}

access_tier() { # access_tier APP frontend|admin [--yes] — kept in .env; the card's rule applied now; who loses it signed out of the portal
    local yes=0 args=() s t cur def stem people losers=() lost
    while (( $# )); do case "$1" in --yes) yes=1; shift ;; -*) die "Unknown access tier arg '$1'" ;; *) args+=("$1"); shift ;; esac; done
    (( ${#args[@]} == 2 )) || die "usage: access tier <app> frontend|admin [--yes]"
    s=${args[0]}; t=${args[1]}
    [[ "$t" == frontend || "$t" == admin ]] || die "access tier: '$t' — frontend (the household and its admins) or admin (admins only)"
    access_app "$s"
    cur=$(svc_tier "$s")
    [[ "$cur" != "$t" ]] || { ok "access: $s is $t already"; return 0; }
    if [[ "$t" == frontend ]]; then
        warn "access: $s for the household — everyone in '$PORTAL_FRONTEND' can then open it and do what it does there (in a download or settings tool: add, change and delete what it holds)"
        (( yes )) || confirm "Open $s to the household?" || { info "nothing changed: $s stays $cur"; return 0; }
    fi
    if [[ "$t" == admin ]]; then
        # who loses it: the household, but not admins and not those given it on its own
        people=$(access_people)
        mapfile -t losers < <(jq -r --arg fe "$PORTAL_FRONTEND" --arg ad "$PORTAL_ADMIN" --arg g "app-$s" '.results[]
            | select([.groups_obj[]?.name] as $n | ($n | index($fe)) != null and ($n | index($ad)) == null and ($n | index($g)) == null)
            | "\(.pk)\t\(.username)"' <<<"$people")
    fi
    def=$(svc_tier_default "$s"); stem=$(uvar "$s")
    if [[ "$t" == "$def" ]]; then env_del "${stem}_TIER"; else env_set "${stem}_TIER" "$t"; fi
    WIRE_FAILS=0
    # shellcheck disable=SC2034  # read by the wire steps (lib/wire.sh) and ak_card
    WIRE_DRY=0 AK_CARDS_QUIET=1
    wire_authentik_cards
    (( ! WIRE_FAILS )) || die "access: $s's rule did not take ($WIRE_FAILS failure(s) above) — .env says $t; ./mediastack.sh wire authentik tries again"
    if (( ${#losers[@]} )) && access_native "$s"; then
        # it signs people in itself: its own switch (the follow below) ends their sign-ins, not the portal's sessions
        ok "access: $s is admin-only — ${#losers[@]} of the household lost it ($(printf '%s\n' "${losers[@]}" | cut -f2 | paste -sd, -))"
    elif (( ${#losers[@]} )); then
        # the gate decided when each session began: only a new sign-in hears no (proven live, 16 Nov 2026)
        local pks=() l
        for l in "${losers[@]}"; do pks+=("${l%%$'\t'*}"); done
        lost=$(signin_sessions_end "${pks[@]}") \
            || die "access: $s is admin-only now, but authentik refused to end the sessions of those who lost it: $(oneline "$lost")"
        ok "access: $s is admin-only — ${#losers[@]} of the household lost it ($(printf '%s\n' "${losers[@]}" | cut -f2 | paste -sd, -)); $(access_sessions_said "$lost")"
    else
        ok "access: $s is $t now"
    fi
    people_follow_now "$s"   # an app with accounts of its own follows now (Navidrome's music apps, Jellyfin's sign-ins)
}

access_grant() { # access_grant USER APP — into app-<app>: they may open it whatever its tier
    (( $# == 2 )) || die "usage: access grant <user> <app>"
    local s=$2 u name why out
    access_app "$s"; access_person "$1"; u=$ACC_PERSON; name=$(jq -r .username <<<"$u")
    [[ "$(jq -r .type <<<"$u")" == internal ]] || die "access: '$name' is not a person's account"
    access_in "$u" "app-$s" && { ok "access: $name has $s granted already"; return 0; }
    out=$(signin_app_group_ready "$s") || die "access: $out — ./mediastack.sh wire authentik makes it; then grant again"
    out=$(signin_group_change add "$(jq -r .pk <<<"$u")" "app-$s") || die "access: authentik did not grant $name $s: $(oneline "$out")"
    why=$(access_why "$u" "$s")
    if [[ -n "$why" ]]; then ok "access: $s granted to $name — they could already open it through $why; the grant keeps it if that changes"
    else ok "access: $name can now open $s (granted)"; fi
    jq -e '.is_active' <<<"$u" >/dev/null || warn "$name's portal account is off — they sign in to nothing until it is on"
    people_follow_now "$s"
}

access_revoke() { # access_revoke USER APP — out of app-<app>; when that takes the app away, their portal sessions end
    (( $# == 2 )) || die "usage: access revoke <user> <app>"
    local s=$2 u name why out n
    access_app "$s"; access_person "$1"; u=$ACC_PERSON; name=$(jq -r .username <<<"$u")
    why=$(access_why "$u" "$s")
    if ! access_in "$u" "app-$s"; then
        case "$why" in
            "") ok "access: $name has no grant of $s — nothing to take away" ;;
            "$PORTAL_ADMIN") die "access: $name opens $s as one of '$PORTAL_ADMIN', not by a grant — ./mediastack.sh access admin $name off" ;;
            *) die "access: $name opens $s through its tier ($PORTAL_FRONTEND), not by a grant — for admins only: ./mediastack.sh access tier $s admin" ;;
        esac
        return 0
    fi
    out=$(signin_group_change remove "$(jq -r .pk <<<"$u")" "app-$s") || die "access: authentik did not take $s from $name: $(oneline "$out")"
    if [[ -n "$why" ]]; then ok "access: $name's grant of $s is gone — they still open it through $why"; return 0; fi
    if access_native "$s"; then   # its own switch ends their sign-ins (the follow below)
        ok "access: $name can no longer open $s"; people_follow_now "$s"; return 0
    fi
    # the gate decided when each session began: only a new sign-in hears no (proven live, 16 Nov 2026)
    n=$(signin_sessions_end "$(jq -r .pk <<<"$u")") \
        || die "access: $name lost $s, but authentik refused to end their portal sessions: $(oneline "$n") — end them by hand (the user → Sessions)"
    ok "access: $name can no longer open $s — $(access_sessions_said "$n"); a device password of theirs stops within a minute"
    people_follow_now "$s"
}

access_admin() { # access_admin USER on|off — into or out of the portal's admin group: every app, and admin rights where an app signs people in itself
    (( $# == 2 )) || die "usage: access admin <user> on|off"
    local want=$2 u name pk out n s sg
    [[ "$want" == on || "$want" == off ]] || die "access admin: '$want' — on or off"
    access_person "$1"; u=$ACC_PERSON; name=$(jq -r .username <<<"$u"); pk=$(jq -r .pk <<<"$u")
    # authentik's own superuser, an admin from its first start: the way in when no person is one
    [[ "$name" != akadmin ]] || die "access: akadmin is authentik's own superuser and stays an admin — use it only when no one else can get in"
    [[ "$(jq -r .type <<<"$u")" == internal ]] || die "access: '$name' is not a person's account"
    if [[ "$want" == on ]]; then
        access_in "$u" "$PORTAL_ADMIN" && { ok "access: $name is an admin already"; return 0; }
        out=$(signin_group_change add "$pk" "$PORTAL_ADMIN") || die "access: authentik did not make $name an admin: $(oneline "$out")"
        ok "access: $name is an admin — every app behind the gate, and admin rights in those that sign people in themselves"
        jq -e '.is_active' <<<"$u" >/dev/null || warn "$name's portal account is off — they sign in to nothing until it is on"
    else
        access_in "$u" "$PORTAL_ADMIN" || { ok "access: $name is not an admin — nothing to take away"; return 0; }
        # nobody keeps authentik's superuser rights after losing admin (access portal needs admin)
        sg=$(signin_supergroup) || die "access: $sg — nothing changed: whether $name manages the portal is unknown"
        if access_in "$u" "$sg"; then
            out=$(signin_group_change remove "$pk" "$sg") || die "access: authentik did not take $name out of '$sg': $(oneline "$out") — nothing else changed"
            ok "access: $name no longer manages the portal ('$sg')"
        fi
        out=$(signin_group_change remove "$pk" "$PORTAL_ADMIN") || die "access: authentik did not take $name out of '$PORTAL_ADMIN': $(oneline "$out")"
        # the gate decided when each session began: only a new sign-in hears no (proven live, 16 Nov 2026)
        n=$(signin_sessions_end "$pk") \
            || die "access: $name is no longer an admin, but authentik refused to end their portal sessions: $(oneline "$n") — end them by hand (the user → Sessions)"
        ok "access: $name is no longer an admin — $(access_sessions_said "$n"); what they keep: ./mediastack.sh access list $name"
    fi
    for s in $(people_apps); do people_follow_now "$s"; done   # admin rights in the apps with accounts of their own follow now
}

access_portal() { # access_portal USER on|off [--yes] — authentik's own superuser group: its admin screens, for an admin who chooses to have them
    local yes=0 args=() want u name pk sg out n
    while (( $# )); do case "$1" in --yes) yes=1; shift ;; -*) die "Unknown access portal arg '$1'" ;; *) args+=("$1"); shift ;; esac; done
    (( ${#args[@]} == 2 )) || die "usage: access portal <user> on|off [--yes]"
    want=${args[1]}
    [[ "$want" == on || "$want" == off ]] || die "access portal: '$want' — on or off"
    access_person "${args[0]}"; u=$ACC_PERSON; name=$(jq -r .username <<<"$u"); pk=$(jq -r .pk <<<"$u")
    [[ "$name" != akadmin ]] || die "access: akadmin is authentik's own superuser and stays one — use it only when no one else can get in"
    [[ "$(jq -r .type <<<"$u")" == internal ]] || die "access: '$name' is not a person's account"
    sg=$(signin_supergroup) || die "access: $sg"
    if [[ "$want" == on ]]; then
        access_in "$u" "$sg" && { ok "access: $name manages the portal already ('$sg')"; return 0; }
        access_in "$u" "$PORTAL_ADMIN" || die "access: $name is not an admin — the portal's management goes only to an admin: ./mediastack.sh access admin $name on"
        warn "access: $name gets authentik's admin screens ('$sg') — they can then sign in as anyone, change anyone's password and every rule the gate uses; a leak of their password is a leak of every account. The stack's verbs (invite, access, users, set-email, reset-password) need none of this"
        (( yes )) || confirm "Let $name manage the portal?" || { info "nothing changed: $name does not manage the portal"; return 0; }
        out=$(signin_group_change add "$pk" "$sg") || die "access: authentik did not put $name in '$sg': $(oneline "$out")"
        ok "access: $name manages the portal — authentik's admin screens (Admin interface, top right of the portal)"
        warn "access: a change made there by hand ends nobody's session and can drift from what wire sets — the verbs do both right"
    else
        access_in "$u" "$sg" || { ok "access: $name does not manage the portal — nothing to take away"; return 0; }
        out=$(signin_group_change remove "$pk" "$sg") || die "access: authentik did not take $name out of '$sg': $(oneline "$out")"
        n=$(signin_sessions_end "$pk") \
            || die "access: $name no longer manages the portal, but authentik refused to end their portal sessions: $(oneline "$n") — end them by hand (the user → Sessions)"
        ok "access: $name no longer manages the portal — $(access_sessions_said "$n"); they stay an admin (take that too: access admin $name off)"
    fi
}

cmd_set_email() { # an admin changes a person's portal email; Kavita follows; a shared address warns, --yes overrides
    load_env; render
    local yes=0 args=()
    while (( $# )); do case "$1" in --yes) yes=1; shift ;; -*) die "Unknown set-email arg '$1'" ;; *) args+=("$1"); shift ;; esac; done
    (( ${#args[@]} == 2 )) || die "usage: set-email <user> <address> [--yes]"
    signin_is authentik || die "set-email is for the portal (authentik); it is not enabled."
    [[ "$(c_health "$(svc_cname authentik)")" == healthy ]] || die "authentik is not healthy yet — ./mediastack.sh status authentik"
    authentik_set_email "${args[0]}" "${args[1]}" "$yes"
}

cmd_invite() { # mint an invitation (authentik's or Wizarr's, whichever runs) and print the ready-to-share URL
    load_env; render
    if signin_is authentik; then
        local days=7 to=""   # single use, a week: an unused link stops working on its own
        local usage="usage: invite [--expires 1|7|30] [--email ADDRESS]   (default: 7 days)"
        while [[ $# -gt 0 ]]; do case "$1" in
            --expires) case "${2:-}" in 1|7|30) days="$2"; shift 2 ;; *) die "$usage" ;; esac ;;
            --email) env_type_ok email "${2:-}" || die "'${2:-}' is not an email address — $usage"; to="$2"; shift 2 ;;
            *) die "$usage" ;;
        esac; done
        # checked before the invitation exists: no link is minted for a send that cannot happen
        [[ -z "$to" ]] || authentik_email_ready \
            || die "sending the invitation needs the portal's email working — set it up and test it: ./mediastack.sh email test <your address> (docs/email.md)"
        authentik_invite "$days" "$to"; return 0
    fi
    local expires=""
    while [[ $# -gt 0 ]]; do case "$1" in
        --expires) case "${2:-}" in 1|7|30) expires="$2"; shift 2 ;;
                   *) die "usage: invite [--expires 1|7|30]   (no flag = never expires)" ;; esac ;;
        --email) die "sending the invitation by email needs the portal (authentik) — with Wizarr, share the printed link yourself" ;;
        *) die "usage: invite [--expires 1|7|30]   (no flag = never expires)" ;;
    esac; done
    signin_is wizarr || die "Neither account model is enabled — invitations come from authentik or Wizarr: ./mediastack.sh enable authentik   (or: enable wizarr)"
    wizarr_invite "$expires"
}
