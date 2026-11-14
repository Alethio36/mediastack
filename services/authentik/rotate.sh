#!/usr/bin/env bash
# services/authentik/rotate.sh — the portal's part of rotate-secrets
# (lib/rotate.sh, docs/design-rotate.md): its API token, the LDAP outpost's
# token, akadmin's password, its own settings (signing key, database
# password, the LDAP bind password and the OIDC client secrets — one restart
# for all of them), and, as the run's very last step, every session. Sourced
# by the entrypoint; relies on lib/common.sh and authentik.sh at call time.

# its own settings: rotated together (one `up`, not one each) — name:length, as authentik_secrets_make makes them
AUTHENTIK_ROTATE_SETTINGS=(AUTHENTIK_SECRET_KEY:60 AUTHENTIK_DB_PASSWORD:32 AUTHENTIK_LDAP_BIND_PASSWORD:48 AUTHENTIK_ABS_CLIENT_SECRET:48 AUTHENTIK_KAVITA_CLIENT_SECRET:48)

authentik_secrets() {
    svc_enabled authentik || return 0
    printf 'AUTHENTIK_API_TOKEN\t\n'
    printf 'AUTHENTIK_ADMIN_PASSWORD\takadmin\n'
    [[ -n "$(env_get AUTHENTIK_LDAP_TOKEN)" ]] && printf 'AUTHENTIK_LDAP_TOKEN\t\n'
    local e keys=""; for e in "${AUTHENTIK_ROTATE_SETTINGS[@]}"; do keys+="${keys:+,}${e%%:*}"; done
    printf "authentik's settings\tportal\t%s\n" "$keys"
}
authentik_secret_rotate() {
    http_ready authentik "$(authentik_url)/-/health/ready/" '^2' || return 1   # after the restore point's restart: up before it is asked
    case "$1" in
        AUTHENTIK_API_TOKEN)      authentik_rotate_api_token ;;
        AUTHENTIK_ADMIN_PASSWORD) authentik_rotate_admin ;;
        AUTHENTIK_LDAP_TOKEN)     authentik_rotate_ldap_token ;;
        "authentik's settings")   authentik_rotate_settings ;;
        *) fail "authentik: no rotation for '$1'"; return 1 ;;
    esac
}

ak_token_set_key() { # ak_token_set_key IDENTIFIER KEY — a token keeps its identity, takes a new key
    ak_api POST "/core/tokens/$1/set_key/" "$(jq -cn --arg k "$2" '{key: $k}')" >/dev/null
}
ak_me_code() { rotate_http_code "$(authentik_url)/api/v3/core/users/me/" "Authorization: Bearer $1"; }   # ak_me_code TOKEN

authentik_rotate_api_token() { # the script's own token (authentik-bootstrap-token); the bootstrap blueprint only creates it, never puts the old key back
    local old new
    old=$(env_get AUTHENTIK_API_TOKEN); new=$(gen_secret 64)
    rotate_journal_hold AUTHENTIK_API_TOKEN "$old" "$new"
    ak_token_set_key authentik-bootstrap-token "$new" \
        || { fail "authentik: refused a new key for its API token — unchanged"; rotate_journal_release; return 1; }
    env_set AUTHENTIK_API_TOKEN "$new"
    rotate_proven authentik "$(authentik_url)/api/v3/core/users/me/" "Authorization: Bearer $new" "Authorization: Bearer $old" || return 2
    rotate_journal_release
}

authentik_rotate_admin() { # akadmin's password, through authentik's API: its answer is the proof (no sign-in flow is driven here)
    local old new
    old=$(env_get AUTHENTIK_ADMIN_PASSWORD); new=$(gen_secret 24)
    rotate_journal_hold AUTHENTIK_ADMIN_PASSWORD "$old" "$new"
    authentik_admin_rotate "$new" >/dev/null || { fail "authentik: akadmin's password unchanged"; rotate_journal_release; return 1; }
    ok "authentik: akadmin has its new password (authentik took it)"
    rotate_journal_release
}

authentik_rotate_ldap_token() { # the LDAP outpost's token: a new key on the same token, the outpost restarted with it
    local old new out pk _
    old=$(env_get AUTHENTIK_LDAP_TOKEN); new=$(gen_secret 64)
    out=$(ak_api GET "/outposts/instances/?name__iexact=mediastack-ldap") || { fail "authentik: its outposts are unreadable"; return 1; }
    pk=$(jq -r '.results[0].pk // empty' <<<"$out")
    [[ -n "$pk" ]] || { fail "authentik: the LDAP outpost (mediastack-ldap) is missing"; return 1; }
    rotate_journal_hold AUTHENTIK_LDAP_TOKEN "$old" "$new"
    ak_token_set_key "ak-outpost-$pk-api" "$new" \
        || { fail "authentik: refused a new key for the LDAP outpost's token — unchanged"; rotate_journal_release; return 1; }
    env_set AUTHENTIK_LDAP_TOKEN "$new"
    # shellcheck disable=SC2034  # the render cache lives in the entrypoint (read by DC's callers)
    RENDERED_JSON=""
    DC up -d --no-deps authentik-ldap >/dev/null 2>&1 || { fail "authentik: the LDAP outpost did not start again — ./mediastack.sh logs authentik-ldap"; return 2; }
    for _ in $(seq 1 30); do [[ "$(c_health "$(svc_cname authentik-ldap)")" == healthy ]] && break; sleep 2; done
    [[ "$(c_health "$(svc_cname authentik-ldap)")" == healthy ]] || { fail "authentik: the LDAP outpost is not healthy on its new token"; return 2; }
    rotate_proven "authentik's LDAP outpost token" "$(authentik_url)/api/v3/core/users/me/" "Authorization: Bearer $new" "Authorization: Bearer $old" || return 2
    rotate_journal_release
}

ak_db_password_set() { # ak_db_password_set PASSWORD — the database role's password (SQL on stdin: never in a process list)
    printf "ALTER ROLE authentik WITH PASSWORD '%s';\n" "$1" \
        | sudo docker exec -i "$(svc_cname authentik-db)" psql -q -v ON_ERROR_STOP=1 -U authentik -d authentik >/dev/null 2>&1
}
ak_db_password_opens() { # ak_db_password_opens PASSWORD — a fresh connection that has to give a password takes it
    # Through the stack network, never loopback: the image trusts 127.0.0.1 and
    # ::1 (and its socket) without asking, so a check there takes any password
    # (found live: "still takes the other password" both ways). Its container
    # name resolves (Docker's DNS) to its stack-network address: `host all all
    # all scram-sha-256`. Not svc_host: that names an address wire writes.
    local cn; cn=$(svc_cname authentik-db)
    printf '%s\n' "$1" | sudo docker exec -i "$cn" \
        sh -c 'read -r p; PGPASSWORD=$p psql -h "$0" -U authentik -d authentik -tAc "select 1"' "$cn" 2>/dev/null \
        | grep -x 1 >/dev/null
}
ak_env_holds() { # ak_env_holds SERVICE KEY VALUE — the running container was started with KEY=VALUE
    sudo docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$(svc_cname "$1")" 2>/dev/null | grep -Fx -- "$2=$3" >/dev/null
}

authentik_settings_proven() { # authentik_settings_proven DB-PASSWORD OTHER-DB-PASSWORD SECRET-KEY — authentik runs on these, applied
    local _
    ak_db_password_opens "$1" || { fail "authentik: its database refuses the password it should take"; return 1; }
    ! ak_db_password_opens "$2" || { fail "authentik: its database still takes the other password"; return 1; }
    ak_env_holds authentik AUTHENTIK_SECRET_KEY "$3" && ak_env_holds authentik-worker AUTHENTIK_SECRET_KEY "$3" \
        || { fail "authentik: its server and worker do not both run on the signing key they should"; return 1; }
    for _ in $(seq 1 30); do [[ "$(rotate_http_code "$(authentik_url)/-/health/ready/" "X-Probe: 1")" =~ ^2 ]] && break; sleep 2; done
    MAINT_LOCKED=1 "$SCRIPT_DIR/mediastack.sh" wire authentik >/dev/null 2>&1 \
        || { fail "authentik: wire authentik failed on its settings — see: ./mediastack.sh wire authentik"; return 1; }
    local rc=0; authentik_blueprint_inputs_changed >/dev/null || rc=$?
    (( rc == 1 )) || { fail "authentik: its portal setup was not applied with the worker's values"; return 1; }
    ok "authentik: runs on its settings — the database, the signing key, the setup applied with them"
}

authentik_rotate_settings() { # its own settings, together: the database role first, then .env, one up, wire authentik applies the rest
    local e k hold=() db_old db_new sk_new
    declare -A old new
    for e in "${AUTHENTIK_ROTATE_SETTINGS[@]}"; do
        k=${e%%:*}; old[$k]=$(env_get "$k"); new[$k]=$(gen_secret "${e#*:}")
        hold+=("$k" "${old[$k]}" "${new[$k]}")
    done
    db_old=${old[AUTHENTIK_DB_PASSWORD]}; db_new=${new[AUTHENTIK_DB_PASSWORD]}; sk_new=${new[AUTHENTIK_SECRET_KEY]}
    rotate_journal_hold "${hold[@]}"
    # the role's password first: open connections keep working, every new one needs it
    ak_db_password_set "$db_new" || { fail "authentik: its database refused the new password — nothing changed"; rotate_journal_release; return 1; }
    for k in "${!new[@]}"; do env_set "$k" "${new[$k]}"; done
    if rotate_up && authentik_settings_proven "$db_new" "$db_old" "$sk_new"; then rotate_journal_release; return 0; fi
    fail "authentik: its new settings are not proven — putting the old ones back"
    ak_db_password_set "$db_old" || { fail "authentik: its database refused the old password back"; return 2; }
    for k in "${!old[@]}"; do env_set "$k" "${old[$k]}"; done
    if rotate_up && authentik_settings_proven "$db_old" "$db_new" "${old[AUTHENTIK_SECRET_KEY]}"; then rotate_journal_release; return 1; fi
    fail "authentik: its old settings are not proven either"; return 2
}

# ---- the run's last step: every session ----
portal_sessions_secrets() { svc_enabled authentik && printf 'every portal session\tsignout\n'; return 0; }
portal_sessions_secret_rotate() { # deleted through authentik's own logout path: the gates' sessions end with them (its outposts are told)
    local out ids id n=0 left
    out=$(ak_api GET "/core/authenticated_sessions/?page_size=1000") || { fail "authentik: its sessions are unreadable"; return 1; }
    ids=$(jq -r '.results[]?.uuid' <<<"$out")
    for id in $ids; do
        ak_api DELETE "/core/authenticated_sessions/$id/" >/dev/null || { fail "authentik: a session was not ended ($id)"; return 1; }
        n=$((n + 1))
    done
    out=$(ak_api GET "/core/authenticated_sessions/?page_size=1000") || { fail "authentik: its sessions are unreadable"; return 1; }
    left=$(jq -r --arg ids "$ids" '[.results[]?.uuid | select(. as $u | ($ids | split("\n") | index($u)))] | length' <<<"$out")
    [[ "$left" == 0 ]] || { fail "authentik: $left of the sessions it ended are still there"; return 1; }
    ok "authentik: $n session(s) ended — the gates' with them"
}
