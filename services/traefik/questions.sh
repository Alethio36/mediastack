#!/usr/bin/env bash
# services/traefik/questions.sh — Traefik's questions: the questionnaire's
# traefik_questions hook (docs/design-install.md), asked again by
# traefik-setup. The domain and where its certificate comes from: Let's
# Encrypt (the expiry email, the Cloudflare token — checked with Cloudflare
# when it is pasted, together with the domain's zone) or your own files
# (checked when given, services/traefik/certs.sh); the dashboard's login is one of the stack's own
# (traefik_logins, lib/logins.sh). They ask and record only.
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

traefik_questions() { # the questionnaire's hook; traefik-setup asks them again
    local domain rc why
    domain=$(env_get STACK_DOMAIN)
    if q_quick && [[ -z "$(traefik_missing)" ]]; then
        # an answer is kept only while it still works: your certificate's files
        # can go missing (a rebuilt host, found live Nov 2026)
        why=$(traefik_cert_why)
        if [[ -z "$why" ]]; then q_took "HTTPS" "keep $domain, $(traefik_cert_words)"; return 0; fi
        warn "HTTPS: your certificate cannot be kept — $why. Asked again below."
    fi
    traefik_cert_question
    # explained right before it is asked, after the certificate's choice
    explain "Your domain" \
"Every service gets its own address under one domain you own:
https://jellyfin.<domain>, https://requests.<domain>, and so on.
Your network needs a wildcard DNS record  *.<domain> -> this machine's
LAN IP (on Cloudflare: proxy toggle OFF, grey cloud, 'DNS only'). This
exposes nothing to the internet — the addresses only resolve usefully on
your own network."
    while true; do
        while true; do   # lowercased before the check: ask_valid would judge it as typed
            ask TD "Base domain (e.g. media.example.com)" "$domain"
            env_type_ok domain "${REPLY_VAL,,}" && { domain="${REPLY_VAL,,}"; break; }
            fail "'$REPLY_VAL' is not a domain name (e.g. media.example.com)."
        done
        rc=0; traefik_cert_specifics "$domain" || rc=$?
        (( rc == 4 )) || break   # 4: the domain does not fit (no zone for it, or a certificate that does not cover it) — asked again
    done
    env_set STACK_DOMAIN "$domain"
}

traefik_cert_why() { # why the recorded certificate cannot serve now ("" when it can, or Let's Encrypt issues it)
    certs_own || return 0
    own_cert_problem "$(env_get TLS_CERT_FILE)" "$(env_get TLS_KEY_FILE)" "$(env_get STACK_DOMAIN)"
}

traefik_cert_words() { # what the certificate is, in the summary's words
    local until
    if certs_own; then until=$(own_cert_until "$(env_get TLS_CERT_FILE)"); echo "your own certificate${until:+ (until $until)}"
    else echo "Let's Encrypt $(env_get ACME_ENV) certificates"; fi
}

traefik_cert_question() { # where the certificate comes from -> TLS_SOURCE, and ACME_ENV for Let's Encrypt
    local def=1
    if certs_own; then def=2; elif [[ "$(env_get ACME_ENV)" == staging ]]; then def=3; fi
    if q_quick; then
        env_set TLS_SOURCE "$(env_get TLS_SOURCE)"; env_set ACME_ENV "$(env_get ACME_ENV)"
        q_took "Certificates" "$(traefik_cert_words)"; return 0
    fi
    explain "Certificates" \
"  1) Let's Encrypt  real certificates, trusted by every browser, renewed by
                    the stack itself — your domain's DNS on Cloudflare and
                    a Cloudflare token (asked next) (recommended)
  2) your own       two PEM files you provide and renew: the certificate with
                    its chain, and its unencrypted key. It must cover the
                    domain and *.<domain>, and come from a public CA — the apps
                    check the portal's certificate themselves (docs/certificates.md)
  3) staging        Let's Encrypt's unlimited test certificates. Browsers warn;
                    Kavita's portal sign-in waits for real ones and
                    Audiobookshelf's is expected to fail. Production allows only
                    5 identical certificates a week: staging is for test installs."
    while true; do
        ask CERTS "Choice" "$def"
        case "$REPLY_VAL" in
            1) env_set TLS_SOURCE letsencrypt; env_set ACME_ENV production; return 0 ;;
            2) env_set TLS_SOURCE own; return 0 ;;
            3) env_set TLS_SOURCE letsencrypt; env_set ACME_ENV staging; return 0 ;;
            *) fail "Pick 1, 2 or 3." ;;
        esac
    done
}

traefik_cert_specifics() { # traefik_cert_specifics DOMAIN -> rc 0 recorded; 4 the domain does not fit (asked again)
    if certs_own; then traefik_own_files "$1"; return; fi
    local email token why rc
    email=$(env_get ACME_EMAIL); token=$(env_get CF_DNS_API_TOKEN)
    if [[ -z "${TRAEFIK_EMAIL_ASKED:-}" ]]; then
        ask_valid email AE "Email for certificate-expiry notices" "$email" "an email address"; env_set ACME_EMAIL "$REPLY_VAL"
        explain "Cloudflare API token" \
"Lets the stack prove to Let's Encrypt that you control the domain.
Create one at dash.cloudflare.com -> My Profile -> API Tokens ->
Create Token: give it the single permission  Zone / DNS / Edit,
scoped to just this domain's zone. (Not the Global API Key.)
It is checked with Cloudflare as soon as it is pasted."
        TRAEFIK_EMAIL_ASKED=1
    fi
    while true; do
        ask_token "Paste the Cloudflare token (input hidden)" "$token"; token="$REPLY_VAL"
        rc=0; why=$(cf_check "$token" "$1") || rc=$?
        case "$rc" in
            0) ok "Cloudflare: the token is live and holds the zone $why"; env_set CF_DNS_API_TOKEN "$token"; return 0 ;;
            3) fail "$why"; token="" ;;                 # pasted again: Enter must not keep a refused token
            4) fail "$why"; env_set CF_DNS_API_TOKEN "$token"; return 4 ;;   # the domain asked again (the token is kept: Enter)
            *) die "Could not reach Cloudflare's API to check the token — check this host's connection, then run configure again." ;;
        esac
    done
}

traefik_own_files() { # traefik_own_files DOMAIN -> rc 0 recorded; 4 the certificate does not cover DOMAIN (asked again)
    local cert key why
    cert=$(env_get TLS_CERT_FILE); key=$(env_get TLS_KEY_FILE)
    explain "Your certificate" \
"Two PEM files, anywhere on this host and readable by you. They are checked
now, and on every 'up' copied into Traefik's own folder when they change:
to renew, replace them and run ./mediastack.sh up. doctor warns $TLS_RENEW_WARN_DAYS days
before the certificate expires."
    while true; do
        ask TLS_CERT_FILE "Certificate file (the certificate, then its chain)" "$cert"; cert=$(abspath "${REPLY_VAL/#\~/$HOME}")
        ask TLS_KEY_FILE "Its private key file" "$key"; key=$(abspath "${REPLY_VAL/#\~/$HOME}")
        why=$(own_cert_problem "$cert" "$key" "$1")
        [[ -n "$why" ]] || break
        fail "$why"
        if [[ "$why" == "the certificate does not cover"* ]]; then env_set TLS_CERT_FILE "$cert"; env_set TLS_KEY_FILE "$key"; return 4; fi
    done
    env_set TLS_CERT_FILE "$cert"; env_set TLS_KEY_FILE "$key"
    ok "your certificate covers $1 and *.$1 and chains to a public CA — until $(own_cert_until "$cert")"
}

traefik_logins() { printf "the Traefik dashboard\tTRAEFIK_DASH_USER\tTRAEFIK_DASH_PASSWORD\n"; }   # lib/logins.sh — with the portal, admins sign in through it and this is the fallback
traefik_summary() { printf 'HTTPS\t%s, %s\n' "$(env_get STACK_DOMAIN)" "$(traefik_cert_words)"; }   # its line of configure's summary
