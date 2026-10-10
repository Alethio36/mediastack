#!/usr/bin/env bash
# services/pihole/pihole.sh — Pi-hole's admin password (`set-credentials
# pihole`). Sourced by the entrypoint; relies on the entrypoint's helpers at
# call time.

sc_rotate_pihole() { # PASS — env-driven; recreate applies it
        local pass="$1"
        svc_enabled pihole || { info "pihole not enabled — skipped"; return 0; }
        env_set PIHOLE_PASSWORD "$pass"
        DC up -d pihole >/dev/null 2>&1 \
            && ok "Pi-hole password rotated (container recreated)" \
            || wfail "Pi-hole recreate failed — apply with: ./mediastack.sh up"
}

pihole_configure_secret() { # configure: its admin password, generated once
    if svc_enabled pihole && [[ -z "$(env_get PIHOLE_PASSWORD)" ]]; then
        env_set PIHOLE_PASSWORD "$(head -c12 /dev/urandom | base64 | tr -d '=+/')"
        ok "Generated Pi-hole admin password (view it any time in .env)."
    fi
}
