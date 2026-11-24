#!/usr/bin/env bash
# services/gluetun/providers/slickvpn/provider.sh — SlickVPN (docs/design-vpn.md), from
# gluetun's wiki and source; not tested live by mediastack yet.
# OpenVPN only.

vpnp_slickvpn_name()      { echo "slickvpn"; }
vpnp_slickvpn_types()     { echo openvpn; }
vpnp_slickvpn_filters()   { echo regions countries cities hostnames; }
vpnp_slickvpn_protocols() { echo udp tcp; }
vpnp_slickvpn_proven()    { echo ""; }
vpnp_slickvpn_env()       { echo OPENVPN_USER OPENVPN_PASSWORD; }
vpnp_slickvpn_questions() { # TYPE
    vpn_ask_openvpn_login "$(vpn_login_hint "SlickVPN" slickvpn)"
}
