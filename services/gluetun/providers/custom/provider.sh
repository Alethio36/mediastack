#!/usr/bin/env bash
# services/gluetun/providers/custom/provider.sh — your own WireGuard config
# (docs/design-vpn.md): a provider gluetun does not know, a server you run, or
# a config file a provider hands out. Its .conf is read into .env — [Interface]
# PrivateKey and Address, [Peer] PublicKey, PresharedKey and Endpoint — each
# value checked, the line at fault named; secrets keep one home (.env). A
# server given by name is looked up from this host and kept current
# (provider.sh, "an endpoint by name"). DNS and AllowedIPs lines are left to
# gluetun (its own encrypted DNS; the whole of the traffic).

vpnp_custom_name()    { echo custom; }
vpnp_custom_types()   { echo wireguard; }
vpnp_custom_filters() { echo; }   # one server: nothing to choose among
vpnp_custom_proven()  { echo ""; }
vpnp_custom_env()     { echo WIREGUARD_PRIVATE_KEY WIREGUARD_ADDRESSES WIREGUARD_PUBLIC_KEY WIREGUARD_ENDPOINT_PORT; }
vpnp_custom_extra() { # TYPE — the endpoint's address (not a secret), and the pre-shared key when there is one
    printf 'WIREGUARD_ENDPOINT_IP\t%s\n' "$(vpn_endpoint_ip)"
    printf 'WIREGUARD_PRESHARED_KEY\t${WIREGUARD_PRESHARED_KEY:-}\n'
}
vpnp_custom_check() { # TYPE
    local h; h=$(env_get WIREGUARD_ENDPOINT_HOST)
    if [[ -z "$h" ]]; then echo "custom needs WIREGUARD_ENDPOINT_HOST (the [Peer] Endpoint of your config) — run ./mediastack.sh configure"; return 1; fi
    if [[ -z "$(vpn_endpoint_ip)" ]]; then echo "the VPN server's name $h has not been looked up yet — ./mediastack.sh up looks it up first"; return 1; fi
    return 0
}

# ---- the config file ----
WGC_PROBLEM=""   # why the last config read failed
declare -gA WGC=()   # what it held: PrivateKey Address PublicKey PresharedKey Host Port
wg_conf_read() { # wg_conf_read FILE -> WGC from a WireGuard config; rc 1 with WGC_PROBLEM ("line N: ...")
    local line n=0 sect="" k v peers=0
    WGC=(); WGC_PROBLEM=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        line=${line%%#*}; line=${line//$'\r'/}
        line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
        [[ -n "$line" ]] || continue
        if [[ "$line" =~ ^\[(Interface|Peer)\]$ ]]; then
            sect=${BASH_REMATCH[1]}
            [[ "$sect" != Peer ]] || peers=$((peers + 1))
            (( peers <= 1 )) || { WGC_PROBLEM="line $n: a second [Peer] — one server per config (gluetun connects to one)"; return 1; }
            continue
        fi
        [[ "$line" =~ ^([A-Za-z]+)[[:space:]]*=[[:space:]]*(.*)$ ]] || { WGC_PROBLEM="line $n: not 'Name = value'"; return 1; }
        k=${BASH_REMATCH[1]}; v=${BASH_REMATCH[2]}
        case "$sect/$k" in
            Interface/PrivateKey|Interface/Address|Peer/PublicKey|Peer/PresharedKey) WGC[$k]=$v ;;
            Peer/Endpoint)
                if [[ "$v" =~ ^\[([0-9A-Fa-f:]+)\]:([0-9]+)$ || "$v" =~ ^([^:]+):([0-9]+)$ ]]; then
                    WGC[Host]=${BASH_REMATCH[1]}; WGC[Port]=${BASH_REMATCH[2]}
                else WGC_PROBLEM="line $n: Endpoint '$v' is not host:port"; return 1; fi ;;
            /*) WGC_PROBLEM="line $n: $k before [Interface] or [Peer]"; return 1 ;;
            *) ;;   # DNS, AllowedIPs, ListenPort, MTU, PersistentKeepalive: gluetun's own
        esac
    done < "$1"
    for k in PrivateKey Address PublicKey Host; do
        [[ -n "${WGC[$k]:-}" ]] || { WGC_PROBLEM="it has no $( [[ "$k" == Host ]] && echo "[Peer] Endpoint" || echo "$k" )"; return 1; }
    done
    local p
    p=$(wg_key_problem "${WGC[PrivateKey]}"); [[ -z "$p" ]] || { WGC_PROBLEM="PrivateKey: $p"; return 1; }
    p=$(wg_key_problem "${WGC[PublicKey]}"); [[ -z "$p" ]] || { WGC_PROBLEM="PublicKey: $p"; return 1; }
    if [[ -n "${WGC[PresharedKey]:-}" ]]; then p=$(wg_key_problem "${WGC[PresharedKey]}"); [[ -z "$p" ]] || { WGC_PROBLEM="PresharedKey: $p"; return 1; }; fi
    p=$(wg_addresses_problem "${WGC[Address]}"); [[ -z "$p" ]] || { WGC_PROBLEM="Address: $p"; return 1; }
    env_type_ok port "${WGC[Port]}" || { WGC_PROBLEM="Endpoint: '${WGC[Port]}' is not a port"; return 1; }
    p=$(wg_endpoint_problem "${WGC[Host]}"); [[ -z "$p" ]] || { WGC_PROBLEM="Endpoint: $p"; return 1; }
    return 0
}
wg_endpoint_problem() { # wg_endpoint_problem HOST -> why HOST is no server name or address ("" when it is)
    ip_literal "$1" && return 0
    [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$ ]] || echo "'$1' is not a server name or address"
}
wg_conf_record() { # what wg_conf_read found, into .env
    env_set WIREGUARD_PRIVATE_KEY "${WGC[PrivateKey]}"
    env_set WIREGUARD_ADDRESSES "${WGC[Address]}"
    env_set WIREGUARD_PUBLIC_KEY "${WGC[PublicKey]}"
    env_set WIREGUARD_PRESHARED_KEY "${WGC[PresharedKey]:-}"
    env_set WIREGUARD_ENDPOINT_HOST "${WGC[Host]}"
    env_set WIREGUARD_ENDPOINT_PORT "${WGC[Port]}"
}

vpnp_custom_questions() { # TYPE
    if [[ -n "$(env_get WIREGUARD_PUBLIC_KEY)" ]] && (( ! VPN_PROVIDER_CHANGED )) \
        && ! confirm "A WireGuard config is already read in (server $(env_get WIREGUARD_ENDPOINT_HOST)). Read another?"; then
        ok "Keeping it."; return 0
    fi
    explain "Your WireGuard config" \
"The .conf file your provider or your own server gives you. Its keys, address
and server are read from it into .env; a server given by name is looked up from
this host and kept current. Give its path — or press Enter and paste it, ending
with an empty line (hidden)."
    local f tmp line
    while true; do
        ask WIREGUARD_CONF "Config file (Enter = paste it)" ""
        f=$REPLY_VAL
        if [[ -z "$f" ]]; then
            tmp=$(mktemp); chmod 600 "$tmp"
            while IFS= read -r -s line && [[ -n "$line" ]]; do printf '%s\n' "$line" >> "$tmp"; done
            f=$tmp
        else
            f=$(abspath "${f/#\~/$HOME}")
            [[ -r "$f" ]] || { fail "'$f' cannot be read"; continue; }
        fi
        if wg_conf_read "$f"; then [[ -z "${tmp:-}" ]] || rm -f "$tmp"; break; fi
        [[ -z "${tmp:-}" ]] || rm -f "$tmp"; tmp=""
        fail "That config won't do — $WGC_PROBLEM"
    done
    wg_conf_record
    ok "read: server ${WGC[Host]}:${WGC[Port]}, address ${WGC[Address]}$( [[ -n "${WGC[PresharedKey]:-}" ]] && echo ", a pre-shared key")"
    ip_literal "${WGC[Host]}" || info "the server is given by name: up looks it up from this host, and the 5-minute check keeps it current"
}

vpnp_custom_answers() { # TYPE — WIREGUARD_CONF read in, or the keys written one by one (WIREGUARD_ENDPOINT_HOST and the pre-shared key here)
    local p
    if answer WIREGUARD_CONF; then
        if wg_conf_read "$REPLY_VAL"; then wg_conf_record; else answer_refused "WIREGUARD_CONF: $WGC_PROBLEM"; fi
        return 0
    fi
    if answer WIREGUARD_ENDPOINT_HOST; then
        p=$(wg_endpoint_problem "$REPLY_VAL"); [[ -z "$p" ]] || { answer_refused "WIREGUARD_ENDPOINT_HOST: $p"; return 0; }
        env_set WIREGUARD_ENDPOINT_HOST "$REPLY_VAL"
    fi
    [[ -n "$(env_get WIREGUARD_ENDPOINT_HOST)" ]] || answer_refused "the VPN (custom) needs WIREGUARD_ENDPOINT_HOST — or WIREGUARD_CONF, your config file"
    if answer WIREGUARD_PRESHARED_KEY; then
        p=$(wg_key_problem "$REPLY_VAL"); [[ -z "$p" ]] || { answer_refused "WIREGUARD_PRESHARED_KEY: $p"; return 0; }
        env_set WIREGUARD_PRESHARED_KEY "$REPLY_VAL"
    fi
}
