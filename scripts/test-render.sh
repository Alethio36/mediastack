#!/usr/bin/env bash
# test-render.sh — the compose config must render from a fresh .env.example
# through vpn_gen, and keep rendering across the override lifecycle that
# `new-service` and its documented removal go through:
#
#   1. .env.example -> vpn_gen -> config renders; vpn_gen is byte-stable
#   2. + a toggle service in docker-compose.override.yml -> vpn_gen sees it,
#      the overlay carries its stanza, config renders
#   3. the override is removed and vpn_gen is NOT re-run -> the stale overlay
#      must break the render (this is the bug `up` regenerates first for —
#      if it stops failing, the test no longer proves what it claims)
#   4. vpn_gen (the `up` order) -> overlay drops the stanza, config renders
#
# Runs on a throwaway copy of the repo; the working tree is never touched.
# Needs `docker compose` (the standalone plugin renders without a daemon).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
repo=$PWD

# tracked files only: on a deployed checkout the repo dir also holds
# config/, cache/ and backups/, and none of that belongs in a render test
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
git -C "$repo" ls-files -z | (cd "$repo" && xargs -0 cp --parents -t "$work")
cd "$work"
cp .env.example .env

fail() { echo "ERROR $*" >&2; exit 1; }
renders() { # renders <label> -> 0 if the full profile set renders
    local err; err=$(mktemp)
    if sudo docker compose --project-directory "$work" \
            -f docker-compose.yml ${1:+-f "$1"} -f local/vpn-overlay.yml \
            --profile "*" config -q 2>"$err"; then
        rm -f "$err"; return 0
    fi
    sed 's/^/    compose: /' "$err" >&2; rm -f "$err"; return 1
}

# the entrypoint minus its last line (main "$@"), sourced for vpn_gen
lib=$(mktemp .test-render.XXXXXX)
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"; rm -f "$lib"

echo ":: 1. fresh .env.example"
vpn_gen
[[ -s local/vpn-overlay.yml ]] || fail "vpn_gen wrote no overlay"
renders "" || fail "base config does not render"
cp local/vpn-overlay.yml "$work/overlay.first"
vpn_gen
cmp -s local/vpn-overlay.yml "$work/overlay.first" || fail "vpn_gen is not byte-stable for identical inputs"
echo "OK base renders; overlay byte-stable ($(grep -c '^  [a-z0-9-]*:$' local/vpn-overlay.yml) stanzas)"

echo ":: 2. toggle service added in docker-compose.override.yml"
cp "$repo/scripts/fixtures/toggle-service.override.yml" docker-compose.override.yml
vpn_gen
grep -q '^  hello:$' local/vpn-overlay.yml || fail "overlay has no stanza for the override service"
renders docker-compose.override.yml || fail "config with the override service does not render"
echo "OK override service seen by vpn_gen and renders"

echo ":: 3. override removed, overlay stale"
rm docker-compose.override.yml
if renders "" 2>/dev/null; then
    fail "a stale overlay stanza rendered — this test no longer proves the up-order regen matters"
fi
echo "OK stale overlay breaks the render (as expected)"

echo ":: 4. vpn_gen before render (the up order)"
vpn_gen
grep -q '^  hello:$' local/vpn-overlay.yml && fail "overlay still carries the removed service"
renders "" || fail "config does not render after vpn_gen"
cmp -s local/vpn-overlay.yml "$work/overlay.first" || fail "overlay differs from the original after add+remove"
echo "OK render: overlay regenerated, config renders, identical to step 1"
