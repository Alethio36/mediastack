#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-dispatcharr.sh — Dispatcharr behind the portal (services/dispatcharr/):
#   * dispatcharr-login names the stack's admin while the portal guards it
#     (gate_planned), and removes the header otherwise; valid YAML either way
#   * its header sign-in follows the gate (on with Traefik's header, off
#     otherwise), is put back when it differs, read back, and proven: the
#     header from this host is refused, or wire fails
#   * `disable authentik` turns it off; wire creates the stack's admin on a
#     fresh install, and fails loud on one set up by hand
#   * before its first start, provision makes uploads/ and jwt its own, and
#     never replaces a key that exists
#   * its fragment trusts Traefik's address alone, and no route skips the gate
# Sources the real entrypoint (minus its last line, main "$@"); its API, curl and sudo are stubs.
#
#   scripts/test-dispatcharr.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-dispatcharr.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"
set +E; trap - ERR

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "OK $*"; }; wfail() { WIRE_FAILS=$((WIRE_FAILS + 1)); echo "FAIL $*"; }
info() { echo "INFO $*"; }; hr() { :; }
WIRE_DRY=0

# ---- dispatcharr-login: the admin's name while guarded, the header removed otherwise ----
PLANNED=yes ON=yes
gate_planned() { [[ $PLANNED == yes && "$1" == dispatcharr ]]; }
svc_enabled() { [[ $ON == yes && "$1" == dispatcharr ]]; }
env_get() { case $1 in DISPATCHARR_ADMIN_USER) echo admin ;; DISPATCHARR_ADMIN_PASSWORD) echo s3cretPass16abcd ;; DISPATCHARR_UID) echo 13030 ;; CONFIG_ROOT) echo "$T/config" ;; esac; }
hdr() { python3 -I -c 'import sys, yaml; print(yaml.safe_load("m:\n" + sys.argv[1])["m"]["dispatcharr-login"]["headers"]["customRequestHeaders"]["X-Mediastack-User"])' "$1"; }
[[ "$(hdr "$(dispatcharr_login_middleware)")" == admin ]] || fail_ "guarded: the header names the stack's admin: $(dispatcharr_login_middleware)"; pass
PLANNED=no
[[ -z "$(hdr "$(dispatcharr_login_middleware)")" ]] || fail_ "not guarded: the header removed (empty), so a client's own copy never passes: $(dispatcharr_login_middleware)"; pass
PLANNED=yes ON=no
[[ -z "$(hdr "$(dispatcharr_login_middleware)")" ]] || fail_ "not enabled: removed, still defined (its route exists for the whole catalogue)"; pass
ON=yes
o=$( svc_managed() { printf '%s\n' sonarr dispatcharr; }; dispatcharr_login_middleware() { echo HOOK; }; traefik_service_middlewares )
[[ "$o" == HOOK ]] || fail_ "Traefik's file takes it as each catalogue service's <svc>_login_middleware: $o"; pass

# ---- its header sign-in: follows the gate, put back, read back, proven ----
TRUSTED=yes
gate_trusted() { [[ $TRUSTED == yes && -z "${GATE_UNTRUSTED:-}" && "$1" == dispatcharr ]]; }
dsp_url() { echo http://127.0.0.1:9191; }
CALLS="$T/calls"
row() { jq -cn --argjson v "$1" '[{id: 3, key: "stream_settings", value: {}}, {id: 18, key: "reverse_proxy_auth", name: "Reverse Proxy Auth", value: $v}]'; }
dsp_api() { # stub: settings as ROWS holds them; a PATCH saves into BACK; read back from BACK
    echo "$1 $2 ${4:-}" >> "$CALLS"
    case "$1 $2" in
        "GET /api/core/settings/")     [[ -n "$ROWS" ]] || { echo refused; return 1; }; echo "$ROWS" ;;
        "PATCH /api/core/settings/18/") [[ -z "${HOLD:-}" ]] && jq -c '.value' <<<"$4" > "$T/back"; echo '{}' ;;
        "GET /api/core/settings/18/")  jq -cn --argjson v "$(cat "$T/back")" '{id: 18, key: "reverse_proxy_auth", value: $v}' ;;
        *) echo "unexpected $1 $2"; return 1 ;;
    esac
}
curl() { echo "$PROOF"; }   # the proof's POST from this host: its status
sg() { # sg CURRENT-VALUE — dsp_signin's run: fails, then the calls made
    ( set -eE; trap on_err ERR; : > "$CALLS"; WIRE_FAILS=0; ROWS=$(row "$1"); echo "$1" > "$T/back"; dsp_signin tok > "$T/out" 2>&1; echo "fails=$WIRE_FAILS"; cut -d' ' -f1,2 "$CALLS" | paste -sd, - )
}
PROOF=401
r=$(sg '{"enabled":true,"header":"X-Mediastack-User"}')
[[ "$r" == $'fails=0\nGET /api/core/settings/' ]] && grep -q 'signs nobody in from anywhere but Traefik' "$T/out" || fail_ "on as wanted: read, nothing written, proven: $r $(cat "$T/out")"; pass
r=$(sg '{"enabled":false,"header":""}')
[[ "$r" == $'fails=0\nGET /api/core/settings/,PATCH /api/core/settings/18/,GET /api/core/settings/18/' ]] \
    && grep -q '"header":"X-Mediastack-User"' "$CALLS" && grep -q '"enabled":true' "$CALLS" || fail_ "off behind the portal: switched on with Traefik's header, read back: $r $(cat "$T/out")"; pass
r=$(sg '{"enabled":true,"header":"X-Forwarded-User"}')
[[ "$r" == *PATCH* && "$r" == fails=0* ]] && grep -q 'X-Forwarded-User' "$T/out" || fail_ "on with another header: put back to Traefik's, and said: $r $(cat "$T/out")"; pass
TRUSTED=no
r=$(sg '{"enabled":true,"header":"X-Mediastack-User"}')
[[ "$r" == *PATCH* && "$r" == fails=0* ]] && grep -q '"enabled":false' "$CALLS" || fail_ "no portal: switched off: $r $(cat "$T/out")"; pass
r=$(sg '{"enabled":false,"header":"X-Old"}')
[[ "$r" != *PATCH* && "$r" == fails=0* ]] || fail_ "no portal, already off (any header kept): nothing written: $r"; pass
TRUSTED=yes
r=$( HOLD=1; sg '{"enabled":false,"header":""}' )
[[ "$r" == fails=1* ]] && grep -q 'did not hold' "$T/out" || fail_ "a change that did not hold: a failure, never assumed: $r $(cat "$T/out")"; pass
PROOF=200
r=$(sg '{"enabled":true,"header":"X-Mediastack-User"}')
[[ "$r" == fails=1* ]] && grep -q 'HTTP 200, not 401' "$T/out" && grep -q DISPATCHARR_TRUSTED_PROXIES "$T/out" || fail_ "the header believed from this host: a failure naming the cause: $r $(cat "$T/out")"; pass
PROOF=000
r=$(sg '{"enabled":true,"header":"X-Mediastack-User"}')
[[ "$r" == fails=1* ]] || fail_ "the proof unanswered: a failure: $r"; pass
PROOF=401
r=$( set -eE; trap on_err ERR; ROWS=x; : > "$CALLS"; WIRE_FAILS=0; ROWS='[{"id":3,"key":"stream_settings","value":{}}]'; dsp_signin tok > "$T/out" 2>&1; echo "fails=$WIRE_FAILS"; grep -c PATCH "$CALLS" || true )
[[ "$r" == $'fails=1\n0' ]] && grep -q 'no reverse_proxy_auth setting' "$T/out" || fail_ "its setting missing: a failure, nothing written: $r"; pass
r=$( set -eE; trap on_err ERR; : > "$CALLS"; WIRE_FAILS=0; ROWS=""; dsp_signin tok > "$T/out" 2>&1; echo "fails=$WIRE_FAILS"; grep -c PATCH "$CALLS" || true )
[[ "$r" == $'fails=1\n0' ]] || fail_ "its settings unreadable: a failure, nothing written: $r"; pass

# ---- disable authentik: off while the portal still runs ----
dsp_login() { echo tok; }
r=$( : > "$CALLS"; WIRE_FAILS=0; ROWS=$(row '{"enabled":true,"header":"X-Mediastack-User"}'); echo '{}' > "$T/back"
     GATE_UNTRUSTED=1 dispatcharr_gate_login > "$T/out" 2>&1; echo "fails=$WIRE_FAILS" )
[[ "$r" == fails=0 ]] && grep -q '"enabled":false' "$CALLS" || fail_ "disable authentik: header sign-in off before the port reopens: $r $(cat "$T/out")"; pass
r=$( set -eE; trap on_err ERR; dsp_login() { echo "dispatcharr rejected the stored admin login: x"; return 1; }; WIRE_FAILS=0; dispatcharr_gate_login > "$T/out" 2>&1; echo "fails=$WIRE_FAILS" )
[[ "$r" == fails=1 ]] || fail_ "disable authentik: no sign-in is a failure (authentik stays): $r"; pass

# ---- wire: the stack's admin on a fresh install; one set up by hand fails loud ----
wire_gate() { :; }; dsp_ready() { :; }; dsp_signin() { echo SIGNIN >> "$CALLS"; }
wd() { # wd FIRST-RUN-STATE [no-login] — wire_dispatcharr's run: fails, then the calls made
    ( set -eE; trap on_err ERR; : > "$CALLS"; WIRE_FAILS=0; ST=$1; NL=${2:-}
      dsp_api() { echo "$1 $2" >> "$CALLS"; case "$1 $2" in
          "GET /api/accounts/initialize-superuser/") [[ "$ST" != refused ]] || { echo refused; return 1; }; echo "$ST" ;;
          "POST /api/accounts/initialize-superuser/") echo '{"superuser_exists":true}' ;; esac; }
      if [[ -n "$NL" ]]; then env_get() { case $1 in CONFIG_ROOT) echo /x ;; *) echo "" ;; esac; }; fi
      wire_dispatcharr > "$T/out" 2>&1; echo "fails=$WIRE_FAILS"; paste -sd, "$CALLS" )
}
r=$(wd '{"superuser_exists":false,"client_ip":"172.31.250.1","setup_allowed":true}')
[[ "$r" == $'fails=0\nGET /api/accounts/initialize-superuser/,POST /api/accounts/initialize-superuser/,SIGNIN' ]] || fail_ "fresh: its admin created, then its sign-in: $r $(cat "$T/out")"; pass
r=$(wd '{"superuser_exists":true}')
[[ "$r" == $'fails=0\nGET /api/accounts/initialize-superuser/,SIGNIN' ]] || fail_ "set up: never created again: $r"; pass
r=$(wd '{"superuser_exists":true}' no-login)
[[ "$r" == fails=1* && "$r" != *SIGNIN* ]] && grep -q 'set up by hand' "$T/out" || fail_ "set up by hand, no login stored: a failure that says both ways out: $r $(cat "$T/out")"; pass
r=$(wd '{"superuser_exists":false}' no-login)
[[ "$r" == fails=1* && "$r" != *POST* ]] || fail_ "fresh with no login stored: a failure, nothing invented: $r"; pass
r=$(wd refused)
[[ "$r" == fails=1* && "$r" != *POST* ]] || fail_ "its first-run state unreadable: a failure, nothing created: $r"; pass
r=$(wd '{"detail":"odd"}')
[[ "$r" == fails=1* && "$r" != *POST* ]] || fail_ "a first-run state that reads neither way: a failure, nothing created: $r"; pass

# ---- before its first start: uploads/ and jwt its own, an existing key kept ----
mkdir -p "$T/bin" "$T/config/dispatcharr"
printf '#!/bin/sh\necho "$@" >> %s/chown\n' "$T" > "$T/bin/chown"; chmod +x "$T/bin/chown"
sudo() { env PATH="$T/bin:$PATH" "$@"; }
dispatcharr_provision
[[ -d "$T/config/dispatcharr/uploads" && "$(stat -c %a "$T/config/dispatcharr/jwt")" == 600 && "$(wc -c < "$T/config/dispatcharr/jwt")" -ge 64 ]] \
    && grep -qx "13030:mediacenter $T/config/dispatcharr/uploads" "$T/chown" && grep -qx "13030:mediacenter $T/config/dispatcharr/jwt" "$T/chown" \
    || fail_ "provision: uploads/ and a private key, both owned by its UID: $(cat "$T/chown")"; pass
k=$(cat "$T/config/dispatcharr/jwt"); : > "$T/chown"; dispatcharr_provision
[[ "$(cat "$T/config/dispatcharr/jwt")" == "$k" && ! -s "$T/chown" ]] || fail_ "provision again: the key kept, nothing re-owned"; pass
grep -q '^        local pf; pf="${s//-/_}_provision"$' mediastack.sh && grep -q 'if declare -F "$pf" >/dev/null; then "$pf"; fi' mediastack.sh \
    || fail_ "provision runs each enabled service's <service>_provision, found by name"; pass

# ---- its fragment: Traefik's address alone, no route past the gate ----
f=services/dispatcharr/compose.yml
grep -qF -- '- DISPATCHARR_TRUSTED_PROXIES=${TRAEFIK_ADDRESS:-172.31.250.2}/32' "$f" || fail_ "it trusts Traefik's address alone (a /32)"; pass
grep -qE '^\s*mediastack\.auth: "gate"' "$f" && grep -qE '^\s*mediastack\.auth\.inject: "true"' "$f" && ! grep -q 'mediastack.auth.bypass' "$f" \
    || fail_ "gated, the header added past the gate, and no route that skips it"; pass

echo "OK dispatcharr: $checks checks"
