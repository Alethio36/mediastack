#!/usr/bin/env bash
# services/gluetun/providers/ivpn/provider.sh — IVPN (docs/design-vpn.md), from
# gluetun's wiki and source; not tested live by mediastack yet.
# The key and its address are the same for every IVPN server.

vpnp_ivpn_name()    { echo ivpn; }
vpnp_ivpn_types()   { echo wireguard; }
vpnp_ivpn_filters() { echo countries cities hostnames; }
vpnp_ivpn_proven()  { echo ""; }
vpnp_ivpn_env()     { echo WIREGUARD_PRIVATE_KEY WIREGUARD_ADDRESSES; }
vpnp_ivpn_questions() { # TYPE
    vpn_ask_wg_key "IVPN account -> WireGuard -> generate a key: copy the private key."
    vpn_ask_wg_address "The IP address IVPN shows for that key."
}
