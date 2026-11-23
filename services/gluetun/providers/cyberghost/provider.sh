#!/usr/bin/env bash
# services/gluetun/providers/cyberghost/provider.sh — CyberGhost (docs/design-vpn.md), from
# gluetun's wiki and source; not tested live by mediastack yet.
# OpenVPN only. Besides its login, gluetun needs CyberGhost's client certificate and key
# (from the OpenVPN config CyberGhost hands out for manual setup).

vpnp_cyberghost_name()      { echo "cyberghost"; }
vpnp_cyberghost_types()     { echo openvpn; }
vpnp_cyberghost_filters()   { echo countries hostnames; }
vpnp_cyberghost_protocols() { echo udp tcp; }
vpnp_cyberghost_proven()    { echo ""; }
vpnp_cyberghost_env()       { echo OPENVPN_USER OPENVPN_PASSWORD OPENVPN_CERT OPENVPN_KEY; }
vpnp_cyberghost_questions() { # TYPE
    vpn_ask_openvpn_login "$(vpn_login_hint "CyberGhost" cyberghost)"
    info "Its client certificate and key: the OpenVPN config file CyberGhost gives you holds both (or two files of their own)."
    vpn_ask_pem OPENVPN_CERT CERTIFICATE "client certificate"
    vpn_ask_pem OPENVPN_KEY "PRIVATE KEY" "client key"
}
