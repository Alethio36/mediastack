#!/usr/bin/env bash
# lib/people.sh — with the portal, each app's own accounts follow it
# (docs/design-access.md, part 3, decisions 10-13). Apps that sign people in
# themselves keep accounts and sessions the portal never sees; their stack-
# owned admin keeps those accounts in step:
#   who may open an app   people_may — the one rule (decision 10)
#   who the stack turned off, per app   people_get / people_set, in
#                         local/<app>-people: only an account the stack turned
#                         off is ever turned back on (decision 12)
#   when                  in each app's wire; every 15 minutes (people-sync,
#                         mediastack-people.timer); at once for the app an
#                         `access` command changed (decision 13)
# Each app's part is <app>_people_follow in its folder, listed in PEOPLE_APPS
# (scripts/check-registries.sh holds the list to its functions). An app is
# followed once its wire has reached its portal step (people_follow_on): the
# timer's run must never beat the wire that makes the stack's admin (found
# live with Navidrome). Sourced by the entrypoint; relies on the portal's
# signin_* helpers, the entrypoint's helpers and lib/wire.sh at call time.

PEOPLE_APPS=(jellyfin kavita audiobookshelf navidrome)   # the order a run follows them in
PEOPLE_TIMER=mediastack-people
PEOPLE_FOLLOWED=people-followed   # local/state: the apps whose wire reached the portal step, space-separated

# ---- the record: who the stack turned off, per app ----
people_file() { echo "$LOCAL_DIR/$1-people"; }   # people_file APP — name<TAB>state, one per person the portal was seen behind
people_get() { awk -F'\t' -v n="${2,,}" 'tolower($1) == n { print $2; exit }' "$(people_file "$1")" 2>/dev/null || true; }   # people_get APP NAME
people_set() { # people_set APP NAME STATE — record it (STATE "": forget it)
    local f tmp; f=$(people_file "$1"); tmp=$(mktemp)
    awk -F'\t' -v n="${2,,}" 'tolower($1) != n' "$f" 2>/dev/null > "$tmp" || true
    [[ -z "$3" ]] || printf '%s\t%s\n' "$2" "$3" >> "$tmp"
    mkdir -p "$LOCAL_DIR"; mv -f "$tmp" "$f"; chmod 600 "$f"; repo_owned "$LOCAL_DIR" "$f"
}

# ---- the rule (decision 10) ----
people_may() { # people_may PERSON-JSON SVC — 0 when their portal account is on and they may open the app
    jq -e '.is_active == true' <<<"$1" >/dev/null || return 1
    access_in "$1" "$PORTAL_ADMIN" && return 0
    [[ "$(svc_tier "$2")" == frontend ]] && access_in "$1" "$PORTAL_FRONTEND" && return 0
    access_in "$1" "app-$2"
}
people_rule_ready() { # -> 0 when both groups the rule reads exist; else the reason (nobody may be judged by a missing group)
    local g pk
    for g in "$PORTAL_ADMIN" "$PORTAL_FRONTEND"; do
        pk=$(ak_group_pk "$g") || { echo "authentik's groups are unreadable: $(oneline "$pk")"; return 1; }
        [[ -n "$pk" ]] || { echo "authentik has no '$g' group (has the portal's setup applied? ./mediastack.sh doctor)"; return 1; }
    done
}

# ---- which apps are followed ----
people_followed() { [[ " $(state_get "$PEOPLE_FOLLOWED") " == *" $1 "* ]]; }   # people_followed APP
people_follow_on() { # people_follow_on APP — its wire reached the portal step: follow it from now on, and start the timer
    (( WIRE_DRY )) && return 0
    people_followed "$1" || state_set "$PEOPLE_FOLLOWED" "$(echo "$(state_get "$PEOPLE_FOLLOWED") $1" | xargs)"
    people_timer_ensure
}

people_timer_ensure() { # write, enable and start the timer; reloads systemd only when a file changed
    local svc tim changed=0
    svc=$(mktemp); tim=$(mktemp)
    timer_service_render "Mediastack: people follow the portal" people-sync > "$svc"
    timer_timer_render "Mediastack: people follow the portal" "*:0/15" > "$tim"
    sudo cmp -s "$svc" "$SYSTEMD_DIR/$PEOPLE_TIMER.service" 2>/dev/null || { sudo install -m 644 "$svc" "$SYSTEMD_DIR/$PEOPLE_TIMER.service"; changed=1; }
    sudo cmp -s "$tim" "$SYSTEMD_DIR/$PEOPLE_TIMER.timer" 2>/dev/null || { sudo install -m 644 "$tim" "$SYSTEMD_DIR/$PEOPLE_TIMER.timer"; changed=1; }
    rm -f "$svc" "$tim"
    (( changed )) || return 0
    failure_unit_ensure
    sudo systemctl daemon-reload
    sudo systemctl enable --now "$PEOPLE_TIMER.timer" >/dev/null 2>&1 \
        || die "could not enable $PEOPLE_TIMER.timer — check: systemctl status $PEOPLE_TIMER.timer"
    info "the apps' people follow the portal every 15 minutes (people-sync)"
}

people_apps_now() { # -> the followed apps that are enabled and running, in PEOPLE_APPS order
    local a
    for a in "${PEOPLE_APPS[@]}"; do
        people_followed "$a" && svc_enabled "$a" || continue
        if [[ "$(c_state "$(svc_cname "$a")")" == running ]]; then echo "$a"
        else info "$a is not running — its people not checked" >&2; fi
    done
    return 0
}

cmd_people_sync() { # the timer's run; a failure goes to ops through the unit's failure hook
    load_env; render
    signin_is authentik || return 0   # nothing to follow
    # a backup, an update or up has the stack (and may have stopped these): the next run is 15 minutes away
    maint_try_lock || { info "people-sync: an update, a backup or up has the stack — checked again in 15 minutes"; return 0; }
    local apps=() a ready=()
    mapfile -t apps < <(people_apps_now)
    (( ${#apps[@]} )) || { info "people-sync: no app follows the portal yet (each starts at its wire)"; return 0; }
    WIRE_FAILS=0; WIRE_DRY=0
    # the boot: the timer catches up at once, before the portal answers (found live, 17 Nov 2026)
    if ! wait_verdict authentik "${apps[@]}"; then
        [[ " $VERDICT_BAD " == *" authentik "* ]] && die "people-sync: authentik ${VERDICT_WHY[authentik]} — nobody's access was checked"
        for a in $VERDICT_BAD; do wfail "people-sync: $a ${VERDICT_WHY[$a]} — its people not checked"; done
    fi
    for a in "${apps[@]}"; do
        [[ " $VERDICT_BAD " == *" $a "* ]] && continue
        ready+=("$a")
    done
    for a in "${ready[@]}"; do "${a//-/_}_people_follow" || true; done   # each counts its own failures (WIRE_FAILS)
    (( ! WIRE_FAILS )) || die "people-sync: $WIRE_FAILS change(s) failed (above)"
}

people_follow_now() { # people_follow_now SVC — an access command changed who may open it: its people follow now
    local s=$1
    [[ " ${PEOPLE_APPS[*]} " == *" $s "* ]] || return 0
    people_followed "$s" && svc_enabled "$s" || return 0
    [[ "$(c_state "$(svc_cname "$s")")" == running ]] \
        || { warn "access: $s is not running — its accounts follow once it is (people-sync, within 15 minutes)"; return 0; }
    # shellcheck disable=SC2034  # read by the wire steps (lib/wire.sh)
    WIRE_FAILS=0 WIRE_DRY=0
    "${s//-/_}_people_follow" || true
    (( ! WIRE_FAILS )) || die "access: the portal changed, but $s's accounts did not follow ($WIRE_FAILS failure(s) above) — people-sync tries again within 15 minutes"
    # said even when nothing above changed: people-sync may have got there first (found live, 18 Nov 2026)
    ok "access: $s's own accounts follow the portal — any change to them is above"
}
