#!/usr/bin/env bash
# test-restore-point.sh — latest_restore_point, the one way status, doctor,
# `backup verify` and `restore --all` find the newest GFS restore point.
# BACKUP_ROOT also holds pre-update/ and manifest/, which sort after any
# timestamp: "newest entry in the folder" picked them (status showed
# "pre-update"; backup verify failed on every install with a scoped update).
# Doctor warns when BACKUP_ROOT shares a filesystem with the configs (or the
# media); a btrfs subvolume counts as its filesystem.
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

echo "OK restore-point: $checks checks"
