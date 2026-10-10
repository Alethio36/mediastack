#!/usr/bin/env bash
# services/authentik/authentik.sh — the authentik shard: its upkeep (secrets,
# its first admin, its upgrade path, blueprints, doctor's account checks) and
# the `wire authentik` role (the gate, identity rules, the LDAP outpost's
# token, the dashboard cards). The portal's email is email.sh beside it.
# Sourced by the entrypoint; relies on lib/common.sh, lib/wire.sh and the
# render/svc/c_* helpers at call time.
#
# The upgrade path is strict (authentik's upgrade docs): releases are taken in
# order — never skip one — and never go back (a downgrade needs the database
# restored, which is what `rollback authentik` does). The release the database
# is at is written beside it (CONFIG_ROOT/authentik/.mediastack-release), so a
# restore point brings the right mark back with the data it describes.

# every release mediastack has shipped for authentik, oldest first — a new one
# is appended when the fragment's tag moves, so an install that fell behind
# walks them one at a time
AUTHENTIK_RELEASES=(2026.2 2026.5 2026.8)
AUTHENTIK_MARK=.mediastack-release

authentik_secret() { # authentik_secret N -> N letters and digits from /dev/urandom
    local s=""
    while (( ${#s} < $1 )); do s+=$(head -c 64 /dev/urandom | base64 -w0 | tr -dc 'A-Za-z0-9'); done
    echo "${s:0:$1}"
}

authentik_dir() { echo "$(env_get CONFIG_ROOT)/authentik"; }

authentik_has_db() { sudo test -e "$(authentik_dir)/db/pgdata/PG_VERSION"; }

authentik_secrets() { # generate what is missing — never over a database that already exists
    local k n made=0
    for k in AUTHENTIK_SECRET_KEY:60 AUTHENTIK_DB_PASSWORD:32 AUTHENTIK_ADMIN_PASSWORD:24 AUTHENTIK_API_TOKEN:64; do
        n=${k#*:}; k=${k%%:*}
        [[ -n "$(env_get "$k")" ]] && continue
        # the database was created with these: a new one would lock the shard
        # out of its own data (or, for the key, invalidate every session)
        authentik_has_db && die "authentik's database exists but $k is missing from .env.
  Put it back from a .env backup (local/env-backups/) or a restore point's env file;
  a new value cannot open the existing database."
        env_set "$k" "$(authentik_secret "$n")"; made=1
    done
    # the LDAP search account's password: the blueprint sets it on every apply,
    # so a new one is simply adopted — no database guard needed
    local k2
    for k2 in AUTHENTIK_LDAP_BIND_PASSWORD AUTHENTIK_ABS_CLIENT_SECRET AUTHENTIK_KAVITA_CLIENT_SECRET; do
        [[ -n "$(env_get "$k2")" ]] || { env_set "$k2" "$(authentik_secret 48)"; made=1; }
    done
    (( made )) && ok "authentik: secrets generated (the admin login: ./mediastack.sh credentials)"
    return 0
}

authentik_release_of() { # authentik_release_of IMAGE-OR-VERSION -> YYYY.N (its release, without the patch)
    local v=${1##*:}
    [[ "$v" =~ ^([0-9]{4}\.[0-9]+) ]] || return 1
    echo "${BASH_REMATCH[1]}"
}

authentik_step() { # authentik_step FROM TO -> ok | <why not>, against AUTHENTIK_RELEASES
    local from="$1" to="$2" i f=-1 t=-1
    for i in "${!AUTHENTIK_RELEASES[@]}"; do
        [[ "${AUTHENTIK_RELEASES[$i]}" == "$from" ]] && f=$i
        [[ "${AUTHENTIK_RELEASES[$i]}" == "$to" ]] && t=$i
    done
    (( t >= 0 )) || { echo "$to is not an authentik release this version of mediastack knows (${AUTHENTIK_RELEASES[*]})"; return 0; }
    [[ -z "$from" ]] && { echo ok; return 0; }   # a new database: any known release
    (( f >= 0 )) || { echo "the database is at $from, which this version of mediastack does not know"; return 0; }
    if (( t < f )); then echo "authentik cannot go back from $from to $to — restore the database instead: ./mediastack.sh rollback authentik"
    elif (( t > f + 1 )); then echo "authentik must not skip releases: $from -> ${AUTHENTIK_RELEASES[$((f + 1))]} first: ./mediastack.sh update authentik --to ${AUTHENTIK_RELEASES[$((f + 1))]}"
    else echo ok; fi
}

authentik_release_check() { # before anything starts authentik: the step from its database's release to the target is allowed
    local target from why
    target=$(authentik_release_of "$(svc_image authentik)") || die "authentik: cannot read a release from its image '$(svc_image authentik)'"
    from=$(sudo cat "$(authentik_dir)/$AUTHENTIK_MARK" 2>/dev/null || true)   # no mark: a new database
    why=$(authentik_step "$from" "$target")
    [[ "$why" == ok ]] || die "authentik: $why
  Nothing was started."
}

authentik_release_record() { # once authentik is healthy on a release, its database is at that release
    local cn v r
    cn=$(svc_cname authentik)
    [[ "$(c_health "$cn")" == healthy ]] || return 0   # not (yet) healthy: the mark stays where it was
    v=$(c_version "$cn"); r=$(authentik_release_of "$v") || return 0
    [[ "$(sudo cat "$(authentik_dir)/$AUTHENTIK_MARK" 2>/dev/null || true)" == "$r" ]] && return 0   # unchanged
    printf '%s\n' "$r" | sudo tee "$(authentik_dir)/$AUTHENTIK_MARK" >/dev/null
    sudo chown "$(env_get AUTHENTIK_UID):mediacenter" "$(authentik_dir)/$AUTHENTIK_MARK"
}

AUTHENTIK_BLUEPRINT="Mediastack - Portal"   # metadata.name in services/authentik/blueprints/mediastack-portal.yaml
AUTHENTIK_JOIN_FLOW=mediastack-join          # its sign-up flow's slug (the invitation links)

authentik_portal() { echo "https://$(env_get AUTHENTIK_HOST portal).$(env_get TRAEFIK_DOMAIN)"; }   # where people go
authentik_url()    { echo "http://127.0.0.1:$(svc_hostport authentik)"; }                             # where the script goes

ak_api() { # ak_api METHOD PATH [json] -> body on stdout; rc from HTTP (authentik's API, as the script's token)
    local m="$1" p="$2" b="${3:-}" out code
    out=$(curl -sS -m 20 -X "$m" -H "Authorization: Bearer $(env_get AUTHENTIK_API_TOKEN)" \
          -H "Content-Type: application/json" ${b:+-d "$b"} -w '\n%{http_code}' "$(authentik_url)/api/v3$p" 2>&1) \
        || { echo "$out"; return 1; }
    code=${out##*$'\n'}; echo "${out%$'\n'*}"
    [[ "$code" =~ ^2 ]]
}

authentik_blueprints_sync() { # the worker applies what is in CONFIG_ROOT/authentik/blueprints: keep it the repo's
    local dst uid f n
    dst="$(authentik_dir)/blueprints"; uid=$(env_get AUTHENTIK_UID)
    sudo install -d -o "$uid" -g mediacenter -m 755 "$dst"
    for f in "$SCRIPT_DIR"/services/authentik/blueprints/*.yaml; do
        sudo cmp -s "$f" "$dst/${f##*/}" || { sudo install -o "$uid" -g mediacenter -m 644 "$f" "$dst/${f##*/}"; n=1; }
    done
    # a blueprint mediastack no longer ships leaves with it (the folder is ours alone)
    for f in $(sudo find "$dst" -maxdepth 1 -name '*.yaml' -printf '%f\n'); do
        [[ -e "$SCRIPT_DIR/services/authentik/blueprints/$f" ]] || { sudo rm -f "$dst/$f"; n=1; }
    done
    [[ -n "${n:-}" ]] && info "authentik: portal setup files updated — its worker applies them on change (check: ./mediastack.sh wire authentik)"
    return 0
}

gate_bind_sync() { # MEDIASTACK_GATE_BIND: where a gated tool's host port listens — 127.0.0.1 while the portal guards it (addr-ok: host bind, not app-to-app)
    # MEDIASTACK_GATE_TRUST: who may name the user to an app that trusts a
    # header (Navidrome) — Traefik's fixed address while the portal runs, nobody otherwise
    local trust=""
    svc_enabled authentik && trust="$(env_get TRAEFIK_ADDRESS 172.31.250.2)/32"
    [[ "$(env_get MEDIASTACK_GATE_TRUST)" == "$trust" ]] || env_set MEDIASTACK_GATE_TRUST "$trust"
    local want=""
    svc_enabled authentik && want="127.0.0.1:"   # addr-ok: host bind, not app-to-app
    [[ "$(env_get MEDIASTACK_GATE_BIND)" == "$want" ]] && return 0
    env_set MEDIASTACK_GATE_BIND "$want"
    if [[ -n "$want" ]]; then info "gated tools' host ports now listen on 127.0.0.1 only — reach them through the portal"   # addr-ok: host bind, not app-to-app
    else info "gated tools' host ports reopen to the LAN (no portal to guard them)"; fi
}

svc_bound_local() { # svc_bound_local <svc> -> 0 when nothing publishes its port beyond 127.0.0.1 (checked on the live container) (addr-ok: host bind, not app-to-app)
    local pub cport lines
    pub=$(svc_host "$1"); cport=$(svc_cport "$1")
    [[ -n "$cport" ]] || return 0
    lines=$(sudo docker port "$(svc_cname "$pub")" "$cport/tcp" 2>/dev/null || true)   # soft read: nothing published is local
    [[ -z "$lines" ]] && return 0
    ! grep -qv '^127\.0\.0\.1:' <<<"$lines"
}

gate_trusted() { # gate_trusted <svc> -> 0 when <svc> may drop its own login: the portal runs, it is gated, and it is unreachable by IP
    svc_enabled authentik && [[ "$(svc_label "$1" mediastack.auth)" == gate ]] && svc_bound_local "$1"
}

authentik_prepare() { # before `up`/`enable` start it: the edge, secrets, the release step, its setup files
    svc_enabled authentik || return 0
    # the API is published on 127.0.0.1 only: people reach the portal through Traefik
    svc_enabled traefik && [[ -n "$(env_get TRAEFIK_DOMAIN)" ]] \
        || die "authentik (the portal) is reached at https://portal.<your domain>, through Traefik — enable and set it up first:
  ./mediastack.sh enable traefik   (then: ./mediastack.sh traefik-setup)"
    authentik_secrets
    authentik_release_check
    authentik_blueprints_sync
}

authentik_blueprint_instance() { # -> the blueprint's instance JSON ("" when authentik has not discovered it yet)
    local out
    out=$(ak_api GET "/managed/blueprints/?page_size=200") || { echo "unreadable ($(head -c120 <<<"$out"))" >&2; return 1; }
    jq -c --arg n "$AUTHENTIK_BLUEPRINT" '[.results[] | select(.name == $n)][0] // empty' <<<"$out"
}

authentik_blueprint_status() { # -> successful | warning | error | … | outdated | "" (not discovered) | "unreadable (…)"
    # "successful" describes the file authentik last applied — the current one
    # only when its hash (sha512 of the file) matches ours. Found live: right
    # after an update the status still spoke for the previous version.
    local inst mine
    inst=$(authentik_blueprint_instance 2>&1) || { echo "$inst"; return 0; }
    [[ -n "$inst" ]] || { echo ""; return 0; }
    mine=$(sha512sum "$SCRIPT_DIR/services/authentik/blueprints/mediastack-portal.yaml" | cut -d' ' -f1)
    if [[ "$(jq -r '.last_applied_hash // ""' <<<"$inst")" != "$mine" ]]; then
        # a failed apply keeps the previous version's hash: its status says it failed
        [[ "$(jq -r '.status' <<<"$inst")" == error ]] && { echo error; return 0; }
        echo outdated; return 0
    fi
    jq -r '.status' <<<"$inst"
}

AUTHENTIK_DISCOVER_WAIT=300   # seconds: how long a first start may take to discover the blueprint
authentik_blueprint_discovered() { # wait for authentik to discover the blueprint; -> its status ("" if it never does)
    local st waited=0
    while :; do
        st=$(authentik_blueprint_status)
        [[ -n "$st" ]] && { echo "$st"; return 0; }
        (( waited >= AUTHENTIK_DISCOVER_WAIT )) && { echo ""; return 0; }
        sleep 5; waited=$((waited + 5))
    done
}

authentik_blueprint_why() { # authentik's own reasons for rejecting mediastack's blueprint (its validator, dry run — nothing applied)
    # its logs and task records keep no reasons; this command states them
    sudo docker exec "$(svc_cname authentik-worker)" ak apply_blueprint --dry-run mediastack/mediastack-portal.yaml 2>&1 \
        | grep -E 'Entry invalid|Error|exception|Traceback|invalid' | grep -v 'Imported related module' \
        | sed -E 's/^[[:space:]]+//; s/\{.entry.: .*//' | cut -c1-400 | tail -5
}

authentik_blueprint_apply() { # apply the current file now instead of waiting for the worker; -> its status
    local inst pk st t
    inst=$(authentik_blueprint_instance 2>&1) || { echo "$inst"; return 0; }
    pk=$(jq -r '.pk // empty' <<<"$inst"); [[ -n "$pk" ]] || { echo ""; return 0; }
    ak_api POST "/managed/blueprints/$pk/apply/" >/dev/null || { echo "unreadable (apply refused)"; return 0; }
    local was; was=$(jq -r '.last_applied // ""' <<<"$inst")
    for t in $(seq 1 90); do   # the apply may be queued behind other tasks: up to three minutes (found live: one was not enough)
        st=$(authentik_blueprint_status)
        # "error" counts only once authentik has tried again since we asked
        if [[ "$st" == error ]]; then
            [[ "$(authentik_blueprint_instance 2>/dev/null | jq -r '.last_applied // ""')" != "$was" ]] && { echo error; return 0; }
        elif [[ "$st" != outdated ]]; then echo "$st"; return 0; fi
        sleep 2
    done
    echo outdated
}

authentik_gate_attached() { # -> 0 when the gate's provider sits on the built-in outpost
    local prov out
    prov=$(ak_api GET "/providers/proxy/?name__iexact=mediastack-gate") || return 1
    prov=$(jq -r '.results[0].pk // empty' <<<"$prov"); [[ -n "$prov" ]] || return 1
    out=$(ak_api GET "/outposts/instances/?managed__iexact=goauthentik.io/outposts/embedded") || return 1
    jq -e --argjson p "$prov" '.results[0].providers | index($p) != null' <<<"$out" >/dev/null
}

authentik_gated() { # the enabled admin tools behind the gate (mediastack.auth: gate, no household group)
    local s
    for s in $(svc_enabled_managed); do
        [[ "$(svc_label "$s" mediastack.auth)" == gate && -z "$(svc_label "$s" mediastack.auth.group)" ]] && echo "$s"
    done
    return 0
}

authentik_household() { # the enabled household apps (mediastack.user_facing) — each gets a card for media-users
    local s
    for s in $(svc_enabled_managed); do
        [[ "$(svc_label "$s" mediastack.user_facing)" == true ]] && echo "$s"
    done
    return 0
}

authentik_oidc_issuer() { # authentik_oidc_issuer SVC -> the issuer of its household card's OIDC provider
    echo "$(authentik_portal)/application/o/mediastack-app-$1/"
}

authentik_invite() { # authentik_invite DAYS -> a single-use sign-up link, printed
    local days="$1" flow name exp out pk
    [[ "$(c_health "$(svc_cname authentik)")" == healthy ]] || die "authentik is not healthy yet — ./mediastack.sh status authentik"
    out=$(ak_api GET "/flows/instances/?slug=$AUTHENTIK_JOIN_FLOW") \
        || die "authentik's API refused the sign-up flow lookup: $(head -c200 <<<"$out")"
    flow=$(jq -r '.results[0].pk // empty' <<<"$out")
    [[ -n "$flow" ]] || die "authentik has no sign-up flow yet ($AUTHENTIK_JOIN_FLOW) — it applies mediastack's setup shortly after starting; check: ./mediastack.sh wire authentik"
    name="invite-$(date +%Y%m%d-%H%M%S)"
    exp=$(date -u -d "+$days days" +%Y-%m-%dT%H:%M:%SZ)
    out=$(ak_api POST /stages/invitation/invitations/ \
          "$(jq -cn --arg n "$name" --arg e "$exp" --arg f "$flow" '{name:$n, expires:$e, single_use:true, flow:$f}')") \
        || die "authentik refused the invitation: $(head -c200 <<<"$out")"
    pk=$(jq -r '.pk // empty' <<<"$out"); [[ -n "$pk" ]] || die "authentik answered without an invitation id: $(head -c200 <<<"$out")"
    ok "Invitation created — single use, expires in $days day(s) ($(date -d "$exp" '+%Y-%m-%d %H:%M'))"
    echo "$(authentik_portal)/if/flow/$AUTHENTIK_JOIN_FLOW/?itoken=$pk"
}

authentik_admin_rotate() { # authentik_admin_rotate NEW-PASSWORD — akadmin's password, then .env; rc 1 after printing why
    # AUTHENTIK_ADMIN_PASSWORD is read by authentik only at its first start:
    # after that the password lives in its database, set here through its API.
    local new="$1" out pk
    out=$(ak_api GET "/core/users/?username=akadmin") || { fail "authentik refused the akadmin lookup: $(oneline "$out")"; return 1; }
    pk=$(jq -r '.results[0].pk // empty' <<<"$out")
    [[ -n "$pk" ]] || { fail "authentik has no akadmin account"; return 1; }
    out=$(ak_api POST "/core/users/$pk/set_password/" "$(jq -cn --arg p "$new" '{password:$p}')") \
        || { fail "authentik refused the new password: $(oneline "$out")"; return 1; }
    env_set AUTHENTIK_ADMIN_PASSWORD "$new"
}

ak_cmd_why() { # ak_cmd_why OUTPUT -> the last line of an `ak` command that isn't its own log (where the error is)
    grep -v '^{"event"' <<<"$1" | grep -v '^[[:space:]]*$' | tail -1
}

authentik_recover() { # authentik_recover USER — clear their login throttle, print a single-use sign-in link
    local user="$1" enc out u pk n=0 path
    case "$user" in
        akadmin) die "akadmin's password is the stack's own — set a new one with: ./mediastack.sh set-credentials portal" ;;
        mediastack-ldap-search) die "mediastack-ldap-search is the stack's LDAP search account, not a person's — its password comes from .env through the blueprint" ;;
    esac
    enc=$(jq -rn --arg u "$user" '$u|@uri')
    out=$(ak_api GET "/core/users/?username=$enc") || die "authentik refused the user lookup: $(oneline "$out")"
    u=$(jq -c '.results[0] // empty' <<<"$out")
    [[ -n "$u" ]] || die "no portal account named '$user' (exact, case-sensitive) — the list: $(authentik_portal)/if/admin/#/identity/users"
    [[ "$(jq -r '.type' <<<"$u")" == internal ]] || die "'$user' is a $(jq -r '.type' <<<"$u") account, not a person's — nothing to reset"
    [[ "$(jq -r '.is_active' <<<"$u")" == true ]] || die "'$user' is deactivated — that is deliberate, not a lockout. To let them back in, activate it first: $(authentik_portal)/if/admin/#/identity/users"
    # failed sign-ins lower a reputation score that locks the LDAP path (Jellyfin) out
    out=$(ak_api GET "/policies/reputation/scores/?identifier=$enc&page_size=100") || die "authentik refused the login-throttle lookup: $(oneline "$out")"
    for pk in $(jq -r '.results[].pk' <<<"$out"); do
        ak_api DELETE "/policies/reputation/scores/$pk/" >/dev/null || die "authentik refused to clear a login-throttle entry for '$user'"
        n=$((n+1))
    done
    (( n )) && ok "cleared $n login-throttle entr$( ((n==1)) && echo y || echo ies) for '$user'" || info "'$user' had no login throttle to clear"
    # USER: the worker runs as mediastack's UID, which has no passwd entry, and
    # the command names who made the link (getpass: "No username set", found live)
    out=$(sudo docker exec -e USER=mediastack "$(svc_cname authentik-worker)" ak create_recovery_key 1440 "$user" 2>&1) \
        || die "authentik could not make a sign-in link: $(ak_cmd_why "$out")"
    path=$(grep -o '/recovery/use-token/[^[:space:]]*' <<<"$out" | tail -1)
    [[ -n "$path" ]] || die "authentik answered without a sign-in link: $(ak_cmd_why "$out")"
    hr "Sign-in link for $user"
    echo "  $(authentik_portal)$path"
    echo "  Works once, for 24 hours — send it to $user only: whoever opens it is signed in as them."
    echo "  Then, in the portal: Settings → Change password. The new password works in every app."
}

authentik_email_dupes() { # -> one line per email two or more people's accounts share: "email: user user…"
    local out
    out=$(ak_api GET "/core/users/?page_size=1000") || return 1
    jq -r '[.results[] | select(.type == "internal" and (.email // "") != "") | {e: (.email | ascii_downcase), u: .username}]
        | group_by(.e) | map(select(length > 1)) | .[] | "\(.[0].e): \(map(.u) | join(" "))"' <<<"$out"
}

authentik_set_email() { # authentik_set_email USER ADDRESS YES — an admin changes a person's email; apps that match by it follow
    local user=$1 email=$2 yes=$3 enc out u pk old others
    [[ "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "'$email' is not an email address"
    enc=$(jq -rn --arg u "$user" '$u|@uri')
    out=$(ak_api GET "/core/users/?username=$enc") || die "authentik refused the user lookup: $(oneline "$out")"
    u=$(jq -c '.results[0] // empty' <<<"$out")
    [[ -n "$u" ]] || die "no portal account named '$user' (exact, case-sensitive) — the list: $(authentik_portal)/if/admin/#/identity/users"
    [[ "$(jq -r '.type' <<<"$u")" == internal ]] || die "'$user' is a $(jq -r '.type' <<<"$u") account, not a person's"
    pk=$(jq -r '.pk' <<<"$u"); old=$(jq -r '.email // ""' <<<"$u")
    [[ "${old,,}" == "${email,,}" ]] && { ok "$user already has $email"; return 0; }
    out=$(ak_api GET "/core/users/?page_size=1000") || die "authentik refused the user list: $(oneline "$out")"
    others=$(jq -r --arg e "${email,,}" --argjson pk "$pk" '[.results[] | select(.pk != $pk and ((.email // "") | ascii_downcase) == $e) | .username] | join(" ")' <<<"$out")
    if [[ -n "$others" ]]; then
        warn "$email is already the email of: $others — each person's email should be their own."
        if (( ! yes )); then
            [[ -t 0 ]] || die "a shared email needs a decision — run it in a terminal, or add --yes"
            confirm "Use it anyway?" || { info "Nothing changed."; return 0; }
        fi
    fi
    out=$(ak_api PATCH "/core/users/$pk/" "$(jq -cn --arg e "$email" '{email:$e}')") || die "authentik rejected the new email: $(oneline "$out")"
    [[ "$(jq -r '.email' <<<"$out")" == "$email" ]] || die "authentik answered, but $user's email did not change"
    ok "portal: $user's email is now $email${old:+ (was $old)}"
    # the apps that find people by email must find the same account under the new one
    if [[ -n "$old" ]] && svc_enabled kavita; then
        [[ -n "$(env_get KAVITA_ADMIN_PASSWORD)" ]] || { warn "kavita: no stored admin login — change $user's email there by hand (Users → $user), or their next sign-in starts a new account"; return 0; }
        kav_email_move "$old" "$email" || warn "kavita still has $old for $user — change it there by hand (Users → $user), or their next sign-in starts a new, empty account"
    fi
}

# ------------------------------------------------------------------ doctor --
_doctor_accounts() { # the account model: one of the services that conflict, and authentik's release mark
    hr "doctor: accounts"
    local np; np=$(network_problems)
    [[ -z "$np" ]] || d_fail "the stack network's addressing: $np" "Traefik's fixed address would clash or fall outside the network" "fix MEDIASTACK_SUBNET / MEDIASTACK_IP_RANGE / TRAEFIK_ADDRESS in .env, then: ./mediastack.sh up"
    local s c seen=""
    for s in $(svc_enabled_managed); do
        for c in $(svc_conflicts "$s"); do
            [[ " $seen " == *" $c "* ]] && continue
            svc_enabled "$c" && d_fail "'$s' and '$c' are both enabled" "they do the same job two ways; users end up in two places" \
                "keep one: ./mediastack.sh disable $c   (or disable $s)"
        done
        seen+=" $s"
    done
    if svc_enabled authentik; then
        authentik_release_record
        local mark run
        mark=$(sudo cat "$(authentik_dir)/$AUTHENTIK_MARK" 2>/dev/null || true)
        run=$(authentik_release_of "$(c_version "$(svc_cname authentik)")" 2>/dev/null || true)
        if [[ -z "$mark" ]]; then
            warn "authentik has not been healthy yet, so its release is not recorded — updates check the next step against it (check again once it is healthy)"
        elif [[ -n "$run" && "$run" != "$mark" ]]; then
            warn "authentik runs $run but its database is recorded at $mark — it is not healthy on $run yet"
        else
            ok "authentik on release $mark (the next update may only step to the release after it)"
        fi
        if [[ "$(c_health "$(svc_cname authentik)")" == healthy ]]; then
            local st; st=$(authentik_blueprint_status)
            case "$st" in
                successful) ok "authentik: mediastack's portal setup applied (groups, sign-up by invitation)" ;;
                "") warn "authentik has not applied mediastack's portal setup yet (it does within minutes of starting): ./mediastack.sh wire authentik" ;;
                outdated) warn "authentik runs an earlier version of mediastack's portal setup — apply the current one: ./mediastack.sh wire authentik" ;;
                *) d_fail "authentik rejected mediastack's portal setup ($st): $(authentik_blueprint_why | tr '\n' ' ')" \
                       "groups, sign-up and LDAP may be missing or incomplete" "fix the entry named above in services/authentik/blueprints/, then: ./mediastack.sh up && ./mediastack.sh wire authentik" ;;
            esac
            local dup
            if dup=$(authentik_email_dupes); then
                [[ -z "$dup" ]] && ok "authentik: every person's email is their own" \
                    || d_fail "authentik: people share an email — $(tr '\n' ';' <<<"$dup" | sed 's/;$//')" \
                        "each person's email should be their own (apps that sign people in by email treat them as one)" \
                        "give each their own: ./mediastack.sh set-email <user> <address>"
            else warn "authentik: its users are unreadable — emails not checked"; fi
            if smtp_configured; then
                local sp; sp=$(smtp_problems)
                if [[ -n "$sp" ]]; then d_fail "email: $(tr '\n' ';' <<<"$sp" | sed 's/;$//')" "the portal cannot send email" "./mediastack.sh configure (docs/email.md)"
                elif [[ -n "$(smtp_live_stale)" ]]; then warn "email: authentik still runs older email settings — ./mediastack.sh up"
                elif [[ "$(state_get SMTP_TESTED)" != "$(smtp_fingerprint)" ]]; then warn "email: these settings have not passed a test — ./mediastack.sh email test <your address>"
                else ok "email: $(env_get SMTP_HOST) — these settings passed a test"; fi
            fi
            local sset
            if sset=$(ak_api GET /admin/settings/); then
                jq -e '.default_user_change_email == false and .default_user_change_username == false' <<<"$sset" >/dev/null \
                    || d_fail "authentik lets people change their own email or username" \
                        "anyone could take another person's email, and with it their account in Kavita (and ROMM)" \
                        "./mediastack.sh wire authentik"
            fi
            if [[ -z "$(env_get AUTHENTIK_LDAP_TOKEN)" ]]; then
                warn "authentik's LDAP outpost has no token yet (it keeps restarting until it does): ./mediastack.sh wire authentik"
            fi
            local g open=""
            for g in $(authentik_gated); do svc_bound_local "$g" || open+="$g "; done
            [[ -z "$open" ]] || d_fail "gated tools reachable by IP, around the portal: $open" \
                "their host ports are not bound to 127.0.0.1 yet" "./mediastack.sh up"   # addr-ok: host bind, not app-to-app
            if [[ -n "$(authentik_gated)" ]]; then
                local hg=""; for g in $(authentik_household); do [[ -n "$(svc_label "$g" mediastack.auth.group)" ]] && hg+="$g "; done
                [[ -n "$hg" ]] && ok "authentik: household gate — ${hg}ask the portal first (media-users and admins)"
                if authentik_gate_attached; then ok "authentik: the gate is up — $(authentik_gated | tr '\n' ' ')ask the portal first (admins only)"
                else d_fail "authentik: the gate is not on its built-in outpost" "routes marked gate ($(authentik_gated | tr '\n' ' '| sed 's/ $//')) refuse everyone" "./mediastack.sh wire authentik"; fi
            fi
        fi
    elif svc_enabled wizarr; then
        info "accounts: Wizarr (each app keeps its own accounts)"
    fi
    return 0
}

wire_authentik() {
    hr "wire: authentik"
    svc_enabled authentik || { info "authentik not enabled — skipped"; return 0; }
    wire_gate authentik
    http_ready authentik "$(authentik_url)/-/health/ready/" '^2' || return 1
    # its base URL: the address in links it generates (invitations included).
    # Set when unset, or when it is still the one mediastack last wrote (a
    # renamed host); a URL you set in authentik's UI is left alone.
    local want cur mine
    want=$(authentik_portal); mine=$(state_get AUTHENTIK_BASE_URL)
    cur=$(ak_api GET /admin/settings/ | jq -r '.base_url // ""') \
        || { wfail "authentik: its settings are unreadable — is AUTHENTIK_API_TOKEN the one it started with?"; return 1; }
    if [[ "$cur" == "$want" ]]; then
        ok "authentik: base URL $want"
    elif [[ -n "$cur" && "$cur" != "$mine" ]]; then
        ok "authentik: base URL $cur was set in its UI — untouched"
    elif w_would "authentik: set its base URL to $want (the address in the links it generates)"; then
        if ak_api PATCH /admin/settings/ "$(jq -cn --arg u "$want" '{base_url:$u}')" >/dev/null; then
            state_set AUTHENTIK_BASE_URL "$want"; ok "authentik: base URL set"
        else wfail "authentik rejected the base URL $want"; fi
    fi
    local st; st=$(authentik_blueprint_status)
    # a first start: authentik discovers the blueprint on its own schedule, and
    # the gate, the cards and the LDAP token all need it — wait, don't skip
    if [[ -z "$st" ]] && ! (( WIRE_DRY )); then
        info "authentik: waiting for it to discover mediastack's portal setup (a first start; up to $((AUTHENTIK_DISCOVER_WAIT / 60)) minutes)"
        st=$(authentik_blueprint_discovered)
    fi
    local applied=0
    # why it is not current: never applied (a first start), a failed apply, or an older file
    local why="an earlier version is in place"
    [[ "$st" == error ]] && why="its last apply failed"
    [[ "$st" == outdated && -z "$(authentik_blueprint_instance 2>/dev/null | jq -r '.last_applied_hash // ""' 2>/dev/null)" ]] \
        && why="authentik has not applied it yet"
    if [[ "$st" == outdated || "$st" == error ]] && w_would "authentik: apply mediastack's current portal setup now ($why)"; then
        st=$(authentik_blueprint_apply); applied=1
    fi
    # the LDAP outpost caches bind results: a changed setup starts it afresh,
    # so an answer from before the change cannot outlive it (found live)
    if (( applied )) && [[ "$st" == successful && "$(c_state "$(svc_cname authentik-ldap)")" == running ]]; then
        sudo docker restart "$(svc_cname authentik-ldap)" >/dev/null && ok "authentik: LDAP outpost restarted on the new setup (its bind cache cleared)"
    fi
    case "$st" in
        successful) ok "authentik: mediastack's portal setup applied (media-users, admins, sign-up by invitation)" ;;
        "") if (( WIRE_DRY )); then info "authentik: mediastack's portal setup not discovered yet — the real run waits for it"
            else wfail "authentik: mediastack's portal setup was not discovered within $((AUTHENTIK_DISCOVER_WAIT / 60)) minutes — ./mediastack.sh logs authentik --no-follow | grep -i blueprint"; fi
            return 0 ;;
        outdated) wfail "authentik: an earlier version of mediastack's portal setup is still in place — ./mediastack.sh logs authentik --no-follow | grep -i blueprint"; return 0 ;;
        *) wfail "authentik rejected mediastack's portal setup ($st). Its validator says:"
           authentik_blueprint_why | sed 's/^/       /'
           return 0 ;;
    esac
    wire_authentik_identity
    wire_authentik_gate
}

wire_authentik_identity() { # people cannot change their own email or username: apps find their account by them
    local cur
    cur=$(ak_api GET /admin/settings/) || { wfail "authentik: its settings are unreadable"; return 1; }
    if jq -e '.default_user_change_email == false and .default_user_change_username == false' <<<"$cur" >/dev/null; then
        ok "authentik: people cannot change their own email or username (an admin can: ./mediastack.sh set-email)"
        return 0
    fi
    w_would "authentik: stop people changing their own email and username (the apps find their account by them)" || return 0
    ak_api PATCH /admin/settings/ '{"default_user_change_email":false,"default_user_change_username":false}' >/dev/null \
        && ok "authentik: people can no longer change their own email or username" \
        || wfail "authentik rejected the change to its self-service settings"
}

wire_authentik_gate() { # the gate on the built-in outpost, the first admin in `admins`, the dashboard cards
    # 1. the gate's provider on the built-in outpost — added to what is there, never replacing it
    local out prov
    out=$(ak_api GET "/providers/proxy/?name__iexact=mediastack-gate") || { wfail "authentik: gate provider unreadable"; return 0; }
    prov=$(jq -r '.results[0].pk // empty' <<<"$out")
    [[ -n "$prov" ]] || { wfail "authentik: the gate provider (mediastack-gate) is missing — the blueprint creates it: ./mediastack.sh logs authentik --no-follow | grep -i blueprint"; return 0; }
    if authentik_gate_attached; then ok "authentik: the gate is on its built-in outpost"
    else authentik_outpost_add "$prov" "the gate"; fi
    # 2. the first admin joins `admins` once — after that, membership is yours to manage
    if [[ -z "$(state_get AUTHENTIK_ADMINS_SEEDED)" ]] && w_would "authentik: put akadmin in 'admins' (the gate lets admins through)"; then
        local g u
        g=$(ak_api GET "/core/groups/?search=admins") && g=$(jq -r '[.results[] | select(.name == "admins") | .pk][0] // empty' <<<"$g")
        u=$(ak_api GET "/core/users/?username=akadmin") && u=$(jq -r '.results[0].pk // empty' <<<"$u")
        if [[ -n "$g" && -n "$u" ]] && ak_api POST "/core/groups/$g/add_user/" "$(jq -cn --argjson u "$u" '{pk:$u}')" >/dev/null; then
            state_set AUTHENTIK_ADMINS_SEEDED 1; ok "authentik: akadmin is in 'admins'"
        else wfail "authentik: could not add akadmin to 'admins'"; fi
    fi
    # 3. dashboard cards: admin tools (admins), household apps (media-users) — slugs mediastack-*: ours
    wire_authentik_cards
    # 4. the LDAP outpost's token: the outpost can only start with it
    wire_authentik_ldap_token
}

wire_authentik_ldap_token() { # fetch the mediastack-ldap outpost's token into .env; restart the outpost on a change
    local out pk key
    out=$(ak_api GET "/outposts/instances/?name__iexact=mediastack-ldap") || { wfail "authentik: outposts unreadable"; return 0; }
    pk=$(jq -r '.results[0].pk // empty' <<<"$out")
    [[ -n "$pk" ]] || { wfail "authentik: the LDAP outpost (mediastack-ldap) is missing — the blueprint creates it"; return 0; }
    out=$(ak_api GET "/core/tokens/ak-outpost-$pk-api/view_key/") || { wfail "authentik: the LDAP outpost's token is unreadable"; return 0; }
    key=$(jq -r '.key // empty' <<<"$out")
    [[ -n "$key" ]] || { wfail "authentik answered without the LDAP outpost's token"; return 0; }
    if [[ "$(env_get AUTHENTIK_LDAP_TOKEN)" == "$key" ]]; then ok "authentik: the LDAP outpost has its token"; return 0; fi
    w_would "authentik: give the LDAP outpost its token, then start it" || return 0
    env_set AUTHENTIK_LDAP_TOKEN "$key"
    # shellcheck disable=SC2034  # the render cache lives in the entrypoint (read by DC's callers)
    RENDERED_JSON=""
    DC up -d --no-deps authentik-ldap >/dev/null && ok "authentik: LDAP outpost started with its token" \
        || wfail "the LDAP outpost did not start: ./mediastack.sh logs authentik"
}

ak_group_pk() { # ak_group_pk NAME -> its pk (exact name, not a lookalike)
    local g; g=$(ak_api GET "/core/groups/?search=$1") || return 1
    jq -r --arg n "$1" '[.results[]? | select(.name == $n) | .pk][0] // empty' <<<"$g"
}

ak_flow_pk() { # ak_flow_pk SLUG -> its pk
    local f; f=$(ak_api GET "/flows/instances/?slug=$1") || return 1
    jq -r '.results[0].pk // empty' <<<"$f"
}

authentik_outpost_add() { # authentik_outpost_add PROVIDER-PK LABEL — beside what is on the built-in outpost, never replacing it
    local out outpost provs
    out=$(ak_api GET "/outposts/instances/?managed__iexact=goauthentik.io/outposts/embedded") || { wfail "authentik: built-in outpost unreadable"; return 1; }
    outpost=$(jq -r '.results[0].pk // empty' <<<"$out"); provs=$(jq -c '.results[0].providers // []' <<<"$out")
    [[ -n "$outpost" ]] || { wfail "authentik: its built-in outpost is missing"; return 1; }
    jq -e --argjson p "$1" 'index($p) != null' <<<"$provs" >/dev/null && return 0
    w_would "authentik: put $2 on its built-in outpost" || return 0
    ak_api PATCH "/outposts/instances/$outpost/" "$(jq -cn --argjson ps "$provs" --argjson p "$1" '{providers: ($ps + [$p])}')" >/dev/null \
        && ok "authentik: $2 attached" || { wfail "authentik refused to attach $2 to its outpost"; return 1; }
}

authentik_house_provider() { # authentik_house_provider SVC -> HOUSE_PK: its household gate (forward auth for its one address)
    # the pk comes back in HOUSE_PK (not stdout: a $(…) subshell would lose wire's failure count)
    HOUSE_PK=""
    local s="$1" name="mediastack-house-$1" url out pk az inv
    url=$(svc_url "$s")
    out=$(ak_api GET "/providers/proxy/?name__iexact=$name") || { wfail "authentik: providers unreadable"; return 1; }
    pk=$(jq -r '.results[0].pk // empty' <<<"$out")
    if [[ -z "$pk" ]]; then
        w_would "authentik: a household gate for $s ($url — media-users get through)" || return 1
        az=$(ak_flow_pk default-provider-authorization-implicit-consent); inv=$(ak_flow_pk default-provider-invalidation-flow)
        [[ -n "$az" && -n "$inv" ]] || { wfail "authentik: its default provider flows are missing"; return 1; }
        out=$(ak_api POST /providers/proxy/ "$(jq -cn --arg n "$name" --arg u "$url" --arg a "$az" --arg i "$inv" \
            '{name:$n, mode:"forward_single", external_host:$u, authorization_flow:$a, invalidation_flow:$i}')") \
            || { wfail "authentik refused $s's household gate: $(head -c160 <<<"$out")"; return 1; }
        pk=$(jq -r '.pk' <<<"$out")
    elif [[ "$(jq -r '.results[0].external_host' <<<"$out")" != "$url" ]]; then
        w_would "authentik: move $s's household gate to $url (its address changed)" || return 1
        ak_api PATCH "/providers/proxy/$pk/" "$(jq -cn --arg u "$url" '{external_host:$u}')" >/dev/null \
            || { wfail "authentik refused to update $s's household gate"; return 1; }
    fi
    authentik_outpost_add "$pk" "$s's household gate" || return 1
    HOUSE_PK=$pk
}

ak_card() { # ak_card ALL SLUG NAME URL DESC SECTION PROVIDER GROUP-PK... — a dashboard card only those groups see
    local all="$1" slug="$2" name="$3" url="$4" desc="$5" section="$6" prov="$7" have body app bind g
    shift 7
    body=$(jq -cn --arg n "$name" --arg sl "$slug" --arg u "$url" --arg d "$desc" --arg sec "$section" --arg p "$prov" \
        '{name:$n, slug:$sl, meta_launch_url:$u, meta_description:$d, meta_publisher:"mediastack", group:$sec,
          open_in_new_tab:true, policy_engine_mode:"any"} + (if $p != "" then {provider: ($p|tonumber)} else {} end)')
    have=$(jq -c --arg sl "$slug" '[.results[] | select(.slug == $sl)][0] // empty' <<<"$all")
    if [[ -z "$have" ]]; then
        w_would "authentik: add the $section card for $name" || return 0
        app=$(ak_api POST /core/applications/ "$body") || { wfail "authentik refused the card for $name: $(head -c160 <<<"$app")"; return 0; }
    elif [[ "$(jq -r '.meta_launch_url' <<<"$have")" != "$url" || "$(jq -r '.provider // "" | tostring' <<<"$have" | sed 's/^null$//')" != "$prov" ]]; then
        w_would "authentik: update $name's card" || return 0
        app=$(ak_api PATCH "/core/applications/$slug/" "$body") || { wfail "authentik refused to update $name's card"; return 0; }
    else
        app=$have
    fi
    bind=$(ak_api GET "/policies/bindings/?target=$(jq -r '.pk' <<<"$app")") || { wfail "authentik: bindings unreadable"; return 0; }
    for g in "$@"; do
        jq -e --arg g "$g" '.results[] | select(.group == $g)' <<<"$bind" >/dev/null && continue
        ak_api POST /policies/bindings/ "$(jq -cn --arg t "$(jq -r '.pk' <<<"$app")" --arg g "$g" '{target:$t, group:$g, order:0}')" >/dev/null \
            || { wfail "authentik: could not limit $name's card"; return 0; }
    done
    ok "authentik: $name card ($section)"
}

ak_card_prune() { # ak_card_prune ALL PREFIX WANTED... — cards mediastack made for services no longer wanted leave
    local all="$1" prefix="$2" slug; shift 2
    for slug in $(jq -r --arg p "$prefix" '.results[].slug | select(startswith($p))' <<<"$all"); do
        [[ " $* " == *" ${slug#"$prefix"} "* ]] && continue
        w_would "authentik: remove the card for ${slug#"$prefix"}" || continue
        ak_api DELETE "/core/applications/$slug/" >/dev/null && ok "authentik: ${slug#"$prefix"} card removed" \
            || wfail "authentik refused to remove ${slug#"$prefix"}'s card"
    done
}

wire_authentik_cards() { # admin tools for admins; household apps for media-users (and admins); ours only, by slug prefix
    local all adm mu s prov
    all=$(ak_api GET "/core/applications/?superuser_full_list=true&page_size=500") || { wfail "authentik: applications unreadable"; return 0; }
    adm=$(ak_group_pk admins); mu=$(ak_group_pk media-users)
    [[ -n "$adm" && -n "$mu" ]] || { wfail "authentik: groups 'admins'/'media-users' missing (the blueprint creates them)"; return 0; }
    for s in $(authentik_gated); do
        ak_card "$all" "mediastack-tool-$s" "$s" "$(svc_url "$s")" "$(svc_label "$s" mediastack.desc)" "Admin tools" "" "$adm"
    done
    for s in $(authentik_household); do
        prov=""
        # a household app behind the household gate: its card carries the gate's rule
        if [[ -n "$(svc_label "$s" mediastack.auth.group)" ]]; then authentik_house_provider "$s" || continue; prov=$HOUSE_PK
        else
            # an app that logs in through OIDC: its card is the provider's application
            local op; op=$(ak_api GET "/providers/oauth2/?client_id=mediastack-$s") || { wfail "authentik: providers unreadable"; continue; }
            prov=$(jq -r '.results[0].pk // empty' <<<"$op")
        fi
        ak_card "$all" "mediastack-app-$s" "$s" "$(svc_url "$s")" "$(svc_label "$s" mediastack.desc)" "Media" "$prov" "$mu" "$adm"
    done
    # shellcheck disable=SC2046  # service names, one word each
    ak_card_prune "$all" mediastack-tool- $(authentik_gated)
    # shellcheck disable=SC2046
    ak_card_prune "$all" mediastack-app- $(authentik_household)
    return 0
}

sc_rotate_portal() { # PASS — akadmin, through authentik's API
        svc_enabled authentik || die "authentik is not enabled — there is no portal admin"
        [[ "$(c_health "$(svc_cname authentik)")" == healthy ]] || die "authentik is not healthy yet — ./mediastack.sh status authentik"
        authentik_admin_rotate "$1" || die "the portal's admin password was not rotated (see above)"
        ok "portal admin (akadmin) password rotated — view: ./mediastack.sh credentials"
        # the worker carries it as its first-start value (never applied again):
        # recreated now, so no pending change is left for the next `up`
        DC up -d --no-deps authentik-worker >/dev/null \
            && ok "authentik's worker recreated with it (nothing else changes)" \
            || die "authentik's worker was not recreated — apply with: ./mediastack.sh up"
}
