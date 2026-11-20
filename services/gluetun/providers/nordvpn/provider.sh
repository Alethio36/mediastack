#!/usr/bin/env bash
# services/gluetun/providers/nordvpn/provider.sh — NordVPN (docs/design-vpn.md).
# Its WireGuard key comes from an access token: NordVPN's API turns the token
# into the key (nordlynx_private_key), so nothing is installed on this host.
# gluetun sets its interface address (10.5.0.2) itself.

vpnp_nordvpn_name()    { echo nordvpn; }
vpnp_nordvpn_types()   { echo wireguard; }
vpnp_nordvpn_filters() { echo countries cities hostnames; }
vpnp_nordvpn_proven()  { echo "live 2026-09"; }
vpnp_nordvpn_env()     { echo WIREGUARD_PRIVATE_KEY; }

nord_wg_key() { # nord_wg_key TOKEN -> the WireGuard private key NordVPN issues for TOKEN; rc 1 with the reason instead
    local key
    # the login goes in on stdin (-K -), never on the command line where ps shows it
    key=$(curl -fsS -K - "https://api.nordvpn.com/v1/users/services/credentials" \
              <<<"user = \"token:${1}\"" \
          | jq -r '.nordlynx_private_key // empty') \
        || { echo "Could not reach Nord's API. Check connectivity and retry."; return 1; }
    [[ -n "$key" ]] || { echo "Token rejected by NordVPN — regenerate it and re-run configure."; return 1; }
    echo "$key"
}

vpnp_nordvpn_questions() { # TYPE
    if [[ -n "$(env_get WIREGUARD_PRIVATE_KEY)" ]] && (( ! VPN_PROVIDER_CHANGED )) && ! confirm "A WireGuard key is already set. Replace it?"; then
        ok "Keeping existing key."; return 0
    fi
    explain "NordVPN token" \
"1. Log in at nordvpn.com -> Services -> NordVPN" \
"2. 'Set up NordVPN manually' -> generate an access token" \
"3. Copy it (it is shown only once) and paste it below." \
"The key is fetched from Nord's API — nothing is installed on this host."
    local key
    ask_token "NordVPN access token (input hidden)"
    key=$(nord_wg_key "$REPLY_VAL") || die "$key"
    env_set WIREGUARD_PRIVATE_KEY "$key"
    ok "WireGuard key fetched and verified."
}

vpnp_nordvpn_answers() { # TYPE — NORDVPN_TOKEN turned into the key, unless the key itself is written
    answer WIREGUARD_PRIVATE_KEY && return 0
    answer NORDVPN_TOKEN || return 0
    local key
    key=$(nord_wg_key "$REPLY_VAL") || { answer_refused "NORDVPN_TOKEN: $key"; return 0; }
    env_set WIREGUARD_PRIVATE_KEY "$key"
}
