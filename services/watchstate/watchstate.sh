#!/usr/bin/env bash
# services/watchstate/watchstate.sh — WatchState's own login behind the portal
# (docs/design-logins.md). Sourced by the entrypoint; relies on the
# entrypoint's helpers at call time.

# Behind the portal WatchState asks no login of the people the portal let in:
# its WS_TRUST_LOCAL signs in whoever comes from WS_TRUST_LOCAL_NET, and that
# is Traefik's fixed address alone (compose). It reads both only at its start,
# so .env decides before `up`. Its own forwarded-header trust (WS_TRUST_PROXY)
# stays off: with it on, a caller could name Traefik's address in a header.
watchstate_gate_sync() { # WATCHSTATE_TRUST_TRAEFIK: true while the portal guards it, absent otherwise — applied at its next start
    if gate_planned watchstate; then
        grep -qE '^WATCHSTATE_TRUST_TRAEFIK=true$' "$ENV_FILE" 2>/dev/null && return 0
        env_set WATCHSTATE_TRUST_TRAEFIK true
        info "watchstate: no login of its own for the portal's people from its next start — the portal guards it"
    else
        grep -qE '^WATCHSTATE_TRUST_TRAEFIK=' "$ENV_FILE" 2>/dev/null || return 0
        env_del WATCHSTATE_TRUST_TRAEFIK
        info "watchstate: its own login again from its next start — no portal guards it"
    fi
}

watchstate_from_traefik() { # -> its has_user answer to a caller at Traefik's own address (empty: it has no account yet); rc 1, the reason in its place
    # asked from inside Traefik's container: the one address it trusts, so
    # the answer is the one the portal's people get. By its service name: a
    # probe, not an address wire writes, and WatchState never rides the VPN
    sudo docker exec "$(svc_cname traefik)" wget -qO- --timeout=5 \
        "http://watchstate:$(svc_label watchstate mediastack.port)/v1/api/system/auth/has_user" 2>&1
}

WATCHSTATE_TRUST_WAIT=180   # seconds a recreated WatchState may take to answer (its start runs database maintenance)
watchstate_gate_login() { # `disable authentik` (GATE_UNTRUSTED=1): its login back while its port is still local — recreated, then proven from Traefik's address
    local out t=0
    [[ "$(c_state "$(svc_cname traefik)")" == running ]] \
        || { wfail "watchstate: Traefik is not running, so its login cannot be proven from Traefik's address — start it: ./mediastack.sh up"; return 0; }
    watchstate_gate_sync
    DC up -d watchstate >/dev/null 2>&1 || { wfail "watchstate: could not recreate it with its own login — inspect: ./mediastack.sh logs watchstate"; return 0; }
    until out=$(watchstate_from_traefik); do
        (( t >= WATCHSTATE_TRUST_WAIT )) && { wfail "watchstate: did not answer Traefik within ${WATCHSTATE_TRUST_WAIT}s of its recreate ($(oneline "$out")) — inspect: ./mediastack.sh logs watchstate"; return 0; }
        sleep 5; t=$((t + 5))
    done
    if [[ -z "$out" ]]; then
        warn "watchstate: it has no account yet — once the portal is gone, whoever opens it first makes one: open $(svc_url watchstate) now and make yours"
    elif jq -e '.auto_login == true' <<<"$out" >/dev/null 2>&1; then
        wfail "watchstate: still signs in Traefik's callers with no login after its recreate — its own settings (Env page; /config/config/.env) set WS_TRUST_LOCAL or WS_TRUST_LOCAL_NET: take them out there"
    elif jq -e 'type == "object"' <<<"$out" >/dev/null 2>&1; then
        ok "watchstate: asks for its own login again"
    else
        wfail "watchstate: its answer to Traefik is unreadable: $(oneline "$out")"
    fi
}
