#!/usr/bin/env bash
# services/gluetun/providers/airvpn/provider.sh — AirVPN (docs/design-vpn.md), from
# gluetun's wiki and source; not tested live by mediastack yet.
# WireGuard: AirVPN needs a pre-shared key besides the key and its address. OpenVPN: no
# username, a client certificate and key instead (both inline in the .ovpn its Config Generator makes).

vpnp_airvpn_name()    { echo airvpn; }
vpnp_airvpn_types()   { echo wireguard openvpn; }
vpnp_airvpn_filters() { echo regions countries cities hostnames; }
vpnp_airvpn_proven()  { echo ""; }
vpnp_airvpn_portforward() { echo static; }   # a port you forward in its client area (Ports), opened on the tunnel by gluetun
vpnp_airvpn_env() { # TYPE
    case "$1" in
        wireguard) echo WIREGUARD_PRIVATE_KEY WIREGUARD_ADDRESSES WIREGUARD_PRESHARED_KEY ;;
        openvpn)   echo OPENVPN_CERT OPENVPN_KEY ;;
    esac
}
vpnp_airvpn_questions() { # TYPE
    if [[ "$1" == openvpn ]]; then
        info "AirVPN Client Area -> Config Generator -> OpenVPN: generate a file — it holds both the certificate and the key."
        vpn_ask_pem OPENVPN_CERT CERTIFICATE "client certificate"
        vpn_ask_pem OPENVPN_KEY "PRIVATE KEY" "client key"
        return 0
    fi
    vpn_ask_wg_key "AirVPN Client Area -> Config Generator -> WireGuard: generate a file and copy its PrivateKey."
    vpn_ask_wg_address "The IPv4 address of the same file's Address line."
    vpn_ask_wg_psk   # the PresharedKey of the same file
}
