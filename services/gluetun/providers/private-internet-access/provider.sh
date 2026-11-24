#!/usr/bin/env bash
# services/gluetun/providers/private-internet-access/provider.sh — Private Internet Access (docs/design-vpn.md), from
# gluetun's wiki and source; not tested live by mediastack yet.
# OpenVPN only (gluetun's name has spaces: the folder has hyphens). Its servers have regions,
# not countries (server choices: slice 3); port forwarding: slice 4.

vpnp_private_internet_access_name()      { echo "private internet access"; }
vpnp_private_internet_access_types()     { echo openvpn; }
vpnp_private_internet_access_filters()   { echo regions hostnames; }
vpnp_private_internet_access_protocols() { echo udp tcp; }
vpnp_private_internet_access_proven()    { echo ""; }
vpnp_private_internet_access_env()       { echo OPENVPN_USER OPENVPN_PASSWORD; }
vpnp_private_internet_access_questions() { # TYPE
    vpn_ask_openvpn_login "$(vpn_login_hint "Private Internet Access" private-internet-access)"
}
