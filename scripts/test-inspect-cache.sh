#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-inspect-cache.sh — the docker inspect cache never outlives a change
# (CACHE RULE at c_inspect, mediastack.sh):
#   * every raw `sudo docker start|stop|restart|kill|rm` clears INSPECT_JSON
#     next to it (compose verbs clear it in DC)
#   * stopped_run's stops and starts run in a subshell, whose clears never
#     reach the caller: the caller's cache is cleared when it returns (found
#     Nov 2026: the gate held Prowlarr stopped, the backup still read it running)
# Sources the real entrypoint (minus its last line, main "$@").
#
#   scripts/test-inspect-cache.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-inspect-cache.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

# ---- every raw mutation clears the cache beside it (3 lines either way) ----
bad=""
for f in mediastack.sh lib/*.sh services/*/*.sh; do
    while IFS=: read -r n _; do
        sed -n "$(( n > 3 ? n - 3 : 1 )),$(( n + 3 ))p" "$f" | grep -F 'INSPECT_JSON=""' >/dev/null || bad+=" $f:$n"
    done < <(grep -nE '^[^#]*sudo docker (start|stop|restart|kill|rm)\b' "$f" || true)
done
[[ -z "$bad" ]] || fail_ "a raw docker mutation leaves the inspect cache as it was:$bad"; pass

# ---- stopped_run: the caller reads what is live, not what its subshell changed ----
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"
set +e +E; trap - ERR
STOP_MARKER=$T/stopped; LOCAL_DIR=$T/local; repo_owned() { :; }; info() { :; }; lt_flows_forget() { :; }
echo running > "$T/live"
sudo() { if [[ "$1 $2" == "docker inspect" ]]; then printf '[{"Name":"/mediastack-prowlarr","State":{"Status":"%s"}}]' "$(cat "$T/live")"; else "$@"; fi; }
DC() { [[ " $* " == *" config "* ]] || INSPECT_JSON=""; [[ "$1" != stop ]] || echo exited > "$T/live"; }
stopped_start() { rm -f "$STOP_MARKER"; }   # the leak gate holds it stopped
INSPECT_JSON=$(c_inspect mediastack-prowlarr)
[[ "$(c_state mediastack-prowlarr)" == running ]] || fail_ "the cache starts as running"; pass
stopped_run backup prowlarr true; rc=$?
[[ $rc == 0 && "$(c_state mediastack-prowlarr)" == exited ]] \
    || fail_ "after stopped_run the caller reads the live state (rc=$rc, read $(c_state mediastack-prowlarr))"; pass
stopped_run backup prowlarr false; rc=$?
(( rc != 0 )) || fail_ "stopped_run still returns its command's status"; pass

echo "test-inspect-cache: $checks checks passed"
