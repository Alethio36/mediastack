#!/usr/bin/env bash
# lib/migrations.sh — the .env schema migrations: migrate_env (run by load_env
# on every command) and one migrate_env_<n>_to_<n+1> per schema step. Adding
# a step = bump SCRIPT_SCHEMA in the entrypoint + one function here + the
# matching change in .env.example (CI enforces the bump). Sourced by the
# entrypoint; relies on lib/common.sh's env_* primitives.

migrate_env() {
    local have; have=$(env_get ENV_SCHEMA 0)
    if (( have > SCRIPT_SCHEMA )); then
        die ".env schema ($have) is NEWER than this script ($SCRIPT_SCHEMA).
  You likely downgraded the repo. Run 'git pull' to return to the newer
  version, or restore .env from a backup matching this script."
    fi
    while (( have < SCRIPT_SCHEMA )); do
        # the schema is part of the name: several steps run within one second,
        # and a timestamp alone made each overwrite the last (only the newest
        # pre-migration state survived — never the file the user started with)
        cp "$ENV_FILE" "$ENV_FILE.bak.$(date +%Y%m%d%H%M%S).schema$have"
        local next=$((have + 1))
        info "Migrating .env schema $have -> $next (backup written)"
        "migrate_env_${have}_to_${next}"
        env_set ENV_SCHEMA "$next"
        have=$next
    done
    :
}
migrate_env_0_to_1() { :; } # base schema: nothing to do
migrate_env_1_to_2() {
    # profiles were groups; now profile == service name. Translate.
    local cur out="" tok
    cur=$(env_get COMPOSE_PROFILES)
    for tok in ${cur//,/ }; do case "$tok" in
        core) out+="gluetun qbittorrent sonarr radarr prowlarr jellyfin npm " ;;
        search) out+="meilisearch jellysearch " ;;
        requests) out+="seerr " ;;
        music) out+="lidarr " ;;
        subs) out+="bazarr " ;;
        dns) out+="pihole " ;;
        tunnel) out+="cloudflared " ;;
        torrents-extra) out+="deluge transmission " ;;
        tv) out+="ersatztv " ;;
        *) out+="$tok " ;;   # already a service name
    esac; done
    env_set COMPOSE_PROFILES "$(echo "$out" | tr ' ' '\n' | awk 'NF && !seen[$0]++' | paste -sd, -)"
    info "Profiles translated to per-service form: $(env_get COMPOSE_PROFILES)"
}
migrate_env_2_to_3() {
    # ersatztv's upstream image is rootful (no user mapping) — a UID entry
    # for it made doctor audit root-owned files against a fictional owner.
    env_del ERSATZTV_UID
    info "Removed ERSATZTV_UID (ersatztv runs as root by upstream design)."
}
migrate_env_3_to_4() { :; } # .env.example default change only; existing values stand
migrate_env_4_to_5() { :; } # additive only (arr instances, wire credentials)
migrate_env_5_to_6() { :; } # additive only (stack-wide arr login)
migrate_env_6_to_7() {
    # wave 4 adds wizarr: adopt its vars so enable/up on an existing .env
    # never renders unset variables (configure's self-heal only runs there).
    if ! grep -qE '^WIZARR_UID=' "$ENV_FILE"; then
        local max
        max=$(grep -E '_UID=[0-9]+' "$ENV_FILE" | cut -d= -f2 | sort -n | tail -1)
        env_set WIZARR_UID "$(( ${max:-$(env_get UID_BASE 13000)} + 1 ))"
        info "New service variable WIZARR_UID -> $(env_get WIZARR_UID)"
    fi
    grep -qE '^WIZARR_UPDATE=' "$ENV_FILE" || env_set WIZARR_UPDATE true
}
migrate_env_7_to_8() {
    # wave 5 adds apprise (+ cleanuparr later in the wave)
    if ! grep -qE '^APPRISE_UID=' "$ENV_FILE"; then
        local max
        max=$(grep -E '_UID=[0-9]+' "$ENV_FILE" | cut -d= -f2 | sort -n | tail -1)
        env_set APPRISE_UID "$(( ${max:-$(env_get UID_BASE 13000)} + 1 ))"
        info "New service variable APPRISE_UID -> $(env_get APPRISE_UID)"
    fi
    grep -qE '^APPRISE_UPDATE=' "$ENV_FILE" || env_set APPRISE_UPDATE true
    if ! grep -qE '^CLEANUPARR_UID=' "$ENV_FILE"; then
        local cmax
        cmax=$(grep -E '_UID=[0-9]+' "$ENV_FILE" | cut -d= -f2 | sort -n | tail -1)
        env_set CLEANUPARR_UID "$(( ${cmax:-$(env_get UID_BASE 13000)} + 1 ))"
        info "New service variable CLEANUPARR_UID -> $(env_get CLEANUPARR_UID)"
    fi
    grep -qE '^CLEANUPARR_UPDATE=' "$ENV_FILE" || env_set CLEANUPARR_UPDATE true
}
migrate_env_8_to_9() {
    # watchstate joins as an official service
    if ! grep -qE '^WATCHSTATE_UID=' "$ENV_FILE"; then
        local wmax
        wmax=$(grep -E '_UID=[0-9]+' "$ENV_FILE" | cut -d= -f2 | sort -n | tail -1)
        env_set WATCHSTATE_UID "$(( ${wmax:-$(env_get UID_BASE 13000)} + 1 ))"
        info "New service variable WATCHSTATE_UID -> $(env_get WATCHSTATE_UID)"
    fi
    grep -qE '^WATCHSTATE_UPDATE=' "$ENV_FILE" || env_set WATCHSTATE_UPDATE true
}
migrate_env_9_to_10() {
    if ! grep -qE '^NAVIDROME_UID=' "$ENV_FILE"; then
        local nmax
        nmax=$(grep -E '_UID=[0-9]+' "$ENV_FILE" | cut -d= -f2 | sort -n | tail -1)
        env_set NAVIDROME_UID "$(( ${nmax:-$(env_get UID_BASE 13000)} + 1 ))"
        info "New service variable NAVIDROME_UID -> $(env_get NAVIDROME_UID)"
    fi
    grep -qE '^NAVIDROME_UPDATE=' "$ENV_FILE" || env_set NAVIDROME_UPDATE true
}
migrate_env_10_to_11() {
    # two reading/listening servers join; adopt their UID/UPDATE vars
    local svc var last
    for svc in AUDIOBOOKSHELF KAVITA; do
        var="${svc}_UID"
        if ! grep -qE "^${var}=" "$ENV_FILE"; then
            last=$(grep -E '_UID=[0-9]+' "$ENV_FILE" | cut -d= -f2 | sort -n | tail -1)
            env_set "$var" "$(( ${last:-$(env_get UID_BASE 13000)} + 1 ))"
            info "New service variable $var -> $(env_get "$var")"
        fi
        grep -qE "^${svc}_UPDATE=" "$ENV_FILE" || env_set "${svc}_UPDATE" true
    done
}
migrate_env_11_to_12() {
    if ! grep -qE '^LAZYLIBRARIAN_UID=' "$ENV_FILE"; then
        local lmax
        lmax=$(grep -E '_UID=[0-9]+' "$ENV_FILE" | cut -d= -f2 | sort -n | tail -1)
        env_set LAZYLIBRARIAN_UID "$(( ${lmax:-$(env_get UID_BASE 13000)} + 1 ))"
        info "New service variable LAZYLIBRARIAN_UID -> $(env_get LAZYLIBRARIAN_UID)"
    fi
    grep -qE '^LAZYLIBRARIAN_UPDATE=' "$ENV_FILE" || env_set LAZYLIBRARIAN_UPDATE true
}
migrate_env_12_to_13() {
    # NPM left the stack when Traefik replaced it (its fragment is gone), but
    # its profile name and variables lingered in .env.example and in every
    # .env written from it. A profile that selects nothing is noise in
    # COMPOSE_PROFILES; drop it and the two dead variables.
    local cur out="" tok
    cur=$(env_get COMPOSE_PROFILES)
    for tok in ${cur//,/ }; do [[ "$tok" == npm ]] || out+="$tok,"; done
    [[ "${out%,}" == "$cur" ]] || { env_set COMPOSE_PROFILES "${out%,}"; info "COMPOSE_PROFILES: dropped 'npm' (no such service since Traefik replaced it)"; }
    env_del NPM_UPDATE; env_del NPM_HTTP_PORT
    # the panel's host user is written by frontdoor-install; declared empty
    # here so a render never warns about an unset variable
    grep -qE '^OLIVETIN_UID=' "$ENV_FILE" || env_set OLIVETIN_UID ""
    grep -qE '^OLIVETIN_GID=' "$ENV_FILE" || env_set OLIVETIN_GID ""
    grep -qE '^CF_DNS_API_TOKEN=' "$ENV_FILE" || env_set CF_DNS_API_TOKEN ""
}
migrate_env_13_to_14() {
    # NPM returns as a shipped fragment (an alternative edge, not wired);
    # root-by-image, so only its update toggle is adopted
    grep -qE '^NPM_UPDATE=' "$ENV_FILE" || env_set NPM_UPDATE true
}
migrate_env_14_to_15() {
    # transcodes get their own root: a few GB per stream at source bitrate,
    # written and read back while someone watches — the one part of the cache
    # that must not sit on a network share. Existing installs keep it under
    # their cache (where wire jellyfin already pointed it); configure asks
    # where it should really live.
    if [[ -z "$(env_get TRANSCODE_ROOT)" ]]; then
        env_set TRANSCODE_ROOT "$(env_get CACHE_ROOT)/transcodes"
        info "New root TRANSCODE_ROOT -> $(env_get TRANSCODE_ROOT) (relocate with: ./mediastack.sh configure)"
    fi
}
migrate_env_15_to_16() { :; } # .env.example default change only (DATA_ROOT=./data); existing values stand
migrate_env_16_to_17() { :; } # .env.example comment only (relative roots are refused at runtime)
