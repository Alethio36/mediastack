#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-ll-login.sh — ll_login (services/lazylibrarian/lazylibrarian.sh),
# LazyLibrarian's page login:
#   * no trusted portal gate: the shared arr login goes into config.ini's
#     [GENERAL] (stopped, then started), the rest of the file, its owner and
#     mode kept; any password is written as typed
#   * behind a trusted gate: its own login is removed
#   * nothing changes when it already matches (no stop, no start); a dry run
#     writes nothing; no arr login yet: nothing is touched
#   * proven, not assumed: a page that still admits a stranger is a failure
# Sources the real entrypoint (minus its last line, main "$@"); compose, sudo,
# curl and the portal check are stubs; curl plays LazyLibrarian from config.ini.
#
#   scripts/test-ll-login.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-ll-login.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

F=$T/lazylibrarian/config.ini
GATE=no ARRU=admin ARRP=secret IGNORES=0
env_get() { case $1 in CONFIG_ROOT) echo "$T" ;; ARR_USER) echo "$ARRU" ;; ARR_PASSWORD) echo "$ARRP" ;; esac; }
gate_trusted() { [[ $GATE == yes ]]; }
DC()           { echo "DC $*" >> "$T/dc"; }
http_ready()   { :; }
ll_url()       { echo "http://ll"; }
sudo() { # runs the command; install's owner flags dropped (the test is not root)
    if [[ $1 == install ]]; then
        shift; local a=()
        while (( $# )); do case $1 in -o|-g) shift 2 ;; *) a+=("$1"); shift ;; esac; done
        command install "${a[@]}"
    else "$@"; fi
}
curl() { # plays LazyLibrarian: a login in config.ini means 401 without it, 303 with it
    local u="" a; for a in "$@"; do [[ ${prev:-} == -u ]] && u=$a; prev=$a; done
    local fu fp; fu=$(sed -n 's/^http_user = //p' "$F"); fp=$(sed -n 's/^http_pass = //p' "$F")
    if [[ -z $fu || $IGNORES == 1 ]]; then echo 303
    elif [[ $u == "$fu:$fp" ]]; then echo 303
    else echo 401; fi
}
fresh() {
    rm -f "$T/dc"; WIRE_FAILS=0; WIRE_DRY=0; mkdir -p "$T/lazylibrarian"
    printf '[API]\napi_enabled = True\napi_key = k123\n\n[GENERAL]\nhttp_port = 5299\n\n[LOGGING]\nlogdir = /config/log\n' > "$F"
    chmod 640 "$F"
}
run() { ll_login > "$T/out" 2>&1 || true; }

fresh; run
grep -qx 'http_user = admin' "$F" && grep -qx 'http_pass = secret' "$F" || fail_ "the arr login is written: $(cat "$F")"; pass
[[ $(awk '/^\[GENERAL\]$/{getline; print; exit}' "$F") == 'http_user = admin' ]] || fail_ "under [GENERAL]: $(cat "$F")"; pass
grep -qx 'api_key = k123' "$F" && grep -qx 'logdir = /config/log' "$F" && grep -qx 'http_port = 5299' "$F" || fail_ "the rest of the file is kept"; pass
[[ $(stat -c %a "$F") == 640 ]] || fail_ "its mode is kept (got $(stat -c %a "$F"))"; pass
[[ $(cat "$T/dc") == $'DC stop lazylibrarian\nDC start lazylibrarian' ]] || fail_ "written while stopped: $(cat "$T/dc")"; pass
(( WIRE_FAILS == 0 )) && grep -q "OK.*asks for the arr login ('admin')" "$T/out" || fail_ "proven by its answers: $(cat "$T/out")"; pass

rm -f "$T/dc"; run
[[ ! -e "$T/dc" ]] && grep -q "OK.*asks for the arr login" "$T/out" || fail_ "a match changes nothing: $(cat "$T/dc" 2>/dev/null)"; pass
[[ $(grep -c '^http_user' "$F") == 1 ]] || fail_ "one login line, never two"; pass

fresh; ARRP='a&b\c/%d e'; run
grep -qxF 'http_pass = a&b\c/%d e' "$F" && (( WIRE_FAILS == 0 )) || fail_ "a password is written as typed: $(grep http_pass "$F")"; pass
ARRP=secret

GATE=yes; run
! grep -qE '^http_(user|pass)' "$F" && grep -q 'OK.*its own login is off' "$T/out" || fail_ "behind the portal its own login goes: $(cat "$F")"; pass
GATE=no

fresh; ARRU=""; run
[[ ! -e "$T/dc" ]] && ! grep -qE '^http_(user|pass)' "$F" && grep -q "not set yet" "$T/out" || fail_ "no arr login yet: nothing touched"; pass
ARRU="admin"

fresh; WIRE_DRY=1; ll_login > "$T/out" 2>&1 || true
[[ ! -e "$T/dc" ]] && ! grep -qE '^http_(user|pass)' "$F" && grep -q 'would:' "$T/out" || fail_ "a dry run writes nothing: $(cat "$T/out")"; pass

fresh; IGNORES=1; run
(( WIRE_FAILS == 1 )) && grep -q 'did not take the login' "$T/out" || fail_ "a page still open to a stranger is a failure: $(cat "$T/out")"; pass

echo "test-ll-login: $checks checks passed"
