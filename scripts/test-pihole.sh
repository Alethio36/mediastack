#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-pihole.sh — Pi-hole's own password behind the portal
# (services/pihole/pihole.sh, docs/design-logins.md):
#   * gate_planned: the portal guards it as .env stands (read before `up`);
#     GATE_UNTRUSTED (disable authentik) says no
#   * pihole_gate_sync: PIHOLE_WEB_PASSWORD empty while guarded, absent
#     otherwise; nothing written when it already matches
#   * gate_bind_sync runs every <svc>_gate_sync, its bind changed or not
#   * pihole_gate_login: recreated with its password, then proven to ask for it
#   * set-credentials pihole while guarded: stored, nothing recreated
#   * the compose line: absent means its own password, never none
# Sources the real entrypoint (minus its last line, main "$@"); compose and
# curl are stubs.
#
#   scripts/test-pihole.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-pihole.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

ENV_FILE=$T/.env
AK=yes AUTH=gate
svc_enabled() { case $1 in authentik) [[ $AK == yes ]] ;; pihole) return 0 ;; *) return 1 ;; esac; }
svc_label()   { [[ $2 == mediastack.auth ]] && echo "$AUTH"; return 0; }
info() { echo ":: $*"; }; ok() { echo "OK $*"; }; wfail() { WIRE_FAILS=$((WIRE_FAILS + 1)); echo "FAIL $*"; }
sleep() { :; }

# ---- gate_planned: from .env, before `up` ----
printf 'MEDIASTACK_GATE_BIND=127.0.0.1:\n' > "$ENV_FILE"
gate_planned pihole || fail_ "portal + gated + its port to be local: guarded"; pass
! GATE_UNTRUSTED=1 gate_planned pihole || fail_ "GATE_UNTRUSTED (disable authentik): no"; pass
AK=no; ! gate_planned pihole || fail_ "no portal: not guarded"; pass; AK=yes
AUTH=native; ! gate_planned pihole || fail_ "not gated: not guarded"; pass; AUTH=gate
printf 'MEDIASTACK_GATE_BIND=\n' > "$ENV_FILE"; ! gate_planned pihole || fail_ "its port open to the LAN: not guarded"; pass

# ---- pihole_gate_sync: empty while guarded, absent otherwise ----
printf 'MEDIASTACK_GATE_BIND=127.0.0.1:\nPIHOLE_PASSWORD=pw\n' > "$ENV_FILE"
o=$(pihole_gate_sync); grep -qx 'PIHOLE_WEB_PASSWORD=' "$ENV_FILE" && grep -q 'no password of its own from its next start' <<<"$o" \
    || fail_ "guarded: set empty, said so: $o $(cat "$ENV_FILE")"; pass
cp "$ENV_FILE" "$T/before"; o=$(pihole_gate_sync); cmp -s "$ENV_FILE" "$T/before" && [[ -z "$o" ]] || fail_ "guarded, set already: nothing written, nothing said: $o"; pass
AK=no; o=$(pihole_gate_sync); ! grep -q '^PIHOLE_WEB_PASSWORD=' "$ENV_FILE" && grep -q 'its own password again from its next start' <<<"$o" \
    || fail_ "not guarded: the key gone (its own password applies), said so: $o $(cat "$ENV_FILE")"; pass
cp "$ENV_FILE" "$T/before"; o=$(pihole_gate_sync); cmp -s "$ENV_FILE" "$T/before" && [[ -z "$o" ]] || fail_ "not guarded, absent already: nothing written: $o"; pass
grep -qx 'PIHOLE_PASSWORD=pw' "$ENV_FILE" || fail_ "its own password is never touched"; pass
AK=yes

# ---- gate_bind_sync runs every <svc>_gate_sync, its bind changed or not ----
printf 'MEDIASTACK_GATE_BIND=127.0.0.1:\nMEDIASTACK_GATE_TRUST=172.31.250.2/32\nTRAEFIK_ADDRESS=172.31.250.2\n' > "$ENV_FILE"
o=$( svc_enabled_managed() { printf '%s\n' pihole sonarr; }; pihole_gate_sync() { echo HOOK-pihole; }; gate_bind_sync )
[[ "$o" == HOOK-pihole ]] || fail_ "the bind unchanged: the hook still runs: $o"; pass

# ---- pihole_gate_login: recreated with its password, proven ----
gl() { # gl VALID(true|false|none) DCRC -> "fails=N" ($T/gl: its output, $T/dc: compose calls)
    ( WIRE_FAILS=0; VALID=$1 DCRC=$2; rm -f "$T/dc"
      printf 'MEDIASTACK_GATE_BIND=127.0.0.1:\nPIHOLE_WEB_PASSWORD=\n' > "$ENV_FILE"
      DC() { echo "DC $* web=$(grep -c '^PIHOLE_WEB_PASSWORD=' "$ENV_FILE")" >> "$T/dc"; return "$DCRC"; }
      svc_hostport() { echo 8083; }
      scurl() { [[ "${*: -1}" == http://127.0.0.1:8083/api/auth ]] || return 7; [[ $VALID == none ]] && return 7
               printf '{"session":{"valid":%s,"totp":false,"sid":null,"validity":-1}}' "$VALID"; }
      GATE_UNTRUSTED=1 pihole_gate_login > "$T/gl" 2>&1; echo "fails=$WIRE_FAILS" )
}
[[ "$(gl false 0)" == "fails=0" ]] && grep -q 'OK pihole: asks for its password again' "$T/gl" && [[ "$(cat "$T/dc")" == "DC up -d pihole web=0" ]] \
    || fail_ "disable: the key gone before its recreate, then proven to ask: $(cat "$T/gl") $(cat "$T/dc")"; pass
[[ "$(gl true 0)" == "fails=1" ]] && grep -q 'still opens without a password' "$T/gl" || fail_ "still open after its recreate: a failure: $(cat "$T/gl")"; pass
[[ "$(gl false 1)" == "fails=1" ]] && grep -q 'could not recreate it' "$T/gl" || fail_ "its recreate refused: a failure: $(cat "$T/gl")"; pass
[[ "$(gl none 0)" == "fails=1" ]] && grep -q 'did not answer within' "$T/gl" || fail_ "its API silent: bounded, then a failure: $(cat "$T/gl")"; pass

# ---- set-credentials pihole while guarded: stored, nothing recreated ----
printf 'MEDIASTACK_GATE_BIND=127.0.0.1:\nPIHOLE_PASSWORD=old\n' > "$ENV_FILE"; rm -f "$T/dc"
o=$( DC() { echo "DC $*" >> "$T/dc"; }; sc_rotate_pihole newpass )
grep -qx 'PIHOLE_PASSWORD=newpass' "$ENV_FILE" && [[ ! -f "$T/dc" ]] && grep -q 'asks none while the portal guards it' <<<"$o" \
    || fail_ "guarded: the password stored for when the portal goes, no recreate: $o"; pass
AK=no; rm -f "$T/dc"; o=$( DC() { echo "DC $*" >> "$T/dc"; }; sc_rotate_pihole newer )
grep -q 'DC up -d pihole' "$T/dc" || fail_ "not guarded: recreated to apply it: $o"; pass; AK=yes

# ---- the compose line: absent means its own password, never none ----
grep -qF -- '- FTLCONF_webserver_api_password=${PIHOLE_WEB_PASSWORD-${PIHOLE_PASSWORD}}' services/pihole/compose.yml \
    || fail_ "compose: PIHOLE_WEB_PASSWORD with '-' (set empty: none; absent: PIHOLE_PASSWORD) — never ':-'"; pass

# ---- through the portal: its name answered, / sent to /admin/ by Traefik (found live 18 Nov 2026) ----
grep -qF -- '- FTLCONF_webserver_domain=${PIHOLE_HOST:-pihole}.${STACK_DOMAIN:-unset.invalid}' services/pihole/compose.yml \
    && grep -qF 'traefik.http.routers.pihole.rule: "Host(`${PIHOLE_HOST:-pihole}.${STACK_DOMAIN:-unset.invalid}`)"' services/pihole/compose.yml \
    || fail_ "compose: Pi-hole's webserver.domain is its route's own name (it refuses any other Host)"; pass
grep -qF 'traefik.http.routers.pihole.middlewares: "mediastack-gate@file,pihole-admin"' services/pihole/compose.yml \
    && grep -qF 'redirectregex.replacement: "$${1}/admin/"' services/pihole/compose.yml \
    || fail_ "compose: the gate first, then Traefik's / to /admin/ (Pi-hole's own names its container's address)"; pass

echo "OK pihole: $checks checks"
