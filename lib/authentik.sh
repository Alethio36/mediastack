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

authentik_prepare() { # before `up`/`enable` start it: secrets, then the release step
    svc_enabled authentik || return 0
    authentik_secrets
    authentik_release_check
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
    elif svc_enabled wizarr; then
        info "accounts: Wizarr (each app keeps its own accounts)"
    fi
    return 0
}
