#!/usr/bin/env bash
# services/qbittorrent/qbittorrent.sh — qBittorrent's API client (login,
# tun0 bind) and its `wire qbit` role. How the arrs, Prowlarr and Cleanuparr
# reach it as a download client: provides/download-client.<consumer>.json.
# Sourced by the entrypoint; relies on lib/wire.sh, lib/addr.sh and the
# entrypoint's helpers at call time.

qbittorrent_logins() { printf "qBittorrent's WebUI\tQBITTORRENT_USER\tQBITTORRENT_PASSWORD\tuser_min=3\n"; }   # lib/logins.sh; its WebUI refuses a shorter name

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

# Behind a trusted portal gate its WebUI asks no login of the people the gate
# let through: requests from Traefik's fixed address skip it ("bypass
# authentication for clients in whitelisted IP subnets", that one address).
# Every other caller — the script, the arrs, Cleanuparr — still signs in.
# Reverse-proxy support must stay off: with it on, qBittorrent takes the
# client's address from X-Forwarded-For, which a client can write itself
# (webapplication.cpp resolveClientAddress). docs/design-logins.md.
qb_gate_want() { # -> the preferences qBittorrent should hold for the gate (JSON): the bypass for Traefik alone when gate_trusted, off otherwise
    if gate_trusted qbittorrent; then
        jq -cn --arg s "$(env_get TRAEFIK_ADDRESS)/32" '{bypass_auth_subnet_whitelist_enabled: true, bypass_auth_subnet_whitelist: $s, web_ui_reverse_proxy_enabled: false}'
    else
        jq -cn '{bypass_auth_subnet_whitelist_enabled: false}'
    fi
}
qb_gate_trust() { # requires QB_COOKIE — the gate's bypass set (or taken away), read back
    [[ -n "$QB_COOKIE" ]] || { info "no qBittorrent session — its portal sign-in skipped"; return 0; }
    local cur want ours
    cur=$(qb_api /app/preferences) || { wfail "qbittorrent: its preferences are unreadable — its portal sign-in unchecked: $(oneline "$cur")"; return 0; }
    want=$(qb_gate_want)
    ours="$(env_get TRAEFIK_ADDRESS)/32"
    if ! gate_trusted qbittorrent; then
        # only the stack's own bypass is taken away; a whitelist someone set up themselves stays —
        # but one that covers Traefik's address lets anyone through Traefik in without a login
        if jq -e --arg s "$ours" '.bypass_auth_subnet_whitelist_enabled and .bypass_auth_subnet_whitelist == $s' <<<"$cur" >/dev/null; then
            w_would "qbittorrent: its login back for everyone (no portal guards it)" || return 0
            qb_api /app/setPreferences "json=$want" >/dev/null || true   # the read-back below is the verdict
        else
            local e
            if jq -e '.bypass_auth_subnet_whitelist_enabled' <<<"$cur" >/dev/null; then
                while IFS= read -r e; do
                    [[ -n "$e" ]] && ipv4_in_cidr "$(env_get TRAEFIK_ADDRESS)" "$e" || continue
                    wfail "qbittorrent: its bypass list's '$e' covers Traefik's address ($(env_get TRAEFIK_ADDRESS)) — with no portal in front, anyone who reaches Traefik gets in without a login; take it out (Tools → Options → WebUI → Authentication)"
                    return 0
                done < <(jq -r '.bypass_auth_subnet_whitelist // "" | split("\n")[] | split(",")[]' <<<"$cur")
            fi
            ok "qbittorrent: asks everyone for its login"; return 0
        fi
    elif jq -e --argjson w "$want" '. as $c | $w | to_entries | all(.value == $c[.key])' <<<"$cur" >/dev/null; then
        ok "qbittorrent: no login for people the portal let in"; return 0
    else
        if jq -e --arg s "$ours" '.bypass_auth_subnet_whitelist_enabled and (.bypass_auth_subnet_whitelist // "") != "" and .bypass_auth_subnet_whitelist != $s' <<<"$cur" >/dev/null; then
            warn "qbittorrent: its bypass list '$(jq -r '.bypass_auth_subnet_whitelist | gsub("\n"; ",")' <<<"$cur")' becomes Traefik's address alone — behind the portal its port is the host's own, so nothing else reached it that way"
        fi
        w_would "qbittorrent: no login for people the portal let in (requests from Traefik, $ours)" || return 0
        qb_api /app/setPreferences "json=$want" >/dev/null || true   # the read-back below is the verdict
    fi
    cur=$(qb_api /app/preferences) || { wfail "qbittorrent: its preferences are unreadable after the change: $(oneline "$cur")"; return 0; }
    if jq -e --argjson w "$want" '. as $c | $w | to_entries | all(.value == $c[.key])' <<<"$cur" >/dev/null; then
        if gate_trusted qbittorrent; then ok "qbittorrent: no login for people the portal let in"
        else ok "qbittorrent: asks everyone for its login"; fi
    else
        wfail "qbittorrent: took the change but reads back otherwise — check Tools → Options → WebUI → Authentication"
    fi
}

qbittorrent_gate_login() { # `disable authentik` (GATE_UNTRUSTED=1): its login back for everyone, proven — a failure counts in WIRE_FAILS
    qb_login "$(env_get QBITTORRENT_USER)" "$(env_get QBITTORRENT_PASSWORD)" \
        || { wfail "qbittorrent: cannot sign in with the stored login to take its portal bypass away — $QB_LOGIN_BODY"; return 0; }
    qb_gate_trust
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
          "$(qb_url)/api/v2$p" 2>&1) || { api_timed_out $? && api_unanswered "$( (( $# )) && echo POST || echo GET)" 20 || echo "$out"; return 1; }
    code=${out##*$'\n'}; echo "${out%$'\n'*}"
    [[ "$code" =~ ^2 ]]
}

wire_qbit() {
    hr "wire: qBittorrent"
    svc_enabled qbittorrent || { info "qbittorrent not enabled — skipped"; return 0; }
    wire_gate qbittorrent
    # auth-free settle: any HTTP status proves the listener (000 = no socket);
    # avoids misreading a boot gap as bad credentials on re-runs
    http_ready qbittorrent "$(qb_url)/api/v2/app/webapiVersion" '^[1-9]' \
        || die "cannot wire qBittorrent without its WebUI (see above)"
    local user pass
    user=$(env_get QBITTORRENT_USER)
    pass=$(env_get QBITTORRENT_PASSWORD)
    # configure records the login (lib/logins.sh); a fresh qBittorrent takes it below
    [[ -n "$user" && -n "$pass" ]] \
        || { wfail "qBittorrent's login is not in .env (QBITTORRENT_USER / QBITTORRENT_PASSWORD) — ./mediastack.sh up records one, then re-run wire"; return 0; }
    if qb_login "$user" "$pass"; then
        ok "credentials from .env work"
    elif (( WIRE_DRY )); then
        w_would "harvest qBittorrent's boot password and set the login from .env" || true
        info "category preview needs credentials — computed on the real run"
        return 0
    else
        # No stored credentials: don't forensically read old boots' logs —
        # restart qBittorrent ourselves and watch for the password THIS
        # restart mints. Deterministic: our restart, our time window.
        local tmp="" t=0 qcn ts
        qcn=$(svc_cname qbittorrent)
        leak_gate_refuse "restarting qBittorrent"   # a raw docker start: DC's chokepoint does not see it
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
        if w_would "set qBittorrent's login from .env (view: credentials)"; then
            qb_api /app/setPreferences \
                "json={\"web_ui_username\":\"$user\",\"web_ui_password\":\"$pass\"}" >/dev/null || true  # re-login below is the verdict
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
    qb_gate_trust
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

sc_rotate_qbit() { # USER PASS — qbit + every place that stores its login
        local user="$1" pass="$2" s
        svc_enabled qbittorrent || { info "qbittorrent not enabled — skipped"; return 0; }
        qb_login "$(env_get QBITTORRENT_USER)" "$(env_get QBITTORRENT_PASSWORD)" \
            || die "cannot sign in to qBittorrent with the stored credentials — fix that first (wire qbit)"
        qb_api /app/setPreferences "json=$(jq -cn --arg u "$user" --arg p "$pass" '{web_ui_username:$u,web_ui_password:$p}')" >/dev/null || true  # re-login below is the verdict
        sleep 2
        qb_login "$user" "$pass" || die "qBittorrent did not accept the new credentials — inspect: logs qbittorrent"
        env_set QBITTORRENT_USER "$user"; env_set QBITTORRENT_PASSWORD "$pass"
        ok "qBittorrent login rotated and verified"
        local key url cur id ent
        # every arr-family app holding a qBittorrent entry — prowlarr's (manual
        # grabs) included: missing it left a stale password there
        for s in $(arr_instances) prowlarr; do
            svc_enabled "$s" || continue
            key=$(arr_key "$s"); url=$(arr_url "$s")
            cur=$(api GET "$url/api/$(arr_apiver "$s")/downloadclient" "$key") \
                || { wfail "$s: could not read its download clients — its qBittorrent login was NOT updated; fix in its UI [$(oneline "$cur")]"; continue; }
            id=$(jq -r '.[] | select(.implementation=="QBittorrent") | .id' <<<"$cur" 2>/dev/null | sed -n 1p)
            [[ -n "$id" ]] || { info "$s: no qBittorrent download client entry — skipped"; continue; }
            if [[ -n "$(jq -r --argjson i "$id" '.[] | select(.id==$i) | .fields[]? | select(.name=="apiKey") | .value // ""' <<<"$cur")" ]]; then
                info "$s: signs in to qBittorrent with its API key — the login rotation does not apply"; continue
            fi
            ent=$(jq -c --argjson i "$id" --arg u "$user" --arg p "$pass" '
                .[] | select(.id==$i)
                | .fields = [ .fields[]
                    | if .name=="username" then .value=$u
                      elif .name=="password" then .value=$p
                      else . end ]' <<<"$cur")
            api PUT "$url/api/$(arr_apiver "$s")/downloadclient/$id" "$key" "$ent" >/dev/null \
                && ok "$s: download-client entry updated" \
                || wfail "$s: could not update its download-client entry — fix in its UI (Settings -> Download Clients)"
        done
        if svc_enabled cleanuparr && [[ -n "$(env_get CLEANUPARR_API_KEY)" ]]; then
            local KH dcs dcid dcent
            KH="X-Api-Key: $(env_get CLEANUPARR_API_KEY)"
            dcs=$(cup_api GET /configuration/download_client "$KH") \
                || { wfail "cleanuparr: could not read its download clients — its qBittorrent login was NOT updated; fix in its UI [HTTP $(cup_code)]"; dcs=""; }
            dcid=$(jq -r '.clients[]? | select(.name=="qbittorrent") | .id' <<<"$dcs" 2>/dev/null | sed -n 1p)
            if [[ -n "$dcid" ]]; then
                dcent=$(jq -c --arg i "$dcid" --arg u "$user" --arg p "$pass" \
                        '.clients[] | select(.id==$i) | .username=$u | .password=$p' <<<"$dcs")
                cup_api PUT "/configuration/download_client/$dcid" "$KH" "$dcent" >/dev/null \
                    && ok "cleanuparr connection updated" \
                    || wfail "cleanuparr connection not updated [HTTP $(cup_code)] — fix in its UI"
            fi
        fi
        if svc_enabled lazylibrarian && [[ -n "$(ll_key)" ]]; then
            ll_api writeCFG "name=USER&group=QBITTORRENT&value=$user" >/dev/null \
                && ll_api writeCFG "name=PASS&group=QBITTORRENT&value=$pass" >/dev/null \
                && ok "lazylibrarian qBittorrent login updated" \
                || wfail "lazylibrarian qBittorrent login not updated — fix in its UI (Settings -> Downloaders)"
        fi
}

qbittorrent_doctor_tun0() { # qbit must be bound to the tunnel interface (wire sets it; doctor: runtime audit)
if svc_enabled qbittorrent && [[ "$(c_state "$(svc_cname qbittorrent)")" == running ]]; then
    if qb_login "$(env_get QBITTORRENT_USER)" "$(env_get QBITTORRENT_PASSWORD)" 2>/dev/null; then
        local iface
        iface=$(qb_api /app/preferences | jq -r '.current_network_interface // .network_interface // empty' 2>/dev/null || true)
        [[ "$iface" == tun0 ]] && ok "qBittorrent transfers bound to tun0" \
            || warn "qBittorrent is NOT bound to tun0 (currently: '${iface:-unset}') — fix: ./mediastack.sh wire qbit"
    else
        warn "could not sign in to qBittorrent to verify the tun0 bind"
    fi
fi
}

support_qbittorrent() { # support: its version, the interface its transfers are bound to, its categories
    local out
    sp_running qbittorrent || return 0
    qb_login "$(env_get QBITTORRENT_USER)" "$(env_get QBITTORRENT_PASSWORD)" || { echo "it refused the login from .env: $(oneline "${QB_LOGIN_BODY:-}")"; return 0; }
    out=$(qb_api /app/version) && echo "version $out" || echo "version unreadable: $(oneline "$out")"
    out=$(qb_api /app/preferences) && jq -r '"transfers bound to: \(if (.current_network_interface // "") == "" then "ANY interface" else .current_network_interface end); listening on port \(.listen_port)"' <<<"$out" || echo "preferences unreadable: $(oneline "$out")"
    out=$(qb_api /torrents/categories) && jq -r '"categories: \(keys | join(", "))"' <<<"$out" || echo "categories unreadable: $(oneline "$out")"
    return 0
}
