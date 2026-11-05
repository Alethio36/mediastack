#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-certs.sh — a certificate of your own (services/traefik/certs.sh,
# docs/certificates.md), with a real root, intermediate and leaf made here:
#   * a pair is accepted only when it can serve the domain: readable, PEM, the
#     key unencrypted and the certificate's own, covering the domain and its
#     wildcard, more than 7 days left, chaining to a public CA (the bundle)
#   * Traefik's config: no Let's Encrypt resolver, the pair as its default
#     certificate; Let's Encrypt's is unchanged (test-snapshot holds it)
#   * trusted like a production certificate (Kavita and Jellyfin check it);
#     staging is not
#   * up copies a changed pair in (mode 600) and refuses one that cannot serve;
#     doctor warns 30 days ahead and fails a pair that cannot serve
#   * configure: the choice, the two paths, a certificate for another domain
#     sends the domain question back
#
#   scripts/test-certs.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
lib=$(mktemp .test-certs.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"
set +e +E; trap - ERR

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; [[ -f "$T/out" ]] && { echo "--- output:" >&2; cat "$T/out" >&2; }; exit 1; }

# ---- a root, an intermediate, and leaves under them ----
c=$T/ca; mkdir -p "$c"
q() { "$@" >/dev/null 2>&1 || fail_ "openssl: $*"; }
q openssl req -x509 -newkey rsa:2048 -nodes -keyout "$c/root.key" -out "$c/root.pem" -days 60 -subj /CN=TestRoot
q openssl req -newkey rsa:2048 -nodes -keyout "$c/int.key" -out "$c/int.csr" -subj /CN=TestIntermediate
printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n' > "$c/int.ext"
q openssl x509 -req -in "$c/int.csr" -CA "$c/root.pem" -CAkey "$c/root.key" -CAcreateserial -out "$c/int.pem" -days 60 -extfile "$c/int.ext"
leaf() { # leaf NAME DAYS SANS — a leaf signed by the intermediate, its fullchain and key
    q openssl req -newkey rsa:2048 -nodes -keyout "$c/$1.key" -out "$c/$1.csr" -subj "/CN=x" -addext "subjectAltName=$3"
    q openssl x509 -req -in "$c/$1.csr" -CA "$c/int.pem" -CAkey "$c/int.key" -CAcreateserial -out "$c/$1.pem" -days "$2" -copy_extensions copy
    cat "$c/$1.pem" "$c/int.pem" > "$c/$1.full"
}
leaf good 90 'DNS:media.example.com,DNS:*.media.example.com'
leaf nowild 90 'DNS:media.example.com'
leaf soon 3 'DNS:media.example.com,DNS:*.media.example.com'
leaf month 20 'DNS:media.example.com,DNS:*.media.example.com'
q openssl pkey -in "$c/good.key" -aes256 -passout pass:x -out "$c/enc.key"
TLS_CA_BUNDLE=$c/root.pem   # "the public CAs": the test's root
D=media.example.com
p() { own_cert_problem "$@"; }

# ---- what a pair must be ----
[[ -z "$(p "$c/good.full" "$c/good.key" $D)" ]] || fail_ "a good pair: $(p "$c/good.full" "$c/good.key" $D)"; pass
[[ "$(p "$c/none" "$c/good.key" $D)" == *"cannot be read"* ]] || fail_ "a missing file"; pass
[[ "$(p "$c/good.key" "$c/good.key" $D)" == *"is not a PEM certificate"* ]] || fail_ "a key where the certificate goes"; pass
[[ "$(p "$c/good.full" "$c/enc.key" $D)" == *"is not an unencrypted PEM private key"* ]] || fail_ "an encrypted key: Traefik cannot ask for its passphrase"; pass
[[ "$(p "$c/good.full" "$c/soon.key" $D)" == *"the key does not belong to the certificate"* ]] || fail_ "another certificate's key"; pass
[[ "$(p "$c/nowild.full" "$c/nowild.key" $D)" == *"does not cover *.media.example.com"* ]] || fail_ "no wildcard: every service has its own name"; pass
[[ "$(p "$c/good.full" "$c/good.key" other.example.com)" == *"does not cover other.example.com"* ]] || fail_ "another domain"; pass
[[ "$(p "$c/soon.full" "$c/soon.key" $D)" == *"expires within 7 days"* ]] || fail_ "3 days left: refused"; pass
[[ "$(p "$c/good.pem" "$c/good.key" $D)" == *"does not chain to a public CA"* ]] || fail_ "the leaf alone, no chain in the file"; pass
[[ "$(TLS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt p "$c/good.full" "$c/good.key" $D)" == *"does not chain to a public CA"* ]] \
    || fail_ "a private CA: the apps would refuse it"; pass
[[ "$(own_cert_days_left "$c/month.full")" =~ ^(19|20)$ ]] || fail_ "days left: $(own_cert_days_left "$c/month.full")"; pass

# ---- trusted like production; Traefik's config follows the source ----
ENV_FILE=$T/.env
printf 'TLS_SOURCE=own\n' > "$ENV_FILE"; certs_trusted || fail_ "own: trusted (it chains to a public CA)"; pass
printf 'ACME_ENV=staging\n' > "$ENV_FILE"; certs_trusted && fail_ "staging: not trusted"; pass
printf 'ACME_ENV=production\n' > "$ENV_FILE"; certs_trusted || fail_ "production: trusted"; pass
printf 'TLS_SOURCE=own\nSTACK_DOMAIN=%s\n' "$D" > "$ENV_FILE"
[[ "$(traefik_missing)" == TLS_CERT_FILE ]] || fail_ "own: the files are what is missing, not a Cloudflare token: $(traefik_missing)"; pass
sudo() { "$@"; }   # as this user, on the test's folders
printf 'TLS_SOURCE=own\nSTACK_DOMAIN=%s\nCONFIG_ROOT=%s/cfg\nTLS_CERT_FILE=%s\nTLS_KEY_FILE=%s\nTRAEFIK_DASH_USER=admin\nTRAEFIK_DASH_PASSWORD=pw\nMEDIASTACK_SUBNET=172.31.250.0/24\n' \
    "$D" "$T" "$c/good.full" "$c/good.key" > "$ENV_FILE"
( signin_is() { false; }; svc_cname() { echo x; }; docker() { :; }; traefik_gen ) > "$T/out" 2>&1 || fail_ "traefik_gen, own"
! grep -q certificatesResolvers "$T/cfg/traefik/traefik.yml" && grep -q 'certFile: /certs/fullchain.pem' "$T/cfg/traefik/dynamic/00-mediastack.yml" \
    && grep -q '^      tls: {}' "$T/cfg/traefik/dynamic/00-mediastack.yml" && ! grep -q certResolver "$T/cfg/traefik/dynamic/00-mediastack.yml" \
    || fail_ "own: no Let's Encrypt resolver, the pair as the default certificate"; pass
grep -q "your own certificate (until" "$T/out" || fail_ "the config line names the certificate: $(cat "$T/out")"; pass

# ---- up: copied in when changed, refused when it cannot serve ----
own_cert_install > "$T/out" 2>&1 || fail_ "install a good pair"
cmp -s "$c/good.full" "$T/cfg/traefik/certs/fullchain.pem" && [[ "$(stat -c %a "$T/cfg/traefik/certs/privkey.pem")" == 600 ]] \
    && grep -q 'your certificate is in place' "$T/out" || fail_ "copied in, the key 600"; pass
own_cert_install > "$T/out" 2>&1; [[ ! -s "$T/out" ]] || fail_ "unchanged: nothing copied, nothing said"; pass
sed -i "s|^TLS_CERT_FILE=.*|TLS_CERT_FILE=$c/nowild.full|; s|^TLS_KEY_FILE=.*|TLS_KEY_FILE=$c/nowild.key|" "$ENV_FILE"
( own_cert_install ) > "$T/out" 2>&1 && fail_ "a pair that cannot serve is refused"
grep -q 'your certificate cannot be served: the certificate does not cover' "$T/out" && cmp -s "$c/good.full" "$T/cfg/traefik/certs/fullchain.pem" \
    || fail_ "said, and the served copy left as it was"; pass

# ---- doctor: 30 days ahead it warns; a pair that cannot serve fails ----
dr() { ( d_fail() { echo "DFAIL $1"; }; warn() { echo "WARN $*"; }; ok() { echo "OK $*"; }; svc_enabled() { [[ "$1" == traefik ]]; }; traefik_doctor ) 2>&1; }
sed -i "s|^TLS_CERT_FILE=.*|TLS_CERT_FILE=$c/month.full|; s|^TLS_KEY_FILE=.*|TLS_KEY_FILE=$c/month.key|" "$ENV_FILE"
[[ "$(dr)" == *"WARN your certificate expires in "*" days"*"renewal is yours"* ]] || fail_ "20 days left: a warning with the way to renew: $(dr)"; pass
[[ "$(dr)" == *"older copy than your certificate file"* ]] || fail_ "a file newer than the served copy is named: $(dr)"; pass
sed -i "s|^TLS_CERT_FILE=.*|TLS_CERT_FILE=$c/soon.full|; s|^TLS_KEY_FILE=.*|TLS_KEY_FILE=$c/soon.key|" "$ENV_FILE"
[[ "$(dr)" == *"DFAIL your certificate cannot be served: the certificate expires within 7 days"* ]] || fail_ "3 days left: a failure: $(dr)"; pass

# ---- configure: the choice, the paths; another domain's certificate sends the domain back ----
printf 'COMPOSE_PROFILES=traefik\n' > "$ENV_FILE"; rm -rf "$T/cfg"
printf '2\nother.example.com\n%s\n%s\nmedia.example.com\n\n\n' "$c/good.full" "$c/good.key" \
    | ( Q_MODE=full; traefik_questions ) > "$T/out" 2>&1 || fail_ "configure, own certificate"
grep -q 'does not cover other.example.com' "$T/out" && [[ "$(env_get STACK_DOMAIN)/$(env_get TLS_SOURCE)/$(env_get TLS_CERT_FILE)" == "$D/own/$c/good.full" ]] \
    || fail_ "the domain asked again, the paths kept: $(grep -E '^(STACK_DOMAIN|TLS_)' "$ENV_FILE" | paste -sd' ')"; pass
! grep -qE 'Paste the Cloudflare token|Email for certificate-expiry' "$T/out" || fail_ "own: no Cloudflare token or Let's Encrypt email asked"; pass
[[ ! -e "$T/cfg" ]] || fail_ "the questions copy nothing: up does"; pass

echo "OK certs: $checks checks"
