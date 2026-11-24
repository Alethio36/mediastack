#!/usr/bin/env bash
# services/gluetun/providers/ivpn/provider.sh — IVPN (docs/design-vpn.md), from
# gluetun's wiki and source; not tested live by mediastack yet.
# WireGuard: the key and its address are the same for every IVPN server. OpenVPN: your
# account ID (i-xxxx-xxxx-xxxx) needs no password; your email does (gluetun's wiki).

vpnp_ivpn_name()    { echo ivpn; }
vpnp_ivpn_types()   { echo wireguard openvpn; }
vpnp_ivpn_filters() { echo regions countries cities isps hostnames; }
vpnp_ivpn_proven()  { echo ""; }
vpnp_ivpn_env() { # TYPE — OpenVPN: the password is optional (an account ID needs none)
    case "$1" in
        wireguard) echo WIREGUARD_PRIVATE_KEY WIREGUARD_ADDRESSES ;;
        openvpn)   echo OPENVPN_USER ;;
    esac
}
vpnp_ivpn_extra() { # TYPE
    if [[ "$1" == openvpn ]]; then printf 'OPENVPN_PASSWORD\t${OPENVPN_PASSWORD:-}\n'; fi
    return 0
}
vpnp_ivpn_check() { # TYPE — an email needs its password; an account ID does not
    [[ "$1" == openvpn ]] || return 0
    [[ "$(env_get OPENVPN_USER)" =~ ^(i|ivpn)-[a-zA-Z0-9]{4}-[a-zA-Z0-9]{4}-[a-zA-Z0-9]{4}$ || -n "$(env_get OPENVPN_PASSWORD)" ]] && return 0
    echo "ivpn needs OPENVPN_PASSWORD when OPENVPN_USER is not your account ID (i-xxxx-xxxx-xxxx) — run ./mediastack.sh configure"
    return 1
}
vpnp_ivpn_questions() { # TYPE
    if [[ "$1" == openvpn ]]; then
        vpn_ask_openvpn_login "IVPN: your account ID (i-xxxx-xxxx-xxxx: no password needed) or your account's email and password." nopass-ok
        return 0
    fi
    vpn_ask_wg_key "IVPN account -> WireGuard -> generate a key: copy the private key."
    vpn_ask_wg_address "The IP address IVPN shows for that key."
}
