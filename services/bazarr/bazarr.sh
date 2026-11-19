#!/usr/bin/env bash
# services/bazarr/bazarr.sh — Bazarr's API key and its `wire bazarr` role.
# Sourced by the entrypoint; relies on lib/wire.sh, lib/addr.sh and the
# entrypoint's helpers at call time.

bazarr_key() { # bazarr_key -> api key from its config.yaml ("" while initialising)
    sudo grep -oP 'apikey:\s*\K\S+' "$(env_get CONFIG_ROOT)/bazarr/config/config.yaml" 2>/dev/null | sed -n 1p || true
}

# ---- its own login (docs/design-logins.md) ----
# Behind a trusted portal gate it needs none (auth type None); otherwise it
# takes the shared arr login as its form login. Its API asks for the API key
# whatever the login (Bazarr's api/utils.py authenticate), so dropping the
# login never opens the API.
# shellcheck disable=SC2120  # force arrives from sc_rotate_arr (services/_arr/arr.sh), another file
bazarr_login() { # bazarr_login [force] — Bazarr's own login follows gate_trusted, read back; force: push the stored password even when the name already matches (set-credentials)
    local key url cur u p want out code form=()
    key=$(bazarr_key); url=$(arr_url bazarr)
    [[ -n "$key" ]] || { info "bazarr: no API key yet — 'wire bazarr' sets its login"; return 0; }
    u=$(env_get ARR_USER); p=$(env_get ARR_PASSWORD)
    if gate_trusted bazarr; then
        want='.auth.type == null'
    else
        [[ -n "$u" && -n "$p" ]] || { info "bazarr: the shared arr login is not set yet — 'wire arr' creates it"; return 0; }
        want='.auth.type == "form" and .auth.username == $u'
    fi
    cur=$(curl -sS -m 20 -H "X-API-KEY: $key" "$url/api/system/settings" 2>&1) && jq -e '.auth | type == "object"' <<<"$cur" >/dev/null 2>&1 \
        || { wfail "bazarr: could not read its settings to check its login — $(oneline "$cur")"; return 0; }
    # the password is stored hashed: a match is the type and the name; force never matches
    if [[ "${1:-}" != force ]] && jq -e --arg u "$u" "$want" <<<"$cur" >/dev/null; then
        if gate_trusted bazarr; then ok "bazarr: no login of its own — the portal guards it"
        else ok "bazarr: its page asks for the arr login ('$u')"; fi
        return 0
    fi
    if gate_trusted bazarr; then
        w_would "bazarr: drop its own login — the portal guards it" || return 0
        form=(--data-urlencode "settings-auth-type=null")   # Bazarr reads null as None (config.py empty_values)
    else
        w_would "bazarr: its page asks for the arr login ('$u')" || return 0
        form=(--data-urlencode "settings-auth-type=form" --data-urlencode "settings-auth-username=$u" --data-urlencode "settings-auth-password=$p")
    fi
    out=$(curl -sS -m 20 -w $'\n%{http_code}' -X POST -H "X-API-KEY: $key" "${form[@]}" "$url/api/system/settings" 2>&1) || out+=$'\n000'
    code=${out##*$'\n'}
    [[ "$code" =~ ^2 ]] || { wfail "bazarr: its login change was refused [HTTP $code]: $(oneline "${out%$'\n'*}")"; return 0; }
    cur=$(curl -sS -m 20 -H "X-API-KEY: $key" "$url/api/system/settings" 2>&1)
    if jq -e --arg u "$u" "$want" <<<"$cur" >/dev/null 2>&1; then
        if gate_trusted bazarr; then ok "bazarr: no login of its own — the portal guards it"
        else ok "bazarr: its page asks for the arr login ('$u')"; fi
    else
        wfail "bazarr: took its login change [HTTP $code] but reads back otherwise — check its Settings → General → Security"
    fi
}

bazarr_gate_login() { bazarr_login; }   # `disable authentik` (GATE_UNTRUSTED=1): its login back, read back — a failure counts in WIRE_FAILS

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
    bazarr_analytics_off "$bkey" "$burl"
    bazarr_login
    local pairs=() t skey
    for t in sonarr radarr; do
        svc_enabled "$t" || continue
        skey=$(arr_key "$t"); [[ -n "$skey" ]] || continue
        pairs+=("$t" "$skey")
    done
    (( ${#pairs[@]} )) || { info "no base sonarr/radarr to pair — skipped"; return 0; }
    if w_would "point bazarr at base sonarr/radarr (extra instances are out of bazarr's scope)"; then
        # its login is bazarr_login's (above), never in this form
        local form=() i
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
            ok "bazarr paired with base sonarr/radarr"
        else
            wfail "bazarr pairing rejected [HTTP $bcode]: $(head -c200 <<<"${bresp%$'\n'*}")
     pair manually meanwhile (Settings -> Sonarr/Radarr) and paste the above"
        fi
    fi
}

bazarr_analytics_read() { # KEY URL -> true|false (anything else: Bazarr's answer, rc 1)
    local out v
    out=$(curl -sS -m 20 -H "X-API-KEY: $1" "$2/api/system/settings" 2>&1) || { echo "$out"; return 1; }
    v=$(jq -r '.analytics.enabled' <<<"$out" 2>/dev/null) || v=""
    [[ "$v" == true || "$v" == false ]] || { echo "$out"; return 1; }
    echo "$v"
}
bazarr_analytics_off() { # KEY URL — Bazarr's Google Analytics (an event per subtitle download), off once: turned back on in its UI, it stays on
    local cur code
    cur=$(bazarr_analytics_read "$1" "$2") || { wfail "bazarr: its analytics setting is unreadable: $(oneline "$cur")"; return 0; }
    if [[ "$cur" == false ]]; then
        [[ -n "$(state_get BAZARR_ANALYTICS_OFF)" ]] || state_set BAZARR_ANALYTICS_OFF 1
        ok "bazarr: no analytics sent"; return 0
    fi
    [[ -z "$(state_get BAZARR_ANALYTICS_OFF)" ]] || { ok "bazarr: analytics were turned on in its UI — untouched"; return 0; }
    w_would "bazarr: stop its analytics (Google Analytics: an event for every subtitle download)" || return 0
    code=$(curl -s -m 20 -o /dev/null -w '%{http_code}' -X POST -H "X-API-KEY: $1" \
           --data-urlencode "settings-analytics-enabled=false" "$2/api/system/settings" 2>/dev/null) || true
    cur=$(bazarr_analytics_read "$1" "$2") || cur=""
    [[ "$cur" == false ]] || { wfail "bazarr did not stop its analytics (HTTP ${code:-000}; it reads: ${cur:-unreadable})"; return 0; }
    state_set BAZARR_ANALYTICS_OFF 1; ok "bazarr: analytics stopped"
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
