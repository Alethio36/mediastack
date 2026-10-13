#!/usr/bin/env bash
# services/traefik/traefik.sh — the Traefik dashboard's password
# (`set-credentials traefik`). The edge itself (routes, certificates, the
# gate) is services/traefik/edge.sh. Sourced by the entrypoint; relies on the entrypoint's
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

traefik_doctor() { # doctor: the certificate store — its mode, staging or production, the wildcard
    if svc_enabled traefik && [[ -n "$(env_get TRAEFIK_DOMAIN)" ]]; then
        local acmef; acmef="$(env_get CONFIG_ROOT)/traefik/acme/acme.json"
        if sudo test -s "$acmef"; then
            [[ "$(sudo stat -c %a "$acmef")" == 600 ]] && ok "acme.json permissions 600" \
                || warn "acme.json is NOT mode 600 — traefik will refuse it; fix: sudo chmod 600 $acmef"
            if sudo grep -q "acme-staging" "$acmef"; then
                warn "STAGING certificates active — browsers will warn. For real use: set ACME_ENV=production in .env, then ./mediastack.sh up"
            else
                ok "production certificates in the store"
            fi
            sudo grep -q "\*.$(env_get TRAEFIK_DOMAIN)" "$acmef" \
                && ok "wildcard certificate present for *.$(env_get TRAEFIK_DOMAIN)" \
                || warn "no wildcard certificate for *.$(env_get TRAEFIK_DOMAIN) yet — check: logs traefik"
        else
            warn "traefik configured but no certificates issued yet — check: logs traefik"
        fi
    fi
}
