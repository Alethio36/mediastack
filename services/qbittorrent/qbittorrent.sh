#!/usr/bin/env bash
# services/qbittorrent/qbittorrent.sh — qBittorrent's API client (login,
# tun0 bind), its `wire qbit` role, and the login fields an arr's
# download-client entry for it carries.
# Sourced by the entrypoint; relies on lib/wire.sh, lib/addr.sh and the
# entrypoint's helpers at call time.

qbit_login_fields() { # qbit_login_fields <list JSON> <entry name> -> the login to (re)send, one field per line
    # none when the entry authenticates by qBittorrent API key: Sonarr, Radarr
    # and Prowlarr reject an entry holding a key AND a username/password
    [[ -n "$(arr_entry_field "$1" "$2" apiKey)" ]] && return 0
    printf '%s\n' "username=$(env_get QBITTORRENT_USER)" "password=$(env_get QBITTORRENT_PASSWORD)"
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
        qb_api /app/setPreferences 'json={"current_network_interface":"tun0"}' >/dev/null || true  # read-back below is the verdict
        cur=$(qb_api /app/preferences | jq -r '.current_network_interface // .network_interface // empty' 2>/dev/null || true)
        [[ "$cur" == tun0 ]] && ok "transfers bound to tun0" \
            || wfail "interface bind did not stick (reads back '$cur') — set it in the UI: Advanced -> Network interface"
    fi
}

qb_url() { local p; p=$(svc_hostport qbittorrent) || return 1; echo "http://127.0.0.1:$p"; }
qb_login() { # rc: 0 = logged in (QB_COOKIE set), 1 = credentials rejected, 2 = unreachable
             # QB_LOGIN_BODY always carries the server's reply / curl error
    local r
    local jar r code
    jar=$(mktemp)
    if ! r=$(curl -sS -m 10 -c "$jar" -w $'\n%{http_code}' \
        --data-urlencode "username=$1" --data-urlencode "password=$2" \
        "$(qb_url)/api/v2/auth/login" 2>&1); then
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
qb_api() { # qb_api PATH [data...] (form-encoded) -> body on stdout, rc from http
    local p="$1"; shift
    local args=(); local a; for a in "$@"; do args+=(--data-urlencode "$a"); done
    local out code
    out=$(curl -sS -m 20 -b "$QB_COOKIE" "${args[@]}" -w '\n%{http_code}' \
          "$(qb_url)/api/v2$p" 2>&1) || { echo "$out"; return 1; }
    code=${out##*$'\n'}; echo "${out%$'\n'*}"
    [[ "$code" =~ ^2 ]]
}

wire_qbit() {
    hr "wire: qBittorrent"
    wire_gate qbittorrent
    # auth-free settle: any HTTP status proves the listener (000 = no socket);
    # avoids misreading a boot gap as bad credentials on re-runs
    http_ready qbittorrent "$(qb_url)/api/v2/app/webapiVersion" '^[1-9]' \
        || die "cannot wire qBittorrent without its WebUI (see above)"
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
        # shellcheck disable=SC2034  # the inspect cache lives in the entrypoint (CACHE RULE at c_inspect)
        INSPECT_JSON=""
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
            2) die "qBittorrent's WebUI never became reachable on port $(svc_port qbittorrent) within 45s.
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
                "json={\"web_ui_username\":\"$user\",\"web_ui_password\":\"$pass\"}" >/dev/null || true  # re-login below is the verdict
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
    local existing s cat cexists
    existing=$(qb_api /torrents/categories || true)
    for s in $(arr_instances); do
        cat=$(svc_label "$s" mediastack.category)
        cexists=no; grep -q "\"$cat\"" <<<"$existing" && cexists=yes
        ensure_resource "$cexists" "create category '$cat' -> /data/torrent/$cat" \
            "category '$cat' exists" "category '$cat' creation failed" \
            -- qb_api /torrents/createCategory "category=$cat" "savePath=/data/torrent/$cat"
    done
    # manual grabs from prowlarr get their own bucket
    cexists=no; grep -q '"prowlarr"' <<<"$existing" && cexists=yes
    ensure_resource "$cexists" "create category 'prowlarr' -> /data/torrent/prowlarr (manual grabs)" \
        "category 'prowlarr' exists" "category 'prowlarr' creation failed" \
        -- qb_api /torrents/createCategory "category=prowlarr" "savePath=/data/torrent/prowlarr"
}
