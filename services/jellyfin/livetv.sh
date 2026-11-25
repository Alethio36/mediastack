#!/usr/bin/env bash
# services/jellyfin/livetv.sh — Jellyfin's Live TV, from the stack's live-tv
# role (lib/roles.sh): its provider — Dispatcharr, ErsatzTV — ships
# provides/live-tv.jellyfin.json, an HDHomeRun tuner and an XMLTV guide at
# addresses inside the stack (VPN-aware: svc_addr). Written once against the
# role: a new provider is a new template, nothing here. Sourced by the
# entrypoint; relies on lib/roles.sh, lib/wire.sh and jellyfin.sh's jf_api.
#
# Which entries are ours, with nothing kept about Jellyfin: the tuner Jellyfin
# saved with the provider's own DeviceID (Jellyfin records it from the
# tuner's discover.json, whatever address it was reached at); the guide whose
# address ends in the provider's port and path (":9191/output/epg"). A VPN
# toggle changes only their host: re-pointed in place, nothing else touched —
# their other settings are yours. With several providers enabled, the first
# in priority order is wired; another's entries are left as they are.

jf_livetv() { # TOKEN — the role's provider as Jellyfin's tuner and guide: added, or re-pointed; read back
    local tok=$1 p e cfg
    p=$(role_pick live-tv)
    [[ -n "$p" ]] || return 0   # no live TV source enabled: nothing to wire
    role_pick_note live-tv
    if [[ "$(c_state "$(svc_cname "$p")")" != running ]]; then
        wfail "jellyfin: live TV from $p not wired — $p is not running (./mediastack.sh up, then: ./mediastack.sh wire jellyfin)"
        return 0
    fi
    e=$(role_entry "$p" live-tv jellyfin)
    cfg=$(jf_api GET /System/Configuration/livetv "$tok") \
        || { wfail "jellyfin: its live TV settings are unreadable [HTTP $(jf_code)]: $(oneline "$cfg")"; return 0; }
    jf_livetv_tuner "$tok" "$p" "$e" "$cfg" || return 0
    jf_livetv_guide "$tok" "$p" "$e" "$cfg"
}

jf_livetv_path() { # URL -> its path ("" at the root): what follows the address
    local rest=${1#*://}
    if [[ "$rest" == */* ]]; then echo "/${rest#*/}"; fi
    return 0
}

jf_livetv_tuner() { # TOKEN PROVIDER ENTRY CONFIG — rc 1 when the tuner cannot be wired (said why)
    local tok=$1 p=$2 e=$3 cfg=$4 url dev disc cur out durl
    url=$(jq -r '.tuner.Url' <<<"$e")
    # its DeviceID, asked from this host through its published port (the stack's name for it does not resolve here)
    durl="http://127.0.0.1:$(svc_hostport "$p")$(jf_livetv_path "$url")/discover.json"
    # running is not answering: right after `up` moved it, Dispatcharr's nginx
    # answers 502 while the app behind it starts (found live 25 Nov 2026)
    http_ready "$p" "$durl" '^200$' || return 1
    disc=$(curl -fsS -m 10 "$durl" 2>&1) \
        || { wfail "jellyfin: $p's tuner does not answer (its discover.json): $(oneline "$disc") — inspect: ./mediastack.sh logs $p"; return 1; }
    dev=$(jq -r '.DeviceID // empty' <<<"$disc" 2>/dev/null || true)   # soft read: no DeviceID is said on the next line
    [[ -n "$dev" ]] || { wfail "jellyfin: $p's tuner answered without a DeviceID: $(oneline "$disc")"; return 1; }
    cur=$(jq -c --arg d "$dev" --arg u "$url" '[.TunerHosts[]? | select(.Type == "hdhomerun" and (.DeviceId == $d or .Url == $u))][0] // empty' <<<"$cfg")
    if [[ -z "$cur" ]]; then
        w_would "jellyfin: $p as a live TV tuner ($url)" || return 0
        out=$(jf_api POST /LiveTv/TunerHosts "$tok" "$(jq -c '.tuner' <<<"$e")") \
            || { wfail "jellyfin refused $p as a tuner [HTTP $(jf_code)]: $(oneline "$out")"; return 1; }
    elif [[ "$(jq -r '.Url' <<<"$cur")" != "$url" ]]; then
        w_would "jellyfin: re-point its $p tuner to $url (was $(jq -r '.Url' <<<"$cur"))" || return 0
        out=$(jf_api POST /LiveTv/TunerHosts "$tok" "$(jq -c --arg u "$url" '.Url = $u' <<<"$cur")") \
            || { wfail "jellyfin refused the re-pointed $p tuner [HTTP $(jf_code)]: $(oneline "$out")"; return 1; }
    else
        ok "jellyfin: live TV tuner $p ($url)"; return 0
    fi
    # read back: the tuner at its address, with its device
    out=$(jf_api GET /System/Configuration/livetv "$tok") \
        || { wfail "jellyfin: its live TV settings are unreadable after the change [HTTP $(jf_code)]"; return 1; }
    jq -e --arg u "$url" --arg d "$dev" '[.TunerHosts[]? | select(.Url == $u and .DeviceId == $d)] | length == 1' <<<"$out" >/dev/null \
        || { wfail "jellyfin: its $p tuner did not hold at $url: $(oneline "$(jq -c '.TunerHosts' <<<"$out")")"; return 1; }
    ok "jellyfin: live TV tuner $p ($url)"
}

jf_livetv_guide() { # TOKEN PROVIDER ENTRY CONFIG
    local tok=$1 p=$2 e=$3 cfg=$4 path tail cur out
    path=$(jq -r '.guide.Path' <<<"$e")
    tail=":$(svc_cport "$p")$(jf_livetv_path "$path")"   # its port and path, whatever host the stack reaches it by
    cur=$(jq -c --arg t "$tail" '[.ListingProviders[]? | select(.Type == "xmltv" and ((.Path // "") | endswith($t)))][0] // empty' <<<"$cfg")
    if [[ -z "$cur" ]]; then
        w_would "jellyfin: $p's guide for live TV ($path)" || return 0
        out=$(jf_api POST "/LiveTv/ListingProviders?validateListings=false&validateLogin=false" "$tok" "$(jq -c '.guide' <<<"$e")") \
            || { wfail "jellyfin refused $p's guide [HTTP $(jf_code)]: $(oneline "$out")"; return 0; }
    elif [[ "$(jq -r '.Path' <<<"$cur")" != "$path" ]]; then
        w_would "jellyfin: re-point $p's guide to $path (was $(jq -r '.Path' <<<"$cur"))" || return 0
        out=$(jf_api POST "/LiveTv/ListingProviders?validateListings=false&validateLogin=false" "$tok" "$(jq -c --arg u "$path" '.Path = $u' <<<"$cur")") \
            || { wfail "jellyfin refused the re-pointed $p guide [HTTP $(jf_code)]: $(oneline "$out")"; return 0; }
    else
        ok "jellyfin: live TV guide from $p ($path)"; return 0
    fi
    out=$(jf_api GET /System/Configuration/livetv "$tok") \
        || { wfail "jellyfin: its live TV settings are unreadable after the change [HTTP $(jf_code)]"; return 0; }
    jq -e --arg u "$path" '[.ListingProviders[]? | select(.Type == "xmltv" and .Path == $u)] | length == 1' <<<"$out" >/dev/null \
        || { wfail "jellyfin: $p's guide did not hold at $path: $(oneline "$(jq -c '.ListingProviders' <<<"$out")")"; return 0; }
    ok "jellyfin: live TV guide from $p ($path) — Jellyfin refreshes its guide now"
}
