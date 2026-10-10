#!/usr/bin/env bash
# services/prowlarr/prowlarr.sh — the `wire prowlarr` role: applications (the
# arrs), the FlareSolverr proxy and Prowlarr's download client.
# Sourced by the entrypoint; relies on lib/wire.sh, lib/addr.sh and the
# entrypoint's helpers at call time.

# ---- prowlarr: applications + flaresolverr proxy ----
prowlarr_app_repoint() { # <target> <entry name> <applications JSON> <prowlarr api url> <prowlarr key>
    # an application entry holds BOTH directions; re-point only the fields that
    # are stale AND mediastack-made, so a hand-set other direction survives
    local t="$1" name="$2" cur="$3" purl="$4" pkey="$5" b pr
    local -a fields=() was=() want=()
    b=$(addr_of "$(arr_entry_field "$cur" "$name" baseUrl)")
    pr=$(addr_of "$(arr_entry_field "$cur" "$name" prowlarrUrl)")
    if addr_stale "prowlarr -> $t" "$t" "$b"; then
        fields+=("baseUrl=http://$(svc_addr "$t")"); was+=("$b"); want+=("$(svc_addr "$t")")
    fi
    if addr_stale "$t -> prowlarr" prowlarr "$pr"; then
        fields+=("prowlarrUrl=http://$(svc_addr prowlarr)"); was+=("$pr"); want+=("$(svc_addr prowlarr)")
    fi
    (( ${#fields[@]} )) || return 0
    addr_repoint "prowlarr <-> $t" "${was[*]}" "${want[*]}" -- \
        arr_repoint "$purl/api/v1" "$pkey" applications "$cur" "$name" "${fields[@]}"
}
prowlarr_download_client() { # manual grabs in prowlarr's UI go to the download client (category 'prowlarr')
    local key url ver base dcs dl miss e name impl schema tmpl body resp p other out
    key=$(arr_key prowlarr); url=$(arr_url prowlarr); ver=$(arr_apiver prowlarr); base="$url/api/$ver"
    [[ -n "$key" ]] || { wfail "prowlarr: no ApiKey readable — re-run wire in a minute"; return 1; }
    dl=$(role_pick download-client)
    [[ -n "$dl" ]] || { info "prowlarr: no download client enabled"; return 0; }
    miss=$(role_env_missing "$dl" download-client prowlarr | paste -sd' ' -)
    [[ -z "$miss" ]] || { info "prowlarr download client $dl pends on its credentials ($miss)"; return 0; }
    dcs=$(api GET "$base/downloadclient" "$key") \
        || { wfail "prowlarr: could not read its download clients — nothing created [$(oneline "$dcs")]"; return 1; }
    e=$(role_entry "$dl" download-client prowlarr); name=$(jq -r '.name' <<<"$e"); impl=$(jq -r '.implementation' <<<"$e")
    if [[ -n "$(jq -r --arg n "$name" '.[]? | select(.name == $n) | .id' <<<"$dcs")" ]]; then
        ok "prowlarr download client $name registered"
        local dst; dst="$(arr_entry_field "$dcs" "$name" host):$(arr_entry_field "$dcs" "$name" port)"
        if addr_stale "prowlarr -> $dl" "$dl" "$dst"; then
            local -a login; mapfile -t login < <(role_login_fields "$dcs" "$name" "$e")
            addr_repoint "prowlarr -> $dl" "$dst" "$(svc_addr "$dl")" -- \
                arr_repoint "$base" "$key" downloadclient "$dcs" "$name" \
                "host=$(svc_host "$dl")" "port=$(svc_cport "$dl")" "${login[@]}"
            if (( ! WIRE_DRY )); then
                dcs=$(api GET "$base/downloadclient" "$key") \
                    || { wfail "prowlarr: could not re-read its download clients [$(oneline "$dcs")]"; return 1; }
            fi
        fi
        if [[ "$(jq -r --arg n "$name" '.[]? | select(.name == $n) | .enable' <<<"$dcs")" == false ]] \
            && w_would "prowlarr: switch $name back on — it is the download client"; then
            out=$(arr_entry_enable "$base" "$key" downloadclient "$dcs" "$name" true) \
                && ok "prowlarr: $name switched back on" || wfail "prowlarr: switching $name back on was rejected — $(oneline "$out")"
        fi
    elif w_would "prowlarr: register $impl as its download client (manual grabs -> category 'prowlarr')"; then
        schema=$(api GET "$base/downloadclient/schema" "$key" || true)   # soft read: create path only: an empty schema FAILs below, nothing created
        tmpl=$(jq -c --arg i "$impl" '[.[] | select(.implementation == $i)][0] // empty' <<<"$schema" 2>/dev/null)
        [[ -n "$tmpl" ]] || { wfail "prowlarr: its API offers no $impl client type — is the image very old?"; return 1; }
        body=$(jq -c --argjson e "$e" '
            .name = $e.name | .enable = true
            | .fields = [ .fields[]
                | .name as $n
                | if ($e.fields | has($n)) then .value = $e.fields[$n]
                  elif .name == "category" then .value = "prowlarr"
                  else . end ]' <<<"$tmpl")
        resp=$(api POST "$base/downloadclient" "$key" "$body") \
            && ok "prowlarr download client $name registered" \
            || { wfail "prowlarr: download client $name rejected: $(head -c200 <<<"$resp")"; return 1; }
    fi
    for p in $(role_all_providers download-client prowlarr); do
        [[ "$p" == "$dl" ]] && continue
        other=$(role_entry_name "$p" download-client prowlarr)
        [[ "$(jq -r --arg n "$other" '.[]? | select(.name == $n) | .enable' <<<"$dcs")" == true ]] || continue
        w_would "prowlarr: switch off '$other' — the download client is $dl" || continue
        out=$(arr_entry_enable "$base" "$key" downloadclient "$dcs" "$other" false) \
            && ok "prowlarr: '$other' switched off (kept, not deleted)" || wfail "prowlarr: switching off '$other' was rejected — $(oneline "$out")"
    done
    return 0
}

wire_prowlarr() {
    hr "wire: Prowlarr"
    svc_enabled prowlarr || { info "prowlarr not enabled — skipped"; return 0; }
    wire_gate prowlarr
    wire_arrs_ready || true
    local pkey purl; pkey=$(arr_key prowlarr); purl=$(arr_url prowlarr)
    [[ -n "$pkey" ]] || { wfail "prowlarr: no ApiKey yet — re-run wire shortly"; return 0; }
    # prowlarr has no arrtype label so wire_arr's loop never sees it: its login
    # here — its own, or trusting the portal (gate_trusted), like the arrs
    arr_login prowlarr
    local s key t impl cur aexists abody
    cur=$(api GET "$purl/api/v1/applications" "$pkey") \
        || { wfail "prowlarr: could not read its apps — nothing created [$(oneline "$cur")]"; return 1; }
    for s in $(arr_instances); do
        t=$(svc_label "$s" mediastack.arrtype)
        arr_known "$t" || continue
        impl=$(arr_meta "$t" impl)
        key=$(arr_key "$s") || true
        [[ -n "$key" ]] || { wfail "prowlarr<-$s: $s has no ApiKey yet"; continue; }
        aexists=no; grep -q "\"$s (mediastack)\"" <<<"$cur" && aexists=yes
        if [[ "$aexists" == yes ]]; then
            prowlarr_app_repoint "$s" "$s (mediastack)" "$cur" "$purl" "$pkey"
        fi
        abody=$(cat <<JSON
{"name":"$s (mediastack)","syncLevel":"fullSync",
 "implementation":"$impl","configContract":"${impl}Settings",
 "fields":[{"name":"prowlarrUrl","value":"http://$(svc_addr prowlarr)"},
   {"name":"baseUrl","value":"http://$(svc_addr "$s")"},
   {"name":"apiKey","value":"$key"}]}
JSON
)
        ensure_resource "$aexists" "register $s in prowlarr (Full Sync)" \
            "prowlarr -> $s registered" "prowlarr -> $s failed — check: logs prowlarr" \
            -- api POST "$purl/api/v1/applications" "$pkey" "$abody"
    done
    # LazyLibrarian is a first-class Prowlarr app — register it so its book
    # indexers sync exactly like the arrs (needs its API key from config.ini)
    if svc_enabled lazylibrarian; then
        local llkey
        llkey=$(ll_key)
        if [[ -z "$llkey" ]]; then
            info "prowlarr -> lazylibrarian: skipped (no API key yet — run 'wire lazylibrarian' first)"
        else
            aexists=no; grep -q '"LazyLibrarian (mediastack)"' <<<"$cur" && aexists=yes
            if [[ "$aexists" == yes ]]; then
                prowlarr_app_repoint lazylibrarian "LazyLibrarian (mediastack)" "$cur" "$purl" "$pkey"
            fi
            abody=$(cat <<JSON
{"name":"LazyLibrarian (mediastack)","syncLevel":"fullSync",
 "implementation":"LazyLibrarian","configContract":"LazyLibrarianSettings",
 "fields":[{"name":"prowlarrUrl","value":"http://$(svc_addr prowlarr)"},
   {"name":"baseUrl","value":"http://$(svc_addr lazylibrarian)"},
   {"name":"apiKey","value":"$llkey"}]}
JSON
)
            ensure_resource "$aexists" "register lazylibrarian in prowlarr (Full Sync)" \
                "prowlarr -> lazylibrarian registered" "prowlarr -> lazylibrarian failed — check: logs prowlarr" \
                -- api POST "$purl/api/v1/applications" "$pkey" "$abody"
        fi
    fi
    if svc_enabled flaresolverr; then
        # tag 'flared': put it on any indexer that needs FlareSolverr and
        # prowlarr routes that indexer through the proxy. Nothing carries it
        # by default — only Cloudflare-protected indexers should pay the tax.
        local fid
        local tags; tags=$(api GET "$purl/api/v1/tag" "$pkey") \
            || { wfail "prowlarr: could not read its tags — flaresolverr not set up [$(oneline "$tags")]"; prowlarr_download_client; return 1; }
        fid=$(jq -r '.[] | select(.label=="flared") | .id' <<<"$tags" 2>/dev/null | head -1)
        if [[ -n "$fid" ]]; then
            ok "tag 'flared' exists"
        elif w_would "create prowlarr tag 'flared' (attach to indexers needing FlareSolverr)"; then
            fid=$(api POST "$purl/api/v1/tag" "$pkey" '{"label":"flared"}' | jq -r '.id' 2>/dev/null || true)
            [[ -n "$fid" && "$fid" != null ]] && ok "tag 'flared' created" \
                || { wfail "prowlarr tag 'flared' creation failed — check: logs prowlarr"; fid=""; }
        fi
        if ! cur=$(api GET "$purl/api/v1/indexerproxy" "$pkey"); then
            wfail "prowlarr: could not read its indexer proxies — nothing created [$(oneline "$cur")]"
        elif grep -q '"FlareSolverr (mediastack)"' <<<"$cur"; then
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
            local fst; fst=$(addr_of "$(arr_entry_field "$cur" "FlareSolverr (mediastack)" host)")
            if addr_stale "prowlarr -> flaresolverr" flaresolverr "$fst"; then
                addr_repoint "prowlarr -> flaresolverr" "$fst" "$(svc_addr flaresolverr)" -- \
                    arr_repoint "$purl/api/v1" "$pkey" indexerproxy "$cur" "FlareSolverr (mediastack)" \
                    "host=http://$(svc_addr flaresolverr)/"
            fi
        elif w_would "register FlareSolverr as indexer proxy"; then
            api POST "$purl/api/v1/indexerproxy" "$pkey" "$(cat <<JSON
{"name":"FlareSolverr (mediastack)","implementation":"FlareSolverr",
 "configContract":"FlareSolverrSettings","tags":[${fid:-}],
 "fields":[{"name":"host","value":"http://$(svc_addr flaresolverr)/"},
   {"name":"requestTimeout","value":60}]}
JSON
)" >/dev/null && ok "flaresolverr proxy registered (tag 'flared')" \
              || wfail "flaresolverr proxy registration failed"
        fi
    fi
    prowlarr_download_client
}

prowlarr_indexers_retest() { # after a stack start: once FlareSolverr is up, Prowlarr re-tests its proxies and indexers
    # A cold start fails Prowlarr's first requests (FlareSolverr launches a
    # browser), Prowlarr backs those indexers off, and the arrs report "all
    # indexers unavailable" until the backoff runs out. A test that passes
    # once FlareSolverr answers says what really works now.
    svc_enabled prowlarr && [[ "$(c_state "$(svc_cname prowlarr)")" == running ]] || return 0
    local key url out bad
    if svc_enabled flaresolverr; then
        wait_verdict flaresolverr \
            || { warn "prowlarr: indexers not re-tested — flaresolverr ${VERDICT_WHY[flaresolverr]} (check: ./mediastack.sh logs flaresolverr)"; return 0; }
    fi
    key=$(arr_key prowlarr); url="$(arr_url prowlarr)/api/$(arr_apiver prowlarr)"
    [[ -n "$key" ]] || { warn "prowlarr: no API key readable — indexers not re-tested"; return 0; }
    http_ready prowlarr "$url/system/status" '^200$' -H "X-Api-Key: $key" || return 0
    if svc_enabled flaresolverr; then
        out=$(api POST "$url/indexerproxy/testall" "$key" '{}') \
            || warn "prowlarr: re-testing its proxies failed — $(oneline "$out")"
    fi
    out=$(api POST "$url/indexer/testall" "$key" '{}') \
        || { warn "prowlarr: re-testing its indexers failed — $(oneline "$out")"; return 0; }
    bad=$(jq -r '[.[]? | select(.isValid == false) | .id] | join(" ")' <<<"$out" 2>/dev/null)
    if [[ "$(jq 'length' <<<"$out" 2>/dev/null)" == 0 ]]; then info "prowlarr: no indexers yet — nothing to re-test"
    elif [[ -z "$bad" ]]; then ok "prowlarr: every indexer answers after the start"
    else warn "prowlarr: indexers still failing after the start (ids: $bad) — check them in Prowlarr; with one indexer, the arrs report all unavailable"; fi
}
