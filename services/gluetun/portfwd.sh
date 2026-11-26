#!/usr/bin/env bash
# services/gluetun/portfwd.sh — port forwarding (docs/design-vpn.md, slice 4):
# the port the VPN forwards reaches the download client, so peers can connect
# in. A provider's folder says whether it can (its portforward hook: native —
# gluetun arranges the port; static — you set it on the provider's site).
#
# Native: gluetun writes the port it got to its own status file in its config
# folder (VPN_PORT_FORWARDING_STATUS_FILE) and empties it when forwarding
# stops — no command of ours runs in it, and the control server stays closed
# (the script holds no key of it). mediastack reads that file; one older than
# gluetun's current start is left from before (a crash) and ignored. Static:
# the port is VPN_FORWARDED_PORT, opened in gluetun's firewall on the tunnel
# (FIREWALL_VPN_INPUT_PORTS). Either way the port is set in the download
# client (DOWNLOAD_CLIENT: the clients share gluetun's namespace, so two
# cannot listen on one port) through that client's own login, its random port
# and UPnP off: <client>_listen_port PORT, in each torrent client's folder.
#
# When: as the gate starts the VPN group, on every 5-minute check, in wire. A
# client that cannot take it is a warning to ops (once per change), never a
# stop: it is no leak. After a reconnect with a new port (ProtonVPN's) the
# client can be unreachable from outside for up to 5 minutes — downloads go on.

# shellcheck disable=SC2034  # rendered by vpn_provider_env (provider.sh)
VPN_PF_FILE_IN=/gluetun/forwarded_port   # the status file, as gluetun sees it (its config folder, mounted at /gluetun)
VPN_PF_STATE=vpn-portfwd                 # local/state: what the last sync did — "<port> <client> ok|fail", or "noport <gluetun instance>"
VPN_PF_GRACE=300                         # seconds after gluetun's start before "no port yet" is told to ops
vpn_pf_file() { echo "$(env_get CONFIG_ROOT)/gluetun/forwarded_port"; }   # the status file, on this host

vpnp_portforward() { if vpnp_has "$1" portforward; then vpnp_call "$1" portforward | awk '{print $1}'; fi; return 0; }   # vpnp_portforward NAME -> native | static | "" (it forwards none)
vpnp_pf_servers_only() { vpnp_has "$1" portforward && [[ " $(vpnp_call "$1" portforward) " == *" servers "* ]]; }   # with forwarding on, gluetun keeps only NAME's forwarding servers (its PORT_FORWARD_ONLY default)
vpn_pf_kind() { # vpn_pf_kind [NAME] -> native | static while VPN_PORT_FORWARDING is on and the provider forwards ("" otherwise)
    local p=${1:-$(env_get VPN_PROVIDER)}
    [[ "$(env_get VPN_PORT_FORWARDING)" == on ]] || return 0
    vpnp_load "$p" || return 0
    vpnp_portforward "$p"
}
vpn_pf_words() { # vpn_pf_words NAME -> ", a port forwarded (...)" for a summary while forwarding is on ("" off)
    case "$(vpn_pf_kind "$1")" in
        native) echo ", a port forwarded (arranged by $1)" ;;
        static) echo ", port $(env_get VPN_FORWARDED_PORT) forwarded" ;;
    esac
    return 0
}
vpn_pf_providers() { local p; for p in $(vpnp_list); do [[ -z "$(vpnp_portforward "$p")" ]] || echo "$p"; done; }   # the providers that forward a port, one a line

vpn_pf_problems() { # vpn_pf_problems NAME -> one line per reason forwarding cannot run as .env says (none: it can, or it is off)
    local p=$1 kind port
    kind=$(vpnp_portforward "$p"); port=$(env_get VPN_FORWARDED_PORT)
    if [[ "$(env_get VPN_PORT_FORWARDING)" == on && -z "$kind" ]]; then
        echo "VPN_PORT_FORWARDING=on, but mediastack forwards no port with $p (it does with: $(vpn_pf_providers | paste -sd' ' | sed 's/ /, /g')) — set it to off (configure asks)"
    elif [[ "$(vpn_pf_kind "$p")" == static && -z "$port" ]]; then
        echo "$p forwards the port you set on its site: put it in VPN_FORWARDED_PORT (configure asks)"
    elif [[ -n "$port" && "$(vpn_pf_kind "$p")" != static ]]; then
        echo "VPN_FORWARDED_PORT=$port does nothing here — it is the port of a provider that forwards one you set ($( [[ "$kind" == native ]] && echo "$p arranges its own" || echo "forwarding is off")): clear it in .env"
    fi
    return 0
}

VPN_PF_PORT=""; VPN_PF_WHY=""   # vpn_pf_read's answer (globals: a $( ) would lose the reason)
vpn_pf_read() { # VPN_PF_PORT: the port the tunnel forwards now; "" with VPN_PF_WHY (none yet, or none to trust)
    local f lines started mtime
    VPN_PF_PORT=""; VPN_PF_WHY=""
    case "$(vpn_pf_kind)" in
        static) VPN_PF_PORT=$(env_get VPN_FORWARDED_PORT); [[ -n "$VPN_PF_PORT" ]] || VPN_PF_WHY="VPN_FORWARDED_PORT is empty"; return 0 ;;
        native) ;;
        *) VPN_PF_WHY="port forwarding is off"; return 0 ;;
    esac
    f=$(vpn_pf_file)
    if ! sudo test -f "$f"; then VPN_PF_WHY="gluetun has written no port yet"; return 0; fi
    started=$(date -d "$(c_get "$(svc_cname gluetun)" .State.StartedAt)" +%s 2>/dev/null || echo 0)
    mtime=$(sudo stat -c %Y "$f" 2>/dev/null || echo 0)
    if (( mtime < started )); then VPN_PF_WHY="its port file is older than gluetun's start — left from before it"; return 0; fi
    lines=$(sudo cat "$f" 2>/dev/null | grep -v '^[[:space:]]*$' || true)
    if [[ -z "$lines" ]]; then VPN_PF_WHY="gluetun has no port forwarded right now (its file is empty)"; return 0; fi
    if [[ "$lines" == *$'\n'* || ! "$lines" =~ ^[0-9]{1,5}$ ]] || (( 10#$lines < 1 || 10#$lines > 65535 )); then
        VPN_PF_WHY="its port file holds '$(oneline "$lines")', not one port"; return 0
    fi
    VPN_PF_PORT=$((10#$lines))
}

vpn_pf_tell() { # vpn_pf_tell STATE TITLE BODY TYPE — ops told once per change of STATE (the sync repeats every 5 minutes)
    [[ "$(state_get "$VPN_PF_STATE")" != "$1" ]] || return 0
    state_set "$VPN_PF_STATE" "$1"
    [[ -n "$2" ]] || return 0
    notify ops "$2" "$3" "$4"
}
vpn_pf_log_lines() { sudo docker logs --tail 300 "$(svc_cname gluetun)" 2>&1 | grep -i 'port forward' | tail -n 3 | sed 's/^/    /' || true; }   # gluetun's last lines about forwarding

vpn_pf_sync() { # the forwarded port into the download client's settings — said, never a stop; ops told when it fails and when it works again
    local kind port dl out prev started
    kind=$(vpn_pf_kind); [[ -n "$kind" ]] || return 0
    vpn_pf_read; port=$VPN_PF_PORT
    if [[ -z "$port" ]]; then
        info "port forwarding: $VPN_PF_WHY — tried again in 5 minutes"
        started=$(date -d "$(c_get "$(svc_cname gluetun)" .State.StartedAt)" +%s 2>/dev/null || echo 0)
        if [[ "$kind" == native ]] && (( started > 0 && $(date +%s) - started >= VPN_PF_GRACE )); then
            local hint=""; if vpnp_has "$(env_get VPN_PROVIDER)" pf_hint; then hint=" $(vpnp_call "$(env_get VPN_PROVIDER)" pf_hint "$(env_get VPN_TYPE)")"; fi
            warn "port forwarding: gluetun has forwarded no port $(( ($(date +%s) - started) / 60 )) minutes after it started — $VPN_PF_WHY.$hint Its last lines on it:"
            vpn_pf_log_lines
            vpn_pf_tell "noport $(gluetun_instance)" "No port forwarded" \
                "gluetun has forwarded no port since it started ($VPN_PF_WHY).$hint Downloads go on; peers cannot connect in. See: ./mediastack.sh logs gluetun" warning
        fi
        return 0
    fi
    if ! dl=$(role_pick download-client 2>/dev/null) || [[ -z "$dl" ]]; then info "port forwarding: no download client runs to give port $port"; return 0; fi
    if ! declare -F "${dl}_listen_port" >/dev/null; then warn "port forwarding: $dl cannot take a listening port (no ${dl}_listen_port)"; return 0; fi
    prev=$(state_get "$VPN_PF_STATE")
    if out=$("${dl}_listen_port" "$port"); then
        ok "port forwarding: $dl listens on $port, the port the VPN forwards"
        if [[ "$prev" == *" fail" ]]; then vpn_pf_tell "$port $dl ok" "Port forwarding works again" "$dl listens on $port, the port the VPN forwards." info
        else vpn_pf_tell "$port $dl ok" "" "" ""; fi
    else
        warn "port forwarding: $dl did not take port $port — $out (tried again in 5 minutes)"
        vpn_pf_tell "$port $dl fail" "The forwarded port did not reach $dl" \
            "The VPN forwards port $port, and $dl did not take it: $out. Downloads go on; peers cannot connect in. Tried again every 5 minutes." warning
    fi
    return 0
}

vpn_pf_doctor() { # doctor: with forwarding on, a port forwarded and the download client listening on it
    local kind port dl out
    kind=$(vpn_pf_kind); [[ -n "$kind" ]] || return 0
    vpn_pf_read; port=$VPN_PF_PORT
    if [[ -z "$port" ]]; then
        local hint=""; if vpnp_has "$(env_get VPN_PROVIDER)" pf_hint; then hint=" $(vpnp_call "$(env_get VPN_PROVIDER)" pf_hint "$(env_get VPN_TYPE)")"; fi
        warn "port forwarding is on, but no port: $VPN_PF_WHY.$hint (./mediastack.sh logs gluetun)"; return 0
    fi
    if ! dl=$(role_pick download-client 2>/dev/null) || [[ -z "$dl" ]]; then info "port $port forwarded; no download client runs to listen on it"; return 0; fi
    if out=$("${dl}_listen_port" "$port" check); then ok "port forwarding: $dl listens on $port, the port the VPN forwards"
    else d_fail "port forwarding: the VPN forwards port $port, and $dl — $out" "peers cannot connect in (downloads go on; no leak)" "./mediastack.sh up   (sets it), or wait for the 5-minute check"; fi
}
vpn_pf_support() { # support: whether forwarding is on, its port, and what the last sync did
    local kind port; kind=$(vpn_pf_kind)
    if [[ -z "$kind" ]]; then echo "port forwarding: off"; return 0; fi
    vpn_pf_read; port=$VPN_PF_PORT
    echo "port forwarding: on ($kind), port ${port:-none}${VPN_PF_WHY:+ — $VPN_PF_WHY}; last sync: $(state_get "$VPN_PF_STATE" | sed 's/^$/none/')"
}

VPN_PF_READY_WAIT=60   # seconds a client's API gets to answer before the sync calls it unreachable (it may have just started)
vpn_pf_client_ready() { # vpn_pf_client_ready URL RE — the client's API answers with a status matching RE (nothing said meanwhile); rc 1 when it never does
    local t0 code; t0=$(date +%s)
    while :; do
        code=$(scurl -s -m 5 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null) || true
        [[ "${code:-000}" =~ $2 ]] && return 0
        (( $(date +%s) - t0 < VPN_PF_READY_WAIT )) || return 1
        sleep 3
    done
}

pf_port_problem() { # pf_port_problem VALUE -> why VALUE is no port to forward ("" when it is)
    [[ "$1" =~ ^[1-9][0-9]{3,4}$ ]] && (( $1 >= 1024 && $1 <= 65535 )) || echo "'$1' is not a port from 1024 to 65535 (the one $(env_get VPN_PROVIDER)'s site shows as forwarded to you)"
}
