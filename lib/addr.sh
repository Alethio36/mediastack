#!/usr/bin/env bash
# lib/addr.sh — app-to-app addresses: how one app reaches another (VPN-aware),
# who stores whose address (WIRE_CALLERS), and re-pointing them when a
# service moves in or out of the VPN. Sourced by the entrypoint.

# ---- app-to-app addresses ----
# How one app reaches another — what wire writes INTO an app's settings (the
# script's own API calls use the host ports above instead). One rule, proven
# live on the stack: a service behind the VPN listens in gluetun's namespace,
# so every caller, behind the VPN or not, reaches it as gluetun:<port>; a
# service outside the VPN is reached by its service name on the stack network,
# from either side. The address depends only on the TARGET: moving a caller
# in or out of the VPN never breaks a connection, moving a target means
# re-pointing its callers — addr_stale/addr_repoint do it, and after a VPN
# toggle `up` runs them for every caller in WIRE_CALLERS.
svc_host() { # svc_host <target> -> gluetun | <target>, from its effective VPN membership
    if [[ "$(vpn_effective "$1" "$(svc_label "$1" mediastack.vpn)")" == true ]]; then echo gluetun; else echo "$1"; fi
}
svc_cport() { svc_label "$1" mediastack.port; }   # the port it listens on inside its namespace
svc_addr()  { echo "$(svc_host "$1"):$(svc_cport "$1")"; }
addr_of() { # addr_of <url | host:port> -> host:port (scheme and path dropped)
    local a=${1#*://}; echo "${a%%/*}"
}
addr_stale() { # addr_stale <what> <target> <stored host:port> -> 0 when mediastack's own address needs re-pointing
    # Only addresses mediastack itself makes are claimed: the target's port on
    # localhost, 127.0.0.1, gluetun or the target's name (any layout, before or
    # after a toggle). Anything else was set by hand — reported, never touched.
    local want; want=$(svc_addr "$2")
    [[ -z "$3" || "$3" == "$want" ]] && return 1
    if [[ "${3##*:}" == "$(svc_cport "$2")" && "${3%:*}" =~ ^(localhost|127\.0\.0\.1|gluetun|$2)$ ]]; then return 0; fi
    info "$1 points at $3 — not an address mediastack makes, so it is yours: left alone"
    return 1
}
addr_repoint() { # addr_repoint <what> <stored> <want> -- <command...> — re-point, or say it would
    local what="$1" stored="$2" want="$3" out; shift 3; [[ "${1:-}" == -- ]] && shift
    w_would "$what: re-point $stored -> $want" || return 0
    if out=$("$@" 2>&1); then ok "$what: re-pointed to $want"
    else wfail "$what: re-point to $want rejected — $(oneline "$out")"; fi
}
# WIRE_CALLERS — who calls whom: for each service wire points OTHER apps at,
# the wire roles that write its address. A VPN toggle moves that address
# (svc_addr), so after the move these roles re-run and re-point their entries
# (wire_repoint_pending, from `up`). "arr" stands for every arr instance.
# recyclarr's arr addresses need no role: trash-sync regenerates them each run.
# CI (scripts/test-repoint.sh) fails if wire points at a service not listed.
declare -A WIRE_CALLERS=(
    [qbittorrent]="arr prowlarr cleanuparr lazylibrarian"
    [apprise]="apprise cleanuparr seerr"
    [arr]="prowlarr cleanuparr seerr bazarr"
    [prowlarr]="prowlarr"
    [lazylibrarian]="prowlarr"
    [flaresolverr]="prowlarr"
    [jellyfin]="seerr"
)
wire_callers() { # wire_callers <svc> -> the roles that write an address of <svc>, one per line
    local key="$1"; [[ -n "$(svc_label "$1" mediastack.arrtype)" ]] && key=arr
    tr ' ' '\n' <<<"${WIRE_CALLERS[$key]:-}" | awk NF
}
repoint_mark() { # repoint_mark <svc> — its address is about to move: re-point its callers after `up`
    local cur; cur=$(state_get WIRE_REPOINT)
    [[ " $cur " == *" $1 "* ]] || state_set WIRE_REPOINT "${cur:+$cur }$1"
}
wire_repoint_pending() { # after `up`: re-point the callers of every service a VPN toggle moved
    local pending s role want="" roles="" failed=""
    pending=$(state_get WIRE_REPOINT); [[ -n "$pending" ]] || return 0
    # never wired: no app holds an address yet, so nothing can be stale
    [[ -f "$WIRED_FILE" ]] || { state_del WIRE_REPOINT; return 0; }
    for s in $pending; do want+=" $(wire_callers "$s" | tr '\n' ' ')"; done
    for role in "${WIRE_ROLES[@]}"; do [[ " $want " == *" $role "* ]] && roles+="$role "; done   # wire's own order
    [[ -n "$roles" ]] || { state_del WIRE_REPOINT; return 0; }
    hr "Re-pointing what calls: $pending (moved in or out of the VPN)"
    for role in $roles; do
        # cmd_wire exits on failure: a subshell keeps `up` alive to report it
        ( cmd_wire "$role" ) || failed+="$role "
    done
    if [[ -n "$failed" ]]; then
        fail "re-pointing incomplete — wire ${failed% } reported failures (above). Fix, then: ./mediastack.sh up (retries) or ./mediastack.sh wire"
        return 1
    fi
    state_del WIRE_REPOINT
    ok "everything that calls ${pending} re-pointed"
}
