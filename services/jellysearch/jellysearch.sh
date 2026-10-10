#!/usr/bin/env bash
# services/jellysearch/jellysearch.sh — JellySearch's checks: doctor's (it
# can read Jellyfin's config) and update's (its index is not empty). Sourced
# by the entrypoint; relies on the entrypoint's helpers at call time.

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

jellysearch_update_probe() { # after an update: the search index exists and is not empty; rc 1 when it is
    local docs stats="http://127.0.0.1:7700/stats"   # addr-ok: inside meilisearch's own container
    # the key goes in on stdin: sudo logs every command line to the journal
    docs=$(printf '%s' "$(env_get MEILI_MASTER_KEY)" | sudo docker exec -i "$(svc_cname meilisearch)" sh -c \
           'k=$(cat); curl -fsS -H "Authorization: Bearer $k" "$1" \
            || wget -qO- --header="Authorization: Bearer $k" "$1"' _ "$stats" \
           2>/dev/null | jq '[.indexes[].numberOfDocuments] | add // 0' || echo 0)
    (( docs > 0 )) && ok "search index: $docs documents" \
        || { warn "search index EMPTY after update — try 'docker restart $(svc_cname jellysearch)';"; warn "if it stays empty: ./mediastack.sh rollback jellyfin"; return 1; }
}
