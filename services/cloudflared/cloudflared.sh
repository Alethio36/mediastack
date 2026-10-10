#!/usr/bin/env bash
# services/cloudflared/cloudflared.sh — the Cloudflare tunnel's token, asked by
# configure. Sourced by the entrypoint; relies on lib/common.sh at call time.
cloudflared_configure_secret() { # configure: the tunnel's token, asked once (the tunnel itself is Cloudflare's)
    if svc_enabled cloudflared && [[ -z "$(env_get CLOUDFLARE_TUNNEL_TOKEN)" ]]; then
        explain "Cloudflare tunnel" \
"The tunnel is created on CLOUDFLARE'S side; this stack just runs the
connector. One-time setup in their dashboard:" \
"  1. dash.cloudflare.com -> Zero Trust -> Networks -> Tunnels" \
"  2. Create a tunnel (type: cloudflared), name it, save" \
"  3. From the install step, copy ONLY the long token string" \
"     (the part after '--token' in the command they show)" \
"AFTER the stack is up, routing also lives in that dashboard: add Public
Hostnames pointing at http://traefik:80 if Traefik is enabled (one
hostname per service, same names as your HTTPS routes) or directly at a
service, e.g. http://jellyfin:8096. Service names resolve — cloudflared
shares the stack's network."
        read -r -p "Tunnel token: " REPLY_VAL
        if [[ -n "$REPLY_VAL" ]]; then
            env_set CLOUDFLARE_TUNNEL_TOKEN "$REPLY_VAL"
        else
            warn "No token — cloudflared will crash-loop until one is set in .env."
        fi
    fi
}
