#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-matrix.sh — the stack renders in more shapes than "everything": every
# other test renders --profile "*", which hides a service that needs one it
# does not pull in. Here:
#   * each service on its own, with what resolve_deps adds: resolve_deps
#     answers service names only (its notes go to stderr — they once landed in
#     COMPOSE_PROFILES, and .env validation then refused every command), and
#     that set renders through vpn_gen like `enable` does
#   * the shipped default set (.env.example) renders
#   * everything at once renders, one side of each conflict pair left out
# Runs on a throwaway copy of the repo (tracked files only); needs `docker
# compose` (the standalone plugin renders without a daemon).
#
#   scripts/test-matrix.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
repo=$PWD
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
git -C "$repo" ls-files -z | (cd "$repo" && xargs -0 cp --parents -t "$work")
cd "$work"
cp .env.example .env
sed '$d' mediastack.sh > .test-matrix-lib.sh
# shellcheck disable=SC1091
source ./.test-matrix-lib.sh
set +e +E; trap - ERR   # each check reads its own status

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }
renders_as() { # renders_as LABEL SERVICE... — that set, through vpn_gen, renders
    local label=$1; shift
    env_set COMPOSE_PROFILES "$(printf '%s\n' "$@" | paste -sd, -)" >/dev/null
    vpn_gen >/dev/null 2>&1 || fail_ "$label: vpn_gen failed"
    local out; out=$(DC config -q 2>&1) || fail_ "$label: does not render [$*]: $(head -3 <<<"$out")"
}

vpn_gen >/dev/null 2>&1 || fail_ "vpn_gen failed on .env.example"   # a live install always has its overlay: VPN membership is a dependency
RENDERED_JSON=""; render
profiles=$(jq -r '[.services[].profiles[]?] | unique[]' <<<"$RENDERED_JSON")
[[ $(wc -l <<<"$profiles") -ge 20 ]] || fail_ "the catalogue lists only $(wc -l <<<"$profiles") profiles"; pass

n=0
for p in $profiles; do
    sel=$(resolve_deps "$p" 2>/dev/null)
    bad=$(grep -vxE '[a-z0-9-]+' <<<"$sel" || true)
    [[ -z "$bad" ]] || fail_ "resolve_deps $p answers more than service names: $bad"
    grep -qx "$p" <<<"$sel" || fail_ "resolve_deps $p leaves $p out"
    # shellcheck disable=SC2086  # a word list of services
    renders_as "$p on its own" $sel
    n=$((n+1))
done
pass; echo "OK $n services each render on their own, with what they pull in"

# shellcheck disable=SC2046  # a word list of services
renders_as "the shipped default set" $(grep -oP '^COMPOSE_PROFILES=\K.*' .env.example | tr ',' ' '); pass

# everything: each conflict pair keeps its first-named side
drop=""
while read -r a b; do [[ -n "$a" ]] && drop+=" $b"; done < <(conflicts_in $profiles)
every=$(for p in $profiles; do [[ " $drop " == *" $p "* ]] || echo "$p"; done)
# shellcheck disable=SC2086  # a word list of services
renders_as "everything (without:$drop)" $every; pass

echo "test-matrix: $checks checks passed"
