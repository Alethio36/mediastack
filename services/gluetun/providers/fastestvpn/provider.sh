#!/usr/bin/env bash
# services/gluetun/providers/fastestvpn/provider.sh — FastestVPN (docs/design-vpn.md), from
# gluetun's wiki and source; not tested live by mediastack yet.
# The key and its address come from FastestVPN's WireGuard configuration file.

vpnp_fastestvpn_name()    { echo fastestvpn; }
vpnp_fastestvpn_types()   { echo wireguard; }
vpnp_fastestvpn_filters() { echo countries cities hostnames; }
vpnp_fastestvpn_proven()  { echo ""; }
vpnp_fastestvpn_env()     { echo WIREGUARD_PRIVATE_KEY WIREGUARD_ADDRESSES; }
vpnp_fastestvpn_questions() { # TYPE
    vpn_ask_wg_key "FastestVPN's WireGuard configuration file: copy its PrivateKey."
    vpn_ask_wg_address "The IPv4 address of the same file's Address line."
}
