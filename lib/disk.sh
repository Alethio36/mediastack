#!/usr/bin/env bash
# lib/disk.sh — room on every filesystem the stack writes to: each root, Docker's
# own data (images, container logs), and this folder (local/: run records,
# state). A full one breaks things quietly — pulls fail, databases stop
# writing, restore points refuse — so doctor judges it and the nightly
# manifest run tells ops.
#   fail  under DISK_FAIL_BYTES free, or under DISK_INODE_FAIL_PCT % of its inodes
#   warn  under DISK_WARN_PCT % free, unless more than DISK_WARN_ROOM is left
#         (90% of a 20 TB disk still leaves 2 TB; 95% of a 30 GB one leaves 1.5)
# Sourced by the entrypoint.

DISK_FAIL_BYTES=$(( 2 * 1024 ** 3 ))
DISK_WARN_PCT=10
DISK_WARN_ROOM=$(( 50 * 1024 ** 3 ))
DISK_INODE_FAIL_PCT=5
DISK_WARN_EVERY=$(( 7 * 86400 ))   # a warning reaches ops at most this often per filesystem; a failure every night

disk_existing() { # disk_existing PATH -> PATH, or its nearest folder that exists (a root not made yet lives where it will be)
    local p=$1
    while [[ -n "$p" && "$p" != / ]] && ! sudo test -e "$p"; do p=$(dirname "$p"); done
    echo "${p:-/}"
}

disk_targets() { # label<TAB>path for every place the stack writes
    local r d
    for r in "${ROOTS[@]}"; do
        [[ -n "$(env_get "$r")" ]] && printf '%s\t%s\n' "$r" "$(env_get "$r")"
    done
    d=$(sudo docker info --format '{{.DockerRootDir}}' 2>/dev/null) && [[ -n "$d" ]] && printf "Docker's data\\t%s\\n" "$d"
    printf 'this folder\t%s\n' "$SCRIPT_DIR"
}

disk_h() { numfmt --to=iec-i --suffix=B "$1"; }

disk_report() { # one line per filesystem: level<TAB>mount<TAB>labels<TAB>size<TAB>avail<TAB>inodes<TAB>inodes-free
    local label path out mnt size avail itot ifree level
    local -A labels=() line=()
    local -a order=()
    while IFS=$'\t' read -r label path; do
        out=$(sudo df -P -B1 --output=target,size,avail,itotal,iavail "$(disk_existing "$path")" 2>/dev/null | sed -n 2p) || continue
        read -r mnt size avail itot ifree <<<"$out"
        [[ -n "$mnt" ]] || continue
        if [[ -z "${labels[$mnt]:-}" ]]; then order+=("$mnt"); labels[$mnt]=$label; line[$mnt]="$size $avail $itot $ifree"
        else labels[$mnt]+=", $label"; fi
    done < <(disk_targets)
    for mnt in "${order[@]}"; do
        read -r size avail itot ifree <<<"${line[$mnt]}"
        level=ok
        if (( avail < DISK_FAIL_BYTES )) || (( itot > 0 && ifree * 100 < itot * DISK_INODE_FAIL_PCT )); then level=fail
        elif (( avail * 100 < size * DISK_WARN_PCT && avail < DISK_WARN_ROOM )); then level=warn; fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$level" "$mnt" "${labels[$mnt]}" "$size" "$avail" "$itot" "$ifree"
    done
}

disk_words() { # disk_words SIZE AVAIL INODES INODES-FREE -> "X free of Y (Z%)", inodes when they matter
    local size=$1 avail=$2 itot=$3 ifree=$4 s
    s="$(disk_h "$avail") free of $(disk_h "$size") ($(( size > 0 ? avail * 100 / size : 0 ))%)"
    (( itot > 0 && ifree * 100 < itot * DISK_INODE_FAIL_PCT )) && s+=", $(( ifree * 100 / itot ))% of its inodes (files) left"
    echo "$s"
}

_doctor_disk() { # in doctor's host resources
    local level mnt labels size avail itot ifree words n=0
    while IFS=$'\t' read -r level mnt labels size avail itot ifree; do
        n=$((n + 1)); words=$(disk_words "$size" "$avail" "$itot" "$ifree")
        case "$level" in
            fail) d_fail "disk $mnt ($labels): $words" \
                     "below $(disk_h "$DISK_FAIL_BYTES") free, or $DISK_INODE_FAIL_PCT% of inodes, image pulls fail, databases stop writing and restore points refuse" \
                     "free space there (old images: sudo docker image prune -a; old restore points: BACKUP_KEEP_* in .env), or move a root with ./mediastack.sh configure" ;;
            warn) warn "disk $mnt ($labels): $words — under $DISK_WARN_PCT% free; it fails below $(disk_h "$DISK_FAIL_BYTES")" ;;
            *)    ok "disk $mnt ($labels): $words" ;;
        esac
    done < <(disk_report)
    (( n )) || warn "disk: no filesystem could be read (df)"
}

disk_watch() { # nightly (with the manifest): a filesystem running out tells ops — a failure every night, a warning once a week
    local level mnt labels size avail itot ifree words key last now=$EPOCHSECONDS
    while IFS=$'\t' read -r level mnt labels size avail itot ifree; do
        key="disk-warned-$(cksum <<<"$mnt" | cut -d' ' -f1)"
        [[ "$level" == ok ]] && { [[ -n "$(state_get "$key")" ]] && rm -f "$STATE_DIR/$key"; continue; }
        words=$(disk_words "$size" "$avail" "$itot" "$ifree")
        warn "disk $mnt ($labels): $words"
        if [[ "$level" == fail ]]; then
            notify ops "Mediastack: a disk is nearly full" "$mnt ($labels): $words. Below $(disk_h "$DISK_FAIL_BYTES") free, pulls, databases and restore points start failing. Details and fixes: \`./mediastack.sh doctor\`" failure
            continue
        fi
        last=$(state_get "$key")
        [[ -n "$last" ]] && (( now - last < DISK_WARN_EVERY )) && continue
        notify ops "Mediastack: a disk is getting full" "$mnt ($labels): $words. It fails below $(disk_h "$DISK_FAIL_BYTES"). Details: \`./mediastack.sh doctor\`" warning
        state_set "$key" "$now"
    done < <(disk_report)
}
