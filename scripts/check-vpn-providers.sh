#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# check-vpn-providers.sh — the provider folders (services/gluetun/providers)
# against the providers the gluetun image itself lists (format-servers -h, read
# as up reads it: gluetun_usage_providers). A folder the image no longer has
# fails: gluetun dropped it (Perfect Privacy's case, Aug 2026) and configure
# would offer a provider that cannot start. A provider the image has and
# mediastack has no folder for is a warning: `custom` reaches it until one is
# written. Each folder's server choices are then held to the image's own server
# list (format-servers -<provider> -format json, its built-in data): a filter
# with no value for a tunnel the folder runs, or a server flag no server has,
# fails — configure would offer a choice that matches nothing. Needs Docker (CI
# pulls the image; :latest is what installs run).
#
#   scripts/check-vpn-providers.sh [IMAGE]     default qmcgaw/gluetun:latest
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
img=${1:-qmcgaw/gluetun:latest}
lib=$(mktemp .check-vpnp.XXXXXX); trap 'rm -f "$lib"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"

docker pull -q "$img" >/dev/null
out=$(docker run --rm "$img" format-servers -h 2>&1 || true)
have=$(gluetun_usage_providers <<<"$out")
[[ -n "$have" ]] || { echo "FAIL $img: its format-servers listed no providers — the usage changed? $(head -c 400 <<<"$out")"; exit 1; }
rc=0
for p in $(vpnp_list); do
    [[ "$p" == custom ]] && continue
    grep -qxF -- "$p" <<<"$have" || { echo "::error::services/gluetun/providers/$p: $img no longer has it — remove the folder (configure would offer a provider that cannot start)"; rc=1; }
done
for p in $(vpnp_list); do
    [[ "$p" == custom ]] && continue
    grep -qxF -- "$p" <<<"$have" || continue
    data=$(docker run --rm --network none "$img" format-servers "-$p" -format json 2>&1) \
        || { echo "::error::services/gluetun/providers/$p: $img's format-servers -$p failed: $(head -c 300 <<<"$data")"; rc=1; continue; }
    for t in $(vpnp_call "$p" types); do
        for f in $(vpnp_call "$p" filters); do
            [[ "$f" != flags ]] || continue
            n=$(jq --arg t "$t" --arg k "${VPN_FILTER_FIELD[$f]}" '[.[] | select(.vpn == $t) | if $k == "categories" then (.categories // [])[] else (.[$k] // empty) end | select(. != "")] | unique | length' <<<"$data")
            (( n > 0 )) || { echo "::error::services/gluetun/providers/$p: it offers $f, and $img's $t servers have none — drop it from its filters"; rc=1; }
        done
        for f in $(vpnp_flags "$p"); do
            n=$(jq --arg t "$t" --arg k "${VPN_FLAG_FIELD[$f]}" '[.[] | select(.vpn == $t and .[$k] == true)] | length' <<<"$data")
            (( n > 0 )) || { echo "::error::services/gluetun/providers/$p: it offers the flag $f, and none of $img's $t servers has it — drop it from its flags"; rc=1; }
        done
    done
done
for g in $have; do
    [[ -d "services/gluetun/providers/$g" ]] || echo "::warning::$img has '$g', mediastack has no folder for it — custom reaches it until one is written"
done
(( rc == 0 )) && echo "OK every provider folder is one $img knows ($(wc -l <<<"$have") providers there), each server choice it offers has servers there"
exit $rc
