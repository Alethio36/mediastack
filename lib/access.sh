#!/usr/bin/env bash
# lib/access.sh — who can get in: the logins the stack created or stores
# (`credentials`), rotating one everywhere it lives (`set-credentials`), and
# household invitations (`invite`: authentik_invite or wizarr_invite, each in
# its provider's folder — no provider's API is spoken here). The account model — which provider signs
# people in — is asked here once (signin_model), never by a service's name. Each target's rotation is
# sc_rotate_<target> in its service's folder (services/<name>/*.sh); this file
# keeps the verbs, their order and their words. Sourced by the entrypoint;
# relies on lib/common.sh, the entrypoint's helpers and the services' own
# API helpers at call time.

signin_model() { # -> authentik | wizarr | none: who signs people in (the installer allows one; the portal wins if both)
    if svc_enabled authentik; then echo authentik
    elif svc_enabled wizarr; then echo wizarr
    else echo none; fi
}
signin_is() { [[ "$(signin_model)" == "$1" ]]; }   # signin_is MODEL

cmd_credentials() {
    load_env
    hr "Credentials (stored in .env)"
    printf '%-22s %s\n' "Arr apps user"        "$(env_or_note ARR_USER '(not set — run wire)')"
    printf '%-22s %s\n' "Arr apps password"    "$(env_or_note ARR_PASSWORD '(not set — run wire)')"
    printf '%-22s %s\n' "qBittorrent user"     "$(env_or_note QBITTORRENT_USER '(not set — run wire)')"
    printf '%-22s %s\n' "qBittorrent password" "$(env_or_note QBITTORRENT_PASSWORD '(not set — run wire)')"
    svc_enabled deluge && printf '%-22s %s\n' "Deluge password" "$(env_or_note DELUGE_PASSWORD '(not set — run wire deluge)')"
    if svc_enabled transmission; then
        printf '%-22s %s\n' "Transmission user"     "$(env_or_note TRANSMISSION_USER '(not set — run wire transmission)')"
        printf '%-22s %s\n' "Transmission password" "$(env_or_note TRANSMISSION_PASSWORD '(not set — run wire transmission)')"
    fi
    printf '%-22s %s\n' "Pi-hole password"     "$(env_or_note PIHOLE_PASSWORD '(dns profile not configured)')"
    printf '%-22s %s\n' "Traefik dash user"    "$(env_or_note TRAEFIK_DASH_USER '(traefik not configured)')"
    printf '%-22s %s\n' "Traefik dash password" "$(env_or_note TRAEFIK_DASH_PASSWORD '(traefik not configured)')"
    printf '%-22s %s\n' "Jellyfin admin user"   "$(env_or_note JELLYFIN_ADMIN_USER '(not set — run wire)')"
    printf '%-22s %s\n' "Jellyfin admin password" "$(env_or_note JELLYFIN_ADMIN_PASSWORD '(not set — run wire)')"
    signin_is authentik && info "With the portal, that Jellyfin admin is the stack's own local account (and the emergency login) — people sign in with their portal accounts; admins get Jellyfin administrator rights from the portal's 'admins' group."
    printf '%-22s %s\n' "Jellyfin API key"      "$(env_or_note JELLYFIN_API_KEY '(not set — run wire jellyfin)')"
    if svc_enabled audiobookshelf; then
        printf '%-22s %s\n' "Audiobookshelf root"   "$(env_or_note ABS_ADMIN_USER '(not set — run wire audiobookshelf)')"
        printf '%-22s %s\n' "Audiobookshelf root pw" "$(env_or_note ABS_ADMIN_PASSWORD '(not set — run wire audiobookshelf)')"
        signin_is authentik && printf '%-22s %s\n' "Audiobookshelf root at" "$(svc_url audiobookshelf)/audiobookshelf/login?autoLaunch=0   (its login page otherwise goes straight to the portal)"
    fi
    if svc_enabled kavita; then
        printf '%-22s %s\n' "Kavita admin"          "$(env_or_note KAVITA_ADMIN_USER '(not set — run wire kavita)')"
        printf '%-22s %s\n' "Kavita admin pw"       "$(env_or_note KAVITA_ADMIN_PASSWORD '(not set — run wire kavita)')"
        signin_is authentik && printf '%-22s %s\n' "Kavita admin at" "$(svc_url kavita)/login?skipAutoLogin=true   (its login page otherwise goes straight to the portal)"
    fi
    if signin_is authentik; then
        printf '%-22s %s\n' "Portal admin user"     "akadmin"
        printf '%-22s %s\n' "Portal admin password" "$(env_or_note AUTHENTIK_ADMIN_PASSWORD '(generated at the first up)')"
    fi
    printf '%-22s %s\n' "Wizarr API key"        "$(env_or_note WIZARR_API_KEY '(not set — run wire wizarr)')"
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
    if signin_is authentik; then
        info "Give an app the https address and the key: behind the portal the /api path skips its login, the key still guards it."
    fi
}

cmd_set_credentials() { # rotate a stored credential in the app(s) AND .env, atomically
    load_env; render
    local target="${1:-}"
    case "$target" in arr|qbit|deluge|transmission|jellyfin|pihole|traefik|audiobookshelf|kavita|portal|all) ;; *)
        die "usage: set-credentials <arr|qbit|deluge|transmission|jellyfin|pihole|traefik|audiobookshelf|kavita|portal|all>
  arr             the shared login of every arr app (+ cleanuparr's account password)
  qbit            qBittorrent's WebUI login (+ every place that stores it)
  deluge          Deluge's web password (+ every download-client entry holding it)
  transmission    Transmission's password (recreated to take it; + every entry holding it)
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
        user=$(env_get ARR_USER); ask SC_U "Username" "${user:-admin}"; user="$REPLY_VAL"
        ask_secret "New password" "$(head -c12 /dev/urandom | base64 | tr -d '=+/')"; pass="$REPLY_VAL"
        sc_rotate_arr "$user" "$pass"
        ;;
    qbit)
        local user pass
        explain "Rotate the qBittorrent login" \
"Changes the WebUI login and updates everything that stores it: each
arr's download-client entry and cleanuparr's connection."
        user=$(env_get QBITTORRENT_USER); ask SC_QU "Username" "${user:-admin}"; user="$REPLY_VAL"
        ask_secret "New password" "$(head -c12 /dev/urandom | base64 | tr -d '=+/')"; pass="$REPLY_VAL"
        sc_rotate_qbit "$user" "$pass"
        ;;
    deluge)
        local pass
        ask_secret "New Deluge password" "$(head -c12 /dev/urandom | base64 | tr -d '=+/')"; pass="$REPLY_VAL"
        sc_rotate_deluge "$pass"
        ;;
    transmission)
        local pass
        ask_secret "New Transmission password" "$(head -c12 /dev/urandom | base64 | tr -d '=+/')"; pass="$REPLY_VAL"
        sc_rotate_transmission "$pass"
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
qBittorrent (and everything storing its login), Deluge and Transmission once
wire has set them up (and every entry holding them), the Jellyfin admin,
Pi-hole, the Traefik dashboard, Audiobookshelf's root and Kavita's admin.
Usernames stay as they are. Deliberate trade-off: one reused password
means one leak opens everything — use a strong, stack-unique one.
NOT covered: the portal's admin (set-credentials portal — it guards the
rest), and Wizarr's admin account — rotate that in Wizarr's UI
(Settings -> Account) yourself."
        ask_secret "New stack password" "$(head -c12 /dev/urandom | base64 | tr -d '=+/')"; pass="$REPLY_VAL"
        local au qu; au=$(env_get ARR_USER); qu=$(env_get QBITTORRENT_USER)
        sc_rotate_arr "${au:-admin}" "$pass"
        sc_rotate_qbit "${qu:-admin}" "$pass"
        if svc_enabled deluge && [[ -n "$(env_get DELUGE_PASSWORD)" ]]; then sc_rotate_deluge "$pass"; fi
        if svc_enabled transmission && [[ -n "$(env_get TRANSMISSION_USER)" ]]; then sc_rotate_transmission "$pass"; fi
        sc_rotate_jellyfin "$pass"
        sc_rotate_pihole "$pass"
        sc_rotate_traefik "$pass"
        sc_rotate_audiobookshelf "$pass"
        sc_rotate_kavita "$pass"
        warn "Wizarr's admin password is NOT rotated by this — change it in Wizarr's UI."
        signin_is authentik && info "the portal's admin keeps its own password: ./mediastack.sh set-credentials portal"
        ok "one password now covers arr + qbit + deluge/transmission (if set up) + jellyfin + pihole + traefik + audiobookshelf + kavita — view: ./mediastack.sh credentials"
        ;;
    esac
}

cmd_reset_password() { # someone locked out: their login throttle cleared, a single-use sign-in link to set a new password
    load_env; render
    local user="${1:-}"
    [[ -n "$user" ]] || die "usage: reset-password <username>"
    if ! signin_is authentik; then
        signin_is wizarr && die "With Wizarr, accounts are Jellyfin's own: reset it in Jellyfin's dashboard (Administration → Users → $user → Password)."
        die "Neither account model is enabled — there are no accounts to reset."
    fi
    [[ "$(c_health "$(svc_cname authentik)")" == healthy ]] || die "authentik is not healthy yet — ./mediastack.sh status authentik"
    authentik_recover "$user"
}

cmd_users() { # the portal's people, as authentik has them
    load_env; render
    signin_is authentik || die "the portal (authentik) is not enabled — with Wizarr, people are Jellyfin's own (its dashboard → Users)"
    [[ "$(c_health "$(svc_cname authentik)")" == healthy ]] || die "authentik is not healthy yet — ./mediastack.sh status authentik"
    local out
    out=$(signin_people) || die "authentik refused the user list: $(oneline "$out")"
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
    signin_is authentik || die "set-email is for the portal (authentik); it is not enabled."
    [[ "$(c_health "$(svc_cname authentik)")" == healthy ]] || die "authentik is not healthy yet — ./mediastack.sh status authentik"
    authentik_set_email "${args[0]}" "${args[1]}" "$yes"
}

cmd_invite() { # mint an invitation (authentik's or Wizarr's, whichever runs) and print the ready-to-share URL
    load_env; render
    if signin_is authentik; then
        local days=7 to=""   # single use, a week: an unused link stops working on its own
        local usage="usage: invite [--expires 1|7|30] [--email ADDRESS]   (default: 7 days)"
        while [[ $# -gt 0 ]]; do case "$1" in
            --expires) case "${2:-}" in 1|7|30) days="$2"; shift 2 ;; *) die "$usage" ;; esac ;;
            --email) env_type_ok email "${2:-}" || die "'${2:-}' is not an email address — $usage"; to="$2"; shift 2 ;;
            *) die "$usage" ;;
        esac; done
        # checked before the invitation exists: no link is minted for a send that cannot happen
        [[ -z "$to" ]] || authentik_email_ready \
            || die "sending the invitation needs the portal's email working — set it up and test it: ./mediastack.sh email test <your address> (docs/email.md)"
        authentik_invite "$days" "$to"; return 0
    fi
    local expires=""
    while [[ $# -gt 0 ]]; do case "$1" in
        --expires) case "${2:-}" in 1|7|30) expires="$2"; shift 2 ;;
                   *) die "usage: invite [--expires 1|7|30]   (no flag = never expires)" ;; esac ;;
        --email) die "sending the invitation by email needs the portal (authentik) — with Wizarr, share the printed link yourself" ;;
        *) die "usage: invite [--expires 1|7|30]   (no flag = never expires)" ;;
    esac; done
    signin_is wizarr || die "Neither account model is enabled — invitations come from authentik or Wizarr: ./mediastack.sh enable authentik   (or: enable wizarr)"
    wizarr_invite "$expires"
}
