#!/usr/bin/env bash
# services/gluetun/providers/surfshark/provider.sh — Surfshark (docs/design-vpn.md), from
# gluetun's wiki and source; not tested live by mediastack yet.
# The key and its address are the same for every Surfshark server.

vpnp_surfshark_name()    { echo surfshark; }
vpnp_surfshark_types()   { echo wireguard; }
vpnp_surfshark_filters() { echo countries cities hostnames; }
vpnp_surfshark_proven()  { echo ""; }
vpnp_surfshark_env()     { echo WIREGUARD_PRIVATE_KEY WIREGUARD_ADDRESSES; }
vpnp_surfshark_questions() { # TYPE
    vpn_ask_wg_key "Surfshark: VPN -> Manual setup -> Desktop or mobile -> WireGuard -> I don't have a key pair
-> name it -> Generate a new key pair: copy the Private key."
    vpn_ask_wg_address "Then pick any location and download its config file: the IPv4 address of its Address line."
}
