#!/usr/bin/env bash
# services/gluetun/providers/fastestvpn/provider.sh — FastestVPN (docs/design-vpn.md), from
# gluetun's wiki and source; not tested live by mediastack yet.
# WireGuard: the key and its address come from FastestVPN's WireGuard configuration file.

vpnp_fastestvpn_name()    { echo fastestvpn; }
vpnp_fastestvpn_types()   { echo wireguard openvpn; }
vpnp_fastestvpn_filters() { echo countries cities hostnames; }
vpnp_fastestvpn_proven()  { echo ""; }
vpnp_fastestvpn_env() { # TYPE
    case "$1" in
        wireguard) echo WIREGUARD_PRIVATE_KEY WIREGUARD_ADDRESSES ;;
        openvpn)   echo OPENVPN_USER OPENVPN_PASSWORD ;;
    esac
}
vpnp_fastestvpn_questions() { # TYPE
    if [[ "$1" == openvpn ]]; then vpn_ask_openvpn_login "$(vpn_login_hint FastestVPN fastestvpn)"; return 0; fi
    vpn_ask_wg_key "FastestVPN's WireGuard configuration file: copy its PrivateKey."
    vpn_ask_wg_address "The IPv4 address of the same file's Address line."
}
