#!/usr/bin/env bash
# test-disk.sh — room on every filesystem the stack writes to (lib/disk.sh):
#   * each root, Docker's data and this folder, one finding per filesystem
#     naming everything that lives on it; a root not made yet is judged where
#     it will be
#   * fail under 2 GiB free or 5% of inodes; warn under 10% free unless more
#     than 50 GiB is left; otherwise ok
#   * doctor counts a fail as a problem; the nightly manifest run tells ops —
#     a failure every night, a warning once a week, the mark cleared once ok
# Sources the real entrypoint (minus its last line, main "$@"); df, sudo and
# docker are stubs reading fixtures.
#
#   scripts/test-disk.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-disk.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"
set +e +E; trap - ERR

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

G=$(( 1024 ** 3 ))
ENV_FILE=$T/env; STATE_DIR=$T/state; SCRIPT_DIR_REAL=$SCRIPT_DIR
mkdir -p "$T/media" "$T/repo" "$T/var-docker"
printf 'CONFIG_ROOT=%s/repo/config\nDATA_ROOT=%s/media\nCACHE_ROOT=%s/repo/cache\nTRANSCODE_ROOT=%s/repo/transcodes\nBACKUP_ROOT=%s/repo/backups\n' "$T" "$T" "$T" "$T" "$T" > "$ENV_FILE"
SCRIPT_DIR=$T/repo
repo_owned() { :; }
sudo() { "$@"; }
docker() { [[ "$*" == "info --format {{.DockerRootDir}}" ]] && echo "$T/var-docker"; }
# df: each path's filesystem from $T/fs.<name> -> "mount size avail inodes free"
fs() { printf '%s %s %s %s %s\n' "$2" "$3" "$4" "$5" "$6" > "$T/fs.$1"; }
df() {
    local p=${!#} f
    case "$p" in "$T"/media*) f=media ;; "$T"/var-docker*) f=docker ;; "$T"/repo*) f=repo ;; *) return 1 ;; esac
    echo "Mounted on 1B-blocks Avail Inodes IFree"; cat "$T/fs.$f"
}
notify() { printf '%s|%s|%s\n' "$1" "$2" "$4" >> "$T/sent"; }
sent() { [[ -e "$T/sent" ]] && wc -l < "$T/sent" || echo 0; }

# ---- the targets and how they group ----
fs repo /srv 100000000000 60000000000 1000000 900000
fs media /mnt/media 20000000000000 15000000000000 0 0
fs docker /var 50000000000 30000000000 1000000 900000
rep=$(disk_report)
[[ $(wc -l <<<"$rep") == 3 ]] || fail_ "one line per filesystem: $rep"; pass
grep -qP '^ok\t/srv\tCONFIG_ROOT, CACHE_ROOT, TRANSCODE_ROOT, BACKUP_ROOT, this folder\t' <<<"$rep" \
    && grep -qP "^ok\t/var\tDocker's data\t" <<<"$rep" && grep -qP '^ok\t/mnt/media\tDATA_ROOT\t' <<<"$rep" \
    || fail_ "each names what lives on it: $rep"; pass
[[ "$(disk_existing "$T/repo/config/not/made")" == "$T/repo" ]] || fail_ "a root not made yet is judged where it will be"; pass

# ---- the levels ----
lvl() { disk_report | awk -F'\t' -v m="$1" '$2 == m { print $1 }'; }
fs repo /srv 100000000000 $(( 2 * G - 1 )) 1000000 900000;           [[ $(lvl /srv) == fail ]] || fail_ "under 2 GiB free: fail"; pass
fs repo /srv 100000000000 $(( 3 * G )) 1000000 40000;                 [[ $(lvl /srv) == fail ]] || fail_ "4% of inodes left: fail"; pass
fs repo /srv 100000000000 $(( 9 * G )) 1000000 900000;                [[ $(lvl /srv) == warn ]] || fail_ "9% free, 9 GiB: warn"; pass
fs media /mnt/media 20000000000000 1000000000000 0 0;                 [[ $(lvl /mnt/media) == ok ]] || fail_ "5% free but 1 TB left: ok"; pass
fs repo /srv 100000000000 $(( 20 * G )) 1000000 900000;               [[ $(lvl /srv) == ok ]] || fail_ "20% free: ok"; pass
fs repo /srv 100000000000 $(( 20 * G )) 0 0;                          [[ $(lvl /srv) == ok ]] || fail_ "a filesystem without inode counts (btrfs, NFS) is judged by space alone"; pass

# ---- doctor ----
fs repo /srv 100000000000 $(( 1 * G )) 1000000 900000
D_FAILS=0; out=$(_doctor_disk); _doctor_disk > /dev/null
(( D_FAILS == 1 )) && [[ "$out" == *"FAIL disk /srv (CONFIG_ROOT, CACHE_ROOT, TRANSCODE_ROOT, BACKUP_ROOT, this folder): 1.0GiB free of 94GiB (1%)"* && "$out" == *"fix : free space there"* ]] \
    || fail_ "doctor: a fail is a problem, named with what lives there and how to fix it ($D_FAILS): $out"; pass
fs repo /srv 100000000000 $(( 9 * G )) 1000000 900000
D_FAILS=0; out=$(_doctor_disk); _doctor_disk > /dev/null
(( D_FAILS == 0 )) && [[ "$out" == *"WARN disk /srv"*"under 10% free; it fails below 2.0GiB"* ]] || fail_ "doctor: a warning, not a problem: $out"; pass
grep -q '_doctor_disk' <(awk '/^_doctor_resources\(\)/,/^}/' lib/doctor.sh) || fail_ "doctor's host resources run it"; pass

# ---- nightly ----
rm -f "$T/sent"; rm -rf "$STATE_DIR"
fs repo /srv 100000000000 $(( 1 * G )) 1000000 900000
disk_watch > /dev/null; disk_watch > /dev/null
[[ $(sent) == 2 ]] && grep -q '^ops|Mediastack: a disk is nearly full|failure$' "$T/sent" || fail_ "a failure reaches ops every night: $(cat "$T/sent")"; pass
rm -f "$T/sent"; fs repo /srv 100000000000 $(( 9 * G )) 1000000 900000
disk_watch > /dev/null; disk_watch > /dev/null
[[ $(sent) == 1 ]] && grep -q '^ops|Mediastack: a disk is getting full|warning$' "$T/sent" || fail_ "a warning reaches ops once: $(cat "$T/sent")"; pass
for f in "$STATE_DIR"/disk-warned-*; do echo $(( EPOCHSECONDS - DISK_WARN_EVERY - 1 )) > "$f"; done
disk_watch > /dev/null; [[ $(sent) == 2 ]] || fail_ "and again a week later"; pass
fs repo /srv 100000000000 $(( 20 * G )) 1000000 900000; disk_watch > /dev/null
[[ -z "$(ls "$STATE_DIR"/disk-warned-* 2>/dev/null)" ]] || fail_ "back to ok: the mark goes, so the next warning is told at once"; pass
SCRIPT_DIR=$SCRIPT_DIR_REAL
awk '/^manifest_take\(\)/ { f = 1 } f && /^    disk_watch/ { ok = 1 } f && /scan/ { exit } END { exit !ok }' lib/manifest.sh || fail_ "the nightly manifest checks the disks first"; pass

echo "OK disk: $checks checks"
