#!/usr/bin/env bash
# services/pihole/pihole.sh — Pi-hole's admin password (`set-credentials
# pihole`). Sourced by the entrypoint; relies on the entrypoint's helpers at
# call time.

# Behind the portal its page and API ask no password: Pi-hole reads it only at
# its start, so .env decides before `up` (PIHOLE_WEB_PASSWORD empty; compose
# falls back to PIHOLE_PASSWORD when the key is absent). Its API then answers
# whoever reaches its port — the host's 127.0.0.1 and the gate. DNS is apart.
pihole_gate_sync() { # PIHOLE_WEB_PASSWORD: empty while the portal guards it, absent otherwise — applied at its next start
    local has=no
    grep -qE '^PIHOLE_WEB_PASSWORD=' "$ENV_FILE" 2>/dev/null && has=yes
    if gate_planned pihole; then
        [[ $has == yes && -z "$(env_get PIHOLE_WEB_PASSWORD)" ]] && return 0
        env_set PIHOLE_WEB_PASSWORD ""
        info "pihole: no password of its own from its next start — the portal guards it"
    else
        [[ $has == no ]] && return 0
        env_del PIHOLE_WEB_PASSWORD
        info "pihole: its own password again from its next start — no portal guards it"
    fi
}

PIHOLE_AUTH_WAIT=60   # seconds a recreated Pi-hole may take to answer its API
pihole_gate_login() { # `disable authentik` (GATE_UNTRUSTED=1): its password back while its port is still local — recreated, then proven to ask for it
    local url out t=0
    pihole_gate_sync
    DC up -d pihole >/dev/null 2>&1 || { wfail "pihole: could not recreate it with its own password — inspect: ./mediastack.sh logs pihole"; return 0; }
    url="http://127.0.0.1:$(svc_hostport pihole)/api/auth"
    # Pi-hole v6's GET /api/auth: valid true for anyone while it has no password
    until out=$(curl -s -m 5 "$url" 2>/dev/null) && jq -e '.session.valid | type == "boolean"' <<<"$out" >/dev/null 2>&1; do
        (( t >= PIHOLE_AUTH_WAIT )) && { wfail "pihole: its API did not answer within ${PIHOLE_AUTH_WAIT}s of its recreate — inspect: ./mediastack.sh logs pihole"; return 0; }
        sleep 3; t=$((t + 3))
    done
    if jq -e '.session.valid == false' <<<"$out" >/dev/null; then ok "pihole: asks for its password again"
    else wfail "pihole: still opens without a password after its recreate — check PIHOLE_PASSWORD in .env"; fi
}

sc_rotate_pihole() { # PASS — env-driven; recreate applies it
        local pass="$1"
        svc_enabled pihole || { info "pihole not enabled — skipped"; return 0; }
        env_set PIHOLE_PASSWORD "$pass"
        if gate_planned pihole; then
            ok "Pi-hole password stored — it asks none while the portal guards it, and takes this one back when the portal goes"
            return 0
        fi
        DC up -d pihole >/dev/null 2>&1 \
            && ok "Pi-hole password rotated (container recreated)" \
            || wfail "Pi-hole recreate failed — apply with: ./mediastack.sh up"
}

pihole_logins() { printf "Pi-hole's admin page (a password, no name)\t-\tPIHOLE_PASSWORD\n"; }   # lib/logins.sh
