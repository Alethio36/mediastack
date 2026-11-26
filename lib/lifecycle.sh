#!/usr/bin/env bash
# lib/lifecycle.sh — the host side of the stack's life: `install` (host
# dependencies), `add-mount` (guided NFS/SMB mount), `upgrade` (mediastack
# itself), `uninstall` and `nuke`. Sourced by the entrypoint; relies on
# lib/common.sh and the entrypoint's compose/service helpers at call time.

# --------------------------------------------------------------- install --
leak_tools_install() { # leak-test reads the host's traffic: conntrack (flows), tcpdump (a probe's packets)
    local p need=()
    for p in $LEAK_TOOLS; do
        if host_pkg_installed "$p"; then
            host_pkg_ours "$p" || info "$p already on this host — yours: uninstall keeps it"
        else need+=("$p"); fi
    done
    (( ${#need[@]} )) || return 0
    info "Installing leak-test's tools (${need[*]})..."
    sudo apt-get install -y -qq "${need[@]}" >/dev/null || die "apt could not install ${need[*]} (its error is above)."
    for p in "${need[@]}"; do host_pkg_mark "$p"; done
    ok "${need[*]} installed — uninstall removes them again"
}

cmd_install() { # install [--answers FILE] [--domain D] [--services a,b] [--signin X] — the host's dependencies, then configure (with the answers, it asks nothing)
    answers_opts "$@"
    (( ${#ANSWERS_REST[@]} == 0 )) || die "unknown argument '${ANSWERS_REST[0]}' for 'install' (accepts: --answers FILE, --domain D, --services a,b, --signin none|wizarr|authentik)"
    sudo_unattended_check
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
    leak_tools_install
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
    [[ "$(printf '%s\n%s\n' "$cv" "$min" | sort -V | sed -n 1p)" == "$min" ]] \
        || warn "compose $cv < $min — 'include:'/wildcard profiles need $min+. Upgrade the compose plugin."
    echo; hr "Dependencies ready"
    cat <<'EOT'
Next: ./mediastack.sh configure — the guided setup. Quick (the default) asks
only what has no sensible default: which services, how people sign in, and
your VPN — HAVE THIS READY: a NordVPN access token (nordvpn.com -> Services
-> NordVPN -> "Set up NordVPN manually"), or your provider's WireGuard key
or OpenVPN login (some also give a certificate file), or your own config file.
With HTTPS: your domain and its Cloudflare token. Then it starts everything,
connects the apps and checks the result (~15-20 min on a first run).
EOT
    # install carries on into configure (docs/design-install.md, "The flow"); answers given: without asking
    if (( ${#ANSWERS_OPTS[@]} )); then
        echo; exec bash "$SCRIPT_DIR/mediastack.sh" configure "${ANSWERS_OPTS[@]}"
    fi
    if [[ -t 0 ]] && confirm_yes "Configure now?"; then
        echo; exec bash "$SCRIPT_DIR/mediastack.sh" configure
    fi
}

# ----------------------------------------------------- upgrade/uninstall --
cmd_upgrade() {
    need_cmd git
    # second half, run by the freshly pulled script (see the hand-over below)
    if [[ -n "${MS_UPGRADE_FROM:-}" ]]; then upgrade_finish "$MS_UPGRADE_FROM"; return; fi
    # -uno: untracked files (.env, custom/, local/) are deployment state,
    # not a pull hazard — only tracked modifications block an upgrade.
    [[ -z "$(git status --porcelain -uno 2>/dev/null)" ]] || die "Working tree has local changes to tracked files.
  Mediastack keeps your state in .env and custom/, so tracked files
  should be clean. Review 'git status', stash or move changes into
  custom/ (docs/adding-a-service.md), then retry."
    # never mid-update, -backup or -wire: a pull landing inside a running update
    # once mixed old and new code in one run. Held across the hand-over (fd 8
    # survives exec), so the pulled script finishes inside the same hold.
    maint_lock upgrade 0
    local before; before=$(git rev-parse HEAD)
    git pull --ff-only || die "git pull failed (diverged history?). Resolve manually."
    [[ "$before" == "$(git rev-parse HEAD)" ]] && { ok "Already up to date."; return; }
    hr "Changes pulled"; git log --oneline "$before..HEAD" | sed 's/^/  /'
    # Hand over: this process is still the code from before the pull, so it
    # knows neither the new migrations nor what the new definitions mean.
    # The pulled script finishes the job.
    MS_UPGRADE_FROM="$before" MAINT_LOCKED=1 exec "$SCRIPT_DIR/mediastack.sh" upgrade
}

# ---- is mediastack itself behind its branch? (SCRIPT_UPDATES; roadmap, MVP step 7) ----
# The update run pulls images, never the script, so an install nobody
# upgrades runs new app versions with old wiring (Jellyfin 12 broke wire that
# way) and nothing said an upgrade existed. A fetch, never a pull: doctor
# says how far behind, and the update run tells ops once per new tip.
SCRIPT_FETCH_TIMEOUT=60   # seconds: a fetch that hangs must not hold the update run
script_git() { # script_git ARGS... — git in this repo, as the repo's owner, never asking
    # A root run (a timer, the panel) fetching as root would leave .git files
    # the owner's own pull cannot write. No prompt either: an unattended run
    # has nobody to type a passphrase, so a remote that wants one fails loud.
    local own; own=$(stat -c %u "$SCRIPT_DIR")
    local -a run=(env GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="ssh -o BatchMode=yes" timeout "$SCRIPT_FETCH_TIMEOUT" git -C "$SCRIPT_DIR")
    if (( $(id -u) == 0 && own != 0 )); then
        run=(setpriv --reuid="$own" --regid="$(stat -c %g "$SCRIPT_DIR")" --clear-groups
             env HOME="$(getent passwd "$own" | cut -d: -f6)" "${run[@]:1}")
    fi
    "${run[@]}" "$@"
}

# shellcheck disable=SC2034  # SB_AHEAD is read by doctor (lib/doctor.sh)
script_behind() { # -> SB_STATE current|behind|off|unknown, SB_UP (origin/stable), SB_N behind, SB_AHEAD, SB_TIP, SB_LOG (newest five), SB_WHY (unknown: why)
    local remote branch out
    SB_STATE=unknown SB_UP="" SB_N=0 SB_AHEAD=0 SB_TIP="" SB_LOG="" SB_WHY=""
    [[ "$(env_get SCRIPT_UPDATES)" != off ]] || { SB_STATE=off; return 0; }
    SB_UP=$(script_git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) \
        || { SB_WHY="this checkout follows no branch — set one: git -C $SCRIPT_DIR branch -u origin/stable"; return 0; }
    remote=${SB_UP%%/*} branch=${SB_UP#*/}
    out=$(script_git fetch --quiet "$remote" "$branch" 2>&1) \
        || { SB_WHY="git fetch $remote $branch failed: $(oneline "$out") — an unattended run cannot type a key's passphrase; a public https remote needs none (git -C $SCRIPT_DIR remote -v)"; return 0; }
    SB_N=$(script_git rev-list --count "HEAD..$SB_UP") && SB_AHEAD=$(script_git rev-list --count "$SB_UP..HEAD") \
        && SB_TIP=$(script_git rev-parse --short "$SB_UP") \
        || { SB_WHY="git could not compare this checkout with $SB_UP"; return 0; }
    if (( SB_N == 0 )); then SB_STATE=current; return 0; fi
    SB_STATE=behind
    SB_LOG=$(script_git log --oneline --no-decorate -5 "HEAD..$SB_UP")
}

script_behind_tell_ops() { # the update run: ops hears of new mediastack commits once per new tip, and once of a check that cannot run
    script_behind
    case $SB_STATE in
        behind)
            if [[ "$(state_get script-behind-told)" == "$SB_TIP" ]]; then
                info "mediastack is $SB_N commit(s) behind $SB_UP — ops was told of $SB_TIP already"
            else
                local more=""; (( SB_N > 5 )) && more=$'\n'"…and $(( SB_N - 5 )) more"
                notify ops "An upgrade is available" "$SB_N new commit(s) on \`$SB_UP\`:"$'\n'"$(sed 's/^/`/; s/$/`/' <<<"$SB_LOG")$more"$'\n'"Upgrade on the host: \`./mediastack.sh upgrade\`" info
                state_set script-behind-told "$SB_TIP"
                info "mediastack is $SB_N commit(s) behind $SB_UP — ops told (upgrade: ./mediastack.sh upgrade)"
            fi
            state_del script-check-failed ;;
        current) ok "mediastack is current with $SB_UP"; state_del script-behind-told; state_del script-check-failed ;;
        unknown)
            warn "mediastack could not check its branch: $SB_WHY"
            [[ -n "$(state_get script-check-failed)" ]] \
                || notify ops "Cannot check for upgrades" "$SB_WHY" warning
            state_set script-check-failed 1 ;;
        off) ;;
    esac
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
    # the portal's setup files reach authentik at `up` (authentik_prepare), its flows at `wire authentik`
    local portal=0
    svc_enabled authentik && grep -qE '^services/authentik/(blueprints|templates)/' <<<"$changed" && portal=1
    if [[ -n "$pending" ]]; then
        ok "Upgrade complete. Apply with ./mediastack.sh up — it changes: $(paste -sd' ' <<<"$pending")"
        if (( portal )); then info "The portal's setup changed too: after up, ./mediastack.sh wire authentik"; fi
    elif (( portal )); then
        ok "Upgrade complete. The portal's setup changed — apply: ./mediastack.sh up && ./mediastack.sh wire authentik"
    elif grep -qE '^(mediastack\.sh|lib/|services/[^/]+/[^/]+\.sh$)' <<<"$changed"; then
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
    # Compose pads some progress lines (seen live: trailing characters after
    # the state), so nothing is anchored to the line's end; CRs are dropped
    # and anything before "Container" is tolerated. Stems catch every tense.
    done < <(tr -d '\r' <<<"$out" \
             | sed -nE 's/.*Container mediastack-([^ ]+) +(Recreat|Creat|Remov|Start).*/\1 \2/p' \
             | sed -E 's/ Recreat$/ Recreate/; s/ Creat$/ Create/; s/ Remov$/ Remove/')
    for s in "${!seen[@]}"; do
        case "${seen[$s]}" in
            Recreate) echo "$s" ;;
            Create)   echo "$s (new)" ;;
            Remove)   echo "$s (removed)" ;;
            Start)    echo "$s (stopped)" ;;
        esac
    done | sort
}

_nuke_root() { # _nuke_root VAR NAME -> VAR's folder: its .env value, or the one configure suggests inside this folder
    local v; v=$(env_get "$1"); realpath -m -- "$(abspath "${v:-$SCRIPT_DIR/$2}")"
}

root_keep_why() { # root_keep_why PATH -> why a whole-root delete must leave PATH in place ("" to delete it)
    local why o k; why=$(root_unsafe "$1"); [[ -z "$why" ]] || { echo "$why"; return 0; }
    for k in DATA_ROOT:data BACKUP_ROOT:backups; do   # the roots nuke and uninstall keep
        o=$(_nuke_root "${k%%:*}" "${k#*:}")
        [[ "$o/" == "$1/"* ]] && { echo "it holds ${k%%:*} ($o), which is kept"; return 0; }
    done
    return 0
}

roots_remove() { # roots_remove PATH... — each one deleted whole, unless root_keep_why keeps it (said, never silent)
    local r why
    for r in "$@"; do
        why=$(root_keep_why "$r")
        if [[ -n "$why" ]]; then warn "$r left in place: $why — delete what you no longer want in it by hand"; continue; fi
        sudo rm -rf -- "$r"; ok "removed $r"
    done
}

cmd_nuke() {
    # Deliberately does NOT need a working compose render or .env — it must
    # succeed on a half-deleted deployment. Containers are found by compose
    # project label; users by the mediacenter group in /etc/passwd.
    hr "NUKE: remove everything the installer created"
    local croot cache tcode r why
    croot=$(_nuke_root CONFIG_ROOT config); cache=$(_nuke_root CACHE_ROOT cache); tcode=$(_nuke_root TRANSCODE_ROOT transcodes)
    echo "Removes: containers, docker network, systemd units,"
    echo "         service users + group, and these folders, whole:"
    for r in "$croot" "$cache" "$tcode"; do
        why=$(root_keep_why "$r")
        if [[ -z "$why" ]]; then echo "           $r"; else echo "           (kept: $r — $why)"; fi
    done
    echo "         the deletion-attribution watch (and auditd, if mediastack installed it),"
    echo "         leak-test's tools (conntrack, tcpdump) if mediastack installed them."
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
    audit_teardown yes
    footprint_remove leakcheck
    footprint_mounts_list
    sudo docker ps -aq --filter "label=com.docker.compose.project=mediastack" \
        | xargs -r sudo docker rm -f -v >/dev/null
    # shellcheck disable=SC2034  # the inspect cache lives in the entrypoint (CACHE RULE at c_inspect)
    INSPECT_JSON=""
    ok "containers removed (with their anonymous volumes)"
    rm -f "$PINS_FILE"
    local net
    for net in mediastack mediastack-panel mediastack-authentik-db mediastack-search; do   # docker-compose.yml's networks
        sudo docker network rm "$net" >/dev/null 2>&1 && ok "network $net removed" || true
    done

    stack_users_remove

    roots_remove "$croot" "$cache" "$tcode"
    local inside=""
    local d repo; repo=$(realpath -m -- "$SCRIPT_DIR")
    d=$(_nuke_root DATA_ROOT data); [[ "$d" == "$repo/"* ]] && inside+="media ($d) "
    d=$(_nuke_root BACKUP_ROOT backups); [[ "$d" == "$repo/"* ]] && inside+="backups ($d) "
    if [[ -n "$inside" ]]; then
        ok "Nuked. Media and backups untouched."
        warn "Still INSIDE this folder: ${inside}— move them out before deleting it."
    else
        ok "Nuked. Media and backups untouched. Safe to delete this folder now."
    fi
    footprint_leftovers
}

systemd_units_teardown() { footprint_remove timers; }   # every mediastack timer/unit but the panel's and audit's

stack_users_remove() { # the users mediastack made (those whose own group is mediacenter), then the group — each said, a refusal too
    # Never by service name: up makes a service's user only when no user of that
    # name exists, so a host's own "jellyfin" (a native install) is not ours —
    # uninstall removed users by name and claimed them all removed whatever happened
    # (the audit, 26 Nov 2026)
    local gid u left=""
    gid=$(getent group mediacenter | cut -d: -f3 || true)
    [[ -n "$gid" ]] || { info "no group mediacenter — no users of mediastack's to remove"; return 0; }
    for u in $(getent passwd | awk -F: -v g="$gid" '$4 == g { print $1 }'); do
        if sudo userdel "$u" 2>/dev/null; then ok "user $u removed"; else warn "user $u was not removed (sudo userdel $u says why)"; left+=" $u"; fi
    done
    if [[ -n "$left" ]]; then warn "group mediacenter kept: users of its are left (${left# })"
    elif sudo groupdel mediacenter 2>/dev/null; then ok "group mediacenter removed"
    else warn "group mediacenter was not removed (sudo groupdel mediacenter says why)"; fi
}

cmd_uninstall() {
    if [[ "${1:-}" == --nuke ]]; then cmd_nuke; return; fi
    load_env
    hr "Uninstall (tiered)"
    echo "Tier 1: remove containers + docker network + the deletion-attribution watch"
    echo "        + leak-test's tools if mediastack installed them (configs, data, users kept)"
    confirm "Proceed with tier 1?" || return 0
    DC down --remove-orphans --volumes; ok "containers removed (anonymous volumes included)"
    systemd_units_teardown
    frontdoor_teardown
    audit_off
    footprint_remove leakcheck
    echo; echo "Mounts added by add-mount (each kept unless you say otherwise):"
    footprint_mounts_offer
    echo; echo "Tier 2: remove the service system users + group"
    if confirm "Also remove users/group?"; then
        stack_users_remove
    fi
    local croot why; croot=$(_nuke_root CONFIG_ROOT config); why=$(root_keep_why "$croot")
    if [[ -n "$why" ]]; then
        echo; info "Tier 3 skipped: $croot is left in place — $why. Delete the service configs in it by hand."
    else
        echo; echo "Tier 3: DELETE ALL SERVICE CONFIGS at $croot — irreversible."
        local really; read -r -p "Type 'delete my configs' to proceed (anything else skips): " really
        if [[ "$really" == "delete my configs" ]]; then roots_remove "$croot"
        else info "Configs kept."; fi
    fi
    footprint_leftovers
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
        IFS= read -r -s -p "SMB password: " smbpass; echo   # IFS=: the NAS's password as typed, a space at either end included
        credfile="/etc/mediastack-cifs-$(basename "$mpoint")"
        printf 'username=%s\npassword=%s\n' "$smbuser" "$smbpass" | sudo tee "$credfile" >/dev/null
        sudo chmod 600 "$credfile"
        ok "credentials stored at $credfile (root-only)"
        gid=$(env_get MEDIA_GROUP_GID)   # no .env yet: the schema's default
        # SMB has no POSIX ownership: map files to the shared media group.
        opts="_netdev,x-systemd.automount,hard,nofail,credentials=$credfile,uid=0,gid=$gid,file_mode=0664,dir_mode=2775,iocharset=utf8"
        fsline="$remote $mpoint cifs $opts 0 0"
    fi
    # the marker line lets uninstall and doctor tell this entry from your own
    printf '%s %s\n%s\n' "$FSTAB_MARK" "$mpoint" "$fsline" | sudo tee -a "$FSTAB" >/dev/null
    ok "fstab entry written (marked as mediastack's)"
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
