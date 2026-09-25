#!/usr/bin/env bash
# lib/lifecycle.sh — the host side of the stack's life: `install` (host
# dependencies), `add-mount` (guided NFS/SMB mount), `upgrade` (mediastack
# itself), `uninstall` and `nuke`. Sourced by the entrypoint; relies on
# lib/common.sh and the entrypoint's compose/service helpers at call time.

# --------------------------------------------------------------- install --
cmd_install() {
    hr "Host dependencies"
    [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release — unsupported OS."
    # shellcheck disable=SC1091
    source /etc/os-release
    case "${ID:-}" in
        debian|ubuntu) ok "Detected ${PRETTY_NAME}" ;;
        *) die "This installer supports Debian/Ubuntu (apt). Detected: ${PRETTY_NAME:-unknown}.
  Docker + compose v2.20+, jq, curl and git installed manually will also work." ;;
    esac
    local base_pkgs="curl git jq ca-certificates argon2 rsync"   # rsync: cross-filesystem root moves (configure)
    info "Installing base packages (${base_pkgs// /, })..."
    sudo apt-get update -qq
    # shellcheck disable=SC2086  # one package per word
    sudo apt-get install -y -qq $base_pkgs >/dev/null
    if ! command -v docker >/dev/null 2>&1; then
        info "Installing Docker from Docker's official repository..."
        sudo install -m 0755 -d /etc/apt/keyrings
        sudo curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
        sudo chmod a+r /etc/apt/keyrings/docker.asc
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
            | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
        sudo apt-get update -qq
        sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null
        ok "Docker installed"
    else
        ok "Docker already present: $(docker --version)"
    fi
    local cv min=2.24.0
    cv=$(sudo docker compose version --short 2>/dev/null || echo "0"); cv=${cv#v}
    ok "docker compose $cv"
    [[ "$(printf '%s\n%s\n' "$cv" "$min" | sort -V | head -n1)" == "$min" ]] \
        || warn "compose $cv < $min — 'include:'/wildcard profiles need $min+. Upgrade the compose plugin."
    echo; hr "Dependencies ready"
    cat <<'EOT'
Next step:   ./mediastack.sh configure

That's the guided setup. Every question explains itself and offers a
sensible default — pressing Enter through it gives a working stack.
It will ask about:
  * where configs, media, cache, transcodes and backups live (defaults are fine)
  * which services to run (a recommended set is offered)
  * your VPN — HAVE THIS READY: a NordVPN access token
    (nordvpn.com -> Services -> NordVPN -> "Set up NordVPN manually"),
    or your provider's WireGuard private key if not using Nord
  * when automatic updates should run

Takes about 5 minutes. Safe to re-run any time — your answers become
the new defaults.
EOT
}

# ----------------------------------------------------- upgrade/uninstall --
cmd_upgrade() {
    need_cmd git
    # second half, run by the freshly pulled script (see the hand-over below)
    if [[ -n "${MS_UPGRADE_FROM:-}" ]]; then upgrade_finish "$MS_UPGRADE_FROM"; return; fi
    # -uno: untracked files (like the .wired marker) are deployment state,
    # not a pull hazard — only tracked modifications block an upgrade.
    [[ -z "$(git status --porcelain -uno 2>/dev/null)" ]] || die "Working tree has local changes to tracked files.
  Mediastack keeps user state in .env / override files, so tracked files
  should be clean. Review 'git status', stash or move changes into
  docker-compose.override.yml, then retry."
    local before; before=$(git rev-parse HEAD)
    git pull --ff-only || die "git pull failed (diverged history?). Resolve manually."
    [[ "$before" == "$(git rev-parse HEAD)" ]] && { ok "Already up to date."; return; }
    hr "Changes pulled"; git log --oneline "$before..HEAD" | sed 's/^/  /'
    # Hand over: this process is still the code from before the pull, so it
    # knows neither the new migrations nor what the new definitions mean.
    # The pulled script finishes the job.
    MS_UPGRADE_FROM="$before" exec "$SCRIPT_DIR/mediastack.sh" upgrade
}

upgrade_finish() { # upgrade_finish <commit before the pull> — run by the pulled script
    local before="$1" changed pending
    load_env                 # schema migrations: this code knows the new ones
    provision >/dev/null || true
    vpn_gen >/dev/null       # the overlay from the pulled fragments — a stale one breaks every render (see cmd_up)
    changed=$(git diff --name-only "$before..HEAD") || die "upgrade: cannot compare $before with HEAD"
    # say what (if anything) the pull requires — images are never part of an
    # upgrade, so they are never mentioned here (that's: update, nightly)
    pending=$(compose_pending)
    if [[ -n "$pending" ]]; then
        ok "Upgrade complete. Apply with ./mediastack.sh up — it changes: $(paste -sd' ' <<<"$pending")"
    elif grep -qE '^(mediastack\.sh|lib/)' <<<"$changed"; then
        ok "Upgrade complete. New tooling is live — nothing to apply."
    else
        ok "Upgrade complete. Docs/templates only — nothing to apply."
    fi
}

compose_pending() { # the services `up` would change — Compose's own dry run of it
    # `--dry-run up` runs up's real convergence logic and touches nothing. Each
    # container prints one progress line per step; an unchanged one only says
    # Running (or Waiting/Healthy while its dependencies are checked). What
    # counts: Recreate (definition changed), Create (new), Remov… (disabled or
    # gone), Start (stopped). Comparing config-hash labels instead was tried and
    # failed live: services in gluetun's namespace never match a fresh render.
    local out s act
    local -A seen=()
    out=$(DC --dry-run up -d --remove-orphans 2>&1) || die "compose dry run failed — $(oneline "$out")"
    while read -r s act; do
        case "${seen[$s]:-}:$act" in              # one verdict per service, strongest first
            *:Recreate)            seen[$s]=Recreate ;;
            Recreate:*)            ;;
            *:Create)              seen[$s]=Create ;;
            Create:*)              ;;
            *:Remove)              seen[$s]=Remove ;;
            Remove:*)              ;;
            *:Start)               seen[$s]=Start ;;
        esac
    done < <(sed -nE 's/^ *Container mediastack-([^ ]+) (Recreat|Creat|Remov|Start)[a-z]*$/\1 \2/p' <<<"$out" \
             | sed -E 's/ Recreat$/ Recreate/; s/ Creat$/ Create/; s/ Remov$/ Remove/')   # stems: every tense Compose prints
    for s in "${!seen[@]}"; do
        case "${seen[$s]}" in
            Recreate) echo "$s" ;;
            Create)   echo "$s (new)" ;;
            Remove)   echo "$s (removed)" ;;
            Start)    echo "$s (stopped)" ;;
        esac
    done | sort
}

cmd_nuke() {
    # Deliberately does NOT need a working compose render or .env — it must
    # succeed on a half-deleted deployment. Containers are found by compose
    # project label; users by the mediacenter group in /etc/passwd.
    hr "NUKE: remove everything the installer created"
    echo "Removes: containers, docker network, systemd units,"
    echo "         service users + group, CONFIG_ROOT, CACHE_ROOT, TRANSCODE_ROOT."
    echo "Keeps  : DATA_ROOT (your media), BACKUP_ROOT (restore points),"
    echo "         .env, this repo folder, and pulled docker images (shared"
    echo "         cache — 'docker image prune -a' reclaims them)."
    echo "Running containers are stopped and removed by this command — no"
    echo "need to stop anything first. (Just never skip this and rm -rf the"
    echo "folder instead: running containers resurrect their mount dirs.)"
    local really; read -r -p "Type 'nuke mediastack' to proceed: " really
    [[ "$really" == "nuke mediastack" ]] || { info "Aborted — nothing touched."; return 1; }

    systemd_units_teardown
    frontdoor_teardown
    ok "systemd units removed"
    sudo docker ps -aq --filter "label=com.docker.compose.project=mediastack" \
        | xargs -r sudo docker rm -f -v >/dev/null
    # shellcheck disable=SC2034  # the inspect cache lives in the entrypoint (CACHE RULE at c_inspect)
    INSPECT_JSON=""
    ok "containers removed (with their anonymous volumes)"
    rm -f "$PINS_FILE"
    sudo docker network rm mediastack >/dev/null 2>&1 && ok "network removed" || true

    local gid u
    gid=$(getent group mediacenter | cut -d: -f3 || true)
    if [[ -n "$gid" ]]; then
        for u in $(awk -F: -v g="$gid" '$4==g{print $1}' /etc/passwd); do
            sudo userdel "$u" 2>/dev/null && ok "user $u removed"
        done
        sudo groupdel mediacenter 2>/dev/null && ok "group mediacenter removed"
    fi

    local croot cache tcode
    croot=$(env_get CONFIG_ROOT "$SCRIPT_DIR/config")
    cache=$(env_get CACHE_ROOT "$SCRIPT_DIR/cache")
    tcode=$(env_get TRANSCODE_ROOT "$SCRIPT_DIR/transcodes")
    sudo rm -rf "$croot" "$cache" "$tcode"
    ok "removed $croot, $cache and $tcode"
    local inside=""
    [[ "$(env_get DATA_ROOT "$SCRIPT_DIR/data")" == "$SCRIPT_DIR/"* ]] && inside+="media ($(env_get DATA_ROOT "$SCRIPT_DIR/data")) "
    [[ "$(env_get BACKUP_ROOT "$SCRIPT_DIR/backups")" == "$SCRIPT_DIR/"* ]] && inside+="backups ($(env_get BACKUP_ROOT "$SCRIPT_DIR/backups")) "
    if [[ -n "$inside" ]]; then
        ok "Nuked. Media and backups untouched."
        warn "Still INSIDE this folder: ${inside}— move them out before deleting it."
    else
        ok "Nuked. Media and backups untouched. Safe to delete this folder now."
    fi
}

systemd_units_teardown() { # every mediastack unit except the front door's (frontdoor_teardown)
    local u
    for u in mediastack-update.timer mediastack-manifest.timer mediastack-vpnguard.service; do
        sudo systemctl disable --now "$u" 2>/dev/null || true
    done
    sudo rm -f /etc/systemd/system/mediastack-update.{service,timer} \
               /etc/systemd/system/mediastack-manifest.{service,timer} \
               /etc/systemd/system/mediastack-vpnguard.service
    sudo systemctl daemon-reload
}

cmd_uninstall() {
    if [[ "${1:-}" == --nuke ]]; then cmd_nuke; return; fi
    load_env
    hr "Uninstall (tiered)"
    echo "Tier 1: remove containers + docker network (configs, data, users kept)"
    confirm "Proceed with tier 1?" || return 0
    DC down --remove-orphans --volumes; ok "containers removed (anonymous volumes included)"
    systemd_units_teardown
    frontdoor_teardown
    echo; echo "Tier 2: remove the service system users + group"
    if confirm "Also remove users/group?"; then
        local s; for s in $(svc_managed); do sudo userdel "$s" 2>/dev/null || true; done
        sudo groupdel mediacenter 2>/dev/null || true; ok "users removed"
    fi
    echo; echo "Tier 3: DELETE ALL SERVICE CONFIGS at $(env_get CONFIG_ROOT) — irreversible."
    local really; read -r -p "Type 'delete my configs' to proceed (anything else skips): " really
    if [[ "$really" == "delete my configs" ]]; then
        sudo rm -rf "$(env_get CONFIG_ROOT)"; ok "configs deleted"
    else info "Configs kept."; fi
    ok "Uninstall finished. Media in DATA_ROOT and backups in BACKUP_ROOT were never touched."
}

cmd_add_mount() {
    explain "Add a host mount (NFS / SMB)" \
"Sets up a network share on THIS host the safe way:
  * /etc/fstab entry with systemd automount — boot never hangs on the NAS,
    the share attaches on first access and survives NAS reboots.
  * 'hard' mount — apps wait out a NAS blip instead of corrupting writes.
  * poison layer — the empty mountpoint is made immutable, so if the share
    is ever down, writes FAIL LOUDLY instead of silently filling your
    system disk behind the mount.
The share itself (NFS export / SMB share on the NAS) must already exist —
server-side setup is out of scope here."
    local mtype remote mpoint
    while true; do
        ask MOUNT_TYPE "Share type (nfs/cifs)" "nfs"
        mtype="$REPLY_VAL"; [[ "$mtype" == nfs || "$mtype" == cifs ]] && break
        fail "Answer 'nfs' or 'cifs' (cifs = SMB/Samba/Windows share)."
    done
    if [[ "$mtype" == nfs ]]; then
        explain "Remote path" "NFS form:  server:/export/path   e.g. 192.168.1.50:/volume1/media"
    else
        explain "Remote path" "SMB form:  //server/share        e.g. //192.168.1.50/media"
    fi
    ask MOUNT_REMOTE "Remote" ""
    remote="$REPLY_VAL"; [[ -n "$remote" ]] || die "Remote path is required."
    ask MOUNT_POINT "Local mountpoint (e.g. /mnt/media)" ""
    mpoint=$(abspath "${REPLY_VAL:?mountpoint required}")
    grep -qsE "[[:space:]]${mpoint}[[:space:]]" /etc/fstab \
        && die "$mpoint already has an fstab entry. Edit /etc/fstab manually or pick another path."
    findmnt -rn "$mpoint" >/dev/null 2>&1 && die "$mpoint is already a mountpoint."

    if [[ "$mtype" == nfs ]]; then
        info "Installing nfs-common..."
        sudo apt-get install -y -qq nfs-common >/dev/null
    else
        info "Installing cifs-utils..."
        sudo apt-get install -y -qq cifs-utils >/dev/null
    fi

    sudo mkdir -p "$mpoint"
    [[ -z "$(sudo ls -A "$mpoint")" ]] || die "$mpoint is not empty — mounting would hide its contents. Move them first."
    sudo chattr +i "$mpoint" 2>/dev/null \
        && ok "poison layer set (mountpoint immutable while unmounted)" \
        || warn "filesystem does not support chattr +i — poison layer skipped"

    local opts fsline
    if [[ "$mtype" == nfs ]]; then
        opts="_netdev,x-systemd.automount,hard,nfsvers=4.2,nofail"
        fsline="$remote $mpoint nfs4 $opts 0 0"
    else
        local smbuser smbpass credfile gid
        ask SMB_USER "SMB username" ""
        smbuser="$REPLY_VAL"
        read -r -s -p "SMB password: " smbpass; echo
        credfile="/etc/mediastack-cifs-$(basename "$mpoint")"
        printf 'username=%s\npassword=%s\n' "$smbuser" "$smbpass" | sudo tee "$credfile" >/dev/null
        sudo chmod 600 "$credfile"
        ok "credentials stored at $credfile (root-only)"
        gid=$( [[ -f "$ENV_FILE" ]] && env_get MEDIA_GROUP_GID 13000 || echo 13000 )
        # SMB has no POSIX ownership: map files to the shared media group.
        opts="_netdev,x-systemd.automount,hard,nofail,credentials=$credfile,uid=0,gid=$gid,file_mode=0664,dir_mode=2775,iocharset=utf8"
        fsline="$remote $mpoint cifs $opts 0 0"
    fi
    echo "$fsline" | sudo tee -a /etc/fstab >/dev/null
    ok "fstab entry written"
    sudo systemctl daemon-reload
    if sudo mount "$mpoint" 2>/dev/null && findmnt -rn "$mpoint" >/dev/null; then
        ok "$mpoint mounted from $remote"
        info "Use this path in './mediastack.sh configure' — the wizard will record and guard it."
    else
        fail "Mount FAILED. The fstab entry is kept (it is boot-safe: nofail+automount).
  Check: server reachable? export/share name right? credentials right?
  Retry with: sudo mount '$mpoint'
  Or remove the line from /etc/fstab to abandon it."
        exit 1
    fi
}
