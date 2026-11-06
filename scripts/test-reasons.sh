#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-reasons.sh — a function that explains a failure never fails itself:
#   * every reason function (*_why, *_reason, *_problem(s), *_hint, oneline and
#     smtp_live_stale), given empty input with docker, curl and the apps unreachable,
#     returns 0 under set -Eeuo pipefail with an ERR trap — as the stack runs it
#     (found live Nov 2026: a reason printer's empty grep ended wire)
#   * every function whose header promises "" when there is nothing (and names
#     no rc of its own) answers "" with rc 0 when nothing is reachable
#   * the paths found by the audit: an update night with GitHub unreachable, a
#     sign-in link authentik did not print, a setting the running worker lacks
# Sources the real entrypoint (minus its last line, main "$@").
#
#   scripts/test-reasons.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-reasons.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"
set +e +E; trap - ERR   # each check reads its own status

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

# as the stack runs: errexit, errtrace, pipefail, an ERR trap that ends the run
as_stack() { ( set -Eeuo pipefail; trap 'echo "TRAPPED at $BASH_COMMAND"; exit 9' ERR; "$@" ) 2>&1; }

LOCAL_DIR="$T/local"; STATE_DIR="$LOCAL_DIR/state"
sudo() { return 1; }; curl() { return 7; }; env_get() { :; }; svc_cname() { echo "mediastack-$1"; }
RENDERED_JSON='{"services":{}}'

# ---- every reason function, empty input, everything unreachable ----
mapfile -t reasons < <(declare -F | awk '{print $3}' \
    | grep -E '_(why|reason|problem|problems|hint)$|^(oneline|smtp_live_stale)$' || true)
(( ${#reasons[@]} >= 15 )) || fail_ "the reason functions are found by name (${#reasons[@]}: ${reasons[*]})"; pass
for f in "${reasons[@]}"; do
    n=$(declare -f "$f" | grep -oE '\$\{?[1-9]' | grep -oE '[1-9]' | sort -n | tail -1 || true)
    args=(); for (( i = 0; i < ${n:-0}; i++ )); do args+=(""); done
    [[ "$f" == env_value_problem ]] && args[0]=TZ   # a key the schema knows
    out=$(as_stack "$f" "${args[@]}"); rc=$?
    (( rc == 0 )) || fail_ "$f, given nothing, fails instead of explaining (rc=$rc): $out"; pass
done

# ---- every getter that promises "" when there is nothing, with everything unreachable ----
# (found live Nov 2026: gluetun_addr on a stopped gluetun ended restore and update)
# a header naming an rc, or that it dies, documents its failure instead
mapfile -t getters < <(grep -hE '^[a-z_][a-z0-9_]*\(\) *\{ *#.*"" when' mediastack.sh lib/*.sh services/*/*.sh \
    | grep -vE '#.*(\brc [0-9]|dies)' | sed 's/().*//' || true)
(( ${#getters[@]} >= 10 )) || fail_ "the getters are found by their header (${#getters[@]}: ${getters[*]})"; pass
for f in "${getters[@]}"; do
    n=$(declare -f "$f" | grep -oE '\$\{?[1-9]' | grep -oE '[1-9]' | sort -n | tail -1 || true)
    args=(); for (( i = 0; i < ${n:-0}; i++ )); do args+=(""); done
    [[ "$f" == c_get ]] && args=(mediastack-x .State.Status)   # a jq path is the caller's
    out=$(as_stack "$f" "${args[@]}"); rc=$?
    (( rc == 0 )) || fail_ "$f, with nothing to find, fails instead of answering \"\" (rc=$rc): $out"; pass
done
[[ "$(as_stack gluetun_addr)" == "" ]] || fail_ "a stopped gluetun has no address: \"\""; pass

# ---- the update night, GitHub unreachable: no notice, the run goes on ----
out=$(as_stack recyclarr_pin_notice; echo "rc=$?")
[[ "$out" == "rc=0" ]] || fail_ "recyclarr's pin notice with GitHub unreachable says nothing and ends nothing: $out"; pass

# ---- a setting the running worker lacks is named, not a crash ----
out=$( sudo() { printf 'AUTHENTIK_EMAIL__HOST=localhost\n'; }; as_stack smtp_live_stale )
[[ "$out" == *SMTP_PORT* && "$out" != *TRAPPED* && "$out" != *SMTP_HOST* ]] \
    || fail_ "smtp_live_stale names what the worker lacks, not what it has: $out"; pass

# ---- authentik answered without a sign-in link: its own words, not a trap ----
out=$( ak_api() { case "$2" in /core/users/*) echo '{"results":[{"pk":1,"type":"internal","is_active":true}]}' ;; *) echo '{"results":[]}' ;; esac; }
       sudo() { echo '{"event": "booting"}'; echo 'Error: user not found'; }; authentik_portal() { echo https://portal.example.com; }
       as_stack authentik_recover bob )
[[ "$out" == *"authentik answered without a sign-in link: Error: user not found"* && "$out" != *TRAPPED* ]] \
    || fail_ "a missing link is reported with authentik's reason: $out"; pass
[[ "$(as_stack ak_cmd_why '{"event": "x"}')" == "it printed only its own log lines" ]] || fail_ "only log lines: said so"; pass

echo "test-reasons: $checks checks passed"
