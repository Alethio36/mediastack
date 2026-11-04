#!/usr/bin/env bash
# services/traefik/questions.sh — Traefik's questions: the questionnaire's
# traefik_questions hook (docs/design-install.md), asked again by
# traefik-setup. The domain, the certificate email, the Cloudflare token —
# checked with Cloudflare when it is pasted, together with the domain's zone —
# the certificates, and the dashboard's login. They ask and record only.
# Sourced by the entrypoint; relies on lib/common.sh and lib/questionnaire.sh
# at call time.

CF_API=https://api.cloudflare.com/client/v4

cf_api() { # cf_api TOKEN PATH -> Cloudflare's JSON reply; rc 1 when Cloudflare could not be reached
    # the token goes in on stdin (-K -), never on the command line where ps shows it
    curl -sS --max-time 20 -K - "$CF_API$2" <<<"header = \"Authorization: Bearer $1\""
}

cf_errors() { jq -r '[.errors[]?.message] | join("; ")' <<<"$1" 2>/dev/null || true; }   # cf_errors REPLY -> Cloudflare's own words

cf_check() { # cf_check TOKEN DOMAIN -> the zone it found (rc 0); why not: rc 3 the token, rc 4 the domain; rc 2 Cloudflare unreachable
    local tok="$1" z="$2" out tried=""
    out=$(cf_api "$tok" /user/tokens/verify) || return 2
    if [[ "$(jq -r '.success == true and .result.status == "active"' <<<"$out" 2>/dev/null)" != true ]]; then
        echo "Cloudflare refused the token ($(cf_errors "$out")) — copy it again, or make a new one."; return 3
    fi
    # the zone is the domain or a parent of it; a top-level name alone is never one
    while [[ "$z" == *.* ]]; do
        out=$(cf_api "$tok" "/zones?name=$z") || return 2
        if [[ "$(jq -r '.success' <<<"$out" 2>/dev/null)" != true ]]; then
            echo "Cloudflare would not say which zone the token covers ($(cf_errors "$out"))."; return 3
        fi
        if [[ "$(jq -r '.result | length' <<<"$out")" -gt 0 ]]; then echo "$z"; return 0; fi
        tried+="${tried:+, }$z"; z=${z#*.}
    done
    echo "the token sees no Cloudflare zone for $2 (looked for: $tried) — a typo in the domain, or a token made for another zone."
    return 4
}

traefik_questions() { # the questionnaire's hook; traefik-setup asks them again (TRAEFIK_FORCE=1)
    local domain email token why rc
    domain=$(env_get STACK_DOMAIN); email=$(env_get ACME_EMAIL); token=$(env_get CF_DNS_API_TOKEN)
    if q_quick && [[ -n "$domain" && -n "$email" && -n "$token" ]]; then
        q_took "HTTPS" "keep $domain"
    else
        explain "Your domain" \
"Every service gets its own address under one domain you own:
https://jellyfin.<domain>, https://requests.<domain>, and so on.
Before continuing, two things must exist at dash.cloudflare.com:
  1. the domain's DNS, hosted on Cloudflare
  2. a wildcard A record  *.<domain> -> this machine's LAN IP,
     with the proxy toggle OFF (grey cloud, 'DNS only')
This exposes nothing to the internet — the addresses only resolve
usefully on your own network."
        local first=1
        while true; do
            while true; do   # lowercased before the check: ask_valid would judge it as typed
                ask TD "Base domain (e.g. media.example.com)" "$domain"
                env_type_ok domain "${REPLY_VAL,,}" && { domain="${REPLY_VAL,,}"; break; }
                fail "'$REPLY_VAL' is not a domain name (e.g. media.example.com)."
            done
            if (( first )); then
                ask_valid email AE "Email for certificate-expiry notices" "$email" "an email address"; email="$REPLY_VAL"
                explain "Cloudflare API token" \
"Lets the stack prove to Let's Encrypt that you control the domain.
Create one at dash.cloudflare.com -> My Profile -> API Tokens ->
Create Token: give it the single permission  Zone / DNS / Edit,
scoped to just this domain's zone. (Not the Global API Key.)
It is checked with Cloudflare as soon as it is pasted."
                first=0
            fi
            while true; do
                ask_token "Paste the Cloudflare token (input hidden)" "$token"; token="$REPLY_VAL"
                rc=0; why=$(cf_check "$token" "$domain") || rc=$?
                case "$rc" in
                    0) ok "Cloudflare: the token is live and holds the zone $why"; break 2 ;;
                    3) fail "$why"; token="" ;;           # pasted again: Enter must not keep a refused token
                    4) fail "$why"; continue 2 ;;         # the domain asked again (the token is kept: Enter)
                    *) die "Could not reach Cloudflare's API to check the token — check this host's connection, then run configure again." ;;
                esac
            done
        done
        env_set STACK_DOMAIN "$domain"; env_set ACME_EMAIL "$email"; env_set CF_DNS_API_TOKEN "$token"
    fi
    traefik_cert_question
    traefik_dash_questions
}

traefik_cert_question() { # real certificates or Let's Encrypt's test ones
    if q_quick; then env_set ACME_ENV "$(env_get ACME_ENV)"; q_took "Certificates" "$(env_get ACME_ENV)"; return 0; fi
    explain "Certificates: real or testing?" \
"  production  real certificates, trusted by every browser. Let's
              Encrypt allows only 5 identical ones per week, so
              repeated install testing can lock you out for days.
  staging     unlimited test certificates. Browsers show a warning
              you can click through. Pick this while you are still
              testing; one setting change switches to production
              later and the stack handles the swap itself.
              Known limitation: apps that check the portal's
              certificate themselves refuse a staging one — Kavita's
              portal sign-in is skipped until production, and
              Audiobookshelf's is expected to fail."
    while true; do
        ask AV "Certificate environment (production/staging)" "$(env_get ACME_ENV)"
        case "${REPLY_VAL,,}" in production|staging) env_set ACME_ENV "${REPLY_VAL,,}"; return 0 ;; *) fail "Type production or staging." ;; esac
    done
}

traefik_dash_questions() { # the dashboard's login — none to ask with the portal (traefik_dash_fallback makes one)
    signin_is authentik && return 0
    local duser dpass
    duser=$(env_get TRAEFIK_DASH_USER); dpass=$(env_get TRAEFIK_DASH_PASSWORD)
    if [[ -n "$duser" && -n "$dpass" ]] && (( ! ${TRAEFIK_FORCE:-0} )); then
        q_quick && q_took "Dashboard login" "keep $duser"
        return 0
    fi
    # a password is only ever generated or typed — an empty one is never kept
    [[ -n "$dpass" ]] || dpass=$(head -c12 /dev/urandom | base64 | tr -d '=+/')
    if q_quick; then
        env_set TRAEFIK_DASH_USER "${duser:-admin}"; env_set TRAEFIK_DASH_PASSWORD "$dpass"
        q_took "Dashboard login" "${duser:-admin}, password generated (see: credentials)"; return 0
    fi
    explain "Dashboard login" \
"Traefik's dashboard (https://dash.<domain>) shows every route and
certificate. It cannot change anything, but it still gets a login.
Enter keeps the name shown and accepts a generated password; see them
later with: credentials"
    while true; do
        ask DU "Dashboard username" "${duser:-admin}"; duser="$REPLY_VAL"
        # basic auth splits on ':' — letters, digits and ._- only
        [[ "$duser" =~ ^[A-Za-z0-9._-]+$ ]] && break
        fail "Use letters, digits and . _ - only."
    done
    ask_secret "Dashboard password" "$dpass"
    env_set TRAEFIK_DASH_USER "$duser"; env_set TRAEFIK_DASH_PASSWORD "$REPLY_VAL"
}
