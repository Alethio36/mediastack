#!/usr/bin/env bash
# test-restore-point.sh — latest_restore_point, the one way status, doctor,
# `backup verify` and `restore --all` find the newest GFS restore point.
# BACKUP_ROOT also holds pre-update/ and manifest/, which sort after any
# timestamp: "newest entry in the folder" picked them (status showed
# "pre-update"; backup verify failed on every install with a scoped update).
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

echo "OK restore-point: $checks checks"
