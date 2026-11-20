#!/usr/bin/env bash
# services/gluetun/providers/mullvad/provider.sh — Mullvad (docs/design-vpn.md), from
# gluetun's wiki and source; not tested live by mediastack yet.
# WireGuard only (Mullvad dropped OpenVPN in January 2026). The key and its address are the
# same for every Mullvad server.

vpnp_mullvad_name()    { echo mullvad; }
vpnp_mullvad_types()   { echo wireguard; }
vpnp_mullvad_filters() { echo countries cities hostnames; }
vpnp_mullvad_proven()  { echo ""; }
vpnp_mullvad_env()     { echo WIREGUARD_PRIVATE_KEY WIREGUARD_ADDRESSES; }
vpnp_mullvad_questions() { # TYPE
    vpn_ask_wg_key "mullvad.net -> Account -> WireGuard configuration: generate a configuration file, then copy
its PrivateKey. (The key on the Devices page is not the private key.)"
    vpn_ask_wg_address "The IPv4 address of the same file's Address line (the first of the two)."
}
