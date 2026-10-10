#!/usr/bin/env bash
# services/cleanuparr/cleanuparr.sh — Cleanuparr's API client and its
# `wire cleanuparr` role.
# Sourced by the entrypoint; relies on lib/wire.sh, lib/addr.sh and the
# entrypoint's helpers at call time.

# ---- cleanuparr (wave 5) ----
# Bootstrap the account (reusing the stack's arr login), store the API key,
# point it at qBittorrent and every arr, and switch the queue cleaner on
# with its conservative upstream defaults. Existing entries: untouched.
cup_url() { local p; p=$(svc_hostport cleanuparr) || return 1; echo "http://127.0.0.1:$p"; }
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
    http_ready cleanuparr "$(cup_url)/health" '^2' || return 1

    local user pass st out
    user=$(env_get ARR_USER); pass=$(env_get ARR_PASSWORD)
    [[ -n "$user" && -n "$pass" ]] || { wfail "cleanuparr bootstrap reuses the arr login — run 'wire arr' first (a full 'wire' does both in order)"; return 1; }

    st=$(cup_api GET /auth/status "" || true)   # soft read: unread = not set up: the setup call below answers 409 when it is, which is accepted
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
    akey=$(cup_api GET /account/api-key "Authorization: Bearer $tok" | jq -r '.apiKey // empty' 2>/dev/null || true)   # soft read: checked on the next line
    [[ -n "$akey" ]] || { wfail "could not read cleanuparr's API key [HTTP $(cup_code)]"; return 1; }
    [[ "$(env_get CLEANUPARR_API_KEY)" == "$akey" ]] || env_set CLEANUPARR_API_KEY "$akey"
    local KH="X-Api-Key: $akey"

    # download client: create-if-missing by name
    local qu qp
    qu=$(env_get QBITTORRENT_USER); qp=$(env_get QBITTORRENT_PASSWORD)
    local cdc=""
    if ! cdc=$(cup_api GET /configuration/download_client "$KH"); then
        wfail "cleanuparr: could not read its download clients — nothing created [HTTP $(cup_code)]"
    elif [[ " $(jq -r '[.clients[]?.name] | join(" ")' <<<"$cdc" 2>/dev/null) " == *" qbittorrent "* ]]; then
        ok "qbittorrent already connected — untouched"
        local cst cbody; cst=$(addr_of "$(jq -r '.clients[]? | select(.name=="qbittorrent") | .host' <<<"$cdc" 2>/dev/null | head -1)")
        if addr_stale "cleanuparr -> qbittorrent" qbittorrent "$cst"; then
            cbody=$(jq -c --arg h "http://$(svc_addr qbittorrent)" --arg u "$(env_get QBITTORRENT_USER)" --arg p "$(env_get QBITTORRENT_PASSWORD)" \
                '[.clients[]? | select(.name=="qbittorrent")][0] | .host = $h | .username = $u | .password = $p' <<<"$cdc")
            addr_repoint "cleanuparr -> qbittorrent" "$cst" "$(svc_addr qbittorrent)" -- \
                cup_api PUT "/configuration/download_client/$(jq -r '.id' <<<"$cbody")" "$KH" "$cbody"
        fi
    elif [[ -z "$qu" || -z "$qp" ]]; then
        wfail "no qBittorrent credentials in .env — run 'wire qbit' first"
    else
        local dc
        dc=$(jq -cn --arg u "$qu" --arg p "$qp" --arg h "http://$(svc_addr qbittorrent)" \
             '{enabled:true,name:"qbittorrent",typeName:"qBittorrent",type:"Torrent",
               host:$h,urlBase:"",username:$u,password:$p}')
        out=$(cup_api POST /configuration/download_client/test "$KH" "$dc") \
            || { wfail "cleanuparr could not reach qBittorrent [HTTP $(cup_code)]: $(head -c200 <<<"$out")"; return 1; }
        out=$(cup_api POST /configuration/download_client "$KH" "$dc") \
            && ok "qbittorrent connected" \
            || wfail "qbittorrent entry rejected [HTTP $(cup_code)]: $(head -c200 <<<"$out")"
    fi

    # arrs: create-if-missing by name, per type
    wire_arrs_ready || true
    local s ty key cfg names
    for s in $(arr_instances); do
        ty=$(svc_label "$s" mediastack.arrtype)
        arr_known "$ty" || continue
        key=$(arr_key "$s")
        [[ -n "$key" ]] || { wfail "$s: no ApiKey readable — re-run wire in a minute"; continue; }
        cfg=$(cup_api GET "/configuration/$ty" "$KH") \
            || { wfail "cleanuparr: could not read its $ty connections — nothing created [HTTP $(cup_code)]"; continue; }
        names=$(jq -r '[.instances[]?.name] | join(" ")' <<<"$cfg" 2>/dev/null)
        if [[ " $names " == *" $s "* ]]; then
            ok "$s already connected — untouched"
            local ist ibody; ist=$(addr_of "$(jq -r --arg n "$s" '.instances[]? | select(.name==$n) | .url' <<<"$cfg" 2>/dev/null | head -1)")
            if addr_stale "cleanuparr -> $s" "$s" "$ist"; then
                ibody=$(jq -c --arg n "$s" --arg u "http://$(svc_addr "$s")" '[.instances[]? | select(.name==$n)][0] | .url = $u' <<<"$cfg")
                addr_repoint "cleanuparr -> $s" "$ist" "$(svc_addr "$s")" -- \
                    cup_api PUT "/configuration/$ty/instances/$(jq -r '.id' <<<"$ibody")" "$KH" "$ibody"
            fi
            continue
        fi
        # version = the arr application major, exactly the value cleanuparr's
        # own UI offers per type (ARR_META major)
        local aver; aver=$(arr_meta "$ty" major)
        out=$(cup_api POST "/configuration/$ty/instances" "$KH" \
              "$(jq -cn --arg n "$s" --arg u "http://$(svc_addr "$s")" --arg k "$key" --argjson v "$aver" \
                 '{enabled:true,name:$n,url:$u,apiKey:$k,version:$v}')") \
            && ok "$s connected" \
            || wfail "$s: cleanuparr rejected it [HTTP $(cup_code)]: $(head -c200 <<<"$out")"
    done

    # queue cleaner: switch on, keep upstream's conservative defaults
    cfg=$(cup_api GET /configuration/queue_cleaner "$KH" || true)   # soft read: unread = nothing written: the PUT needs the config it read
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
        local cnp=""
        if ! cnp=$(cup_api GET /configuration/notification_providers "$KH"); then
            wfail "cleanuparr: could not read its notification providers — nothing created [HTTP $(cup_code)]"
        elif [[ " $(jq -r '[.providers[]?.name] | join(" ")' <<<"$cnp" 2>/dev/null) " == *" mediastack-apprise "* ]]; then
            ok "already notifies the hub — untouched"
            local ast abody; ast=$(addr_of "$(jq -r '.providers[]? | select(.name=="mediastack-apprise") | (.url // .configuration.url // "")' <<<"$cnp" 2>/dev/null | head -1)")
            if addr_stale "cleanuparr -> apprise" apprise "$ast"; then
                # GET nests events{} and configuration{}; PUT takes them flat —
                # a naive round trip would reset every event toggle to false
                abody=$(jq -c --arg u "http://$(svc_addr apprise)" '[.providers[]? | select(.name=="mediastack-apprise")][0]
                    | {name, isEnabled} + .events
                      + (.configuration | {mode, url: $u, key, tags: (.tags // ""), serviceUrls})' <<<"$cnp")
                addr_repoint "cleanuparr -> apprise" "$ast" "$(svc_addr apprise)" -- \
                    cup_api PUT "/configuration/notification_providers/apprise/$(jq -r --arg n mediastack-apprise '.providers[]? | select(.name==$n) | .id' <<<"$cnp" | head -1)" "$KH" "$abody"
            fi
        else
            out=$(cup_api POST /configuration/notification_providers/apprise "$KH" \
                  "$(jq -cn --arg u "http://$(svc_addr apprise)" '{name:"mediastack-apprise",isEnabled:true,mode:"Api",
                              url:$u,key:"mediastack",tags:"ops",
                              onQueueItemDeleted:true,onDownloadCleaned:true,
                              onStalledStrike:true,onFailedImportStrike:true}')") \
                && ok "now notifies the hub (tag: ops)" \
                || wfail "hub connection rejected [HTTP $(cup_code)]: $(head -c200 <<<"$out")"
        fi
    fi
}
