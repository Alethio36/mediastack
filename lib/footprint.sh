#!/usr/bin/env bash
# lib/footprint.sh — everything mediastack puts on the host outside this
# folder, in one registry. Each feature lists what it placed (a provider,
# because some entries only exist at runtime: one fstab entry per add-mount);
# uninstall removes through it, doctor shows it, and CI fails a write outside
# the repo that no provider owns (scripts/test-footprint.sh).
# Sourced by the entrypoint; relies on lib/common.sh, lib/frontdoor.sh
# (FRONTDOOR_*), lib/vpn.sh (VPNGUARD_UNIT) and lib/audit.sh at call time.
#
# One line per entry:  feature <TAB> kind <TAB> path <TAB> action
#   kind   unit (a systemd unit file) | file | user | group | fstab | pkg
#   action remove  uninstall removes it
#          audit   removed by the audit feature's own teardown (it unloads
#                  kernel rules and knows whether it installed the package)
#          users   the service users + group: uninstall's tier 2 asks first
#          ask     a mount: uninstall offers it one at a time, default No
#          keep    a host dependency (docker, packages): listed, never removed

FSTAB=/etc/fstab
FSTAB_MARK="# mediastack add-mount"   # the line add-mount writes above each entry it adds
# every place a mediastack write outside the repo may land — CI holds every
# literal outside-repo write path in lib/ to this list (scripts/test-footprint.sh)
# shellcheck disable=SC2034  # read by scripts/test-footprint.sh
FOOTPRINT_PREFIXES=(
    "$SYSTEMD_DIR/mediastack-" /etc/sudoers.d/mediastack- /usr/local/bin/olivetin-
    /etc/audit/rules.d/99-mediastack "$FSTAB" /etc/mediastack-cifs- /var/log/audit
    /etc/apt/keyrings /etc/apt/sources.list.d/docker
)
FOOTPRINT_FEATURES=(timers panel audit mounts users deps)

fp_timers() {
    local u
    for u in mediastack-update.timer mediastack-update.service mediastack-manifest.timer \
             mediastack-manifest.service mediastack-vpnguard.service; do
        printf 'timers\tunit\t%s/%s\tremove\n' "$SYSTEMD_DIR" "$u"
    done
}
fp_panel() {
    printf 'panel\tunit\t%s/mediastack-frontdoor-refresh.timer\tremove\n' "$SYSTEMD_DIR"
    printf 'panel\tunit\t%s/mediastack-frontdoor-refresh.service\tremove\n' "$SYSTEMD_DIR"
    printf 'panel\tfile\t%s\tremove\n' "$FRONTDOOR_SUDOERS" "$FRONTDOOR_WRAPPER"
    printf 'panel\tuser\t%s\tremove\n' "$FRONTDOOR_USER"
}
fp_audit() {
    local p
    for p in "${AUDIT_FOOTPRINT[@]}"; do printf 'audit\t%s\t%s\taudit\n' "$([[ "$p" == "$SYSTEMD_DIR"/* ]] && echo unit || echo file)" "$p"; done
    [[ "$(audit_marker)" == yes ]] && printf 'audit\tpkg\tauditd\taudit\n'
    return 0
}
fp_mounts() { # the entries add-mount marked: the fstab entry, its credentials file (SMB), its mountpoint
    local m line cred
    while IFS=$'\t' read -r m line; do
        printf 'mounts\tfstab\t%s\task\n' "$m"
        cred=$(grep -oE 'credentials=[^, ]+' <<<"$line" | cut -d= -f2 || true)   # NFS entries have none
        [[ -n "$cred" ]] && printf 'mounts\tfile\t%s\task\n' "$cred"
    done < <(fstab_marked)
    return 0
}
fp_users() {
    local gid u
    gid=$(getent group mediacenter | cut -d: -f3 || true)   # no group: no service users either
    [[ -n "$gid" ]] || return 0
    printf 'users\tgroup\tmediacenter\tusers\n'
    for u in $(awk -F: -v g="$gid" '$4 == g { print $1 }' /etc/passwd); do printf 'users\tuser\t%s\tusers\n' "$u"; done
}
fp_deps() { # what `install` added for docker; other packages are named in the inventory text
    printf 'deps\tfile\t/etc/apt/keyrings/docker.asc\tkeep\n'
    printf 'deps\tfile\t/etc/apt/sources.list.d/docker.list\tkeep\n'
}

fstab_marked() { # mountpoint <TAB> fstab entry, for every entry add-mount marked
    awk -v mark="$FSTAB_MARK" '
        index($0, mark " ") == 1 { m = substr($0, length(mark) + 2); next }
        m != "" { if ($2 == m) print m "\t" $0; m = "" }' "$FSTAB" 2>/dev/null
    return 0
}

footprint_list() { # footprint_list [feature...] -> every entry (all features by default)
    local f
    for f in "${@:-${FOOTPRINT_FEATURES[@]}}"; do "fp_$f"; done
}

fp_present() { # fp_present KIND PATH -> 0 when it is on this host
    case "$1" in
        unit|file) sudo test -e "$2" ;;
        user)  getent passwd "$2" >/dev/null ;;
        group) getent group "$2" >/dev/null ;;
        fstab) fstab_marked | cut -f1 | grep -qxF -- "$2" ;;
        pkg)   dpkg-query -W -f='${Status}' "$2" 2>/dev/null | grep -q 'install ok installed' ;;
        *) die "footprint: unknown kind '$1'" ;;
    esac
}

footprint_present() { # footprint_present [feature...] -> the entries that are on this host
    local feat kind path act
    while IFS=$'\t' read -r feat kind path act; do
        fp_present "$kind" "$path" && printf '%s\t%s\t%s\t%s\n' "$feat" "$kind" "$path" "$act"
    done < <(footprint_list "$@")
    return 0
}

footprint_remove() { # footprint_remove feature... — remove every present entry whose action is remove
    local feat kind path act reload=0
    while IFS=$'\t' read -r feat kind path act; do
        [[ "$act" == remove ]] || continue
        case "$kind" in
            unit) sudo systemctl disable --now "${path##*/}" >/dev/null 2>&1 || true   # a unit that was never enabled
                  sudo rm -f "$path"; reload=1 ;;
            file) sudo rm -f "$path" ;;
            user) sudo userdel -r "$path" 2>/dev/null || sudo userdel "$path" ;;
            *) die "footprint: '$kind' entries are not removed this way ($feat $path)" ;;
        esac
    done < <(footprint_present "$@")
    (( reload )) && sudo systemctl daemon-reload
    return 0
}

footprint_leftovers() { # after an uninstall: whatever it should have removed and did not
    local left
    left=$(footprint_present | awk -F'\t' '$4 == "remove" || $4 == "audit" { print "  " $3 " (" $1 ")" }')
    if [[ -n "$left" ]]; then
        warn "still on this host, though uninstall removes it:"$'\n'"$left"
    else
        ok "nothing mediastack placed outside this folder is left, apart from what is listed as kept"
    fi
}

# ---------------------------------------------------------------- mounts --
mount_unit() { systemd-escape -p --suffix=automount "$1"; }   # add-mount's entries attach through this

mount_remove() { # mount_remove MOUNTPOINT — unmount, drop the fstab entry, its credentials and the empty folder
    local m="$1" line cred
    line=$(fstab_marked | awk -F'\t' -v m="$m" '$1 == m { print $2 }')
    [[ -n "$line" ]] || { warn "$m: no marked fstab entry — left alone"; return 0; }
    sudo systemctl stop "$(mount_unit "$m")" >/dev/null 2>&1 || true   # not attached yet: nothing to stop
    if findmnt -rn "$m" >/dev/null 2>&1 && ! sudo umount "$m" 2>/dev/null; then
        warn "$m is in use by something on this host — kept, nothing changed. Find it: sudo lsof +f -- $m"
        return 0
    fi
    cred=$(grep -oE 'credentials=[^, ]+' <<<"$line" | cut -d= -f2 || true)
    local tmp; tmp=$(mktemp)
    awk -v mark="$FSTAB_MARK $m" -v entry="$line" '$0 == mark || $0 == entry { next } { print }' "$FSTAB" > "$tmp"
    sudo install -m 0644 -o root -g root "$tmp" "$FSTAB"; rm -f "$tmp"
    sudo systemctl daemon-reload
    [[ -n "$cred" ]] && sudo rm -f "$cred"
    sudo chattr -i "$m" 2>/dev/null || true   # set by add-mount only where the filesystem supports it
    sudo rmdir "$m" 2>/dev/null || warn "$m is not empty after unmounting — the folder is kept"
    ok "$m unmounted and removed (its fstab entry${cred:+, stored credentials} and folder; the share itself is untouched)"
}

footprint_mounts_offer() { # uninstall: each marked mount, offered one at a time (default No)
    local m any=0
    while IFS=$'\t' read -r m _; do
        any=1
        echo "  $m — a share added by add-mount (your media may live here)."
        confirm "  Remove this mount (and any credentials stored for it)? Media on the share is not touched" \
            && mount_remove "$m" || info "  $m kept (remove it later: README, \"Removing a mount\")"
    done < <(fstab_marked)
    (( any )) || info "no mounts made by add-mount"
    footprint_unmarked_note
}

footprint_mounts_list() { # nuke: mounts are never part of its single confirmation — listed only
    local m
    while IFS=$'\t' read -r m _; do
        info "kept: the mount $m (add-mount) — remove it by hand: README, \"Removing a mount\""
    done < <(fstab_marked)
    footprint_unmarked_note
}

footprint_unmarked_note() { # entries for the stack's roots that add-mount did not mark (made before the marker, or by hand)
    local r p
    for r in DATA_ROOT BACKUP_ROOT; do
        [[ -f "$ENV_FILE" ]] || return 0
        p=$(findmnt -rn -o TARGET --target "$(env_get "$r")" 2>/dev/null | head -1)
        [[ -n "$p" && "$p" != / ]] || continue
        fstab_marked | cut -f1 | grep -qxF -- "$p" && continue
        awk -v p="$p" '$2 == p { f = 1 } END { exit !f }' "$FSTAB" 2>/dev/null \
            && info "$r lives on $p, an fstab entry mediastack did not mark (made before add-mount marked its entries, or by hand) — left alone"
    done
    return 0
}

# ------------------------------------------------------------------ doctor --
_doctor_footprint() {
    hr "doctor: on this host, outside this folder"
    local feat kind path act n=0 users=0
    while IFS=$'\t' read -r feat kind path act; do
        n=$((n + 1))
        [[ "$feat" == users && "$kind" == user ]] && { users=$((users + 1)); continue; }   # one line for all of them, below
        case "$act" in
            keep) info "$feat: $path (kept by uninstall)" ;;
            ask)  info "$feat: $path (uninstall asks before removing it)" ;;
            *)    info "$feat: $path" ;;
        esac
    done < <(footprint_present)
    (( users )) && info "users: $users service users in the mediacenter group (uninstall asks, tier 2)"
    (( n )) || info "nothing"
    local r m
    while IFS=$'\t' read -r m _; do   # a marked mount that no longer holds any root
        for r in "${ROOTS[@]}"; do
            [[ "$(findmnt -rn -o TARGET --target "$(env_get "$r")" 2>/dev/null | head -1)" == "$m" ]] && continue 2
        done
        info "the mount $m (add-mount) holds none of this stack's folders — remove it if nothing else uses it: README, \"Removing a mount\""
    done < <(fstab_marked)
    return 0
}
