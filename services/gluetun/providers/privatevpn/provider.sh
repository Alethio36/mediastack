#!/usr/bin/env bash
# services/gluetun/providers/privatevpn/provider.sh — PrivateVPN (docs/design-vpn.md), from
# gluetun's wiki and source; not tested live by mediastack yet.
# OpenVPN only. Its login is the PrivateVPN account's own, not the "Proxy login" of its
# Control Panel (gluetun's wiki).

vpnp_privatevpn_name()      { echo "privatevpn"; }
vpnp_privatevpn_types()     { echo openvpn; }
vpnp_privatevpn_filters()   { echo countries cities hostnames; }
vpnp_privatevpn_protocols() { echo udp tcp; }
vpnp_privatevpn_proven()    { echo ""; }
vpnp_privatevpn_env()       { echo OPENVPN_USER OPENVPN_PASSWORD; }
vpnp_privatevpn_questions() { # TYPE
    vpn_ask_openvpn_login "$(vpn_login_hint "PrivateVPN" privatevpn)"
}
