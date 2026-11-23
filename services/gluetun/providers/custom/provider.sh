#!/usr/bin/env bash
# services/gluetun/providers/custom/provider.sh — your own WireGuard or OpenVPN
# config (docs/design-vpn.md): a provider gluetun does not know, a server you
# run, or a config file a provider hands out. A server given by name is looked
# up from this host and kept current (provider.sh, "an endpoint by name").
#   WireGuard: the .conf is read into .env — [Interface] PrivateKey and Address,
#   [Peer] PublicKey, PresharedKey and Endpoint — each value checked, the line at
#   fault named; secrets keep one home (.env). DNS and AllowedIPs lines are left
#   to gluetun (its own encrypted DNS; the whole of the traffic).
#   OpenVPN: the .ovpn is yours, kept as custom/vpn/openvpn.ovpn (copied there by
#   configure, never rewritten). gluetun reads its first `remote` and refuses a
#   name there (its source, Nov 2026), so what it runs is a copy rendered into
#   local/vpn-files/ (0600: the file holds your keys) with that remote's address
#   looked up and the other remotes left out — mounted read-only. Its username
#   and password are asked only when the file has `auth-user-pass`.

vpn_custom_ovpn() { echo "$CUSTOM_DIR/vpn/openvpn.ovpn"; }   # yours
vpn_custom_run()  { echo "$(vpn_files_dir)/custom.ovpn"; }   # what gluetun runs (generated)
VPN_CUSTOM_MOUNT=/mediastack/vpn.ovpn              # where gluetun reads it

vpnp_custom_name()      { echo custom; }
vpnp_custom_types()     { echo wireguard openvpn; }
vpnp_custom_filters()   { echo; }   # one server: nothing to choose among
vpnp_custom_protocols() { echo; }   # the .ovpn says it (gluetun reads it from the file)
vpnp_custom_proven()    { echo ""; }
vpnp_custom_env() { # TYPE
    case "$1" in
        wireguard) echo WIREGUARD_PRIVATE_KEY WIREGUARD_ADDRESSES WIREGUARD_PUBLIC_KEY WIREGUARD_ENDPOINT_PORT ;;
        openvpn)   echo ;;   # all of it is in the file; its login is optional (extra)
    esac
}
vpnp_custom_keys() { # TYPE — read beyond env and extra (the answers-file keys too)
    case "$1" in
        wireguard) echo WIREGUARD_ENDPOINT_HOST WIREGUARD_CONF ;;
        openvpn)   echo OPENVPN_CONF ;;
    esac
}
vpnp_custom_extra() { # TYPE — the endpoint's address (not a secret), the optional keys as references
    case "$1" in
        wireguard)
            printf 'WIREGUARD_ENDPOINT_IP\t%s\n' "$(vpn_endpoint_ip)"
            printf 'WIREGUARD_PRESHARED_KEY\t${WIREGUARD_PRESHARED_KEY:-}\n' ;;
        openvpn)
            printf 'OPENVPN_CUSTOM_CONFIG\t%s\n' "$VPN_CUSTOM_MOUNT"
            printf 'OPENVPN_USER\t${OPENVPN_USER:-}\n'
            printf 'OPENVPN_PASSWORD\t${OPENVPN_PASSWORD:-}\n' ;;
    esac
}
vpnp_custom_endpoint() { # TYPE — the server the config names
    case "$1" in
        wireguard) env_get WIREGUARD_ENDPOINT_HOST ;;
        openvpn)   if [[ -r "$(vpn_custom_ovpn)" ]] && ovpn_read "$(vpn_custom_ovpn)"; then echo "${OVPN[Host]}"; fi ;;
    esac
    return 0
}
vpnp_custom_mounts() { # TYPE
    if [[ "$1" == openvpn ]]; then printf '%s\t%s\n' "$(vpn_custom_run)" "$VPN_CUSTOM_MOUNT"; fi
    return 0
}
vpnp_custom_prepare() { # TYPE — the copy gluetun runs: your .ovpn, its first remote at the address looked up
    [[ "$1" == openvpn ]] || return 0
    local a; a=$(vpn_endpoint_ip)
    if [[ -z "$a" ]] || ! ovpn_read "$(vpn_custom_ovpn)" 2>/dev/null; then rm -f "$(vpn_custom_run)"; return 0; fi   # check says why
    install -d -m 700 "$(dirname "$(vpn_custom_run)")"; repo_owned "$(dirname "$(vpn_custom_run)")"
    local tmp; tmp=$(mktemp); chmod 600 "$tmp"
    ovpn_render "$(vpn_custom_ovpn)" "$a" > "$tmp"
    if cmp -s "$tmp" "$(vpn_custom_run)" 2>/dev/null; then rm -f "$tmp"
    else mv -f "$tmp" "$(vpn_custom_run)"; repo_owned "$(vpn_custom_run)"; fi
}
vpnp_custom_check() { # TYPE
    local h
    if [[ "$1" == openvpn ]]; then
        [[ -r "$(vpn_custom_ovpn)" ]] || { echo "custom (OpenVPN) needs your config at custom/vpn/openvpn.ovpn — run ./mediastack.sh configure"; return 1; }
        ovpn_read "$(vpn_custom_ovpn)" || { echo "custom/vpn/openvpn.ovpn won't do — $OVPN_PROBLEM"; return 1; }
        if (( OVPN[Auth] )) && [[ -z "$(env_get OPENVPN_USER)" ]]; then
            echo "custom/vpn/openvpn.ovpn asks for a login (auth-user-pass) and OPENVPN_USER is empty — run ./mediastack.sh configure"; return 1
        fi
        h=${OVPN[Host]}
    else
        h=$(env_get WIREGUARD_ENDPOINT_HOST)
        if [[ -z "$h" ]]; then echo "custom needs WIREGUARD_ENDPOINT_HOST (the [Peer] Endpoint of your config) — run ./mediastack.sh configure"; return 1; fi
    fi
    if [[ -z "$(vpn_endpoint_ip)" ]]; then echo "the VPN server's name $h has not been looked up yet — ./mediastack.sh up looks it up first"; return 1; fi
    return 0
}

# ---- an OpenVPN config file ----
OVPN_PROBLEM=""      # why the last read failed
OVPN_BLOCK_RE='^<([a-z-]+)>$'   # an inline block's opening line (a variable: \< in a [[ =~ ]] is a word boundary)
declare -gA OVPN=()  # what it held: Host Port Proto (its first remote) Auth (1: it asks for a login)
ovpn_read() { # ovpn_read FILE -> OVPN from an OpenVPN config; rc 1 with OVPN_PROBLEM ("line N: ...")
    local line n=0 blk="" host="" port="" proto="" dport="" dproto="" auth=0; local -a f
    OVPN=(); OVPN_PROBLEM=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        line=${line//$'\r'/}
        line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
        if [[ -n "$blk" ]]; then [[ "$line" == "</$blk>" ]] && blk=""; continue; fi   # inline <ca>, <cert>, <key>: not read here
        [[ -n "$line" && "$line" != [#\;]* ]] || continue
        if [[ "$line" =~ $OVPN_BLOCK_RE ]]; then
            blk=${BASH_REMATCH[1]}
            [[ "$blk" != connection ]] || { OVPN_PROBLEM="line $n: a <connection> block — one server per config (gluetun connects to one): keep a single remote line"; return 1; }
            continue
        fi
        read -ra f <<<"$line"
        case "${f[0]}" in
            remote)
                [[ -z "$host" ]] || continue   # gluetun takes the first; the copy it runs keeps only that one
                (( ${#f[@]} >= 2 && ${#f[@]} <= 4 )) || { OVPN_PROBLEM="line $n: '$line' is not 'remote HOST [PORT [PROTO]]'"; return 1; }
                host=${f[1]}; port=${f[2]:-}; proto=${f[3]:-} ;;
            port)  dport=${f[1]:-} ;;
            proto) dproto=${f[1]:-} ;;
            auth-user-pass) auth=1 ;;
        esac
    done < "$1"
    [[ -n "$host" ]] || { OVPN_PROBLEM="it has no remote line (the server to connect to)"; return 1; }
    local p; p=$(wg_endpoint_problem "$host"); [[ -z "$p" ]] || { OVPN_PROBLEM="remote: $p"; return 1; }
    proto=${proto:-${dproto:-udp}}
    case "$proto" in
        udp|udp4|udp6) proto=udp ;;
        tcp|tcp4|tcp6|tcp-client) proto=tcp ;;
        *) OVPN_PROBLEM="proto '$proto' is not one gluetun runs (udp or tcp)"; return 1 ;;
    esac
    port=${port:-${dport:-$( [[ "$proto" == tcp ]] && echo 443 || echo 1194 )}}   # gluetun's own defaults
    env_type_ok port "$port" || { OVPN_PROBLEM="remote: '$port' is not a port"; return 1; }
    OVPN=([Host]=$host [Port]=$port [Proto]=$proto [Auth]=$auth)
}
ovpn_render() { # ovpn_render FILE ADDRESS -> the file, its first remote at ADDRESS (port and protocol written out), every other remote left out
    awk -v a="$2" -v p="${OVPN[Port]}" -v pr="${OVPN[Proto]}" '
        { l = $0; sub(/\r$/, "", l); t = l; sub(/^[ \t]+/, "", t) }
        blk != "" { print l; if (t == "</" blk ">") blk = ""; next }
        t ~ /^<[a-z-]+>$/ { blk = substr(t, 2, length(t) - 2); print l; next }
        t ~ /^remote[ \t]/ { if (!done) { print "remote " a " " p " " pr; done = 1 } next }
        { print l }' "$1"
}
ovpn_take() { # ovpn_take FILE — your .ovpn, read, kept as custom/vpn/openvpn.ovpn (0600: it holds your keys); rc 1 with OVPN_PROBLEM
    ovpn_read "$1" || return 1
    install -d -m 700 "$(dirname "$(vpn_custom_ovpn)")"; repo_owned "$CUSTOM_DIR" "$(dirname "$(vpn_custom_ovpn)")"
    if [[ "$(abspath "$1")" != "$(abspath "$(vpn_custom_ovpn)")" ]]; then install -m 600 "$1" "$(vpn_custom_ovpn)"; fi
    chmod 600 "$(vpn_custom_ovpn)"; repo_owned "$(vpn_custom_ovpn)"
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
    if [[ "$1" == openvpn ]]; then custom_ovpn_questions; return 0; fi
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

vpnp_custom_answers() { # TYPE — WIREGUARD_CONF read in, or the keys written one by one (WIREGUARD_ENDPOINT_HOST and the pre-shared key here); OpenVPN: OPENVPN_CONF
    local p
    if [[ "$1" == openvpn ]]; then custom_ovpn_answers; return 0; fi
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

custom_ovpn_questions() { # your .ovpn, and its login when it asks for one
    if [[ -r "$(vpn_custom_ovpn)" ]] && ovpn_read "$(vpn_custom_ovpn)" && (( ! VPN_PROVIDER_CHANGED )) \
        && ! confirm "An OpenVPN config is already in custom/vpn/openvpn.ovpn (server ${OVPN[Host]}). Use another?"; then
        ok "Keeping it."
    else
        explain "Your OpenVPN config" \
"The .ovpn file your provider or your own server gives you. It is kept as
custom/vpn/openvpn.ovpn (yours: never rewritten); its first remote is the
server — a name is looked up from this host and kept current."
        local f
        while true; do
            ask OPENVPN_CONF "OpenVPN config file (.ovpn, its path)" ""
            f=$(abspath "${REPLY_VAL/#\~/$HOME}")
            [[ -r "$f" ]] || { fail "'$f' cannot be read"; continue; }
            ovpn_take "$f" && break
            fail "That config won't do — $OVPN_PROBLEM"
        done
        ok "read: server ${OVPN[Host]}:${OVPN[Port]} over ${OVPN[Proto]}$( (( OVPN[Auth] )) && echo ", a login (auth-user-pass)")"
        ip_literal "${OVPN[Host]}" || info "the server is given by name: up looks it up from this host, and the 5-minute check keeps it current"
    fi
    if (( OVPN[Auth] )); then vpn_ask_openvpn_login "The username and password your provider gives for this config." nopass-ok
    else env_set OPENVPN_USER ""; env_set OPENVPN_PASSWORD ""; fi
}
custom_ovpn_answers() { # OPENVPN_CONF taken in; OPENVPN_USER and OPENVPN_PASSWORD when it asks for a login
    if answer OPENVPN_CONF; then
        ovpn_take "$REPLY_VAL" || { answer_refused "OPENVPN_CONF: $OVPN_PROBLEM"; return 0; }
    elif ! { [[ -r "$(vpn_custom_ovpn)" ]] && ovpn_read "$(vpn_custom_ovpn)"; }; then
        answer_refused "the VPN (custom, openvpn) needs OPENVPN_CONF — your .ovpn file"; return 0
    fi
    local k
    for k in OPENVPN_USER OPENVPN_PASSWORD; do
        if answer "$k"; then env_set "$k" "$REPLY_VAL"; fi
    done
    if (( OVPN[Auth] )) && [[ -z "$(env_get OPENVPN_USER)" ]]; then
        answer_refused "the VPN (custom, openvpn): your .ovpn asks for a login (auth-user-pass) — OPENVPN_USER and OPENVPN_PASSWORD"
    fi
}
