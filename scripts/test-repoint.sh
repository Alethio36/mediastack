#!/usr/bin/env bash
# test-repoint.sh — phase 3 of app-to-app addressing: after a VPN toggle moves
# a service, `up` re-points what calls it. Pins the who-calls-whom table
# (WIRE_CALLERS) — statically, every service wire writes an address for must be
# in it, so a new edge cannot be forgotten — the marker `vpn` sets (only on a
# real change), and the re-point step `up` runs: roles in wire's own order, no
# duplicates, marker cleared on success, kept on failure (so `up` retries), and
# skipped entirely on an install that was never wired.
#
#   scripts/test-repoint.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-repoint.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"

# ENV_FILE, RENDERED_JSON and SCRIPT_DIR are read by the sourced code
# shellcheck disable=SC2034
ENV_FILE=$T/.env
# shellcheck disable=SC2034
SCRIPT_DIR=$T                                   # where .wired lives
# shellcheck disable=SC2034
RENDERED_JSON='{"services":{
  "radarr":{"labels":{"mediastack.arrtype":"radarr","mediastack.vpn":"true","mediastack.vpntoggle":"true"}},
  "apprise":{"labels":{"mediastack.vpn":"true","mediastack.vpntoggle":"true"}},
  "kavita":{"labels":{}}}}'
echo "ENV_SCHEMA=$SCRIPT_SCHEMA" > "$ENV_FILE"   # current: cmd_vpn's load_env must not migrate

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }
eq()    { [[ "$2" == "$3" ]] || fail_ "$1: got '$2' want '$3'"; }
callers() { wire_callers "$1" | tr '\n' ' '; }

# who calls whom
eq "arr instance"  "$(callers radarr)"  "prowlarr cleanuparr seerr bazarr "; pass
eq "apprise"       "$(callers apprise)" "apprise cleanuparr seerr "; pass
eq "uncalled"      "$(callers kavita)"  ""; pass
for k in "${!WIRE_CALLERS[@]}"; do
    for r in ${WIRE_CALLERS[$k]}; do
        [[ " ${WIRE_ROLES[*]} " == *" $r "* ]] || fail_ "WIRE_CALLERS[$k] names '$r', which is not a wire role"
    done
done; pass
# static coverage: every service wire writes an address for is in the table
while read -r t; do
    [[ -n "${WIRE_CALLERS[$t]:-}" ]] || fail_ "wire writes an address for '$t' but WIRE_CALLERS has no entry — a toggle would not re-point its callers"
done < <(grep -hoE 'svc_(addr|host|cport) [a-z][a-z0-9-]*' lib/integrations.sh lib/trash.sh | awk '{print $2}' | sort -u); pass

# the marker: added once, only when the side really changes
vpn_base_json() { echo "$RENDERED_JSON"; }
vpn_gen() { :; }
cmd_vpn apprise on >/dev/null                  # already on (label default): no move
eq "no change, no mark" "$(env_get WIRE_REPOINT)" ""; pass
cmd_vpn apprise off >/dev/null
cmd_vpn radarr off >/dev/null
cmd_vpn apprise on >/dev/null                  # moves back: already marked, not twice
eq "marked once each" "$(env_get WIRE_REPOINT)" "apprise radarr"; pass

# the re-point step
CALLS=$T/calls
cmd_wire() { echo "$1" >> "$CALLS"; [[ " ${FAIL_ROLES:-} " != *" $1 "* ]]; }
: > "$CALLS"
wire_repoint_pending > "$T/out"
eq "never wired: no roles run" "$(cat "$CALLS")" ""; pass
eq "never wired: marker cleared" "$(env_get WIRE_REPOINT)" ""; pass

touch "$T/.wired"
repoint_mark apprise; repoint_mark radarr
: > "$CALLS"
wire_repoint_pending > "$T/out"
eq "roles in wire order, once each" "$(tr '\n' ' ' < "$CALLS")" "prowlarr bazarr apprise cleanuparr seerr "; pass
eq "success clears the marker" "$(env_get WIRE_REPOINT)" ""; pass

repoint_mark apprise
: > "$CALLS"
set +e; FAIL_ROLES=cleanuparr wire_repoint_pending > "$T/out"; rc=$?; set -e
[[ $rc == 1 ]] || fail_ "a failed role must fail the step (rc=$rc)"; pass
eq "every role still attempted" "$(tr '\n' ' ' < "$CALLS")" "apprise cleanuparr seerr "; pass
eq "failure keeps the marker for the next up" "$(env_get WIRE_REPOINT)" "apprise"; pass
grep -q 'wire cleanuparr reported failures' "$T/out" || fail_ "the failure must name the role: $(cat "$T/out")"; pass

wire_repoint_pending > /dev/null
eq "nothing pending: no-op" "$(env_get WIRE_REPOINT)" ""; pass

echo "OK repoint: $checks checks"
