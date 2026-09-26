#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-recycle.sh — the arr recycle bin's contract.
#   * placement: inside DATA_ROOT, outside the media library, no whitespace;
#     the arr's view of the path comes from its own DATA_ROOT mount
#   * a library on another drive than the bin gets no bin (a copy, not a move)
#   * wire only changes a bin it set: unset -> set (with the on-by-default
#     warning, once), ours -> kept or its days corrected, one set in the arr's
#     UI -> left alone, off -> ours cleared and a hand-set one kept; --dry-run
#     writes nothing; days go out as a number
#   * space: the bin's share of the drive and the drive's free space warn at
#     their thresholds, the nightly watch notifies ops with the advice, and
#     mediastack never deletes from the bin itself
#
#   scripts/test-recycle.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-recycle.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "OK $*" >> "$T/out"; }; info() { echo "INFO $*" >> "$T/out"; }; warn() { echo "WARN $*" >> "$T/out"; }
explain() { echo "EXPLAIN $1" >> "$T/out"; }
sudo() { "$@"; }; chown() { :; }

ENV_FILE=$T/env
envf() { printf 'DATA_ROOT=%s\nRECYCLE_ENABLED=%s\nRECYCLE_ROOT=%s\nRECYCLE_DAYS=%s\n' "$T/data" "$1" "${2:-}" "${3:-7}" > "$ENV_FILE"; }
envf true
mkdir -p "$T/data/media"

# ---- placement ----
[[ "$(recycle_root)" == "$T/data/recycle" ]] || fail_ "default RECYCLE_ROOT: $(recycle_root)"; pass
recycle_check_place /d/recycle /d /d/media >/dev/null || fail_ "inside DATA_ROOT must be allowed"; pass
for bad in /elsewhere/recycle /d /d/media /d/media/recycle "/d/re cycle"; do
    if recycle_check_place "$bad" /d /d/media >/dev/null; then fail_ "$bad must be refused"; fi; pass
done
[[ -z "$(recycle_place_problem)" ]] || fail_ "the default placement must be fine: $(recycle_place_problem)"; pass
envf true "$T/data/media/bin"
[[ "$(recycle_place_problem)" == *"inside the media library"* ]] || fail_ "a bin in the library must be refused"; pass
envf true
for d in 0 7 30; do envf true "" "$d"; [[ "$(recycle_days)" == "$d" ]] || fail_ "RECYCLE_DAYS=$d"; pass; done
for d in -1 abc 07; do envf true "" "$d"; if recycle_days 2>/dev/null; then fail_ "RECYCLE_DAYS=$d must be refused"; fi; pass; done
envf true

# ---- the arr's view of the bin: through its own DATA_ROOT mount ----
RENDERED_JSON=$(jq -n --arg d "$T/data" '{services: {
    radarr: {volumes: [{type: "bind", source: "/cfg/radarr", target: "/config"}, {type: "bind", source: $d, target: "/data"}]},
    sonarr: {volumes: [{type: "bind", source: ($d + "/"), target: "/mnt/lib/"}]},
    other:  {volumes: [{type: "bind", source: "/x", target: "/data"}]} }}')
[[ "$(recycle_cpath radarr)" == /data/recycle/radarr ]] || fail_ "radarr's view: $(recycle_cpath radarr)"; pass
[[ "$(recycle_cpath sonarr)" == /mnt/lib/recycle/sonarr ]] || fail_ "a custom mount target (and trailing slashes): $(recycle_cpath sonarr)"; pass
if recycle_cpath other >/dev/null; then fail_ "an arr without a DATA_ROOT mount must be refused"; fi; pass

# ---- wire: only a bin it set is changed ----
api() { # a fake arr: GET returns $CUR, PUT is logged
    case "$1" in GET) echo "$CUR" ;; PUT) echo "$4" >> "$T/put" ;; esac
}
arr_apiver() { echo v3; }
WIRE_DRY=0; WIRE_CHANGES=0; WIRE_FAILS=0
run() { # run CUR -> PUT (last body, or "none") in $PUT, output in $OUT
    CUR=$1; rm -f "$T/put" "$T/out"; RECYCLE_WARNED=0
    arr_recycle radarr http://x key
    PUT=$( [[ -e "$T/put" ]] && tail -1 "$T/put" || echo none ); OUT=$(cat "$T/out" 2>/dev/null || true)
}
run '{"id":1,"recycleBin":"","recycleBinCleanupDays":7,"other":"kept"}'
[[ "$(jq -c '{recycleBin, recycleBinCleanupDays, other}' <<<"$PUT")" == '{"recycleBin":"/data/recycle/radarr","recycleBinCleanupDays":7,"other":"kept"}' ]] \
    || fail_ "unset: must set path + days (a number), keep the rest: $PUT"; pass
[[ "$OUT" == *"EXPLAIN Arr recycle bin (on by default)"* ]] || fail_ "the first set must warn: $OUT"; pass
[[ -d "$T/data/recycle/radarr" ]] || fail_ "the arr's folder must be created"; pass
RECYCLE_WARNED=1; CUR='{"id":1,"recycleBin":"","recycleBinCleanupDays":7}'; rm -f "$T/out"; arr_recycle radarr http://x key
[[ "$(cat "$T/out")" != *EXPLAIN* ]] || fail_ "the warning must show once per run"; pass
run '{"id":1,"recycleBin":"/data/recycle/radarr","recycleBinCleanupDays":7}'
[[ "$PUT" == none ]] || fail_ "already right: nothing to write"; pass
run '{"id":1,"recycleBin":"/data/recycle/radarr","recycleBinCleanupDays":30}'
[[ "$(jq -c '.recycleBinCleanupDays' <<<"$PUT")" == 7 ]] || fail_ "ours with other days: days corrected: $PUT"; pass
run '{"id":1,"recycleBin":"/data/my-bin","recycleBinCleanupDays":3}'
[[ "$PUT" == none && "$OUT" == *"left alone"* ]] || fail_ "set in the UI: left alone and said: $PUT / $OUT"; pass
WIRE_DRY=1; run '{"id":1,"recycleBin":"","recycleBinCleanupDays":7}'; WIRE_DRY=0
[[ "$PUT" == none ]] || fail_ "--dry-run must write nothing"; pass
envf false
run '{"id":1,"recycleBin":"/data/recycle/radarr","recycleBinCleanupDays":7}'
[[ "$(jq -c '{recycleBin, recycleBinCleanupDays}' <<<"$PUT")" == '{"recycleBin":"","recycleBinCleanupDays":7}' ]] || fail_ "off: ours cleared: $PUT"; pass
run '{"id":1,"recycleBin":"/data/my-bin","recycleBinCleanupDays":3}'
[[ "$PUT" == none ]] || fail_ "off: a hand-set bin is kept"; pass
envf true

# ---- a library on another drive than the bin: refused per arr ----
svc_label() { [[ "$2" == mediastack.rootfolder ]] && echo /data/media/movies; }
mkdir -p "$T/data/media/movies"
[[ "$(recycle_arr_library radarr)" == "$T/data/media/movies" ]] || fail_ "radarr's library on the host: $(recycle_arr_library radarr)"; pass
fsdev_of() { case "$1" in *media/movies*) echo 2 ;; *) echo 1 ;; esac; }   # movies is a second disk
run '{"id":1,"recycleBin":"","recycleBinCleanupDays":7}'
[[ "$PUT" == none && "$OUT" != *EXPLAIN* ]] || fail_ "a library on another drive must not get a bin: $PUT"; pass
fsdev_of() { echo 1; }
run '{"id":1,"recycleBin":"","recycleBinCleanupDays":7}'
[[ "$PUT" != none ]] || fail_ "the same drive must get its bin"; pass
unset -f svc_label fsdev_of

# ---- space ----
GB=$((1024**3))
[[ -z "$(recycle_problems $((9*GB)) $((100*GB)) $((50*GB)))" ]] || fail_ "9% of the drive, half free: no warning"; pass
[[ "$(recycle_problems $((11*GB)) $((100*GB)) $((50*GB)))" == *"11% of the media drive"* ]] || fail_ "11% of the drive must warn"; pass
p=$(recycle_problems $((2*GB)) $((100*GB)) $((5*GB)))
[[ "$p" == *"5.0GiB free"* && "$p" == *"holds 2.0GiB of it"* ]] || fail_ "low free space must say what the bin holds: $p"; pass
[[ "$(recycle_problems 0 $((100*GB)) $((5*GB)))" == *"not the cause"* ]] || fail_ "an empty bin must not be blamed"; pass
recycle_usage() { echo $((20*GB)) $((100*GB)) $((5*GB)); }
notify() { printf '%s\n%s\n' "$2" "$3" > "$T/notified"; }
recycle_watch
grep -q 'recycle bin needs attention' "$T/notified" && grep -q 'delete what you no longer need yourself' "$T/notified" \
    || fail_ "the nightly watch must notify ops with the advice: $(cat "$T/notified" 2>/dev/null)"; pass
envf false; rm -f "$T/notified"; recycle_watch
[[ ! -e "$T/notified" ]] || fail_ "off: the watch stays quiet"; pass

# ---- mediastack never deletes from the bin ----
if grep -nE '(^|[^a-z_-])rm( |$)|find .*-delete|unlink ' lib/recycle.sh; then
    fail_ "lib/recycle.sh deletes something (above) — emptying the bin is the operator's call"
fi; pass

echo "OK recycle: $checks checks"
