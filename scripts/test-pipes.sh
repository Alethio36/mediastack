#!/usr/bin/env bash
# test-pipes.sh — no pipeline in the stack or its tests ends in a reader that stops early:
#   * after a `|`: head, grep -q / -m (or --quiet, --max-count), an awk that
#     exits — the reader stops, the writer still writing dies of SIGPIPE, and
#     under pipefail the pipeline is 141: an `if` reads "no", an assignment
#     under set -e ends the run (found live, Nov 2026: vpn_group | grep -q
#     read a VPN'd service as outside the group; oneline's | head -c killed a
#     run on a 16 KB reply). Read everything instead: sed -n 1p, grep >/dev/null,
#     awk 'NR == 1', ${s:0:N}.
#   * oneline() turns a 100 KB reply into 200 characters under set -euo pipefail
# A line that must keep one says why: # pipe-ok: <why>
#
#   scripts/test-pipes.sh     run (exit 1 on a hit)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

files=(mediastack.sh lib/*.sh services/*/*.sh scripts/*.sh)   # the tests too: a check that fails by timing is no check
reader='(^|[^|])\|[[:space:]]*(head\b|grep\b[^|;&]*[[:space:]](-[a-zA-Z]*[qm][a-zA-Z]*|--quiet|--silent|--max-count)\b)'
awkexit='(^|[^|])\|[^|]*\bawk\b[^|]*\bexit\b'
hits=$(grep -nE "$reader|$awkexit" "${files[@]}" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -v '# pipe-ok:' || true)
if [[ -n "$hits" ]]; then
    echo "$hits"
    echo "FAIL: a pipeline ends in a reader that stops early (above) — read everything: sed -n 1p, grep >/dev/null, awk 'NR == 1', \${s:0:N}" >&2
    exit 1
fi
echo "OK no pipeline ends in a reader that stops early (${#files[@]} files)"

out=$(bash -c 'set -euo pipefail; source lib/wire.sh 2>/dev/null || true
    big=$(head -c 100000 /dev/zero | tr "\0" x); m="error: $(oneline "$big")"; echo "${#m}"') \
    || { echo "FAIL: oneline killed a set -euo pipefail run on a 100 KB reply" >&2; exit 1; }
[[ "$out" == 207 ]] || { echo "FAIL: oneline on a 100 KB reply: 200 characters (got $out, with the 7 of the message)" >&2; exit 1; }
echo "OK oneline: a 100 KB reply, 200 characters, the run goes on"
