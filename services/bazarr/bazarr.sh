#!/usr/bin/env bash
# services/bazarr/bazarr.sh — Bazarr's API key and its `wire bazarr` role.
# Sourced by the entrypoint; relies on lib/wire.sh, lib/addr.sh and the
# entrypoint's helpers at call time.

bazarr_key() { # bazarr_key -> api key from its config.yaml ("" while initialising)
    sudo grep -oP 'apikey:\s*\K\S+' "$(env_get CONFIG_ROOT)/bazarr/config/config.yaml" 2>/dev/null | sed -n 1p || true
}

# ---- bazarr ----
BAZARR_KEY_WAIT=90   # seconds a first start may take to write its key
wire_bazarr() {
    hr "wire: Bazarr"
    svc_enabled bazarr || { info "bazarr not enabled — skipped"; return 0; }
    wire_gate bazarr
    local bkey burl kw=0
    bkey=$(bazarr_key)
    if [[ -z "$bkey" ]] && (( ! WIRE_DRY )); then
        # a first start: Bazarr writes config.yaml, its key in it, a while after
        # its container starts (found live: `enable bazarr` wired it too soon)
        info "waiting for bazarr to write its API key (budget ${BAZARR_KEY_WAIT}s)..."
        until bkey=$(bazarr_key); [[ -n "$bkey" ]] || (( kw >= BAZARR_KEY_WAIT )); do sleep 3; kw=$((kw + 3)); done
    fi
    [[ -n "$bkey" ]] || { wfail "bazarr: no api key in config/config.yaml$( ((kw)) && echo " after ${kw}s") — re-run wire shortly; check: logs bazarr"; return 0; }
    burl=$(arr_url bazarr)
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
                   "settings-${t}-ip=$(svc_host "$t")"
                   "settings-${t}-port=$(svc_cport "$t")"
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

# ---- rotate-secrets (lib/rotate.sh) ----
bazarr_secrets() { svc_enabled bazarr && [[ -n "$(bazarr_key)" ]] && printf 'bazarr API key\tcompanion\n'; return 0; }
bazarr_secret_rotate() { # a new key through its settings form; config.yaml follows
    local old new url code
    old=$(bazarr_key); new=$(rotate_hex); url=$(arr_url bazarr)
    # after the restore point's restart: Bazarr is the slowest to answer (found live: HTTP 000, 31s after it)
    http_ready bazarr "$url/api/system/status" '^200$' -H "X-API-KEY: $old" || return 1
    rotate_journal_hold "bazarr API key" "$old" "$new"
    code=$(curl -s -m 20 -o /dev/null -w '%{http_code}' -X POST -H "X-API-KEY: $old" \
           --data-urlencode "settings-auth-apikey=$new" "$url/api/system/settings" 2>/dev/null) || true
    if ! [[ "$code" =~ ^2 ]]; then fail "bazarr: refused the new key (HTTP ${code:-000}) — its key is unchanged"; rotate_journal_release; return 1; fi
    rotate_proven bazarr "$url/api/system/status" "X-API-KEY: $new" "X-API-KEY: $old" || return 2
    rotate_journal_release
}
