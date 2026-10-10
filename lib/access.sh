#!/usr/bin/env bash
# lib/access.sh — who can get in: the logins the stack created or stores
# (`credentials`), rotating one everywhere it lives (`set-credentials`), and
# household invitations (`invite`, via Wizarr). Each target's rotation is
# sc_rotate_<target> in its service's folder (services/<name>/*.sh); this file
# keeps the verbs, their order and their words. Sourced by the entrypoint;
# relies on lib/common.sh, the entrypoint's helpers and the services' own
# API helpers at call time.

cmd_credentials() {
    load_env
    hr "Credentials (stored in .env)"
    printf '%-22s %s\n' "Arr apps user"        "$(env_get ARR_USER '(not set — run wire)')"
    printf '%-22s %s\n' "Arr apps password"    "$(env_get ARR_PASSWORD '(not set — run wire)')"
    printf '%-22s %s\n' "qBittorrent user"     "$(env_get QBITTORRENT_USER '(not set — run wire)')"
    printf '%-22s %s\n' "qBittorrent password" "$(env_get QBITTORRENT_PASSWORD '(not set — run wire)')"
    printf '%-22s %s\n' "Pi-hole password"     "$(env_get PIHOLE_PASSWORD '(dns profile not configured)')"
    printf '%-22s %s\n' "Traefik dash user"    "$(env_get TRAEFIK_DASH_USER '(traefik not configured)')"
    printf '%-22s %s\n' "Traefik dash password" "$(env_get TRAEFIK_DASH_PASSWORD '(traefik not configured)')"
    printf '%-22s %s\n' "Jellyfin admin user"   "$(env_get JELLYFIN_ADMIN_USER '(not set — run wire)')"
    printf '%-22s %s\n' "Jellyfin admin password" "$(env_get JELLYFIN_ADMIN_PASSWORD '(not set — run wire)')"
    svc_enabled authentik && info "With the portal, that Jellyfin admin is the stack's own local account (and the emergency login) — people sign in with their portal accounts; admins get Jellyfin administrator rights from the portal's 'admins' group."
    printf '%-22s %s\n' "Jellyfin API key"      "$(env_get JELLYFIN_API_KEY '(not set — run wire jellyfin)')"
    if svc_enabled audiobookshelf; then
        printf '%-22s %s\n' "Audiobookshelf root"   "$(env_get ABS_ADMIN_USER '(not set — run wire audiobookshelf)')"
        printf '%-22s %s\n' "Audiobookshelf root pw" "$(env_get ABS_ADMIN_PASSWORD '(not set — run wire audiobookshelf)')"
        svc_enabled authentik && printf '%-22s %s\n' "Audiobookshelf root at" "$(svc_url audiobookshelf)/audiobookshelf/login?autoLaunch=0   (its login page otherwise goes straight to the portal)"
    fi
    if svc_enabled kavita; then
        printf '%-22s %s\n' "Kavita admin"          "$(env_get KAVITA_ADMIN_USER '(not set — run wire kavita)')"
        printf '%-22s %s\n' "Kavita admin pw"       "$(env_get KAVITA_ADMIN_PASSWORD '(not set — run wire kavita)')"
        svc_enabled authentik && printf '%-22s %s\n' "Kavita admin at" "$(svc_url kavita)/login?skipAutoLogin=true   (its login page otherwise goes straight to the portal)"
    fi
    if svc_enabled authentik; then
        printf '%-22s %s\n' "Portal admin user"     "akadmin"
        printf '%-22s %s\n' "Portal admin password" "$(env_get AUTHENTIK_ADMIN_PASSWORD '(generated at the first up)')"
    fi
    printf '%-22s %s\n' "Wizarr API key"        "$(env_get WIZARR_API_KEY '(not set — run wire wizarr)')"
    credentials_api_keys
    info "Seerr owner = the Jellyfin admin above; all Seerr sign-ins use Jellyfin accounts (no separate Seerr passwords exist)."
    info "The Jellyfin API key is what Wizarr's Add Server form asks for."
    info "Wizarr's ADMIN login is its own account — set-credentials does not cover it; rotate in Wizarr's UI."
    info "Meilisearch master key is machine-to-machine — apps use it, you never need it."
}

credentials_api_keys() { # the keys companion apps (nzb360, LunaSea, Home Assistant…) ask for, with the address to give them
    local s k rows=""
    for s in $(arr_instances) prowlarr bazarr seerr; do
        svc_enabled "$s" || continue
        case "$s" in
            bazarr) k=$(bazarr_key) ;;
            seerr)  k=$(env_get SEERR_API_KEY) ;;
            *)      k=$(arr_key "$s") ;;
        esac
        rows+=$(printf '%-14s %-44s %s' "$s" "$(svc_url "$s")" "${k:-(not created yet — start it once)}")$'\n'
    done
    [[ -n "$rows" ]] || return 0
    hr "API keys (companion apps)"
    printf '%s' "$rows"
    if svc_enabled authentik; then
        info "Give an app the https address and the key: behind the portal the /api path skips its login, the key still guards it."
    fi
}

cmd_set_credentials() { # rotate a stored credential in the app(s) AND .env, atomically
    load_env; render
    local target="${1:-}"
    case "$target" in arr|qbit|jellyfin|pihole|traefik|audiobookshelf|kavita|portal|all) ;; *)
        die "usage: set-credentials <arr|qbit|jellyfin|pihole|traefik|audiobookshelf|kavita|portal|all>
  arr             the shared login of every arr app (+ cleanuparr's account password)
  qbit            qBittorrent's WebUI login (+ every place that stores it)
  jellyfin        the Jellyfin admin password (Seerr/Wizarr need no change)
  pihole          the Pi-hole admin password
  traefik         the Traefik dashboard password
  audiobookshelf  its root password (every session signed in as root ends)
  kavita          its admin password (the stack's own account)
  portal          the portal's admin (akadmin) password
  all             ONE password across all of the above except portal (usernames stay put)
Someone else locked out of the portal: ./mediastack.sh reset-password <username>" ;; esac
    [[ -t 0 ]] || die "set-credentials is interactive — run it at a terminal."

    case "$target" in
    arr)
        local user pass
        explain "Rotate the arr login" \
"One login for Sonarr/Radarr/Lidarr/Prowlarr/Bazarr — and cleanuparr's
account password follows it. Cleanuparr's USERNAME cannot be changed via
its API: if you change the username here, sign-in to cleanuparr keeps the
old one."
        ask SC_U "Username" "$(env_get ARR_USER admin)"; user="$REPLY_VAL"
        ask_secret "New password" "$(head -c12 /dev/urandom | base64 | tr -d '=+/')"; pass="$REPLY_VAL"
        sc_rotate_arr "$user" "$pass"
        ;;
    qbit)
        local user pass
        explain "Rotate the qBittorrent login" \
"Changes the WebUI login and updates everything that stores it: each
arr's download-client entry and cleanuparr's connection."
        ask SC_QU "Username" "$(env_get QBITTORRENT_USER admin)"; user="$REPLY_VAL"
        ask_secret "New password" "$(head -c12 /dev/urandom | base64 | tr -d '=+/')"; pass="$REPLY_VAL"
        sc_rotate_qbit "$user" "$pass"
        ;;
    pihole)
        local pass
        ask_secret "New Pi-hole password" "$(head -c12 /dev/urandom | base64 | tr -d '=+/')"; pass="$REPLY_VAL"
        sc_rotate_pihole "$pass"
        ;;
    traefik)
        local pass
        ask_secret "New dashboard password" "$(head -c12 /dev/urandom | base64 | tr -d '=+/')"; pass="$REPLY_VAL"
        sc_rotate_traefik "$pass"
        ;;
    jellyfin)
        local npass
        explain "Rotate the Jellyfin admin password" \
"Seerr federates to Jellyfin (nothing to change there) and Wizarr connects
by API key (unchanged). Only this password and .env move."
        ask_secret "New password" "$(head -c12 /dev/urandom | base64 | tr -d '=+/')"; npass="$REPLY_VAL"
        sc_rotate_jellyfin "$npass"
        ;;
    audiobookshelf)
        local pass
        explain "Rotate Audiobookshelf's root password" \
"The root account is the stack's own (people sign in with their own
accounts). A password change ends every session signed in as root: other
browsers and apps must sign in again (a page already open keeps working up
to an hour)."
        ask_secret "New password" "$(head -c12 /dev/urandom | base64 | tr -d '=+/')"; pass="$REPLY_VAL"
        sc_rotate_audiobookshelf "$pass"
        ;;
    kavita)
        local pass
        explain "Rotate Kavita's admin password" \
"The admin is the stack's own account (people sign in with their own).
Only this password and .env move."
        ask_secret "New password" "$(head -c12 /dev/urandom | base64 | tr -d '=+/')"; pass="$REPLY_VAL"
        sc_rotate_kavita "$pass"
        ;;
    portal)
        local pass
        explain "Rotate the portal's admin password" \
"akadmin guards every admin tool behind the portal. Set here, through
authentik's API, and stored in .env (AUTHENTIK_ADMIN_PASSWORD is otherwise
read only at authentik's first start). Kept out of 'all' on purpose: the
shared password also sits in the arrs' and qBittorrent's settings."
        ask_secret "New password" "$(head -c16 /dev/urandom | base64 | tr -d '=+/')"; pass="$REPLY_VAL"
        sc_rotate_portal "$pass"
        ;;
    all)
        local pass
        explain "One password across the stack" \
"Sets a single password on the arr login (6 apps + cleanuparr follows),
qBittorrent (and everything storing its login), the Jellyfin admin,
Pi-hole, the Traefik dashboard, Audiobookshelf's root and Kavita's admin.
Usernames stay as they are. Deliberate trade-off: one reused password
means one leak opens everything — use a strong, stack-unique one.
NOT covered: the portal's admin (set-credentials portal — it guards the
rest), and Wizarr's admin account — rotate that in Wizarr's UI
(Settings -> Account) yourself."
        ask_secret "New stack password" "$(head -c12 /dev/urandom | base64 | tr -d '=+/')"; pass="$REPLY_VAL"
        sc_rotate_arr "$(env_get ARR_USER admin)" "$pass"
        sc_rotate_qbit "$(env_get QBITTORRENT_USER admin)" "$pass"
        sc_rotate_jellyfin "$pass"
        sc_rotate_pihole "$pass"
        sc_rotate_traefik "$pass"
        sc_rotate_audiobookshelf "$pass"
        sc_rotate_kavita "$pass"
        warn "Wizarr's admin password is NOT rotated by this — change it in Wizarr's UI."
        svc_enabled authentik && info "the portal's admin keeps its own password: ./mediastack.sh set-credentials portal"
        ok "one password now covers arr + qbit + jellyfin + pihole + traefik + audiobookshelf + kavita — view: ./mediastack.sh credentials"
        ;;
    esac
}

cmd_reset_password() { # someone locked out: their login throttle cleared, a single-use sign-in link to set a new password
    load_env; render
    local user="${1:-}"
    [[ -n "$user" ]] || die "usage: reset-password <username>"
    if ! svc_enabled authentik; then
        svc_enabled wizarr && die "With Wizarr, accounts are Jellyfin's own: reset it in Jellyfin's dashboard (Administration → Users → $user → Password)."
        die "Neither account model is enabled — there are no accounts to reset."
    fi
    [[ "$(c_health "$(svc_cname authentik)")" == healthy ]] || die "authentik is not healthy yet — ./mediastack.sh status authentik"
    authentik_recover "$user"
}

cmd_users() { # the portal's people, as authentik has them
    load_env; render
    svc_enabled authentik || die "the portal (authentik) is not enabled — with Wizarr, people are Jellyfin's own (its dashboard → Users)"
    [[ "$(c_health "$(svc_cname authentik)")" == healthy ]] || die "authentik is not healthy yet — ./mediastack.sh status authentik"
    local out
    out=$(ak_api GET "/core/users/?page_size=1000") || die "authentik refused the user list: $(oneline "$out")"
    { printf 'USERNAME\tNAME\tEMAIL\tGROUPS\tSIGN-IN\n'
      jq -r '.results[] | select(.type == "internal" and .username != "akadmin" and .username != "mediastack-ldap-search")
        | [.username, (.name // "-" | if . == "" then "-" else . end), (.email // "" | if . == "" then "-" else . end),
           ([.groups_obj[]?.name] | if length == 0 then "-" else join(",") end), (if .is_active then "yes" else "off" end)] | @tsv' <<<"$out"
    } | awk -F'\t' '{ for (i = 1; i <= NF; i++) { c[NR, i] = $i; if (length($i) > w[i]) w[i] = length($i) } n = NR; f = NF }
        END { for (r = 1; r <= n; r++) { line = ""; for (i = 1; i <= f; i++) line = line sprintf(i < f ? "%-" w[i] + 2 "s" : "%s", c[r, i]); print line } }'
    info "the stack's own accounts (akadmin, mediastack-ldap-search) are left out; change an email: ./mediastack.sh set-email <user> <address>"
}

cmd_set_email() { # an admin changes a person's portal email; Kavita follows; a shared address warns, --yes overrides
    load_env; render
    local yes=0 args=()
    while (( $# )); do case "$1" in --yes) yes=1; shift ;; -*) die "Unknown set-email arg '$1'" ;; *) args+=("$1"); shift ;; esac; done
    (( ${#args[@]} == 2 )) || die "usage: set-email <user> <address> [--yes]"
    svc_enabled authentik || die "set-email is for the portal (authentik); it is not enabled."
    [[ "$(c_health "$(svc_cname authentik)")" == healthy ]] || die "authentik is not healthy yet — ./mediastack.sh status authentik"
    authentik_set_email "${args[0]}" "${args[1]}" "$yes"
}

cmd_invite() { # mint an invitation (authentik's or Wizarr's, whichever runs) and print the ready-to-share URL
    load_env; render
    if svc_enabled authentik; then
        local days=7   # single use, a week: an unused link stops working on its own
        while [[ $# -gt 0 ]]; do case "$1" in
            --expires) case "${2:-}" in 1|7|30) days="$2"; shift 2 ;;
                       *) die "usage: invite [--expires 1|7|30]   (default: 7 days)" ;; esac ;;
            *) die "usage: invite [--expires 1|7|30]   (default: 7 days)" ;;
        esac; done
        authentik_invite "$days"; return 0
    fi
    local expires="" host domain base key
    while [[ $# -gt 0 ]]; do case "$1" in
        --expires) case "${2:-}" in 1|7|30) expires="$2"; shift 2 ;;
                   *) die "usage: invite [--expires 1|7|30]   (no flag = never expires)" ;; esac ;;
        *) die "usage: invite [--expires 1|7|30]   (no flag = never expires)" ;;
    esac; done
    svc_enabled wizarr || die "Neither account model is enabled — invitations come from authentik or Wizarr: ./mediastack.sh enable authentik   (or: enable wizarr)"
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
    host=$(env_get WIZARR_HOST invites); domain=$(env_get TRAEFIK_DOMAIN)
    if [[ -n "$domain" ]]; then base="https://$host.$domain"
    else base="http://$(hostname -I 2>/dev/null | awk '{print $1}'):$(svc_hostport wizarr)"; fi
    exp_line="never expires"
    [[ -n "$expires" ]] && exp_line="expires in $expires day(s)"
    hr "Invitation ready"
    echo "  ${base}${url}"
    echo "  ($exp_line — manage or revoke in wizarr's UI)"
}
