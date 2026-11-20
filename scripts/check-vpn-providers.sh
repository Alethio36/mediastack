#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# check-vpn-providers.sh — the provider folders (services/gluetun/providers)
# against the providers the gluetun image itself lists (format-servers -h, read
# as up reads it: gluetun_usage_providers). A folder the image no longer has
# fails: gluetun dropped it (Perfect Privacy's case, Aug 2026) and configure
# would offer a provider that cannot start. A provider the image has and
# mediastack has no folder for is a warning: `custom` reaches it until one is
# written. Needs Docker (CI pulls the image; :latest is what installs run).
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
for g in $have; do
    [[ -d "services/gluetun/providers/$g" ]] || echo "::warning::$img has '$g', mediastack has no folder for it — custom reaches it until one is written"
done
(( rc == 0 )) && echo "OK every provider folder is one $img knows ($(wc -l <<<"$have") providers there)"
exit $rc
