#!/usr/bin/env bash
# lib/manifest.sh — the media manifest: a scheduled, read-only snapshot of
# every file under DATA_ROOT/media, a compare that tells a real loss from arr
# churn, and `manifest find` to answer "when did X disappear?". Sourced by the
# entrypoint; relies on lib/common.sh, ts_now, notify and require_mounts at
# call time.
#
# Snapshot: BACKUP_ROOT/manifest/<ts>.tsv.gz, one record per file:
#   size <TAB> mtime <TAB> inode <TAB> path-relative-to-media-root
# sorted bytewise by path and gzipped with -n, so identical trees give
# identical files. A path's backslashes and newlines are escaped (\\, \n);
# tabs are left alone because the path is the last field.
#
# Loss vs churn: a file is identified by inode+size, so an arr rename — file
# or whole folder — is a move, not a loss. A folder alerts only when it lost
# more media files than it gained: an upgrade (one out, one in) stays quiet,
# a deleted movie (1 -> 0) or season (10 -> 8) does not. Sidecars (artwork,
# NFO, subtitles) never count. Known blind spot: an upgrade that also renames
# its folder reads as one loss in the old folder.

MANIFEST_SCAN_TIMEOUT=10800   # 3h: a hung network mount must not wedge the timer forever
MANIFEST_GUARD_MIN=25         # the % guard ignores drops smaller than this many files (small libraries)
MANIFEST_TSGLOB='[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].tsv.gz'
# lowercase match against the relative path; churn in these never counts as loss
MANIFEST_SIDECAR_RE='\.(nfo|jpe?g|png|webp|gif|bmp|tbn|srt|ass|ssa|sub|idx|sup|vtt|smi|lrc|txt|xml|bif|log|url|db|part|!qb|tmp)$|(^|/)sample[^/]*$|-sample\.[^/]*$'

manifest_dir()  { echo "$(env_get BACKUP_ROOT)/manifest"; }
manifest_root() { echo "$(env_get DATA_ROOT)/media"; }

manifest_list() { # snapshot file names, oldest first
    local f dir; dir=$(manifest_dir)
    # shellcheck disable=SC2231  # the glob is a constant pattern, not data
    for f in "$dir"/$MANIFEST_TSGLOB; do [[ -f "$f" ]] && basename "$f"; done
    return 0
}

manifest_guard_gitignore() { # a snapshot lists the whole library — never let git track one
    local dir="$1"
    [[ "$dir/" == "$SCRIPT_DIR/"* && -d "$SCRIPT_DIR/.git" ]] || return 0
    git -C "$SCRIPT_DIR" -c safe.directory="$SCRIPT_DIR" check-ignore -q "$dir/probe.tsv.gz" \
        || die "Manifest folder $dir is inside this repo but NOT gitignored — a snapshot lists your whole library.
  Fix: point BACKUP_ROOT outside the repo or at a gitignored folder (default ./backups), via ./mediastack.sh configure"
}

manifest_scan() { # manifest_scan OUT.gz — dies on any unreadable path or timeout
    local root raw err rc=0
    root=$(manifest_root)
    sudo test -d "$root" || die "Media root $root does not exist — nothing to snapshot. Check DATA_ROOT in .env."
    raw=$(mktemp); err=$(mktemp)
    # shellcheck disable=SC2024  # the temp files are ours; only find needs root
    sudo timeout -k 60 "$MANIFEST_SCAN_TIMEOUT" find "$root" -type f -printf '%s\t%T@\t%i\t%P\0' >"$raw" 2>"$err" || rc=$?
    if (( rc )); then
        local why; why=$(head -5 "$err"); rm -f "$raw" "$err"
        (( rc == 124 )) && die "Manifest scan of $root timed out after $((MANIFEST_SCAN_TIMEOUT/3600))h — hung network mount?
  Check the share, then retry: ./mediastack.sh manifest"
        die "Manifest scan of $root failed (find rc=$rc) — a partial scan would look like lost media, so nothing was recorded.
  find said:
$(sed 's/^/    /' <<<"$why")
  Fix the permissions/share above, then retry: ./mediastack.sh manifest"
    fi
    # whole-second mtime; escape \ and newline inside paths; NUL-terminated -> lines
    sed -z -E 's/^([0-9]+\t[0-9]+)\.[0-9]+/\1/; s/\\/\\\\/g; s/\n/\\n/g' "$raw" \
        | tr '\0' '\n' | LC_ALL=C sort -t $'\t' -k4 | gzip -n > "$1"
    rm -f "$raw" "$err"
}

# manifest_compare OLD.gz NEW.gz — first line:
#   SUMMARY <old media> <new media> <gone> <arrived> <moved>
# then one line per folder with a net media-file loss, sorted by folder:
#   LOSS <folder> <net lost> <gone file names, sorted, ' | '-joined>
# Tabs inside folder/file names are shown as \t so the columns hold.
manifest_compare() {
    # stage 1: identify files by inode+size; emit per-file G(one)/A(rrived) rows
    # shellcheck disable=SC2016  # awk programs, not shell
    local rows
    rows=$(awk -v SIDE="$MANIFEST_SIDECAR_RE" -F '\t' '
        function path() { p = $0; sub(/^[^\t]*\t[^\t]*\t[^\t]*\t/, "", p); return p }
        function dir(p) { return match(p, /.*\//) ? substr(p, 1, RLENGTH - 1) : "." }
        function esc(x) { gsub(/\t/, "\\t", x); return x }
        { p = path(); if (tolower(p) ~ SIDE) next; k = $3 ":" $1 }
        FILENAME == ARGV[1] { old[k] = p; no++; next }
        { nn++
          if (k in old) { seen[k] = 1; if (old[k] != p) mv++ }
          else          { printf "A\t%s\n", esc(dir(p)); na++ } }
        END {
            for (k in old) if (!(k in seen)) {
                n = old[k]; sub(/.*\//, "", n)
                printf "G\t%s\t%s\n", esc(dir(old[k])), esc(n); ng++
            }
            printf "S\t%d\t%d\t%d\t%d\t%d\n", no, nn, ng, na, mv
        }' <(sudo gzip -dc "$1") <(sudo gzip -dc "$2"))
    grep '^S' <<<"$rows" | sed 's/^S/SUMMARY/'
    # stage 2: per folder (sorted), a net loss is more gone than arrived
    # shellcheck disable=SC2016
    { grep -v '^S' <<<"$rows" || true; } | LC_ALL=C sort -t $'\t' -k2,2 -k3,3 | awk -F '\t' '
        function flush() { if (cur != "" && g > a) printf "LOSS\t%s\t%d\t%s\n", cur, g - a, names }
        $2 != cur { flush(); cur = $2; g = 0; a = 0; names = "" }
        $1 == "G" { g++; names = names (names == "" ? "" : " | ") $3 }
        $1 == "A" { a++ }
        END { flush() }'
}

manifest_titles() { # LOSS lines on stdin -> unique <category>/<title> folders
    cut -f2 | awk -F/ '{ print (NF > 1 ? $1 "/" $2 : $1) }' | LC_ALL=C sort -u
}

manifest_report() { # manifest_report COMPARE-OUTPUT [MAX-FOLDERS] — human-readable, to stdout
    local s max="${2:-0}" n; s=$(head -1 <<<"$1")
    local -a f; IFS=$'\t' read -r -a f <<<"$s"
    echo "media files: ${f[1]} -> ${f[2]}   (removed ${f[3]}, added ${f[4]}, renamed/moved ${f[5]})"
    if grep -q '^LOSS' <<<"$1"; then
        n=$(grep -c '^LOSS' <<<"$1")
        echo "Folders with a net loss of media files ($n):"
        # shellcheck disable=SC2016  # awk program, not shell
        grep '^LOSS' <<<"$1" | awk -F '\t' -v max="$max" '
            max == 0 || NR <= max { printf "  -%d  %s\n        %s\n", $3, $2, $4 }'
        if (( max > 0 && n > max )); then echo "  …and $((n - max)) more"; fi
    else
        echo "No folder lost media files (upgrades and renames are not losses)."
    fi
}

manifest_notify_loss() { # manifest_notify_loss COMPARE-OUTPUT PREV-TS
    local titles n list more="" nl=$'\n'
    titles=$(grep '^LOSS' <<<"$1" | manifest_titles)
    n=$(wc -l <<<"$titles")
    list=$(head -20 <<<"$titles" | sed 's/^/• /')
    (( n > 20 )) && more="$nl…and $((n - 20)) more"
    notify ops "Mediastack: media removed" "$n title folder(s) lost media files since the manifest of $2:$nl$list$more${nl}Detail: \`./mediastack.sh manifest diff\`" warning
}

manifest_take() { # manifest_take [--accept]
    load_env; require_mounts
    local dir latest new ts out cmp
    dir=$(manifest_dir); manifest_guard_gitignore "$dir"
    sudo mkdir -p "$dir"
    info "Scanning $(manifest_root) ..."
    new=$(mktemp); manifest_scan "$new"
    latest=$(manifest_list | tail -1)
    if [[ -z "$latest" ]]; then
        info "First manifest — this is the baseline; nothing to compare yet."
    else
        cmp=$(manifest_compare "$dir/$latest" "$new")
        local -a f; IFS=$'\t' read -r -a f <<<"$(head -1 <<<"$cmp")"
        local limit; limit=$(env_get MANIFEST_ALERT_PCT 5)
        # mass drop: most likely an unmounted or half-visible share — never let
        # that become the baseline the next comparison trusts. An empty root
        # after a non-empty one is always refused; otherwise the % applies once
        # the drop is big enough to matter (a small library deleting 3 movies
        # is not an outage)
        local drop=$(( f[1] - f[2] ))
        if [[ "${1:-}" != --accept ]] && (( f[1] > 0 )) \
           && (( f[2] == 0 || (drop >= MANIFEST_GUARD_MIN && drop * 100 > limit * f[1]) )); then
            local pct=$(( drop * 100 / f[1] ))
            manifest_report "$cmp" 10
            rm -f "$new"
            notify ops "Mediastack manifest: large drop NOT recorded" "Media file count fell ${pct}% (${f[1]} -> ${f[2]}), above MANIFEST_ALERT_PCT=${limit}. The snapshot was NOT kept as the new baseline."$'\n'"Share down? Fix it. Deletion intended? \`./mediastack.sh manifest --accept\`" failure
            die "Media file count fell ${pct}% (${f[1]} -> ${f[2]}) — above MANIFEST_ALERT_PCT=$limit. Snapshot NOT recorded.
  Share unmounted or half-visible? Fix it and retry: ./mediastack.sh manifest
  Deletion intended? Record it: ./mediastack.sh manifest --accept"
        fi
        manifest_report "$cmp" 50
        grep -q '^LOSS' <<<"$cmp" && manifest_notify_loss "$cmp" "${latest%.tsv.gz}"
    fi
    ts=$(ts_now); out="$dir/$ts.tsv.gz"
    sudo install -m 600 "$new" "$out"; rm -f "$new"
    ok "Manifest recorded: $out"
    prune_manifest
}

# Keep MANIFEST_KEEP_DAYS of history; the newest snapshot (the baseline) is
# never pruned. Only ever touches timestamp-named files in manifest/.
prune_manifest() {
    local dir keep cutoff f pruned=0
    dir=$(manifest_dir); keep=$(env_get MANIFEST_KEEP_DAYS 365)
    cutoff=$(date -d "-$keep days" +%Y%m%d)
    local -a all; mapfile -t all < <(manifest_list)
    (( ${#all[@]} > 1 )) || return 0
    for f in "${all[@]:0:${#all[@]}-1}"; do
        [[ "${f:0:8}" < "$cutoff" ]] || continue
        sudo rm -f "${dir:?}/$f"; pruned=$((pruned+1))
    done
    ok "manifests: kept $(( ${#all[@]} - pruned )), pruned $pruned (MANIFEST_KEEP_DAYS=$keep)"
}

manifest_resolve() { # manifest_resolve <timestamp or unique prefix> -> file name
    local n; local -a hits=()
    while IFS= read -r n; do [[ "$n" == "$1"* ]] && hits+=("$n"); done < <(manifest_list)
    (( ${#hits[@]} == 1 )) && { echo "${hits[0]}"; return; }
    (( ${#hits[@]} == 0 )) && die "No manifest matches '$1'. Available: $(manifest_list | sed 's/\.tsv\.gz$//' | tail -10 | tr '\n' ' ')"
    die "'$1' matches ${#hits[@]} manifests — give more of the timestamp."
}

manifest_diff() { # manifest_diff [A [B]] — B defaults to the newest, A to the one before B
    load_env
    local dir a b; dir=$(manifest_dir)
    local -a all; mapfile -t all < <(manifest_list)
    (( ${#all[@]} >= 2 )) || die "Need at least two manifests to diff (have ${#all[@]}). Take one: ./mediastack.sh manifest"
    if [[ -n "${1:-}" ]]; then a=$(manifest_resolve "$1"); else a=${all[-2]}; fi
    if [[ -n "${2:-}" ]]; then b=$(manifest_resolve "$2"); else b=${all[-1]}; fi
    [[ "$a" != "$b" ]] || die "Both sides are $a — nothing to compare."
    hr "manifest diff ${a%.tsv.gz} -> ${b%.tsv.gz}"
    manifest_report "$(manifest_compare "$dir/$a" "$dir/$b")"
}

manifest_find() { # manifest_find TEXT — first/last snapshot each matching path appears in
    load_env
    local dir f latest; dir=$(manifest_dir)
    latest=$(manifest_list | tail -1)
    [[ -n "$latest" ]] || die "No manifests yet. Take one: ./mediastack.sh manifest"
    local hits
    hits=$(for f in $(manifest_list); do
               sudo gzip -dc "$dir/$f" | cut -f4- | { grep -iF -- "$1" || true; } | sed "s/^/${f%.tsv.gz}\t/"
           done)
    [[ -n "$hits" ]] || { info "No manifest contains a path matching '$1'."; return 0; }
    echo "first seen       last seen        now      path"
    # shellcheck disable=SC2016  # awk program, not shell
    awk -F '\t' -v L="${latest%.tsv.gz}" '
        { p = $0; sub(/^[^\t]*\t/, "", p)
          if (!(p in first)) first[p] = $1
          last[p] = $1 }
        END { for (p in first) printf "%s  %s  %-7s  %s\n", first[p], last[p], (last[p] == L ? "present" : "GONE"), p }
    ' <<<"$hits" | LC_ALL=C sort -k4
}

# shellcheck disable=SC2120  # arguments arrive via main()'s registry dispatch
cmd_manifest() {
    case "${1:-}" in
        ""|--accept) args_max 1 "$@"; manifest_take "$@" ;;
        diff) shift; args_max 2 "$@"; manifest_diff "$@" ;;
        find) shift; [[ $# -eq 1 && -n "$1" ]] || die "usage: manifest find <text>   (one argument; quote it if it has spaces)"
              manifest_find "$1" ;;
        *) die "Unknown manifest argument '$1' (usage: manifest [--accept] | diff [A [B]] | find <text>)" ;;
    esac
}
