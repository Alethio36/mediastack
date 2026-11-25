#!/usr/bin/env bash
# services/wizarr/wizarr.sh — Wizarr's address, its `wire wizarr` role and its
# halves of `invite` and `reset-password` (wizarr_invite, wizarr_reset_link;
# the verbs themselves are lib/access.sh).
# Sourced by the entrypoint; relies on lib/wire.sh, lib/addr.sh and the
# entrypoint's helpers at call time.

# ---- wizarr (wave 4) ----
# Wizarr's admin account, jellyfin connection, and API keys are web-UI-only
# by upstream design — no bootstrap API exists. One documented first-run in
# the UI, then wire holds the API key and './mediastack.sh invite' does the
# rest forever.
wizarr_url() { local p; p=$(svc_hostport wizarr) || return 1; echo "http://127.0.0.1:$p"; }
wizarr_public_base() { # where people open Wizarr's links: its subdomain, or this host's LAN address without a domain
    local domain; domain=$(env_get STACK_DOMAIN)
    if [[ -n "$domain" ]]; then echo "https://$(svc_subdomain wizarr).$domain"
    else echo "http://$(hostname -I 2>/dev/null | awk '{print $1}'):$(svc_hostport wizarr)"; fi
}

WIZARR_KEY_WHERE="Settings → General, at the bottom of the page"   # where its UI makes API keys
WZ_CODE=""   # wizarr_key_works' last answer (a global: a $( ) would lose it)
wizarr_key_works() { # wizarr_key_works KEY — Wizarr takes it (WZ_CODE: its HTTP answer, 000 none)
    local out
    out=$(curl -sS -m 15 -H "X-API-Key: $1" -w $'\n%{http_code}' "$(wizarr_url)/api/invitations" 2>&1) || { WZ_CODE=000; return 1; }
    WZ_CODE=${out##*$'\n'}
    [[ "$WZ_CODE" =~ ^2 ]]
}

wizarr_server_problem() { # KEY -> why Wizarr's Jellyfin entry sends people the wrong way ("" when right); never fails
    # Its API reads servers but cannot write them, so wire checks what only its
    # UI can set. Found live Nov 2026: with no external URL Wizarr sent a new
    # user to http://jellyfin:8096, which the LAN resolved to another server.
    local u out want got
    u=$(wizarr_url 2>/dev/null) || { echo "it is not reachable from this host — ./mediastack.sh status wizarr"; return 0; }
    out=$(curl -sS -m 15 -H "X-API-Key: $1" "$u/api/servers" 2>/dev/null) || out=""
    jq -e '.servers' <<<"$out" >/dev/null 2>&1 || { echo "its servers are unreadable — ./mediastack.sh logs wizarr"; return 0; }
    want=$(svc_url jellyfin 2>/dev/null) || want=""
    [[ "$(jq '[.servers[] | select(.server_type == "jellyfin")] | length' <<<"$out")" != 0 ]] \
        || { echo "it has no Jellyfin server yet — add one: Settings → Servers → Add Server (URL http://$(svc_addr jellyfin), External URL $want)"; return 0; }
    got=$(jq -r '[.servers[] | select(.server_type == "jellyfin")][0].external_url // ""' <<<"$out")
    [[ "${got%/}" == "$want" ]] && return 0
    # quoted: a space pasted around the address is invisible otherwise (found live Nov 2026)
    local stray=""
    [[ "$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<<"$got")" != "$got" ]] && stray=" — it has spaces around it"
    if [[ -z "$got" ]]; then
        echo "its Jellyfin server's External URL is empty, so people land on its internal address after signing up — set it to $want (Settings → Servers → edit the Jellyfin server)"
    else
        echo "its Jellyfin server's External URL is \"$got\"$stray, so people are sent there after signing up — set it to exactly $want (Settings → Servers → edit the Jellyfin server)"
    fi
}

wire_wizarr() {
    hr "wire: wizarr"
    svc_enabled wizarr || { info "wizarr not enabled — skipped"; return 0; }
    wire_gate wizarr
    # a virgin wizarr 302s /health to /setup (onboarding middleware) —
    # any 2xx/3xx means the app is up and serving
    http_ready wizarr "$(wizarr_url)/health" '^[23]' || return 0
    local key host domain
    key=$(env_get WIZARR_API_KEY)
    if [[ -n "$key" ]]; then
        if wizarr_key_works "$key"; then ok "API key verified — mint invites with: ./mediastack.sh invite"; wizarr_server_check "$key"; return 0; fi
        [[ "$WZ_CODE" != 000 ]] || { wfail "wizarr did not answer while its API key was checked — ./mediastack.sh logs wizarr"; return 0; }
        # refused: the stored key is not Wizarr's (a paste cut short, or deleted in its UI) — a new one is asked, never the dead end of keeping it
        if (( WIRE_DRY )) || [[ ! -t 0 ]]; then
            w_would "replace the stored wizarr API key (wizarr refuses it, HTTP $WZ_CODE) — a new one from $WIZARR_KEY_WHERE, pasted at a terminal: ./mediastack.sh wire wizarr" || true
            return 0
        fi
        warn "wizarr refuses the stored API key [HTTP $WZ_CODE] — make a new one in $WIZARR_KEY_WHERE and paste it"
        wizarr_key_ask refused; return 0
    fi
    if (( WIRE_DRY )); then
        w_would "store + verify a wizarr API key (pasted by you after wizarr's one-time UI first-run)" || true
        return 0
    fi
    if [[ ! -t 0 ]]; then
        info "no WIZARR_API_KEY yet — wizarr's first-run is a one-time UI step; run './mediastack.sh wire wizarr' interactively after it"
        return 0
    fi
    host=$(svc_subdomain wizarr); domain=$(env_get STACK_DOMAIN)
    local jfkey; jfkey=$(env_or_note JELLYFIN_API_KEY "(empty — run 'wire jellyfin' first to mint it)")
    explain "Wizarr first-run (one-time, in its UI)" \
"Wizarr's admin account and API keys can only be created in its web UI —
there is no automation API for this by upstream design. Once, ever:
  1. open ${domain:+https://$host.$domain (or }http://$(hostname -I 2>/dev/null | awk '{print $1}'):$(svc_hostport wizarr)${domain:+)}
  2. create the admin account
  3. Settings -> Servers -> Add Server:
       Name            jellyfin
       Server Type     Jellyfin
       URL (Internal)  http://$(svc_addr jellyfin)
       External URL    $(svc_url jellyfin)   (where people land after signing up)
       API Key         $jfkey
     then Test & Add
  4. $WIZARR_KEY_WHERE -> create an API key, and paste it below
Paste nothing to skip for now — re-run 'wire wizarr' any time."
    wizarr_key_ask
}

wizarr_server_check() { # KEY — wire: Wizarr's Jellyfin entry sends people to this stack's Jellyfin (only its UI can change it)
    local why; why=$(wizarr_server_problem "$1")
    if [[ -n "$why" ]]; then wfail "wizarr: $why"; else ok "wizarr: sends people to $(svc_url jellyfin) after signing up"; fi
}

wizarr_key_ask() { # wizarr_key_ask [refused] — a pasted key goes into .env only once Wizarr takes it; refused, asked again; Enter skips
    while true; do
        ask_token "Wizarr API key (input hidden; Enter = skip)" "" optional
        if [[ -z "$REPLY_VAL" ]]; then
            if [[ "${1:-}" == refused ]]; then wfail "wizarr still refuses the stored API key — 'invite' cannot mint links until: ./mediastack.sh wire wizarr"
            else info "skipped — invites stay in wizarr's UI until a key is stored: ./mediastack.sh wire wizarr"; fi
            return 0
        fi
        if wizarr_key_works "$REPLY_VAL"; then
            env_set WIZARR_API_KEY "$REPLY_VAL"; ok "API key verified and stored — mint invites with: ./mediastack.sh invite"
            wizarr_server_check "$REPLY_VAL"; return 0
        fi
        [[ "$WZ_CODE" != 000 ]] || { wfail "wizarr did not answer while the key was checked — nothing stored; ./mediastack.sh logs wizarr"; return 0; }
        fail "wizarr refuses that key [HTTP $WZ_CODE] — nothing stored (a paste cut short?). Paste it again, or Enter to skip."
    done
}

wizarr_doctor() { # doctor: apps — its stored API key works ('invite' needs it)
    local wkey wcode
    wkey=$(env_get WIZARR_API_KEY)
    if [[ -z "$wkey" ]]; then
        warn "wizarr has no stored API key — invites need it: ./mediastack.sh wire wizarr"
    else
        wcode=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -H "X-API-Key: $wkey" \
                "$(wizarr_url)/api/invitations" 2>/dev/null || echo 000)
        if [[ "$wcode" =~ ^2 ]]; then
            ok "wizarr API key works ('invite' is ready)"
            local why; why=$(wizarr_server_problem "$wkey")
            if [[ -n "$why" ]]; then d_fail "wizarr: $why" "a new user is sent somewhere other than this stack's Jellyfin" "in Wizarr's UI, as said above"
            else ok "wizarr sends people to $(svc_url jellyfin) after signing up"; fi
        else
            d_fail "wizarr rejected the stored API key [HTTP $wcode]" "'invite' cannot mint links" "make a new key in wizarr's $WIZARR_KEY_WHERE, then: ./mediastack.sh wire wizarr (it asks for it)"
        fi
    fi
}

wizarr_invite() { # wizarr_invite [EXPIRES-DAYS] — mint a Wizarr invitation and print the ready-to-share URL
    local expires="${1:-}" key
    [[ "$(c_state "$(svc_cname wizarr)")" == running ]] || die "wizarr is not running: ./mediastack.sh up"
    key=$(env_get WIZARR_API_KEY)
    [[ -n "$key" ]] || die "No wizarr API key stored yet — run: ./mediastack.sh wire wizarr"
    # server discovery: a create without server_ids deliberately answers 400
    # WITH the available_servers list (upstream-documented behaviour)
    local disc dcode ids out code url exp_line
    disc=$(curl -sS -m 15 -X POST -H "X-API-Key: $key" -H "Content-Type: application/json" \
           -d '{}' -w $'\n%{http_code}' "$(wizarr_url)/api/invitations" 2>&1) \
        || die "wizarr unreachable: $(head -c200 <<<"$disc")"
    dcode=${disc##*$'\n'}; disc=${disc%$'\n'*}
    [[ "$dcode" == 400 || "$dcode" =~ ^2 ]] || die "wizarr refused the request [HTTP $dcode]: $(head -c200 <<<"$disc")
  (401 = stale API key: re-run 'wire wizarr')"
    ids=$(jq -c '[.available_servers[]?.id]' <<<"$disc" 2>/dev/null)
    [[ "$ids" != "[]" && -n "$ids" ]] || die "wizarr has no verified media server yet — finish its one-time
  first-run in the UI (see: wire wizarr), then retry."
    out=$(curl -sS -m 15 -X POST -H "X-API-Key: $key" -H "Content-Type: application/json" \
          -d "$(jq -cn --argjson ids "$ids" --argjson e "${expires:-null}" \
               '{server_ids:$ids} + (if $e then {expires_in_days:$e} else {} end)')" \
          -w $'\n%{http_code}' "$(wizarr_url)/api/invitations" 2>&1) \
        || die "wizarr unreachable during creation: $(head -c200 <<<"$out")"
    code=${out##*$'\n'}; out=${out%$'\n'*}
    [[ "$code" =~ ^2 ]] || die "invitation rejected [HTTP $code]: $(head -c200 <<<"$out")"
    url=$(jq -r '.invitation.url // empty' <<<"$out")
    [[ -n "$url" ]] || die "invitation created but no URL in the reply: $(head -c300 <<<"$out")"
    exp_line="never expires"
    [[ -n "$expires" ]] && exp_line="expires in $expires day(s)"
    hr "Invitation ready"
    echo "  $(wizarr_public_base)${url}"
    echo "  ($exp_line — manage or revoke in wizarr's UI)"
}

wizarr_reset_link() { # wizarr_reset_link USER — Wizarr's single-use reset link (24 h): the person chooses their own password
    local user="$1" key admin out code all u n link exp when
    [[ "$(c_state "$(svc_cname wizarr)")" == running ]] || die "wizarr is not running: ./mediastack.sh up"
    key=$(env_get WIZARR_API_KEY)
    [[ -n "$key" ]] || die "No wizarr API key stored yet — run: ./mediastack.sh wire wizarr"
    admin=$(env_get JELLYFIN_ADMIN_USER)
    [[ "${user,,}" != "${admin,,}" ]] \
        || die "'$user' is the stack's own Jellyfin admin — its password: ./mediastack.sh set-credentials jellyfin"
    # Wizarr's id, not Jellyfin's; its list syncs from Jellyfin when stale, so a slow answer is normal
    out=$(curl -sS -m 60 -H "X-API-Key: $key" -w $'\n%{http_code}' "$(wizarr_url)/api/users" 2>&1) \
        || die "wizarr unreachable: $(oneline "$out")"
    code=${out##*$'\n'}; all=${out%$'\n'*}
    [[ "$code" =~ ^2 ]] || die "wizarr refused its user list [HTTP $code]: $(oneline "$all")  (401 = stale API key: ./mediastack.sh wire wizarr)"
    u=$(jq -c --arg n "${user,,}" '[.users[]? | select(.server_type == "jellyfin" and (.username | ascii_downcase) == $n)]' <<<"$all") \
        || die "wizarr's user list is unreadable: $(oneline "$all")"
    n=$(jq length <<<"$u")
    case "$n" in
        1) ;;
        0) die "wizarr has no Jellyfin user '$user' — check the name in Wizarr: Users" ;;
        *) die "wizarr lists $n Jellyfin users named '$user' — reset this one in Wizarr's UI: Users" ;;
    esac
    # asked before the link exists: a new link voids the person's last one
    local disabled=0; jellyfin_disabled "$user" && disabled=1
    out=$(curl -sS -m 15 -X POST -H "X-API-Key: $key" -w $'\n%{http_code}' \
          "$(wizarr_url)/api/users/$(jq -r '.[0].id' <<<"$u")/reset-password" 2>&1) \
        || die "wizarr unreachable while making the link: $(oneline "$out")"
    code=${out##*$'\n'}; out=${out%$'\n'*}
    [[ "$code" =~ ^2 ]] || die "wizarr refused to make a reset link [HTTP $code]: $(oneline "$out")"
    link=$(jq -r '.url // empty' <<<"$out"); exp=$(jq -r '.expires_at // empty' <<<"$out")
    [[ "$link" == /reset/* && -n "$exp" ]] || die "wizarr made a link but its reply has no /reset/ path or expiry: $(oneline "$out")"
    [[ "$exp" =~ (Z|[+-][0-9]{2}:?[0-9]{2})$ ]] || exp+=Z   # Wizarr keeps its times in UTC; one without an offset is UTC
    when=$(date -d "$exp" '+%Y-%m-%d %H:%M %Z') || die "wizarr's expiry is not a time: $exp"
    if (( disabled )); then
        warn "'$user' is disabled in Jellyfin (too many wrong passwords, or an admin's choice) — the link sets a password, but they sign in only once enabled again: Administration → Users → $user → untick 'Disable this user'"
    fi
    hr "Reset link for $(jq -r '.[0].username' <<<"$u")"
    echo "  $(wizarr_public_base)${link}"
    echo "  (single-use, until $when — a newer link voids this one)"
    info "Send it to them privately. They choose their own password; no one else sees it."
}

wizarr_credentials() { # credentials (lib/access.sh): its API key, and its admin (its own, not one of the stack's)
    printf '  %-10s %s\n' "API key" "$(env_or_note WIZARR_API_KEY '(not set — run wire wizarr)')"
    info "Wizarr's Add Server form asks for the Jellyfin API key (above)."
    info "Wizarr's ADMIN login is its own account — set-credentials does not cover it; rotate it in Wizarr's UI."
}
