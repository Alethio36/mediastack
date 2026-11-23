#!/usr/bin/env bash
# services/gluetun/providers/windscribe/provider.sh — Windscribe (docs/design-vpn.md), from
# gluetun's wiki and source; not tested live by mediastack yet.
# Windscribe chooses servers by region and city, not country. WireGuard needs a pre-shared key;
# OpenVPN, the username and password of a config it generates. On a "Build a Plan"
# subscription the regions you pay for must be set (server choices: slice 3).

vpnp_windscribe_name()    { echo windscribe; }
vpnp_windscribe_types()   { echo wireguard openvpn; }
vpnp_windscribe_filters() { echo cities hostnames; }
vpnp_windscribe_proven()  { echo ""; }
vpnp_windscribe_env() { # TYPE
    case "$1" in
        wireguard) echo WIREGUARD_PRIVATE_KEY WIREGUARD_ADDRESSES WIREGUARD_PRESHARED_KEY ;;
        openvpn)   echo OPENVPN_USER OPENVPN_PASSWORD ;;
    esac
}
vpnp_windscribe_questions() { # TYPE
    if [[ "$1" == openvpn ]]; then
        vpn_ask_openvpn_login "windscribe.com/getconfig/openvpn: generate a config — the username and password it shows with it."
        return 0
    fi
    vpn_ask_wg_key "windscribe.com/getconfig/wireguard: generate a config file and copy its PrivateKey (the same
for every Windscribe server)."
    vpn_ask_wg_address "The IPv4 address of the same file's Address line."
    vpn_ask_wg_psk   # the PresharedKey of the same file
}
