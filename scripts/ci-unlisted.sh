#!/usr/bin/env bash
# ci-unlisted.sh — CI's last step: every scripts/test-*.sh and
# scripts/check-*.sh that no step of .github/workflows/lint.yml names runs
# here, so a new service's own test (scripts/test-<service>.sh) runs in CI
# without a line of its own. A line of its own still gives it a name in the
# run's list; this makes sure nothing is left out.
#
#   scripts/ci-unlisted.sh          run them (exit 1 if any fails)
#   scripts/ci-unlisted.sh --list   only say which they are
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
wf=.github/workflows/lint.yml
mapfile -t rest < <(for f in scripts/test-*.sh scripts/check-*.sh; do
    grep -qF "$f" "$wf" || echo "$f"
done)
if [[ "${1:-}" == --list ]]; then printf '%s\n' "${rest[@]}"; exit 0; fi
(( ${#rest[@]} )) || { echo "OK every test script has a step of its own"; exit 0; }
rc=0
for f in "${rest[@]}"; do
    echo "── $f"
    if "$f"; then :; else echo "::error::$f failed"; rc=1; fi
done
(( rc == 0 )) && echo "OK ${#rest[@]} test script(s) without a step of their own: ${rest[*]}"
exit $rc
