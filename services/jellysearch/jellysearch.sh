#!/usr/bin/env bash
# services/jellysearch/jellysearch.sh — doctor's check that JellySearch can
# read Jellyfin's config. Sourced by the entrypoint; relies on the
# entrypoint's helpers at call time.

jellysearch_doctor_read() { # jellysearch must READ jellyfin's config (doctor: permissions)
if svc_enabled jellysearch; then
    local jcn jout jrc
    jcn=$(svc_cname jellysearch)
    if [[ $(c_state "$jcn") == running ]]; then
        jout=$(sudo docker exec "$jcn" test -r /config 2>&1) && jrc=0 || jrc=$?
        if (( jrc == 0 )); then ok "jellysearch can read jellyfin's config"
        elif grep -q "executable file not found" <<<"$jout"; then
            info "jellysearch: image has no probe tooling — skipped"
        else d_fail "jellysearch cannot read /config inside its container" "search cannot index" "./mediastack.sh fix-perms jellyfin"; fi
    else info "jellysearch not running — read probe skipped"; fi
fi
}
