#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-rotate.sh — rotate-secrets' rules (docs/design-rotate.md):
#   * a secret compose carries moves all-or-nothing: proven on its new value,
#     or put back on its old one and proven there, or the run is told it is
#     stuck — and the journal holds it while it is in flight, never after
#   * no value is ever printed
#   * a rotation that never finished is refused until the stack is put back,
#     and doctor names it; one that stopped between secrets is not in flight
#   * the closing warning: framed at one width, a line per cost that leaves
#     work outside the stack, the outside secrets this install holds
#   * Meilisearch's key is proven by the new one taken and the old refused
#
#   scripts/test-rotate.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
lib=$(mktemp .test-rotate.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"
set +e +E; trap - ERR   # each check reads its own status

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

LOCAL_DIR=$T/local; ROTATE_DIR=$LOCAL_DIR/rotate; ROTATE_JOURNAL=$ROTATE_DIR/journal
repo_owned() { :; }; load_env() { :; }
env_get() { sed -n "s/^$1=//p" "$T/env" 2>/dev/null; }
env_set() { sed -i "/^$1=/d" "$T/env"; echo "$1=$2" >> "$T/env"; }

# ---- one secret, all-or-nothing ----
re() { # re PROVES-NEW PROVES-OLD -> "rc=N env=VALUE inflight=NAME" (and the output in $T/out)
    ( echo "K=OLDVALUE" > "$T/env"; rotate_journal_start 20261113-120000
      rotate_up() { :; }
      prove() { if [[ "$1" == NEWVALUE ]]; then [[ "$PN" == yes ]]; else [[ "$PO" == yes ]]; fi; }
      PN=$1 PO=$2; rc=0; rotate_env K NEWVALUE prove > "$T/out" 2>&1 || rc=$?
      echo "rc=$rc env=$(env_get K) inflight=$(rotate_inflight)" )
}
[[ "$(re yes yes)" == "rc=0 env=NEWVALUE inflight=" ]] || fail_ "proven on the new value: kept, nothing in flight: $(re yes yes)"; pass
[[ "$(re no yes)" == "rc=1 env=OLDVALUE inflight=" ]] || fail_ "the new one not proven: back on the old, nothing in flight: $(re no yes)"; pass
[[ "$(re no no)" == "rc=2 env=OLDVALUE inflight=K" ]] || fail_ "neither proven: stuck, the journal still holds it: $(re no no)"; pass
re no no >/dev/null; ! grep -qE 'OLDVALUE|NEWVALUE' "$T/out" || fail_ "a value was printed: $(cat "$T/out")"; pass
[[ "$(stat -c %a "$ROTATE_JOURNAL")" == 600 && "$(stat -c %a "$ROTATE_DIR")" == 700 ]] \
    || fail_ "the journal holds values: 0600 in a 0700 folder"; pass
[[ "$(rotate_journal_point)" == 20261113-120000 ]] || fail_ "the journal keeps the run's restore point"; pass

# ---- a rotation that never finished ----
rotate_journal_start 20261113-120000; rotate_journal_hold K a b
r=$( (cmd_rotate_secrets) 2>&1 </dev/null; echo "rc=$?")
[[ "$r" == *"K was in flight"*"restore --all --from 20261113-120000"*"rc=1" ]] || fail_ "in flight: refused, the way back named: $r"; pass
D_FAILS=0; r=$(run_unfinished() { :; }; _doctor_runs 2>&1)
[[ "$r" == *"a rotation never finished: K"* ]] || fail_ "doctor names a rotation in flight: $r"; pass
rotate_journal_release
[[ -z "$(rotate_inflight)" ]] || fail_ "settled between secrets: nothing in flight"; pass
r=$( (cmd_rotate_secrets) 2>&1 </dev/null; echo "rc=$?")
[[ "$r" == *"interactive"*"rc=1" ]] || fail_ "stopped between secrets is no refusal; no terminal is: $r"; pass

# ---- the closing warning ----
echo "CF_DNS_API_TOKEN=x" > "$T/env"
r=$(rotate_box_lines search)
[[ "$r" == *"Nothing outside the stack held these"* ]] || fail_ "a cost with nothing to do outside: said so: $r"; pass
[[ "$r" == *"Cloudflare's DNS token"* && "$r" != *"tunnel"* && "$r" != *"VPN's key"* ]] \
    || fail_ "the outside secrets this install holds, and only those: $r"; pass
C_YLW=""; C_BLD=""; C_RST=""
w=$(rotate_box "• a line — with dashes" --- "$(printf 'word %.0s' $(seq 1 40))" | while IFS= read -r l; do LC_ALL=C.UTF-8; echo "${#l}"; done | sort -u)
[[ "$(wc -l <<<"$w")" == 1 ]] || fail_ "every line of the frame is one width (long lines fold): $w"; pass

# ---- Meilisearch's key ----
mk() { ( meili_key_code() { case "$1" in NEW) echo "$A" ;; OLD) echo "$B" ;; esac; }; sleep() { :; }
         A=$1 B=$2; meili_key_proven NEW OLD >/dev/null 2>&1; echo $? ) }
[[ "$(mk 200 403)" == 0 ]] || fail_ "meilisearch: new taken, old refused: proven"; pass
[[ "$(mk 200 200)" == 1 ]] || fail_ "meilisearch: the old still taken: not proven"; pass
[[ "$(mk 403 403)" == 1 ]] || fail_ "meilisearch: the new refused: not proven"; pass
[[ "$(svc_enabled() { return 1; }; meilisearch_secrets)" == "" ]] || fail_ "meilisearch off: nothing to rotate"; pass
[[ "$(svc_enabled() { :; }; meilisearch_secrets)" == $'MEILI_MASTER_KEY\tsearch' ]] || fail_ "meilisearch on: its key, tagged search"; pass

echo "OK rotate: $checks checks"
