#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-cleanuparr.sh — Cleanuparr's sign-in through the portal
# (services/cleanuparr/cleanuparr.sh, docs/design-logins.md):
#   * cup_oidc: our settings written with the secret, read back, never
#     exclusive; a rotated secret noticed by its digest; another provider's
#     never touched; proven by its button leading to the portal
#   * cup_oidc_off (no portal, or disable authentik): our button and exclusive
#     mode off, the masked secret sent back as it came; another's untouched
#   * cleanuparr_gate_login: needs its API key
#   * ak_signin_rule: its sign-in admits whoever its card does
#   * the blueprint, authentik's compose and secrets, wire's order
# Sources the real entrypoint (minus its last line, main "$@"); Cleanuparr's
# and authentik's APIs are stubs.
#
#   scripts/test-cleanuparr.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-cleanuparr.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

ENV_FILE=$T/.env
AK=yes
svc_enabled()   { [[ $1 == cleanuparr ]]; }
signin_is()     { [[ $1 == authentik && $AK == yes ]]; }
svc_subdomain() { echo portal; }
svc_url()       { echo "https://cleanup.media.example.com"; }
state_get() { cat "$T/state-$1" 2>/dev/null || true; }; state_set() { printf '%s\n' "$2" > "$T/state-$1"; }
info() { echo ":: $*"; }; ok() { echo "OK $*"; }; warn() { echo "WARN $*"; }; wfail() { WIRE_FAILS=$((WIRE_FAILS + 1)); echo "FAIL $*"; }
MASK='••••••••'
ISSUER=https://portal.media.example.com/application/o/mediastack-signin-cleanuparr/

# Cleanuparr's OIDC settings in $T/oidc (its secret shown masked); KEEP=no: it answers 200 and keeps nothing; START: its button's answer
KEEP=yes START=ok CODE=200
cup_code() { echo "$CODE"; }
cup_api() {
    echo "$1 $2" >> "$T/calls"
    case "$1 $2" in
        "GET /account/oidc") CODE=200; cat "$T/oidc" ;;
        "PUT /account/oidc") CODE=200; echo "$4" > "$T/put"
            [[ $KEEP == yes ]] && jq -c --arg m "$MASK" '.clientSecret = $m' <<<"$4" > "$T/oidc"
            echo '{"message":"OIDC configuration updated"}' ;;
        "POST /auth/oidc/start")
            if [[ $START == ok ]]; then CODE=200; echo '{"authorizationUrl":"https://portal.media.example.com/application/o/authorize/?client_id=mediastack-cleanuparr"}'
            else CODE=503; echo '{"title":"OIDC provider unreachable"}'; return 1; fi ;;
        *) CODE=404; return 1 ;;
    esac
}
fresh() { jq -cn '{enabled:false, issuerUrl:"", clientId:"", clientSecret:"", scopes:"openid profile email", authorizedSubject:"", providerName:"OIDC", redirectUrl:"", exclusiveMode:false}' > "$T/oidc"; }
run() { # run [VAR=value...] -> "fails=N" ($T/out: its output, $T/calls: Cleanuparr's)
    ( WIRE_FAILS=0; rm -f "$T/calls" "$T/put"; for a in "$@"; do export "${a?}"; done
      cup_oidc "X-Api-Key: K" > "$T/out" 2>&1; echo "fails=$WIRE_FAILS" )
}
printf 'STACK_DOMAIN=media.example.com\nPORTAL_TITLE=Home\nAUTHENTIK_CLEANUPARR_CLIENT_SECRET=CSEC\n' > "$ENV_FILE"

# ---- cup_oidc: the portal's button ----
fresh; rm -f "$T"/state-*
[[ "$(run)" == fails=0 ]] || fail_ "fresh: no failure: $(cat "$T/out")"; pass
[[ "$(jq -c '[.enabled, .issuerUrl, .clientId, .clientSecret, .scopes, .providerName, .redirectUrl, .exclusiveMode]' "$T/put")" \
    == "[true,\"$ISSUER\",\"mediastack-cleanuparr\",\"CSEC\",\"openid profile email\",\"Home\",\"https://cleanup.media.example.com\",false]" ]] \
    || fail_ "written: its own issuer, our client and secret, the portal's name, its https address, never exclusive: $(cat "$T/put")"; pass
grep -q 'OK cleanuparr: sign-in through the portal set up' "$T/out" && [[ "$(tail -1 "$T/calls")" == "POST /auth/oidc/start" ]] \
    || fail_ "set up, then proven by its button: $(cat "$T/out") $(cat "$T/calls")"; pass
[[ "$(run)" == fails=0 ]] && [[ ! -f "$T/put" ]] && grep -q 'OK cleanuparr: sign-in through the portal$' "$T/out" \
    || fail_ "already right: nothing written: $(cat "$T/out")"; pass
sed -i 's/=CSEC$/=ROTATED/' "$ENV_FILE"
[[ "$(run)" == fails=0 ]] && [[ "$(jq -r '.clientSecret' "$T/put" 2>/dev/null)" == ROTATED ]] \
    || fail_ "a rotated secret (read back masked) is noticed by its digest and written: $(cat "$T/out")"; pass
[[ "$(run WIRE_DRY=1)" == fails=0 ]] && [[ ! -f "$T/put" ]] || fail_ "dry run, nothing to do: nothing written"; pass
fresh; rm -f "$T"/state-*
[[ "$(run WIRE_DRY=1)" == fails=0 ]] && [[ ! -f "$T/put" ]] && grep -q 'would: cleanuparr: sign in through the portal' "$T/out" \
    || fail_ "dry run, fresh: said, not written: $(cat "$T/out")"; pass
fresh
[[ "$(run KEEP=no)" == fails=1 ]] && grep -q 'did not keep its sign-in settings' "$T/out" && [[ ! -s "$T/state-CLEANUPARR_OIDC_SECRET" ]] \
    || fail_ "answered 200 but kept nothing: a failure, its secret not marked applied: $(cat "$T/out")"; pass
fresh
[[ "$(run START=no)" == fails=1 ]] && grep -q 'does not lead to the portal' "$T/out" && grep -q "${ISSUER}.well-known/openid-configuration" "$T/out" \
    || fail_ "its button cannot reach the portal: a failure naming what it reads: $(cat "$T/out")"; pass
jq -c '.enabled = true | .clientId = "my-keycloak" | .providerName = "Keycloak" | .issuerUrl = "https://kc.example.com/"' "$T/oidc" > "$T/o2"; mv "$T/o2" "$T/oidc"
[[ "$(run)" == fails=0 ]] && [[ ! -f "$T/put" ]] && grep -q 'a provider you set up (Keycloak) — untouched' "$T/out" \
    && ! grep -q 'oidc/start' "$T/calls" || fail_ "another provider: untouched: $(cat "$T/out")"; pass

# ---- cup_oidc_off: no portal, or disable authentik ----
ours_on() { jq -cn --arg i "$ISSUER" --arg m "$MASK" --argjson x "${1:-false}" '{enabled:true, issuerUrl:$i, clientId:"mediastack-cleanuparr", clientSecret:$m, scopes:"openid profile email", authorizedSubject:"", providerName:"Home", redirectUrl:"https://cleanup.media.example.com", exclusiveMode:$x}' > "$T/oidc"; }
ours_on
[[ "$(run AK=no)" == fails=0 ]] && [[ "$(jq -c '[.enabled, .exclusiveMode, .clientId, .clientSecret, .issuerUrl]' "$T/put")" == "[false,false,\"mediastack-cleanuparr\",\"$MASK\",\"$ISSUER\"]" ]] \
    && grep -q 'OK cleanuparr: no portal button' "$T/out" && ! grep -q 'oidc/start' "$T/calls" \
    || fail_ "no portal: off, the rest (the masked secret too) sent back as it came: $(cat "$T/out") $(cat "$T/put" 2>/dev/null)"; pass
ours_on
[[ "$(run GATE_UNTRUSTED=1)" == fails=0 ]] && [[ "$(jq -r '.enabled' "$T/put")" == false ]] || fail_ "disable authentik (portal still up): off"; pass
ours_on true
[[ "$(run AK=no)" == fails=0 ]] && [[ "$(jq -c '[.enabled, .exclusiveMode]' "$T/put")" == "[false,false]" ]] || fail_ "exclusive mode goes with it (no portal: nobody could sign in)"; pass
ours_on; jq -c '.enabled = false' "$T/oidc" > "$T/o2"; mv "$T/o2" "$T/oidc"
[[ "$(run AK=no)" == fails=0 ]] && [[ ! -f "$T/put" ]] && [[ ! -s "$T/out" ]] || fail_ "ours, already off: nothing written, nothing said: $(cat "$T/out")"; pass
jq -c '.clientId = "my-keycloak"' "$T/oidc" > "$T/o2"; jq -c '.enabled = true' "$T/o2" > "$T/oidc"
[[ "$(run AK=no)" == fails=0 ]] && [[ ! -f "$T/put" ]] || fail_ "another provider's, no portal: untouched"; pass
ours_on
[[ "$(run AK=no KEEP=no)" == fails=1 ]] && grep -q 'still shows its portal button' "$T/out" || fail_ "off not kept: a failure: $(cat "$T/out")"; pass

# ---- cleanuparr_gate_login ----
o=$( WIRE_FAILS=0; GATE_UNTRUSTED=1 cleanuparr_gate_login 2>&1; echo "fails=$WIRE_FAILS" )
[[ "$o" == *"no API key in .env"*"fails=1" ]] || fail_ "no API key: a failure, nothing guessed: $o"; pass
o=$( WIRE_FAILS=0; printf 'CLEANUPARR_API_KEY=K\n' >> "$ENV_FILE"; ours_on; http_ready() { :; }; cup_url() { echo http://x; }
     GATE_UNTRUSTED=1 cleanuparr_gate_login 2>&1; echo "fails=$WIRE_FAILS" )
[[ "$o" == *"OK cleanuparr: no portal button"*"fails=0" ]] || fail_ "disable authentik: its button goes: $o"; pass

# ---- ak_signin_rule: its sign-in admits whoever its card does ----
sr() { # sr ALL TIER -> the binding calls
    ( TIER=$2; svc_tier() { echo "$TIER"; }; ak_app_group() { APP_GROUP=G-app; }
      ak_rule_bind() { echo "BIND $*"; }; ak_card_unbind() { echo "UNBIND $*"; }
      ak_signin_rule "$1" cleanuparr G-adm G-mu )
}
WITH='{"results":[{"slug":"mediastack-app-cleanuparr"},{"slug":"mediastack-signin-cleanuparr"}]}'
[[ -z "$(sr '{"results":[{"slug":"mediastack-app-cleanuparr"}]}' admin)" ]] || fail_ "no sign-in application: nothing"; pass
[[ "$(sr "$WITH" admin)" == $'BIND mediastack-signin-cleanuparr cleanuparr\'s sign-in G-adm G-app\nUNBIND mediastack-signin-cleanuparr G-mu cleanuparr\'s sign-in' ]] \
    || fail_ "admin tier: admin and its own group; the household's binding goes: $(sr "$WITH" admin)"; pass
[[ "$(sr "$WITH" frontend)" == "BIND mediastack-signin-cleanuparr cleanuparr's sign-in G-adm G-mu G-app" ]] \
    || fail_ "household tier: the household too: $(sr "$WITH" frontend)"; pass
grep -q 'for s in $(authentik_gate_apps); do ak_signin_rule "$all" "$s" "$adm" "$mu"; done' services/authentik/authentik.sh \
    || fail_ "wire authentik mirrors every gated tool's sign-in rule"; pass

# ---- the blueprint, authentik's compose and secrets, wire's order ----
bp=services/authentik/blueprints/mediastack-portal.yaml
awk '/id: provider-oidc-cleanuparr/,/^  - model: authentik_core.application/' "$bp" > "$T/prov"
grep -qx '      client_id: mediastack-cleanuparr' "$T/prov" && grep -qF 'client_secret: !Env [MEDIASTACK_CLEANUPARR_CLIENT_SECRET, ""]' "$T/prov" \
    && grep -qF 'url: !Format ["%s/api/auth/oidc/callback", !Env [MEDIASTACK_CLEANUPARR_URL, ""]]' "$T/prov" \
    && grep -qx '      grant_types: \[authorization_code\]' "$T/prov" \
    || fail_ "blueprint: its provider — our client, its secret, its one callback, strict"; pass
awk '/id: app-signin-cleanuparr/,/order: 0/' "$bp" > "$T/app"
grep -qx '      slug: mediastack-signin-cleanuparr' "$T/app" && grep -qx '      meta_launch_url: blank://blank' "$T/app" \
    && grep -qx '      provider: !KeyOf provider-oidc-cleanuparr' "$T/app" && grep -qx '      group: !KeyOf group-admin' "$T/app" \
    || fail_ "blueprint: its sign-in application — on no dashboard, admin bound: $(cat "$T/app")"; pass
grep -qF 'MEDIASTACK_CLEANUPARR_URL: https://${CLEANUPARR_HOST:-cleanup}.${STACK_DOMAIN:-unset.invalid}' services/authentik/compose.yml \
    && grep -qF 'MEDIASTACK_CLEANUPARR_CLIENT_SECRET: ${AUTHENTIK_CLEANUPARR_CLIENT_SECRET}' services/authentik/compose.yml \
    || fail_ "authentik's compose: its address and secret for the blueprint"; pass
grep -q 'AUTHENTIK_KAVITA_CLIENT_SECRET AUTHENTIK_CLEANUPARR_CLIENT_SECRET; do' services/authentik/authentik.sh \
    && grep -q 'AUTHENTIK_CLEANUPARR_CLIENT_SECRET:48' services/authentik/rotate.sh \
    || fail_ "its secret generated like the others, and rotated with authentik's settings"; pass
[[ " ${WIRE_ROLES[*]} " == *" authentik cleanuparr "* ]] || fail_ "wire: authentik before cleanuparr (its button is proven against the portal's setup)"; pass
[[ "$(awk '/^wire_cleanuparr\(\)/,/^}/' services/cleanuparr/cleanuparr.sh | grep -c 'cup_oidc "\$KH"')" == 1 ]] || fail_ "wire cleanuparr sets its sign-in"; pass

echo "OK cleanuparr: $checks checks"
