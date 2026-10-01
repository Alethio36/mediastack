#!/usr/bin/env bash
# lib/backup.sh — restore points and the image pipeline: backup (+verify,
# prune), restore, rollback/pin/unpin, update (backup -> pull -> apply) and
# its systemd timer. Sourced by the entrypoint; relies on lib/common.sh and
# the entrypoint's service/render/inspect helpers at call time.

# ------------------------------------------------------------------ backup --
ts_now() { date +%Y%m%d-%H%M%S; }

# latest_restore_point -> the newest GFS restore point's name, "" if none.
# The ONE way to find it: BACKUP_ROOT also holds pre-update/ and manifest/,
# and "newest entry in the folder" picks those (status and backup verify did).
# Bash sorts the glob, so the last match is the newest timestamp.
latest_restore_point() {
    local d last=""
    for d in "$(env_get BACKUP_ROOT)"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]; do
        [[ -d "$d" ]] && last=$(basename "$d")
    done
    echo "$last"
}

# shellcheck disable=SC2120  # arguments arrive via main()'s registry dispatch
cmd_backup() {
    case "${1:-}" in
        verify) shift; args_max 1 "$@"; cmd_backup_verify "$@"; return ;;
        list)   shift; args_max 1 "$@"; cmd_backup_list "$@"; return ;;
    esac
    local note="" auto=0
    while (( $# )); do case "$1" in
        --note) [[ -n "${2:-}" ]] || die "usage: backup --note \"why this point\""; note=$2; shift 2 ;;
        --auto) auto=1; shift ;;
        *) die "Unknown backup arg '$1' (usage: backup [--note TEXT] | backup verify [TS] | backup list [svc])" ;;
    esac; done
    if (( auto )); then
        [[ -z "$note" ]] || die "backup --auto is the timer's run — it takes no note"
        backup_scheduled
    else
        backup_take manual "$note"
    fi
}

# The backup timer's run (BACKUP_SCHEDULE). It waits for a running update or
# backup, then skips when a full restore point is under BACKUP_SKIP_HOURS old
# — an update's covers every service, so update nights get one, not two (a
# scoped update <svc> point never counts). It waits while someone streams,
# like the update timer (UPDATE_DEFER_*).
BACKUP_SKIP_HOURS=6
backup_scheduled() {
    load_env
    maint_lock "the scheduled backup" "$MAINT_WAIT" || {
        notify ops "Mediastack scheduled backup skipped" "Another update or backup held the stack for $((MAINT_WAIT / 3600)) hours. Check: \`systemctl status mediastack-update mediastack-backup\`" failure
        die "Another update or backup held the stack for $((MAINT_WAIT / 3600)) hours — this scheduled backup is skipped."
    }
    local last age
    last=$(latest_restore_point)
    if [[ -n "$last" ]] && age=$(ts_age_hours "$last") && (( age < BACKUP_SKIP_HOURS )); then
        ok "Restore point $last is $( (( age == 0 )) && echo "under an hour" || echo "${age}h" ) old and covers every service — this scheduled backup is skipped."
        return 0
    fi
    defer_while_streaming backup || return 0
    backup_take scheduled ""
}

# ------------------------------------------------------- maintenance lock --
# Updates and backups stop and start the stack: two at once would fight over
# it. One lock: a run you start refuses while another holds it; a timer's run
# waits (MAINT_WAIT). Held until the process exits; re-entry (update's own
# restore point) is a no-op.
MAINT_LOCK=/run/lock/mediastack-maintenance.lock
MAINT_WAIT=21600   # seconds a timer's run waits: an update postponed for streams (UPDATE_DEFER_MAX_MIN) plus its run
MAINT_LOCKED=0
maint_lock() { # maint_lock WHAT WAIT-SECONDS — 0: refuse at once when held; rc 1 when the wait ran out
    (( MAINT_LOCKED )) && return 0
    [[ -e "$MAINT_LOCK" ]] || : > "$MAINT_LOCK"
    exec 8<"$MAINT_LOCK"
    if ! flock -n 8; then
        (( $2 > 0 )) || die "Another update or backup is running — $1 refused. Try again once it has finished."
        info "Another update or backup is running — $1 waits for it (up to $(( $2 / 3600 )) hours)..."
        flock -w "$2" 8 || return 1
    fi
    MAINT_LOCKED=1
}

defer_while_streaming() { # defer_while_streaming WHAT — postpone while someone streams (UPDATE_DEFER_*); rc 1 = skip this run
    [[ "$(env_get UPDATE_DEFER_IF_ACTIVE false)" == true ]] || return 0
    local waited=0 retry max
    retry=$(( $(env_get UPDATE_DEFER_RETRY_MIN 30) * 60 )); max=$(( $(env_get UPDATE_DEFER_MAX_MIN 180) * 60 ))
    while jellyfin_sessions_active; do
        if (( waited >= max )); then
            if [[ "$(env_get UPDATE_DEFER_ACTION proceed)" == skip ]]; then
                warn "Streams still active after max deferral — SKIPPING this $1 run."; return 1
            fi
            warn "Streams still active after max deferral — proceeding anyway."; return 0
        fi
        info "Active stream detected — deferring $1 $((retry/60))min..."
        sleep "$retry"; waited=$(( waited + retry ))
    done
}

# Every restore point says who made it and what ran: `meta` holds its kind —
# manual (backup by hand or the panel), scheduled (the backup timer), update
# (a full update's point), update-scoped (update <svc>), migrate (an import) —
# an optional note, and one "svc version digest" line per container.
# Information only: retention, restore and the skip rule never read it.
backup_take() { # backup_take KIND NOTE — a full cold restore point into the GFS pool
    load_env; require_mounts
    maint_lock backup 0
    local broot croot dest need have
    broot=$(env_get BACKUP_ROOT); croot=$(env_get CONFIG_ROOT)
    need=$(sudo du -sk "$croot" | awk '{print $1}')
    have=$(df -k --output=avail "$broot" | tail -1 | tr -d ' ')
    (( have > need + 524288 )) || die "Not enough space at $broot: need ~$((need/1024))MB (+512MB headroom), have $((have/1024))MB.
  Free space or point BACKUP_ROOT somewhere larger, then retry."
    # built under <ts>.partial and renamed once complete: an interrupted or
    # failed point never looks like one (restore, doctor and verify skip it)
    local final; final="$broot/$(ts_now)"; dest="$final.partial"; sudo mkdir -p "$dest"
    info "Restore point: $final"

    # shellcheck disable=SC2046  # a word list of services
    point_record "$dest" "$1" "$2" $(svc_managed)
    [[ -s "$dest/images.lock" ]] || warn "images.lock is empty — image-exact rollback unavailable for this point"

    info "Stopping stack for a consistent snapshot... (all services briefly stop; ~20-40s)"
    local rc=0
    stopped_run backup "" backup_snapshot "$croot" "$dest" || rc=$?
    case $rc in
        0) sudo mv "$dest" "$final"; ok "Restore point complete: $final" ;;
        "$BACKUP_PARTIAL")
            notify ops "Mediastack backup FAILED" "Restore point \`$dest\` finished with errors — **do not trust it**. Inspect on the host; the next backup removes it." failure
            die "Backup finished WITH ERRORS — $dest is kept for inspection, never restored from, and removed by the next backup." ;;
        *) die "Backup stopped early (exit $rc) — the services were started again; nothing was kept as a restore point." ;;
    esac
    prune_backups
    points_private
}

svc_digest() { # svc_digest SVC -> the digest its container runs ("" when unknown); needs c_inspect_all
    local img
    # RepoDigests is an IMAGE field: resolve container -> image -> digest
    img=$(c_get "$(svc_cname "$1")" '.Image'); [[ -n "$img" ]] || return 0
    sudo docker image inspect --format '{{index .RepoDigests 0}}' "$img" 2>/dev/null | tr -d '\n' || true
}

point_record() { # point_record DEST KIND NOTE SVC... — images.lock and meta, BEFORE stopping (inspect needs the containers)
    local dest=$1 kind=$2 note=${3//$'\n'/ } s ref ver lock="" rows=""; shift 3
    c_inspect_all
    for s in "$@"; do
        ref=$(svc_digest "$s"); [[ -n "$ref" ]] || continue
        ver=$(c_version "$(svc_cname "$s")" || true)
        lock+="$s $ref"$'\n'; rows+="$s ${ver:--} $ref"$'\n'
    done
    printf '%s' "$lock" | sudo tee "$dest/images.lock" >/dev/null
    { printf 'kind=%s\nnote=%s\n' "$kind" "$note"; printf '%s' "$rows"; } | sudo tee "$dest/meta" >/dev/null
}

cmd_backup_list() { # backup list [svc] — every restore point, newest first; with a service, what it ran in each
    load_env
    local svc=${1:-} broot run="" tgt="" rel ts kind note ver mark
    broot=$(env_get BACKUP_ROOT)
    if [[ -n "$svc" ]]; then
        svc_exists "$svc" || die "No service '$svc'."
        c_inspect_all; run=$(svc_digest "$svc")
        [[ -z "$run" ]] || tgt=$(rollback_target "$broot" "$svc" "$run") || tgt=""
    fi
    local rows; rows=$(points_holding "$broot" "$svc")
    [[ -n "$rows" ]] || { info "No restore points${svc:+ holding $svc} under $broot yet — take one: ./mediastack.sh backup"; return 0; }
    if [[ -n "$svc" ]]; then printf '  %-15s  %-13s  %-26s  %-8s  %s\n' WHEN KIND "$(tr '[:lower:]' '[:upper:]' <<<"$svc")" "" NOTE
    else printf '  %-15s  %-13s  %s\n' WHEN KIND NOTE; fi
    while read -r rel; do
        ts=${rel#pre-update/}; kind=$(point_kind "$broot/$rel" "$rel"); note=$(point_meta "$broot/$rel" note)
        if [[ -n "$svc" ]]; then
            ver=$(point_version "$broot/$rel" "$svc")
            # current: the image running now; rollback: where `rollback <svc>` goes
            mark=""
            [[ -n "$run" && "$(awk -v s="$svc" '$1==s {print $2}' "$broot/$rel/images.lock" 2>/dev/null || true)" == "$run" ]] && mark=current
            [[ "$rel" == "$tgt" ]] && mark=rollback
            printf '  %-15s  %-13s  %-26s  %-8s  %s\n' "$ts" "$kind" "${ver:0:26}" "$mark" "$note"
        else
            printf '  %-15s  %-13s  %s\n' "$ts" "$kind" "$note"
        fi
    done <<<"$rows"
}

point_meta() { # point_meta POINT KEY -> the value ("" when the point has no meta)
    [[ -f "$1/meta" ]] || return 0
    sed -n "s/^$2=//p" "$1/meta" | head -1
}

point_private() { # point_private DEST — the archives hold every app's keys and databases: root reads them, nobody else
    # (meta, images.lock and SHA256SUMS stay readable: backup list and the skip rule read them without sudo)
    local f
    for f in "$1"/*.tar.gz; do
        [[ -e "$f" ]] || continue
        sudo chmod 600 "$f" || { fail "could not restrict $f"; return 1; }
    done
}

points_private() { # points_private — restore points made before point_private existed were 644: tighten them, once per backup
    local broot; broot=$(env_get BACKUP_ROOT)
    sudo find "$broot" -maxdepth 3 -name '*.tar.gz' ! -perm 600 -exec chmod 600 {} + 2>/dev/null || true
}

backup_snapshot() { # backup_snapshot CROOT DEST — runs with the stack stopped; -> 0, or BACKUP_PARTIAL if an archive failed
    # stopped_run's caller tests it with ||, and there bash ignores set -e:
    # every step here checks itself
    local croot=$1 dest=$2 s rc=0
    for s in $(svc_managed_where mediastack.config true); do
        [[ -d "$croot/$s" ]] || continue
        # jellyfin's default transcode dir is inside /config; in-flight or
        # orphaned HLS segments are not config (wire moves them to /cache)
        sudo tar -C "$croot" --exclude="$s/data/transcodes" -czf "$dest/$s.tar.gz" "$s" || { fail "tar failed for $s"; rc=$BACKUP_PARTIAL; }
    done
    { sudo cp "$ENV_FILE" "$dest/env" && sudo chmod 600 "$dest/env"; } || { fail "could not copy .env into the restore point"; return 1; }
    if [[ -s "$PINS_FILE" ]]; then sudo cp "$PINS_FILE" "$dest/pins.yml" || { fail "could not copy the pins into the restore point"; return 1; }; fi
    if [[ -d "$CUSTOM_DIR" ]]; then
        sudo tar -C "$SCRIPT_DIR" -czf "$dest/custom.tar.gz" custom || { fail "tar failed for custom/"; rc=$BACKUP_PARTIAL; }
    fi
    point_private "$dest" || return 1
    ( cd "$dest" && sudo sh -c 'sha256sum * > SHA256SUMS' ) || { fail "could not write the restore point's checksums"; return 1; }
    info "Restarting stack... (waiting on gluetun health; can take up to ~1min)"
    return "$rc"
}

# ------------------------------------------------------ stopped services --
# A backup and a scoped pre-update point stop containers, then start them
# again. Docker never restarts them on its own: `compose stop` marks them as
# deliberately stopped, and that outlives a reboot. So STOP_MARKER names what
# is down while the work runs; stopped_run's EXIT trap starts it again on any
# exit (an error, Ctrl-C, a dropped SSH session, a shutdown's SIGTERM), and the
# boot guard does after what no trap survives (a power cut, kill -9);
# STOP_MARKER itself lives with the other path globals in mediastack.sh.
# `restore` stays out on purpose: restarting a service on a half-extracted
# config is worse than leaving it down for the restore to be run again.
BACKUP_PARTIAL=3   # the work finished, but an archive failed (not an interruption)

stopped_run() { # stopped_run WHAT "SVC..." CMD [ARG...] — stop SVC ("" = the stack), run CMD, start them whatever happens
    local what=$1 svcs=$2; shift 2
    mkdir -p "$LOCAL_DIR"; repo_owned "$LOCAL_DIR"
    printf '%s\n%s\n' "$what" "$svcs" > "$STOP_MARKER"; repo_owned "$STOP_MARKER"
    (
        trap stopped_restart EXIT
        trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
        # set -e is off in here (the caller tests us with ||): check each step
        # shellcheck disable=SC2086  # a word list; empty means every service
        DC stop $svcs >/dev/null || { fail "$what: could not stop ${svcs:-the stack}"; exit 1; }
        "$@"
    )
}

stopped_start() { # start what STOP_MARKER names; the marker goes only once they are up
    local what svcs
    { read -r what; read -r svcs || true; } < "$STOP_MARKER"
    # shellcheck disable=SC2086
    DC up -d $svcs >/dev/null 2>&1 || return 1
    sudo rm -f "$STOP_MARKER"
}

stopped_restart() { # stopped_run's EXIT trap: the services come back first, messages after
    local rc=$? what
    what=$(head -1 "$STOP_MARKER")
    if ! stopped_start; then
        fail "$what: the services it stopped did not start again — run: ./mediastack.sh up"
        notify ops "Mediastack is DOWN" "The $what stopped services that did not start again. Run \`./mediastack.sh up\` on the host." failure
        exit 1
    fi
    if (( rc != 0 && rc != BACKUP_PARTIAL )); then
        warn "$what stopped early (exit $rc) — the services it stopped were started again"
        notify ops "Mediastack $what stopped early — services running again" "Exit $rc (an error, Ctrl-C, a dropped session or a shutdown): the services it stopped were started again. The restore point it was making is incomplete and is never used." failure
    fi
    exit "$rc"
}

stopped_recover() { # at boot: a marker left behind is a stop no trap could undo (a power cut, kill -9)
    [[ -f "$STOP_MARKER" ]] || return 0
    local what; what=$(head -1 "$STOP_MARKER")
    if stopped_start; then
        warn "$what was cut off (power loss or a killed run) — the services it stopped were started again"
        notify ops "Mediastack $what cut off — services started again at boot" "Found at boot: the services it stopped were started again. The restore point it was making is incomplete and is never used." failure
    else
        fail "$what was cut off and the services it stopped did not start — run: ./mediastack.sh up"
        notify ops "Mediastack is DOWN" "Found at boot: a cut-off $what left services stopped, and they did not start. Run \`./mediastack.sh up\` on the host." failure
    fi
}

prune_partial() { # prune_partial DIR — incomplete points left by a failed or interrupted run
    local d
    for d in "$1"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].partial; do
        [[ -d "$d" ]] || continue
        info "Removing incomplete restore point $(basename "$d")"
        sudo rm -rf "$d"
    done
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
    prune_partial "$broot"
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

# Scoped pre-update restore point: stops and snapshots ONLY the named
# service(s), leaving the rest of the stack running. Lands under
# $BACKUP_ROOT/pre-update/ — a pool the GFS prune_backups never scans (it
# globs top-level timestamp dirs only), so scheduled retention is untouched.
# Retained by its own count-based prune_preupdate. Used by targeted
# `update <svc>`. No whole-croot space precheck (a single service tar is
# small); a failed tar still fails loud below.
preupdate_backup() {
    local broot croot dest ts s rc=0
    broot=$(env_get BACKUP_ROOT); croot=$(env_get CONFIG_ROOT)
    ts=$(ts_now); dest="$broot/pre-update/$ts.partial"; sudo mkdir -p "$dest"   # renamed once complete (see cmd_backup)
    info "Pre-update restore point (scoped to: $*): ${dest%.partial}"

    # every container's image, members included (rollback pins them all)
    # shellcheck disable=SC2046  # a word list of services
    point_record "$dest" update-scoped "" $(svc_shard "$@")

    local src
    for s in "$@"; do
        info "snapshotting $s (only this service stops)..."
        # its shard stops with it: a consistent database
        src=0; stopped_run "pre-update restore point ($s)" "$(svc_shard "$s" | tr '\n' ' ')" preupdate_snapshot "$croot" "$dest" "$s" || src=$?
        case $src in
            0) ;;
            "$BACKUP_PARTIAL") rc=1 ;;
            *) die "Pre-update restore point stopped early (exit $src) — $s was started again; nothing was kept, nothing updated." ;;
        esac
    done
    sudo cp "$ENV_FILE" "$dest/env"; sudo chmod 600 "$dest/env"
    if [[ -s "$PINS_FILE" ]]; then sudo cp "$PINS_FILE" "$dest/pins.yml"; fi
    point_private "$dest" || die "could not make the pre-update point private — nothing updated."
    ( cd "$dest" && sudo sh -c 'sha256sum * > SHA256SUMS' )
    if (( rc == 0 )); then sudo mv "$dest" "${dest%.partial}"; ok "Pre-update restore point complete: ${dest%.partial}"
    else
        notify ops "Mediastack pre-update backup FAILED" "Scoped restore point \`$dest\` finished with errors — **do not trust it**. Inspect on the host; the next one removes it." failure
        die "Pre-update backup finished WITH ERRORS — $dest is kept for inspection, never restored from, and removed by the next one."
    fi
    prune_preupdate
}

preupdate_snapshot() { # preupdate_snapshot CROOT DEST SVC — runs with SVC's shard stopped; -> 0, or BACKUP_PARTIAL
    local croot=$1 dest=$2 s=$3
    [[ -d "$croot/$s" ]] || return 0
    # same transcode exclude as the full backup (canonical: backup_snapshot)
    sudo tar -C "$croot" --exclude="$s/data/transcodes" -czf "$dest/$s.tar.gz" "$s" || { fail "tar failed for $s"; return "$BACKUP_PARTIAL"; }
}

# Pre-update pool retention: keep the newest BACKUP_KEEP_PREUPDATE scoped
# points, prune the rest. Independent of the GFS prune_backups; only ever
# touches $BACKUP_ROOT/pre-update/.
prune_preupdate() {
    local broot keep pud d n=0 pruned=0
    broot=$(env_get BACKUP_ROOT); keep=$(env_get BACKUP_KEEP_PREUPDATE 3)
    pud="$broot/pre-update"; [[ -d "$pud" ]] || return 0
    prune_partial "$pud"
    local -a all=()
    for d in "$pud"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]; do
        [[ -d "$d" ]] && all+=("$(basename "$d")")
    done
    (( ${#all[@]} )) || return 0
    mapfile -t all < <(printf '%s\n' "${all[@]}" | sort -r)
    for d in "${all[@]}"; do
        n=$((n+1)); (( n <= keep )) && continue
        sudo rm -rf "${pud:?}/$d"; pruned=$((pruned+1))
    done
    ok "pre-update points: kept $(( ${#all[@]} - pruned )), pruned $pruned (BACKUP_KEEP_PREUPDATE=$keep)"
}

cmd_backup_verify() {
    load_env
    local broot t="${1:-}"
    broot=$(env_get BACKUP_ROOT)
    [[ -n "$t" ]] || t=$(latest_restore_point)
    [[ -n "$t" && -d "$broot/$t" ]] || die "No restore point '${t:-(none yet)}' under $broot"
    ( cd "$broot/$t" && sudo sha256sum -c SHA256SUMS ) && ok "Checksums OK for $t"
    local f; for f in "$broot/$t"/*.tar.gz; do
        sudo tar -tzf "$f" >/dev/null || die "Corrupt archive: $f"
    done
    ok "Archives readable. (True proof is a restore drill: restore --service <svc>.)"
}

# ------------------------------------------------- restore / rollback / pin --
pin_service() { # pin_service svc image_ref
    mkdir -p "$LOCAL_DIR"; repo_owned "$LOCAL_DIR"
    touch "$PINS_FILE"; repo_owned "$PINS_FILE"
    grep -q '^services:' "$PINS_FILE" || echo "services:" > "$PINS_FILE"
    if grep -q "^  $1:" "$PINS_FILE"; then
        # replace the image line following the service key
        sudo sed -i "/^  $1:/,/image:/ s|image:.*|image: $2|" "$PINS_FILE"
    else
        printf '  %s:\n    image: %s\n' "$1" "$2" >> "$PINS_FILE"
    fi
    repo_owned "$PINS_FILE"
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
    local tsglob='[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]'
    if [[ -z "$from" ]]; then
        if [[ -n "$svc" ]]; then
            # rollback: newest point covering this service across BOTH pools —
            # the scoped pre-update point is the exact pre-update state, so it
            # wins over an older nightly full when it's newer. $from carries the
            # $broot-relative path (may be "pre-update/<ts>").
            from=$( { for d in "$broot"/pre-update/$tsglob "$broot"/$tsglob; do
                        [[ -d "$d" && -f "$d/$svc.tar.gz" ]] && printf '%s\t%s\n' "$(basename "$d")" "${d#"$broot"/}"
                     done; } | sort -r | head -1 | cut -f2 )
        else
            # full restore: newest GFS point only — never a partial pre-update one
            from=$(latest_restore_point)
        fi
    fi
    if [[ -z "$from" || ! -d "$broot/$from" ]]; then
        local avail="" d
        for d in "$broot"/$tsglob; do [[ -d "$d" ]] && avail+="$(basename "$d") "; done
        die "No restore point found. Available: $avail"
    fi
    info "Restoring from $from"
    local targets; if (( all_svcs )); then targets=$(svc_managed); else targets="$svc"; fi
    local croot ts s ref
    croot=$(env_get CONFIG_ROOT); ts=$(ts_now)
    local m
    for s in $targets; do
        svc_exists "$s" || die "No service '$s'."
        # shellcheck disable=SC2046  # the shard stops together (its data is one folder)
        DC stop $(svc_shard "$s") >/dev/null
        if [[ -f "$broot/$from/$s.tar.gz" ]]; then
            [[ -d "$croot/$s" ]] && sudo mv "$croot/$s" "$croot/$s.pre-restore.$ts"
            sudo tar -C "$croot" -xzf "$broot/$from/$s.tar.gz"
            ok "$s config restored (previous kept at $s.pre-restore.$ts)"
        fi
        for m in $(svc_shard "$s"); do
            ref=$(awk -v s="$m" '$1==s{print $2}' "$broot/$from/images.lock" 2>/dev/null || true)
            [[ -n "$ref" ]] && pin_service "$m" "$ref"
        done
        RENDERED_JSON=""
        DC up -d "$s"
    done
    ok "Restore done. Verify with: ./mediastack.sh status"
}

# rollback returns a service to the image that ran before its current one —
# the newest restore point holding a different image (a second rollback
# undoes the first); --from picks any point instead. Its config goes back
# with the image (a newer version may have upgraded its data), so it shows
# what it will do and asks first; --yes is for the panel and scripts.
cmd_rollback() {
    local usage="usage: rollback <svc> [--from TS] [--yes]" svc="" from="" yes=0
    while (( $# )); do case "$1" in
        --from) [[ -n "${2:-}" ]] || die "$usage"; from=$2; shift 2 ;;
        --yes)  yes=1; shift ;;
        -*)     die "Unknown rollback arg '$1' ($usage)" ;;
        *)      [[ -z "$svc" ]] || die "$usage"; svc=$1; shift ;;
    esac; done
    [[ -n "$svc" ]] || die "$usage"
    load_env
    svc_exists "$svc" || die "No service '$svc'."
    local broot run rel ts
    broot=$(env_get BACKUP_ROOT)
    c_inspect_all; run=$(svc_digest "$svc")
    if [[ -n "$from" ]]; then
        rel=$(point_resolve "$broot" "$from") || die "No restore point '$from' under $broot — see: ./mediastack.sh backup list $svc"
        [[ -f "$broot/$rel/$svc.tar.gz" ]] || die "Restore point '$from' does not hold $svc — see: ./mediastack.sh backup list $svc"
    else
        [[ -n "$run" ]] || die "rollback: cannot tell which image $svc runs (is it up?) — pick a point: ./mediastack.sh backup list $svc, then: rollback $svc --from <ts>"
        rel=$(rollback_target "$broot" "$svc" "$run") || die "No restore point holds an earlier image of $svc than the one it runs.
  To run a specific version instead: ./mediastack.sh update $svc --to <tag>
  That changes only the image: an older version may not read data a newer one
  upgraded — if it fails, 'rollback $svc' returns to the point update takes first."
    fi
    ts=${rel#pre-update/}
    local age; age=$(ts_age_hours "$ts") || age=""
    hr "rollback $svc"
    echo "  back to:     $(point_version "$broot/$rel" "$svc") (restore point $ts, $(point_kind "$broot/$rel" "$rel")${age:+, $(age_words "$age") old})"
    echo "  running now: $(running_version "$svc" "$run")"
    echo "  $svc's data since then — its settings, database, history — is replaced;"
    echo "  the current folder is kept as $svc.pre-restore.<now>. It stays on that"
    echo "  image until: ./mediastack.sh unpin $svc"
    if (( ! yes )); then
        [[ -t 0 ]] || die "rollback replaces $svc's data, so it asks first — run it in a terminal, or add --yes"
        confirm "Roll $svc back?" || { info "Nothing changed."; return 0; }
    fi
    cmd_restore --service "$svc" --from "$rel"
}

rollback_target() { # rollback_target BROOT SVC RUNNING-DIGEST -> the newest point (broot-relative) holding a different image; rc 1 if none
    local rel ref
    while read -r rel; do
        ref=$(awk -v s="$2" '$1==s {print $2}' "$1/$rel/images.lock" 2>/dev/null || true)
        [[ -n "$ref" && "$ref" != "$3" ]] && { echo "$rel"; return 0; }
    done < <(points_holding "$1" "$2")
    return 1
}

points_holding() { # points_holding BROOT [SVC] -> complete points (broot-relative), newest first, both pools; with SVC only those holding it
    local d tsglob='[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]'
    for d in "$1"/$tsglob "$1"/pre-update/$tsglob; do
        [[ -d "$d" ]] || continue
        [[ -z "${2:-}" || -f "$d/$2.tar.gz" ]] || continue
        printf '%s\t%s\n' "$(basename "$d")" "${d#"$1"/}"
    done | sort -r | cut -f2
}

point_resolve() { # point_resolve BROOT TS|pre-update/TS -> the point, broot-relative; rc 1 if none
    local p
    for p in "$2" "pre-update/$2"; do
        [[ "$p" =~ ^(pre-update/)?[0-9]{8}-[0-9]{6}$ && -d "$1/$p" ]] && { echo "$p"; return 0; }
    done
    return 1
}

point_kind() { # point_kind POINT REL -> its kind; a point from before meta: update-scoped in the scoped pool, else unknown
    local k; k=$(point_meta "$1" kind)
    [[ -n "$k" ]] && { echo "$k"; return 0; }
    [[ "$2" == pre-update/* ]] && echo update-scoped || echo unknown
}

point_version() { # point_version POINT SVC -> the version it holds (its digest when no version was recorded)
    local ver ref
    ver=$(awk -v s="$2" '$1==s {print $2}' "$1/meta" 2>/dev/null || true)
    ref=$(awk -v s="$2" '$1==s {print $2}' "$1/images.lock" 2>/dev/null || true)
    [[ -n "$ver" && "$ver" != - ]] || ver=$(digest_short "$ref")
    echo "${ver:-?}"
}

digest_short() { # digest_short REF -> sha256: and its first 12 hex digits (as docker shows it)
    local d=${1#*@}; echo "${d:0:19}"
}

running_version() { # running_version SVC DIGEST -> its version label, else the digest
    local v; v=$(c_version "$(svc_cname "$1")" || true)
    [[ -n "$v" ]] && echo "$v" || digest_short "$2"
}

age_words() { # age_words HOURS -> "5 hours" / "3 days"
    if (( $1 < 48 )); then echo "$1 hours"; else echo "$(( $1 / 24 )) days"; fi
}

# ------------------------------------------------------------------ update --
pin_shard_to() { # pin_shard_to <primary> <tag> — the primary, and every member released in lockstep with it
    # lockstep = the same tag today: authentik's worker, and its LDAP outpost (a
    # different image, but authentik requires the same release); its database
    # (postgres:16) keeps its own version
    local one="$1" to="$2" base tag m
    base=$(svc_image "$one" | cut -d: -f1); tag=$(svc_image "$one" | cut -s -d: -f2)
    for m in $(svc_members "$one"); do
        [[ -n "$tag" && "$(svc_image "$m" | cut -s -d: -f2)" == "$tag" ]] \
            && pin_service "$m" "$(svc_image "$m" | cut -d: -f1):$to"
    done
    pin_service "$one" "$base:$to"
}
jellyfin_sessions_active() {
    local key host; key=$(env_get JELLYFIN_API_KEY); host=$(jf_url)
    [[ -n "$key" ]] || return 1
    local n
    n=$(curl -fsS --max-time 5 -H "$(jf_auth_hdr "$key")" "$host/Sessions" 2>/dev/null \
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

    # one update or backup at a time: a timer's run waits, yours refuses
    if (( ! dry )); then
        if (( auto )); then
            maint_lock "the scheduled update" "$MAINT_WAIT" || {
                notify ops "Mediastack scheduled update skipped" "Another update or backup held the stack for $((MAINT_WAIT / 3600)) hours." failure
                die "Another update or backup held the stack for $((MAINT_WAIT / 3600)) hours — this scheduled update is skipped."
            }
        else
            maint_lock update 0
        fi
    fi
    # session deferral (auto runs only)
    if (( auto && ! now )); then defer_while_streaming update || return 0; fi

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
    # a shard updates as one: server and worker on the same version, its
    # database pulled with it (pins and health are checked per container)
    mapfile -t targets < <(svc_shard "${targets[@]}")

    if (( dry )); then
        hr "update --dry-run"
        for s in "${targets[@]}"; do
            local cn cur; cn=$(svc_cname "$s"); cur=$(c_version "$cn")
            echo "$s: would pull $( [[ -n "$to_tag" ]] && echo "$(svc_image "$s" | cut -d: -f1):$to_tag" || svc_image "$s" ) (currently ${cur:-unknown})"
        done
        return 0
    fi

    # Household (users) heads-up before the restore-point backup — only when this
    # run bounces a user-facing service (is_user_facing: the mediastack.user_facing
    # label, with a per-install set-user-facing override). Full update / gluetun
    # bounce the whole stack; a targeted update bounces only $one. Wording matches
    # the scope. The NOTIFY_GRACE pause is a courtesy that needs a live-session
    # check — only jellyfin has one — so it fires only when jellyfin is bounced.
    local ntitle="" nstart="" ndone="" notify_users=0 jf_affected=0 u
    if [[ -z "$one" || "$one" == gluetun ]]; then
        for u in $(svc_enabled_managed); do is_user_facing "$u" && { notify_users=1; break; }; done
        svc_enabled jellyfin && jf_affected=1
        ntitle="Mediastack maintenance"
        nstart="Scheduled maintenance is starting — services will restart briefly and anything you're watching or listening to will drop for a moment."
        ndone="Everything's back up. It can take a few minutes to fully warm up, so if something isn't loading yet, give it a moment."
    else
        is_user_facing "$one" && notify_users=1
        [[ "$one" == jellyfin ]] && jf_affected=1
        ntitle="${one^} maintenance"
        nstart="${one^} is restarting briefly for maintenance — back in a moment."
        ndone="${one^} is back up. It can take a few minutes to fully warm up, so if something isn't loading yet, give it a moment."
    fi
    if (( notify_users )); then
        notify_interruption "$ntitle" "$nstart"
        if (( jf_affected )) && jellyfin_sessions_active; then
            local grace; grace=$(env_get NOTIFY_GRACE 30)
            (( grace > 0 )) && { info "active stream(s) — warned users, pausing ${grace}s before maintenance"; sleep "$grace"; }
        fi
    fi

    # Targeted single-service update (not gluetun) → scoped pre-update point:
    # only that service stops, the rest of the stack stays up. Full updates and
    # gluetun keep the full stop-the-world restore point (gluetun cascades its
    # borrower recreate, so it can't be a single-service snapshot).
    if [[ -n "$one" && "$one" != gluetun ]]; then
        hr "Update: pre-update restore point (scoped to $one)"
        preupdate_backup "$one"
    else
        hr "Update: restore point first"
        backup_take update ""
    fi

    if [[ -n "$to_tag" ]]; then
        pin_shard_to "$one" "$to_tag"
        RENDERED_JSON=""
    fi

    # authentik takes its releases in order and never goes back: check the
    # step to what this run would start (a --to pin included) before pulling
    if printf '%s\n' "${targets[@]}" | grep -qx authentik; then
        RENDERED_JSON=""; authentik_release_check
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
    local bad=() b
    # Docker's verdict per updated service (wait_verdict: live re-inspect,
    # unhealthy / exited / boot-loop fail at once, capped by START_WAIT)
    wait_verdict "${targets[@]}" || for b in $VERDICT_BAD; do
        fail "$b ${VERDICT_WHY[$b]}"; bad+=("$b")
    done
    for s in "${targets[@]}"; do
        after=$(c_version "$(svc_cname "$s")")
        [[ "${before[$s]}" != "$after" ]] && changed+=("$s: ${before[$s]:-?} -> ${after:-?}")
    done
    # search functional probe: index must exist and be non-empty
    if svc_enabled jellysearch; then
        local docs
        # the key goes in on stdin: sudo logs every command line to the journal
        docs=$(printf '%s' "$(env_get MEILI_MASTER_KEY)" | sudo docker exec -i "$(svc_cname meilisearch)" sh -c \
               'k=$(cat); curl -fsS -H "Authorization: Bearer $k" http://127.0.0.1:7700/stats \
                || wget -qO- --header="Authorization: Bearer $k" http://127.0.0.1:7700/stats' \
               2>/dev/null | jq '[.indexes[].numberOfDocuments] | add // 0' || echo 0)
        (( docs > 0 )) && ok "search index: $docs documents" \
            || { warn "search index EMPTY after update — try 'docker restart $(svc_cname jellysearch)';"; warn "if it stays empty: ./mediastack.sh rollback jellyfin"; bad+=("jellysearch(index)"); }
    fi

    echo; hr "Update summary"
    (( ${#changed[@]} )) && printf '  %s\n' "${changed[@]}" || echo "  no version changes"
    if (( ${#bad[@]} )); then
        fail "Unhealthy after update: ${bad[*]}"
        echo "  Roll back any of them with: ./mediastack.sh rollback <service>"
        notify ops "Mediastack update FAILED" "Unhealthy after update: **${bad[*]}**"$'\n'"Roll back: \`./mediastack.sh rollback <service>\`" failure
        exit 1
    fi
    ok "All updated services healthy."
    printf '%s\n' "${targets[@]}" | grep -qx authentik && authentik_release_record
    (( notify_users )) && notify_interruption "$ntitle complete" "$ndone" success
    (( ${#changed[@]} )) && notify ops "Mediastack updated" "$(printf '`%s`\n' "${changed[@]}")" success

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
                            notify ops "Mediastack trash-sync FAILED" "Nightly TRaSH sync failed — updates themselves succeeded."$'\n'"Inspect: \`./mediastack.sh trash-sync\`" failure
                            exit 1; }
    fi
}

cmd_apply_timer() {
    load_env
    apply_timer mediastack-update "Mediastack update pipeline" "update --auto" UPDATE_SCHEDULE "Automatic updates"
    apply_timer mediastack-backup "Mediastack scheduled backup" "backup --auto" BACKUP_SCHEDULE "Automatic backups"
    apply_timer mediastack-manifest "Mediastack media manifest" "manifest" MANIFEST_SCHEDULE "Media manifest"
}

# apply_timer UNIT DESCRIPTION VERB SCHEDULE_VAR LABEL — install/refresh one
# oneshot service + timer from an OnCalendar value in .env; empty disables it
apply_timer() {
    local unit="$1" desc="$2" verb="$3" var="$4" label="$5" sched
    sched=$(env_get "$var")
    if [[ -z "$sched" ]]; then
        sudo systemctl disable --now "$unit.timer" 2>/dev/null || true
        ok "$label disabled ($var is empty)."
        return
    fi
    systemd-analyze calendar "$sched" >/dev/null 2>&1 || die "$var '$sched' is invalid (not a systemd OnCalendar expression)."
    timer_write "$unit" "$desc" "$verb" "$sched"
    ok "$label timer installed: $sched (next: $(systemctl show "$unit.timer" -p NextElapseUSecRealtime --value 2>/dev/null || echo '?'))"
}

timer_write() { # timer_write UNIT DESCRIPTION VERB ONCALENDAR — write, enable and start one oneshot service + timer
    local unit="$1" desc="$2" verb="$3" sched="$4"
    [[ "$unit" == mediastack-* ]] || die "timer_write: unit '$unit' must be named mediastack-* (the host-footprint registry owns that prefix)"
    sudo tee "$SYSTEMD_DIR/$unit.service" >/dev/null <<EOF
[Unit]
Description=$desc
[Service]
Type=oneshot
WorkingDirectory=$SCRIPT_DIR
ExecStart=$SCRIPT_DIR/mediastack.sh $verb
EOF
    sudo tee "$SYSTEMD_DIR/$unit.timer" >/dev/null <<EOF
[Unit]
Description=$desc (scheduled)
[Timer]
OnCalendar=$sched
Persistent=true
[Install]
WantedBy=timers.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now "$unit.timer"
}
