#!/usr/bin/env bash
# lib/authentik.sh — the authentik shard's upkeep (compose.d/authentik.yml):
# its secrets, its first admin, and its upgrade path. Sourced by the
# entrypoint; relies on lib/common.sh and the render/svc/c_* helpers.
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
    if [[ -z "$(env_get AUTHENTIK_LDAP_BIND_PASSWORD)" ]]; then
        env_set AUTHENTIK_LDAP_BIND_PASSWORD "$(authentik_secret 32)"; made=1
    fi
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

AUTHENTIK_BLUEPRINT="Mediastack - Portal"   # metadata.name in blueprints/authentik/mediastack-portal.yaml
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
    for f in "$SCRIPT_DIR"/blueprints/authentik/*.yaml; do
        sudo cmp -s "$f" "$dst/${f##*/}" || { sudo install -o "$uid" -g mediacenter -m 644 "$f" "$dst/${f##*/}"; n=1; }
    done
    # a blueprint mediastack no longer ships leaves with it (the folder is ours alone)
    for f in $(sudo find "$dst" -maxdepth 1 -name '*.yaml' -printf '%f\n'); do
        [[ -e "$SCRIPT_DIR/blueprints/authentik/$f" ]] || { sudo rm -f "$dst/$f"; n=1; }
    done
    [[ -n "${n:-}" ]] && info "authentik: portal setup files updated — its worker applies them on change (check: ./mediastack.sh wire authentik)"
    return 0
}

gate_bind_sync() { # MEDIASTACK_GATE_BIND: where a gated tool's host port listens — 127.0.0.1 while the portal guards it
    # MEDIASTACK_GATE_TRUST: who may name the user to an app that trusts a
    # header (Navidrome) — Traefik's fixed address while the portal runs, nobody otherwise
    local trust=""
    svc_enabled authentik && trust="$(env_get TRAEFIK_ADDRESS 172.31.250.2)/32"
    [[ "$(env_get MEDIASTACK_GATE_TRUST)" == "$trust" ]] || env_set MEDIASTACK_GATE_TRUST "$trust"
    local want=""
    svc_enabled authentik && want="127.0.0.1:"
    [[ "$(env_get MEDIASTACK_GATE_BIND)" == "$want" ]] && return 0
    env_set MEDIASTACK_GATE_BIND "$want"
    if [[ -n "$want" ]]; then info "gated tools' host ports now listen on 127.0.0.1 only — reach them through the portal"
    else info "gated tools' host ports reopen to the LAN (no portal to guard them)"; fi
}

svc_bound_local() { # svc_bound_local <svc> -> 0 when nothing publishes its port beyond 127.0.0.1 (checked on the live container)
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
    mine=$(sha512sum "$SCRIPT_DIR/blueprints/authentik/mediastack-portal.yaml" | cut -d' ' -f1)
    if [[ "$(jq -r '.last_applied_hash // ""' <<<"$inst")" != "$mine" ]]; then
        # a failed apply keeps the previous version's hash: its status says it failed
        [[ "$(jq -r '.status' <<<"$inst")" == error ]] && { echo error; return 0; }
        echo outdated; return 0
    fi
    jq -r '.status' <<<"$inst"
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
    for t in $(seq 1 30); do   # the apply may be queued: up to a minute
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
                       "groups, sign-up and LDAP may be missing or incomplete" "fix the entry named above in blueprints/authentik/, then: ./mediastack.sh up && ./mediastack.sh wire authentik" ;;
            esac
            if [[ -z "$(env_get AUTHENTIK_LDAP_TOKEN)" ]]; then
                warn "authentik's LDAP outpost has no token yet (it keeps restarting until it does): ./mediastack.sh wire authentik"
            fi
            local g open=""
            for g in $(authentik_gated); do svc_bound_local "$g" || open+="$g "; done
            [[ -z "$open" ]] || d_fail "gated tools reachable by IP, around the portal: $open" \
                "their host ports are not bound to 127.0.0.1 yet" "./mediastack.sh up"
            if [[ -n "$(authentik_gated)" ]]; then
                if authentik_gate_attached; then ok "authentik: the gate is up — $(authentik_gated | tr '\n' ' ')ask the portal first (admins only)"
                else d_fail "authentik: the gate is not on its built-in outpost" "routes marked gate ($(authentik_gated | tr '\n' ' '| sed 's/ $//')) refuse everyone" "./mediastack.sh wire authentik"; fi
            fi
        fi
    elif svc_enabled wizarr; then
        info "accounts: Wizarr (each app keeps its own accounts)"
    fi
    return 0
}
