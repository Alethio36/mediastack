#!/usr/bin/env bash
# services/deluge/deluge.sh — Deluge's web API client, its `wire deluge` role
# (its password, its web UI connected to its daemon, downloads on the data
# tree, the Label plugin the arrs' categories need, transfers bound to tun0),
# doctor's tun0 check and `set-credentials deluge`. How the arrs, Prowlarr and
# Cleanuparr reach it as a download client: provides/download-client.*.json.
# Sourced by the entrypoint; relies on lib/wire.sh, lib/roles.sh and the
# entrypoint's helpers at call time.

DELUGE_FIRST_PASSWORD=deluge                  # the image's first-run web password
DELUGE_SAVE=/data/torrent                     # the data tree's torrent folder, as every app mounts it
DELUGE_JAR="${TMPDIR:-/tmp}/.mediastack-deluge.$$"

deluge_url() { local p; p=$(svc_hostport deluge) || return 1; echo "http://127.0.0.1:$p"; }
deluge_rpc() { # deluge_rpc METHOD PARAMS-JSON-ARRAY -> its .result (JSON); rc 1 with the reason on stdout
    local out
    out=$(curl -sS -m 20 -b "$DELUGE_JAR" -c "$DELUGE_JAR" -H 'Content-Type: application/json' \
          --data "$(jq -cn --arg m "$1" --argjson p "$2" '{method: $m, params: $p, id: 1}')" \
          "$(deluge_url)/json" 2>&1) || { echo "unreachable: $out"; return 1; }
    jq -e '.error == null' <<<"$out" >/dev/null 2>&1 || { echo "$(jq -r '.error.message // .' <<<"$out" 2>/dev/null || echo "$out")"; return 1; }
    jq -c '.result' <<<"$out"
}
deluge_login() { # deluge_login PASSWORD -> rc 0 when accepted (the session cookie is kept for deluge_rpc)
    rm -f "$DELUGE_JAR"
    [[ "$(deluge_rpc auth.login "$(jq -cn --arg p "$1" '[$p]')" 2>/dev/null)" == true ]]
}
deluge_connect() { # deluge_connect -> rc 0 when its web UI talks to its daemon (connecting it when it does not)
    local hosts hid
    [[ "$(deluge_rpc web.connected '[]')" == true ]] && return 0
    hosts=$(deluge_rpc web.get_hosts '[]') && hid=$(jq -r '.[0][0] // empty' <<<"$hosts")
    [[ -n "$hid" ]] || return 1
    deluge_rpc web.connect "$(jq -cn --arg h "$hid" '[$h]')" >/dev/null && [[ "$(deluge_rpc web.connected '[]')" == true ]]
}

wire_deluge() {
    hr "wire: Deluge"
    svc_enabled deluge || { info "deluge not enabled — skipped"; return 0; }
    wire_gate deluge
    http_ready deluge "$(deluge_url)/" '^200$' || return 1
    local pass out hosts hid dd cur k want plugins
    # --- its password: the image's first-run one is replaced, the new one kept in .env
    pass=$(env_get DELUGE_PASSWORD)
    if [[ -n "$pass" ]] && deluge_login "$pass"; then
        ok "deluge: password from .env works"
    elif deluge_login "$DELUGE_FIRST_PASSWORD"; then
        w_would "deluge: replace its first-run password (stored in .env — view: credentials)" || return 0
        [[ -n "$pass" ]] || pass=$(head -c12 /dev/urandom | base64 | tr -d '=+/')
        out=$(deluge_rpc auth.change_password "$(jq -cn --arg o "$DELUGE_FIRST_PASSWORD" --arg n "$pass" '[$o, $n]')") \
            || { wfail "deluge refused the new password — $out"; return 1; }
        deluge_login "$pass" || { wfail "deluge did not accept its new password — inspect: logs deluge"; return 1; }
        env_set DELUGE_PASSWORD "$pass"
        ok "deluge: password set and verified (view: credentials)"
    else
        wfail "deluge rejects DELUGE_PASSWORD and its first-run password — put its current web password in .env (DELUGE_PASSWORD), then re-run"
        return 1
    fi
    # --- its web UI talks to its daemon: now, and by itself after a restart
    hosts=$(deluge_rpc web.get_hosts '[]') || { wfail "deluge: its daemon list is unreadable — $hosts"; return 1; }
    hid=$(jq -r '.[0][0] // empty' <<<"$hosts")
    [[ -n "$hid" ]] || { wfail "deluge: its web UI lists no daemon — inspect: logs deluge"; return 1; }
    if [[ "$(deluge_rpc web.connected '[]')" == true ]]; then
        ok "deluge: web UI connected to its daemon"
    elif w_would "deluge: connect its web UI to its daemon"; then
        deluge_connect && ok "deluge: web UI connected to its daemon" \
            || { wfail "deluge: its web UI could not connect to its daemon — inspect: logs deluge"; return 1; }
    else
        info "deluge: its daemon settings are checked once it is connected (the real run)"; return 0
    fi
    dd=$(deluge_rpc web.get_config '[]' | jq -r '.default_daemon // ""')
    if [[ "$dd" == "$hid" ]]; then ok "deluge: connects to its daemon at every start"
    elif w_would "deluge: connect to its daemon at every start"; then
        out=$(deluge_rpc web.set_config "$(jq -cn --arg h "$hid" '[{default_daemon: $h}]')") \
            && ok "deluge: connects to its daemon at every start" || wfail "deluge: default daemon not set — $out"
    fi
    # --- downloads on the data tree (the arrs import from there), transfers on tun0
    cur=$(deluge_rpc core.get_config_values '[["download_location", "outgoing_interface"]]') \
        || { wfail "deluge: its settings are unreadable — $cur"; return 1; }
    for k in download_location outgoing_interface; do
        case "$k" in download_location) want=$DELUGE_SAVE ;; outgoing_interface) want=tun0 ;; esac
        if [[ "$(jq -r --arg k "$k" '.[$k] // ""' <<<"$cur")" == "$want" ]]; then ok "deluge: $k $want"
        elif w_would "deluge: set $k to $want"; then
            out=$(deluge_rpc core.set_config "$(jq -cn --arg k "$k" --arg v "$want" '[{($k): $v}]')") \
                && ok "deluge: $k $want" || wfail "deluge: $k not set — $out"
        fi
    done
    # --- the arrs' categories are Deluge labels
    plugins=$(deluge_rpc core.get_enabled_plugins '[]') || { wfail "deluge: its plugins are unreadable — $plugins"; return 1; }
    if jq -e 'index("Label")' <<<"$plugins" >/dev/null; then ok "deluge: Label plugin on (the arrs' categories)"
    elif w_would "deluge: switch its Label plugin on (the arrs' categories need it)"; then
        out=$(deluge_rpc core.enable_plugin '["Label"]') && ok "deluge: Label plugin on (the arrs' categories)" \
            || wfail "deluge: Label plugin not switched on — $out"
    fi
}

deluge_doctor_tun0() { # deluge must be bound to the tunnel interface (wire sets it; doctor: runtime audit)
    svc_enabled deluge && [[ "$(c_state "$(svc_cname deluge)")" == running ]] || return 0
    local iface
    if deluge_login "$(env_get DELUGE_PASSWORD)" && deluge_connect; then
        iface=$(deluge_rpc core.get_config_value '["outgoing_interface"]' | jq -r '. // ""')
        [[ "$iface" == tun0 ]] && ok "Deluge transfers bound to tun0" \
            || warn "Deluge is NOT bound to tun0 (currently: '${iface:-unset}') — fix: ./mediastack.sh wire deluge"
    else
        warn "could not sign in to Deluge to verify the tun0 bind — ./mediastack.sh wire deluge"
    fi
}

sc_rotate_deluge() { # PASS — Deluge's web password + every download-client entry holding it
        local pass="$1"
        svc_enabled deluge || { info "deluge not enabled — skipped"; return 0; }
        deluge_login "$(env_get DELUGE_PASSWORD)" \
            || die "cannot sign in to Deluge with the stored password — fix that first (wire deluge)"
        local out
        out=$(deluge_rpc auth.change_password "$(jq -cn --arg o "$(env_get DELUGE_PASSWORD)" --arg n "$pass" '[$o, $n]')") \
            || die "Deluge refused the new password — $out"
        deluge_login "$pass" || die "Deluge did not accept the new password — inspect: logs deluge"
        env_set DELUGE_PASSWORD "$pass"
        ok "Deluge password rotated and verified"
        arr_dl_login_resync deluge
        cleanuparr_dl_login_resync deluge
}
