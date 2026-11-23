#!/usr/bin/env bash
# services/gluetun/providers/vpn-unlimited/provider.sh — VPN Unlimited (docs/design-vpn.md), from
# gluetun's wiki and source; not tested live by mediastack yet.
# OpenVPN only, over UDP (gluetun's server data has no TCP server for it); gluetun's name has
# a space, the folder a hyphen. Besides its login, gluetun needs its client certificate and key
# (from the OpenVPN config VPN Unlimited hands out for manual setup).

vpnp_vpn_unlimited_name()      { echo "vpn unlimited"; }
vpnp_vpn_unlimited_types()     { echo openvpn; }
vpnp_vpn_unlimited_filters()   { echo countries cities hostnames; }
vpnp_vpn_unlimited_protocols() { echo udp; }
vpnp_vpn_unlimited_proven()    { echo ""; }
vpnp_vpn_unlimited_env()       { echo OPENVPN_USER OPENVPN_PASSWORD OPENVPN_CERT OPENVPN_KEY; }
vpnp_vpn_unlimited_questions() { # TYPE
    vpn_ask_openvpn_login "$(vpn_login_hint "VPN Unlimited" vpn-unlimited)"
    info "Its client certificate and key: the OpenVPN config file VPN Unlimited gives you holds both (or two files of their own)."
    vpn_ask_pem OPENVPN_CERT CERTIFICATE "client certificate"
    vpn_ask_pem OPENVPN_KEY "PRIVATE KEY" "client key"
}
