#!/usr/bin/env bash
# services/gluetun/questions.sh — configure's VPN step: which provider (a
# folder of services/gluetun/providers), its credentials (the provider's own
# questions) and its server choices (checked against gluetun's own server
# list when its image is on this host). Called by the questionnaire at its place
# (after the download client) and by enable's questions when gluetun is among
# what it brings — not through the <name>_questions hook, whose order would
# move it. It asks and records, as every question does (docs/adding-a-service.md);
# a provider's own question may call that provider's account API (NordVPN's,
# to turn a token into a key) and nothing else.

vpn_choices_list() { printf '%s\n' "$@" | paste -sd, | sed 's/,/, /g' | fold -s -w 78 | sed 's/^/  /'; }   # vpn_choices_list CHOICE... — for "?" at a choice's prompt
vpn_ask_filter() { # vpn_ask_filter NAME FILTER — one server choice (empty: any), checked against gluetun's server list when it is on this host (VPN_SERVERS), recorded as the list spells it
    local key=${VPN_FILTER_KEY[$2]} title v item c p anyis="no limit"; local -a choices=() items out
    title="Server ${VPN_FILTER_ONE[$2]}"
    if vpnp_has "$1" filter_default && [[ -n "$(vpnp_call "$1" filter_default "$2")" ]]; then anyis="$1's default, $(vpnp_call "$1" filter_default "$2")"; fi
    if q_quick; then v=$(vpn_filter_value "$1" "$2"); q_took "$title" "${v:-any}"; return 0; fi
    if [[ -n "$VPN_SERVERS" ]]; then
        vpn_filters_before "$1" "$2"
        mapfile -t choices < <(vpn_servers_query "$1" "${VPN_FILTER_FIELD[$2]}" "$VPN_PRIOR")
        if (( ${#choices[@]} == 0 )); then   # none among the servers the choices before keep: nothing to choose
            if [[ -n "$(env_get "$key")" ]]; then info "$key cleared: $(vpn_servers_said "$1" "$VPN_WITH") have no ${VPN_FILTER_ONE[$2]}"; env_set "$key" ""; fi
            return 0
        fi
    fi
    while true; do
        ask "$key" "$title ($( (( ${#choices[@]} )) && echo "? lists the ${#choices[@]}; " )comma-separated; any = $anyis)" "$(env_or_note "$key" any)"
        if [[ "$REPLY_VAL" == "?" ]]; then
            if (( ${#choices[@]} )); then vpn_choices_list "${choices[@]}"; else info "the list needs gluetun's image on this host — up checks the choice against it"; fi
            continue
        fi
        v=$(vpn_list_tidy "$REPLY_VAL"); p=""
        if [[ -n "$v" ]] && (( ${#choices[@]} )); then
            IFS=, read -ra items <<<"$v"; out=()
            for item in "${items[@]}"; do
                if c=$(vpn_choice_match "$item" "${choices[@]}"); then out+=("$c"); continue; fi
                p="no ${VPN_FILTER_ONE[$2]} '$item' among $(vpn_servers_said "$1" "$VPN_WITH") — $(vpn_close_matches "$item" "${choices[@]}")"; break
            done
            v=$(IFS=,; echo "${out[*]}")
        fi
        [[ -n "$p" ]] || break
        fail "$p"
    done
    env_set "$key" "$v"
}
vpn_flags_problem() { # vpn_flags_problem NAME LIST -> why LIST is not flags of NAME's ("" when it is)
    local f
    for f in ${2//,/ }; do
        [[ " $(vpnp_flags "$1") " == *" $f "* ]] || { echo "'$f' is no server flag of $1's — its flags: $(vpnp_flags "$1" | sed 's/ /, /g')"; return 0; }
    done
}
vpn_ask_flags() { # vpn_ask_flags NAME — the server flags (empty: none), recorded; asked before the filters, whose lists they narrow
    local f v p
    if q_quick; then q_took "Server flags" "$(env_or_note VPN_SERVER_FLAGS none)"; return 0; fi
    info "$1 can keep to servers that are: $(for f in $(vpnp_flags "$1"); do printf '%s (%s); ' "$f" "${VPN_FLAG_SAYS[$f]}"; done | sed 's/; $//')"
    while true; do
        ask VPN_SERVER_FLAGS "Server flags ($(vpnp_flags "$1" | tr ' ' /), comma-separated; none = any server)" "$(env_or_note VPN_SERVER_FLAGS none)"
        v=$(vpn_list_tidy "${REPLY_VAL,,}"); [[ "$v" != none ]] || v=""
        p=$(vpn_flags_problem "$1" "$v")
        if [[ -z "$p" && -n "$v" && -n "$VPN_SERVERS" ]]; then   # together they must leave a server
            env_set VPN_SERVER_FLAGS "$v"
            [[ "$(vpn_servers_query "$1" "" '{}')" -gt 0 ]] || p="no server of $1's is all of $v — $(vpn_servers_said "$1")"
        fi
        [[ -n "$p" ]] || break
        fail "$p"
    done
    env_set VPN_SERVER_FLAGS "$v"
}
vpn_ask_portforward() { # vpn_ask_portforward NAME TYPE — a port forwarded to the download client, asked only where NAME forwards one; recorded (off where it cannot)
    local kind p; kind=$(vpnp_portforward "$1")
    if [[ -z "$kind" ]]; then
        [[ "$(env_get VPN_PORT_FORWARDING)" != on ]] || env_set VPN_PORT_FORWARDING off
        return 0
    fi
    if q_quick; then q_took "Port forwarding" "$(env_get VPN_PORT_FORWARDING)"; return 0; fi
    info "$1 can forward a port to the download client, so peers can connect in — better for seeding.
Off changes nothing for downloads.$( [[ "$kind" == static ]] && echo " $1 forwards the port you set on its site: you give it next." )"
    local yes=0
    if [[ "$(env_get VPN_PORT_FORWARDING)" == on ]]; then confirm_yes "Forward a port?" && yes=1; else confirm "Forward a port?" && yes=1; fi
    if (( ! yes )); then env_set VPN_PORT_FORWARDING off; env_set VPN_FORWARDED_PORT ""; return 0; fi
    env_set VPN_PORT_FORWARDING on
    if [[ "$kind" == static ]]; then
        while true; do
            ask VPN_FORWARDED_PORT "The port $1's site forwards to you" "$(env_get VPN_FORWARDED_PORT)"
            p=$(pf_port_problem "$REPLY_VAL"); [[ -n "$p" ]] || break
            fail "$p"
        done
        env_set VPN_FORWARDED_PORT "$REPLY_VAL"
    else
        env_set VPN_FORWARDED_PORT ""
    fi
    if vpnp_has "$1" portforward_on; then vpnp_call "$1" portforward_on "$2"; fi
}
vpn_ask_server_choices() { # vpn_ask_server_choices NAME — the server choices NAME offers: its flags first (they narrow every list), then each filter in order but hostnames (set in .env only)
    local f p
    [[ -n "$(vpnp_call "$1" filters | tr -d '[:space:]')" ]] || return 0
    VPN_SERVERS=""
    if ! q_quick && ! vpn_servers_load "$1"; then info "Server choices are not checked here: $VPN_SERVERS_ERR — up checks them against gluetun's server list."; fi
    if vpnp_filter_on "$1" flags; then vpn_ask_flags "$1"; fi
    for f in $VPN_FILTER_ORDER; do
        if [[ "$f" != hostnames ]] && vpnp_filter_on "$1" "$f"; then vpn_ask_filter "$1" "$f"; fi
    done
    [[ -n "$VPN_SERVERS" ]] || return 0
    p=$(vpn_choices_problems "$1")   # VPN_SERVER_HOSTNAMES is never asked: it can still rule them out
    [[ -z "$p" ]] && return 0
    while IFS= read -r f; do fail "$f"; done <<<"$p"
    warn "up refuses to start gluetun with these — change them in .env, or run ./mediastack.sh configure again"
}

vpn_choose_provider() { # -> REPLY_VAL: a provider folder, by its name or its number in the list
    local -a all; local i p cur
    mapfile -t all < <(vpnp_list)
    cur=$(env_get VPN_PROVIDER)
    for i in "${!all[@]}"; do
        vpnp_load "${all[$i]}"
        local note; note=$(vpnp_call "${all[$i]}" types | sed 's/ /, /g')
        [[ "${all[$i]}" == custom ]] && note="your own WireGuard or OpenVPN config"
        [[ -n "$(vpnp_call "${all[$i]}" proven)" ]] || note+=" — not tested by mediastack yet: tell us how it goes"
        printf '  %2d) %-24s %s\n' "$((i + 1))" "${all[$i]}" "$note"
    done
    while true; do
        ask VPN_PROVIDER "VPN provider (its name or number)" "$cur"
        p=${REPLY_VAL,,}
        if [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= ${#all[@]} )); then p=${all[$((p - 1))]}; fi
        [[ -z "$(vpn_provider_problem "$p")" ]] && break
        fail "$(vpn_provider_problem "$p")"
    done
    REPLY_VAL=$p
}

gluetun_vpn_from_answers() { # the VPN from the answers file; a blank keeps what is set
    local prov t k p mine all pr protos changed=0
    prov=$(env_get VPN_PROVIDER); answer VPN_PROVIDER && prov=${REPLY_VAL,,}
    p=$(vpn_provider_problem "$prov"); [[ -z "$p" ]] || { answer_refused "VPN_PROVIDER: $p"; return 0; }
    [[ "$prov" != "$(env_get VPN_PROVIDER)" ]] && changed=1
    t=$(vpn_type_default "$prov"); answer VPN_TYPE && t=${REPLY_VAL,,}
    [[ " $(vpnp_call "$prov" types) " == *" $t "* ]] || { answer_refused "VPN_TYPE=$t: mediastack runs $prov with $(vpnp_call "$prov" types | sed 's/ / or /g') only"; return 0; }
    [[ "$t" != "$(env_get VPN_TYPE)" ]] && changed=1
    VPN_PROVIDER_CHANGED=$changed
    env_set VPN_PROVIDER "$prov"; env_set VPN_TYPE "$t"
    # a key another provider reads, or this one over the other tunnel, is refused: it would do nothing here
    mine=" $(vpnp_type_keys "$prov" "$t" | tr '\n' ' ') "; all=" $(vpnp_keys "$prov" | tr '\n' ' ') "
    for k in $(vpn_all_keys); do
        if [[ "$mine" == *" $k "* ]] || ! answers_any "$k"; then continue; fi
        if [[ "$all" == *" $k "* ]]; then answer_refused "$k is for $prov over the other tunnel — VPN_TYPE is $t"
        else answer_refused "$k is for another VPN provider — VPN_PROVIDER is $prov"; fi
    done
    # a new provider or tunnel takes nothing the old one made: every key it reads comes from this file
    if (( changed )); then
        vpn_keys_drop_others "$prov" "$t"
        for k in $(vpnp_call "$prov" env "$t"); do env_set "$k" ""; done
    fi
    # the provider's own answers first (a token turned into a key), then its keys as written
    if vpnp_has "$prov" answers; then vpnp_call "$prov" answers "$t"; fi
    for k in $(vpnp_call "$prov" env "$t"); do
        if answer "$k"; then
            p=$(vpn_key_problem "$k" "$REPLY_VAL"); [[ -z "$p" ]] || { answer_refused "$k: $p"; continue; }
            env_set "$k" "$REPLY_VAL"
        fi
        [[ -n "$(env_get "$k")" ]] || answer_refused "the VPN ($prov, $t) needs $k$(vpnp_has "$prov" answers && echo " — or $prov's own key (answers.example, its lines)")"
    done
    protos=$(vpnp_protocols "$prov")
    if [[ "$t" == openvpn && -n "$protos" ]]; then
        pr=$(env_get OPENVPN_PROTOCOL); answer OPENVPN_PROTOCOL && pr=${REPLY_VAL,,}
        if [[ " $protos " == *" $pr "* ]]; then env_set OPENVPN_PROTOCOL "$pr"
        elif answers_any OPENVPN_PROTOCOL; then answer_refused "OPENVPN_PROTOCOL=$pr: $prov has OpenVPN servers over $(sed 's/ / and /g' <<<"$protos") only"
        else env_set OPENVPN_PROTOCOL "${protos%% *}"; fi
    elif answers_any OPENVPN_PROTOCOL && answer OPENVPN_PROTOCOL; then
        answer_refused "OPENVPN_PROTOCOL: $( [[ "$t" == openvpn ]] && echo "$prov's OpenVPN config file says it" || echo "only for VPN_TYPE=openvpn — VPN_TYPE is $t" )"
    fi
    # port forwarding, before the server choices: it narrows them (forwarding servers only, for some)
    local kind; kind=$(vpnp_portforward "$prov")
    if answer VPN_PORT_FORWARDING; then
        if [[ "$REPLY_VAL" == on && -z "$kind" ]]; then answer_refused "VPN_PORT_FORWARDING=on: mediastack forwards no port with $prov (it does with: $(vpn_pf_providers | paste -sd' ' | sed 's/ /, /g'))"
        else env_set VPN_PORT_FORWARDING "$REPLY_VAL"; fi
    elif [[ -z "$kind" && "$(env_get VPN_PORT_FORWARDING)" == on ]]; then env_set VPN_PORT_FORWARDING off
    fi
    if answer VPN_FORWARDED_PORT; then
        if [[ "$kind" != static || "$(env_get VPN_PORT_FORWARDING)" != on ]]; then answer_refused "VPN_FORWARDED_PORT: only for VPN_PORT_FORWARDING=on with a provider that forwards a port you set (AirVPN, Windscribe) — $prov $( [[ "$kind" == native ]] && echo "arranges its own" || echo "with forwarding off" )"
        else p=$(pf_port_problem "$REPLY_VAL"); [[ -z "$p" ]] || answer_refused "VPN_FORWARDED_PORT: $p"; env_set VPN_FORWARDED_PORT "$REPLY_VAL"; fi
    elif [[ "$kind" != static || "$(env_get VPN_PORT_FORWARDING)" != on ]] && [[ -n "$(env_get VPN_FORWARDED_PORT)" ]]; then env_set VPN_FORWARDED_PORT ""
    fi
    if [[ "$(vpn_pf_kind "$prov")" == static && -z "$(env_get VPN_FORWARDED_PORT)" ]]; then answer_refused "VPN_PORT_FORWARDING=on: $prov forwards the port you set on its site — write it as VPN_FORWARDED_PORT"; fi
    if [[ -n "$(vpn_pf_kind "$prov")" ]] && vpnp_has "$prov" portforward_on; then vpnp_call "$prov" portforward_on "$t"; fi
    local f key v
    for f in flags $VPN_FILTER_ORDER; do
        [[ "$f" != hostnames ]] || continue   # .env only: never asked
        key=${VPN_FILTER_KEY[$f]}
        if ! vpnp_filter_on "$prov" "$f"; then
            if answers_any "$key"; then answer_refused "$key: $prov does not choose servers by ${VPN_FILTER_ONE[$f]}"; fi
            continue
        fi
        answer "$key" || continue
        v=$(vpn_list_tidy "$REPLY_VAL")
        if [[ "$f" == flags ]]; then
            v=${v,,}; [[ "$v" != none ]] || v=""
            p=$(vpn_flags_problem "$prov" "$v"); [[ -z "$p" ]] || { answer_refused "VPN_SERVER_FLAGS: $p"; continue; }
        fi
        env_set "$key" "$v"
    done
    # each against gluetun's server list, when its image is on this host (up checks them otherwise)
    if [[ -n "$(vpnp_call "$prov" filters | tr -d '[:space:]')" ]]; then
        if vpn_servers_load "$prov"; then
            while IFS= read -r p; do [[ -z "$p" ]] || answer_refused "$p"; done <<<"$(vpn_choices_problems "$prov")"
        fi
    fi
    vpn_protocol_tidy "$prov" "$t"
    q_answered "VPN" "$prov ($t$( [[ "$t" == openvpn && -n "$protos" ]] && echo " over $(env_get OPENVPN_PROTOCOL)" )), its login set, $(vpn_servers_words "$prov")$(vpn_pf_words "$prov")"
}

gluetun_vpn_questions() { # configure's VPN step — only when something runs in the VPN
    svc_enabled gluetun || return 0
    local cur curt prov t
    cur=$(env_get VPN_PROVIDER); curt=$(env_get VPN_TYPE)
    local -a keys; mapfile -t keys < <(vpn_all_keys)
    local f; for f in flags $VPN_FILTER_ORDER; do keys+=("${VPN_FILTER_KEY[$f]}"); done
    if answers_any VPN_PROVIDER VPN_TYPE OPENVPN_PROTOCOL VPN_PORT_FORWARDING VPN_FORWARDED_PORT "${keys[@]}"; then gluetun_vpn_from_answers; return 0; fi
    if q_quick && vpnp_load "$cur" && [[ -z "$(vpn_provider_problems)" ]]; then vpn_protocol_tidy "$cur" "$curt"; q_took "VPN" "keep $cur ($curt) and its login"; return 0; fi
    if answers_checking; then q_unasked "VPN" "VPN_PROVIDER and its keys (answers.example, the gluetun lines)"; return 0; fi
    explain "VPN (gluetun)" \
"All download traffic runs inside a VPN container. Pick your provider from the
list (each is a folder of services/gluetun/providers — gluetun's own names),
or 'custom' to give your own WireGuard or OpenVPN config."
    vpn_choose_provider; prov=$REPLY_VAL
    vpn_ask_type "$prov"; t=$REPLY_VAL
    # a new provider or tunnel: a key the old one made is not offered as the current one
    VPN_PROVIDER_CHANGED=0; [[ "$prov" != "$cur" || "$t" != "$curt" ]] && VPN_PROVIDER_CHANGED=1
    env_set VPN_PROVIDER "$prov"; env_set VPN_TYPE "$t"
    if (( VPN_PROVIDER_CHANGED )); then vpn_keys_drop_others "$prov" "$t"; fi
    vpnp_call "$prov" questions "$t"
    if [[ "$t" == openvpn ]]; then vpn_ask_protocol "$prov"; fi
    vpn_protocol_tidy "$prov" "$t"   # nothing left that this provider and tunnel do not read
    vpn_ask_portforward "$prov" "$t"   # before the server choices: forwarding narrows them for some
    vpn_ask_server_choices "$prov"
}
