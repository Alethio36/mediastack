#!/usr/bin/env bash
# test-restore-point.sh — latest_restore_point, the one way status, doctor,
# `backup verify` and `restore --all` find the newest GFS restore point.
# BACKUP_ROOT also holds pre-update/ and manifest/, which sort after any
# timestamp: "newest entry in the folder" picked them (status showed
# "pre-update"; backup verify failed on every install with a scoped update).
# Doctor warns when BACKUP_ROOT shares a filesystem with the configs (or the
# media); a btrfs subvolume counts as its filesystem.
# Stopped services come back: a backup's stop is undone on any exit (success,
# an error, a signal, a failed archive) and, after a power cut, at boot; a
# point is built as <ts>.partial, never picked until complete, and a leftover
# is removed by the next prune. The boot unit is 644.
#
#   scripts/test-restore-point.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-restore-point.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"
ENV_FILE=$T/.env
printf 'BACKUP_ROOT=%s/bk\n' "$T" > "$ENV_FILE"

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$T/bk"
[[ -z "$(latest_restore_point)" ]] || fail_ "empty BACKUP_ROOT must give none"; pass

mkdir -p "$T/bk/pre-update/20260925-010101" "$T/bk/manifest"
[[ -z "$(latest_restore_point)" ]] || fail_ "pre-update/ and manifest/ alone are not restore points"; pass

mkdir -p "$T/bk/20260923-040000" "$T/bk/20260924-040000"
touch "$T/bk/20260926-040000"      # a stray FILE with a timestamp name is not a point
[[ "$(latest_restore_point)" == 20260924-040000 ]] || fail_ "newest point: got '$(latest_restore_point)'"; pass

# ---- same filesystem: findmnt answers from a table (path -> SOURCE) ----
mkdir -p "$T/bin"
cat > "$T/bin/findmnt" <<'SH'
#!/bin/sh
for a; do t=$a; done
grep "^$t " "$FM_TABLE" | cut -d' ' -f2
SH
chmod +x "$T/bin/findmnt"; PATH=$T/bin:$PATH; export FM_TABLE=$T/fm
fm() { printf '%s\n' "$@" > "$FM_TABLE"; }
fm "/cfg /dev/sda2[/@configs]" "/bk /dev/sda2[/@backups]" "/nas nas:/backups"
[[ "$(fs_source_of /cfg)" == /dev/sda2 ]] || fail_ "a btrfs subvolume is its filesystem: $(fs_source_of /cfg)"; pass
[[ "$(fs_shared /cfg /bk)" == /dev/sda2 ]] || fail_ "two subvolumes of one filesystem are shared"; pass
! fs_shared /cfg /nas >/dev/null || fail_ "a NAS is not the configs' disk"; pass
! fs_shared /cfg /missing >/dev/null || fail_ "an unknown path is never 'shared'"; pass
warn() { echo "WARN $*"; }
printf 'CONFIG_ROOT=/cfg\nBACKUP_ROOT=/bk\n' > "$ENV_FILE"
[[ "$(_doctor_backup_disk)" == *"shares a filesystem with the configs (/dev/sda2)"* ]] || fail_ "doctor warns: backups beside the configs"; pass
printf 'CONFIG_ROOT=/cfg\nBACKUP_ROOT=/nas\n' > "$ENV_FILE"
[[ -z "$(_doctor_backup_disk)" ]] || fail_ "doctor is quiet: backups on another disk"; pass

# ---- stopped services come back, whatever ends the work ----
printf 'BACKUP_ROOT=%s/bk\n' "$T" > "$ENV_FILE"
sudo() { "$@"; }
DC() { echo "DC $*" >> "$T/log"; [[ "$1" != up ]] || return "${DC_UP_RC:-0}"; }
notify() { echo "NOTIFY $2" >> "$T/log"; }
fail() { echo "FAIL $*" >> "$T/log"; }; warn() { echo "WARN $*" >> "$T/log"; }; info() { :; }; ok() { :; }
mkdir -p "$T/bk/20260927-040000.partial"
[[ "$(latest_restore_point)" == 20260924-040000 ]] || fail_ "an incomplete <ts>.partial is never the newest point"; pass
mkdir -p "$T/bk/pre-update/20260927-030000.partial" "$T/bk/pre-update/20260926-030000"
prune_partial "$T/bk"; prune_partial "$T/bk/pre-update"
[[ ! -e "$T/bk/20260927-040000.partial" && ! -e "$T/bk/pre-update/20260927-030000.partial" ]] || fail_ "prune removes leftover .partial points"; pass
[[ -d "$T/bk/20260924-040000" && -d "$T/bk/pre-update/20260926-030000" ]] || fail_ "prune_partial touches nothing complete"; pass

LOCAL_DIR=$T/local; STOP_MARKER=$LOCAL_DIR/stopped-for-backup
work_ok()      { echo "WORK marker=$(cat "$STOP_MARKER" | tr '\n' '|')" >> "$T/log"; }
work_error()   { false; }                              # set -e aborting the work
work_signal()  { kill -TERM "$BASHPID"; }              # Ctrl-C, SSH drop, shutdown
work_partial() { return "$BACKUP_PARTIAL"; }           # finished, an archive failed
run() { # run SVCS "WORK [ARG...]" -> "rc=N | log lines | marker=yes/no"
    rm -f "$T/log"; local rc=0
    # shellcheck disable=SC2086  # WORK is a command line
    stopped_run backup "$1" $2 2>/dev/null || rc=$?
    echo "rc=$rc | $(tr '\n' '|' < "$T/log") marker=$([[ -f "$STOP_MARKER" ]] && echo yes || echo no)"
}
out=$(run "" work_ok)
[[ "$out" == "rc=0 | DC stop|WORK marker=backup||"*"DC up -d|"*"marker=no" && "$out" != *NOTIFY* ]] \
    || fail_ "success: stop, work (marker naming it), start, marker gone, no alert: $out"; pass
out=$(run "" work_error)
[[ "$out" == "rc=1 | "*"DC up -d|"*"NOTIFY Mediastack backup stopped early — services running again"*"marker=no" ]] || fail_ "an error: started again and alerted: $out"; pass
out=$(run "" work_signal)
[[ "$out" == "rc=143 | "*"DC up -d|"*"NOTIFY Mediastack backup stopped early — services running again"*"marker=no" ]] || fail_ "a signal: started again and alerted: $out"; pass
out=$(run "" work_partial)
[[ "$out" == "rc=$BACKUP_PARTIAL | "*"DC up -d|"*"marker=no" && "$out" != *"stopped early"* ]] \
    || fail_ "a failed archive: started again, left to the caller's FAILED alert: $out"; pass
out=$(run "sonarr " work_ok)
[[ "$out" == *"DC stop sonarr|"*"DC up -d sonarr|"* ]] || fail_ "a scoped stop starts exactly what it stopped: $out"; pass
out=$(DC_UP_RC=1 run "" work_ok)
[[ "$out" == "rc=1 | "*"FAIL"*"did not start again"*"NOTIFY Mediastack is DOWN"*"marker=yes" ]] \
    || fail_ "services that will not start: a failure, an alert, the marker kept for boot: $out"; pass
# found reproducing the bug: a failed copy under the caller's || (where bash
# ignores set -e) must still fail — not finish as a complete point
mkdir -p "$T/cfg/sonarr" "$T/pt"
svc_managed_where() { echo sonarr; }
# shellcheck disable=SC2034  # read by backup_snapshot
PINS_FILE=$T/nopins CUSTOM_DIR=$T/nocustom
sudo() { [[ "$1" == cp && "$*" == *"/env" ]] && return 1; "$@"; }
out=$(run "" "backup_snapshot $T/cfg $T/pt")
[[ "$out" == "rc=1 | "*"could not copy .env"*"DC up -d|"*"stopped early"*"marker=no" ]] || fail_ "a failed .env copy: a failure, services started again: $out"; pass
sudo() { "$@"; }
out=$(run "" "backup_snapshot $T/cfg $T/pt")
[[ "$out" == "rc=0 | "*"DC up -d|"*"marker=no" && -s "$T/pt/sonarr.tar.gz" && -s "$T/pt/env" && -s "$T/pt/SHA256SUMS" ]] \
    || fail_ "a whole snapshot: archive, env, checksums, services started again: $out"; pass
DC() { echo "DC $*" >> "$T/log"; [[ "$1" != stop ]]; }
out=$(run "" work_ok)
[[ "$out" == "rc=1 | "*"could not stop"*"DC up -d|"*"marker=no" && "$out" != *WORK* ]] || fail_ "a failed stop: no work on running services: $out"; pass
DC() { echo "DC $*" >> "$T/log"; [[ "$1" != up ]] || return "${DC_UP_RC:-0}"; }
printf 'backup\n\n' > "$STOP_MARKER"   # what a power cut leaves
rm -f "$T/log"; stopped_recover; [[ "$(cat "$T/log")" == *"DC up -d"*"NOTIFY Mediastack backup cut off — services started again at boot"* && ! -f "$STOP_MARKER" ]] \
    || fail_ "at boot, a marker left behind: its services started, alerted, marker gone: $(cat "$T/log")"; pass
rm -f "$T/log"; stopped_recover; [[ ! -s "$T/log" ]] || fail_ "at boot, no marker: nothing started"; pass
# the boot unit is 644 like every unit (found live: mktemp's 600 made
# `systemctl cat` refuse users), and an existing 600 one is repaired
SYSTEMD_DIR=$T/systemd; VPNGUARD_UNIT=$SYSTEMD_DIR/mediastack-vpnguard.service; mkdir -p "$SYSTEMD_DIR"
systemctl() { :; }
vpnguard_ensure; [[ "$(stat -c %a "$VPNGUARD_UNIT")" == 644 ]] || fail_ "a new boot unit is 644: $(stat -c %a "$VPNGUARD_UNIT")"; pass
chmod 600 "$VPNGUARD_UNIT"; vpnguard_ensure
[[ "$(stat -c %a "$VPNGUARD_UNIT")" == 644 ]] || fail_ "an existing 600 boot unit with the same content is repaired"; pass
grep -q 'stopped_recover' <(awk '/^cmd_vpn_guard\(\)/,/^}/' lib/vpn.sh) || fail_ "the boot guard runs stopped_recover"; pass

echo "OK restore-point: $checks checks"
