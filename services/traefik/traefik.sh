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

traefik_doctor() { # doctor: the certificate — your own (its expiry), or Let's Encrypt's store (its mode, staging or production, the wildcard)
    if svc_enabled traefik && [[ -n "$(env_get STACK_DOMAIN)" ]] && certs_own; then
        local cert days why
        cert=$(env_get TLS_CERT_FILE)
        why=$(own_cert_problem "$cert" "$(env_get TLS_KEY_FILE)" "$(env_get STACK_DOMAIN)")
        days=$(own_cert_days_left "$cert")
        if [[ -n "$why" ]]; then
            d_fail "your certificate cannot be served: $why" "Traefik serves it for every name under $(env_get STACK_DOMAIN)" "replace the files (TLS_CERT_FILE / TLS_KEY_FILE), then: ./mediastack.sh up"
        elif (( days < TLS_RENEW_WARN_DAYS )); then
            warn "your certificate expires in $days days ($(own_cert_until "$cert")) — renewal is yours: replace the files, then ./mediastack.sh up"
        else
            ok "your own certificate, until $(own_cert_until "$cert") ($days days)"
        fi
        # a pair that cannot serve is the finding above, not a copy to apply
        [[ -n "$why" ]] || sudo cmp -s "$cert" "$(env_get CONFIG_ROOT)/traefik/certs/fullchain.pem" \
            || warn "Traefik serves an older copy than your certificate file — apply it: ./mediastack.sh up"
    elif svc_enabled traefik && [[ -n "$(env_get STACK_DOMAIN)" ]]; then
        local acmef; acmef="$(env_get CONFIG_ROOT)/traefik/acme/acme.json"
        if sudo test -s "$acmef"; then
            [[ "$(sudo stat -c %a "$acmef")" == 600 ]] && ok "acme.json permissions 600" \
                || warn "acme.json is NOT mode 600 — traefik will refuse it; fix: sudo chmod 600 $acmef"
            if sudo grep -q "acme-staging" "$acmef"; then
                warn "STAGING certificates active — browsers will warn, and apps that check the portal's certificate refuse it (Kavita's portal sign-in is skipped; Audiobookshelf's likely fails). For real use: ./mediastack.sh traefik-setup --certs"
            else
                ok "production certificates in the store"
            fi
            sudo grep -q "\*.$(env_get STACK_DOMAIN)" "$acmef" \
                && ok "wildcard certificate present for *.$(env_get STACK_DOMAIN)" \
                || warn "no wildcard certificate for *.$(env_get STACK_DOMAIN) yet — check: logs traefik"
        else
            warn "traefik configured but no certificates issued yet — check: logs traefik"
        fi
    fi
}
