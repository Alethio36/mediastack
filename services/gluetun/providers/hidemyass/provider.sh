#!/usr/bin/env bash
# services/gluetun/providers/hidemyass/provider.sh — HideMyAss (docs/design-vpn.md), from
# gluetun's wiki and source; not tested live by mediastack yet.
# OpenVPN only.

vpnp_hidemyass_name()      { echo "hidemyass"; }
vpnp_hidemyass_types()     { echo openvpn; }
vpnp_hidemyass_filters()   { echo countries cities hostnames; }
vpnp_hidemyass_protocols() { echo udp tcp; }
vpnp_hidemyass_proven()    { echo ""; }
vpnp_hidemyass_env()       { echo OPENVPN_USER OPENVPN_PASSWORD; }
vpnp_hidemyass_questions() { # TYPE
    vpn_ask_openvpn_login "$(vpn_login_hint "HideMyAss" hidemyass)"
}
