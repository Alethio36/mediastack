#!/usr/bin/env bash
# services/gluetun/providers/vpnsecure/provider.sh — VPNSecure (docs/design-vpn.md), from
# gluetun's wiki and source; not tested live by mediastack yet.
# OpenVPN only, and no username: a client certificate (yourusername.crt) and an encrypted
# key (yourusername.key) unlocked by your account password — gluetun re-encrypts the key,
# whose old DES OpenVPN 2.5+ refuses (gluetun's wiki).

vpnp_vpnsecure_name()      { echo "vpnsecure"; }
vpnp_vpnsecure_types()     { echo openvpn; }
vpnp_vpnsecure_filters()   { echo countries cities hostnames; }   # no premium flag: gluetun reads PREMIUM_ONLY and filters nothing by it (Nov 2026)
vpnp_vpnsecure_protocols() { echo udp tcp; }
vpnp_vpnsecure_proven()    { echo ""; }
vpnp_vpnsecure_env()       { echo OPENVPN_CERT OPENVPN_ENCRYPTED_KEY OPENVPN_KEY_PASSPHRASE; }
vpnp_vpnsecure_questions() { # TYPE
    info "VPNSecure's OpenVPN files for manual setup: yourusername.crt and yourusername.key (gluetun's wiki,
setup/providers/vpn-secure.md)."
    vpn_ask_pem OPENVPN_CERT CERTIFICATE "client certificate (yourusername.crt)"
    vpn_ask_pem OPENVPN_ENCRYPTED_KEY "ENCRYPTED PRIVATE KEY" "encrypted key (yourusername.key)"
    local cur; cur=$(env_get OPENVPN_KEY_PASSPHRASE); (( VPN_PROVIDER_CHANGED )) && cur=""
    ask_secret_token "VPNSecure account password — it unlocks the key (input hidden)" "$cur"
    env_set OPENVPN_KEY_PASSPHRASE "$REPLY_VAL"
}
