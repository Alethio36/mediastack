#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-jf-proxies.sh — Jellyfin's Known proxies (services/jellyfin/jellyfin.sh):
#   * Traefik on: its address is added, Jellyfin restarts once and the change
#     is read back; entries of the owner's stay
#   * Traefik off: the stack's address is removed (it could be anyone's),
#     the owner's entries stay
#   * already right: nothing written, no restart; a dry run writes nothing
#   * the setting missing (moved in a new Jellyfin), a rejected write, or a
#     change lost over the restart: a failure, and no restart before the write
#   * doctor: a problem when Traefik is on and not trusted; silent with Traefik off
# Sources the real entrypoint (minus its last line, main "$@"); Jellyfin's API,
# compose and the service lookups are stubs.
#
#   scripts/test-jf-proxies.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-jf-proxies.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

TRAEFIK=on POST_OK=1 LOSE=0
env_get()      { [[ $1 == TRAEFIK_ADDRESS ]] && echo 172.31.250.2; }
svc_enabled()  { [[ $1 == traefik && $TRAEFIK == on ]]; }
is_user_facing() { return 1; }
jf_ready()     { :; }
DC()           { echo "DC $*" >> "$T/dc"; (( LOSE )) && echo '{"KnownProxies":[]}' > "$T/net.json"; return 0; }
jf_code()      { cat "$T/code" 2>/dev/null || echo 200; }
jf_api() { # GET answers $T/net.json; POST stores the body (or is rejected)
    case "$1" in
        GET)  cat "$T/net.json" ;;
        POST) (( POST_OK )) || { echo 400 > "$T/code"; echo rejected; return 1; }
              printf '%s' "$4" > "$T/net.json"; echo "POST" >> "$T/posts" ;;
    esac
}
fresh() { rm -f "$T/dc" "$T/posts" "$T/code"; printf '%s' "$1" > "$T/net.json"; WIRE_FAILS=0; WIRE_DRY=0; D_FAILS=0; TRAEFIK=on POST_OK=1 LOSE=0; }
proxies() { jq -c '.KnownProxies' "$T/net.json"; }
run() { jf_known_proxies tok > "$T/out" 2>&1 || true; }

fresh '{"KnownProxies":[],"EnableIPv6":false}'; run
[[ $(proxies) == '["172.31.250.2"]' ]] || fail_ "Traefik on: its address is added ($(proxies))"; pass
[[ $(jq -r .EnableIPv6 "$T/net.json") == false ]] || fail_ "the rest of the network settings is kept"; pass
[[ $(cat "$T/dc") == "DC restart jellyfin" ]] || fail_ "one restart: $(cat "$T/dc" 2>/dev/null)"; pass
(( WIRE_FAILS == 0 )) && grep -q 'OK.*now trusts Traefik' "$T/out" || fail_ "read back after the restart: $(cat "$T/out")"; pass

rm -f "$T/dc" "$T/posts"; run
[[ ! -e "$T/dc" && ! -e "$T/posts" ]] && grep -q 'OK.*trusts Traefik (172.31.250.2)' "$T/out" || fail_ "already right: no write, no restart"; pass

fresh '{"KnownProxies":["10.9.9.9"]}'; run
[[ $(proxies) == '["10.9.9.9","172.31.250.2"]' ]] || fail_ "an owner's entry stays when ours is added ($(proxies))"; pass

fresh '{"KnownProxies":["10.9.9.9","172.31.250.2"]}'; TRAEFIK=off; run
[[ $(proxies) == '["10.9.9.9"]' && $(cat "$T/dc") == "DC restart jellyfin" ]] || fail_ "Traefik off: ours goes, the owner's stays ($(proxies))"; pass

fresh '{"KnownProxies":null}'; TRAEFIK=off; run
[[ ! -e "$T/dc" ]] && grep -q 'OK.*trusts no proxy' "$T/out" || fail_ "Traefik off, nothing trusted: nothing to do — $(cat "$T/out")"; pass

fresh '{"EnableIPv6":false}'; run
(( WIRE_FAILS == 1 )) && [[ ! -e "$T/posts" && ! -e "$T/dc" ]] && grep -q 'no KnownProxies — the setting moved' "$T/out" \
    || fail_ "the setting missing: a failure, nothing written — $(cat "$T/out")"; pass

fresh '{"KnownProxies":[]}'; POST_OK=0; run
(( WIRE_FAILS == 1 )) && [[ ! -e "$T/dc" ]] && grep -q 'rejected its network settings \[HTTP 400\]' "$T/out" \
    || fail_ "a rejected write: a failure, no restart — $(cat "$T/out")"; pass

fresh '{"KnownProxies":[]}'; LOSE=1; run
(( WIRE_FAILS == 1 )) && grep -q 'did not read back as changed after its restart \[HTTP 200\]: \[\]' "$T/out" || fail_ "a change lost over the restart is a failure, with what was read — $(cat "$T/out")"; pass

fresh '{"KnownProxies":[]}'; WIRE_DRY=1; jf_known_proxies tok > "$T/out" 2>&1 || true
[[ ! -e "$T/posts" && ! -e "$T/dc" ]] && grep -q 'would: jellyfin: trust Traefik' "$T/out" || fail_ "a dry run writes nothing — $(cat "$T/out")"; pass

# ---- doctor ----
fresh '{"KnownProxies":[]}'; jellyfin_doctor_proxies key > "$T/out" 2>&1
(( D_FAILS == 1 )) && grep -q 'does not trust Traefik' "$T/out" && grep -q 'wire jellyfin' "$T/out" || fail_ "doctor: untrusted Traefik is a problem with its fix — $(cat "$T/out")"; pass
fresh '{"KnownProxies":["172.31.250.2"]}'; jellyfin_doctor_proxies key > "$T/out" 2>&1
(( D_FAILS == 0 )) && grep -q '^OK.*trusts Traefik' "$T/out" || fail_ "doctor: trusted is OK"; pass
fresh '{"KnownProxies":[]}'; TRAEFIK=off; jellyfin_doctor_proxies key > "$T/out" 2>&1
(( D_FAILS == 0 )) && [[ ! -s "$T/out" ]] || fail_ "doctor: Traefik off — nothing to check"; pass

echo "test-jf-proxies: $checks checks passed"
