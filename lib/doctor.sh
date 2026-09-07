#!/usr/bin/env bash
# lib/doctor.sh — the audit: one _doctor_<section> per DOCTOR_SECTIONS entry,
# each reporting through ok/warn/info/d_fail into D_FAILS; cmd_doctor runs
# them, cmd_fix-perms repairs what the permissions section finds. Sourced by
# the entrypoint; relies on lib/common.sh and the entrypoint's
# service/render/inspect helpers at call time.

# ------------------------------------------------------------------ doctor --
D_FAILS=0
d_fail() { fail "$1"; printf '     why : %s\n     fix : %s\n' "$2" "$3"; D_FAILS=$((D_FAILS+1)); }

# --- doctor section checks (one helper per `hr "doctor: …"` block; each self-contained,
#     reporting via ok/warn/info/d_fail into the file-scope D_FAILS accumulator). ---
_doctor_environment() {
    hr "doctor: environment"
    local root
    for root in CONFIG_ROOT DATA_ROOT CACHE_ROOT BACKUP_ROOT; do
        [[ -n "$(env_get "$root")" ]] && ok "$root=$(env_get "$root")" \
            || d_fail "$root unset" "the stack cannot locate its files" "run: ./mediastack.sh configure"
    done
    local fs; fs=$(fstype_of "$(env_get CONFIG_ROOT)")
    [[ "$fs" =~ ^(nfs|nfs4|cifs|smb3)$ ]] \
        && d_fail "CONFIG_ROOT on $fs" "SQLite databases corrupt on network shares" "move configs to local disk (see docs/migration-existing.md)" \
        || ok "CONFIG_ROOT filesystem: $fs"
    require_mounts && ok "mount identity checks pass"

}

_doctor_containers() {
    hr "doctor: containers"
    local s cn st h
    local pending=()
    local -A rc0=()
    for s in $(svc_managed); do
        cn=$(svc_cname "$s"); st=$(c_state "$cn"); h=$(c_health "$cn")
        case "$st:$h" in
            running:healthy|running:-) ok "$s ($st${h:+, $h})" ;;
            running:starting) pending+=("$s"); rc0[$s]=$(c_restarts "$cn") ;;   # verdict deferred
            absent:*) if svc_enabled "$s"; then
                          d_fail "$s enabled but not running" "container was never created or was removed" "./mediastack.sh up"
                      else info "$s not enabled — skipped"; fi ;;
            *) d_fail "$s is $st/$h (restarts: $(c_restarts "$cn"))" "service is not serving" "./mediastack.sh logs $s   (then: rollback $s if a recent update broke it)" ;;
        esac
    done
    if (( ${#pending[@]} )); then
        info "${#pending[@]} service(s) in their startup window — waiting (up to 90s, shared)..."
        local deadline=$(( $(date +%s) + 90 )) rc_now still
        while (( ${#pending[@]} )) && (( $(date +%s) < deadline )); do
            sleep 5
            still=()
            for s in "${pending[@]}"; do
                cn=$(svc_cname "$s"); st=$(c_state "$cn"); h=$(c_health "$cn")
                rc_now=$(c_restarts "$cn")
                if (( rc_now > ${rc0[$s]} )) || [[ "$st" == restarting ]]; then
                    d_fail "$s is boot-looping (restarted $rc_now times)" "it starts, crashes, and restarts — it will never become healthy" "./mediastack.sh logs $s"
                elif [[ "$h" == healthy ]]; then ok "$s (running, healthy — came up during the wait)"
                elif [[ "$h" == starting ]]; then still+=("$s")
                elif [[ "$st" == running && "$h" == "-" ]]; then ok "$s (running)"
                else d_fail "$s is $st/$h" "service failed its startup" "./mediastack.sh logs $s"
                fi
            done
            pending=("${still[@]}")
        done
        for s in "${pending[@]}"; do
            d_fail "$s still not healthy after 90s (health: $(c_health "$(svc_cname "$s")"))" "startup is taking abnormally long or the healthcheck cannot pass" "./mediastack.sh logs $s"
        done
    fi

}

_doctor_ports() {
    hr "doctor: host ports"
    local found line
    # an evaluation error is UNCONFIRMED, never "no collisions"
    found=$(port_collisions) || { d_fail "host port audit could not run" "the rendered config could not be evaluated (jq's message above)" "run: ./mediastack.sh up — compose reports the config error"; return; }
    if [[ -z "$found" ]]; then ok "no host port published twice among enabled services"; return; fi
    while IFS= read -r line; do
        d_fail "host port collision: $line" "docker fails the second bind, so one of them cannot start" "set <SVC>_PORT=<free port> in .env for one of them (see docs/adding-a-service.md), then: ./mediastack.sh up"
    done <<<"$found"
}

_doctor_permissions() {
    hr "doctor: permissions"
    # Two independent questions, deliberately not conflated:
    #   1. Can the app write its own config? (the true invariant — probed live)
    #   2. Is anything mis-owned, and does it matter? (reported, tiered)
    # Ownership drift confined to regenerable paths (cache/logs/backups) is
    # expected for images that ignore PUID and run as root — their background
    # tasks (update checks, log rotation) write those files as root. That is a
    # WARN, not a FAIL. Drift in actual config files is a FAIL. The writable
    # probe decides real health regardless, and resolves the container's true
    # mount path (which is not always /config — e.g. kavita uses /kavita/config).
    local croot gid v uid s
    croot=$(env_get CONFIG_ROOT); gid=$(env_get MEDIA_GROUP_GID)
    # path segments whose ownership is cosmetic (regenerable, non-config)
    local ephemeral_re='/(cache|cache-long|logs?|te?mp|[Bb]ackups?)(/|$)'
    for s in $(svc_managed_where mediastack.config true); do
        v="$(uvar "$s")_UID"; uid=$(env_get "$v"); [[ -n "$uid" && -d "$croot/$s" ]] || continue

        # Ownership audit, tiered: split drift into config vs ephemeral.
        local misowned cfgbad="" ephbad="" f
        misowned=$(sudo find "$croot/$s" \( -not -user "$uid" -o -not -group "$gid" \) 2>/dev/null || true)
        if [[ -n "$misowned" ]]; then
            while IFS= read -r f; do
                [[ -z "$f" ]] && continue
                if [[ "${f#"$croot/$s"}" =~ $ephemeral_re ]]; then ephbad+="$f"$'\n'; else cfgbad+="$f"$'\n'; fi
            done <<<"$misowned"
        fi
        if [[ -n "$cfgbad" ]]; then
            d_fail "$s: config files not owned $uid:$gid" "the app cannot write its own config" "./mediastack.sh fix-perms $s"
        elif [[ -n "$ephbad" ]]; then
            warn "$s: $(grep -c . <<<"$ephbad") root-owned file(s) in cache/logs/backups — expected for a root-by-image app, cosmetic (clear with: ./mediastack.sh fix-perms $s)"
        fi

        # True invariant: can the app write its config? Probe live, from inside
        # the container, at its REAL mount path. This decides pass/fail; runs
        # regardless of ownership tier above (a config FAIL already fired if
        # warranted, but writability is the definitive check).
        local cn dest out rc
        cn=$(svc_cname "$s")
        if [[ $(c_state "$cn") == running ]]; then
            dest=$(c_get "$cn" "(.Mounts[]? | select(.Source==\"$croot/$s\") | .Destination)" | head -1)
            if [[ -n "$dest" ]]; then
                out=$(sudo docker exec "$cn" test -w "$dest" 2>&1) && rc=0 || rc=$?
                if (( rc == 0 )); then ok "$s config writable from inside the container"
                elif grep -q "executable file not found" <<<"$out"; then
                    info "$s: image has no probe tooling — writability unverified"
                else
                    d_fail "$s cannot write $dest from inside its container" "the app cannot persist settings" "./mediastack.sh fix-perms $s && ./mediastack.sh logs $s"
                fi
            else info "$s: config not bind-mounted in running container — skipped"; fi
        elif [[ -z "$cfgbad" ]]; then ok "$s config ownership OK (write probe skipped: not running)"; fi
    done
    # jellysearch must READ jellyfin's config
    if svc_enabled jellysearch; then
        local jcn jout jrc
        jcn=$(svc_cname jellysearch)
        if [[ $(c_state "$jcn") == running ]]; then
            jout=$(sudo docker exec "$jcn" test -r /config 2>&1) && jrc=0 || jrc=$?
            if (( jrc == 0 )); then ok "jellysearch can read jellyfin's config"
            elif grep -q "executable file not found" <<<"$jout"; then
                info "jellysearch: image has no probe tooling — skipped"
            else d_fail "jellysearch cannot read /config inside its container" "search cannot index" "./mediastack.sh fix-perms jellyfin"; fi
        else info "jellysearch not running — read probe skipped"; fi
    fi
    # artifact sweep
    [[ $(sudo find "$(env_get DATA_ROOT)" -maxdepth 2 -name '*{*}*' 2>/dev/null | wc -l) -gt 0 ]] \
        && warn "literal '{...}' directories under DATA_ROOT — junk from an old installer; safe to remove"
    [[ $(sudo find "$croot" -maxdepth 1 -name '*.pre-restore.*' 2>/dev/null | wc -l) -gt 0 ]] \
        && warn "old *.pre-restore.* trees under CONFIG_ROOT — remove once you trust the restore"

}

_doctor_resources() {
    hr "doctor: host resources"
    local croot; croot=$(env_get CONFIG_ROOT)
    df -h "$croot" "$(env_get DATA_ROOT)" "$(env_get CACHE_ROOT)" 2>/dev/null | tail -n +2 | sort -u | while read -r line; do
        local pct; pct=$(awk '{print $5}' <<<"$line" | tr -d %)
        (( pct >= 90 )) && warn "disk >90%: $line" || ok "disk: $line"
    done
    # transcodes on the config volume: Jellyfin's default until `wire jellyfin`
    # points it at /cache; a session that died leaves its segments behind
    local jt="$croot/jellyfin/data/transcodes" jmb
    if sudo test -d "$jt"; then
        jmb=$(sudo du -sm "$jt" 2>/dev/null | cut -f1)
        [[ -n "$jmb" ]] || jmb=UNKNOWN
        if [[ "$jmb" == UNKNOWN ]]; then
            warn "jellyfin transcodes: could not size $jt"
        elif (( jmb >= 1024 )); then
            warn "jellyfin: ${jmb}MB of transcode segments on the CONFIG volume ($jt) — './mediastack.sh wire jellyfin' moves transcodes to CACHE_ROOT; segments from a dead session clear when jellyfin restarts"
        else
            ok "jellyfin transcodes on the config volume: ${jmb}MB"
        fi
    fi
    local memfree l1 l5 l15 cores
    memfree=$(awk '/MemAvailable/{printf "%.1f", $2/1048576}' /proc/meminfo)
    read -r l1 l5 l15 _ < /proc/loadavg; cores=$(nproc)
    awk -v m="$memfree" 'BEGIN{exit !(m<1)}' && warn "available RAM low: ${memfree}G" || ok "available RAM: ${memfree}G"
    # Judge on the 5-min average: the 1-min figure spikes on every cold start
    # (container init is IO-heavy and Linux load counts IO-wait) and would
    # cry wolf exactly when people run doctor. Sustained 5-min > cores is
    # the real "this host is too small" signal.
    if awk -v l="$l5" -v c="$cores" 'BEGIN{exit !(l>c)}'; then
        warn "sustained load high: $l1 / $l5 / $l15 (1/5/15min) on $cores cores"
    else
        ok "load $l1 / $l5 / $l15 (1/5/15min) on $cores cores"
    fi

}

_doctor_storage() {
    hr "doctor: docker storage"
    local dtype dtot dact dsize drecl dpct
    while IFS='|' read -r dtype dtot dact dsize drecl; do
        case "$dtype" in
            Images)
                ok "images: $dtot on disk ($dsize), $dact in use by this host's containers"
                dpct=$(grep -oP '\(\K[0-9]+(?=%\))' <<<"$drecl" || echo 0)
                if (( dpct >= 30 )); then
                    info "  $drecl of image data is unused — reclaim with: sudo docker image prune -a  (keeps anything in use)"
                fi ;;
            Containers)
                if (( dtot > dact )); then
                    warn "stopped containers lingering: $(( dtot - dact )) — list with: sudo docker ps -a --filter status=exited"
                else
                    ok "containers: $dact running, none stopped/exited"
                fi ;;
            "Build Cache")
                [[ "$dsize" != "0B" ]] && info "build cache: $dsize — this stack builds nothing; reclaim with: sudo docker builder prune" ;;
        esac
    done < <(sudo docker system df --format '{{.Type}}|{{.TotalCount}}|{{.Active}}|{{.Size}}|{{.Reclaimable}}' 2>/dev/null)
    local dang
    dang=$(sudo docker volume ls -qf dangling=true 2>/dev/null | wc -l)
    if (( dang > 0 )); then
        info "orphaned anonymous volumes: $dang — empty leftovers from container recreates (all real state is bind-mounted). Clean: sudo docker volume prune -f"
    else
        ok "no orphaned volumes"
    fi

}

_doctor_neighbours() {
    hr "doctor: host neighbours"
    sudo docker ps --format '{{.Names}} {{.Image}}' | grep -Ei 'watchtower|ouroboros|autoheal' | grep -v mediastack \
        && warn "foreign auto-updater found on this host — it may update mediastack containers behind the backup system's back (our labels tell watchtower no; verify it honours them)" \
        || ok "no foreign auto-updaters"
    # docker subnet vs host routes overlap
    local net
    while read -r net; do
        [[ -z "$net" ]] && continue
        ip route | grep -vE 'dev (docker0|br-)' | grep -v "^default" | grep -q "^${net%.*}" \
            && warn "docker subnet $net overlaps a host route — containers may fail to reach the LAN/NAS. Fix: 'default-address-pools' in /etc/docker/daemon.json (restarts ALL containers on this host — do it in a window)."
    done < <(sudo docker network ls -q | xargs -r sudo docker network inspect \
             --format '{{range .IPAM.Config}}{{.Subnet}}{{println}}{{end}}' 2>/dev/null \
             | grep -oE '^[0-9.]+' || true)

}

_doctor_vpn_backups() {
    hr "doctor: vpn + backups"
    if [[ "$(c_state "$(svc_cname gluetun)")" == running ]]; then
        local dgid dnm dbad="" dchecked=0
        dgid=$(c_id "$(svc_cname gluetun)")
        for s in $(svc_managed_where mediastack.vpn true); do
            svc_enabled "$s" || continue
            [[ $(c_state "$(svc_cname "$s")") == running ]] || continue
            dnm=$(c_netmode "$(svc_cname "$s")")
            dchecked=1
            [[ "$dnm" == "container:$dgid" ]] || dbad+="$s "
        done
        if (( dchecked == 0 )); then info "no running VPN'd services to audit"
        elif [[ -z "$dbad" ]]; then ok "all VPN'd services routed through the gluetun tunnel"
        else d_fail "VPN'd services NOT attached to gluetun: $dbad" "their traffic bypasses the VPN entirely" "./mediastack.sh up   (recreates with correct attachment), then ./mediastack.sh leak-test"; fi
    fi
    if [[ "$(c_state "$(svc_cname gluetun)")" == running ]]; then
        local vip; vip=$(sudo docker exec "$(svc_cname gluetun)" wget -qO- --timeout=8 https://ipinfo.io/ip 2>/dev/null || true)
        [[ -n "$vip" ]] && ok "tunnel public IP: $vip" \
            || d_fail "cannot fetch IP through tunnel" "VPN may be down; downloads are dead (not leaking — kill-switch)" "./mediastack.sh logs gluetun"
    fi
    local last age broot; broot=$(env_get BACKUP_ROOT)
    last=$(ls -1 "$broot" 2>/dev/null | tail -1 || true)
    if [[ -n "$last" ]]; then
        age=$(( ( $(date +%s) - $(date -d "$(sed -E 's/([0-9]{8})-([0-9]{2})([0-9]{2}).*/\1 \2:\3/' <<<"$last")" +%s 2>/dev/null || date +%s) ) / 3600 ))
        (( age > 48 )) && warn "latest restore point is ${age}h old — run: ./mediastack.sh backup" || ok "latest restore point ${age}h old"
    else
        warn "no restore points yet — run: ./mediastack.sh backup"
    fi
    if grep -q "^TRASH_PROFILE_" .env 2>/dev/null; then
        if [[ -s cache/trash-last-sync ]]; then
            local tage=$(( ( $(date +%s) - $(cat cache/trash-last-sync) ) / 3600 ))
            local tsum=""
            [[ -s cache/trash-last-summary ]] && tsum=" — last run: $(cat cache/trash-last-summary)"
            (( tage > 26 )) && warn "TRaSH sync is ${tage}h old — run: ./mediastack.sh trash-sync" \
                            || ok "TRaSH sync ${tage}h old${tsum}"
        else
            warn "TRaSH configured but never synced — run: ./mediastack.sh trash-sync"
        fi
    fi
    if svc_enabled traefik && [[ -n "$(env_get TRAEFIK_DOMAIN)" ]]; then
        local acmef; acmef="$(env_get CONFIG_ROOT)/traefik/acme/acme.json"
        if sudo test -s "$acmef"; then
            [[ "$(sudo stat -c %a "$acmef")" == 600 ]] && ok "acme.json permissions 600" \
                || warn "acme.json is NOT mode 600 — traefik will refuse it; fix: sudo chmod 600 $acmef"
            if sudo grep -q "acme-staging" "$acmef"; then
                warn "STAGING certificates active — browsers will warn. For real use: set ACME_ENV=production in .env, then ./mediastack.sh up"
            else
                ok "production certificates in the store"
            fi
            sudo grep -q "\*.$(env_get TRAEFIK_DOMAIN)" "$acmef" \
                && ok "wildcard certificate present for *.$(env_get TRAEFIK_DOMAIN)" \
                || warn "no wildcard certificate for *.$(env_get TRAEFIK_DOMAIN) yet — check: logs traefik"
        else
            warn "traefik configured but no certificates issued yet — check: logs traefik"
        fi
    fi

}

_doctor_apps() {
    hr "doctor: apps"
    if svc_enabled jellyfin && [[ "$(c_state "$(svc_cname jellyfin)")" == running ]]; then
        local jpub
        jpub=$(curl -s -m 10 "$(jf_url)/System/Info/Public" 2>/dev/null || true)
        case "$(jq -r '.StartupWizardCompleted' <<<"$jpub" 2>/dev/null)" in
            true)  ok "jellyfin first-run wizard completed" ;;
            false) d_fail "jellyfin first-run wizard NOT completed" "an unclaimed jellyfin lets any visitor create the admin account" "./mediastack.sh wire jellyfin" ;;
            *)     warn "jellyfin public info unreadable — API may still be warming up" ;;
        esac
    fi
    if svc_enabled seerr && [[ "$(c_state "$(svc_cname seerr)")" == running ]]; then
        local spub
        spub=$(curl -s -m 10 "$(seerr_url)/api/v1/settings/public" 2>/dev/null || true)
        case "$(jq -r '.initialized' <<<"$spub" 2>/dev/null)" in
            true)  ok "seerr initialised" ;;
            false) warn "seerr not initialised yet — run: ./mediastack.sh wire seerr" ;;
            *)     warn "seerr public settings unreadable — API may still be warming up" ;;
        esac
    fi
    if svc_enabled wizarr && [[ "$(c_state "$(svc_cname wizarr)")" == running ]]; then
        local wkey wcode
        wkey=$(env_get WIZARR_API_KEY)
        if [[ -z "$wkey" ]]; then
            warn "wizarr has no stored API key — invites need it: ./mediastack.sh wire wizarr"
        else
            wcode=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -H "X-API-Key: $wkey" \
                    "$(wizarr_url)/api/invitations" 2>/dev/null || echo 000)
            [[ "$wcode" =~ ^2 ]] && ok "wizarr API key works ('invite' is ready)" \
                || d_fail "wizarr rejected the stored API key [HTTP $wcode]" "'invite' cannot mint links" "recreate the key in wizarr's Settings -> API Keys, then: ./mediastack.sh wire wizarr"
        fi
    fi

}

_doctor_runtime_audit() {
    hr "doctor: runtime audit"
    # per-service error volume, last 24h — noisy logs surface real problems
    local noisy=0 cnt
    for s in $(svc_enabled_managed); do
        cn=$(svc_cname "$s")
        [[ "$(c_state "$cn")" == running ]] || continue
        cnt=$(sudo docker logs --since 24h "$cn" 2>&1 | grep -ciE '\b(error|fatal)\b' || true)
        if (( cnt > 25 )); then
            warn "$s: $cnt error lines in 24h — inspect: ./mediastack.sh logs $s"
            noisy=$((noisy+1))
        fi
    done
    (( noisy == 0 )) && ok "log noise: every service under the error threshold (25/24h)"
    # effective UID: the process must actually run as the UID .env assigns —
    # PUID images silently ignore bad values, this catches that
    local expect uids drift=0
    for s in $(svc_enabled_managed); do
        cn=$(svc_cname "$s")
        [[ "$(c_state "$cn")" == running ]] || continue
        expect=$(env_get "$(uvar "$s")_UID")
        [[ -n "$expect" ]] || continue
        # docker's daemon locates the PID column via the ps TITLE row, so the
        # format must keep its headers; awk drops the title line
        uids=$(sudo docker top "$cn" -o uid,pid 2>/dev/null | awk 'NR>1{print $1}' | sort -u | tr '\n' ' ' || true)
        if [[ " $uids" == *" $expect "* ]]; then :; else
            warn "$s: no process runs as UID $expect (saw: ${uids:-none}) — PUID may be ignored; check: logs $s"
            drift=$((drift+1))
        fi
    done
    (( drift == 0 )) && ok "effective UIDs match the .env map"
    # qbit must be bound to the tunnel interface (wire sets it; verify here)
    if svc_enabled qbittorrent && [[ "$(c_state "$(svc_cname qbittorrent)")" == running ]]; then
        if qb_login "$(env_get QBITTORRENT_USER)" "$(env_get QBITTORRENT_PASSWORD)" 2>/dev/null; then
            local iface
            iface=$(qb_api /app/preferences | jq -r '.current_network_interface // .network_interface // empty' 2>/dev/null || true)
            [[ "$iface" == tun0 ]] && ok "qBittorrent transfers bound to tun0" \
                || warn "qBittorrent is NOT bound to tun0 (currently: '${iface:-unset}') — fix: ./mediastack.sh wire qbit"
        else
            warn "could not sign in to qBittorrent to verify the tun0 bind"
        fi
    fi

}

# doctor runs these in order; adding a section = append here + define
# _doctor_<name>. Mirrors WIRE_ROLES: one registry, no second list to sync.
DOCTOR_SECTIONS=(environment containers ports permissions resources storage neighbours vpn_backups apps runtime_audit)

cmd_doctor() {
    load_env; need_cmd jq; render
    # Sections are report-only: real problems are counted in D_FAILS, never
    # signalled by exit code. Under `set -e` a section whose last command is a
    # false `[[ ]] && warn` returns non-zero and would abort the whole audit at
    # a bare call, so the loop invokes every section non-fatally — in one
    # place, so a new section cannot forget it.
    local sec
    c_inspect_all   # in the parent scope: a daemon failure dies here, not inside a section's $( )
    for sec in "${DOCTOR_SECTIONS[@]}"; do "_doctor_$sec" || true; done
    echo
    if (( D_FAILS )); then
        fail "doctor: $D_FAILS problem(s) — fixes listed above."
        notify ops "Mediastack doctor: $D_FAILS problem(s)" "Run \`./mediastack.sh doctor\` on the host for the findings and fixes." failure
        exit 1
    else ok "doctor: all checks passed."; fi
}

cmd_fix_perms() {
    load_env
    local croot targets s v uid
    croot=$(env_get CONFIG_ROOT)
    targets="${1:-$(svc_managed)}"
    for s in $targets; do
        [[ $(svc_label "$s" mediastack.config) == "true" ]] || continue
        v="$(uvar "$s")_UID"; uid=$(env_get "$v"); [[ -n "$uid" && -d "$croot/$s" ]] || continue
        sudo chown -R "$uid:mediacenter" "$croot/$s"
        ok "$s -> $uid:mediacenter"
    done
}
