#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-watchstate.sh — WatchState's own login behind the portal
# (services/watchstate/watchstate.sh, docs/design-logins.md):
#   * watchstate_gate_sync: WATCHSTATE_TRUST_TRAEFIK true while guarded,
#     absent otherwise; nothing written when it already matches
#   * watchstate_gate_login: recreated without the trust, then proven from
#     Traefik's own address; still trusted, silent, or Traefik down: a failure
#   * the compose lines: the trust off unless .env says so, and only ever
#     Traefik's address
# Sources the real entrypoint (minus its last line, main "$@"); compose and
# docker are stubs.
#
#   scripts/test-watchstate.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-watchstate.XXXXXX)
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
svc_enabled() { case $1 in authentik) [[ $AK == yes ]] ;; watchstate) return 0 ;; *) return 1 ;; esac; }
svc_label()   { case $2 in mediastack.auth) echo "$AUTH" ;; mediastack.port) echo 8080 ;; esac; return 0; }
svc_cname()   { echo "mediastack-$1"; }
svc_url()     { echo "https://watch.example.com"; }
info() { echo ":: $*"; }; ok() { echo "OK $*"; }; warn() { echo "WARN $*"; }; wfail() { WIRE_FAILS=$((WIRE_FAILS + 1)); echo "FAIL $*"; }
sleep() { :; }

# ---- watchstate_gate_sync: true while guarded, absent otherwise ----
printf 'MEDIASTACK_GATE_BIND=127.0.0.1:\n' > "$ENV_FILE"
o=$(watchstate_gate_sync); grep -qx 'WATCHSTATE_TRUST_TRAEFIK=true' "$ENV_FILE" && grep -q 'no login of its own for the portal' <<<"$o" \
    || fail_ "guarded: set true, said so: $o $(cat "$ENV_FILE")"; pass
cp "$ENV_FILE" "$T/before"; o=$(watchstate_gate_sync); cmp -s "$ENV_FILE" "$T/before" && [[ -z "$o" ]] || fail_ "guarded, set already: nothing written, nothing said: $o"; pass
o=$(GATE_UNTRUSTED=1 watchstate_gate_sync); ! grep -q '^WATCHSTATE_TRUST_TRAEFIK=' "$ENV_FILE" && grep -q 'its own login again from its next start' <<<"$o" \
    || fail_ "disable authentik (GATE_UNTRUSTED): the key gone, said so: $o $(cat "$ENV_FILE")"; pass
cp "$ENV_FILE" "$T/before"; o=$(AK=no watchstate_gate_sync); cmp -s "$ENV_FILE" "$T/before" && [[ -z "$o" ]] || fail_ "not guarded, absent already: nothing written: $o"; pass
printf 'MEDIASTACK_GATE_BIND=127.0.0.1:\nWATCHSTATE_TRUST_TRAEFIK=false\n' > "$ENV_FILE"
watchstate_gate_sync >/dev/null; grep -qx 'WATCHSTATE_TRUST_TRAEFIK=true' "$ENV_FILE" || fail_ "guarded, a stale false: set true"; pass
AUTH=native; o=$(watchstate_gate_sync); ! grep -q '^WATCHSTATE_TRUST_TRAEFIK=' "$ENV_FILE" || fail_ "moved off the gate: the trust goes: $o"; pass; AUTH=gate

# ---- watchstate_gate_login: its login back, proven from Traefik's address ----
gl() { # gl ANSWER(trusted|asks|none|silent|junk) DCRC TRAEFIK(running|exited) -> "fails=N" ($T/gl: its output, $T/calls)
    ( WIRE_FAILS=0; ANS=$1 DCRC=$2 TS=$3; rm -f "$T/calls"
      printf 'MEDIASTACK_GATE_BIND=127.0.0.1:\nWATCHSTATE_TRUST_TRAEFIK=true\n' > "$ENV_FILE"
      c_state() { [[ $1 == mediastack-traefik ]] && echo "$TS"; }
      DC() { echo "DC $* trust=$(grep -c '^WATCHSTATE_TRUST_TRAEFIK=' "$ENV_FILE")" >> "$T/calls"; return "$DCRC"; }
      sudo() { echo "sudo $*" >> "$T/calls"
               [[ "$*" == "docker exec mediastack-traefik wget -qO- --timeout=5 http://watchstate:8080/v1/api/system/auth/has_user" ]] || return 9
               case $ANS in
                   trusted) echo '{"auto_login":true,"token":"t","oidc_available":false}' ;;
                   asks)    echo '{"oidc_available":false}' ;;
                   none)    : ;;
                   silent)  echo "wget: can't connect to remote host"; return 1 ;;
                   junk)    echo '<html>' ;;
               esac; }
      GATE_UNTRUSTED=1 watchstate_gate_login > "$T/gl" 2>&1; echo "fails=$WIRE_FAILS" )
}
[[ "$(gl asks 0 running)" == "fails=0" ]] && grep -q 'OK watchstate: asks for its own login again' "$T/gl" \
    && [[ "$(sed -n 1p "$T/calls")" == "DC up -d watchstate trust=0" ]] && grep -q 'docker exec mediastack-traefik' "$T/calls" \
    || fail_ "disable: the trust gone before its recreate, then proven from Traefik: $(cat "$T/gl") $(cat "$T/calls")"; pass
[[ "$(gl trusted 0 running)" == "fails=1" ]] && grep -q 'still signs in Traefik.s callers' "$T/gl" && grep -q 'WS_TRUST_LOCAL' "$T/gl" \
    || fail_ "still trusted after its recreate (its own .env): a failure naming the setting: $(cat "$T/gl")"; pass
[[ "$(gl none 0 running)" == "fails=0" ]] && grep -q 'WARN watchstate: it has no account yet' "$T/gl" && grep -q 'https://watch.example.com' "$T/gl" \
    || fail_ "no account yet: a warning with where to make it, not a failure: $(cat "$T/gl")"; pass
[[ "$(gl silent 0 running)" == "fails=1" ]] && grep -q 'did not answer Traefik within' "$T/gl" || fail_ "silent: bounded, then a failure: $(cat "$T/gl")"; pass
[[ "$(gl junk 0 running)" == "fails=1" ]] && grep -q 'unreadable' "$T/gl" || fail_ "an answer that is not its JSON: a failure: $(cat "$T/gl")"; pass
[[ "$(gl asks 1 running)" == "fails=1" ]] && grep -q 'could not recreate it' "$T/gl" || fail_ "its recreate refused: a failure: $(cat "$T/gl")"; pass
[[ "$(gl asks 0 exited)" == "fails=1" ]] && grep -q 'Traefik is not running' "$T/gl" && [[ ! -f "$T/calls" ]] \
    || fail_ "Traefik down: a failure before anything changes: $(cat "$T/gl")"; pass

# ---- the compose lines ----
grep -qF -- '- WS_TRUST_LOCAL=${WATCHSTATE_TRUST_TRAEFIK:-false}' services/watchstate/compose.yml \
    || fail_ "compose: the trust off unless .env says so"; pass
grep -qF -- '- WS_TRUST_LOCAL_NET=${TRAEFIK_ADDRESS:-172.31.250.2}/32' services/watchstate/compose.yml \
    || fail_ "compose: the trust names Traefik's address alone (its default: every private range)"; pass
! grep -q 'WS_TRUST_PROXY' services/watchstate/compose.yml || fail_ "compose: its forwarded-header trust never set (a header could name Traefik)"; pass

echo "OK watchstate: $checks checks"
