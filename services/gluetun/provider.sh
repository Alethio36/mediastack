#!/usr/bin/env bash
# services/gluetun/provider.sh — the VPN provider layer (docs/design-vpn.md):
# every provider gluetun knows is a folder, services/gluetun/providers/<name>/,
# holding everything about it — its credentials' questions, the gluetun
# settings it needs, the server choices it offers, whether it was proven live.
# Nothing outside the folders names a provider: configure's list, the answers
# file, the rendering and doctor find them by listing the folders. This file is
# the generic part: list and load them, render what reaches gluetun
# (local/vpn-provider.yml, ${KEY} references only — no secret in it), and check
# before gluetun starts that it can (the folder, the type, every setting, and
# the gluetun image knowing the provider). Sourced by the entrypoint; the
# folders are not (the loop reaches services/*/*.sh only): one is loaded when
# it is needed, all of them for configure's list.
#
# A provider's folder: provider.sh with six functions, vpnp_<name>_ (hyphens as
# underscores) — name (gluetun's VPN_SERVICE_PROVIDER, exactly), types (what
# mediastack runs it with; the first is the default), filters (its server
# choices, only those gluetun's server data has values for: regions countries
# cities isps categories hostnames flags), proven ("live <date>" once proven on a
# test box; empty: from gluetun's wiki and source only), questions TYPE (ask
# for its credentials and record them), env TYPE (the .env keys gluetun needs,
# each read by gluetun under the same name). Optional, found by name:
# answers TYPE (its own answers-file keys, e.g. a token turned into a key),
# check TYPE (a reason it cannot start: rc 1), extra TYPE (literal gluetun
# settings, NAME<TAB>VALUE — not secrets: the file is 0644), protocols (the
# OpenVPN protocols it has servers for, default "udp tcp"; empty: its config
# file decides), keys TYPE (.env keys it reads beyond env and extra — kept on a
# switch to it), endpoint TYPE (the server name or address its config names,
# for "an endpoint by name"), prepare TYPE (write the files its mounts name,
# under local/) and mounts TYPE (HOST<TAB>CONTAINER, the host path absolute,
# mounted read-only into gluetun; their contents' hash is a label, so a changed
# file recreates gluetun), flags (the server flags it offers, with "flags" among
# its filters: owned free stream secure-core tor) and filter_default FILTER
# (what the filter is when .env leaves it empty — NordVPN's standard servers).
# An env.tsv beside it holds the keys only it reads.

VPN_PROVIDERS_DIR="$SCRIPT_DIR/services/gluetun/providers"
# what a filter is: to gluetun, in .env, in a message, in gluetun's server data
VPN_FILTER_ORDER="categories regions countries cities isps hostnames"   # configure asks and the check narrows in this order, the kind of server first (hostnames never asked)
declare -gA VPN_FILTER_VAR=([regions]=SERVER_REGIONS [countries]=SERVER_COUNTRIES [cities]=SERVER_CITIES [isps]=ISP [categories]=SERVER_CATEGORIES [hostnames]=SERVER_HOSTNAMES)
declare -gA VPN_FILTER_KEY=([regions]=VPN_SERVER_REGIONS [countries]=VPN_SERVER_COUNTRIES [cities]=VPN_SERVER_CITIES [isps]=VPN_SERVER_ISPS [categories]=VPN_SERVER_CATEGORIES [hostnames]=VPN_SERVER_HOSTNAMES [flags]=VPN_SERVER_FLAGS)
declare -gA VPN_FILTER_ONE=([regions]=region [countries]=country [cities]=city [isps]=ISP [categories]=category [hostnames]=hostname [flags]="server flag")
declare -gA VPN_FILTER_FIELD=([regions]=region [countries]=country [cities]=city [isps]=isp [categories]=categories [hostnames]=hostname)
# a server flag: on, gluetun keeps only servers with it (PREMIUM_ONLY is none:
# gluetun reads it and filters nothing by it — its filterServer, Nov 2026)
declare -gA VPN_FLAG_VAR=([owned]=OWNED_ONLY [free]=FREE_ONLY [stream]=STREAM_ONLY [secure-core]=SECURE_CORE_ONLY [tor]=TOR_ONLY)
declare -gA VPN_FLAG_FIELD=([owned]=owned [free]=free [stream]=stream [secure-core]=secure_core [tor]=tor)
# shellcheck disable=SC2034  # read by configure's question (questions.sh)
declare -gA VPN_FLAG_SAYS=([owned]="on the provider's own hardware" [free]="on its free plan" [stream]="for streaming" [secure-core]="Secure Core: in through a hardened server" [tor]="with Tor")

vpnp_list() { # every provider folder, alphabetical, custom last
    local d n
    for d in "$VPN_PROVIDERS_DIR"/*/; do
        n=$(basename "$d"); [[ "$n" == custom ]] || echo "$n"
    done
    [[ -d "$VPN_PROVIDERS_DIR/custom" ]] && echo custom
    return 0
}
vpnp_fn() { local n=${1//-/_}; echo "vpnp_${n}_$2"; }   # vpnp_fn NAME HOOK -> its function's name
vpnp_load() { # vpnp_load NAME — its provider.sh sourced (once); rc 1 when there is no such folder
    [[ "$1" =~ ^[a-z0-9-]+$ && -f "$VPN_PROVIDERS_DIR/$1/provider.sh" ]] || return 1
    declare -F "$(vpnp_fn "$1" name)" >/dev/null && return 0
    # shellcheck source=/dev/null
    source "$VPN_PROVIDERS_DIR/$1/provider.sh"
}
# a provider loaded inside $( ) is gone outside it: these two load it themselves, in whichever shell asks
vpnp_has() { vpnp_load "$1" && declare -F "$(vpnp_fn "$1" "$2")" >/dev/null; }   # vpnp_has NAME HOOK — the provider brings HOOK
vpnp_call() { # vpnp_call NAME HOOK [ARG...] — the provider's HOOK (dies when it lacks a required one)
    local f; f=$(vpnp_fn "$1" "$2")
    vpnp_load "$1" || die "VPN_PROVIDER=$1: there is no folder services/gluetun/providers/$1"
    declare -F "$f" >/dev/null || die "VPN provider $1 has no $2 (services/gluetun/providers/$1/provider.sh) — every provider brings name, types, filters, proven, questions and env"
    "$f" "${@:3}"
}
vpnp_filter_on() { [[ " $(vpnp_call "$1" filters) " == *" $2 "* ]]; }   # vpnp_filter_on NAME FILTER — it chooses servers by FILTER
vpnp_flags() { if vpnp_filter_on "$1" flags; then vpnp_call "$1" flags; fi; return 0; }   # vpnp_flags NAME — the server flags it offers ("" for none)
vpn_filter_value() { # vpn_filter_value NAME FILTER -> the filter as gluetun gets it: .env's value, or the provider's default for an empty one
    local v; v=$(env_get "${VPN_FILTER_KEY[$2]}")
    if [[ -z "$v" ]] && vpnp_has "$1" filter_default; then v=$(vpnp_call "$1" filter_default "$2"); fi
    echo "$v"
}
vpn_flags_set() { local v; v=$(env_get VPN_SERVER_FLAGS); v=${v,,}; tr ',' '\n' <<<"${v//[[:space:]]/}" | grep -v '^$' || true; }   # the flags .env sets, one a line (lowercase, no spaces: mediastack reads them, not gluetun)
vpnp_protocols() { if vpnp_has "$1" protocols; then vpnp_call "$1" protocols; else echo udp tcp; fi; }   # vpnp_protocols NAME — its OpenVPN protocols ("": its config file decides)
vpnp_type_keys() { # vpnp_type_keys NAME TYPE — the .env keys the provider reads run with TYPE (its env, the ${KEY}s of its extra, its keys), one a line
    # word-split, never line-split: a hook that names none prints a blank line
    # (custom's env for OpenVPN), and a blank key broke ANSWER[$k] (found live Nov 2026)
    local w
    for w in $(vpnp_call "$1" env "$2"); do echo "$w"; done
    if vpnp_has "$1" extra; then vpnp_call "$1" extra "$2" | grep -oE '\$\{[A-Z0-9_]+' | cut -c3- || true; fi
    if vpnp_has "$1" keys; then for w in $(vpnp_call "$1" keys "$2"); do echo "$w"; done; fi
    return 0
}
vpnp_keys() { # vpnp_keys NAME — every .env key the provider reads, any type (each type's keys, its own rows)
    local t
    for t in $(vpnp_call "$1" types); do vpnp_type_keys "$1" "$t"; done
    [[ -f "$VPN_PROVIDERS_DIR/$1/env.tsv" ]] && grep -vE '^(#|[[:space:]]*$)' "$VPN_PROVIDERS_DIR/$1/env.tsv" | cut -f1
    return 0
}
vpn_all_keys() { local p; for p in $(vpnp_list); do vpnp_load "$p" && vpnp_keys "$p"; done | sort -u; }   # every key some provider reads
vpn_keys_drop_others() { # vpn_keys_drop_others NAME TYPE — a switch to NAME run with TYPE: every other provider's or type's key is emptied in .env, and the endpoint record when NAME names no server
    # left, they read as NAME's own (a custom server's name and key under nordvpn: found live Nov 2026)
    local mine k
    mine=" $(vpnp_type_keys "$1" "$2" | tr '\n' ' ') "
    for k in $(vpn_all_keys); do
        [[ "$mine" == *" $k "* ]] && continue
        if [[ -n "$(env_get "$k")" ]]; then env_set "$k" ""; fi   # only what .env holds: an answers-only key is never added
    done
    for k in $VPN_FILTER_ORDER flags; do   # a server choice NAME does not offer: up would refuse it
        if ! vpnp_filter_on "$1" "$k" && [[ -n "$(env_get "${VPN_FILTER_KEY[$k]}")" ]]; then env_set "${VPN_FILTER_KEY[$k]}" ""; fi
    done
    vpnp_has "$1" endpoint || state_del "$VPN_ENDPOINT_STATE"
    return 0
}

vpn_summary() { # -> one line: the provider, its tunnel, whether what it needs is set, its servers (configure's summary)
    local p t k miss=0 proto=""
    p=$(env_get VPN_PROVIDER); t=$(env_get VPN_TYPE)
    vpnp_load "$p" || { echo "$p (no such provider)"; return 0; }
    for k in $(vpnp_call "$p" env "$t"); do [[ -n "$(env_get "$k")" ]] || miss=1; done
    [[ "$t" == openvpn && -n "$(vpnp_protocols "$p")" ]] && proto=" over $(env_get OPENVPN_PROTOCOL)"
    echo "$p ($t$proto), $( (( miss )) && echo "login MISSING" || echo "login set"), $(vpn_servers_words "$p")"
}
vpn_servers_words() { # vpn_servers_words NAME -> where NAME connects, for a summary: its server choice, or the one server its config names
    local h f v; local -a said=()
    if [[ -n "$(vpnp_call "$1" filters | tr -d '[:space:]')" ]]; then
        for f in $VPN_FILTER_ORDER; do vpnp_filter_on "$1" "$f" || continue; v=$(vpn_filter_value "$1" "$f"); [[ -z "$v" ]] || said+=("$v"); done
        v=$(vpn_flags_set | paste -sd,); [[ -z "$v" ]] || said+=("$v only")
        if (( ${#said[@]} )); then echo "servers: $(printf '%s; ' "${said[@]}" | sed 's/; $//')"; else echo "servers: any"; fi
        return 0
    fi
    h=$(vpn_endpoint_host)   # a provider with no server choices names one server (custom)
    echo "server: ${h:-not set} (its config)"
}
vpn_protocol_tidy() { # vpn_protocol_tidy NAME TYPE — OPENVPN_PROTOCOL emptied when NAME run with TYPE does not read it (WireGuard; a config file that says it)
    [[ "$2" == openvpn && -n "$(vpnp_protocols "$1")" ]] && return 0
    if grep -qE '^OPENVPN_PROTOCOL=.' "$ENV_FILE"; then env_set OPENVPN_PROTOCOL ""; fi   # the raw line: env_get answers the default for an empty one
    return 0
}
vpn_provider_problem() { # vpn_provider_problem NAME -> why NAME is no provider here ("" when it is; recorded lowercase)
    vpnp_load "${1,,}" && return 0
    echo "'${1,,}' is no VPN provider mediastack knows. Choose one of: $(vpnp_list | paste -sd' ' | sed 's/ /, /g')"
}

# ---------------------------------------------------------- what reaches gluetun --
vpn_provider_env() { # vpn_provider_env -> NAME<TAB>VALUE for every gluetun setting of the provider in .env; rc 1 with no folder
    local p t k f
    p=$(env_get VPN_PROVIDER); t=$(env_get VPN_TYPE)
    vpnp_load "$p" || return 1
    printf 'VPN_SERVICE_PROVIDER\t%s\n' "$(vpnp_call "$p" name)"
    printf 'VPN_TYPE\t%s\n' "$t"
    # a reference, never the value: compose reads it from .env (0644 file, secrets stay in .env)
    for k in $(vpnp_call "$p" env "$t"); do printf '%s\t${%s:-%s}\n' "$k" "$k" "${ENV_DEFAULT[$k]-}"; done
    if [[ "$t" == openvpn && -n "$(vpnp_protocols "$p")" ]]; then printf 'OPENVPN_PROTOCOL\t${OPENVPN_PROTOCOL:-%s}\n' "${ENV_DEFAULT[OPENVPN_PROTOCOL]-udp}"; fi
    local def
    for f in $(vpnp_call "$p" filters); do
        [[ -n "${VPN_FILTER_VAR[$f]-}" ]] || continue
        def=""; if vpnp_has "$p" filter_default; then def=$(vpnp_call "$p" filter_default "$f"); fi
        printf '%s\t${%s:-%s}\n' "${VPN_FILTER_VAR[$f]}" "${VPN_FILTER_KEY[$f]}" "$def"
    done
    # a flag is gluetun's on/off, one setting each: written as on for each one
    # .env sets (not a reference — one .env key holds them all; no secret)
    for f in $(vpn_flags_set); do
        [[ " $(vpnp_flags "$p") " != *" $f "* ]] || printf '%s\t%s\n' "${VPN_FLAG_VAR[$f]}" on
    done
    if vpnp_has "$p" extra; then vpnp_call "$p" extra "$t"; fi
}

vpn_provider_mounts() { # -> HOST<TAB>CONTAINER for every file the provider in .env mounts into gluetun ("" for none)
    local p t; p=$(env_get VPN_PROVIDER); t=$(env_get VPN_TYPE)
    vpnp_load "$p" || return 0
    if vpnp_has "$p" mounts; then vpnp_call "$p" mounts "$t"; fi
    return 0
}
vpn_files_dir() { echo "$LOCAL_DIR/vpn-files"; }   # the files a provider renders for gluetun (prepare): they may hold keys, so 0700
vpn_files_tidy() { # vpn_files_tidy MOUNTS — a file there that the provider in use does not mount is removed (a switch away leaves no copy of a key)
    local f
    [[ -d "$(vpn_files_dir)" ]] || return 0
    for f in "$(vpn_files_dir)"/*; do
        [[ -e "$f" ]] || continue
        grep -qF -- "$f"$'\t' <<<"$1" || rm -f "$f"
    done
}
vpn_provider_gen() { # local/vpn-provider.yml from .env and the provider's folder — byte-stable; removed when there is no folder
    install -d -m 755 "$LOCAL_DIR"; repo_owned "$LOCAL_DIR"
    local rows tmp n v mounts p sum
    p=$(env_get VPN_PROVIDER)
    if vpnp_load "$p" && vpnp_has "$p" prepare; then vpnp_call "$p" prepare "$(env_get VPN_TYPE)"; fi   # its files first: what it mounts must exist
    if ! rows=$(vpn_provider_env); then rm -f "$PROVIDER_FILE"; return 0; fi   # up says why (vpn_provider_ready)
    mounts=$(vpn_provider_mounts)
    vpn_files_tidy "$mounts"
    tmp=$(mktemp)
    {
        echo "# GENERATED by mediastack vpn_provider_gen — DO NOT EDIT."
        echo "# The VPN provider's settings, from services/gluetun/providers/$p/"
        echo "# (VPN_PROVIDER, VPN_TYPE and the provider's keys in .env). Values are .env references (a server flag: on)."
        echo "services:"
        echo "  gluetun:"   # addr-ok: the YAML key of the gluetun service, no address
        echo "    environment:"
        while IFS=$'\t' read -r n v; do printf '      %s: "%s"\n' "$n" "$v"; done <<<"$rows"
        if [[ -n "$mounts" ]]; then
            # read-only files of the provider's; their contents' hash is part of
            # gluetun's config, so a changed file recreates it (through the gate)
            echo "    volumes:"
            while IFS=$'\t' read -r n v; do printf '      - "%s:%s:ro"\n' "$n" "$v"; done <<<"$mounts"
            sum=$(while IFS=$'\t' read -r n v; do cat "$n" 2>/dev/null || true; done <<<"$mounts" | sha256sum | cut -c1-16)
            echo "    labels:"
            printf '      mediastack.vpn-files: "%s"\n' "$sum"
        fi
    } > "$tmp"
    if ! cmp -s "$tmp" "$PROVIDER_FILE" 2>/dev/null; then
        chmod 644 "$tmp"; mv -f "$tmp" "$PROVIDER_FILE"; repo_owned "$PROVIDER_FILE"   # 0644: references only, like the VPN overlay
    else
        rm -f "$tmp"
    fi
}

vpn_provider_problems() { # -> one line per reason gluetun cannot start with the provider in .env (none: it can)
    local p t k f v
    p=$(env_get VPN_PROVIDER); t=$(env_get VPN_TYPE)
    if ! vpnp_load "$p"; then
        echo "VPN_PROVIDER=$p is no provider mediastack knows (choose one: ./mediastack.sh configure; they are: $(vpnp_list | paste -sd' '))"; return 0
    fi
    [[ " $(vpnp_call "$p" types) " == *" $t "* ]] \
        || { echo "VPN_TYPE=$t: mediastack runs $p with $(vpnp_call "$p" types | sed 's/ / or /g') only"; return 0; }
    for k in $(vpnp_call "$p" env "$t"); do
        [[ -n "$(env_get "$k")" ]] || echo "$p needs $k — run ./mediastack.sh configure (it asks, and says where $p shows it)"
    done
    if [[ "$t" == openvpn ]]; then
        local protos pr; protos=$(vpnp_protocols "$p"); pr=$(env_get OPENVPN_PROTOCOL)
        [[ -z "$protos" || " $protos " == *" $pr "* ]] \
            || echo "OPENVPN_PROTOCOL=$pr, but $p has OpenVPN servers over $(sed 's/ / and /g' <<<"$protos") only — set it to ${protos%% *} (configure asks)"
    fi
    for f in $VPN_FILTER_ORDER flags; do
        v=$(env_get "${VPN_FILTER_KEY[$f]}")
        [[ -z "$v" ]] || vpnp_filter_on "$p" "$f" \
            || echo "${VPN_FILTER_KEY[$f]}=$v, but $p does not choose servers by ${VPN_FILTER_ONE[$f]} — clear it in .env (configure asks what $p offers)"
    done
    if vpnp_filter_on "$p" flags; then
        for f in $(vpn_flags_set); do
            [[ " $(vpnp_flags "$p") " == *" $f "* ]] || echo "VPN_SERVER_FLAGS: '$f' is no server flag of $p's — its flags: $(vpnp_flags "$p" | sed 's/ /, /g')"
        done
    fi
    if vpnp_has "$p" check; then vpnp_call "$p" check "$t" || true; fi
    return 0
}

gluetun_usage_providers() { # stdin: gluetun's format-servers usage -> its providers, one per line (CI's check reads the image the same way)
    # Go's flag usage: "  -<provider>" alone on a line, then its "Format ... servers" line;
    # the format and output flags carry their type on the same line, so never match
    awk '/^  -[a-z0-9-]+$/ { f = substr($1, 2); next } f != "" && /Format .* servers/ { print f } { f = "" }'
}
GLUETUN_PROVIDERS=""; GLUETUN_PROVIDERS_ERR=""   # gluetun_image_providers' answer (not printed: a $( ) would lose the reason)
gluetun_image_providers() { # GLUETUN_PROVIDERS: the providers the gluetun image knows (one per line: format-servers' flags), cached per image; rc 1 with GLUETUN_PROVIDERS_ERR
    local img id cached out list
    GLUETUN_PROVIDERS=""; GLUETUN_PROVIDERS_ERR=""
    img=$(svc_image gluetun)
    id=$(sudo docker image inspect -f '{{.Id}}' "$img" 2>/dev/null) \
        || { GLUETUN_PROVIDERS_ERR="the image $img is not on this host (pulled first by up and update)"; return 1; }
    cached=$(state_get gluetun-providers)
    if [[ "${cached%%$'\n'*}" == "$id" ]]; then GLUETUN_PROVIDERS=$(tail -n +2 <<<"$cached"); return 0; fi
    out=$(sudo docker run --rm "$img" format-servers -h 2>&1) || true
    list=$(gluetun_usage_providers <<<"$out")
    [[ -n "$list" ]] || { GLUETUN_PROVIDERS_ERR="its format-servers listed no providers: $(oneline "$out")"; return 1; }
    state_set gluetun-providers "$id"$'\n'"$list"
    GLUETUN_PROVIDERS=$list
}

# ------------------------------------------- the servers gluetun chooses among --
# Every server choice is checked against the data gluetun itself will choose
# from: the list built into its image merged with the one its updater keeps in
# config/gluetun/servers/ — merged by the image's own format-servers, run with
# no network on a throwaway copy (it rewrites what it merges, so never on the
# real folder). Kept in local/vpn-servers/ per image and data, with only the
# fields a choice reads. The check mirrors gluetun's filterServer
# (internal/storage/filter.go, Nov 2026): equality ignoring case, a category
# matching any of a server's, a Dedicated IP server only with categories or
# hostnames set, the OpenVPN protocol. Each filter is checked among the servers
# the ones before it keep (VPN_FILTER_ORDER), so a value is refused naming what
# narrowed it. If gluetun changes its rules the two can disagree — loudly
# either way: this refusal, or gluetun's own error and log lines at start.
VPN_SERVERS=""; VPN_SERVERS_ERR=""   # vpn_servers_load's answer
vpn_servers_dir() { echo "$LOCAL_DIR/vpn-servers"; }
vpn_servers_load() { # vpn_servers_load NAME — VPN_SERVERS: NAME's servers as gluetun sees them (a JSON array, in a file); rc 1 with VPN_SERVERS_ERR
    local img id g src sum dir tmp f
    VPN_SERVERS=""; VPN_SERVERS_ERR=""
    img=$(svc_image gluetun)
    [[ -n "$img" && "$img" != null ]] || { VPN_SERVERS_ERR="gluetun's image is not in the rendered config"; return 1; }
    id=$(sudo docker image inspect -f '{{.Id}}' "$img" 2>/dev/null) \
        || { VPN_SERVERS_ERR="the image $img is not on this host yet (up and update pull it)"; return 1; }
    g=$(vpnp_call "$1" name); src=$(env_get CONFIG_ROOT)/gluetun
    sum=$( { sudo cat "$src/servers/$g.json" "$src/servers.json" 2>/dev/null || true; } | sha256sum | cut -c1-16)
    dir=$(vpn_servers_dir)
    if [[ "$(cat "$dir/$1.key" 2>/dev/null)" == "$id $sum" && -s "$dir/$1.json" ]]; then VPN_SERVERS=$dir/$1.json; return 0; fi
    tmp=$(mktemp -d); mkdir -p "$tmp/gluetun/servers"
    for f in "servers/$g.json" servers.json; do
        if sudo test -f "$src/$f"; then sudo cp "$src/$f" "$tmp/gluetun/$f"; fi
    done
    # shellcheck disable=SC2024  # its output is ours to read: written as this user, not root
    if ! sudo docker run --rm --network none -v "$tmp/gluetun:/gluetun" "$img" format-servers "-$1" -format json > "$tmp/out" 2> "$tmp/err"; then   # addr-ok: a mount, no address
        VPN_SERVERS_ERR="its format-servers -$1 failed: $(oneline "$(cat "$tmp/err")")"; sudo rm -rf "$tmp"; return 1
    fi
    install -d -m 755 "$dir"; repo_owned "$dir"
    if ! jq -ce 'map({vpn, country, region, city, isp, categories, owned, free, stream, secure_core, tor, tcp, udp, hostname, dedicated}
                     | with_entries(select(.value != null and .value != false and .value != "" and .value != [])))
                 | if length > 0 then . else error("no server") end' "$tmp/out" > "$dir/$1.json" 2>/dev/null; then
        VPN_SERVERS_ERR="its format-servers -$1 gave no server list: $(oneline "$(head -c 300 "$tmp/out")")"; rm -f "$dir/$1.json"; sudo rm -rf "$tmp"; return 1
    fi
    sudo rm -rf "$tmp"
    echo "$id $sum" > "$dir/$1.key"; repo_owned "$dir/$1.json" "$dir/$1.key"
    VPN_SERVERS=$dir/$1.json
}
# the servers that the tunnel, the flags and PRIOR (a JSON object: field -> values) keep
# — gluetun's filterServer, in jq; then FIELD's values among them, or their count
# shellcheck disable=SC2016  # jq's own $variables
VPN_SERVERS_JQ='
def keeps($field; $vals): ($vals | map(ascii_downcase)) as $w
  | if ($w | length) == 0 then true
    elif $field == "categories" then any((.categories // [])[]; ascii_downcase as $c | any($w[]; . == $c))
    else ((.[$field] // "") | ascii_downcase) as $v | any($w[]; . == $v) end;
[ .[] | select(.vpn == $type)
      | select($type != "openvpn" or $proto == "" or (if $proto == "tcp" then .tcp else .udp end) == true)
      | select(. as $s | all($flags[]; $s[.] == true))
      | select((.dedicated | not) or $named)
      | select(. as $s | all($prior | to_entries[]; . as $e | $s | keeps($e.key; $e.value))) ]
| if $field == "" then length
  else [ .[] | if $field == "categories" then (.categories // [])[] else (.[$field] // empty) end ] | map(select(. != "")) | unique | .[] end'
vpn_servers_query() { # vpn_servers_query NAME FIELD PRIOR -> FIELD's values among NAME's servers the tunnel, flags and PRIOR keep, one a line (FIELD "": how many servers)
    local t proto="" flags f named=false
    t=$(env_get VPN_TYPE)
    [[ "$t" == openvpn && -n "$(vpnp_protocols "$1")" ]] && proto=$(env_get OPENVPN_PROTOCOL)
    flags=$(for f in $(vpn_flags_set); do [[ " $(vpnp_flags "$1") " == *" $f "* ]] && echo "${VPN_FLAG_FIELD[$f]}"; done | jq -Rsc 'split("\n") | map(select(. != ""))')
    [[ -n "$(vpn_filter_value "$1" categories)$(env_get VPN_SERVER_HOSTNAMES)" ]] && named=true
    jq -r --arg type "$t" --arg proto "$proto" --argjson flags "$flags" --argjson named "$named" \
        --arg field "$2" --argjson prior "$3" "$VPN_SERVERS_JQ" "$VPN_SERVERS"
}
vpn_servers_said() { # vpn_servers_said NAME [WITH] -> how a message names the servers checked among ("nordvpn's WireGuard servers", WITH appended)
    local t; t=$(env_get VPN_TYPE)
    if [[ "$t" == openvpn ]]; then t="OpenVPN$( [[ -n "$(vpnp_protocols "$1")" ]] && echo " ($(env_get OPENVPN_PROTOCOL))" )"; else t=WireGuard; fi
    echo "$1's $t servers$( [[ -z "$(vpn_flags_set)" ]] || echo " with VPN_SERVER_FLAGS=$(vpn_flags_set | paste -sd,)" )${2:+ with $2}"
}
vpn_close_matches() { # vpn_close_matches VALUE CHOICE... -> a hint: up to 8 choices close to VALUE, or all of a few, or where the list is
    local v=${1,,} c lc; local -a near=(); shift
    for c in "$@"; do
        lc=${c,,}
        if [[ "$lc" == *"$v"* || "$v" == *"$lc"* || "${lc:0:3}" == "${v:0:3}" ]]; then near+=("$c"); fi
    done
    if (( ${#near[@]} )); then echo "close: $(printf '%s, ' "${near[@]:0:8}" | sed 's/, $//')"
    elif (( $# <= 8 )); then echo "they are: $(printf '%s, ' "$@" | sed 's/, $//')"
    else echo "configure lists all $# (? at its prompt)"; fi
}
vpn_choice_match() { # vpn_choice_match VALUE CHOICE... -> the choice VALUE names (ignoring case, as gluetun does); rc 1 when none
    local c; local v=$1; shift
    for c in "$@"; do [[ "${c,,}" == "${v,,}" ]] && { echo "$c"; return 0; }; done
    return 1
}
vpn_item_problem() { # vpn_item_problem KEY ITEM -> why ITEM, one value of a comma list, is not as gluetun reads it ("" when it is)
    if [[ -z "$2" ]]; then echo "$1: an empty value (two commas together, or one at an end) — write it as a,b"
    elif [[ "$2" =~ ^[[:space:]] || "$2" =~ [[:space:]]$ ]]; then echo "$1: '$2' has a space at an end — gluetun reads each value exactly as written between the commas (a,b, no spaces around them)"
    fi
}
VPN_PRIOR='{}'; VPN_WITH=""   # vpn_filters_before's answer
vpn_filters_before() { # vpn_filters_before NAME FILTER — VPN_PRIOR: the filters before FILTER as gluetun gets them (JSON, for vpn_servers_query); VPN_WITH: the same, as a message says it
    local f v
    VPN_PRIOR='{}'; VPN_WITH=""
    for f in $VPN_FILTER_ORDER; do
        [[ "$f" != "$2" ]] || break
        vpnp_filter_on "$1" "$f" || continue
        v=$(vpn_filter_value "$1" "$f"); [[ -n "$v" ]] || continue
        VPN_PRIOR=$(jq -c --arg k "${VPN_FILTER_FIELD[$f]}" --arg v "$v" '. + {($k): ($v | split(","))}' <<<"$VPN_PRIOR")
        VPN_WITH+="${VPN_WITH:+, }${VPN_FILTER_KEY[$f]}=$v"
    done
}
vpn_choices_problems() { # vpn_choices_problems NAME -> one line per server choice in .env that no server of NAME's (VPN_SERVERS, loaded first) has; nothing: every one is there and together they keep a server
    local f key v item p n; local -a items choices
    vpnp_load "$1" && [[ -n "$VPN_SERVERS" ]] || return 0   # no provider or no list: nothing to check against (callers load it first)
    for f in $VPN_FILTER_ORDER; do
        vpnp_filter_on "$1" "$f" || continue
        v=$(vpn_filter_value "$1" "$f"); [[ -n "$v" ]] || continue
        key=${VPN_FILTER_KEY[$f]}
        [[ -n "$(env_get "$key")" ]] || key="$key (empty: $1's default)"   # the provider's default, not a value of yours
        vpn_filters_before "$1" "$f"
        mapfile -t choices < <(vpn_servers_query "$1" "${VPN_FILTER_FIELD[$f]}" "$VPN_PRIOR")
        IFS=, read -ra items <<<"$v,"   # the trailing comma keeps an empty last value, as gluetun's split does
        n=0
        for item in "${items[@]}"; do
            p=$(vpn_item_problem "$key" "$item")
            if [[ -z "$p" ]] && ! vpn_choice_match "$item" "${choices[@]}" >/dev/null; then
                if (( ${#choices[@]} )); then p="$key: no ${VPN_FILTER_ONE[$f]} '$item' among $(vpn_servers_said "$1" "$VPN_WITH") — $(vpn_close_matches "$item" "${choices[@]}")"
                else p="$key=$v: $(vpn_servers_said "$1" "$VPN_WITH") have no ${VPN_FILTER_ONE[$f]} at all — clear it (configure asks what $1 offers)"; fi
            fi
            [[ -z "$p" ]] || { echo "$p"; n=1; }
        done
        (( n == 0 )) || return 0   # the filters after it would be checked among servers it failed to name
    done
    vpn_filters_before "$1" ""
    n=$(vpn_servers_query "$1" "" "$VPN_PRIOR")
    (( n > 0 )) || echo "no server matches: $(vpn_servers_said "$1" "$VPN_WITH") — none in gluetun's list (configure asks what $1 offers)"
    return 0
}

vpn_provider_ready() { # vpn_provider_ready [WHAT] — die with every reason gluetun cannot start with this provider (WHAT: the verb, for the message)
    local probs p
    probs=$(vpn_provider_problems)
    p=$(env_get VPN_PROVIDER)
    if [[ -z "$probs" && "$p" != custom ]]; then
        if ! gluetun_image_providers; then probs="cannot read which providers the gluetun image knows: $GLUETUN_PROVIDERS_ERR"
        elif ! grep -qx -- "$p" <<<"$GLUETUN_PROVIDERS"; then
            probs="the gluetun image ($(svc_image gluetun)) does not know $p — gluetun may have dropped it. Its providers: $(paste -sd' ' <<<"$GLUETUN_PROVIDERS"). Choose another: ./mediastack.sh configure"
        elif ! vpn_servers_load "$p"; then probs="cannot read the gluetun image's server list for $p: $VPN_SERVERS_ERR"
        else probs=$(vpn_choices_problems "$p")
        fi
    fi
    [[ -z "$probs" ]] && return 0
    die "${1:-up}: gluetun cannot start with this VPN setup — nothing VPN'd was started:
$(sed 's/^/  /' <<<"$probs")"
}

# ------------------------------------------------------ an endpoint by name --
# gluetun takes only an address for a server of your own (its firewall is one
# rule for one address; its issue #2680 — and an OpenVPN file's `remote` with a
# name fails its settings check outright, OPENVPN_ENDPOINT_IP not overriding it
# for custom: read in its source, Nov 2026). What the config says stays as said
# (WireGuard: WIREGUARD_ENDPOINT_HOST in .env; OpenVPN: the file's first
# `remote`); a name is looked up from this host — outside the tunnel, which is
# not up yet — at up, at boot and by the 5-minute check, and the address kept in
# local/state. Rendering only reads that record, so the generated files stay
# byte-stable. A failed lookup is not a change: only an answer that no longer
# holds the address in use moves the tunnel (gluetun recreated through the leak
# gate). Of several addresses the first in sorted order is taken, so
# round-robin DNS does not move it.
VPN_ENDPOINT_STATE=vpn-endpoint   # local/state: "<name> <address>" the tunnel uses
ip_literal() { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || "$1" =~ ^[0-9A-Fa-f:]+:[0-9A-Fa-f:]*$ ]]; }   # an address, not a name
vpn_endpoint_host() { # the endpoint the provider in .env names ("" when it reads none) — its endpoint hook, which never asks for the address
    local p; p=$(env_get VPN_PROVIDER)
    if vpnp_has "$p" endpoint; then vpnp_call "$p" endpoint "$(env_get VPN_TYPE)"; fi
    return 0
}
vpn_endpoint_ip() { # the endpoint's address as gluetun gets it: the address written, or the last lookup of the name ("" when not looked up yet)
    local h s; h=$(vpn_endpoint_host)
    [[ -n "$h" ]] || return 0
    if ip_literal "$h"; then echo "$h"; return 0; fi
    s=$(state_get "$VPN_ENDPOINT_STATE")
    [[ "${s%% *}" == "$h" ]] && echo "${s#* }"
    return 0
}
vpn_endpoint_resolve() { getent ahostsv4 "$1" 2>/dev/null | awk '{ print $1 }' | sort -u; }   # vpn_endpoint_resolve NAME -> its IPv4 addresses, sorted
VPN_ENDPOINT_OLD=""   # the address before a move (vpn_endpoint_refresh rc 10)
vpn_endpoint_refresh() { # rc 0: nothing moved; 10: the name points elsewhere now (recorded; VPN_ENDPOINT_OLD the old); dies on a first lookup that fails
    local h s cur; local -a now
    h=$(vpn_endpoint_host)
    [[ -n "$h" ]] && ! ip_literal "$h" || return 0
    s=$(state_get "$VPN_ENDPOINT_STATE"); cur=""; [[ "${s%% *}" == "$h" ]] && cur=${s#* }
    mapfile -t now < <(vpn_endpoint_resolve "$h")
    if (( ${#now[@]} == 0 )); then
        [[ -n "$cur" ]] || die "the VPN server's name $h does not resolve from this host (IPv4) — check the server your config names ($( [[ "$(env_get VPN_TYPE)" == openvpn ]] && echo "the remote line of custom/vpn/openvpn.ovpn" || echo WIREGUARD_ENDPOINT_HOST )) and this host's DNS, then: ./mediastack.sh up"
        warn "the VPN server's name $h did not resolve just now — the tunnel keeps $cur"
        return 0
    fi
    local a; for a in "${now[@]}"; do [[ "$a" != "$cur" ]] || return 0; done   # still among the answers: nothing moves
    state_set "$VPN_ENDPOINT_STATE" "$h ${now[0]}"
    [[ -n "$cur" ]] || return 0   # the first lookup: nothing moved
    VPN_ENDPOINT_OLD=$cur
    return 10
}
vpn_endpoint_move() { # the endpoint's name points elsewhere: gluetun recreated onto it, the VPN group through the gate
    local -a group; local new; new=$(vpn_endpoint_ip)
    mapfile -t group < <(vpn_group)
    warn "the VPN server $(vpn_endpoint_host) moved: $VPN_ENDPOINT_OLD -> $new — gluetun is recreated onto it, the VPN'd services restarted through the leak gate"
    notify ops "Mediastack VPN server moved" "$(vpn_endpoint_host) now answers at **$new** (was $VPN_ENDPOINT_OLD): gluetun recreated onto it; the VPN'd services restart through the leak gate." warning
    gluetun_recreate_prepare || { fail "stopping gluetun and its VPN'd services for the move failed — see compose's message above"; return 1; }
    vpn_gen
    DC up -d --no-deps gluetun >/dev/null || { fail "recreating gluetun onto $new failed — see compose's message above"; return 1; }
    wait_verdict --recover gluetun || { fail "gluetun ${VERDICT_WHY[gluetun]} after the move — the VPN'd services stay stopped"; return 1; }
    (( ${#group[@]} )) || return 0
    vpn_start_group "${group[@]}" || return 1
}

# --------------------------------------------------------- shared questions --
# Each reads the answers file first and honours quick mode, as every question
# does (docs/adding-a-service.md); a provider's file says only where its
# account page keeps each value.
wg_key_problem() { # wg_key_problem KEY -> why KEY is no WireGuard key ("" when it is)
    [[ "$1" =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]] || echo "that is not a WireGuard key (44 characters of base64, ending in =) — copy the value from the config file"
}
wg_addresses_problem() { # wg_addresses_problem ADDRS -> why ADDRS is no [Interface] Address line ("" when it is)
    # one or more IP/prefix, comma-separated
    [[ "$1" =~ ^[0-9A-Fa-f:.]+/[0-9]{1,3}(,[[:space:]]*[0-9A-Fa-f:.]+/[0-9]{1,3})*$ ]] \
        || echo "'$1' is not an address like 10.5.0.2/32 (copy the Address line of the config file)."
}
pem_b64_problem() { # pem_b64_problem VALUE -> why VALUE is no PEM body as .env holds it ("" when it is)
    [[ "$1" =~ ^[A-Za-z0-9+/]+=*$ ]] && (( ${#1} % 4 == 0 )) \
        || echo "that is not the one-line base64 body of a certificate or key (configure reads it from the file: ./mediastack.sh configure)"
}
vpn_key_problem() { # vpn_key_problem KEY VALUE -> why VALUE cannot be KEY's ("" when it can) — the keys several providers share
    case "$1" in
        WIREGUARD_PRIVATE_KEY|WIREGUARD_PRESHARED_KEY|WIREGUARD_PUBLIC_KEY) wg_key_problem "$2" ;;
        WIREGUARD_ADDRESSES) wg_addresses_problem "$2" ;;
        OPENVPN_CERT|OPENVPN_KEY|OPENVPN_ENCRYPTED_KEY) pem_b64_problem "$2" ;;
    esac
    return 0
}

# ---- a certificate or key, from the file the provider gives ----
# gluetun takes each as its base64 body on one line (OPENVPN_CERT, OPENVPN_KEY,
# OPENVPN_ENCRYPTED_KEY) and wraps it back itself — a client key always as
# "PRIVATE KEY" (PKCS#8): an older "RSA PRIVATE KEY" would reach OpenVPN under
# the wrong label, so it is refused with the one-line conversion.
pem_body() { # pem_body FILE LABEL -> the one-line base64 body of FILE's first "BEGIN LABEL" block (a .ovpn's inline <cert>/<key> too); rc 1 with the reason instead
    local body
    body=$(awk -v b="-----BEGIN $2-----" -v e="-----END $2-----" '
        { sub(/\r$/, ""); sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "") }
        $0 == b { on = 1; next } $0 == e && on { print s; done = 1; exit } on { s = s $0 }
        END { if (!done) exit 1 }' "$1") || {
        if [[ "$2" == "PRIVATE KEY" ]] && grep -q -- '-----BEGIN RSA PRIVATE KEY-----' "$1"; then
            echo "its key is an older RSA PRIVATE KEY — gluetun needs PKCS#8: openssl pkcs8 -topk8 -nocrypt -in $(basename "$1") -out client.key, then give client.key"
        else echo "it holds no '-----BEGIN $2-----' block"; fi
        return 1
    }
    [[ -z "$(pem_b64_problem "$body")" ]] || { echo "its $2 block is not base64"; return 1; }
    echo "$body"
}
vpn_ask_pem() { # vpn_ask_pem KEY LABEL WHAT — the file holding it (the provider's .ovpn or its own file), read into .env as one line
    local f b
    if [[ -n "$(env_get "$1")" ]] && (( ! VPN_PROVIDER_CHANGED )) && ! confirm "The $3 is already read in. Read another?"; then return 0; fi
    while true; do
        ask "$1" "File with the $3 (its path)" ""
        f=$(abspath "${REPLY_VAL/#\~/$HOME}")
        [[ -r "$f" ]] || { fail "'$f' cannot be read"; continue; }
        if b=$(pem_body "$f" "$2"); then break; fi
        fail "That file won't do — $b"
    done
    env_set "$1" "$b"
    ok "$3 read from $(basename "$f")"
}
vpn_login_hint() { # vpn_login_hint TITLE WIKI-PAGE -> where a provider's OpenVPN login is, when its account page is not known to mediastack
    echo "$1's OpenVPN username and password for manual setup (often not your website login). Where your account
shows them: gluetun's wiki, setup/providers/$2.md (github.com/qdm12/gluetun-wiki)."
}
vpn_ask_openvpn_login() { # vpn_ask_openvpn_login HINT [nopass-ok] — the provider's OpenVPN username and password (hidden); nopass-ok: an empty password is an answer
    local cur
    info "$1"
    cur=$(env_get OPENVPN_USER); (( VPN_PROVIDER_CHANGED )) && cur=""
    ask_secret_token "OpenVPN username (input hidden)" "$cur"; env_set OPENVPN_USER "$REPLY_VAL"
    cur=$(env_get OPENVPN_PASSWORD); (( VPN_PROVIDER_CHANGED )) && cur=""
    if [[ "${2:-}" == nopass-ok ]]; then ask_secret_token "OpenVPN password (input hidden, Enter = none)" "$cur" optional
    else ask_secret_token "OpenVPN password (input hidden)" "$cur"; fi
    env_set OPENVPN_PASSWORD "$REPLY_VAL"
}
vpn_type_default() { # vpn_type_default NAME -> the type a question offers: the one set when NAME runs it, else NAME's first
    local t; t=$(env_get VPN_TYPE)
    [[ " $(vpnp_call "$1" types) " == *" $t "* && -n "$t" ]] && { echo "$t"; return 0; }
    vpnp_call "$1" types | awk '{print $1}'
}
vpn_ask_type() { # vpn_ask_type NAME -> REPLY_VAL: the tunnel, asked only where NAME offers more than one
    local -a ts; read -ra ts <<<"$(vpnp_call "$1" types)"
    if (( ${#ts[@]} < 2 )); then REPLY_VAL=${ts[0]}; return 0; fi
    if q_quick; then REPLY_VAL=$(vpn_type_default "$1"); q_took "VPN tunnel" "$REPLY_VAL"; return 0; fi
    info "WireGuard is faster and what the leak gate was first proven on; OpenVPN for a network that blocks it, or over TCP."
    while true; do
        ask VPN_TYPE "Tunnel ($(sed 's/ /\//g' <<<"${ts[*]}"))" "$(vpn_type_default "$1")"
        REPLY_VAL=${REPLY_VAL,,}
        [[ " ${ts[*]} " == *" $REPLY_VAL "* ]] && return 0
        fail "'$REPLY_VAL': $1 runs $(sed 's/ / or /g' <<<"${ts[*]}")"
    done
}
vpn_ask_protocol() { # vpn_ask_protocol NAME — OpenVPN over UDP or TCP, asked only where NAME has servers for both, recorded
    local -a ps; read -ra ps <<<"$(vpnp_protocols "$1")"
    (( ${#ps[@]} )) || return 0   # its config file decides
    if (( ${#ps[@]} == 1 )); then env_set OPENVPN_PROTOCOL "${ps[0]}"; return 0; fi
    local cur; cur=$(env_get OPENVPN_PROTOCOL)
    [[ " ${ps[*]} " == *" $cur "* ]] || cur=${ps[0]}
    if q_quick; then env_set OPENVPN_PROTOCOL "$cur"; q_took "OpenVPN protocol" "$cur"; return 0; fi
    while true; do
        ask OPENVPN_PROTOCOL "OpenVPN protocol ($(sed 's/ /\//g' <<<"${ps[*]}"); tcp only where UDP is blocked)" "$cur"
        REPLY_VAL=${REPLY_VAL,,}
        [[ " ${ps[*]} " == *" $REPLY_VAL "* ]] && break
        fail "'$REPLY_VAL': $1 has OpenVPN servers over $(sed 's/ / and /g' <<<"${ps[*]}")"
    done
    env_set OPENVPN_PROTOCOL "$REPLY_VAL"
}
vpn_list_tidy() { # vpn_list_tidy TYPED -> a comma list as gluetun reads one: no space around a value, no empty one ("any" and "auto": empty, no limit)
    local v out="" i; local -a items
    v=$1; [[ "${v,,}" =~ ^[[:space:]]*(any|auto)[[:space:]]*$ ]] && return 0
    IFS=, read -ra items <<<"$v"
    for i in "${items[@]}"; do
        i=$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$i")
        [[ -z "$i" ]] || out+="${out:+,}$i"
    done
    echo "$out"
}

VPN_PROVIDER_CHANGED=0   # set by the questions: a key the old provider made is not offered as the current one
vpn_ask_key() { # vpn_ask_key KEY "prompt" PROBLEM-FN — a pasted secret (hidden), checked; Enter keeps the current one
    local cur p
    cur=$(env_get "$1"); (( VPN_PROVIDER_CHANGED )) && cur=""
    while true; do
        ask_secret_token "$2 (input hidden)" "$cur"
        p=$("$3" "$REPLY_VAL"); [[ -z "$p" ]] && break
        fail "$p"; cur=""
    done
    env_set "$1" "$REPLY_VAL"
}
vpn_ask_wg_key() { explain "WireGuard key" "$1"; vpn_ask_key WIREGUARD_PRIVATE_KEY "PrivateKey" wg_key_problem; }   # vpn_ask_wg_key HINT
vpn_ask_wg_psk() { vpn_ask_key WIREGUARD_PRESHARED_KEY "PresharedKey" wg_key_problem; }
vpn_ask_wg_address() { # vpn_ask_wg_address HINT — the [Interface] Address the provider gave this key
    local cur p; cur=$(env_get WIREGUARD_ADDRESSES); (( VPN_PROVIDER_CHANGED )) && cur=""
    info "$1"
    while true; do
        ask WIREGUARD_ADDRESSES "Address (e.g. 10.64.0.2/32)" "$cur"
        p=$(wg_addresses_problem "$REPLY_VAL"); [[ -z "$p" ]] && break
        fail "$p"
    done
    env_set WIREGUARD_ADDRESSES "$REPLY_VAL"
}
