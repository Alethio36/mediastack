#!/usr/bin/env bash
# services/gluetun/providers/purevpn/provider.sh — PureVPN (docs/design-vpn.md), from
# gluetun's wiki and source; not tested live by mediastack yet.
# OpenVPN only.

vpnp_purevpn_name()      { echo "purevpn"; }
vpnp_purevpn_types()     { echo openvpn; }
vpnp_purevpn_filters()   { echo regions countries cities categories hostnames; }
vpnp_purevpn_protocols() { echo udp tcp; }
vpnp_purevpn_proven()    { echo ""; }
vpnp_purevpn_env()       { echo OPENVPN_USER OPENVPN_PASSWORD; }
vpnp_purevpn_questions() { # TYPE
    vpn_ask_openvpn_login "$(vpn_login_hint "PureVPN" purevpn)"
}
