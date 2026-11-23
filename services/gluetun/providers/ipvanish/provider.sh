#!/usr/bin/env bash
# services/gluetun/providers/ipvanish/provider.sh — IPVanish (docs/design-vpn.md), from
# gluetun's wiki and source; not tested live by mediastack yet.
# OpenVPN only, over UDP (gluetun refuses TCP for it).

vpnp_ipvanish_name()      { echo "ipvanish"; }
vpnp_ipvanish_types()     { echo openvpn; }
vpnp_ipvanish_filters()   { echo countries cities hostnames; }
vpnp_ipvanish_protocols() { echo udp; }
vpnp_ipvanish_proven()    { echo ""; }
vpnp_ipvanish_env()       { echo OPENVPN_USER OPENVPN_PASSWORD; }
vpnp_ipvanish_questions() { # TYPE
    vpn_ask_openvpn_login "$(vpn_login_hint "IPVanish" ipvanish)"
}
