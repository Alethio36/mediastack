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

ll_api_enable() { # api_enabled + a new api_key into config.ini's [GENERAL], written while it is stopped
    local f own key
    f="$(env_get CONFIG_ROOT)/lazylibrarian/config.ini"
    sudo test -f "$f" || { wfail "lazylibrarian: no $f yet — it writes one at its first start; re-run: ./mediastack.sh wire lazylibrarian"; return 1; }
    key=$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')   # 32 hex, as it mints its own
    DC stop lazylibrarian >/dev/null 2>&1 || { wfail "lazylibrarian: could not stop it to write its API key"; return 1; }
    own=$(sudo stat -c %u:%g "$f")
    sudo sed -i -e '/^api_enabled *=/d' -e '/^api_key *=/d' -e "/^\[GENERAL\]\$/a api_enabled = 1\napi_key = $key" "$f"
    sudo chown "$own" "$f"
    DC start lazylibrarian >/dev/null 2>&1 || { wfail "lazylibrarian did not start again — inspect: ./mediastack.sh logs lazylibrarian"; return 1; }
    http_ready lazylibrarian "$(ll_url)/" '^([23][0-9][0-9]|401|403)$' || return 1
    [[ "$(ll_api getVersion | head -c1)" == "{" ]] \
        || { wfail "lazylibrarian did not take the API key written to its config.ini — inspect: ./mediastack.sh logs lazylibrarian"; return 1; }
    ok "lazylibrarian: API on, with a key of its own"
}

# Its page has no login of its own. Behind a trusted portal gate it needs none
# (the gate admits admins only, its port is closed to the LAN); anywhere else
# it takes the shared arr login, as HTTP basic auth on the page only — the API
# keeps taking just its key, so Prowlarr's sync is untouched (proven live, Oct
# 2026). Read at start only: written while it is stopped, and only on a change.
ll_login() {
    local f u p cur_u cur_p own mode tmp
    f="$(env_get CONFIG_ROOT)/lazylibrarian/config.ini"
    if gate_trusted lazylibrarian; then u=""; p=""
    else
        u=$(env_get ARR_USER); p=$(env_get ARR_PASSWORD)
        [[ -n "$u" && -n "$p" ]] || { info "lazylibrarian: the shared arr login is not set yet — 'wire arr' creates it"; return 0; }
    fi
    cur_u=$(sudo sed -n 's/^http_user *= *//p' "$f" | head -1)
    cur_p=$(sudo sed -n 's/^http_pass *= *//p' "$f" | head -1)
    if [[ "$cur_u" == "$u" && "$cur_p" == "$p" ]]; then
        if [[ -n "$u" ]]; then ok "lazylibrarian: its page asks for the arr login ('$u')"
        else ok "lazylibrarian: no login of its own — the portal guards it"; fi
        return 0
    fi
    if [[ -n "$u" ]]; then w_would "lazylibrarian: its page asks for the arr login ('$u')" || return 0
    else w_would "lazylibrarian: drop its own login — the portal guards it" || return 0; fi
    DC stop lazylibrarian >/dev/null 2>&1 || { wfail "lazylibrarian: could not stop it to write its login"; return 1; }
    own=$(sudo stat -c %u:%g "$f"); mode=$(sudo stat -c %a "$f"); tmp=$(mktemp)
    # awk takes the login from its environment: no quoting of what the password holds
    sudo cat "$f" | U="$u" P="$p" awk '
        /^http_(user|pass) *=/ { next }
        { print }
        /^\[GENERAL\]$/ && ENVIRON["U"] != "" { print "http_user = " ENVIRON["U"]; print "http_pass = " ENVIRON["P"] }' > "$tmp"
    sudo install -o "${own%:*}" -g "${own#*:}" -m "$mode" "$tmp" "$f"; rm -f "$tmp"
    DC start lazylibrarian >/dev/null 2>&1 || { wfail "lazylibrarian did not start again — inspect: ./mediastack.sh logs lazylibrarian"; return 1; }
    http_ready lazylibrarian "$(ll_url)/" '^([23][0-9][0-9]|401)$' || return 1
    ll_login_proven "$u" "$p"
}

ll_login_proven() { # ll_login_proven USER PASS — the page refuses a stranger and admits the login ("" "": admits anyone)
    local anon with
    anon=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$(ll_url)/" || true)
    if [[ -z "$1" ]]; then
        [[ "$anon" =~ ^[23] ]] && { ok "lazylibrarian: its own login is off — the portal guards it"; return 0; }
        wfail "lazylibrarian still asks for a login after it was removed (HTTP $anon) — inspect its config.ini"; return 1
    fi
    with=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -u "$1:$2" "$(ll_url)/" || true)
    [[ "$anon" == 401 && "$with" =~ ^[23] ]] && { ok "lazylibrarian: its page asks for the arr login ('$1')"; return 0; }
    wfail "lazylibrarian did not take the login written to its config.ini (no login: HTTP $anon, with it: HTTP $with) — inspect: ./mediastack.sh logs lazylibrarian"
    return 1
}

wire_lazylibrarian() {
    hr "wire: LazyLibrarian"
    svc_enabled lazylibrarian || { info "lazylibrarian not enabled — skipped"; return 0; }
    wire_gate lazylibrarian
    http_ready lazylibrarian "$(ll_url)/" '^([23][0-9][0-9]|401|403)$' || return 0
    local key; key=$(ll_key)
    if [[ -z "$key" ]]; then
        # a fresh LazyLibrarian has its API off and no key; config.ini holds only
        # what differs from its defaults, and is read at start
        w_would "lazylibrarian: switch its API on, with a key of its own" || return 0
        ll_api_enable || return 0
        key=$(ll_key)
    fi
    ok "API key found"
    ll_login || return 0

    # download client: the one the stack uses (DOWNLOAD_CLIENT, as the arrs);
    # wire knows LazyLibrarian's qBittorrent settings only
    local dl; dl=$(role_pick download-client)
    if [[ "$dl" != qbittorrent ]]; then
        warn "lazylibrarian: the stack's download client is ${dl:-none}; wire sets up only qBittorrent in LazyLibrarian — add ${dl:-yours} in its UI (Config -> Downloaders)"
    elif (( WIRE_DRY )); then
        w_would "point lazylibrarian at qBittorrent" || true
    else
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
        fi
    fi
    # book destination on the shared media tree, whichever client downloads
    if (( WIRE_DRY )); then
        w_would "set lazylibrarian's book folders" || true
    else
        ll_api writeCFG "name=EBOOK_DEST_FOLDER&group=General&value=/data/media/books" >/dev/null
        ll_api writeCFG "name=AUDIO_DEST_FOLDER&group=General&value=/data/media/audiobooks" >/dev/null
        ll_api writeCFG "name=DESTINATION_DIR&group=General&value=/data/media/books" >/dev/null
        ok "book folders set (/data/media/books, /data/media/audiobooks)"
        ll_api loadCFG >/dev/null
        ok "config reloaded"
    fi
    info "indexers arrive automatically from Prowlarr (registered in the prowlarr pass)"
}
