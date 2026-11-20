#!/usr/bin/env bash
# services/gluetun/providers/airvpn/provider.sh — AirVPN (docs/design-vpn.md), from
# gluetun's wiki and source; not tested live by mediastack yet.
# AirVPN needs a pre-shared key besides the key and its address.

vpnp_airvpn_name()    { echo airvpn; }
vpnp_airvpn_types()   { echo wireguard; }
vpnp_airvpn_filters() { echo countries cities hostnames; }
vpnp_airvpn_proven()  { echo ""; }
vpnp_airvpn_env()     { echo WIREGUARD_PRIVATE_KEY WIREGUARD_ADDRESSES WIREGUARD_PRESHARED_KEY; }
vpnp_airvpn_questions() { # TYPE
    vpn_ask_wg_key "AirVPN Client Area -> Config Generator -> WireGuard: generate a file and copy its PrivateKey."
    vpn_ask_wg_address "The IPv4 address of the same file's Address line."
    vpn_ask_wg_psk   # the PresharedKey of the same file
}
