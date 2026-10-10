#!/usr/bin/env bash
# services/transmission/transmission.sh — Transmission's RPC client, its
# `wire transmission` role (its login, carried by the container's environment;
# downloads on the data tree), doctor's note on its bind and
# `set-credentials transmission`. How the arrs, Prowlarr and Cleanuparr reach
# it as a download client: provides/download-client.*.json.
# Sourced by the entrypoint; relies on lib/wire.sh, lib/roles.sh and the
# entrypoint's helpers at call time.

TRANSMISSION_SAVE=/data/torrent               # the data tree's torrent folder, as every app mounts it
TRANSMISSION_SID=""                           # the RPC's X-Transmission-Session-Id (its CSRF guard)

transmission_url() { local p; p=$(svc_hostport transmission) || return 1; echo "http://127.0.0.1:$p/transmission/rpc"; }
transmission_code_anon() { # -> the RPC's HTTP status without a login: 401 when it asks for one
    curl -s -m 10 -o /dev/null -w '%{http_code}' "$(transmission_url)" 2>/dev/null || echo 000
}
transmission_rpc() { # transmission_rpc METHOD ARGUMENTS-JSON -> its .arguments (JSON); rc 1 with the reason on stdout
    local body out code
    body=$(jq -cn --arg m "$1" --argjson a "$2" '{method: $m, arguments: $a}')
    for _ in 1 2; do   # the first answer may be 409 with the session id to use
        out=$(curl -sS -m 20 -u "$(env_get TRANSMISSION_USER):$(env_get TRANSMISSION_PASSWORD)" \
              -H "X-Transmission-Session-Id: $TRANSMISSION_SID" -D - --data "$body" "$(transmission_url)" 2>&1) \
            || { echo "unreachable: $out"; return 1; }
        code=$(sed -n '1s/^HTTP\/[0-9.]* \([0-9]*\).*/\1/p' <<<"$out")
        if [[ "$code" == 409 ]]; then
            TRANSMISSION_SID=$(sed -n 's/^X-Transmission-Session-Id: *\([^[:space:]]*\).*/\1/Ip' <<<"$out" | head -1); continue
        fi
        out=$(sed '1,/^\r\{0,1\}$/d' <<<"$out")
        [[ "$code" == 200 ]] || { echo "HTTP $code"; return 1; }
        jq -e '.result == "success"' <<<"$out" >/dev/null 2>&1 || { echo "$(jq -r '.result // .' <<<"$out" 2>/dev/null)"; return 1; }
        jq -c '.arguments' <<<"$out"; return 0
    done
    echo "no session id after a 409"; return 1
}
transmission_login_live() { # -> rc 0 when the running container asks for a login and takes .env's
    [[ "$(transmission_code_anon)" == 401 ]] && transmission_rpc session-get '{"fields": ["version"]}' >/dev/null
}

wire_transmission() {
    hr "wire: Transmission"
    svc_enabled transmission || { info "transmission not enabled — skipped"; return 0; }
    wire_gate transmission
    http_ready transmission "$(transmission_url)" '^(401|409)$' || return 1
    local cur out k want
    # --- its login: in .env, carried by the container's environment (USER/PASS)
    if [[ -z "$(env_get TRANSMISSION_USER)" || -z "$(env_get TRANSMISSION_PASSWORD)" ]]; then
        w_would "transmission: give it a login (stored in .env — view: credentials) and recreate it to take it" || return 0
        [[ -n "$(env_get TRANSMISSION_USER)" ]] || env_set TRANSMISSION_USER admin
        env_set TRANSMISSION_PASSWORD "$(head -c12 /dev/urandom | base64 | tr -d '=+/')"
    fi
    if transmission_login_live; then
        ok "transmission: login from .env works"
    elif w_would "transmission: recreate it so it takes its login from .env"; then
        DC up -d transmission >/dev/null 2>&1 || { wfail "transmission: recreate failed — apply with: ./mediastack.sh up"; return 1; }
        http_ready transmission "$(transmission_url)" '^(401|409)$' || return 1
        transmission_login_live && ok "transmission: login from .env works (recreated)" \
            || { wfail "transmission does not take the login from .env after a recreate — inspect: logs transmission"; return 1; }
    else
        return 0
    fi
    # --- downloads on the data tree, in progress too (the arrs import from there)
    cur=$(transmission_rpc session-get '{"fields": ["download-dir", "incomplete-dir-enabled"]}') \
        || { wfail "transmission: its settings are unreadable — $cur"; return 1; }
    for k in download-dir incomplete-dir-enabled; do
        case "$k" in download-dir) want="\"$TRANSMISSION_SAVE\"" ;; incomplete-dir-enabled) want=false ;; esac
        if [[ "$(jq -c --arg k "$k" '.[$k]' <<<"$cur")" == "$want" ]]; then ok "transmission: $k $want"
        elif w_would "transmission: set $k to $want"; then
            out=$(transmission_rpc session-set "$(jq -cn --arg k "$k" --argjson v "$want" '{($k): $v}')") \
                && ok "transmission: $k $want" || wfail "transmission: $k not set — $out"
        fi
    done
}

transmission_doctor_bind() { # it binds by address, not interface: say what guards it instead (doctor: runtime audit)
    svc_enabled transmission && [[ "$(c_state "$(svc_cname transmission)")" == running ]] || return 0
    info "Transmission cannot be bound to tun0 (it binds to an address, and the tunnel's changes) — gluetun's kill switch keeps its traffic in the tunnel; check: ./mediastack.sh leak-test"
}

sc_rotate_transmission() { # PASS — its login (applied by recreating it) + every download-client entry holding it
        local pass="$1"
        svc_enabled transmission || { info "transmission not enabled — skipped"; return 0; }
        [[ -n "$(env_get TRANSMISSION_USER)" ]] || die "Transmission has no login yet — set it up first: ./mediastack.sh wire transmission"
        env_set TRANSMISSION_PASSWORD "$pass"
        DC up -d transmission >/dev/null 2>&1 || die "Transmission recreate failed — apply with: ./mediastack.sh up"
        http_ready transmission "$(transmission_url)" '^(401|409)$' || die "Transmission did not come back — inspect: logs transmission"
        transmission_login_live || die "Transmission does not take the new password — inspect: logs transmission"
        ok "Transmission password rotated and verified (container recreated)"
        arr_dl_login_resync transmission
        cleanuparr_dl_login_resync transmission
}
