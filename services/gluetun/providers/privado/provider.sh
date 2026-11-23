#!/usr/bin/env bash
# services/gluetun/providers/privado/provider.sh — Privado (docs/design-vpn.md), from
# gluetun's wiki and source; not tested live by mediastack yet.
# OpenVPN only, over UDP (gluetun's server data has no TCP server for it).

vpnp_privado_name()      { echo "privado"; }
vpnp_privado_types()     { echo openvpn; }
vpnp_privado_filters()   { echo countries cities hostnames; }
vpnp_privado_protocols() { echo udp; }
vpnp_privado_proven()    { echo ""; }
vpnp_privado_env()       { echo OPENVPN_USER OPENVPN_PASSWORD; }
vpnp_privado_questions() { # TYPE
    vpn_ask_openvpn_login "$(vpn_login_hint "Privado" privado)"
}
