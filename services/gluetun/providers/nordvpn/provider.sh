#!/usr/bin/env bash
# services/gluetun/providers/nordvpn/provider.sh — NordVPN (docs/design-vpn.md).
# Its credentials come from an access token: NordVPN's API turns the token into
# the WireGuard key (nordlynx_private_key) and the OpenVPN service login
# (username, password — checked against a live account, Nov 2026), so nothing is
# installed on this host and nothing else is asked. gluetun sets its WireGuard
# interface address (10.5.0.2) itself.

vpnp_nordvpn_name()    { echo nordvpn; }
vpnp_nordvpn_types()   { echo wireguard openvpn; }
vpnp_nordvpn_filters() { echo countries cities hostnames; }
vpnp_nordvpn_proven()  { echo "live 2026-09"; }
vpnp_nordvpn_env() { # TYPE
    case "$1" in
        wireguard) echo WIREGUARD_PRIVATE_KEY ;;
        openvpn)   echo OPENVPN_USER OPENVPN_PASSWORD ;;
    esac
}
vpnp_nordvpn_keys() { echo NORDVPN_TOKEN; }   # TYPE — an answers-file key, for either tunnel
# Standard servers only, never a Dedicated IP one: those take only the login of
# the account the address was sold to — AUTH_FAILED over OpenVPN on every retry,
# a silent WireGuard tunnel until the healthcheck moves on (found live Nov 2026:
# us12774, nl1025, nl1032, uk1618, uk2785). gluetun's own exclusion needs a
# "dedicated" flag its NordVPN server data does not carry yet (gluetun-servers,
# 6 Nov 2026; its issue #3497). A P2P server is a standard one too (any match).
vpnp_nordvpn_extra() { printf 'SERVER_CATEGORIES\tStandard VPN servers\n'; }   # TYPE

nord_creds() { # nord_creds TOKEN TYPE -> NordVPN's service credentials for TOKEN (JSON), holding what TYPE needs; rc 1 with the reason instead
    local out need
    # the login goes in on stdin (-K -), never on the command line where ps shows it
    out=$(curl -fsS -K - "https://api.nordvpn.com/v1/users/services/credentials" <<<"user = \"token:${1}\"") \
        || { echo "Could not reach Nord's API. Check connectivity and retry."; return 1; }
    case "$2" in
        wireguard) need='(.nordlynx_private_key // "") != ""' ;;
        *)         need='(.username // "") != "" and (.password // "") != ""' ;;
    esac
    jq -e "$need" <<<"$out" >/dev/null 2>&1 || { echo "Token rejected by NordVPN — regenerate it and re-run configure."; return 1; }
    echo "$out"
}
nord_wg_key() { # nord_wg_key TOKEN -> the WireGuard private key NordVPN issues for TOKEN; rc 1 with the reason instead
    local j; j=$(nord_creds "$1" wireguard) || { echo "$j"; return 1; }
    jq -r .nordlynx_private_key <<<"$j"
}
nord_record() { # nord_record TOKEN TYPE — what TYPE needs, fetched for TOKEN, into .env; rc 1 with the reason instead
    local j
    j=$(nord_creds "$1" "$2") || { echo "$j"; return 1; }
    case "$2" in
        wireguard) env_set WIREGUARD_PRIVATE_KEY "$(jq -r .nordlynx_private_key <<<"$j")" ;;
        openvpn)   env_set OPENVPN_USER "$(jq -r .username <<<"$j")"; env_set OPENVPN_PASSWORD "$(jq -r .password <<<"$j")" ;;
    esac
}

vpnp_nordvpn_questions() { # TYPE
    local what=key; [[ "$1" == openvpn ]] && what="OpenVPN login"
    if [[ -n "$(env_get "$(vpnp_nordvpn_env "$1" | awk '{print $1}')")" ]] && (( ! VPN_PROVIDER_CHANGED )) && ! confirm "A NordVPN $what is already set. Replace it?"; then
        ok "Keeping the existing $what."; return 0
    fi
    explain "NordVPN token" \
"1. Log in at nordvpn.com -> Services -> NordVPN" \
"2. 'Set up NordVPN manually' -> generate an access token" \
"3. Copy it (it is shown only once) and paste it below." \
"The $what is fetched from Nord's API — nothing is installed on this host."
    local why
    ask_token "NordVPN access token (input hidden)"
    why=$(nord_record "$REPLY_VAL" "$1") || die "$why"   # .env is written by the $( ) too: env_set writes the file
    ok "NordVPN $what fetched and verified."
}

vpnp_nordvpn_answers() { # TYPE — NORDVPN_TOKEN turned into the key or login, unless written themselves
    case "$1" in
        wireguard) answer WIREGUARD_PRIVATE_KEY && return 0 ;;
        openvpn)   answer OPENVPN_USER && return 0 ;;
    esac
    answer NORDVPN_TOKEN || return 0
    local why
    why=$(nord_record "$REPLY_VAL" "$1") || answer_refused "NORDVPN_TOKEN: $why"
}
