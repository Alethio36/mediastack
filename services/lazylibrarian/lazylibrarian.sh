#!/usr/bin/env bash
# services/lazylibrarian/lazylibrarian.sh — LazyLibrarian's API client and
# its `wire lazylibrarian` role.
# Sourced by the entrypoint; relies on lib/wire.sh, lib/addr.sh and the
# entrypoint's helpers at call time.

ll_url() { local p; p=$(svc_hostport lazylibrarian) || return 1; echo "http://127.0.0.1:$p"; }
ll_key() { # LazyLibrarian mints its API key on first run into config.ini
    local f
    f="$(env_get CONFIG_ROOT)/lazylibrarian/config.ini"
    [[ -r "$f" ]] || { sudo cat "$f" 2>/dev/null | sed -n 's/^api_key = *//p' | head -1; return; }
    sed -n 's/^api_key = *//p' "$f" | head -1
}
ll_api() { # ll_api cmd [k=v ...] -> body; the &cmd= API, apikey-authenticated
    local cmd="$1"; shift
    local q kv
    q="apikey=$(ll_key)&cmd=$cmd"
    for kv in "$@"; do q+="&$kv"; done
    curl -sS -m 15 "$(ll_url)/api?$q" 2>/dev/null
}

wire_lazylibrarian() {
    hr "wire: LazyLibrarian"
    svc_enabled lazylibrarian || { info "lazylibrarian not enabled — skipped"; return 0; }
    wire_gate lazylibrarian
    http_ready lazylibrarian "$(ll_url)/" '^([23][0-9][0-9]|401|403)$' || return 1
    local key; key=$(ll_key)
    if [[ -z "$key" ]]; then
        # first-ever start: the API key is minted only after the web UI has
        # been opened once and config saved. Cannot proceed headless.
        wfail "lazylibrarian has no API key yet — open https://books-dl.\$TRAEFIK_DOMAIN once,
     go to Config -> Interface, set a username/password and Save, restart it
     in the UI, then re-run: ./mediastack.sh wire lazylibrarian"
        return 1
    fi
    ok "API key found"

    # download client: qBittorrent, at its app-to-app address (svc_addr)
    (( WIRE_DRY )) && { w_would "point lazylibrarian at qBittorrent and set its book folder" || true; }
    if ! (( WIRE_DRY )); then
        local qu qp
        qu=$(env_get QBITTORRENT_USER); qp=$(env_get QBITTORRENT_PASSWORD)
        if [[ -z "$qu" || -z "$qp" ]]; then
            wfail "no qBittorrent credentials in .env — run 'wire qbit' first"
        else
            # LazyLibrarian's qBittorrent settings live in [QBITTORRENT]
            ll_api writeCFG "name=HOST&group=QBITTORRENT&value=http://$(svc_host qbittorrent)" >/dev/null
            ll_api writeCFG "name=PORT&group=QBITTORRENT&value=$(svc_cport qbittorrent)" >/dev/null
            ll_api writeCFG "name=USER&group=QBITTORRENT&value=$qu" >/dev/null
            ll_api writeCFG "name=PASS&group=QBITTORRENT&value=$qp" >/dev/null
            ll_api writeCFG "name=LABEL&group=QBITTORRENT&value=prowlarr" >/dev/null
            ll_api writeCFG "name=TOR_DOWNLOADER&group=General&value=qbittorrent" >/dev/null
            ok "qBittorrent set as download client"
            # book destination on the shared media tree
            ll_api writeCFG "name=EBOOK_DEST_FOLDER&group=General&value=/data/media/books" >/dev/null
            ll_api writeCFG "name=AUDIO_DEST_FOLDER&group=General&value=/data/media/audiobooks" >/dev/null
            ll_api writeCFG "name=DESTINATION_DIR&group=General&value=/data/media/books" >/dev/null
            ok "book folders set (/data/media/books, /data/media/audiobooks)"
            ll_api loadCFG >/dev/null
            ok "config reloaded"
        fi
    fi
    info "indexers arrive automatically from Prowlarr (registered in the prowlarr pass)"
}
