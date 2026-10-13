#!/usr/bin/env bash
# safety-live.sh — the safety rules, checked on a RUNNING stack (not CI).
# Read-only: it changes nothing. Run it on the box, from the repo:
#   scripts/safety-live.sh
# before and after each re-org slice, and after any change to the edge, the
# portal or the VPN. Exit 0 = every check passed.
#
#   vpn      leak-test (attachment, tunnel IP, no IPv6, interfaces), and every
#            enabled torrent client bound to tun0
#   gate     with the portal on: each gated tool, signed out, is sent to sign
#            in; its API path (a gate bypass) is answered by the app instead;
#            the dashboard always asks for a login
#   ports    with the portal on: no gated tool listens beyond 127.0.0.1, and
#            its port refuses a connection on this box's LAN address
#   certs    the certificate's issuer matches ACME_ENV, and it is not due to
#            expire within 14 days
#   ldap     the LDAP route answers here (the stack's side of the allow-list),
#            then prints the probe to run from another LAN machine, which
#            must get NO answer (the host itself reaches Traefik through
#            Docker's gateway, inside the allow-list — only a LAN machine can
#            prove the refusal)
#
# Every request goes to this box (curl --resolve to 127.0.0.1), so DNS is not
# part of the test. Needs: sudo docker, curl, jq, openssl, ip.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
repo=$PWD

lib=$(mktemp "$repo/.safety-live.XXXXXX")
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"; rm -f "$lib"
[[ -f "$ENV_FILE" ]] || { echo "ERROR no .env — this checks an installed stack" >&2; exit 2; }
[[ "$(env_get ENV_SCHEMA 0)" == "$SCRIPT_SCHEMA" ]] \
    || { echo "ERROR .env schema $(env_get ENV_SCHEMA 0) != script $SCRIPT_SCHEMA — run ./mediastack.sh up first (this check changes nothing)" >&2; exit 2; }
env_validate

fails=0 passes=0
pass() { echo "PASS $*"; passes=$((passes + 1)); }
flunk() { echo "FAIL $*"; fails=$((fails + 1)); }
note() { echo "  .. $*"; }

domain=$(env_get TRAEFIK_DOMAIN)
portal=0; svc_enabled authentik && portal=1
edge=0; svc_enabled traefik && [[ -n "$domain" ]] && edge=1
RENDERED_JSON=""; render

https() { # https HOST PATH -> "code redirect_url" from this box's Traefik
    curl -sk --max-time 10 --resolve "$1:443:127.0.0.1" -o /dev/null \
        -w '%{http_code} %{redirect_url}' "https://$1$2" 2>/dev/null || echo "000 "
}
host_of() { # host_of SVC -> its https name
    echo "$(env_get "$(uvar "$1")_HOST" "$(svc_label "$1" mediastack.subdomain)").$domain"
}
gated_enabled() { # the enabled services the portal guards
    local s
    for s in $(jq -r '.services | to_entries[] | select(.value.labels["mediastack.auth"] == "gate") | .key' <<<"$RENDERED_JSON"); do
        svc_enabled "$s" && echo "$s"
    done
    return 0
}

echo "== vpn"
if svc_enabled gluetun; then
    if "$repo/mediastack.sh" leak-test >"$repo/.safety-live.leak" 2>&1; then pass "leak-test"
    else flunk "leak-test (its output:)"; sed 's/^/     /' "$repo/.safety-live.leak"; fi
    rm -f "$repo/.safety-live.leak"
    for s in qbittorrent deluge; do
        svc_enabled "$s" || continue
        out=$("${s}_doctor_tun0" 2>&1 || true)
        if [[ "$out" == *"bound to tun0"* && "$out" != *"NOT bound"* ]]; then pass "$s transfers bound to tun0"
        else flunk "$s tun0 bind: $(tr '\n' ' ' <<<"$out")"; fi
    done
else
    note "gluetun not enabled — skipped"
fi

echo "== gate"
if (( portal && edge )); then
    for s in $(gated_enabled); do
        h=$(host_of "$s"); read -r code to <<<"$(https "$h" /)"
        if [[ "$code" == 302 && ( "$to" == *outpost.goauthentik.io* || "$to" == *"$(env_get AUTHENTIK_HOST portal).$domain"* ) ]]; then
            pass "$s: signed out, sent to sign in"
        else flunk "$s: https://$h/ answered $code ${to:-(no redirect)} — want 302 to the portal's sign-in"; fi
        for p in $(svc_label "$s" mediastack.auth.bypass); do
            read -r code to <<<"$(https "$h" "$p")"
            if [[ "$code" != 000 && "$code" != 302 ]]; then pass "$s: $p answered by the app ($code), past the gate"
            else flunk "$s: https://$h$p answered $code ${to:-} — its gate bypass is not reaching the app"; fi
        done
    done
fi
if (( edge )); then
    dh="$(env_get TRAEFIK_DASH_HOST dash).$domain"; read -r code to <<<"$(https "$dh" /)"
    want=401; (( portal )) && want=302
    if [[ "$code" == "$want" ]]; then pass "dashboard: asks for a login ($code)"
    else flunk "dashboard answered $code ${to:-} — want $want ($( (( portal )) && echo "the gate" || echo "its basic auth"))"; fi
else
    note "no Traefik edge — skipped"
fi

echo "== ports"
if (( portal )); then
    lanip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i+1)}')
    [[ -n "$lanip" ]] || flunk "could not find this box's LAN address (ip route get)"
    for s in $(gated_enabled); do
        if svc_bound_local "$s"; then pass "$s: published on 127.0.0.1 only"
        else flunk "$s: its port is published beyond 127.0.0.1"; fi
        [[ -n "$lanip" ]] || continue
        hp=$(env_get "$(uvar "$s")_PORT" "$(svc_cport "$s")")
        if curl -s --max-time 3 -o /dev/null "http://$lanip:$hp/" 2>/dev/null; then flunk "$s: $lanip:$hp answered — open to the LAN"
        else pass "$s: $lanip:$hp refuses"; fi
    done
else
    note "no portal: gated tools keep their own logins and LAN ports — skipped"
fi

echo "== certs"
if (( edge )); then
    cert=$(openssl s_client -connect 127.0.0.1:443 -servername "$(env_get TRAEFIK_DASH_HOST dash).$domain" </dev/null 2>/dev/null | openssl x509 2>/dev/null || true)
    if [[ -z "$cert" ]]; then flunk "no certificate served on :443"
    else
        issuer=$(openssl x509 -noout -issuer <<<"$cert")
        staging=0; [[ "$issuer" == *STAGING* ]] && staging=1
        want=$(env_get ACME_ENV production)
        match=0
        if [[ "$want" == staging ]]; then (( staging )) && match=1; else (( staging )) || match=1; fi
        if (( match )); then pass "issuer matches ACME_ENV=$want (${issuer#issuer=})"
        else flunk "ACME_ENV=$want but the served certificate is from ${issuer#issuer=}"; fi
        if openssl x509 -noout -checkend $((14 * 86400)) <<<"$cert" >/dev/null; then pass "certificate valid for 14+ days ($(openssl x509 -noout -enddate <<<"$cert" | cut -d= -f2))"
        else flunk "certificate expires within 14 days ($(openssl x509 -noout -enddate <<<"$cert" | cut -d= -f2))"; fi
    fi
else
    note "no Traefik edge — skipped"
fi

echo "== ldap"
if (( portal && edge )); then
    # an anonymous LDAP bind request; any LDAP server answers it with a bind response (0x30 ... 0x61)
    bind='\x30\x0c\x02\x01\x01\x60\x07\x02\x01\x03\x04\x00\x80\x00'
    lh="ldap.$domain"
    # shellcheck disable=SC2059  # the bytes are the format
    ans=$(printf "$bind" | timeout 6 openssl s_client -quiet -connect 127.0.0.1:443 -servername "$lh" 2>/dev/null | od -An -tx1 | tr -s ' \n' ' ' || true)
    if [[ "$ans" == " 30 "*" 61 "* ]]; then pass "LDAP answers on the stack's side (the probe works)"
    else flunk "no LDAP answer from this box (got '${ans:-nothing}') — the LAN probe below would prove nothing"; fi
    lanip=${lanip:-$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i+1)}')}
    echo "  >> now from ANOTHER LAN machine (Git Bash works) — it must print NOTHING:"
    echo "     printf '$bind' | timeout 6 openssl s_client -quiet -connect $lanip:443 -servername $lh 2>/dev/null | od -An -tx1"
else
    note "no portal — no LDAP route"
fi

echo
(( ! fails )) || { echo "safety-live: $fails FAILED, $passes passed"; exit 1; }
echo "OK safety-live: $passes passed (run the LAN probe above too)"
