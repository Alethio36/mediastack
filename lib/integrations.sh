#!/usr/bin/env bash
# lib/integrations.sh — the service-integration layer: thin per-service API
# wrappers (arr/qbit/jellyfin/seerr/cleanuparr/apprise/...), the idempotent
# `wire` engine that drives them, and their shared globals. Sourced by the
# entrypoint; credentials/trash also call these API wrappers. Relies on
# lib/common.sh primitives and the entrypoint's service/render helpers.

# ================================================================= wire ====
# Idempotent app-to-app configuration: read live state, compare intent
# (labels + .env), apply only the delta. Safe to re-run forever.
WIRE_DRY=0
WIRE_CHANGES=0
WIRE_FAILS=0
wfail() { fail "$@"; WIRE_FAILS=$((WIRE_FAILS+1)); }

w_would() { # w_would "description" -> 0 if execution should proceed
    WIRE_CHANGES=$((WIRE_CHANGES+1))
    if (( WIRE_DRY )); then echo "  would: $1"; return 1; fi
    info "$1"
}

api() { # api METHOD URL APIKEY [json-body] -> body on stdout, rc from http
    local m="$1" u="$2" k="$3" b="${4:-}" out code
    out=$(curl -sS -m 20 -X "$m" -H "X-Api-Key: $k" -H "Content-Type: application/json" \
          ${b:+-d "$b"} -w '\n%{http_code}' "$u" 2>&1) || { echo "$out"; return 1; }
    code=${out##*$'\n'}; echo "${out%$'\n'*}"
    [[ "$code" =~ ^2 ]]
}

arr_key() { # arr_key <svc> -> api key from its config.xml ("" while initialising)
    sudo grep -oP '<ApiKey>\K[^<]+' "$(env_get CONFIG_ROOT)/$1/config.xml" 2>/dev/null | head -1 || true
}

arr_url() { echo "http://127.0.0.1:$(svc_label "$1" mediastack.port)"; }
arr_apiver() { # prowlarr and lidarr speak v1; the content arrs are v3
    [[ "$1" == prowlarr ]] && { echo v1; return; }
    case "$(svc_label "$1" mediastack.arrtype)" in lidarr) echo v1 ;; *) echo v3 ;; esac
}

arr_pretty_name() { # sonarr-anime -> "Sonarr (Anime)", radarr-4k -> "Radarr (4K)"
    local s="$1" ty suffix
    ty=$(svc_label "$s" mediastack.arrtype)
    suffix=${s#"$ty"}; suffix=${suffix#-}
    case "$suffix" in
        "")    echo "${ty^}" ;;
        4k)    echo "${ty^} (4K)" ;;
        anime) echo "${ty^} (Anime)" ;;
        *)     echo "${ty^} (${suffix^})" ;;
    esac
}

arr_instance_name() { # brand the instance so notifications are tellable apart;
                      # only replaces the stock default — a custom name is yours
    local s="$1" key url cur have want
    key=$(arr_key "$s"); [[ -n "$key" ]] || return 0
    url=$(arr_url "$s")
    cur=$(api GET "$url/api/$(arr_apiver "$s")/config/host" "$key" || true)
    have=$(jq -r '.instanceName // empty' <<<"$cur" 2>/dev/null)
    want=$(arr_pretty_name "$s")
    if [[ "$have" == "$want" ]]; then
        ok "$s: instance name '$have'"
    elif [[ -n "$have" && "${have,,}" != "$(svc_label "$s" mediastack.arrtype)" ]]; then
        ok "$s: instance name '$have' (custom) — untouched"
    elif w_would "$s: name the instance '$want' (distinguishes its notifications)"; then
        api PUT "$url/api/$(arr_apiver "$s")/config/host" "$key" \
            "$(jq -c --arg n "$want" '.instanceName=$n' <<<"$cur")" >/dev/null \
            && ok "$s: instance name set to '$want'" \
            || wfail "$s: instance rename rejected — set it in its UI (Settings -> General)"
    fi
}

arr_forms_login() { # shared operator login on an arr-family UI; idempotent
    local s="$1" auser apass key url cur verb=enable
    [[ "${2:-}" == force ]] && verb=rotate
    auser=$(env_get ARR_USER); apass=$(env_get ARR_PASSWORD)
    [[ -n "$auser" && -n "$apass" ]] || { info "$s: shared arr login not set yet — 'wire arr' creates it"; return 0; }
    key=$(arr_key "$s"); [[ -n "$key" ]] || return 0
    url=$(arr_url "$s")
    cur=$(api GET "$url/api/$(arr_apiver "$s")/config/host" "$key" || true)
    if [[ "${2:-}" != force ]] && jq -e --arg u "$auser" '.authenticationMethod=="forms" and .username==$u' <<<"$cur" >/dev/null 2>&1; then
        ok "$s: forms login already set for '$auser'"
    elif w_would "$s: $verb forms login for '$auser'"; then
        api PUT "$url/api/$(arr_apiver "$s")/config/host" "$key" "$(jq -c --arg u "$auser" --arg p "$apass" \
            '.authenticationMethod="forms" | .authenticationRequired="enabled"
             | .username=$u | .password=$p | .passwordConfirmation=$p' <<<"$cur")" >/dev/null \
            && ok "$s: forms login enabled" \
            || wfail "$s: auth setup rejected by the API — set it once in its UI; check: logs $s"
    fi
}

wire_gate() { # refuse to wire what isn't up
    local s missing=""
    for s in "$@"; do
        svc_enabled "$s" || continue
        [[ "$(c_state "$(svc_cname "$s")")" == running ]] || missing+="$s "
    done
    [[ -z "$missing" ]] || die "Cannot wire: not running: $missing
  Start the stack first: ./mediastack.sh up   (then wait for healthy: status)"
}

# shellcheck disable=SC2120  # type argument is optional by design
arr_instances() { # arr_instances [type] -> enabled arr services (optionally by type)
    local s t
    for s in $(svc_managed); do
        svc_enabled "$s" || continue
        t=$(svc_label "$s" mediastack.arrtype)
        [[ -n "$t" ]] || continue
        [[ -z "${1:-}" || "$t" == "$1" ]] && echo "$s"
    done
}

# ---- qbit ----
QB_COOKIE=""
QB_LOGIN_BODY=""
qb_bind_tun0() { # requires QB_COOKIE
    [[ -n "$QB_COOKIE" ]] || { info "no qBittorrent session — interface bind skipped"; return 0; }
    local cur
    cur=$(qb_api /app/preferences | jq -r '.current_network_interface // .network_interface // empty' 2>/dev/null || true)
    if [[ "$cur" == tun0 ]]; then
        ok "transfers bound to tun0"
    elif w_would "bind qBittorrent's transfers to tun0 (VPN interface)"; then
        qb_api /app/setPreferences 'json={"current_network_interface":"tun0"}' >/dev/null
        cur=$(qb_api /app/preferences | jq -r '.current_network_interface // .network_interface // empty' 2>/dev/null || true)
        [[ "$cur" == tun0 ]] && ok "transfers bound to tun0" \
            || wfail "interface bind did not stick (reads back '$cur') — set it in the UI: Advanced -> Network interface"
    fi
}

qb_login() { # rc: 0 = logged in (QB_COOKIE set), 1 = credentials rejected, 2 = unreachable
             # QB_LOGIN_BODY always carries the server's reply / curl error
    local r
    local jar r code
    jar=$(mktemp)
    if ! r=$(curl -sS -m 10 -c "$jar" -w $'\n%{http_code}' \
        --data-urlencode "username=$1" --data-urlencode "password=$2" \
        "http://127.0.0.1:$(svc_label qbittorrent mediastack.port)/api/v2/auth/login" 2>&1); then
        QB_LOGIN_BODY="unreachable: ${r:-<no detail>}"
        rm -f "$jar"; return 2
    fi
    code=${r##*$'\n'}
    QB_LOGIN_BODY="[HTTP ${code}] ${r%%$'\n'*}"; [[ "$QB_LOGIN_BODY" == "[HTTP ${code}] ${code}" ]] && QB_LOGIN_BODY="[HTTP ${code}] <empty body>"
    # qBittorrent >= 5.2 returns 204 on success and names the cookie
    # QBT_SID_<port>; older versions use 200 + "SID". Take name AND value
    # from the jar so we send back exactly what was issued.
    QB_COOKIE=$(awk -F'\t' '$6 ~ /(^|_)SID(_|$)|^SID$/ {print $6"="$7}' "$jar" 2>/dev/null | tail -1 || true)
    rm -f "$jar"
    [[ -n "$QB_COOKIE" ]] || return 1
}
qb_api() { # qb_api PATH [data...] (form-encoded)
    local p="$1"; shift
    local args=(); local a; for a in "$@"; do args+=(--data-urlencode "$a"); done
    curl -sS -m 20 -b "$QB_COOKIE" "${args[@]}" \
        "http://127.0.0.1:$(svc_label qbittorrent mediastack.port)/api/v2$p"
}

wire_qbit() {
    hr "wire: qBittorrent"
    wire_gate qbittorrent
    # auth-free settle: any HTTP status proves the listener (000 = no socket);
    # avoids misreading a boot gap as bad credentials on re-runs
    local qt=0
    while [[ "$(curl -s -m 3 -o /dev/null -w '%{http_code}' \
             "http://127.0.0.1:$(svc_label qbittorrent mediastack.port)/api/v2/app/webapiVersion" 2>/dev/null || echo 000)" == 000 ]]; do
        (( qt >= 45 )) && die "qBittorrent's WebUI never started listening — inspect: ./mediastack.sh logs qbittorrent"
        sleep 3; qt=$((qt+3)); info "qBittorrent WebUI not accepting connections yet (${qt}s)..."
    done
    local user pass gen
    user=$(env_get QBITTORRENT_USER)
    pass=$(env_get QBITTORRENT_PASSWORD)
    if [[ -n "$user" && -n "$pass" ]] && qb_login "$user" "$pass"; then
        ok "credentials from .env work"
    elif (( WIRE_DRY )); then
        w_would "harvest qBittorrent's boot password and set permanent credentials (you pick or accept generated)" || true
        info "category preview needs credentials — computed on the real run"
        return 0
    else
        # No stored credentials: don't forensically read old boots' logs —
        # restart qBittorrent ourselves and watch for the password THIS
        # restart mints. Deterministic: our restart, our time window.
        local tmp="" t=0 qcn ts
        qcn=$(svc_cname qbittorrent)
        info "restarting qBittorrent to mint a fresh temporary password (~20s)..."
        ts=$(date +%s)
        sudo docker restart "$qcn" >/dev/null
        while [[ -z "$tmp" && $t -lt 90 ]]; do
            sleep 5; t=$((t+5))
            # relative window covering everything since our restart
            tmp=$(sudo docker logs --since "$(( $(date +%s) - ts + 2 ))s" "$qcn" 2>&1 \
                  | grep -oP 'temporary password .*: \K\S+' | tail -1 || true)
            [[ -n "$tmp" ]] || info "waiting for qBittorrent to boot (${t}s)..."
        done
        [[ -n "$tmp" ]] || die "qBittorrent printed no temporary password within 90s of a fresh
  restart. Either it already has a password set that isn't in .env
  (set QBITTORRENT_USER/QBITTORRENT_PASSWORD there and re-run), or it
  is failing to boot: ./mediastack.sh logs qbittorrent"
        # the password prints BEFORE the WebUI is fully ready: during warmup
        # it can be unreachable (rc2) OR answer with empty non-auth replies
        # (rc1, empty body). Retry BOTH through the window, evidence inline —
        # a real "Fails." repeated to window-end is still a clean diagnosis.
        local lrc=2 lt=0
        while (( lt < 45 )); do
            if qb_login admin "$tmp"; then lrc=0; break; else lrc=$?; fi
            info "login attempt at ${lt}s: rc=$lrc, server said: $QB_LOGIN_BODY"
            sleep 3; lt=$((lt+3))
        done
        case $lrc in
            0) ok "logged in with the freshly minted password" ;;
            2) die "qBittorrent's WebUI never became reachable on port $(svc_label qbittorrent mediastack.port) within 45s.
  Last state: $QB_LOGIN_BODY
  Inspect: ./mediastack.sh logs qbittorrent" ;;
            *) die "qBittorrent rejected the password it just printed — genuinely unexpected
  (restart clears auth bans, so that isn't it). Server said: $QB_LOGIN_BODY
  Inspect: ./mediastack.sh logs qbittorrent" ;;
        esac
        gen=$(head -c12 /dev/urandom | base64 | tr -d '=+/')
        explain "qBittorrent credentials" \
"Pick the permanent WebUI login. Enter accepts a generated password;
type your own to use it instead. Stored in .env (view: credentials)."
        ask QB_USER "Username" "${user:-admin}"; user="$REPLY_VAL"
        ask_secret "Password" "$gen"; pass="$REPLY_VAL"
        if w_would "set permanent qBittorrent credentials"; then
            qb_api /app/setPreferences \
                "json={\"web_ui_username\":\"$user\",\"web_ui_password\":\"$pass\"}" >/dev/null
            env_set QBITTORRENT_USER "$user"; env_set QBITTORRENT_PASSWORD "$pass"
            sleep 2   # let the preference write settle
            local vrc=0; qb_login "$user" "$pass" || vrc=$?
            (( vrc == 0 )) \
                || die "qBittorrent did not accept the new credentials (rc=$vrc). Server said: $QB_LOGIN_BODY — inspect: logs qbittorrent"
            ok "permanent credentials set and verified"
        fi
    fi
    # bind transfers to the tunnel interface: belt on top of the killswitch —
    # even a firewall wipe inside gluetun cannot make qbit talk past tun0
    qb_bind_tun0
    # categories: one per arr instance, distinct save paths = hardlink discipline
    [[ -n "$QB_COOKIE" ]] || { info "no qBittorrent session — categories skipped"; return 0; }
    local existing s cat
    existing=$(qb_api /torrents/categories || true)
    for s in $(arr_instances); do
        cat=$(svc_label "$s" mediastack.category)
        if grep -q "\"$cat\"" <<<"$existing"; then
            ok "category '$cat' exists"
        elif w_would "create category '$cat' -> /data/torrent/$cat"; then
            qb_api /torrents/createCategory "category=$cat" "savePath=/data/torrent/$cat" >/dev/null \
                && ok "category '$cat' created" \
                || { wfail "category '$cat' creation failed"; }
        fi
    done
    # manual grabs from prowlarr get their own bucket
    if grep -q '"prowlarr"' <<<"$existing"; then
        ok "category 'prowlarr' exists"
    elif w_would "create category 'prowlarr' -> /data/torrent/prowlarr (manual grabs)"; then
        qb_api /torrents/createCategory "category=prowlarr" "savePath=/data/torrent/prowlarr" >/dev/null \
            && ok "category 'prowlarr' created" \
            || wfail "category 'prowlarr' creation failed"
    fi
}

# ---- arr root folders + download client ----
wire_arr() {
    hr "wire: arr instances (root folders + download client)"
    local insts; insts=$(arr_instances)
    [[ -n "$insts" ]] || { info "no arr instances enabled"; return 0; }
    wire_gate $insts
    # --- arr login (the first-run "authentication required" gate) ---
    local auser apass
    auser=$(env_get ARR_USER); apass=$(env_get ARR_PASSWORD)
    if [[ -z "$auser" || -z "$apass" ]]; then
        if (( WIRE_DRY )); then
            w_would "set one shared login on every arr instance (the first-run auth gate)" || true
        else
            explain "Arr login" \
"The arrs refuse to serve their UI until an authentication method and
login are set. One login is used for ALL instances (they share one
operator). Stored in .env (view: credentials)."
            ask ARR_U "Username" "${auser:-admin}"; auser="$REPLY_VAL"
            ask_secret "Password" "$(head -c12 /dev/urandom | base64 | tr -d '=+/')"; apass="$REPLY_VAL"
            env_set ARR_USER "$auser"; env_set ARR_PASSWORD "$apass"
        fi
    fi
    local user pass; user=$(env_get QBITTORRENT_USER); pass=$(env_get QBITTORRENT_PASSWORD)
    if [[ -z "$pass" ]]; then
        if (( WIRE_DRY )); then
            info "download-client previews pend on qBittorrent credentials — they're created earlier in the same real run"
        else
            warn "qBittorrent credentials not set (scoped run?) — download-client wiring skipped; 'wire qbit' or a full 'wire' sets them"
        fi
    fi
    local s key url root t catfield cat cur
    for s in $insts; do
        key=$(arr_key "$s")
        [[ -n "$key" ]] || { wfail "$s: no ApiKey in config.xml yet (still initialising?) — re-run wire in a minute"; continue; }
        url=$(arr_url "$s"); root=$(svc_label "$s" mediastack.rootfolder)
        # authentication (forms login) — idempotent on method+username match
        arr_forms_login "$s"
        arr_instance_name "$s"
        # root folder
        t=$(svc_label "$s" mediastack.arrtype)
        cur=$(api GET "$url/api/$(arr_apiver "$s")/rootfolder" "$key" || true)
        if grep -q "\"path\":\"$root\"" <<<"${cur//[[:space:]]/}"; then
            ok "$s: root folder $root registered"
        elif w_would "$s: register root folder $root"; then
            local rbody rresp
            if [[ "$t" == lidarr ]]; then
                # lidarr root folders carry library defaults (unlike sonarr/radarr);
                # profile IDs 1 = the built-in Standard profiles on a fresh install
                rbody="{\"name\":\"Music\",\"path\":\"$root\",\"defaultMetadataProfileId\":1,\"defaultQualityProfileId\":1,\"defaultMonitorOption\":\"all\",\"defaultTags\":[]}"
            else
                rbody="{\"path\":\"$root\"}"
            fi
            if rresp=$(api POST "$url/api/$(arr_apiver "$s")/rootfolder" "$key" "$rbody"); then
                ok "$s: root folder registered"
            else
                wfail "$s: root folder rejected — API said: $(head -c180 <<<"$rresp")"
            fi
        fi
        # download client
        [[ -n "$pass" ]] || continue
        cat=$(svc_label "$s" mediastack.category)
        case "$t" in sonarr) catfield=tvCategory ;; radarr) catfield=movieCategory ;; lidarr) catfield=musicCategory ;; esac
        cur=$(api GET "$url/api/$(arr_apiver "$s")/downloadclient" "$key" || true)
        if grep -q '"qBittorrent (mediastack)"' <<<"$cur"; then
            ok "$s: download client registered"
        elif w_would "$s: register qBittorrent (category $cat)"; then
            api POST "$url/api/$(arr_apiver "$s")/downloadclient" "$key" "$(cat <<JSON
{"enable":true,"protocol":"torrent","priority":1,
 "removeCompletedDownloads":true,"removeFailedDownloads":true,
 "name":"qBittorrent (mediastack)","implementation":"QBittorrent",
 "implementationName":"qBittorrent","configContract":"QBittorrentSettings",
 "fields":[{"name":"host","value":"localhost"},
   {"name":"port","value":$(svc_label qbittorrent mediastack.port)},
   {"name":"useSsl","value":false},
   {"name":"username","value":"$user"},{"name":"password","value":"$pass"},
   {"name":"$catfield","value":"$cat"}]}
JSON
)" >/dev/null && ok "$s: download client registered" \
              || wfail "$s: download client registration failed — API said no; check: logs $s"
        fi
    done
}

# ---- prowlarr: applications + flaresolverr proxy ----
prowlarr_download_client() { # manual grabs in prowlarr's UI go straight to qbit
    local key url ver have qu qp schema tmpl body resp qport
    key=$(arr_key prowlarr); url=$(arr_url prowlarr); ver=$(arr_apiver prowlarr)
    [[ -n "$key" ]] || { wfail "prowlarr: no ApiKey readable — re-run wire in a minute"; return 1; }
    qu=$(env_get QBITTORRENT_USER); qp=$(env_get QBITTORRENT_PASSWORD)
    [[ -n "$qu" && -n "$qp" ]] || { info "prowlarr download client pends on 'wire qbit' storing credentials"; return 0; }
    qport=$(svc_label qbittorrent mediastack.port)
    have=$(api GET "$url/api/$ver/downloadclient" "$key" | jq -r '[.[].name] | join(" ")' 2>/dev/null || true)
    if [[ " $have " == *" qbittorrent "* ]]; then
        ok "prowlarr download client registered"
        return 0
    fi
    w_would "prowlarr: register qBittorrent as its download client (manual grabs -> category 'prowlarr')" || return 0
    schema=$(api GET "$url/api/$ver/downloadclient/schema" "$key" || true)
    tmpl=$(jq -c '[.[] | select(.implementation=="QBittorrent")][0] // empty' <<<"$schema" 2>/dev/null)
    [[ -n "$tmpl" ]] || { wfail "prowlarr: its API offers no QBittorrent client type — is the image very old?"; return 1; }
    body=$(jq -c --arg u "$qu" --arg p "$qp" --argjson port "$qport" '
        .name = "qbittorrent" | .enable = true
        | .fields = [ .fields[]
            | if   .name == "host"     then .value = "localhost"
              elif .name == "port"     then .value = $port
              elif .name == "username" then .value = $u
              elif .name == "password" then .value = $p
              elif .name == "category" then .value = "prowlarr"
              else . end ]' <<<"$tmpl")
    resp=$(api POST "$url/api/$ver/downloadclient" "$key" "$body") \
        && ok "prowlarr download client registered" \
        || wfail "prowlarr: download client rejected: $(head -c200 <<<"$resp")"
}

ll_url() { echo "http://127.0.0.1:$(env_get LAZYLIBRARIAN_PORT 5299)"; }
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
    local t=0 code
    while :; do
        code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$(ll_url)/" 2>/dev/null || echo 000)
        [[ "$code" =~ ^(2|3)[0-9][0-9]$ || "$code" =~ ^(401|403)$ ]] && break
        (( t >= 90 )) && { wfail "lazylibrarian never became ready within 90s (last: HTTP $code) — inspect: ./mediastack.sh logs lazylibrarian"; return 1; }
        sleep 5; t=$((t+5)); info "waiting for lazylibrarian (${t}s)..."
    done
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

    # download client: qBittorrent, reachable in-namespace at localhost:8085
    (( WIRE_DRY )) && { w_would "point lazylibrarian at qBittorrent and set its book folder" || true; }
    if ! (( WIRE_DRY )); then
        local qu qp qport
        qu=$(env_get QBITTORRENT_USER); qp=$(env_get QBITTORRENT_PASSWORD)
        qport=$(svc_label qbittorrent mediastack.port)
        if [[ -z "$qu" || -z "$qp" ]]; then
            wfail "no qBittorrent credentials in .env — run 'wire qbit' first"
        else
            # LazyLibrarian's qBittorrent settings live in [QBITTORRENT]
            ll_api writeCFG "name=HOST&group=QBITTORRENT&value=http://localhost" >/dev/null
            ll_api writeCFG "name=PORT&group=QBITTORRENT&value=$qport" >/dev/null
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

wire_prowlarr() {
    hr "wire: Prowlarr"
    svc_enabled prowlarr || { info "prowlarr not enabled — skipped"; return 0; }
    wire_gate prowlarr
    local pkey purl; pkey=$(arr_key prowlarr); purl=$(arr_url prowlarr)
    [[ -n "$pkey" ]] || { wfail "prowlarr: no ApiKey yet — re-run wire shortly"; return 0; }
    # prowlarr has no arrtype label so wire_arr's loop never sees it: gate here
    arr_forms_login prowlarr
    local s key t impl cur
    cur=$(api GET "$purl/api/v1/applications" "$pkey" || true)
    for s in $(arr_instances); do
        t=$(svc_label "$s" mediastack.arrtype)
        case "$t" in sonarr) impl=Sonarr ;; radarr) impl=Radarr ;; lidarr) impl=Lidarr ;; *) continue ;; esac
        key=$(arr_key "$s") || true
        [[ -n "$key" ]] || { wfail "prowlarr<-$s: $s has no ApiKey yet"; continue; }
        if grep -q "\"$s (mediastack)\"" <<<"$cur"; then
            ok "prowlarr -> $s registered"
        elif w_would "register $s in prowlarr (Full Sync)"; then
            api POST "$purl/api/v1/applications" "$pkey" "$(cat <<JSON
{"name":"$s (mediastack)","syncLevel":"fullSync",
 "implementation":"$impl","configContract":"${impl}Settings",
 "fields":[{"name":"prowlarrUrl","value":"$purl"},
   {"name":"baseUrl","value":"$(arr_url "$s")"},
   {"name":"apiKey","value":"$key"}]}
JSON
)" >/dev/null && ok "prowlarr -> $s registered (Full Sync)" \
              || wfail "prowlarr -> $s failed — check: logs prowlarr"
        fi
    done
    # LazyLibrarian is a first-class Prowlarr app — register it so its book
    # indexers sync exactly like the arrs (needs its API key from config.ini)
    if svc_enabled lazylibrarian; then
        local llkey
        llkey=$(ll_key)
        if [[ -z "$llkey" ]]; then
            info "prowlarr -> lazylibrarian: skipped (no API key yet — run 'wire lazylibrarian' first)"
        elif grep -q '"LazyLibrarian (mediastack)"' <<<"$cur"; then
            ok "prowlarr -> lazylibrarian registered"
        elif w_would "register lazylibrarian in prowlarr (Full Sync)"; then
            api POST "$purl/api/v1/applications" "$pkey" "$(cat <<JSON
{"name":"LazyLibrarian (mediastack)","syncLevel":"fullSync",
 "implementation":"LazyLibrarian","configContract":"LazyLibrarianSettings",
 "fields":[{"name":"prowlarrUrl","value":"$purl"},
   {"name":"baseUrl","value":"http://localhost:5299"},
   {"name":"apiKey","value":"$llkey"}]}
JSON
)" >/dev/null && ok "prowlarr -> lazylibrarian registered (Full Sync)" \
              || wfail "prowlarr -> lazylibrarian failed — check: logs prowlarr"
        fi
    fi
    if svc_enabled flaresolverr; then
        # tag 'flared': put it on any indexer that needs FlareSolverr and
        # prowlarr routes that indexer through the proxy. Nothing carries it
        # by default — only Cloudflare-protected indexers should pay the tax.
        local fid
        fid=$(api GET "$purl/api/v1/tag" "$pkey" | jq -r '.[] | select(.label=="flared") | .id' 2>/dev/null | head -1 || true)
        if [[ -n "$fid" ]]; then
            ok "tag 'flared' exists"
        elif w_would "create prowlarr tag 'flared' (attach to indexers needing FlareSolverr)"; then
            fid=$(api POST "$purl/api/v1/tag" "$pkey" '{"label":"flared"}' | jq -r '.id' 2>/dev/null || true)
            [[ -n "$fid" && "$fid" != null ]] && ok "tag 'flared' created" \
                || { wfail "prowlarr tag 'flared' creation failed — check: logs prowlarr"; fid=""; }
        fi
        cur=$(api GET "$purl/api/v1/indexerproxy" "$pkey" || true)
        if grep -q '"FlareSolverr (mediastack)"' <<<"$cur"; then
            if [[ -n "$fid" ]] && jq -e --argjson id "$fid" \
                    '.[] | select(.name=="FlareSolverr (mediastack)") | .tags | index($id) | not' \
                    <<<"$cur" >/dev/null 2>&1; then
                if w_would "attach tag 'flared' to the FlareSolverr proxy"; then
                    local fbody
                    fbody=$(jq -c --argjson id "$fid" \
                        '[.[] | select(.name=="FlareSolverr (mediastack)")][0] | .tags += [$id]' <<<"$cur")
                    api PUT "$purl/api/v1/indexerproxy/$(jq -r '.id' <<<"$fbody")" "$pkey" "$fbody" >/dev/null \
                        && ok "flaresolverr proxy tagged 'flared'" \
                        || wfail "could not tag the flaresolverr proxy — check: logs prowlarr"
                fi
            else
                ok "flaresolverr proxy registered"
            fi
        elif w_would "register FlareSolverr as indexer proxy"; then
            api POST "$purl/api/v1/indexerproxy" "$pkey" "$(cat <<JSON
{"name":"FlareSolverr (mediastack)","implementation":"FlareSolverr",
 "configContract":"FlareSolverrSettings","tags":[${fid:-}],
 "fields":[{"name":"host","value":"http://localhost:8191/"},
   {"name":"requestTimeout","value":60}]}
JSON
)" >/dev/null && ok "flaresolverr proxy registered (tag 'flared')" \
              || wfail "flaresolverr proxy registration failed"
        fi
    fi
    prowlarr_download_client
}

# ---- bazarr ----
wire_bazarr() {
    hr "wire: Bazarr"
    svc_enabled bazarr || { info "bazarr not enabled — skipped"; return 0; }
    wire_gate bazarr
    local bkey burl
    bkey=$(sudo grep -oP 'apikey:\s*\K\S+' "$(env_get CONFIG_ROOT)/bazarr/config/config.yaml" 2>/dev/null | head -1 || true)
    [[ -n "$bkey" ]] || { wfail "bazarr: no api key found yet (config/config.yaml) — re-run wire shortly"; return 0; }
    burl="http://127.0.0.1:$(svc_label bazarr mediastack.port)"
    # readiness gate: on a virgin install bazarr is still migrating its DB when
    # wire reaches it and resets the connection (HTTP 000). Poll before posting.
    if (( ! WIRE_DRY )); then
        local waited=0 bprobe
        until bprobe=$(curl -sS -m 5 -o /dev/null -w '%{http_code}' \
                -H "X-API-KEY: $bkey" "$burl/api/system/status" 2>&1) \
                && [[ "$bprobe" == 200 ]]; do
            if (( waited >= 90 )); then
                wfail "bazarr not ready after ${waited}s (last probe: $(head -c120 <<<"$bprobe")) — re-run wire once it settles; check: logs bazarr"
                return 0
            fi
            (( waited == 0 )) && info "waiting for bazarr to come up (budget 90s)..."
            sleep 3; waited=$((waited+3))
        done
    fi
    local pairs=() t skey
    for t in sonarr radarr; do
        svc_enabled "$t" || continue
        skey=$(arr_key "$t"); [[ -n "$skey" ]] || continue
        pairs+=("$t" "$skey")
    done
    (( ${#pairs[@]} )) || { info "no base sonarr/radarr to pair — skipped"; return 0; }
    if w_would "point bazarr at base sonarr/radarr (extra instances are out of bazarr's scope)"; then
        # auth fields exactly ONCE — duplicate form keys become lists on
        # bazarr's side and fail its type validation
        local form=("settings-auth-type=form"
                    "settings-auth-username=$(env_get ARR_USER)"
                    "settings-auth-password=$(env_get ARR_PASSWORD)") i
        for ((i=0; i<${#pairs[@]}; i+=2)); do
            t=${pairs[i]}; skey=${pairs[i+1]}
            form+=("settings-general-use_${t}=true"
                   "settings-${t}-ip=localhost"
                   "settings-${t}-port=$(svc_label "$t" mediastack.port)"
                   "settings-${t}-base_url=/"
                   "settings-${t}-ssl=false"
                   "settings-${t}-apikey=${skey}")
        done
        local args=() a
        for a in "${form[@]}"; do args+=(--data-urlencode "$a"); done
        local bresp bcode
        bresp=$(curl -sS -m 20 -w $'\n%{http_code}' -X POST -H "X-API-KEY: $bkey" \
                "${args[@]}" "$burl/api/system/settings" 2>&1) || bresp="${bresp}"$'\n000'
        bcode=${bresp##*$'\n'}
        if [[ "$bcode" =~ ^2 ]]; then
            ok "bazarr paired with base sonarr/radarr (+ shared login)"
        else
            wfail "bazarr pairing rejected [HTTP $bcode]: $(head -c200 <<<"${bresp%$'\n'*}")
     pair manually meanwhile (Settings -> Sonarr/Radarr) and paste the above"
        fi
    fi
}

jf_plugin_webhook() { # install-if-missing; two consumers: WatchState + the hub
    local tok="$1" plugins
    plugins=$(jf_api GET /Plugins "$tok" | jq -r '[.[].Name] | join(" ")' 2>/dev/null || true)
    if [[ " $plugins " == *" Webhook "* ]]; then
        ok "Webhook plugin installed"
        return 0
    fi
    w_would "install Jellyfin's Webhook plugin (WatchState webhooks + hub notifications need it) and restart jellyfin once" \
        || return 0
    jf_api POST "/Packages/Installed/Webhook?assemblyGuid=71552A5A-5C5C-4350-A2AE-EBE451A30173" "$tok" >/dev/null \
        || { wfail "plugin install rejected [HTTP $(jf_code)] — install in Dashboard -> Plugins -> Catalog"; return 1; }
    info "plugin downloaded — restarting jellyfin to load it..."
    DC restart jellyfin >/dev/null 2>&1 || { wfail "jellyfin restart failed — restart it, then re-run wire jellyfin"; return 1; }
    jf_ready || return 1
    plugins=$(jf_api GET /Plugins "$tok" | jq -r '[.[].Name] | join(" ")' 2>/dev/null || true)
    [[ " $plugins " == *" Webhook "* ]] \
        && ok "Webhook plugin installed and loaded" \
        || wfail "plugin not visible after restart — check Dashboard -> Plugins (a repository fetch may have failed)"
}

jf_server_name() { # the name apps/casting show; container default is the ID hash
    local tok="$1" cfg have want
    cfg=$(jf_api GET /System/Configuration "$tok" || true)
    have=$(jq -r '.ServerName // empty' <<<"$cfg" 2>/dev/null)
    if [[ -n "$have" && ! "$have" =~ ^[0-9a-f]{12}$ ]]; then
        ok "server name '$have'"
        return 0
    fi
    if (( WIRE_DRY )); then w_would "name the Jellyfin server (asked on the real run)" || true; return 0; fi
    [[ -t 0 ]] || { info "server name still the container ID — run 'wire jellyfin' interactively to set it"; return 0; }
    ask JF_SRVNAME "Server name (shows in Jellyfin apps and casting)" "Jellyfin"
    want="$REPLY_VAL"
    jf_api POST /System/Configuration "$tok" "$(jq -c --arg n "$want" '.ServerName=$n' <<<"$cfg")" >/dev/null \
        && ok "server name set to '$want'" \
        || wfail "Jellyfin rejected the server name [HTTP $(jf_code)] — set it in Dashboard -> General"
}

# ---- apprise (wave 5): one notification hub for the whole stack ----
# apprise-api in gluetun's namespace. Tags route messages: ops (pipeline,
# backups, doctor), activity (arr events), users (wizarr invites).
apprise_url() { echo "http://127.0.0.1:$(env_get APPRISE_PORT 8000)"; }

NOTIFY_WARNED=0
notify() { # notify TAG TITLE BODY [TYPE] — never blocks, never fails the caller
    local tag="$1" title="$2" body="$3" type="${4:-info}"
    svc_enabled apprise 2>/dev/null || return 0
    [[ "$(c_state "$(svc_cname apprise)" 2>/dev/null)" == running ]] || return 0
    curl -sS -m 5 -o /dev/null -X POST -H "Content-Type: application/json" \
        -d "$(jq -cn --arg t "$title" --arg b "$body" --arg g "$tag" --arg y "$type" \
             '{title:$t,body:$b,tag:$g,type:$y,format:"markdown"}')" \
        "$(apprise_url)/notify/mediastack" 2>/dev/null && return 0
    if (( ! NOTIFY_WARNED )); then
        warn "apprise unreachable — notification dropped (stack keeps going; check: ./mediastack.sh logs apprise)"
        NOTIFY_WARNED=1
    fi
    return 0
}

wire_apprise() {
    hr "wire: apprise"
    svc_enabled apprise || { info "apprise not enabled — skipped"; return 0; }
    wire_gate apprise
    local t=0 code
    while :; do
        code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$(apprise_url)/status" 2>/dev/null || echo 000)
        [[ "$code" =~ ^2 ]] && break
        (( t >= 90 )) && { wfail "apprise never became ready within 90s (last: HTTP $code) — inspect: ./mediastack.sh logs apprise"; return 1; }
        sleep 5; t=$((t+5)); info "waiting for apprise (${t}s)..."
    done

    # --- notification endpoints: stored once under key 'mediastack';
    # an existing config is never touched (edit in apprise's UI or re-add)
    code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -X POST "$(apprise_url)/get/mediastack" 2>/dev/null || echo 000)
    if [[ "$code" == 200 ]]; then
        ok "notification endpoints configured — untouched (yours to manage; UI: http://<this-host>:$(env_get APPRISE_PORT 8000))"
    elif (( WIRE_DRY )); then
        w_would "store notification endpoints (URLs asked per tag on the real run)" || true
    elif [[ ! -t 0 ]]; then
        info "no notification endpoints stored yet — run './mediastack.sh wire apprise' interactively to add them"
    else
        explain "Notifications (Apprise)" \
"One hub, three streams — give each one or more Apprise URLs
(comma-separated), or leave blank to skip a stream:
  ops       update pipeline, backup failures, doctor problems
  activity  arr grabs, imports, health events
  users     invite activity (wizarr)
Getting a URL:
  Discord   channel -> gear -> Integrations -> Webhooks -> New Webhook
            -> Copy Webhook URL, and paste that https://... URL as-is
  ntfy      pick any unique topic name: ntfy://ntfy.sh/your-topic
            (subscribe to the topic in the ntfy app — zero signup)
  anything  else: https://github.com/caronc/apprise/wiki"
        local ops_u act_u usr_u cfg="" u
        ask AP_OPS "URLs for ops" ""; ops_u="$REPLY_VAL"
        ask AP_ACT "URLs for activity" ""; act_u="$REPLY_VAL"
        ask AP_USR "URLs for users" ""; usr_u="$REPLY_VAL"
        for u in ${ops_u//,/ }; do cfg+="ops=$u"$'\n'; done
        for u in ${act_u//,/ }; do cfg+="activity=$u"$'\n'; done
        for u in ${usr_u//,/ }; do cfg+="users=$u"$'\n'; done
        if [[ -z "$cfg" ]]; then
            info "no URLs given — notifications stay off until 'wire apprise' stores some"
        elif w_would "store the notification endpoints under key 'mediastack'"; then
            local resp acode
            resp=$(curl -sS -m 10 -X POST -H "Content-Type: application/json" \
                   -d "$(jq -cn --arg c "$cfg" '{config:$c,format:"text"}')" \
                   -w $'\n%{http_code}' "$(apprise_url)/add/mediastack" 2>&1) \
                || { wfail "apprise unreachable while storing config: $(head -c200 <<<"$resp")"; return 1; }
            acode=${resp##*$'\n'}
            [[ "$acode" =~ ^2 ]] \
                || { wfail "apprise rejected the config [HTTP $acode]: $(head -c200 <<<"${resp%$'\n'*}")
     check the URL syntax against https://github.com/caronc/apprise/wiki"; return 1; }
            ok "notification endpoints stored"
            notify ops "Mediastack" "Notifications are wired up — this is your ops stream." info
            info "a test notification went to the ops stream — check it arrived"
        fi
    fi

    # --- each arr notifies the hub (tag: activity); create-if-missing by
    # name, schema-driven so per-type event flags stay version-proof
    local s ty key url ver have schema tmpl body resp
    for s in $(arr_instances); do
        ty=$(svc_label "$s" mediastack.arrtype)
        [[ "$ty" == sonarr || "$ty" == radarr || "$ty" == lidarr ]] || continue
        key=$(arr_key "$s"); url=$(arr_url "$s"); ver=$(arr_apiver "$s")
        [[ -n "$key" ]] || { wfail "$s: no ApiKey readable — re-run wire in a minute"; continue; }
        have=$(api GET "$url/api/$ver/notification" "$key" | jq -r '[.[].name] | join(" ")' 2>/dev/null || true)
        if [[ " $have " == *" mediastack-apprise "* ]]; then
            ok "$s already notifies the hub — untouched"
            continue
        fi
        if ! w_would "$s: notify the hub on grab/import/health (tag: activity)"; then continue; fi
        schema=$(api GET "$url/api/$ver/notification/schema" "$key" || true)
        tmpl=$(jq -c '[.[] | select(.implementation=="Apprise")][0] // empty' <<<"$schema" 2>/dev/null)
        [[ -n "$tmpl" ]] || { wfail "$s: its API offers no Apprise notification type — is the image very old?"; continue; }
        body=$(jq -c --arg srv "http://localhost:8000" '
            .name = "mediastack-apprise"
            | .fields = [ .fields[]
                | if .name == "serverUrl"         then .value = $srv
                  elif .name == "configurationKey" then .value = "mediastack"
                  elif .name == "tags"             then .value = ["activity"]
                  else . end ]
            | reduce ("onGrab","onDownload","onUpgrade","onReleaseImport",
                      "onImportComplete","onHealthIssue","onHealthRestored",
                      "onApplicationUpdate") as $k
                (.; if has($k) then .[$k] = true else . end)' <<<"$tmpl")
        resp=$(api POST "$url/api/$ver/notification" "$key" "$body") \
            && ok "$s now notifies the hub" \
            || wfail "$s: notification connection rejected: $(head -c200 <<<"$resp")"
    done
    # prowlarr too — indexer/health events are ops signal
    if svc_enabled prowlarr; then
        key=$(arr_key prowlarr); url=$(arr_url prowlarr); ver=$(arr_apiver prowlarr)
        have=$(api GET "$url/api/$ver/notification" "$key" | jq -r '[.[].name] | join(" ")' 2>/dev/null || true)
        if [[ " $have " == *" mediastack-apprise "* ]]; then
            ok "prowlarr already notifies the hub — untouched"
        elif w_would "prowlarr: notify the hub on indexer/health events (tag: ops)"; then
            schema=$(api GET "$url/api/$ver/notification/schema" "$key" || true)
            tmpl=$(jq -c '[.[] | select(.implementation=="Apprise")][0] // empty' <<<"$schema" 2>/dev/null)
            if [[ -z "$tmpl" ]]; then
                wfail "prowlarr: its API offers no Apprise notification type — is the image very old?"
            else
                body=$(jq -c --arg srv "http://localhost:8000" '
                    .name = "mediastack-apprise"
                    | .fields = [ .fields[]
                        | if .name == "serverUrl"          then .value = $srv
                          elif .name == "configurationKey" then .value = "mediastack"
                          elif .name == "tags"             then .value = ["ops"]
                          else . end ]
                    | reduce ("onHealthIssue","onHealthRestored","onApplicationUpdate") as $k
                        (.; if has($k) then .[$k] = true else . end)' <<<"$tmpl")
                resp=$(api POST "$url/api/$ver/notification" "$key" "$body") \
                    && ok "prowlarr now notifies the hub" \
                    || wfail "prowlarr: notification connection rejected: $(head -c200 <<<"$resp")"
            fi
        fi
    fi
}

# ---- cleanuparr (wave 5) ----
# Bootstrap the account (reusing the stack's arr login), store the API key,
# point it at qBittorrent and every arr, and switch the queue cleaner on
# with its conservative upstream defaults. Existing entries: untouched.
cup_url() { echo "http://127.0.0.1:$(env_get CLEANUPARR_PORT 11011)"; }
CUP_CODE_F="${TMPDIR:-/tmp}/.mediastack-cup-code.$$"
cup_code() { cat "$CUP_CODE_F" 2>/dev/null || echo 000; }
cup_api() { # cup_api METHOD PATH AUTHHDR [json-body] -> body; rc = http 2xx
    local m="$1" p="$2" hdr="$3" b="${4:-}" out code
    if ! out=$(curl -sS -m 20 -X "$m" ${hdr:+-H "$hdr"} -H "Content-Type: application/json" \
          ${b:+-d "$b"} -w $'\n%{http_code}' "$(cup_url)/api$p" 2>&1); then
        printf '000' > "$CUP_CODE_F"; echo "$out"; return 1
    fi
    code=${out##*$'\n'}; printf '%s' "$code" > "$CUP_CODE_F"
    echo "${out%$'\n'*}"
    [[ "$code" =~ ^2 ]]
}

wire_cleanuparr() {
    hr "wire: cleanuparr"
    svc_enabled cleanuparr || { info "cleanuparr not enabled — skipped"; return 0; }
    wire_gate cleanuparr
    local t=0 code
    while :; do
        code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$(cup_url)/health" 2>/dev/null || echo 000)
        [[ "$code" =~ ^2 ]] && break
        (( t >= 90 )) && { wfail "cleanuparr never became ready within 90s (last: HTTP $code) — inspect: ./mediastack.sh logs cleanuparr"; return 1; }
        sleep 5; t=$((t+5)); info "waiting for cleanuparr (${t}s)..."
    done

    local user pass st out
    user=$(env_get ARR_USER); pass=$(env_get ARR_PASSWORD)
    [[ -n "$user" && -n "$pass" ]] || { wfail "cleanuparr bootstrap reuses the arr login — run 'wire arr' first (a full 'wire' does both in order)"; return 1; }

    st=$(cup_api GET /auth/status "" || true)
    if [[ "$(jq -r '.setupCompleted' <<<"$st" 2>/dev/null)" != true ]]; then
        if w_would "create cleanuparr's account ('$user' — same login as the arrs) and complete setup"; then
            out=$(cup_api POST /auth/setup/account "" "$(jq -cn --arg u "$user" --arg p "$pass" '{username:$u,password:$p}')")
            [[ "$(cup_code)" =~ ^2 || "$(cup_code)" == 409 ]] \
                || { wfail "cleanuparr account creation rejected [HTTP $(cup_code)]: $(head -c200 <<<"$out")"; return 1; }
            out=$(cup_api POST /auth/setup/complete "")
            [[ "$(cup_code)" =~ ^2 || "$(cup_code)" == 409 ]] \
                || { wfail "cleanuparr setup completion rejected [HTTP $(cup_code)]: $(head -c200 <<<"$out")"; return 1; }
            ok "account created — sign in with the arr login (view: credentials)"
        fi
    else
        ok "account already set up"
    fi
    (( WIRE_DRY )) && { info "remaining cleanuparr previews pend on signing in — shown on the real run"; return 0; }

    # login -> bearer -> durable API key
    local tok akey
    out=$(cup_api POST /auth/login "" "$(jq -cn --arg u "$user" --arg p "$pass" '{username:$u,password:$p}')") \
        || { wfail "cleanuparr rejected the arr login [HTTP $(cup_code)]: $(head -c200 <<<"$out")
     if you changed its password in the UI, this is expected — its config stays yours"; return 1; }
    tok=$(jq -r '.tokens.accessToken // empty' <<<"$out")
    [[ -n "$tok" ]] || { wfail "cleanuparr login gave no access token: $(head -c200 <<<"$out")"; return 1; }
    akey=$(cup_api GET /account/api-key "Authorization: Bearer $tok" | jq -r '.apiKey // empty' 2>/dev/null || true)
    [[ -n "$akey" ]] || { wfail "could not read cleanuparr's API key [HTTP $(cup_code)]"; return 1; }
    [[ "$(env_get CLEANUPARR_API_KEY)" == "$akey" ]] || env_set CLEANUPARR_API_KEY "$akey"
    local KH="X-Api-Key: $akey"

    # download client: create-if-missing by name
    local qu qp have
    qu=$(env_get QBITTORRENT_USER); qp=$(env_get QBITTORRENT_PASSWORD)
    have=$(cup_api GET /configuration/download_client "$KH" | jq -r '[.clients[]?.name] | join(" ")' 2>/dev/null || true)
    if [[ " $have " == *" qbittorrent "* ]]; then
        ok "qbittorrent already connected — untouched"
    elif [[ -z "$qu" || -z "$qp" ]]; then
        wfail "no qBittorrent credentials in .env — run 'wire qbit' first"
    else
        local dc
        dc=$(jq -cn --arg u "$qu" --arg p "$qp" \
             '{enabled:true,name:"qbittorrent",typeName:"qBittorrent",type:"Torrent",
               host:"http://gluetun:8085",urlBase:"",username:$u,password:$p}')
        out=$(cup_api POST /configuration/download_client/test "$KH" "$dc") \
            || { wfail "cleanuparr could not reach qBittorrent [HTTP $(cup_code)]: $(head -c200 <<<"$out")"; return 1; }
        out=$(cup_api POST /configuration/download_client "$KH" "$dc") \
            && ok "qbittorrent connected" \
            || wfail "qbittorrent entry rejected [HTTP $(cup_code)]: $(head -c200 <<<"$out")"
    fi

    # arrs: create-if-missing by name, per type
    local s ty key port cfg names
    for s in $(arr_instances); do
        ty=$(svc_label "$s" mediastack.arrtype)
        [[ "$ty" == sonarr || "$ty" == radarr || "$ty" == lidarr ]] || continue
        key=$(arr_key "$s"); port=$(svc_label "$s" mediastack.port)
        [[ -n "$key" ]] || { wfail "$s: no ApiKey readable — re-run wire in a minute"; continue; }
        cfg=$(cup_api GET "/configuration/$ty" "$KH" || true)
        names=$(jq -r '[.instances[]?.name] | join(" ")' <<<"$cfg" 2>/dev/null)
        if [[ " $names " == *" $s "* ]]; then
            ok "$s already connected — untouched"
            continue
        fi
        # version = the arr application major, exactly the value cleanuparr's
        # own UI offers per type (sonarr 4, radarr 6, lidarr 3)
        local aver
        case "$ty" in sonarr) aver=4 ;; radarr) aver=6 ;; lidarr) aver=3 ;; esac
        out=$(cup_api POST "/configuration/$ty/instances" "$KH" \
              "$(jq -cn --arg n "$s" --arg u "http://gluetun:$port" --arg k "$key" --argjson v "$aver" \
                 '{enabled:true,name:$n,url:$u,apiKey:$k,version:$v}')") \
            && ok "$s connected" \
            || wfail "$s: cleanuparr rejected it [HTTP $(cup_code)]: $(head -c200 <<<"$out")"
    done

    # queue cleaner: switch on, keep upstream's conservative defaults
    cfg=$(cup_api GET /configuration/queue_cleaner "$KH" || true)
    if [[ "$(jq -r '.enabled' <<<"$cfg" 2>/dev/null)" == true ]]; then
        ok "queue cleaner already on — its settings are yours to manage in the UI"
    elif [[ -n "$cfg" ]]; then
        out=$(cup_api PUT /configuration/queue_cleaner "$KH" "$(jq -c '.enabled = true' <<<"$cfg")") \
            && ok "queue cleaner enabled (conservative defaults — tune in its UI)" \
            || wfail "could not enable the queue cleaner [HTTP $(cup_code)]: $(head -c200 <<<"$out")"
    else
        wfail "could not read the queue-cleaner config [HTTP $(cup_code)]"
    fi

    # ops notifications via the hub, when the hub is wired
    if svc_enabled apprise && [[ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST "$(apprise_url)/get/mediastack" 2>/dev/null || echo 000)" == 200 ]]; then
        have=$(cup_api GET /configuration/notification_providers "$KH" | jq -r '[.providers[]?.name] | join(" ")' 2>/dev/null || true)
        if [[ " $have " == *" mediastack-apprise "* ]]; then
            ok "already notifies the hub — untouched"
        else
            out=$(cup_api POST /configuration/notification_providers/apprise "$KH" \
                  "$(jq -cn '{name:"mediastack-apprise",isEnabled:true,mode:"Api",
                              url:"http://gluetun:8000",key:"mediastack",tags:"ops",
                              onQueueItemDeleted:true,onDownloadCleaned:true,
                              onStalledStrike:true,onFailedImportStrike:true}')") \
                && ok "now notifies the hub (tag: ops)" \
                || wfail "hub connection rejected [HTTP $(cup_code)]: $(head -c200 <<<"$out")"
        fi
    fi
}

# ---- jellyfin (wave 4) ----
# Wire's jellyfin surface is deliberately tiny: complete the first-run wizard
# (once, ever — the API gate closes itself), create libraries whose PATH is
# not yet covered, and mint the stack's API key. It never updates or deletes
# anything: rename/merge/tune libraries in the GUI freely — wire matches by
# path, not name, so it will not recreate or touch them.
JF_AUTH_HDR='Authorization: MediaBrowser Client="mediastack", Device="mediastack", DeviceId="mediastack-wire", Version="1.0"'
# jf_api runs inside $( ) at every call site, so a plain global would be lost
# to the subshell — the last HTTP code crosses back via a per-PID file.
JF_CODE_F="${TMPDIR:-/tmp}/.mediastack-jf-code.$$"
jf_code() { cat "$JF_CODE_F" 2>/dev/null || echo 000; }
jf_url() { echo "http://127.0.0.1:$(svc_label jellyfin mediastack.port)"; }
jf_api() { # jf_api METHOD PATH TOKEN [json-body] -> body on stdout; rc = http 2xx
    local m="$1" p="$2" tok="$3" b="${4:-}" out code
    if ! out=$(curl -sS -m 20 -X "$m" -H "$JF_AUTH_HDR" \
          ${tok:+-H "X-Emby-Token: $tok"} -H "Content-Type: application/json" \
          ${b:+-d "$b"} -w $'\n%{http_code}' "$(jf_url)$p" 2>&1); then
        printf '000' > "$JF_CODE_F"; echo "$out"; return 1
    fi
    code=${out##*$'\n'}; printf '%s' "$code" > "$JF_CODE_F"
    echo "${out%$'\n'*}"
    [[ "$code" =~ ^2 ]]
}
jf_ready() { # container "running" != API "ready"
    local t=0 code
    while :; do
        code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$(jf_url)/health" 2>/dev/null || echo 000)
        [[ "$code" == 200 ]] && return 0
        (( t >= 90 )) && { wfail "jellyfin's API never became ready within 90s (last: HTTP $code) — inspect: ./mediastack.sh logs jellyfin"; return 1; }
        sleep 5; t=$((t+5)); info "waiting for jellyfin's API (${t}s)..."
    done
}
jf_libname() { # default library name for a media subdir
    case "$1" in
        movies)    echo "Movies" ;;
        movies-4k) echo "Movies (4K)" ;;
        tv)        echo "TV Shows" ;;
        tv-anime)  echo "Anime" ;;
        music)     echo "Music" ;;
        *)         echo "${1^}" ;;
    esac
}

wire_jellyfin() {
    hr "wire: jellyfin"
    svc_enabled jellyfin || { info "jellyfin not enabled — skipped"; return 0; }
    wire_gate jellyfin
    jf_ready || return 1
    local pub completed juser jpass
    pub=$(jf_api GET /System/Info/Public "" || true)
    # NB: jq's // operator treats false as missing — read booleans plainly
    completed=$(jq -r '.StartupWizardCompleted' <<<"$pub" 2>/dev/null)
    [[ "$completed" == true || "$completed" == false ]] \
        || { wfail "jellyfin gave no readable public info [HTTP $(jf_code)]: $(head -c200 <<<"$pub")"; return 1; }
    juser=$(env_get JELLYFIN_ADMIN_USER); jpass=$(env_get JELLYFIN_ADMIN_PASSWORD)

    # --- first-run wizard: only ever runs while jellyfin says it is unclaimed.
    # This also closes a real hole: an unconfigured jellyfin lets ANY visitor
    # create the admin account.
    if [[ "$completed" == false ]]; then
        if [[ -z "$juser" || -z "$jpass" ]]; then
            if (( WIRE_DRY )); then
                w_would "complete jellyfin's first-run wizard (admin login asked on the real run)" || true
            elif [[ ! -t 0 ]]; then
                wfail "jellyfin's first-run wizard is incomplete and there is no terminal to ask for the admin login — run './mediastack.sh wire jellyfin' interactively"
                return 1
            else
                explain "Jellyfin admin" \
"Jellyfin needs one administrator account. This is the operator/recovery
login (it also signs in to Seerr as its owner) — your household gets
their own accounts later via invites. Everything else about Jellyfin
(look, libraries' settings, users) stays yours to manage in its GUI;
wire only performs this minimum first-run. Stored in .env (view:
credentials)."
                ask JF_U "Admin username" "${juser:-admin}"; juser="$REPLY_VAL"
                ask_secret "Admin password" "$(head -c12 /dev/urandom | base64 | tr -d '=+/')"; jpass="$REPLY_VAL"
                env_set JELLYFIN_ADMIN_USER "$juser"; env_set JELLYFIN_ADMIN_PASSWORD "$jpass"
            fi
        fi
        if [[ -n "$juser" && -n "$jpass" ]] && w_would "complete jellyfin's first-run wizard (admin '$juser', remote access on, UPnP off)"; then
            local step out
            for step in cfg getuser postuser remote complete; do
                case "$step" in
                    cfg)      out=$(jf_api POST /Startup/Configuration "" '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}') ;;
                    getuser)  out=$(jf_api GET /Startup/User "") ;;  # initialises the first-user record
                    postuser) out=$(jf_api POST /Startup/User "" "$(jq -cn --arg u "$juser" --arg p "$jpass" '{Name:$u,Password:$p}')") ;;
                    remote)   out=$(jf_api POST /Startup/RemoteAccess "" '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}') ;;
                    complete) out=$(jf_api POST /Startup/Complete "") ;;
                esac || { wfail "jellyfin wizard step '$step' rejected [HTTP $(jf_code)]: $(head -c200 <<<"$out")"; return 1; }
            done
            ok "first-run wizard completed — admin '$juser'"
        fi
    else
        ok "first-run wizard already completed"
    fi

    # --- everything below needs an admin session
    if [[ -z "$juser" || -z "$jpass" ]]; then
        if (( WIRE_DRY )); then
            info "library/API-key previews pend on the admin login — created earlier in the same real run"
        else
            info "jellyfin was configured outside wire and no JELLYFIN_ADMIN_USER/PASSWORD is in .env — libraries and the stack API key stay manual (set them in .env to let wire manage those)"
        fi
        return 0
    fi
    local auth tok
    auth=$(jf_api POST /Users/AuthenticateByName "" "$(jq -cn --arg u "$juser" --arg p "$jpass" '{Username:$u,Pw:$p}')") \
        || { (( WIRE_DRY )) && { info "cannot verify further without logging in — real run continues from here"; return 0; }
             wfail "jellyfin rejected the admin login from .env [HTTP $(jf_code)]: $(head -c200 <<<"$auth")"; return 1; }
    tok=$(jq -r '.AccessToken // empty' <<<"$auth")
    [[ -n "$tok" ]] || { wfail "jellyfin login succeeded but returned no token: $(head -c200 <<<"$auth")"; return 1; }
    jf_server_name "$tok"
    jf_plugin_webhook "$tok"

    # --- libraries: create-if-path-missing, derived from the arrs' own
    # rootfolder labels. Match by PATH so GUI renames/merges are respected.
    local vf droot; vf=$(jf_api GET /Library/VirtualFolders "$tok" || true)
    [[ "$(jf_code)" =~ ^2 ]] || { wfail "could not list jellyfin libraries [HTTP $(jf_code)]: $(head -c200 <<<"$vf")"; return 1; }
    droot=$(env_get DATA_ROOT)
    local -A seen=()
    local s rf base path ctype lname enc_n enc_p resp
    for s in $(arr_instances); do
        rf=$(svc_label "$s" mediastack.rootfolder); base=${rf##*/}
        [[ -n "$base" && -z "${seen[$base]:-}" ]] || continue; seen[$base]=1
        path="/media/$base"
        case "$(svc_label "$s" mediastack.arrtype)" in
            radarr) ctype=movies ;; sonarr) ctype=tvshows ;; lidarr) ctype=music ;; *) continue ;;
        esac
        if jq -e --arg p "$path" 'any(.[].Locations[]?; . == $p)' <<<"$vf" >/dev/null 2>&1; then
            ok "a library already covers $path — untouched (yours to manage in the GUI)"
            continue
        fi
        if (( WIRE_DRY )); then
            w_would "create jellyfin library for $path (${ctype}; name asked on the real run)" || true
            continue
        fi
        if [[ ! -t 0 ]]; then
            info "$path has no library yet — creation asks for a name, so it only happens interactively: ./mediastack.sh wire jellyfin"
            continue
        fi
        # jellyfin sees /media read-only; the host dir must exist or the
        # library is born broken. Same ownership pattern as configure's tree.
        sudo test -d "$droot/media/$base" \
            || { sudo install -d -m 2775 -g mediacenter "$droot/media/$base" && info "created $droot/media/$base (was missing)"; }
        ask JF_LN "Library name for $path" "$(jf_libname "$base")"; lname="$REPLY_VAL"
        if w_would "create jellyfin library '$lname' -> $path"; then
            enc_n=$(jq -rn --arg v "$lname" '$v|@uri'); enc_p=$(jq -rn --arg v "$path" '$v|@uri')
            resp=$(jf_api POST "/Library/VirtualFolders?name=${enc_n}&collectionType=${ctype}&paths=${enc_p}&refreshLibrary=true" "$tok" '{"LibraryOptions":{}}') \
                && ok "library '$lname' created" \
                || wfail "library '$lname' rejected [HTTP $(jf_code)]: $(head -c200 <<<"$resp")"
        fi
    done

    # --- one API key for the stack (update-defer streaming check + doctor)
    local keys have
    keys=$(jf_api GET /Auth/Keys "$tok" || true)
    have=$(jq -r '.Items[]? | select(.AppName=="mediastack") | .AccessToken' <<<"$keys" 2>/dev/null | head -1)
    if [[ -n "$have" ]]; then
        [[ "$(env_get JELLYFIN_API_KEY)" == "$have" ]] || env_set JELLYFIN_API_KEY "$have"
        ok "stack API key present"
    elif w_would "mint a jellyfin API key for the stack (app 'mediastack')"; then
        jf_api POST "/Auth/Keys?app=mediastack" "$tok" >/dev/null \
            || { wfail "API key creation rejected [HTTP $(jf_code)]"; return 1; }
        keys=$(jf_api GET /Auth/Keys "$tok" || true)
        have=$(jq -r '.Items[]? | select(.AppName=="mediastack") | .AccessToken' <<<"$keys" 2>/dev/null | head -1)
        [[ -n "$have" ]] || { wfail "API key created but not readable back — check Dashboard -> API Keys"; return 1; }
        env_set JELLYFIN_API_KEY "$have"
        ok "stack API key minted and stored (JELLYFIN_API_KEY)"
    fi
}

# ---- seerr (wave 4) ----
# Seerr federates auth to jellyfin (users sign in with their jellyfin logins;
# no seerr-local passwords exist here). Wire bootstraps an UNINITIALISED
# seerr only: first sign-in as the jellyfin admin (which creates seerr's
# owner), library sync + enable, one server entry per arr, initialise. An
# initialised seerr is never touched — its settings are GUI territory.
seerr_url() { echo "http://127.0.0.1:$(svc_label seerr mediastack.port)"; }
SEERR_CODE_F="${TMPDIR:-/tmp}/.mediastack-seerr-code.$$"
seerr_code() { cat "$SEERR_CODE_F" 2>/dev/null || echo 000; }
seerr_api() { # seerr_api METHOD PATH JAR [json-body] -> body; rc = http 2xx
    local m="$1" p="$2" jar="$3" b="${4:-}" out code
    if ! out=$(curl -sS -m 30 -X "$m" -b "$jar" -c "$jar" -H "Content-Type: application/json" \
          ${b:+-d "$b"} -w $'\n%{http_code}' "$(seerr_url)/api/v1$p" 2>&1); then
        printf '000' > "$SEERR_CODE_F"; echo "$out"; return 1
    fi
    code=${out##*$'\n'}; printf '%s' "$code" > "$SEERR_CODE_F"
    echo "${out%$'\n'*}"
    [[ "$code" =~ ^2 ]]
}

wire_seerr() {
    hr "wire: seerr"
    svc_enabled seerr || { info "seerr not enabled — skipped"; return 0; }
    svc_enabled jellyfin || { wfail "seerr is enabled but jellyfin is not — seerr cannot function without it"; return 1; }
    wire_gate seerr jellyfin
    local t=0 code
    while :; do
        code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$(seerr_url)/api/v1/status" 2>/dev/null || echo 000)
        [[ "$code" == 200 ]] && break
        (( t >= 90 )) && { wfail "seerr's API never became ready within 90s (last: HTTP $code) — inspect: ./mediastack.sh logs seerr"; return 1; }
        sleep 5; t=$((t+5)); info "waiting for seerr's API (${t}s)..."
    done
    local jar pub
    jar=$(mktemp)
    pub=$(seerr_api GET /settings/public "$jar" || true)
    local seerr_initialized=false
    [[ "$(jq -r '.initialized' <<<"$pub" 2>/dev/null)" == true ]] && seerr_initialized=true
    local juser jpass
    juser=$(env_get JELLYFIN_ADMIN_USER); jpass=$(env_get JELLYFIN_ADMIN_PASSWORD)
    if [[ -z "$juser" || -z "$jpass" ]]; then
        if (( WIRE_DRY )); then
            w_would "bootstrap seerr (sign in as the jellyfin admin, sync + enable libraries, add the arrs, initialise)" || true
        else
            wfail "seerr bootstrap needs the jellyfin admin login — run 'wire jellyfin' first (a full 'wire' does both in order)"
        fi
        rm -f "$jar"; return 0
    fi
    if $seerr_initialized; then
        # initialised = its settings are yours; wire only CREATES missing arr
        # entries (matched by name), mirroring the jellyfin library contract
        if ! w_would "verify seerr's arr entries (create missing only — nothing existing is touched)"; then rm -f "$jar"; return 0; fi
    else
        if ! w_would "bootstrap seerr: jellyfin sign-in ('$juser'), libraries, arr servers, initialise"; then rm -f "$jar"; return 0; fi
    fi

    # the API demands the hostname iff seerr does not have one yet: a prior
    # partial bootstrap leaves it stored, and re-sending it is a hard 500
    local jfport out
    jfport=$(svc_label jellyfin mediastack.port)
    out=$(seerr_api POST /auth/jellyfin "$jar" "$(jq -cn --arg u "$juser" --arg p "$jpass" --argjson port "$jfport" \
          '{username:$u,password:$p,hostname:"jellyfin",port:$port,useSsl:false,urlBase:"",serverType:2}')") || {
        if grep -q "already configured" <<<"$out"; then
            $seerr_initialized || info "seerr already holds the jellyfin hostname (earlier attempt) — signing in without it"
            out=$(seerr_api POST /auth/jellyfin "$jar" "$(jq -cn --arg u "$juser" --arg p "$jpass" \
                  '{username:$u,password:$p,serverType:2}')") \
                || { wfail "seerr rejected the jellyfin sign-in [HTTP $(seerr_code)]: $(head -c200 <<<"$out")"; rm -f "$jar"; return 1; }
        else
            wfail "seerr rejected the jellyfin sign-in [HTTP $(seerr_code)]: $(head -c200 <<<"$out")"; rm -f "$jar"; return 1
        fi
    }
    ok "signed in — seerr owner is jellyfin admin '$juser'"

    if ! $seerr_initialized; then
    # v3.4.1 API: ?sync=true fetches from jellyfin and returns the list;
    # ?enable=<csv-ids> declares the complete enabled set in one call
    local libs ids n
    libs=$(seerr_api GET "/settings/jellyfin/library?sync=true" "$jar") \
        || { wfail "library sync failed [HTTP $(seerr_code)]: $(head -c200 <<<"$libs")"; rm -f "$jar"; return 1; }
    ids=$(jq -r '[.[].id] | join(",")' <<<"$libs" 2>/dev/null)
    [[ -n "$ids" ]] || { wfail "seerr returned no libraries from jellyfin — are the libraries created? re-run 'wire jellyfin' first: $(head -c200 <<<"$libs")"; rm -f "$jar"; return 1; }
    libs=$(seerr_api GET "/settings/jellyfin/library?enable=$ids" "$jar") \
        || { wfail "enabling libraries failed [HTTP $(seerr_code)]: $(head -c200 <<<"$libs")"; rm -f "$jar"; return 1; }
    n=$(jq '[.[] | select(.enabled)] | length' <<<"$libs" 2>/dev/null)
    ok "libraries synced — ${n:-0} enabled"
    fi

    # one server entry per arr instance, connection details straight from the
    # stack's own labels/keys. The arrs live in gluetun's network namespace,
    # so 'gluetun' is their in-network hostname. Existing entries (matched by
    # name) are never touched — create-if-missing only.
    local have_radarr have_sonarr
    have_radarr=$(seerr_api GET /settings/radarr "$jar" | jq -r '[.[].name] | join(" ")' 2>/dev/null || true)
    have_sonarr=$(seerr_api GET /settings/sonarr "$jar" | jq -r '[.[].name] | join(" ")' 2>/dev/null || true)
    local s ty key port root profs pid pname body ep is4k
    for s in $(arr_instances); do
        ty=$(svc_label "$s" mediastack.arrtype)
        [[ "$ty" == radarr || "$ty" == sonarr ]] || { info "$s: seerr does not manage $ty — skipped"; continue; }
        if [[ "$ty" == radarr && " $have_radarr " == *" $s "* ]] || [[ "$ty" == sonarr && " $have_sonarr " == *" $s "* ]]; then
            ok "$s already in seerr — untouched (yours to manage in the GUI)"
            continue
        fi
        key=$(arr_key "$s"); port=$(svc_label "$s" mediastack.port); root=$(svc_label "$s" mediastack.rootfolder)
        [[ -n "$key" ]] || { wfail "$s: no ApiKey readable — is it initialised? re-run wire in a minute"; continue; }
        profs=$(api GET "$(arr_url "$s")/api/$(arr_apiver "$s")/qualityprofile" "$key" || true)
        pid=$(jq -r --arg n "$(env_get "TRASH_PROFILE_$(uvar "$s")")" \
              '(map(select(.name==$n)) + .)[0].id // empty' <<<"$profs" 2>/dev/null)
        pname=$(jq -r --arg n "$(env_get "TRASH_PROFILE_$(uvar "$s")")" \
              '(map(select(.name==$n)) + .)[0].name // empty' <<<"$profs" 2>/dev/null)
        [[ -n "$pid" ]] || { wfail "$s: could not read a quality profile from its API — seerr entry skipped"; continue; }
        is4k=false; [[ "$s" == *-4k ]] && is4k=true
        body=$(jq -cn --arg name "$s" --argjson port "$port" --arg key "$key" \
                     --argjson pid "$pid" --arg pname "$pname" --arg root "$root" --argjson is4k "$is4k" \
              '{name:$name,hostname:"gluetun",port:$port,apiKey:$key,useSsl:false,baseUrl:"",
                activeProfileId:$pid,activeProfileName:$pname,activeDirectory:$root,
                tags:[],is4k:$is4k,isDefault:true,syncEnabled:true,preventSearch:false,
                tagRequests:false,overrideRule:[]}')
        ep="/settings/$ty"
        [[ "$ty" == radarr ]] && body=$(jq -c '. + {minimumAvailability:"released"}' <<<"$body")
        [[ "$ty" == sonarr ]] && body=$(jq -c '. + {enableSeasonFolders:true}' <<<"$body")
        [[ "$s" == sonarr-anime ]] && body=$(jq -c '. + {isDefault:false}' <<<"$body")
        out=$(seerr_api POST "$ep/test" "$jar" "$body") \
            || { wfail "$s: seerr could not reach it [HTTP $(seerr_code)]: $(head -c200 <<<"$out")"; continue; }
        out=$(seerr_api POST "$ep" "$jar" "$body") \
            && ok "$s added to seerr (profile '$pname'${is4k:+, 4k=$is4k})" \
            || wfail "$s: seerr rejected the server entry [HTTP $(seerr_code)]: $(head -c200 <<<"$out")"
    done

    # request/media events -> the hub (tag: activity), when the hub is wired.
    # An enabled webhook agent (whatever it points at) is never overwritten.
    if svc_enabled apprise && [[ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST "$(apprise_url)/get/mediastack" 2>/dev/null || echo 000)" == 200 ]]; then
        local wh
        wh=$(seerr_api GET /settings/notifications/webhook "$jar" || true)
        if [[ "$(jq -r '.enabled' <<<"$wh" 2>/dev/null)" == true ]]; then
            ok "webhook notifications already enabled — untouched (yours to manage in the GUI)"
        elif w_would "notify the hub on requests/approvals/availability (tag: activity)"; then
            out=$(seerr_api POST /settings/notifications/webhook "$jar" "$(jq -cn '
                {enabled:true, embedPoster:false, types:222,
                 options:{webhookUrl:"http://gluetun:8000/notify/mediastack",
                          authHeader:"",
                          jsonPayload:"{\"title\":\"Seerr\",\"body\":\"{{event}}\\n{{subject}}\\n{{message}}\",\"tag\":\"activity\",\"type\":\"info\"}"}}')") \
                && ok "seerr now notifies the hub" \
                || wfail "seerr rejected the webhook agent [HTTP $(seerr_code)]: $(head -c200 <<<"$out")"
        fi
    fi
    if $seerr_initialized; then
        rm -f "$jar"
        ok "seerr arr entries verified"
        return 0
    fi
    out=$(seerr_api POST /settings/initialize "$jar") \
        || { wfail "seerr initialise call failed [HTTP $(seerr_code)]: $(head -c200 <<<"$out")"; rm -f "$jar"; return 1; }
    local skey
    skey=$(seerr_api GET /settings/main "$jar" | jq -r '.apiKey // empty' 2>/dev/null || true)
    [[ -n "$skey" ]] && env_set SEERR_API_KEY "$skey"
    rm -f "$jar"
    ok "seerr initialised — users sign in with their jellyfin logins"
}

# ---- wizarr (wave 4) ----
# Wizarr's admin account, jellyfin connection, and API keys are web-UI-only
# by upstream design — no bootstrap API exists. One documented first-run in
# the UI, then wire holds the API key and './mediastack.sh invite' does the
# rest forever.
wizarr_url() { echo "http://127.0.0.1:$(svc_label wizarr mediastack.port)"; }

wire_wizarr() {
    hr "wire: wizarr"
    svc_enabled wizarr || { info "wizarr not enabled — skipped"; return 0; }
    wire_gate wizarr
    local t=0 code
    while :; do
        code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$(wizarr_url)/health" 2>/dev/null || echo 000)
        # a virgin wizarr 302s /health to /setup (onboarding middleware) —
        # any 2xx/3xx means the app is up and serving
        [[ "$code" =~ ^[23] ]] && break
        (( t >= 90 )) && { wfail "wizarr never became ready within 90s (last: HTTP $code) — inspect: ./mediastack.sh logs wizarr"; return 1; }
        sleep 5; t=$((t+5)); info "waiting for wizarr (${t}s)..."
    done
    local key host domain
    key=$(env_get WIZARR_API_KEY)
    if [[ -z "$key" ]]; then
        if (( WIRE_DRY )); then
            w_would "store + verify a wizarr API key (pasted by you after wizarr's one-time UI first-run)" || true
            return 0
        fi
        if [[ ! -t 0 ]]; then
            info "no WIZARR_API_KEY yet — wizarr's first-run is a one-time UI step; run './mediastack.sh wire wizarr' interactively after it"
            return 0
        fi
        host=$(env_get WIZARR_HOST invites); domain=$(env_get TRAEFIK_DOMAIN)
        local jfkey; jfkey=$(env_get JELLYFIN_API_KEY "(empty — run 'wire jellyfin' first to mint it)")
        explain "Wizarr first-run (one-time, in its UI)" \
"Wizarr's admin account and API keys can only be created in its web UI —
there is no automation API for this by upstream design. Once, ever:
  1. open ${domain:+https://$host.$domain (or }http://<this-host>:$(svc_label wizarr mediastack.port)${domain:+)}
  2. create the admin account
  3. Settings -> Servers -> Add Server:
       Name            jellyfin
       Server Type     Jellyfin
       URL (Internal)  http://jellyfin:8096
       API Key         $jfkey
     then Test & Add
  4. Settings -> API Keys -> create one, and paste it below
Paste nothing to skip for now — re-run 'wire wizarr' any time."
        ask_token "Wizarr API key (input is hidden; empty = skip)" ""
        key="$REPLY_VAL"
        [[ -n "$key" ]] || { info "skipped — invites stay in wizarr's UI until a key is stored"; return 0; }
        env_set WIZARR_API_KEY "$key"
    fi
    local out
    if ! out=$(curl -sS -m 15 -H "X-API-Key: $key" -w $'\n%{http_code}' "$(wizarr_url)/api/invitations" 2>&1); then
        wfail "wizarr unreachable while verifying the API key: $(head -c200 <<<"$out")"; return 1
    fi
    code=${out##*$'\n'}
    if [[ "$code" =~ ^2 ]]; then
        ok "API key verified — mint invites with: ./mediastack.sh invite"
    else
        wfail "wizarr rejected the stored API key [HTTP $code] — recreate it in Settings -> API Keys, then re-run 'wire wizarr' (the old value stays in .env until replaced)"
        return 1
    fi
}

cmd_wire() {
    load_env; render
    local section="all"
    while [[ $# -gt 0 ]]; do case "$1" in
        --dry-run) WIRE_DRY=1; shift ;;
        qbit|arr|prowlarr|bazarr|apprise|cleanuparr|lazylibrarian|jellyfin|seerr|wizarr|all) section="$1"; shift ;;
        *) die "usage: wire [qbit|arr|prowlarr|bazarr|apprise|cleanuparr|lazylibrarian|jellyfin|seerr|wizarr] [--dry-run]" ;;
    esac; done
    (( WIRE_DRY )) && hr "wire --dry-run: showing changes, touching nothing"
    if (( ! WIRE_DRY )) && [[ ! -f "$SCRIPT_DIR/.wired" ]]; then
        if confirm "First wire on this deployment — take a restore point first? (recommended)"; then
            cmd_backup
            # the backup bounced every container — let the apps come back
            # before wiring their APIs
            info "waiting for services to settle after the restore point (up to 120s)..."
            local wt=0 pending_s
            while (( wt < 120 )); do
                pending_s=""
                for s in qbittorrent prowlarr bazarr apprise cleanuparr lazylibrarian jellyfin seerr wizarr $(arr_instances); do
                    svc_enabled "$s" || continue
                    case "$(c_health "$(svc_cname "$s")")" in
                        healthy|-) : ;;
                        *) pending_s+="$s " ;;
                    esac
                done
                [[ -z "$pending_s" ]] && break
                sleep 5; wt=$((wt+5))
            done
            [[ -z "$pending_s" ]] && ok "services settled" \
                || warn "still settling: $pending_s— wiring anyway; anything that refuses gets a per-item FAIL and a re-run picks it up"
        fi
    fi
    case "$section" in
        qbit)     wire_qbit ;;
        arr)      wire_arr ;;
        prowlarr) wire_prowlarr ;;
        bazarr)   wire_bazarr ;;
        apprise)  wire_apprise ;;
        cleanuparr) wire_cleanuparr ;;
        lazylibrarian) wire_lazylibrarian ;;
        jellyfin) wire_jellyfin ;;
        seerr)    wire_seerr ;;
        wizarr)   wire_wizarr ;;
        # order matters: seerr signs in via jellyfin's admin; wizarr's UI
        # first-run wants jellyfin claimed first
        all)      wire_qbit; wire_arr; wire_prowlarr; wire_bazarr; wire_apprise; wire_cleanuparr; wire_lazylibrarian; wire_jellyfin; wire_seerr; wire_wizarr ;;
    esac
    echo
    if (( WIRE_DRY )); then
        info "dry-run complete: $WIRE_CHANGES change(s) would be applied. Run without --dry-run to apply."
        info "note: items marked as pending on credentials resolve mid-run — the real run creates them in order."
    else
        touch "$SCRIPT_DIR/.wired"
        if (( WIRE_FAILS )); then
            fail "wire finished with $WIRE_FAILS failure(s) — see the FAIL lines above. Re-run after fixing; completed items just skip."
            exit 1
        fi
        ok "wire complete. Verify: ./mediastack.sh doctor   Credentials: ./mediastack.sh credentials"
    fi
}
