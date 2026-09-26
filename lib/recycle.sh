#!/usr/bin/env bash
# lib/recycle.sh — the arrs' recycle bin (on by default). An arr with a recycle
# bin MOVES what it deletes — including the old copy it replaces on an
# upgrade — into it instead of deleting it, and empties it itself after
# RECYCLE_DAYS (the arrs' own housekeeping; 0 = never). mediastack sets it up
# (wire arr: one folder per arr under RECYCLE_ROOT), checks it (doctor), and
# watches the space it takes (nightly, with the manifest), but NEVER deletes
# from it: freeing space early is the operator's call, and the warnings say
# how. Covers arr-made deletes only — a delete by Jellyfin, a person or another
# tool is gone (the deletion log, lib/audit.sh, still says who).
# Sourced by the entrypoint; relies on lib/common.sh, lib/doctor.sh (d_fail),
# lib/manifest.sh (manifest_root), lib/integrations.sh (api, arr_*, w_would,
# wfail, oneline, notify) and the render/svc helpers at call time.
#
# Placement rules, all checked before anything is set:
#   * inside DATA_ROOT — every arr already sees DATA_ROOT, so no new mounts
#   * outside DATA_ROOT/media — the library, the manifest and Jellyfin must
#     not see recycled files
#   * on the same filesystem as the media — an arr's recycle is a move;
#     across filesystems it becomes a full copy of every file
# Ownership (as for addresses): wire only changes a recycle bin it set. A
# path set in the arr's own UI is reported and left alone.

RECYCLE_WARN_BIN_PCT=10    # warn when the bin holds more than this % of the media drive
RECYCLE_WARN_FREE_PCT=10   # warn when the media drive has less than this % free
RECYCLE_WARNED=0           # wire prints the on-by-default warning once per run

recycle_on() { [[ "$(env_get RECYCLE_ENABLED false)" == true ]]; }

recycle_root() { # the host folder holding one bin per arr
    local r; r=$(env_get RECYCLE_ROOT)
    [[ -n "$r" ]] || r="$(env_get DATA_ROOT)/recycle"
    realpath -m "$(abspath "$r")"
}

recycle_days() { # RECYCLE_DAYS, validated (0 = the arrs never empty it)
    local d; d=$(env_get RECYCLE_DAYS 7)
    [[ "$d" =~ ^(0|[1-9][0-9]*)$ ]] || { echo "RECYCLE_DAYS='$d' is not a whole number of days (0 = never empty)" >&2; return 1; }
    echo "$d"
}

recycle_check_place() { # recycle_check_place ROOT DATA MEDIA -> rc 1 + the reason when the bin may not live there
    local r="$1" d="$2" m="$3"
    [[ "$r" == "$d/"* ]] || { echo "RECYCLE_ROOT $r is not inside DATA_ROOT ($d) — the arrs cannot see it there"; return 1; }
    [[ "$r" == "$m" || "$r" == "$m/"* ]] && { echo "RECYCLE_ROOT $r is inside the media library ($m) — recycled files would show up as media"; return 1; }
    [[ "$r" =~ [[:space:]] ]] && { echo "RECYCLE_ROOT '$r' contains whitespace"; return 1; }
    return 0
}

recycle_place_problem() { # this install's placement problem, if any (empty = fine)
    local d; d=$(realpath -m "$(abspath "$(env_get DATA_ROOT)")")
    recycle_check_place "$(recycle_root)" "$d" "$(realpath -m "$(abspath "$(manifest_root)")")" || true   # the reason is the output
}

recycle_cpath() { # recycle_cpath <svc> -> the bin's path as that arr sees it; rc 1 when it does not mount DATA_ROOT
    local d rel t
    d=$(realpath -m "$(abspath "$(env_get DATA_ROOT)")")
    rel=$(recycle_root); rel=${rel#"$d"}
    render
    t=$(jq -r --arg s "$1" --arg d "$d" '[.services[$s].volumes // [] | .[]
            | select(.type == "bind" and ((.source | rtrimstr("/")) == $d)) | .target] | first // empty' <<<"$RENDERED_JSON")
    [[ -n "$t" ]] || return 1
    echo "${t%/}$rel/$1"
}

recycle_same_fs() { # 0 when the bin and the media share a filesystem (a recycle is then a move, not a copy)
    [[ "$(fsdev_of "$(recycle_root)")" == "$(fsdev_of "$(manifest_root)")" ]]
}

recycle_arr_library() { # recycle_arr_library <svc> -> the host folder of that arr's library (its root folder)
    local d t rf
    d=$(realpath -m "$(abspath "$(env_get DATA_ROOT)")")
    render
    t=$(jq -r --arg s "$1" --arg d "$d" '[.services[$s].volumes // [] | .[]
            | select(.type == "bind" and ((.source | rtrimstr("/")) == $d)) | .target | rtrimstr("/")] | first // empty' <<<"$RENDERED_JSON")
    rf=$(svc_label "$1" mediastack.rootfolder)
    [[ -n "$t" && "$rf" == "$t/"* ]] || return 1
    echo "$d${rf#"$t"}"
}

recycle_arr_split() { # recycle_arr_split <svc> -> the reason when that arr's library is on another drive than the bin (empty = same)
    # the media root can be one drive while a library folder under it is
    # another (a second disk mounted at media/movies-4k): checked per arr
    local lib; lib=$(recycle_arr_library "$1") || return 0   # no library folder known: nothing to compare
    sudo test -d "$lib" || return 0
    [[ "$(fsdev_of "$lib")" == "$(fsdev_of "$(recycle_root)")" ]] && return 0
    echo "its library $lib is on another drive than the recycle bin $(recycle_root) — every recycle would be a full copy across drives"
}

recycle_advice() { # what to do about a full bin — the operator decides, mediastack never deletes from it
    echo "Files older than RECYCLE_DAYS=$(env_get RECYCLE_DAYS 7) are removed by the arrs on their own. To free space now,
  look through $(recycle_root) and delete what you no longer need yourself (mediastack never empties it),
  or lower RECYCLE_DAYS in .env and run: ./mediastack.sh wire arr"
}

# ------------------------------------------------------------------ wire --
recycle_warn_once() {
    (( RECYCLE_WARNED )) && return 0
    RECYCLE_WARNED=1
    explain "Arr recycle bin (on by default)" \
"Files an arr deletes — including the old copy it replaces on an upgrade —
are MOVED instead of deleted, one folder per arr, to:
    $(recycle_root)/<arr>
and the arrs remove them after RECYCLE_DAYS=$(env_get RECYCLE_DAYS 7) days.

It lives on the media drive and needs room for that many days of deletes
and upgrades: a 4K remux can be 50+ GB, and a quality-profile change can
replace a whole library at once. doctor and the nightly manifest warn when
the bin grows large or the drive runs low; mediastack never deletes from it.

Turn it off: set RECYCLE_ENABLED=false in .env, then ./mediastack.sh wire arr"
}

recycle_prepare() { # before any arr: the bin may live where RECYCLE_ROOT says; rc 1 (reported) when it may not
    local why days
    why=$(recycle_place_problem)
    [[ -z "$why" ]] || { wfail "recycle bin not set up: $why. Fix RECYCLE_ROOT in .env (empty = DATA_ROOT/recycle)"; return 1; }
    days=$(recycle_days 2>&1) || { wfail "recycle bin not set up: $days. Fix it in .env"; return 1; }
    if (( ! WIRE_DRY )); then
        sudo mkdir -p "$(recycle_root)"
        sudo chown ":mediacenter" "$(recycle_root)"; sudo chmod 2775 "$(recycle_root)"
    fi
    if sudo test -d "$(recycle_root)" && ! recycle_same_fs; then
        wfail "recycle bin not set up: $(recycle_root) is not on the media's filesystem ($(manifest_root)) — every recycle would be a full copy. Put RECYCLE_ROOT on the media drive"
        return 1
    fi
    return 0
}

arr_recycle() { # arr_recycle <svc> <url> <key> — that arr's recycle bin, per RECYCLE_*
    local s="$1" ep cur have hdays want days
    ep="$2/api/$(arr_apiver "$s")/config/mediamanagement"
    cur=$(api GET "$ep" "$3") || { wfail "$s: could not read its media management settings — recycle bin not checked [$(oneline "$cur")]"; return 0; }
    have=$(jq -r '.recycleBin // ""' <<<"$cur"); hdays=$(jq -r '.recycleBinCleanupDays // 0' <<<"$cur")
    want=$(recycle_cpath "$s") || { wfail "$s: does not mount DATA_ROOT — its recycle bin cannot be placed"; return 0; }
    if ! recycle_on; then
        [[ -n "$have" && "$have" == "$want" ]] || { ok "$s: recycle bin off"; return 0; }
        w_would "$s: clear the recycle bin mediastack set ($want) — RECYCLE_ENABLED=false" || return 0
        recycle_put "$s" "$ep" "$3" "$cur" "" "$hdays"
        return 0
    fi
    if [[ -n "$have" && "$have" != "$want" ]]; then
        warn "$s: recycle bin is '$have' — set in its UI (or under an earlier RECYCLE_ROOT), so left alone. For mediastack to manage it, clear it in $s (Settings → Media Management) and run: ./mediastack.sh wire arr"
        return 0
    fi
    local split; split=$(recycle_arr_split "$s")
    if [[ -n "$split" ]]; then
        wfail "$s: recycle bin not set: $split. Keep a library on the same filesystem as DATA_ROOT (drives pooled into one, e.g. mergerfs — see README)"
        return 0
    fi
    days=$(recycle_days)
    [[ "$have" == "$want" && "$hdays" == "$days" ]] && { ok "$s: recycle bin $want (emptied after $days days)"; return 0; }
    [[ -n "$have" ]] || recycle_warn_once
    if (( ! WIRE_DRY )); then
        sudo mkdir -p "$(recycle_root)/$s"
        sudo chown ":mediacenter" "$(recycle_root)/$s"; sudo chmod 2775 "$(recycle_root)/$s"
    fi
    w_would "$s: recycle bin -> $want, emptied after $days days" || return 0
    recycle_put "$s" "$ep" "$3" "$cur" "$want" "$days"
}

recycle_put() { # recycle_put <svc> <endpoint> <key> <cur JSON> <path> <days>
    local out
    if out=$(api PUT "$2" "$3" "$(jq -c --arg p "$5" --argjson d "$6" '.recycleBin = $p | .recycleBinCleanupDays = $d' <<<"$4")"); then
        ok "$1: recycle bin ${5:-cleared}${5:+ (emptied after $6 days)}"
    else
        wfail "$1: recycle bin update rejected — API said: $(oneline "$out")"
    fi
}

# -------------------------------------------------- space it takes --
recycle_usage() { # -> "bin-bytes drive-bytes drive-free-bytes"; rc 1 when a figure cannot be read
    local root bin fs
    root=$(recycle_root)
    bin=$(sudo timeout 300 du -sb "$root" 2>/dev/null | cut -f1) || return 1
    fs=$(df -B1 --output=size,avail "$(manifest_root)" 2>/dev/null | tail -1) || return 1
    [[ "$bin" =~ ^[0-9]+$ && "$fs" =~ ^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]*$ ]] || return 1
    echo "$bin" $fs
}

recycle_h() { numfmt --to=iec-i --suffix=B "$1"; }   # bytes, for people

recycle_problems() { # recycle_problems BIN DRIVE FREE -> one line per problem (none = fine)
    local bin="$1" size="$2" free="$3"
    (( size > 0 )) || return 0
    (( bin * 100 > size * RECYCLE_WARN_BIN_PCT )) \
        && echo "the recycle bin holds $(recycle_h "$bin") — $(( bin * 100 / size ))% of the media drive (warns above ${RECYCLE_WARN_BIN_PCT}%)"
    if (( free * 100 < size * RECYCLE_WARN_FREE_PCT )); then
        if (( bin > 0 )); then
            echo "the media drive has $(recycle_h "$free") free ($(( free * 100 / size ))%); the recycle bin holds $(recycle_h "$bin") of it"
        else
            echo "the media drive has $(recycle_h "$free") free ($(( free * 100 / size ))%) — the recycle bin is empty, so it is not the cause"
        fi
    fi
    return 0
}

recycle_watch() { # nightly (with the manifest): warn and notify ops when the bin or the drive needs attention
    recycle_on || return 0
    sudo test -d "$(recycle_root)" || return 0   # not set up yet: doctor says so
    local u problems
    u=$(recycle_usage) || { warn "recycle bin: its size or the drive's free space could not be read"; return 0; }
    # shellcheck disable=SC2086  # three numbers
    problems=$(recycle_problems $u)
    [[ -n "$problems" ]] || return 0
    warn "recycle bin: $problems"
    notify ops "Mediastack: recycle bin needs attention" "$problems"$'\n'"$(recycle_advice)" warning
}

# ------------------------------------------------------------------ doctor --
_doctor_recycle() {
    hr "doctor: recycle bin"
    if ! recycle_on; then
        info "off (RECYCLE_ENABLED=false) — files an arr deletes are gone at once"
        return 0
    fi
    local why days root u problems p
    why=$(recycle_place_problem)
    [[ -z "$why" ]] || { d_fail "the recycle bin cannot live where RECYCLE_ROOT says" "$why" "fix RECYCLE_ROOT in .env (empty = DATA_ROOT/recycle), then: ./mediastack.sh wire arr"; return 0; }
    days=$(recycle_days 2>&1) || { d_fail "RECYCLE_DAYS is invalid" "$days" "fix RECYCLE_DAYS in .env (default 7)"; return 0; }
    root=$(recycle_root)
    sudo test -d "$root" || { d_fail "$root does not exist" "the arrs have nowhere to move deleted files" "./mediastack.sh wire arr"; return 0; }
    recycle_same_fs && ok "recycle bin $root on the media's filesystem (emptied after $days days)" \
        || d_fail "$root is not on the media's filesystem" "every recycle would be a full copy of the file" "put RECYCLE_ROOT on the media drive, then: ./mediastack.sh wire arr"
    _doctor_recycle_arrs
    if u=$(recycle_usage); then
        # shellcheck disable=SC2086  # three numbers
        problems=$(recycle_problems $u)
        if [[ -z "$problems" ]]; then
            # shellcheck disable=SC2086
            set -- $u
            ok "recycle bin holds $(recycle_h "$1"); the media drive has $(recycle_h "$3") free"
        else
            while IFS= read -r p; do warn "$p"; done <<<"$problems"
            recycle_advice | sed 's/^/     /'
        fi
    else
        warn "recycle bin size or free space UNCONFIRMED (du/df could not read them)"
    fi
    return 0
}

_doctor_recycle_arrs() { # each running arr's setting matches what wire sets
    local s key url cur have hdays want days split
    days=$(recycle_days)
    for s in $(arr_instances); do
        [[ "$(c_state "$(svc_cname "$s")")" == running ]] || { info "$s: not running — its recycle bin not checked"; continue; }
        key=$(arr_key "$s"); url=$(arr_url "$s") || continue
        if ! cur=$(api GET "$url/api/$(arr_apiver "$s")/config/mediamanagement" "$key"); then
            warn "$s: media management settings unreadable — recycle bin UNCONFIRMED [$(oneline "$cur")]"; continue
        fi
        have=$(jq -r '.recycleBin // ""' <<<"$cur"); hdays=$(jq -r '.recycleBinCleanupDays // 0' <<<"$cur")
        want=$(recycle_cpath "$s") || { d_fail "$s does not mount DATA_ROOT" "its recycle bin cannot be placed" "check its volumes in docker-compose.override.yml"; continue; }
        split=$(recycle_arr_split "$s")
        [[ -z "$split" ]] || { d_fail "$s: its recycle bin would copy, not move" "$split" "pool the drives into one filesystem as DATA_ROOT (README: DATA_ROOT should be one filesystem), or turn the bin off: RECYCLE_ENABLED=false"; continue; }
        if [[ "$have" == "$want" && "$hdays" == "$days" ]]; then ok "$s: recycle bin set"
        elif [[ -z "$have" || "$have" == "$want" ]]; then d_fail "$s: recycle bin not set as .env says" "files it deletes are gone at once (or kept the wrong time)" "./mediastack.sh wire arr"
        else info "$s: recycle bin '$have' set in its UI — mediastack leaves it alone"
        fi
    done
    return 0
}
