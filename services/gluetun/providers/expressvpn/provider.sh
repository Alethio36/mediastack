#!/usr/bin/env bash
# services/gluetun/providers/expressvpn/provider.sh — ExpressVPN (docs/design-vpn.md), from
# gluetun's wiki and source; not tested live by mediastack yet.
# OpenVPN only, over UDP (gluetun's server data has no TCP server for it).

vpnp_expressvpn_name()      { echo "expressvpn"; }
vpnp_expressvpn_types()     { echo openvpn; }
vpnp_expressvpn_filters()   { echo countries cities hostnames; }
vpnp_expressvpn_protocols() { echo udp; }
vpnp_expressvpn_proven()    { echo ""; }
vpnp_expressvpn_env()       { echo OPENVPN_USER OPENVPN_PASSWORD; }
vpnp_expressvpn_questions() { # TYPE
    vpn_ask_openvpn_login "$(vpn_login_hint "ExpressVPN" expressvpn)"
}
