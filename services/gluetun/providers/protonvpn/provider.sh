#!/usr/bin/env bash
# services/gluetun/providers/protonvpn/provider.sh — ProtonVPN (docs/design-vpn.md), from
# gluetun's wiki and source; not tested live by mediastack yet.
# WireGuard: gluetun sets its interface addresses (10.2.0.2 and its IPv6 one) itself; a key
# made with NAT-PMP on is the one port forwarding will need (slice 4). OpenVPN: its own
# OpenVPN/IKEv2 username, not the Proton account's (port forwarding adds +pmp: slice 4).

vpnp_protonvpn_name()    { echo protonvpn; }
vpnp_protonvpn_types()   { echo wireguard openvpn; }
vpnp_protonvpn_filters() { echo countries cities hostnames flags; }
vpnp_protonvpn_flags()   { echo free stream secure-core tor; }   # its server flags (CI: each has servers in gluetun's list)
vpnp_protonvpn_proven()  { echo ""; }
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
for all of them) and copy its PrivateKey. For port forwarding later, tick NAT-PMP there."
}
