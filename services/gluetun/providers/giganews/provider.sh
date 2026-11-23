#!/usr/bin/env bash
# services/gluetun/providers/giganews/provider.sh — Giganews (docs/design-vpn.md), from
# gluetun's wiki and source; not tested live by mediastack yet.
# OpenVPN only, over UDP (gluetun refuses TCP for it). Its servers have regions, not
# countries (server choices: slice 3).

vpnp_giganews_name()      { echo "giganews"; }
vpnp_giganews_types()     { echo openvpn; }
vpnp_giganews_filters()   { echo hostnames; }
vpnp_giganews_protocols() { echo udp; }
vpnp_giganews_proven()    { echo ""; }
vpnp_giganews_env()       { echo OPENVPN_USER OPENVPN_PASSWORD; }
vpnp_giganews_questions() { # TYPE
    vpn_ask_openvpn_login "$(vpn_login_hint "Giganews" giganews)"
}
