#!/usr/bin/env bash
# shellcheck disable=SC2034  # RENDERED_JSON is read by the sourced render()
# test-render.sh — the compose config must render from a fresh .env.example
# through vpn_gen, and keep rendering across the your-service lifecycle that
# `new-service` and its documented removal go through:
#
#   1. .env.example -> vpn_gen -> config renders; vpn_gen is byte-stable
#   2. + a toggle service as a drop-in (custom/compose.d/, what new-service
#      writes) -> vpn_gen sees it, the overlay carries its stanza, it renders
#   3. the drop-in is removed and vpn_gen is NOT re-run -> the stale overlay
#      must break the render (this is the bug `up` regenerates first for —
#      if it stops failing, the test no longer proves what it claims)
#   4. vpn_gen (the `up` order) -> overlay drops the stanza, config renders
#   5. the shard rules hold for every shipped fragment, and a two-container
#      drop-in shard renders with its member found and not managed
#   6. every web interface declares mediastack.auth, and exactly the gated
#      ones' routes carry the mediastack-gate middleware
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

renders() { # renders <label> -> 0 if the full profile set renders
    local err; err=$(mktemp)
    if sudo docker compose --project-directory "$work" \
            -f docker-compose.yml ${1:+-f "$1"} -f "$OVERLAY_FILE" \
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
# defined AFTER the source: the entrypoint has its own fail() that only prints
t_fail() { echo "ERROR $*" >&2; exit 1; }

echo ":: 1. fresh .env.example"
# every fragment is included — one left out renders fine and is silently absent
missing=$(for f in compose.d/*.yml; do grep -qxF "  - $f" docker-compose.yml || echo "$f"; done)
[[ -z "$missing" ]] || t_fail "fragments docker-compose.yml does not include: $missing"
vpn_gen
[[ -s "$OVERLAY_FILE" ]] || t_fail "vpn_gen wrote no overlay"
renders "" || t_fail "base config does not render"
# every variable a fragment reads is declared in .env.example (a value may be
# empty — a secret written later — but an UNDECLARED one is a stale example)
unset_vars=$(sudo docker compose --project-directory "$work" -f docker-compose.yml -f "$OVERLAY_FILE" \
    --profile "*" config -q 2>&1 | grep -oE 'The \\?"[A-Z0-9_]+\\?" variable is not set' || true)
[[ -z "$unset_vars" ]] || t_fail "variables read by a fragment but absent from .env.example:"$'\n'"$unset_vars"
cp "$OVERLAY_FILE" "$work/overlay.first"
vpn_gen
cmp -s "$OVERLAY_FILE" "$work/overlay.first" || t_fail "vpn_gen is not byte-stable for identical inputs"
echo "OK base renders; overlay byte-stable ($(grep -c '^  [a-z0-9-]*:$' "$OVERLAY_FILE") stanzas)"

echo ":: 2. toggle service added as a drop-in (custom/compose.d/)"
mkdir -p custom/compose.d
cp "$repo/scripts/fixtures/toggle-service.override.yml" custom/compose.d/hello.yml
vpn_gen
grep -q '^  hello:$' "$OVERLAY_FILE" || t_fail "overlay has no stanza for the drop-in service"
renders custom/compose.d/hello.yml || t_fail "config with the drop-in service does not render"
echo "OK drop-in service seen by vpn_gen and renders"

echo ":: 3. drop-in removed, overlay stale"
rm custom/compose.d/hello.yml
if renders "" 2>/dev/null; then
    t_fail "a stale overlay stanza rendered — this test no longer proves the up-order regen matters"
fi
echo "OK stale overlay breaks the render (as expected)"

echo ":: 4. vpn_gen before render (the up order)"
vpn_gen
grep -q '^  hello:$' "$OVERLAY_FILE" && t_fail "overlay still carries the removed service"
renders "" || t_fail "config does not render after vpn_gen"
cmp -s "$OVERLAY_FILE" "$work/overlay.first" || t_fail "overlay differs from the original after add+remove"
echo "OK render: overlay regenerated, config renders, identical to step 1"

echo ":: 5. shards: the shipped fragments and a two-container drop-in"
RENDERED_JSON=""; bad=$(shard_problems)
[[ -z "$bad" ]] || t_fail "the shipped fragments break the shard rules:"$'\n'"$bad"
cp "$repo/scripts/fixtures/shard-service.yml" custom/compose.d/shardapp.yml
vpn_gen; RENDERED_JSON=""
[[ "$(svc_members shardapp)" == shardapp-db ]] || t_fail "the drop-in's member was not found: $(svc_members shardapp)"
bad=$(shard_problems); [[ -z "$bad" ]] || t_fail "a well-formed drop-in shard reported: $bad"
svc_managed | grep -qx shardapp-db && t_fail "a member must not be listed as a managed service"
rm custom/compose.d/shardapp.yml; vpn_gen
echo "OK shard rules hold for the shipped fragments and a rendered drop-in shard"

echo ":: 6. every web interface declares who logs it in; gated routes carry the gate"
RENDERED_JSON=""; render
bad=$(jq -r '.services | to_entries[] | select(.value.labels["mediastack.subdomain"] != null)
    | select((.value.labels["mediastack.auth"] // "") | IN("gate","native","open") | not) | .key' <<<"$RENDERED_JSON")
[[ -z "$bad" ]] || t_fail "web interfaces without mediastack.auth (gate|native|open): $bad"
for s in $(jq -r '.services | to_entries[] | select(.value.labels["mediastack.subdomain"] != null) | .key' <<<"$RENDERED_JSON"); do
    r=$(vpn_rname "$s"); auth=$(jq -r --arg s "$s" '.services[$s].labels["mediastack.auth"]' <<<"$RENDERED_JSON")
    mw=$(jq -r --arg k "traefik.http.routers.$r.middlewares" '[.services[].labels[$k] // empty] | join(",")' <<<"$RENDERED_JSON")
    if [[ "$auth" == gate ]]; then [[ "$mw" == *mediastack-gate@file* ]] || t_fail "$s is gated but its route ($r) has no mediastack-gate middleware"
    else [[ "$mw" != *mediastack-gate@file* ]] || t_fail "$s is $auth but its route carries the gate"; fi
done
# an API that skips the gate: only on a gated tool, as its own router without the gate
for s in $(jq -r '.services | to_entries[] | select(.value.labels["mediastack.auth.bypass"] != null) | .key' <<<"$RENDERED_JSON"); do
    [[ "$(jq -r --arg s "$s" '.services[$s].labels["mediastack.auth"]' <<<"$RENDERED_JSON")" == gate ]] || t_fail "$s: a gate bypass on a service that is not gated"
    r=$(vpn_rname "$s")
    rule=$(jq -r --arg k "traefik.http.routers.$r-api.rule" '[.services[].labels[$k] // empty][0] // ""' <<<"$RENDERED_JSON")
    for p in $(jq -r --arg s "$s" '.services[$s].labels["mediastack.auth.bypass"]' <<<"$RENDERED_JSON"); do
        [[ "$rule" == *"PathPrefix(\`$p\`)"* ]] || t_fail "$s: its $r-api router does not cover $p (got: $rule)"
    done
    # past the gate: no gate — and never a username header a client made up
    [[ "$(jq -r --arg k "traefik.http.routers.$r-api.middlewares" '[.services[].labels[$k] // empty] | join(",")' <<<"$RENDERED_JSON")" == "mediastack-strip@file" ]] \
        || t_fail "$s: its API router must carry mediastack-strip (and not the gate)"
done
# while the portal guards them (MEDIASTACK_GATE_BIND=127.0.0.1:), a gated
# tool's host port listens on 127.0.0.1 only — and nothing else's changes
web_ips() { # -> "<svc> <auth> <host_ip|none>" per web interface, from the current render
    local s pub nm cp
    for s in $(jq -r '.services | to_entries[] | select(.value.labels["mediastack.subdomain"] != null) | .key' <<<"$RENDERED_JSON"); do
        pub=$s; nm=$(jq -r --arg s "$s" '.services[$s].network_mode // ""' <<<"$RENDERED_JSON"); [[ "$nm" == service:* ]] && pub=${nm#service:}
        cp=$(jq -r --arg s "$s" '.services[$s].labels["mediastack.port"]' <<<"$RENDERED_JSON")
        echo "$s $(jq -r --arg s "$s" '.services[$s].labels["mediastack.auth"]' <<<"$RENDERED_JSON") $(jq -r --arg p "$pub" --argjson t "$cp" \
            '[.services[$p].ports[]? | select(.target == $t) | (.host_ip // "any")][0] // "none"' <<<"$RENDERED_JSON")"
    done
}
open_ips=$(web_ips)
env_set MEDIASTACK_GATE_BIND "127.0.0.1:"; RENDERED_JSON=""; render
while read -r s auth ip; do
    before=$(awk -v s="$s" '$1==s{print $3}' <<<"$open_ips")
    [[ "$ip" == none ]] && continue   # not published on the host at all
    if [[ "$auth" == gate ]]; then [[ "$ip" == 127.0.0.1 ]] || t_fail "$s is gated but its host port listens on '$ip'"
    else [[ "$ip" == "$before" ]] || t_fail "$s is $auth but closing the gate moved its host port ($before -> $ip)"; fi
done < <(web_ips)
env_set MEDIASTACK_GATE_BIND ""; RENDERED_JSON=""
# the stack network's fixed range, Traefik's fixed address in it
render
net=$(jq -c '.networks.mediastack.ipam.config[0]' <<<"$RENDERED_JSON")
[[ "$(jq -r '.subnet' <<<"$net")" == 172.31.250.0/24 && "$(jq -r '.ip_range' <<<"$net")" == 172.31.250.128/25 ]] \
    || t_fail "the stack network has no fixed range: $net"
[[ "$(jq -r '.services.traefik.networks.mediastack.ipv4_address' <<<"$RENDERED_JSON")" == 172.31.250.2 ]] \
    || t_fail "Traefik has no fixed address"
jq -e '.services.traefik.networks.mediastack.aliases | any(startswith("portal.")) and any(startswith("ldap."))' <<<"$RENDERED_JSON" >/dev/null \
    || t_fail "inside the stack, the portal's and LDAP's names must lead to Traefik"
# the script reaches Audiobookshelf on 127.0.0.1 only (mediastack.hostport: local)
[[ "$(jq -r '[.services.audiobookshelf.ports[]? | select(.target == 13378) | .host_ip][0] // "none"' <<<"$RENDERED_JSON")" == 127.0.0.1 ]] \
    || t_fail "Audiobookshelf's port must be 127.0.0.1 only"
echo "OK every web interface declares mediastack.auth; the gate is on exactly the gated routes"
