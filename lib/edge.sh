#!/usr/bin/env bash
# lib/edge.sh — the Traefik HTTPS edge: traefik_ensure (auto-run by up),
# traefik_gen (generated static + dynamic config), hostname and certificate
# re-setup (the traefik-setup verb). Sourced by the entrypoint; relies on
# lib/common.sh and the entrypoint's service/render/inspect helpers at call
# time.

# ================================================================= traefik --
# Wave 3: the edge. All config is generated (desired state from .env); the
# only imperative act is issuing certs, which Traefik does itself.

traefik_ensure() { # traefik_ensure [--reconfigure]; runs on up/enable; idempotent
    svc_enabled traefik || return 0
    local force=0; [[ "${1:-}" == --reconfigure ]] && force=1
    local domain email token acmeenv duser
    domain=$(env_get TRAEFIK_DOMAIN); email=$(env_get ACME_EMAIL)
    token=$(env_get CF_DNS_API_TOKEN)
    if [[ -z "$domain" || -z "$email" || -z "$token" ]] || (( force )); then
        if [[ ! -t 0 ]]; then
            (( force )) && die "traefik-setup needs a terminal."
            die "traefik is enabled but not configured (TRAEFIK_DOMAIN/ACME_EMAIL/CF_DNS_API_TOKEN) and there is no terminal to ask — run './mediastack.sh traefik-setup' interactively first."
        fi
        hr "Traefik setup"
        (( force )) && info "Enter keeps the value shown in [brackets]."
        explain "Your domain" \
"Every service gets its own address under one domain you own:
https://jellyfin.<domain>, https://requests.<domain>, and so on.
Before continuing, two things must exist at dash.cloudflare.com:
  1. the domain's DNS, hosted on Cloudflare
  2. a wildcard A record  *.<domain> -> this machine's LAN IP,
     with the proxy toggle OFF (grey cloud, 'DNS only')
This exposes nothing to the internet — the addresses only resolve
usefully on your own network."
        ask TD "Base domain (e.g. media.example.com)" "${domain}"; domain="$REPLY_VAL"
        [[ -n "$domain" ]] || die "A domain is required."
        ask AE "Email for certificate-expiry notices" "${email}"; email="$REPLY_VAL"
        explain "Cloudflare API token" \
"Lets the stack prove to Let's Encrypt that you control the domain.
Create one at dash.cloudflare.com -> My Profile -> API Tokens ->
Create Token: give it the single permission  Zone / DNS / Edit,
scoped to just this domain's zone. (Not the Global API Key.)"
        ask_token "Paste the Cloudflare token (input is hidden)" "$token"; token="$REPLY_VAL"
        explain "Certificates: real or testing?" \
"  production  real certificates, trusted by every browser. Let's
              Encrypt allows only 5 identical ones per week, so
              repeated install testing can lock you out for days.
  staging     unlimited test certificates. Browsers show a warning
              you can click through — everything else works the
              same. Pick this while you are still testing; one
              setting change switches to production later and the
              stack handles the swap itself."
        ask AV "Certificate environment [production/staging]" "$(env_get ACME_ENV production)"
        case "$REPLY_VAL" in production|staging) acmeenv="$REPLY_VAL" ;; *) die "Expected 'production' or 'staging'." ;; esac
        env_set TRAEFIK_DOMAIN "$domain"; env_set ACME_EMAIL "$email"
        env_set CF_DNS_API_TOKEN "$token"; env_set ACME_ENV "$acmeenv"
    fi
    duser=$(env_get TRAEFIK_DASH_USER)
    if [[ -z "$duser" ]] || (( force )); then
        [[ -t 0 ]] || die "traefik dashboard credentials unset and no terminal — run './mediastack.sh traefik-setup'."
        explain "Dashboard login" \
"Traefik's dashboard (https://dash.<domain>) shows every route and
certificate. It cannot change anything, but it still gets a login.
Enter accepts a generated password; see it later with: credentials"
        ask DU "Dashboard username" "$(env_get TRAEFIK_DASH_USER admin)"; duser="$REPLY_VAL"
        ask_secret "Dashboard password" "$(env_get TRAEFIK_DASH_PASSWORD "$(head -c12 /dev/urandom | base64 | tr -d '=+/')")"
        env_set TRAEFIK_DASH_USER "$duser"; env_set TRAEFIK_DASH_PASSWORD "$REPLY_VAL"
    fi
    traefik_gen
}

traefik_gen() {
    local croot domain acmeenv caline hash duser dpass prehash posthash
    croot=$(env_get CONFIG_ROOT); domain=$(env_get TRAEFIK_DOMAIN)
    acmeenv=$(env_get ACME_ENV production)
    # docker creates missing bind sources as root-owned DIRECTORIES; if the
    # container ever started before setup, our file paths are junk dirs now
    local f
    for f in "$croot/traefik/traefik.yml" "$croot/traefik/dynamic.yml" "$croot/traefik/dynamic/00-mediastack.yml"; do
        sudo test -d "$f" && { warn "removing docker-created junk directory at $f"; sudo rm -rf "$f"; }
    done
    sudo test -d /run-traefik-setup-first && sudo rm -rf /run-traefik-setup-first
    sudo install -d -m 700 "$croot/traefik" "$croot/traefik/acme"
    install -d -m 755 local/proxy.d
    env_set TRAEFIK_LOCAL_PROXY "$PWD/local/proxy.d"
    # env switch detection: staging certs must not survive into production
    # (and vice versa) — traefik would keep serving the cached ones forever
    local acme="$croot/traefik/acme/acme.json" stored=""
    if sudo test -s "$acme"; then
        sudo grep -q "acme-staging" "$acme" && stored=staging || stored=production
        if [[ "$stored" != "$acmeenv" ]]; then
            warn "ACME_ENV is '$acmeenv' but stored certificates are '$stored' — resetting the certificate store so the switch takes effect (reissue happens automatically)."
            sudo mv "$acme" "$acme.old-$stored.$(date +%s)"
        fi
    fi
    prehash=$(sudo cat "$croot/traefik/traefik.yml" "$croot/traefik/dynamic/00-mediastack.yml" 2>/dev/null | sha256sum)
    caline=""
    [[ "$acmeenv" == staging ]] && caline='      caServer: "https://acme-staging-v02.api.letsencrypt.org/directory"'
    local tmp; tmp=$(mktemp)
    cat > "$tmp" <<STATIC
# GENERATED by mediastack traefik-setup — DO NOT EDIT. Knobs live in .env.
ping: {}
api:
  dashboard: true
entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"
providers:
  docker:
    exposedByDefault: false
    network: mediastack
  file:
    directory: /dynamic
    watch: true
certificatesResolvers:
  le:
    acme:
      email: $(env_get ACME_EMAIL)
      storage: /letsencrypt/acme.json
$caline
      dnsChallenge:
        provider: cloudflare
        resolvers:
          - "1.1.1.1:53"
          - "8.8.8.8:53"
STATIC
    sudo install -m 600 "$tmp" "$croot/traefik/traefik.yml"
    duser=$(env_get TRAEFIK_DASH_USER); dpass=$(env_get TRAEFIK_DASH_PASSWORD)
    # deterministic salt: identical inputs must yield an identical file, or
    # the change-detection restart fires on every regeneration
    hash=$(openssl passwd -apr1 -salt "$(printf '%s' "$duser:$dpass" | sha256sum | cut -c1-8)" "$dpass")
    cat > "$tmp" <<DYNAMIC
# GENERATED by mediastack traefik-setup — DO NOT EDIT.
# The dashboard router is also the single wildcard-cert requester: every
# other router says tls=true and reuses the cert issued here.
http:
  routers:
    dashboard:
      rule: "Host(\`$(env_get TRAEFIK_DASH_HOST dash).$domain\`)"
      entryPoints: [websecure]
      service: api@internal
      middlewares: [dash-auth]
      tls:
        certResolver: le
        domains:
          - main: "$domain"
            sans: ["*.$domain"]
  middlewares:
    dash-auth:
      basicAuth:
        users:
          - "$duser:$hash"
DYNAMIC
    sudo install -d -m 700 "$croot/traefik/dynamic"
    sudo rm -f "$croot/traefik/dynamic.yml"   # pre-dir layout leftover
    sudo install -m 600 "$tmp" "$croot/traefik/dynamic/00-mediastack.yml"; rm -f "$tmp"
    # user proxy hosts: copied in (applied on every up / traefik-setup)
    sudo rm -f "$croot/traefik/dynamic/"user-*.yml
    local uf n=0
    for uf in local/proxy.d/*.yml; do
        [[ -e "$uf" ]] || break
        sudo install -m 600 "$uf" "$croot/traefik/dynamic/user-$(basename "$uf")"; n=$((n+1))
    done
    (( n )) && info "$n user proxy file(s) from local/proxy.d applied"
    ok "traefik config generated ($acmeenv certificates, domain $domain)"
    # static config only loads at container start; a content change on a
    # running traefik needs an explicit restart or it silently stays stale
    posthash=$(sudo cat "$croot/traefik/traefik.yml" "$croot/traefik/dynamic/00-mediastack.yml" 2>/dev/null | sha256sum)
    if [[ "$prehash" != "$posthash" ]] \
        && sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$(svc_cname traefik)"; then
        info "config changed — restarting traefik to load it"
        # shellcheck disable=SC2034  # the inspect cache lives in the entrypoint (CACHE RULE at c_inspect)
        INSPECT_JSON=""
        sudo docker restart "$(svc_cname traefik)" >/dev/null \
            && ok "traefik restarted" \
            || wfail "traefik restart failed — restart it manually: sudo docker restart $(svc_cname traefik)"
    fi
}

# hostname map is discovered from the fragments' own router labels
# (${X_HOST:-default}), so it self-maintains as services are added
traefik_host_vars() {
    grep -rhoE '\$\{[A-Z0-9_]+_HOST:-[a-z0-9-]+\}' compose.d/ \
        | sed -E 's/^\$\{([A-Z0-9_]+_HOST):-([a-z0-9-]+)\}$/\1 \2/' | sort -u
    echo "TRAEFIK_DASH_HOST dash"
}

cmd_traefik_hosts() {
    [[ -t 0 ]] || die "traefik-setup --hosts needs a terminal."
    local domain; domain=$(env_get TRAEFIK_DOMAIN)
    [[ -n "$domain" ]] || die "Run './mediastack.sh traefik-setup' first — no domain configured yet."
    hr "Service hostnames"
    explain "Pick each service's address" \
"Enter keeps the name shown in [brackets]. Names must be a single DNS
label: letters, numbers, hyphens (not first or last). The wildcard
certificate covers any choice — renames are free."
    local var def cur val
    local -A chosen
    # map on fd 3: ask() must keep stdin for the person's answers
    while read -r var def <&3; do
        cur=$(env_get "$var"); cur=${cur:-$def}
        while :; do
            ask HV "  ${var%_HOST} -> https://?.$domain" "$cur"; val="$REPLY_VAL"
            [[ "$val" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] \
                || { warn "'$val' is not a valid DNS label — lowercase letters, numbers, hyphens only"; continue; }
            if [[ -n "${chosen[$val]:-}" ]]; then
                warn "'$val' is already taken by ${chosen[$val]} — pick another"
                continue
            fi
            break
        done
        chosen[$val]="${var%_HOST}"
        env_set "$var" "$val"
    done 3< <(traefik_host_vars)
    traefik_gen   # the dashboard hostname lives in the generated config
    info "Apply with: ./mediastack.sh up"
    info "(services whose name changed are recreated; renaming a VPN'd service recreates gluetun — a brief tunnel bounce)"
}

cmd_traefik_certs() {
    [[ -t 0 ]] || die "traefik-setup --certs needs a terminal."
    local cur acmef stored="(none issued yet)"
    cur=$(env_get ACME_ENV production)
    acmef="$(env_get CONFIG_ROOT)/traefik/acme/acme.json"
    if sudo test -s "$acmef" 2>/dev/null; then
        sudo grep -q "acme-staging" "$acmef" && stored=staging || stored=production
    fi
    hr "Certificate environment"
    info "Setting: $cur — certificates in the store: $stored"
    explain "Real or testing certificates?" \
"  production  real certificates, trusted by every browser. Let's
              Encrypt allows only 5 identical ones per week, so
              repeated install testing can lock you out for days.
  staging     unlimited test certificates. Browsers show a warning
              you can click through — everything else works the same.
Switching either way is safe: the stack resets the certificate store,
restarts traefik, and the new environment reissues automatically."
    ask AV "Certificate environment [production/staging]" "$cur"
    case "$REPLY_VAL" in production|staging) env_set ACME_ENV "$REPLY_VAL" ;; *) die "Expected 'production' or 'staging'." ;; esac
    traefik_gen
}

cmd_traefik_setup() {
    svc_enabled traefik || die "traefik is not enabled. Enable it first: ./mediastack.sh enable traefik"
    if [[ "${1:-}" == --hosts ]]; then cmd_traefik_hosts; return; fi
    if [[ "${1:-}" == --certs ]]; then cmd_traefik_certs; return; fi
    traefik_ensure --reconfigure
    info "Apply with: ./mediastack.sh up   (recreates traefik if config changed)"
    info "Rename service addresses any time: ./mediastack.sh traefik-setup --hosts"
}
