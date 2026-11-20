#!/usr/bin/env bash
# services/gluetun/providers/protonvpn/provider.sh — ProtonVPN (docs/design-vpn.md), from
# gluetun's wiki and source; not tested live by mediastack yet.
# gluetun sets its interface addresses (10.2.0.2 and its IPv6 one) itself; a key made with
# NAT-PMP on is the one port forwarding will need (slice 4).

vpnp_protonvpn_name()    { echo protonvpn; }
vpnp_protonvpn_types()   { echo wireguard; }
vpnp_protonvpn_filters() { echo countries cities hostnames; }
vpnp_protonvpn_proven()  { echo ""; }
vpnp_protonvpn_env()     { echo WIREGUARD_PRIVATE_KEY; }
vpnp_protonvpn_questions() { # TYPE
    vpn_ask_wg_key "account.proton.me -> VPN -> WireGuard: create a configuration (any server — the key works
for all of them) and copy its PrivateKey. For port forwarding later, tick NAT-PMP there."
}
