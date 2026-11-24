#!/usr/bin/env bash
# services/gluetun/providers/protonvpn/provider.sh — ProtonVPN (docs/design-vpn.md), from
# gluetun's wiki and source; not tested live by mediastack yet.
# WireGuard: gluetun sets its interface addresses (10.2.0.2 and its IPv6 one) itself; a key
# made with NAT-PMP on is the one port forwarding needs. OpenVPN: its own OpenVPN/IKEv2
# username, not the Proton account's; port forwarding needs +pmp at its end (gluetun's
# NAT-PMP is refused without it — its source, Nov 2026), added when forwarding is turned on.

vpnp_protonvpn_name()    { echo protonvpn; }
vpnp_protonvpn_types()   { echo wireguard openvpn; }
vpnp_protonvpn_filters() { echo countries cities hostnames flags; }
vpnp_protonvpn_flags()   { echo free stream secure-core tor; }   # its server flags (CI: each has servers in gluetun's list)
vpnp_protonvpn_proven()  { echo ""; }
vpnp_protonvpn_portforward() { echo native servers; }   # NAT-PMP, on its forwarding servers only (gluetun's default with forwarding on)
vpnp_protonvpn_portforward_on() { # TYPE — its OpenVPN username takes +pmp
    local u; u=$(env_get OPENVPN_USER)
    [[ "$1" == openvpn && -n "$u" && "$u" != *+pmp ]] || return 0
    env_set OPENVPN_USER "$u+pmp"; info "ProtonVPN: +pmp added to the OpenVPN username — its port forwarding needs it"
}
vpnp_protonvpn_pf_hint() { # TYPE
    if [[ "$1" == wireguard ]]; then echo "ProtonVPN forwards only for a WireGuard key made with NAT-PMP ticked (account.proton.me -> VPN -> WireGuard): make a new one, then ./mediastack.sh configure."
    else echo "ProtonVPN forwards only for an OpenVPN username ending in +pmp."; fi
}
vpnp_protonvpn_check() { # TYPE — forwarding over OpenVPN needs +pmp
    [[ "$1" == openvpn && "$(vpn_pf_kind protonvpn)" == native && "$(env_get OPENVPN_USER)" != *+pmp ]] || return 0
    echo "VPN_PORT_FORWARDING=on: ProtonVPN forwards only for an OpenVPN username ending in +pmp — add it to OPENVPN_USER (configure does)"
    return 1
}
vpnp_protonvpn_env() { # TYPE
    case "$1" in
        wireguard) echo WIREGUARD_PRIVATE_KEY ;;
        openvpn)   echo OPENVPN_USER OPENVPN_PASSWORD ;;
    esac
}
vpnp_protonvpn_questions() { # TYPE
    if [[ "$1" == openvpn ]]; then
        vpn_ask_openvpn_login "account.proton.me -> VPN -> OpenVPN / IKEv2 username: its username and password (not your Proton login)."
        return 0
    fi
    vpn_ask_wg_key "account.proton.me -> VPN -> WireGuard: create a configuration (any server — the key works
for all of them) and copy its PrivateKey. For port forwarding, tick NAT-PMP there."
}
