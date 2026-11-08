#!/usr/bin/env bash
# services/cloudflared/cloudflared.sh — the Cloudflare tunnel's token, asked by
# configure and by `enable cloudflared` (its questionnaire hook). The tunnel
# never runs without one: it would only crash-loop. Sourced by the entrypoint;
# relies on lib/common.sh at call time.

cloudflared_questions() { # the questionnaire: the tunnel's token, asked once; none turns the tunnel off
    if ! svc_enabled cloudflared; then return 0; fi
    if answer CLOUDFLARE_TUNNEL_TOKEN; then env_set CLOUDFLARE_TUNNEL_TOKEN "$REPLY_VAL"; q_answered "Tunnel token" "" secret; return 0; fi
    [[ -z "$(env_get CLOUDFLARE_TUNNEL_TOKEN)" ]] || return 0
    # optional: with no one to ask, the tunnel stays off
    if [[ -n "$ANSWERS_FILE" ]] && ! q_terminal; then cloudflared_off; return 0; fi
    answers_checking && return 0   # asked in pass 2
    cloudflared_token_ask && return 0
    cloudflared_off
}
cloudflared_off() { # configure's record for no token: the tunnel leaves the selection
    env_set COMPOSE_PROFILES "$(env_get COMPOSE_PROFILES | tr ',' '\n' | grep -vx cloudflared | paste -sd, -)"
    info "No token — the tunnel is off. Turn it on later: ./mediastack.sh enable cloudflared (it asks for the token)"
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
    prompt_guard "Tunnel token"
    read -r -s -p "Tunnel token (input hidden; Enter = no tunnel): " tok; echo
    [[ -n "$tok" ]] || return 1
    env_set CLOUDFLARE_TUNNEL_TOKEN "$tok"
    ok "Tunnel token stored."
}
