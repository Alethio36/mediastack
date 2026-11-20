#!/usr/bin/env bash
# services/gluetun/questions.sh — configure's VPN step: which provider (a
# folder of services/gluetun/providers), its credentials (the provider's own
# questions) and its server choices. Called by the questionnaire at its place
# (after the download client) and by enable's questions when gluetun is among
# what it brings — not through the <name>_questions hook, whose order would
# move it. It asks and records, as every question does (docs/adding-a-service.md);
# a provider's own question may call that provider's account API (NordVPN's,
# to turn a token into a key) and nothing else.

vpn_ask_countries() { # vpn_ask_countries "prompt" — the countries to choose servers in (empty: any), recorded
    if q_quick; then q_took "Server country" "$(env_or_note VPN_SERVER_COUNTRIES auto)"; return 0; fi
    local p
    while true; do
        ask VPN_SERVER_COUNTRIES "$1" "$(env_get VPN_SERVER_COUNTRIES)"
        p=$(vpn_countries_problem "$REPLY_VAL"); [[ -z "$p" ]] && break
        fail "$p"
    done
    env_set VPN_SERVER_COUNTRIES "$REPLY_VAL"
}

vpn_choose_provider() { # -> REPLY_VAL: a provider folder, by its name or its number in the list
    local -a all; local i p cur
    mapfile -t all < <(vpnp_list)
    cur=$(env_get VPN_PROVIDER)
    for i in "${!all[@]}"; do
        vpnp_load "${all[$i]}"
        local note; note=$(vpnp_call "${all[$i]}" types | sed 's/ /, /g')
        [[ "${all[$i]}" == custom ]] && note="your own WireGuard config"
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
    local prov t k p mine
    prov=$(env_get VPN_PROVIDER); answer VPN_PROVIDER && prov=${REPLY_VAL,,}
    p=$(vpn_provider_problem "$prov"); [[ -z "$p" ]] || { answer_refused "VPN_PROVIDER: $p"; return 0; }
    [[ "$prov" != "$(env_get VPN_PROVIDER)" ]] && VPN_PROVIDER_CHANGED=1
    env_set VPN_PROVIDER "$prov"
    t=$(env_get VPN_TYPE); answer VPN_TYPE && t=$REPLY_VAL
    [[ " $(vpnp_call "$prov" types) " == *" $t "* ]] || { answer_refused "VPN_TYPE=$t: mediastack runs $prov with $(vpnp_call "$prov" types) only"; return 0; }
    env_set VPN_TYPE "$t"
    # a key another provider reads is refused: it would do nothing here
    mine=" $(vpnp_keys "$prov" | tr '\n' ' ') "
    for k in $(vpn_all_keys); do
        [[ "$mine" == *" $k "* ]] || ! answers_any "$k" || answer_refused "$k is for another VPN provider — VPN_PROVIDER is $prov"
    done
    # a new provider takes nothing the old one made: every key it reads comes from this file
    if (( VPN_PROVIDER_CHANGED )); then for k in $(vpnp_call "$prov" env "$t"); do env_set "$k" ""; done; fi
    # the provider's own answers first (a token turned into a key), then its keys as written
    if vpnp_has "$prov" answers; then vpnp_call "$prov" answers "$t"; fi
    for k in $(vpnp_call "$prov" env "$t"); do
        if answer "$k"; then
            p=$(vpn_key_problem "$k" "$REPLY_VAL"); [[ -z "$p" ]] || { answer_refused "$k: $p"; continue; }
            env_set "$k" "$REPLY_VAL"
        fi
        [[ -n "$(env_get "$k")" ]] || answer_refused "the VPN ($prov) needs $k$(vpnp_has "$prov" answers && echo " — or $prov's own key (answers.example, its lines)")"
    done
    if vpnp_filter_on "$prov" countries && answer VPN_SERVER_COUNTRIES; then
        p=$(vpn_countries_problem "$REPLY_VAL"); [[ -z "$p" ]] || answer_refused "VPN_SERVER_COUNTRIES: $p"
        env_set VPN_SERVER_COUNTRIES "$REPLY_VAL"
    elif answers_any VPN_SERVER_COUNTRIES && ! vpnp_filter_on "$prov" countries; then
        answer_refused "VPN_SERVER_COUNTRIES: $prov does not choose servers by country"
    fi
    q_answered "VPN" "$prov, key set, servers: $(env_or_note VPN_SERVER_COUNTRIES auto)"
}

gluetun_vpn_questions() { # configure's VPN step — only when something runs in the VPN
    svc_enabled gluetun || return 0
    local cur key prov
    cur=$(env_get VPN_PROVIDER); key=$(env_get WIREGUARD_PRIVATE_KEY)
    local -a keys; mapfile -t keys < <(vpn_all_keys)
    if answers_any VPN_PROVIDER VPN_TYPE VPN_SERVER_COUNTRIES "${keys[@]}"; then gluetun_vpn_from_answers; return 0; fi
    if q_quick && [[ -n "$key" ]] && [[ -z "$(vpn_provider_problems)" ]]; then q_took "VPN" "keep $cur and its key"; return 0; fi
    if answers_checking; then q_unasked "VPN" "VPN_PROVIDER and its keys (answers.example, the gluetun lines)"; return 0; fi
    explain "VPN (gluetun)" \
"All download traffic runs inside a VPN container. Pick your provider from the
list (each is a folder of services/gluetun/providers — gluetun's own names),
or 'custom' to paste your own WireGuard config."
    vpn_choose_provider; prov=$REPLY_VAL
    VPN_PROVIDER_CHANGED=0; [[ "$prov" != "$cur" ]] && VPN_PROVIDER_CHANGED=1
    env_set VPN_PROVIDER "$prov"
    # one type each for now (WireGuard): asked once a provider offers two
    env_set VPN_TYPE "$(vpnp_call "$prov" types | awk '{print $1}')"
    vpnp_call "$prov" questions "$(env_get VPN_TYPE)"
    if vpnp_filter_on "$prov" countries; then vpn_ask_countries "Server country (e.g. Switzerland; Enter = auto)"; fi
}
