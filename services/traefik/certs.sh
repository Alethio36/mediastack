#!/usr/bin/env bash
# services/traefik/certs.sh — where the stack's certificate comes from
# (docs/certificates.md): Let's Encrypt through Cloudflare (TLS_SOURCE=
# letsencrypt, ACME_ENV production or staging), or two files of your own
# (TLS_SOURCE=own: TLS_CERT_FILE, TLS_KEY_FILE). Your files are checked when
# configure records them and on every `up`, then copied into Traefik's
# folder (read-only to it, mode 600) whenever they change: renewing is
# replacing them and running `up`. Sourced by the entrypoint; relies on
# lib/common.sh at call time.

TLS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt   # the public CAs an own certificate must chain to
# shellcheck disable=SC2034  # read by traefik_doctor and the questions (services/traefik/)
TLS_RENEW_WARN_DAYS=30                             # doctor warns this many days before an own certificate expires
TLS_RENEW_FAIL_DAYS=7                              # ...and fails at this many (configure and up refuse it too)

certs_own() { [[ "$(env_get TLS_SOURCE)" == own ]]; }

# Trusted inside the apps' own containers: Kavita and Jellyfin check the
# portal's certificate themselves. An own certificate is only accepted when
# it chains to a public CA (own_cert_problem), so it is trusted like a
# production one; a staging one is not.
certs_trusted() { certs_own || [[ "$(env_get ACME_ENV)" == production ]]; }

own_cert_problem() { # own_cert_problem CERT KEY DOMAIN -> why the pair cannot serve DOMAIN ("" when it can)
    local cert=$1 key=$2 dom=$3 h
    [[ -r "$cert" ]] || { echo "$cert cannot be read (it must exist and be readable by you)"; return 0; }
    [[ -r "$key" ]] || { echo "$key cannot be read (it must exist and be readable by you)"; return 0; }
    openssl x509 -in "$cert" -noout 2>/dev/null || { echo "$cert is not a PEM certificate"; return 0; }
    # Traefik cannot ask for a passphrase: an encrypted key never loads
    openssl pkey -in "$key" -noout -passin pass: 2>/dev/null || { echo "$key is not an unencrypted PEM private key"; return 0; }
    [[ "$(openssl x509 -in "$cert" -noout -pubkey 2>/dev/null)" == "$(openssl pkey -in "$key" -pubout 2>/dev/null)" ]] \
        || { echo "the key does not belong to the certificate"; return 0; }
    # every service has its own name under the domain: the wildcard, and the domain itself
    for h in "$dom" "mediastack-check.$dom"; do
        [[ "$(openssl x509 -in "$cert" -noout -checkhost "$h" 2>/dev/null)" == *"does match"* ]] \
            || { echo "the certificate does not cover $( [[ "$h" == "$dom" ]] && echo "$dom" || echo "*.$dom") — it must cover both $dom and *.$dom"; return 0; }
    done
    openssl x509 -in "$cert" -noout -checkend $(( TLS_RENEW_FAIL_DAYS * 86400 )) >/dev/null 2>&1 \
        || { echo "the certificate expires within $TLS_RENEW_FAIL_DAYS days ($(own_cert_until "$cert")) — renew it first"; return 0; }
    # the leaf (the file's first certificate), through the chain the file carries, to a public CA
    openssl verify -CAfile "$TLS_CA_BUNDLE" -untrusted "$cert" <(openssl x509 -in "$cert" 2>/dev/null) >/dev/null 2>&1 \
        || { echo "the certificate does not chain to a public CA (with the chain in the same file, leaf first) — the apps check the portal's certificate themselves and would refuse it"; return 0; }
}

own_cert_until() { openssl x509 -in "$1" -noout -enddate 2>/dev/null | sed 's/^notAfter=//'; }   # own_cert_until CERT -> its expiry, as openssl says it
own_cert_days_left() { # own_cert_days_left CERT -> whole days until it expires (negative once it has)
    local end; end=$(date -d "$(own_cert_until "$1")" +%s 2>/dev/null) || { echo 0; return 0; }
    echo $(( (end - $(date +%s)) / 86400 ))
}

own_cert_install() { # up: the recorded pair, checked, copied into Traefik's folder when it changed
    local croot cert key why
    croot=$(env_get CONFIG_ROOT); cert=$(env_get TLS_CERT_FILE); key=$(env_get TLS_KEY_FILE)
    why=$(own_cert_problem "$cert" "$key" "$(env_get STACK_DOMAIN)")
    [[ -z "$why" ]] || die "your certificate cannot be served: $why. Fix the files (TLS_CERT_FILE / TLS_KEY_FILE), or choose again: ./mediastack.sh traefik-setup --certs"
    sudo install -d -m 700 "$croot/traefik/certs"
    if ! sudo cmp -s "$cert" "$croot/traefik/certs/fullchain.pem" || ! sudo cmp -s "$key" "$croot/traefik/certs/privkey.pem"; then
        sudo install -m 600 "$cert" "$croot/traefik/certs/fullchain.pem"
        sudo install -m 600 "$key" "$croot/traefik/certs/privkey.pem"
        ok "your certificate is in place (until $(own_cert_until "$cert")) — Traefik reloads it by itself"
    fi
}
