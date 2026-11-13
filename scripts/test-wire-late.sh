#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-wire-late.sh — a call that got no answer (lib/wire.sh, MVP step 3):
#   * every API helper marks a timeout (curl 28) and only a timeout; its
#     message says wire reads it back
#   * the failure that follows such a call is noted as unanswered; one that
#     follows none is not; a timeout is cleared at each role's start
#   * when the run ends, each role with one is read back with its own
#     `wire <role> --verify`: nothing missing -> its unanswered failures are
#     taken back (others stay); drift -> they stand, what is missing shown;
#     a role that writes blind cannot be read back and its stand
# Sources the real entrypoint (minus its last line, main "$@"); curl and the
# read-back's `mediastack.sh` are stubs.
#
#   scripts/test-wire-late.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-wire-late.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"
set +e +E; trap - ERR

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }
fresh() { WIRE_FAILS=0; WIRE_FAIL_LIST=(); WIRE_FAIL_UNANSWERED=(); WIRE_UNANSWERED_F=$T/unanswered; : > "$WIRE_UNANSWERED_F"; }

# ---- the helpers mark a timeout, and only a timeout ----
fresh
curl() { return "${CURL_RC:-28}"; }
out=$(api PUT http://x/thing k '{}'); rc=$?
(( rc == 1 )) && [[ "$out" == "no answer within 20s — the change may still have been made: wire reads it back at the end" && -s "$WIRE_UNANSWERED_F" ]] \
    || fail_ "a write that timed out: failed, said, marked ($rc): $out"; pass
fresh; out=$(CURL_RC=7 api PUT http://x/thing k '{}')
[[ ! -s "$WIRE_UNANSWERED_F" ]] || fail_ "a refused connection is not a timeout"; pass
unset -f curl
for h in api ak_api jf_api seerr_api nd_api abs_api kav_api qb_api cup_api deluge_rpc transmission_rpc; do
    grep -q 'api_timed_out' <(declare -f "$h") || fail_ "$h does not mark a call that got no answer"
done; pass

# ---- the failure that follows ----
fresh; WIRE_STEP=jellyfin
echo x >> "$WIRE_UNANSWERED_F"; wfail "jellyfin: setting X — no answer" >/dev/null
wfail "jellyfin: setting Y refused" >/dev/null
[[ "${WIRE_FAIL_UNANSWERED[*]}" == 0 && $WIRE_FAILS == 2 ]] || fail_ "only the failure after the timeout is unanswered: ${WIRE_FAIL_UNANSWERED[*]}"; pass
body=$(awk '/^cmd_wire\(\)/,/^}/' lib/wire.sh)   # the source: declare -f drops comments
grep -qF ': > "$WIRE_UNANSWERED_F"   # a timeout belongs to the role it happened in' <<<"$body" || fail_ "cleared at each role's start"; pass
[[ "$(sed -n '/WIRE_STEP=apply; wire_apply_settings/,/wire_fail_summary/p' <<<"$body")" == *wire_recheck* ]] || fail_ "read back before the summary"; pass

# ---- the read-back ----
mkdir -p "$T/repo"; SCRIPT_DIR=$T/repo; WIRE_LATE_WAIT=0
cat > "$T/repo/mediastack.sh" <<'S'
#!/usr/bin/env bash
# stand-in for `wire <role> --verify`: authentik and arr read back clean, jellyfin still differs
[[ "$1 $3" == "wire --verify" ]] || { echo "called as: $*"; exit 9; }
case "$2" in authentik|arr) echo "OK wire --verify: no drift"; exit 0 ;;
             jellyfin) echo "  would: jellyfin: set Known proxies"; echo "FAIL wire --verify: 1 drift item(s)"; exit 1 ;; esac
exit 9
S
chmod +x "$T/repo/mediastack.sh"
fresh
WIRE_STEP=authentik; echo x > "$WIRE_UNANSWERED_F"; wfail "the gate — no answer" >/dev/null
WIRE_STEP=authentik; wfail "a card refused" >/dev/null
WIRE_STEP=jellyfin;  echo x > "$WIRE_UNANSWERED_F"; wfail "proxies — no answer" >/dev/null
WIRE_STEP=arr;       echo x > "$WIRE_UNANSWERED_F"; wfail "radarr root folder — no answer" >/dev/null
WIRE_STEP=seerr;     echo x > "$WIRE_UNANSWERED_F"; wfail "settings — no answer" >/dev/null
WIRE_STEP=""
out=$(wire_recheck 2>&1; echo "FAILS=$WIRE_FAILS"; printf 'LIST=%s\n' "${WIRE_FAIL_LIST[@]}")
[[ "$out" == *"authentik: read back — everything is in place: what got no answer was done late (1 failure(s) taken back)"* \
   && "$out" == *"arr: read back — everything is in place"* ]] || fail_ "clean roles: their unanswered failures taken back: $out"; pass
[[ "$out" == *"jellyfin: read back — not everything is in place"*"would: jellyfin: set Known proxies"* ]] || fail_ "drift: the failure stands, what is missing shown: $out"; pass
[[ "$out" == *"seerr: it writes blind, so it cannot be read back"* ]] || fail_ "a blind role cannot be read back"; pass
[[ "$out" == *"FAILS=3"* && "$out" == *"LIST=authentik: a card refused"* && "$out" == *"LIST=jellyfin: proxies — no answer"* \
   && "$out" == *"LIST=seerr: settings — no answer"* && "$out" != *"LIST=arr:"* && "$out" != *"LIST=authentik: the gate"* ]] \
    || fail_ "what stands: the other failure of a clean role, the drift, the blind one: $out"; pass
fresh; out=$(wire_recheck 2>&1); [[ -z "$out" ]] || fail_ "nothing got no answer: no read-back, no wait: $out"; pass

echo "OK wire-late: $checks checks"
