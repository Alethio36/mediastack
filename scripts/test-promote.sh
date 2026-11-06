#!/usr/bin/env bash
# test-promote.sh — scripts/promote.sh on a throwaway repo pair (GitHub only
# by name: git's insteadOf points it at a local bare repo; curl is a stub):
#   * CI green: stable fast-forwarded to unstable and pushed; you end on unstable
#   * the push of stable fails (found live Nov 2026: a dropped SSH session):
#     it says so, GitHub's stable is unchanged, and you end on unstable
#
#   scripts/test-promote.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

g() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=stable "$@"; }
g init -q --bare "$T/origin.git"
g init -q "$T/work"; cd "$T/work"
git config url."$T/origin.git".insteadOf https://github.com/acme/demo.git
git remote add origin https://github.com/acme/demo.git
mkdir scripts; cp "$OLDPWD/scripts/promote.sh" scripts/
g add -A; g commit -qm base; git push -q origin HEAD:stable HEAD:unstable 2>/dev/null
g checkout -qb unstable --track origin/unstable 2>/dev/null || g checkout -q unstable
echo x > f; g add f; g commit -qm change; git push -q origin unstable 2>/dev/null
mkdir -p "$T/bin"; printf '#!/usr/bin/env bash\necho %s\n' "'{\"total_count\": 1, \"status\": \"completed\", \"conclusion\": \"success\"}'" > "$T/bin/curl"; chmod +x "$T/bin/curl"

# the push of stable fails: refused by the origin
printf '#!/bin/sh\nwhile read o n r; do [ "$r" = refs/heads/stable ] && exit 1; done; exit 0\n' > "$T/origin.git/hooks/pre-receive"; chmod +x "$T/origin.git/hooks/pre-receive"
out=$(PATH="$T/bin:$PATH" bash scripts/promote.sh 2>&1) && fail_ "a failed push: promote fails"; pass
[[ "$(git rev-parse --abbrev-ref HEAD)" == unstable ]] || fail_ "a failed push: back on unstable ($(git rev-parse --abbrev-ref HEAD))"; pass
[[ "$out" == *"pushing stable failed"*"back on unstable"* ]] || fail_ "and it says so: $out"; pass
[[ "$(git --git-dir="$T/origin.git" rev-parse stable)" != "$(git rev-parse unstable)" ]] || fail_ "GitHub's stable is unchanged"; pass

# CI green, the push goes through
rm "$T/origin.git/hooks/pre-receive"
PATH="$T/bin:$PATH" bash scripts/promote.sh > "$T/out" 2>&1 || fail_ "green: promoted — $(cat "$T/out")"; pass
[[ "$(git --git-dir="$T/origin.git" rev-parse stable)" == "$(git rev-parse unstable)" && "$(git rev-parse --abbrev-ref HEAD)" == unstable ]] \
    || fail_ "green: stable is unstable's tip, you end on unstable"; pass

echo "test-promote: $checks checks passed"
