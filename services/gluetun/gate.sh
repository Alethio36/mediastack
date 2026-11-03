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
