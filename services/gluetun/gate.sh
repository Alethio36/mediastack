#!/usr/bin/env bash
# services/gluetun/gate.sh — the leak gate: the VPN group (every enabled
# service in gluetun's namespace) runs only once gluetun is proven.
#   * a leak-test verdict is acted on, whoever ran it (leak_verdict): a FAIL
#     stops the VPN group — gluetun stays up for inspection — and the stop is
#     remembered; an UNPROVEN only warns; ops hears each change once
#   * while the gate is closed nothing starts a member of the group (DC refuses,
#     leak_gate_refuse for raw docker calls); only `up` re-opens it, after
#     its own full leak-test passes (leak_gate_up)
# Sourced by the entrypoint; relies on lib/common.sh, lib/notify.sh and the
# entrypoint's render/inspect helpers at call time.

LEAK_GATE=leak-gate         # local/state: why and when a proven leak closed the gate; absent = open
LEAK_VERDICT=leak-verdict   # local/state: the last verdict (0 pass, 1 fail, 2 unproven) — ops hears changes only

vpn_namespace_services() { # every service in gluetun's namespace, enabled or not (recyclarr runs without its profile enabled)
    render
    jq -r '.services | to_entries[] | select((.value.network_mode // "") == "service:gluetun") | .key' <<<"$RENDERED_JSON" | sort
}
vpn_group() { # the VPN group: the enabled ones, one per line
    local s
    for s in $(vpn_namespace_services); do
        if svc_enabled "$s"; then echo "$s"; fi
    done
}

leak_gate_closed() { [[ -n "$(state_get "$LEAK_GATE")" ]]; }

leak_gate_refuse() { # leak_gate_refuse WHAT — die before WHAT starts a member of the VPN group while the gate is closed
    leak_gate_closed || return 0
    die "$1: the leak gate stopped the VPN group ($(state_get "$LEAK_GATE")). Find the leak: ./mediastack.sh leak-test — fix it, then: ./mediastack.sh up"
}

leak_gate_guards() { # leak_gate_guards COMPOSE-ARGS... -> 0 when DC may run them (DC's chokepoint)
    # a start (up, start, restart, run, create) of the whole stack or of a
    # group member is refused while the gate is closed; stop, ps, config... pass
    leak_gate_closed || return 0
    local verb=$1 a targets=() g t
    case $verb in up|start|restart|run|create) ;; *) return 0 ;; esac
    shift
    for a in "$@"; do
        [[ "$a" == -* ]] && continue
        targets+=("$a")
        [[ "$verb" == run ]] && break   # run SERVICE [COMMAND...]: only the service counts
    done
    (( ${#targets[@]} )) || return 1    # no service named: the whole stack, the group with it
    for g in $(vpn_namespace_services); do
        for t in "${targets[@]}"; do [[ "$t" == "$g" ]] && return 1; done
    done
    return 0
}

leak_gate_close() { # leak_gate_close WHY — stop the VPN group (gluetun stays up for inspection) and remember why
    local running=() s
    state_set "$LEAK_GATE" "$(date '+%F %T'): $1"
    # shellcheck disable=SC2034  # the inspect cache lives in the entrypoint (CACHE RULE at c_inspect)
    INSPECT_JSON=""
    for s in $(vpn_group); do
        if [[ "$(c_state "$(svc_cname "$s")")" == running ]]; then running+=("$s"); fi
    done
    (( ${#running[@]} )) || return 0
    DC stop "${running[@]}" >/dev/null \
        || die "leak gate: could not stop ${running[*]} — stop the stack by hand: ./mediastack.sh down"
    fail "leak gate: stopped the VPN group (${running[*]}) — gluetun stays up for inspection"
}

leak_verdict() { # leak_verdict RC — act on a leak-test verdict (LT_FIRST names its first problem)
    local rc=$1 prev
    prev=$(state_get "$LEAK_VERDICT")
    state_set "$LEAK_VERDICT" "$rc"
    case $rc in
        1)  leak_gate_close "$LT_FIRST"
            [[ "$prev" == 1 ]] || notify ops "Mediastack VPN LEAK — downloads stopped" \
                "leak-test proved a problem: \`$LT_FIRST\`"$'\n'"The VPN'd services are stopped; gluetun stays up for inspection."$'\n'"Fix it, then: \`./mediastack.sh up\` (it runs the checks again first)" failure ;;
        2)  [[ "$prev" == 2 ]] || notify ops "Mediastack leak-test: not everything proven" \
                "Nothing failed, but: \`$LT_FIRST\`"$'\n'"Nothing was stopped. Check: \`./mediastack.sh leak-test\`" warning ;;
        0)  if [[ -n "$prev" && "$prev" != 0 ]]; then
                if leak_gate_closed; then
                    notify ops "Mediastack leak checks pass again" "Every check proven. The VPN'd services stay stopped until: \`./mediastack.sh up\`" success
                else
                    notify ops "Mediastack leak checks pass again" "Every check proven." success
                fi
            fi ;;
    esac
}

leak_gate_up() { # up's gate: the full leak-test before the VPN group starts; a FAIL keeps it stopped and ends up
    local rc=0
    hr "Leak gate: proving gluetun before the VPN'd services start"
    leak_test_run 0 0 || rc=$?
    # opened before the verdict is told: its recovery message reads the gate
    if (( rc != 1 )); then state_del "$LEAK_GATE"; fi
    leak_verdict "$rc"
    case $rc in
        0) ok "leak gate: every check proven — starting the VPN'd services" ;;
        2) warn "leak gate: nothing failed, but not everything was proven (UNPROVEN above) — starting the VPN'd services" ;;
        *) die "leak gate: a problem is proven (FAIL above) — the VPN'd services stay stopped, gluetun stays up for inspection. Fix it, then: ./mediastack.sh up" ;;
    esac
}

# ---- proven: which gluetun the last full run vouched for ----
# A full leak-test that found no leak records gluetun's container and start
# time. Until gluetun restarts, a VPN'd service may start after the local
# checks alone; after a restart (a crash, a backup, a boot) the full run first.
LEAK_PROVEN=leak-proven   # local/state: "<container id> <started at>" of the gluetun last proven
gluetun_instance() { local cn; cn=$(svc_cname gluetun); echo "$(c_id "$cn") $(c_get "$cn" '.State.StartedAt')"; }
leak_proof_record() { INSPECT_JSON=""; state_set "$LEAK_PROVEN" "$(gluetun_instance)"; }
gluetun_proven() { local p; p=$(state_get "$LEAK_PROVEN"); [[ -n "$p" && "$p" == "$(gluetun_instance)" ]]; }

vpn_start_group() { # vpn_start_group SVC... — start these VPN'd services through the gate: 0 started, 3 held by it, 1 failed
    # gluetun must be up (the caller waits for it). The gate open, the tier
    # follows gluetun: proven since its last start -> the local checks, else
    # the full run. A FAIL closes the gate (leak_verdict) and nothing starts.
    local rc=0 lonly=0
    if leak_gate_closed; then
        warn "leak gate closed ($(state_get "$LEAK_GATE")) — not starting: $*"
        return 3
    fi
    if gluetun_proven; then lonly=1; fi
    hr "Leak gate: $( (( lonly )) && echo "local checks (gluetun proven since it started)" || echo "full checks (gluetun started since it was last proven)") before starting $*"
    leak_test_run 0 "$lonly" || rc=$?
    leak_verdict "$rc"
    (( rc != 1 )) || return 3
    DC up -d "$@" >/dev/null || { fail "starting $* failed — see compose's message above"; return 1; }
    vpn_reattach_guard
}

# ---- the supervisor: the 5-minute check, and the boot ----
# The VPN group is off Docker's restart policy (vpn_gen: restart "no") so that
# nothing starts it before gluetun is proven — at boot, Docker starts gluetun
# and the rest, never the group. This puts back what that policy did: every
# enabled member that is not running is started, through the gate, whether it
# crashed or the host just booted. To keep one stopped: disable it, or down.
vpn_supervise() { # vpn_supervise [full] — local or full checks (as gluetun's state needs, or full), then any member not running
    local full=${1:-} group=() missing=() s rc=0 lonly=0
    mapfile -t group < <(vpn_group)
    (( ${#group[@]} )) || return 0
    svc_enabled gluetun || return 0
    # shellcheck disable=SC2034  # the inspect cache lives in the entrypoint (CACHE RULE at c_inspect)
    INSPECT_JSON=""
    if [[ "$(c_state "$(svc_cname gluetun)")" != running ]]; then
        info "vpn-watch: gluetun is not running — Docker restarts it; checked again in 5 minutes"
        return 0
    fi
    wait_verdict --recover gluetun \
        || { warn "vpn-watch: gluetun ${VERDICT_WHY[gluetun]} — checked again in 5 minutes"; return 0; }
    # shellcheck disable=SC2034  # the inspect cache lives in the entrypoint (CACHE RULE at c_inspect)
    INSPECT_JSON=""
    for s in "${group[@]}"; do
        [[ "$(c_state "$(svc_cname "$s")")" == running ]] || missing+=("$s")
    done
    if (( ${#missing[@]} )); then
        vpn_start_group "${missing[@]}" || rc=$?
        (( rc != 1 )) || return 1
        return 0
    fi
    if [[ "$full" != full ]] && gluetun_proven; then lonly=1; fi
    leak_test_run 0 "$lonly" || rc=$?
    leak_verdict "$rc"
}

cmd_vpn_watch() { # the 5-minute check (mediastack-leakcheck.timer); --full: the hourly run (mediastack-leaktest.timer)
    load_env; render   # once, here: < <(vpn_group) and every $(svc_cname) would each render again in their subshells
    local full=""; [[ "${1:-}" == --full ]] && full=full
    # a backup, an update or `up` has the stack: they start the group
    # themselves. The hourly run waits a while for its turn; the 5-minute one is next soon
    if [[ -n "$full" ]]; then
        maint_lock "the hourly leak-test" 600 || { info "vpn-watch: the stack was held for 10 minutes — the full run waits for the next hour"; return 0; }
    else
        maint_try_lock || { info "vpn-watch: an update, a backup or up has the stack — checked again in 5 minutes"; return 0; }
    fi
    [[ ! -e "$STOP_MARKER" ]] || { info "vpn-watch: a backup is mid-copy — checked again later"; return 0; }
    # its own news went to ops (leak_verdict, one message per change): a
    # failed unit would only tell it again, so only a check that could not run fails
    vpn_supervise "$full" || die "vpn-watch: the VPN'd services could not be started — see above"
}

# The gate's three timers, one line each: UNIT|DESCRIPTION|VERB|ONCALENDAR|RANDOM DELAY (s)
#   every 5 minutes  the local checks, and the supervisor
#   hourly           the full run, at a random minute: who the internet sees
#   daily            this host's own address (RIPEstat), at a random time —
#                    never in the same run as the tunnel's checkers
# Fixed: the safety cadence is not a setting.
GATE_TIMERS=(
    "mediastack-leakcheck|Mediastack leak check and VPN group supervisor|vpn-watch|*:0/5|"
    "mediastack-leaktest|Mediastack hourly leak-test (the full run)|vpn-watch --full|hourly|3000"
    "mediastack-hostid|Mediastack record of this host's own address|host-identity|daily|43200"
)
gate_timer_field() { # gate_timer_field UNIT N -> field N (1-based) of its GATE_TIMERS line
    local l; for l in "${GATE_TIMERS[@]}"; do [[ "${l%%|*}" == "$1" ]] && { cut -d'|' -f"$2" <<<"$l"; return; }; done
}
gate_service_render() { timer_service_render "$(gate_timer_field "$1" 2)" "$(gate_timer_field "$1" 3)"; }
gate_timer_render()   { timer_timer_render "$(gate_timer_field "$1" 2)" "$(gate_timer_field "$1" 4)" "$(gate_timer_field "$1" 5)"; }
gate_timers_ensure() { # write, enable and start the gate's timers; reloads systemd only when a file changed
    local l u svc tim changed=0
    svc=$(mktemp); tim=$(mktemp)
    for l in "${GATE_TIMERS[@]}"; do
        u=${l%%|*}
        gate_service_render "$u" > "$svc"; gate_timer_render "$u" > "$tim"
        sudo cmp -s "$svc" "$SYSTEMD_DIR/$u.service" 2>/dev/null || { sudo install -m 644 "$svc" "$SYSTEMD_DIR/$u.service"; changed=1; }
        sudo cmp -s "$tim" "$SYSTEMD_DIR/$u.timer" 2>/dev/null || { sudo install -m 644 "$tim" "$SYSTEMD_DIR/$u.timer"; changed=1; }
    done
    rm -f "$svc" "$tim"
    (( changed )) || return 0
    failure_unit_ensure
    sudo systemctl daemon-reload
    for l in "${GATE_TIMERS[@]}"; do
        u=${l%%|*}
        sudo systemctl enable --now "$u.timer" >/dev/null 2>&1 \
            || die "could not enable $u.timer — check: systemctl status $u.timer"
    done
    info "leak checks scheduled: local every 5 minutes, the full run hourly, this host's own address daily"
}
