#!/usr/bin/env bash
# services/gluetun/providers/vyprvpn/provider.sh — VyprVPN (docs/design-vpn.md), from
# gluetun's wiki and source; not tested live by mediastack yet.
# OpenVPN only, over UDP (gluetun refuses TCP for it). Its servers have regions, not
# countries (server choices: slice 3).

vpnp_vyprvpn_name()      { echo "vyprvpn"; }
vpnp_vyprvpn_types()     { echo openvpn; }
vpnp_vyprvpn_filters()   { echo regions hostnames; }
vpnp_vyprvpn_protocols() { echo udp; }
vpnp_vyprvpn_proven()    { echo ""; }
vpnp_vyprvpn_env()       { echo OPENVPN_USER OPENVPN_PASSWORD; }
vpnp_vyprvpn_questions() { # TYPE
    vpn_ask_openvpn_login "$(vpn_login_hint "VyprVPN" vyprvpn)"
}
