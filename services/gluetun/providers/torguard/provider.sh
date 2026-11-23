#!/usr/bin/env bash
# services/gluetun/providers/torguard/provider.sh — TorGuard (docs/design-vpn.md), from
# gluetun's wiki and source; not tested live by mediastack yet.
# OpenVPN only.

vpnp_torguard_name()      { echo "torguard"; }
vpnp_torguard_types()     { echo openvpn; }
vpnp_torguard_filters()   { echo countries cities hostnames; }
vpnp_torguard_protocols() { echo udp tcp; }
vpnp_torguard_proven()    { echo ""; }
vpnp_torguard_env()       { echo OPENVPN_USER OPENVPN_PASSWORD; }
vpnp_torguard_questions() { # TYPE
    vpn_ask_openvpn_login "$(vpn_login_hint "TorGuard" torguard)"
}
