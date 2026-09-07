#!/usr/bin/env bash
# lib/backup.sh — restore points and the image pipeline: backup (+verify,
# prune), restore, rollback/pin/unpin, update (backup -> pull -> apply) and
# its systemd timer. Sourced by the entrypoint; relies on lib/common.sh and
# the entrypoint's service/render/inspect helpers at call time.

# ------------------------------------------------------------------ backup --
ts_now() { date +%Y%m%d-%H%M%S; }

# shellcheck disable=SC2120  # arguments arrive via main()'s registry dispatch
cmd_backup() {
    # 'backup verify [TS]' is a subcommand; anything else is not an argument
    if [[ "${1:-}" == verify ]]; then shift; args_max 1 "$@"; cmd_backup_verify "$@"; return; fi
    args_none "$@"
    load_env; require_mounts
    local broot croot dest need have
    broot=$(env_get BACKUP_ROOT); croot=$(env_get CONFIG_ROOT)
    need=$(sudo du -sk "$croot" | awk '{print $1}')
    have=$(df -k --output=avail "$broot" | tail -1 | tr -d ' ')
    (( have > need + 524288 )) || die "Not enough space at $broot: need ~$((need/1024))MB (+512MB headroom), have $((have/1024))MB.
  Free space or point BACKUP_ROOT somewhere larger, then retry."
    dest="$broot/$(ts_now)"; sudo mkdir -p "$dest"
    info "Restore point: $dest"

    # images.lock BEFORE stopping (inspect needs the containers)
    local s cn img ref
    c_inspect_all
    { for s in $(svc_managed); do
        cn=$(svc_cname "$s")
        # RepoDigests is an IMAGE field: resolve container -> image -> digest
        img=$(c_get "$cn" '.Image')
        [[ -n "$img" ]] || continue
        ref=$(sudo docker image inspect --format '{{index .RepoDigests 0}}' "$img" 2>/dev/null | tr -d '\n' || true)
        [[ -n "$ref" ]] && echo "$s $ref"
      done; } | sudo tee "$dest/images.lock" >/dev/null
    [[ -s "$dest/images.lock" ]] || warn "images.lock is empty — image-exact rollback unavailable for this point"

    info "Stopping stack for a consistent snapshot... (all services briefly stop; ~20-40s)"
    DC stop >/dev/null
    local rc=0
    for s in $(svc_managed_where mediastack.config true); do
        [[ -d "$croot/$s" ]] || continue
        sudo tar -C "$croot" -czf "$dest/$s.tar.gz" "$s" || { fail "tar failed for $s"; rc=1; }
    done
    sudo cp "$ENV_FILE" "$dest/env"; sudo chmod 600 "$dest/env"
    [[ -s "$PINS_FILE" ]] && sudo cp "$PINS_FILE" "$dest/pins.yml"
    ( cd "$dest" && sudo sh -c 'sha256sum * > SHA256SUMS' )
    info "Restarting stack... (waiting on gluetun health; can take up to ~1min)"
    DC up -d >/dev/null
    if (( rc == 0 )); then ok "Restore point complete: $dest"
    else
        notify ops "Mediastack backup FAILED" "Restore point \`$dest\` finished with errors — **do not trust it**. Inspect on the host." failure
        die "Backup finished WITH ERRORS — do not trust $dest."
    fi
    prune_backups
}

# Tiered (grandfather-father-son) retention, all knobs in .env:
#   BACKUP_KEEP_DAILY   (7)  newest N restore points, kept unconditionally
#   BACKUP_KEEP_WEEKLY  (4)  beyond those: newest point per ISO week, N weeks
#   BACKUP_KEEP_MONTHLY (6)  beyond those: newest point per month, N months
# 0 disables a tier; the newest point is never pruned; anything in
# BACKUP_ROOT not matching a restore-point name is never touched.
prune_backups() {
    local broot keepd keepw keepm
    broot=$(env_get BACKUP_ROOT)
    keepd=$(env_get BACKUP_KEEP_DAILY 7)
    keepw=$(env_get BACKUP_KEEP_WEEKLY 4)
    keepm=$(env_get BACKUP_KEEP_MONTHLY 6)
    local -a all
    local d
    all=()
    for d in "$broot"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]; do
        [[ -d "$d" ]] && all+=("$(basename "$d")")
    done
    mapfile -t all < <(printf '%s\n' "${all[@]}" | sort -r)
    (( ${#all[@]} )) || return 0
    local -A keepset seenw seenm
    local p d wk mo i=0 pruned=0 nw=0 nm=0
    for p in "${all[@]}"; do
        d=${p:0:8}
        if (( i < keepd )) || (( i == 0 )); then keepset[$p]=1; i=$((i+1)); continue; fi
        i=$((i+1))
        wk=$(date -d "$d" +%G-%V 2>/dev/null) || { keepset[$p]=1; continue; }
        mo=${d:0:6}
        if [[ -z "${seenw[$wk]:-}" ]] && (( nw < keepw )); then
            seenw[$wk]=1; nw=$((nw+1)); keepset[$p]=1; continue
        fi
        seenw[$wk]=1
        if [[ -z "${seenm[$mo]:-}" ]] && (( nm < keepm )); then
            seenm[$mo]=1; nm=$((nm+1)); keepset[$p]=1; continue
        fi
        seenm[$mo]=1
    done
    for p in "${all[@]}"; do
        [[ -n "${keepset[$p]:-}" ]] && continue
        info "Pruning restore point $p (older than the retention policy keeps)"
        sudo rm -rf "${broot:?}/$p"; pruned=$((pruned+1))
    done
    ok "restore points: kept $(( ${#all[@]} - pruned )), pruned $pruned — policy: the last $keepd backups, plus one per week for $keepw weeks, plus one per month for $keepm months (change via BACKUP_KEEP_* in .env)"
}

cmd_backup_verify() {
    load_env
    local broot t="${1:-}"
    broot=$(env_get BACKUP_ROOT)
    [[ -n "$t" ]] || t=$(ls -1 "$broot" | tail -1)
    [[ -d "$broot/$t" ]] || die "No restore point '$t' under $broot"
    ( cd "$broot/$t" && sudo sha256sum -c SHA256SUMS ) && ok "Checksums OK for $t"
    local f; for f in "$broot/$t"/*.tar.gz; do
        sudo tar -tzf "$f" >/dev/null || die "Corrupt archive: $f"
    done
    ok "Archives readable. (True proof is a restore drill: restore --service <svc>.)"
}

# ------------------------------------------------- restore / rollback / pin --
pin_service() { # pin_service svc image_ref
    touch "$PINS_FILE"
    grep -q '^services:' "$PINS_FILE" || echo "services:" > "$PINS_FILE"
    if grep -q "^  $1:" "$PINS_FILE"; then
        # replace the image line following the service key
        sudo sed -i "/^  $1:/,/image:/ s|image:.*|image: $2|" "$PINS_FILE"
    else
        printf '  %s:\n    image: %s\n' "$1" "$2" >> "$PINS_FILE"
    fi
    ok "$1 pinned to $2 (updates hold; release with: ./mediastack.sh unpin $1)"
}

cmd_unpin() {
    local s="${1:?usage: unpin <service>}"; load_env
    [[ -s "$PINS_FILE" ]] || { ok "Nothing pinned."; return; }
    sed -i "/^  $s:/,+1d" "$PINS_FILE"
    [[ $(grep -c ':' "$PINS_FILE") -le 1 ]] && rm -f "$PINS_FILE"
    RENDERED_JSON=""; DC up -d "$s"
    ok "$s unpinned and returned to the floating tag. Next 'update' includes it."
}

cmd_restore() {
    load_env; require_mounts
    local svc="" all_svcs=0 from=""
    while [[ $# -gt 0 ]]; do case "$1" in
        --service) svc="$2"; shift 2 ;;
        --all) all_svcs=1; shift ;;
        --from) from="$2"; shift 2 ;;
        *) die "Unknown restore arg '$1' (usage: restore --service SVC|--all [--from TS])" ;;
    esac; done
    (( all_svcs )) || [[ -n "$svc" ]] || die "usage: restore --service SVC | --all  [--from TIMESTAMP]"
    local broot; broot=$(env_get BACKUP_ROOT)
    [[ -n "$from" ]] || from=$(ls -1 "$broot" 2>/dev/null | tail -1)
    [[ -n "$from" && -d "$broot/$from" ]] || die "No restore point found. Available: $(ls -1 "$broot" 2>/dev/null | tr '\n' ' ')"
    info "Restoring from $from"
    local targets; if (( all_svcs )); then targets=$(svc_managed); else targets="$svc"; fi
    local croot ts s ref
    croot=$(env_get CONFIG_ROOT); ts=$(ts_now)
    for s in $targets; do
        svc_exists "$s" || die "No service '$s'."
        DC stop "$s" >/dev/null
        if [[ -f "$broot/$from/$s.tar.gz" ]]; then
            [[ -d "$croot/$s" ]] && sudo mv "$croot/$s" "$croot/$s.pre-restore.$ts"
            sudo tar -C "$croot" -xzf "$broot/$from/$s.tar.gz"
            ok "$s config restored (previous kept at $s.pre-restore.$ts)"
        fi
        ref=$(awk -v s="$s" '$1==s{print $2}' "$broot/$from/images.lock" 2>/dev/null || true)
        [[ -n "$ref" ]] && pin_service "$s" "$ref"
        RENDERED_JSON=""
        DC up -d "$s"
    done
    ok "Restore done. Verify with: ./mediastack.sh status"
}

cmd_rollback() { cmd_restore --service "${1:?usage: rollback <service>}"; }

# ------------------------------------------------------------------ update --
jellyfin_sessions_active() {
    local key host; key=$(env_get JELLYFIN_API_KEY); host=$(jf_url)
    [[ -n "$key" ]] || return 1
    local n
    n=$(curl -fsS --max-time 5 "$host/Sessions?api_key=$key" 2>/dev/null \
        | jq '[.[] | select(.NowPlayingItem != null)] | length' 2>/dev/null || echo 0)
    (( n > 0 ))
}

# `DC up` during an update, with the health verdict delegated to the script's
# own health gate. Compose's depends_on: service_healthy gating fails `up`
# (non-zero, fatal under set -e) the moment a service is briefly unhealthy on
# recreate — e.g. a new image mid first-run migration — aborting the update
# before vpn_reattach_guard and the tolerant 300s health gate ever run. We
# therefore treat ONLY a health-gate abort as non-fatal and let the gate
# adjudicate; every other up failure (broken config, image pull, etc.) still
# dies loudly with compose's message. Never swallow a non-health failure.
apply_up() {
    local rerr rc
    rerr=$(mktemp)
    if DC up -d "$@" 2>"$rerr"; then
        cat "$rerr" >&2; rm -f "$rerr"; return 0
    fi
    rc=$?
    cat "$rerr" >&2   # always surface compose's output
    if grep -qE 'dependency failed to start|is unhealthy|health' "$rerr"; then
        warn "compose aborted the apply on a transient health check — deferring the verdict to the health gate below"
        rm -f "$rerr"; return 0
    fi
    rm -f "$rerr"
    die "update: 'up' failed for a non-health reason (rc=$rc) — see compose's message above. Nothing further was applied."
}

cmd_update() {
    load_env; require_mounts
    local one="" to_tag="" dry=0 now=0 auto=0
    while [[ $# -gt 0 ]]; do case "$1" in
        --dry-run) dry=1; shift ;;
        --now) now=1; shift ;;
        --auto) auto=1; shift ;;
        --to) [[ -n "${2:-}" ]] || die "--to needs a tag (usage: update <svc> --to <tag>)"; to_tag="$2"; shift 2 ;;
        -*) die "unknown option '$1' (usage: update [svc] [--dry-run] [--now] [--auto] [--to TAG])" ;;
        *) [[ -z "$one" ]] || die "update takes one service (got '$one' and '$1')"; one="$1"; shift ;;
    esac; done
    [[ -n "$to_tag" && -z "$one" ]] && die "--to requires a service: update <svc> --to <tag>"
    [[ -n "$one" ]] && { svc_exists "$one" || die "No service '$one'."; }

    # session deferral (auto runs only)
    if (( auto )) && [[ "$(env_get UPDATE_DEFER_IF_ACTIVE false)" == true ]] && (( ! now )); then
        local waited=0 retry max
        retry=$(( $(env_get UPDATE_DEFER_RETRY_MIN 30) * 60 )); max=$(( $(env_get UPDATE_DEFER_MAX_MIN 180) * 60 ))
        while jellyfin_sessions_active; do
            (( waited >= max )) && { [[ "$(env_get UPDATE_DEFER_ACTION proceed)" == skip ]] \
                && { warn "Streams still active after max deferral — SKIPPING this update run."; return 0; } \
                || { warn "Streams still active after max deferral — proceeding anyway."; break; }; }
            info "Active stream detected — deferring update $((retry/60))min..."
            sleep "$retry"; waited=$(( waited + retry ))
        done
    fi

    # build target list honouring toggles + pins
    [[ -n "$one" ]] && ! svc_enabled "$one" && die "'$one' is not enabled — enable it first or skip it."
    local targets=() s
    for s in $(svc_enabled_managed); do
        [[ -n "$one" && "$s" != "$one" ]] && continue
        [[ -z "$one" ]] && { [[ "$(env_get "$(uvar "$s")_UPDATE" true)" == true ]] || continue; }
        [[ -s "$PINS_FILE" ]] && grep -q "^  $s:" "$PINS_FILE" && [[ -z "$to_tag" ]] \
            && { info "$s is pinned — skipping (unpin to resume updates)."; continue; }
        targets+=("$s")
    done
    (( ${#targets[@]} )) || { ok "Nothing to update."; return 0; }

    if (( dry )); then
        hr "update --dry-run"
        for s in "${targets[@]}"; do
            local cn cur; cn=$(svc_cname "$s"); cur=$(c_version "$cn")
            echo "$s: would pull $( [[ -n "$to_tag" ]] && echo "$(svc_image "$s" | cut -d: -f1):$to_tag" || svc_image "$s" ) (currently ${cur:-unknown})"
        done
        return 0
    fi

    hr "Update: restore point first"
    cmd_backup

    if [[ -n "$to_tag" ]]; then
        local base; base=$(svc_image "$one" | cut -d: -f1)
        pin_service "$one" "$base:$to_tag"
        RENDERED_JSON=""
    fi

    hr "Pulling images"
    info "pulling from registries — the slowest step on a full update; a minute or two is normal"
    local after changed=()
    local -A before=()
    for s in "${targets[@]}"; do before[$s]=$(c_version "$(svc_cname "$s")"); done
    DC pull "${targets[@]}"
    hr "Applying"
    # Cascade: recreating gluetun gives it a new container ID, and compose does
    # NOT recreate its network_mode:service:gluetun borrowers when only their
    # namespace-host changed — they would be left on the dead ID (the ghost).
    # So when gluetun is in this update's target set, expand the recreate to
    # its enabled borrowers and --force-recreate the group together, the way a
    # dependency-aware updater would. Prevention: the borrowers never come up
    # stale, so there is no repair window. vpn_reattach_guard still runs after
    # as the catch-all for drift arriving via any OTHER path (out-of-band
    # compose, reboots) — this only closes the update path's own recreate.
    if printf '%s\n' "${targets[@]}" | grep -qx gluetun; then
        # gluetun is in this run: recreate it AND its borrowers as one
        # force-recreated group so no borrower is left on the old ID. Other
        # targets apply normally in the same call — only the VPN group is
        # forced, to avoid needlessly recreating unrelated services.
        render
        local grp=(gluetun) b
        while IFS= read -r b; do
            [[ -z "$b" ]] && continue
            svc_enabled "$b" && grp+=("$b")
        done < <(jq -r '.services | to_entries[]
            | select((.value.network_mode // "") == "service:gluetun") | .key' \
            <<<"$RENDERED_JSON")
        info "gluetun is updating — recreating its ${#grp[@]}-member VPN group together so none is orphaned"
        apply_up --remove-orphans --force-recreate "${grp[@]}"
        apply_up --remove-orphans "${targets[@]}"
    else
        apply_up --remove-orphans "${targets[@]}"
    fi
    sudo docker image prune -f >/dev/null

    vpn_reattach_guard

    hr "Health gate"
    local deadline=$(( $(date +%s) + 300 )) bad=()
    for s in "${targets[@]}"; do
        local cn h; cn=$(svc_cname "$s")
        while :; do
            h=$(c_health "$cn")
            [[ "$h" == healthy || "$h" == "-" ]] && break
            (( $(date +%s) > deadline )) && { bad+=("$s"); break; }
            sleep 5
        done
        after=$(c_version "$cn")
        [[ "${before[$s]}" != "$after" ]] && changed+=("$s: ${before[$s]:-?} -> ${after:-?}")
    done
    # search functional probe: index must exist and be non-empty
    if svc_enabled jellysearch; then
        local docs
        docs=$(sudo docker exec "$(svc_cname meilisearch)" sh -c \
               "curl -fsS -H 'Authorization: Bearer $(env_get MEILI_MASTER_KEY)' http://127.0.0.1:7700/stats \
                || wget -qO- --header='Authorization: Bearer $(env_get MEILI_MASTER_KEY)' http://127.0.0.1:7700/stats" \
               2>/dev/null | jq '[.indexes[].numberOfDocuments] | add // 0' || echo 0)
        (( docs > 0 )) && ok "search index: $docs documents" \
            || { warn "search index EMPTY after update — try 'docker restart $(svc_cname jellysearch)';"; warn "if it stays empty: ./mediastack.sh rollback jellyfin"; bad+=("jellysearch(index)"); }
    fi

    echo; hr "Update summary"
    (( ${#changed[@]} )) && printf '  %s\n' "${changed[@]}" || echo "  no version changes"
    if (( ${#bad[@]} )); then
        fail "Unhealthy after update: ${bad[*]}"
        echo "  Roll back any of them with: ./mediastack.sh rollback <service>"
        notify ops "Mediastack update FAILED" "Unhealthy after update: **${bad[*]}**\nRoll back: \`./mediastack.sh rollback <service>\`" failure
        exit 1
    fi
    ok "All updated services healthy."
    (( ${#changed[@]} )) && notify ops "Mediastack updated" "$(printf '`%s`\\n' "${changed[@]}")" success

    # nightly TRaSH sync rides the update pipeline: same schedule the
    # operator already chose, guides drift-window stays at one cycle.
    if grep -q "^TRASH_PROFILE_" .env 2>/dev/null; then
        # pinned-major drift notice: the recyclarr pin (":8") is deliberate,
        # but a released v9 should be a visible decision, not silence
        local rc_pin rc_latest
        rc_pin=$(grep -oE 'recyclarr/recyclarr:[0-9]+' compose.d/recyclarr.yml 2>/dev/null | cut -d: -f2)
        rc_latest=$(curl -sf -m 10 https://github.com/recyclarr/recyclarr/releases.atom 2>/dev/null \
                    | grep -oE '<title>v[0-9]+' | head -1 | grep -oE '[0-9]+')
        if [[ -n "$rc_pin" && -n "$rc_latest" ]] && (( rc_latest > rc_pin )); then
            warn "recyclarr v$rc_latest is out; the stack pins major v$rc_pin — review the breaking changes, then bump the tag in compose.d/recyclarr.yml when ready"
            notify ops "recyclarr v$rc_latest available" "Stack pins major **v$rc_pin**. Review upstream breaking changes, then bump \`compose.d/recyclarr.yml\`." warning
        fi
        echo
        cmd_trash_sync || { fail "update pipeline: trash-sync step failed (updates themselves succeeded — see FAIL lines above)"
                            notify ops "Mediastack trash-sync FAILED" "Nightly TRaSH sync failed — updates themselves succeeded.\nInspect: \`./mediastack.sh trash-sync\`" failure
                            exit 1; }
    fi
}

cmd_apply_timer() {
    load_env
    local sched; sched=$(env_get UPDATE_SCHEDULE)
    if [[ -z "$sched" ]]; then
        sudo systemctl disable --now mediastack-update.timer 2>/dev/null || true
        ok "Automatic updates disabled (UPDATE_SCHEDULE is empty)."
        return
    fi
    systemd-analyze calendar "$sched" >/dev/null 2>&1 || die "UPDATE_SCHEDULE '$sched' is invalid."
    sudo tee /etc/systemd/system/mediastack-update.service >/dev/null <<EOF
[Unit]
Description=Mediastack update pipeline
[Service]
Type=oneshot
WorkingDirectory=$SCRIPT_DIR
ExecStart=$SCRIPT_DIR/mediastack.sh update --auto
EOF
    sudo tee /etc/systemd/system/mediastack-update.timer >/dev/null <<EOF
[Unit]
Description=Mediastack scheduled update
[Timer]
OnCalendar=$sched
Persistent=true
[Install]
WantedBy=timers.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now mediastack-update.timer
    ok "Timer installed: $sched (next: $(systemctl show mediastack-update.timer -p NextElapseUSecRealtime --value 2>/dev/null || echo '?'))"
}
