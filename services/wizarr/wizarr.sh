#!/usr/bin/env bash
# services/wizarr/wizarr.sh — Wizarr's address and its `wire wizarr` role.
# Sourced by the entrypoint; relies on lib/wire.sh, lib/addr.sh and the
# entrypoint's helpers at call time.

# ---- wizarr (wave 4) ----
# Wizarr's admin account, jellyfin connection, and API keys are web-UI-only
# by upstream design — no bootstrap API exists. One documented first-run in
# the UI, then wire holds the API key and './mediastack.sh invite' does the
# rest forever.
wizarr_url() { local p; p=$(svc_hostport wizarr) || return 1; echo "http://127.0.0.1:$p"; }

wire_wizarr() {
    hr "wire: wizarr"
    svc_enabled wizarr || { info "wizarr not enabled — skipped"; return 0; }
    wire_gate wizarr
    # a virgin wizarr 302s /health to /setup (onboarding middleware) —
    # any 2xx/3xx means the app is up and serving
    http_ready wizarr "$(wizarr_url)/health" '^[23]' || return 1
    local key host domain
    key=$(env_get WIZARR_API_KEY)
    if [[ -z "$key" ]]; then
        if (( WIRE_DRY )); then
            w_would "store + verify a wizarr API key (pasted by you after wizarr's one-time UI first-run)" || true
            return 0
        fi
        if [[ ! -t 0 ]]; then
            info "no WIZARR_API_KEY yet — wizarr's first-run is a one-time UI step; run './mediastack.sh wire wizarr' interactively after it"
            return 0
        fi
        host=$(env_get WIZARR_HOST invites); domain=$(env_get TRAEFIK_DOMAIN)
        local jfkey; jfkey=$(env_get JELLYFIN_API_KEY "(empty — run 'wire jellyfin' first to mint it)")
        explain "Wizarr first-run (one-time, in its UI)" \
"Wizarr's admin account and API keys can only be created in its web UI —
there is no automation API for this by upstream design. Once, ever:
  1. open ${domain:+https://$host.$domain (or }http://$(hostname -I 2>/dev/null | awk '{print $1}'):$(svc_hostport wizarr)${domain:+)}
  2. create the admin account
  3. Settings -> Servers -> Add Server:
       Name            jellyfin
       Server Type     Jellyfin
       URL (Internal)  http://$(svc_addr jellyfin)
       API Key         $jfkey
     then Test & Add
  4. Settings -> API Keys -> create one, and paste it below
Paste nothing to skip for now — re-run 'wire wizarr' any time."
        ask_token "Wizarr API key (input is hidden; empty = skip)" ""
        key="$REPLY_VAL"
        [[ -n "$key" ]] || { info "skipped — invites stay in wizarr's UI until a key is stored"; return 0; }
        env_set WIZARR_API_KEY "$key"
    fi
    local out
    if ! out=$(curl -sS -m 15 -H "X-API-Key: $key" -w $'\n%{http_code}' "$(wizarr_url)/api/invitations" 2>&1); then
        wfail "wizarr unreachable while verifying the API key: $(head -c200 <<<"$out")"; return 1
    fi
    code=${out##*$'\n'}
    if [[ "$code" =~ ^2 ]]; then
        ok "API key verified — mint invites with: ./mediastack.sh invite"
    else
        wfail "wizarr rejected the stored API key [HTTP $code] — recreate it in Settings -> API Keys, then re-run 'wire wizarr' (the old value stays in .env until replaced)"
        return 1
    fi
}

wizarr_doctor() { # doctor: apps — its stored API key works ('invite' needs it)
    local wkey wcode
    wkey=$(env_get WIZARR_API_KEY)
    if [[ -z "$wkey" ]]; then
        warn "wizarr has no stored API key — invites need it: ./mediastack.sh wire wizarr"
    else
        wcode=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -H "X-API-Key: $wkey" \
                "$(wizarr_url)/api/invitations" 2>/dev/null || echo 000)
        [[ "$wcode" =~ ^2 ]] && ok "wizarr API key works ('invite' is ready)" \
            || d_fail "wizarr rejected the stored API key [HTTP $wcode]" "'invite' cannot mint links" "recreate the key in wizarr's Settings -> API Keys, then: ./mediastack.sh wire wizarr"
    fi
}
