#!/usr/bin/env bash
# services/traefik/traefik.sh — the Traefik dashboard's password
# (`set-credentials traefik`). The edge itself (routes, certificates, the
# gate) is lib/edge.sh. Sourced by the entrypoint; relies on the entrypoint's
# helpers at call time.

sc_rotate_traefik() { # PASS — regenerated into the watched dynamic config
        local pass="$1"
        svc_enabled traefik || { info "traefik not enabled — skipped"; return 0; }
        [[ -n "$(env_get TRAEFIK_DASH_USER)" ]] || { info "traefik dashboard never configured — skipped (run traefik-setup first)"; return 0; }
        env_set TRAEFIK_DASH_PASSWORD "$pass"
        traefik_gen \
            && ok "Traefik dashboard password rotated (config regenerated; traefik watches it live)" \
            || wfail "traefik config regeneration failed — inspect: ./mediastack.sh traefik-setup"
}
