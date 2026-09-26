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

authentik_blueprint_status() { # -> successful | warning | error | ... | "" (not discovered yet) | "unreadable (…)"
    local out
    out=$(ak_api GET "/managed/blueprints/?page_size=200") || { echo "unreadable ($(head -c120 <<<"$out"))"; return 0; }
    jq -r --arg n "$AUTHENTIK_BLUEPRINT" '[.results[] | select(.name == $n) | .status][0] // ""' <<<"$out"
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
                *) d_fail "authentik: mediastack's portal setup is '$st'" "groups and sign-up may be missing or incomplete" \
                       "./mediastack.sh logs authentik --no-follow | grep -i blueprint" ;;
            esac
        fi
    elif svc_enabled wizarr; then
        info "accounts: Wizarr (each app keeps its own accounts)"
    fi
    return 0
}
