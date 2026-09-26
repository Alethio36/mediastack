#!/usr/bin/env bash
# lib/access.sh — who can get in: the logins the stack created or stores
# (`credentials`), rotating one everywhere it lives (`set-credentials`), and
# household invitations (`invite`, via Wizarr). Sourced by the entrypoint;
# relies on lib/common.sh, the entrypoint's helpers and lib/integrations.sh's
# per-app API helpers at call time.

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
    printf '%-22s %s\n' "Jellyfin API key"      "$(env_get JELLYFIN_API_KEY '(not set — run wire jellyfin)')"
    if svc_enabled authentik; then
        printf '%-22s %s\n' "Portal admin user"     "akadmin"
        printf '%-22s %s\n' "Portal admin password" "$(env_get AUTHENTIK_ADMIN_PASSWORD '(generated at the first up)')"
    fi
    printf '%-22s %s\n' "Wizarr API key"        "$(env_get WIZARR_API_KEY '(not set — run wire wizarr)')"
    info "Seerr owner = the Jellyfin admin above; all Seerr sign-ins use Jellyfin accounts (no separate Seerr passwords exist)."
    info "The Jellyfin API key is what Wizarr's Add Server form asks for."
    info "Wizarr's ADMIN login is its own account — set-credentials does not cover it; rotate in Wizarr's UI."
    info "Meilisearch master key is machine-to-machine — apps use it, you never need it."
}

cmd_set_credentials() { # rotate a stored credential in the app(s) AND .env, atomically
    load_env; render
    local target="${1:-}"
    case "$target" in arr|qbit|jellyfin|pihole|traefik|all) ;; *)
        die "usage: set-credentials <arr|qbit|jellyfin|pihole|traefik|all>
  arr       the shared login of every arr app (+ cleanuparr's account password)
  qbit      qBittorrent's WebUI login (+ every place that stores it)
  jellyfin  the Jellyfin admin password (Seerr/Wizarr need no change)
  pihole    the Pi-hole admin password
  traefik   the Traefik dashboard password
  all       ONE password across all of the above (usernames stay put)" ;; esac
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
    all)
        local pass
        explain "One password across the stack" \
"Sets a single password on the arr login (6 apps + cleanuparr follows),
qBittorrent (and everything storing its login), the Jellyfin admin,
Pi-hole, and the Traefik dashboard.
Usernames stay as they are. Deliberate trade-off: one reused password
means one leak opens everything — use a strong, stack-unique one.
NOT covered: Wizarr's admin account is its own — rotate it in Wizarr's
UI (Settings -> Account) yourself."
        ask_secret "New stack password" "$(head -c12 /dev/urandom | base64 | tr -d '=+/')"; pass="$REPLY_VAL"
        sc_rotate_arr "$(env_get ARR_USER admin)" "$pass"
        sc_rotate_qbit "$(env_get QBITTORRENT_USER admin)" "$pass"
        sc_rotate_jellyfin "$pass"
        sc_rotate_pihole "$pass"
        sc_rotate_traefik "$pass"
        warn "Wizarr's admin password is NOT rotated by this — change it in Wizarr's UI."
        ok "one password now covers arr + qbit + jellyfin + pihole + traefik — view: ./mediastack.sh credentials"
        ;;
    esac
}

sc_rotate_arr() { # USER PASS — every arr-family app + cleanuparr follows
        local user="$1" pass="$2" olduser oldpass s
        olduser=$(env_get ARR_USER); oldpass=$(env_get ARR_PASSWORD)
        env_set ARR_USER "$user"; env_set ARR_PASSWORD "$pass"
        for s in $(arr_instances) prowlarr; do
            svc_enabled "$s" || continue
            arr_forms_login "$s" force   # the new password is stored either way (the login it falls back to)
            arr_login "$s"               # and, behind the portal, it goes back to trusting it
        done
        if svc_enabled cleanuparr && [[ "$(c_state "$(svc_cname cleanuparr)")" == running ]]; then
            local lout ltok
            lout=$(cup_api POST /auth/login "" "$(jq -cn --arg u "$olduser" --arg p "$oldpass" '{username:$u,password:$p}')" || true)
            ltok=$(jq -r '.tokens.accessToken // empty' <<<"$lout" 2>/dev/null)
            if [[ -n "$ltok" ]]; then
                cup_api PUT /account/password "Authorization: Bearer $ltok" \
                    "$(jq -cn --arg c "$oldpass" --arg n "$pass" '{currentPassword:$c,newPassword:$n}')" >/dev/null \
                    && ok "cleanuparr account password rotated in step" \
                    || warn "cleanuparr refused the password change [HTTP $(cup_code)] — change it in its UI (login: '$olduser' + the OLD password)"
            else
                warn "could not sign in to cleanuparr with the previous login — rotate its password in its UI"
            fi
            [[ "$user" != "$olduser" ]] && warn "cleanuparr's username stays '$olduser' (no API to change it)"
        fi
        ok "arr login rotated — view: ./mediastack.sh credentials"
}

sc_rotate_qbit() { # USER PASS — qbit + every place that stores its login
        local user="$1" pass="$2" s
        qb_login "$(env_get QBITTORRENT_USER)" "$(env_get QBITTORRENT_PASSWORD)" \
            || die "cannot sign in to qBittorrent with the stored credentials — fix that first (wire qbit)"
        qb_api /app/setPreferences "json=$(jq -cn --arg u "$user" --arg p "$pass" '{web_ui_username:$u,web_ui_password:$p}')" >/dev/null || true  # re-login below is the verdict
        sleep 2
        qb_login "$user" "$pass" || die "qBittorrent did not accept the new credentials — inspect: logs qbittorrent"
        env_set QBITTORRENT_USER "$user"; env_set QBITTORRENT_PASSWORD "$pass"
        ok "qBittorrent login rotated and verified"
        local key url cur id ent
        # every arr-family app holding a qBittorrent entry — prowlarr's (manual
        # grabs) included: missing it left a stale password there
        for s in $(arr_instances) prowlarr; do
            svc_enabled "$s" || continue
            key=$(arr_key "$s"); url=$(arr_url "$s")
            cur=$(api GET "$url/api/$(arr_apiver "$s")/downloadclient" "$key") \
                || { wfail "$s: could not read its download clients — its qBittorrent login was NOT updated; fix in its UI [$(oneline "$cur")]"; continue; }
            id=$(jq -r '.[] | select(.implementation=="QBittorrent") | .id' <<<"$cur" 2>/dev/null | head -1)
            [[ -n "$id" ]] || { info "$s: no qBittorrent download client entry — skipped"; continue; }
            if [[ -n "$(jq -r --argjson i "$id" '.[] | select(.id==$i) | .fields[]? | select(.name=="apiKey") | .value // ""' <<<"$cur")" ]]; then
                info "$s: signs in to qBittorrent with its API key — the login rotation does not apply"; continue
            fi
            ent=$(jq -c --argjson i "$id" --arg u "$user" --arg p "$pass" '
                .[] | select(.id==$i)
                | .fields = [ .fields[]
                    | if .name=="username" then .value=$u
                      elif .name=="password" then .value=$p
                      else . end ]' <<<"$cur")
            api PUT "$url/api/$(arr_apiver "$s")/downloadclient/$id" "$key" "$ent" >/dev/null \
                && ok "$s: download-client entry updated" \
                || wfail "$s: could not update its download-client entry — fix in its UI (Settings -> Download Clients)"
        done
        if svc_enabled cleanuparr && [[ -n "$(env_get CLEANUPARR_API_KEY)" ]]; then
            local KH dcs dcid dcent
            KH="X-Api-Key: $(env_get CLEANUPARR_API_KEY)"
            dcs=$(cup_api GET /configuration/download_client "$KH") \
                || { wfail "cleanuparr: could not read its download clients — its qBittorrent login was NOT updated; fix in its UI [HTTP $(cup_code)]"; dcs=""; }
            dcid=$(jq -r '.clients[]? | select(.name=="qbittorrent") | .id' <<<"$dcs" 2>/dev/null | head -1)
            if [[ -n "$dcid" ]]; then
                dcent=$(jq -c --arg i "$dcid" --arg u "$user" --arg p "$pass" \
                        '.clients[] | select(.id==$i) | .username=$u | .password=$p' <<<"$dcs")
                cup_api PUT "/configuration/download_client/$dcid" "$KH" "$dcent" >/dev/null \
                    && ok "cleanuparr connection updated" \
                    || wfail "cleanuparr connection not updated [HTTP $(cup_code)] — fix in its UI"
            fi
        fi
        if svc_enabled lazylibrarian && [[ -n "$(ll_key)" ]]; then
            ll_api writeCFG "name=USER&group=QBITTORRENT&value=$user" >/dev/null \
                && ll_api writeCFG "name=PASS&group=QBITTORRENT&value=$pass" >/dev/null \
                && ok "lazylibrarian qBittorrent login updated" \
                || wfail "lazylibrarian qBittorrent login not updated — fix in its UI (Settings -> Downloaders)"
        fi
}

sc_rotate_pihole() { # PASS — env-driven; recreate applies it
        local pass="$1"
        svc_enabled pihole || { info "pihole not enabled — skipped"; return 0; }
        env_set PIHOLE_PASSWORD "$pass"
        DC up -d pihole >/dev/null 2>&1 \
            && ok "Pi-hole password rotated (container recreated)" \
            || wfail "Pi-hole recreate failed — apply with: ./mediastack.sh up"
}

sc_rotate_traefik() { # PASS — regenerated into the watched dynamic config
        local pass="$1"
        svc_enabled traefik || { info "traefik not enabled — skipped"; return 0; }
        [[ -n "$(env_get TRAEFIK_DASH_USER)" ]] || { info "traefik dashboard never configured — skipped (run traefik-setup first)"; return 0; }
        env_set TRAEFIK_DASH_PASSWORD "$pass"
        traefik_gen \
            && ok "Traefik dashboard password rotated (config regenerated; traefik watches it live)" \
            || wfail "traefik config regeneration failed — inspect: ./mediastack.sh traefik-setup"
}

sc_rotate_jellyfin() { # PASS — the Jellyfin admin (Seerr/Wizarr unaffected)
        local npass="$1" juser jpass auth tok
        juser=$(env_get JELLYFIN_ADMIN_USER); jpass=$(env_get JELLYFIN_ADMIN_PASSWORD)
        [[ -n "$juser" && -n "$jpass" ]] || die "no Jellyfin admin stored — run 'wire jellyfin' first"
        auth=$(jf_api POST /Users/AuthenticateByName "" "$(jq -cn --arg u "$juser" --arg p "$jpass" '{Username:$u,Pw:$p}')") \
            || die "Jellyfin rejected the stored admin login [HTTP $(jf_code)] — is .env stale?"
        tok=$(jq -r '.AccessToken // empty' <<<"$auth")
        jf_api POST /Users/Password "$tok" "$(jq -cn --arg c "$jpass" --arg n "$npass" '{CurrentPw:$c,NewPw:$n}')" >/dev/null \
            || die "Jellyfin refused the password change [HTTP $(jf_code)]"
        jf_api POST /Users/AuthenticateByName "" "$(jq -cn --arg u "$juser" --arg p "$npass" '{Username:$u,Pw:$p}')" >/dev/null \
            || die "verification sign-in with the NEW password failed — check Jellyfin's users in its dashboard"
        env_set JELLYFIN_ADMIN_PASSWORD "$npass"
        ok "Jellyfin admin password rotated and verified"
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
