#!/usr/bin/env bash
# services/cloudflared/cloudflared.sh — the Cloudflare tunnel's token, asked by
# configure and by `enable cloudflared`. The tunnel never runs without one: it
# would only crash-loop. Sourced by the entrypoint; relies on lib/common.sh at
# call time.
cloudflared_configure_secret() { # configure: the tunnel's token, asked once; none turns the tunnel off
    if ! svc_enabled cloudflared || [[ -n "$(env_get CLOUDFLARE_TUNNEL_TOKEN)" ]]; then return 0; fi
    cloudflared_token_ask && return 0
    env_set COMPOSE_PROFILES "$(env_get COMPOSE_PROFILES | tr ',' '\n' | grep -vx cloudflared | paste -sd, -)"
    info "No token — the tunnel is off. Turn it on later: ./mediastack.sh enable cloudflared (it asks for the token)"
}

cloudflared_enable_check() { # cloudflared_enable_check "SVC..." — enable: a set that brings the tunnel brings its token
    grep -qx cloudflared <<<"$1" || return 0
    [[ -z "$(env_get CLOUDFLARE_TUNNEL_TOKEN)" ]] || return 0
    [[ -t 0 ]] || die "cloudflared needs its tunnel token — run './mediastack.sh enable cloudflared' in a terminal to paste it"
    cloudflared_token_ask || die "No token — nothing changed. The tunnel cannot run without one."
}

cloudflared_token_ask() { # explain, then a hidden paste; 0 with the token stored, 1 when left blank
    explain "Cloudflare tunnel (optional)" \
"Only for reaching the stack from outside your network through Cloudflare.
Not using a tunnel? Leave the token blank: the tunnel stays off." \
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
    local tok
    read -r -s -p "Tunnel token (input hidden; Enter = no tunnel): " tok; echo
    [[ -n "$tok" ]] || return 1
    env_set CLOUDFLARE_TUNNEL_TOKEN "$tok"
    ok "Tunnel token stored."
}
