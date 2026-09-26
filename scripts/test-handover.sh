#!/usr/bin/env bash
# test-handover.sh — the one-time UID ownership handover (uid_handover and
# the migration that schedules it), end to end against a throwaway tree.
# No docker, no root: sudo, docker and container state are local stand-ins,
# so the real migration and handover code runs unmodified. Each check guards
# a way this broke, or nearly broke, while it was built:
#   1. the migration only MARKS the handover — migrations also run from
#      `upgrade` and the panel's 5-minute timer, where stopping a service
#      would leave it down unattended
#   2. the handover stops a running container BEFORE changing ownership
#      (a still-root app keeps creating root files, e.g. SQLite -wal/-shm)
#   3. a failed chown dies and KEEPS the marker, so the next `up` retries
#   4. a second `up` is a no-op
#
#   scripts/test-handover.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-handover.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"

# shellcheck disable=SC2034  # read by the sourced migrate_env
LOCAL_DIR=$T/local
# shellcheck disable=SC2034
ENV_BACKUP_DIR=$T/local/env-backups
ENV_FILE=$T/.env
printf 'ENV_SCHEMA=22\nMEDIA_GROUP_GID=%s\nCONFIG_ROOT=%s/config\nCACHE_ROOT=%s/cache\nDATA_ROOT=%s/data\nAUDIOBOOKSHELF_UID=%s\nKAVITA_UID=%s\n' \
    "$(id -g)" "$T" "$T" "$T" "$(id -u)" "$(id -u)" > "$ENV_FILE"

# stand-ins: every action is appended to $T/log, in order
sudo()       { "$@"; }
svc_cname()  { echo "mediastack-$1"; }
c_state()    { [[ -f "$T/running.$1" ]] && echo running || echo exited; }
docker()     { echo "docker $*" >> "$T/log"; [[ "$1" == stop ]] && rm -f "$T/running.$2"; return 0; }
chown()      { echo "chown $*" >> "$T/log"; [[ ! -f "$T/chown-fails" ]]; }
# the migration's own .env backup is handed to the repo owner (repo_owned) —
# repo bookkeeping, not the service-file handover this test pins; stubbed so
# the result does not depend on whether the test runs as root
repo_owned() { :; }
find()       { echo "find $*" >> "$T/log"; }

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }
: > "$T/log"
mkdir -p "$T/config/kavita" "$T/config/audiobookshelf" "$T/cache/audiobookshelf" "$T/data/media/podcasts"
touch "$T/running.mediastack-kavita" "$T/running.mediastack-audiobookshelf"

# 1. migration marks only — no stop, no chown
migrate_env >/dev/null
[[ "$(env_get UID_HANDOVER)" == "audiobookshelf kavita" ]] || fail_ "migration must set UID_HANDOVER"; pass
[[ ! -s "$T/log" ]] || fail_ "migration must not stop or chown anything: $(cat "$T/log")"; pass
[[ -f "$T/running.mediastack-kavita" ]] || fail_ "migration stopped kavita"; pass

# 3. a failed chown dies and keeps the marker
touch "$T/chown-fails"
set +e; out=$( ( set -e; uid_handover ) 2>&1 ); rc=$?; set -e
[[ $rc != 0 ]] || fail_ "a failed chown must stop the handover"; pass
grep -q 'UID_HANDOVER is kept' <<<"$out" || fail_ "failure must say the marker is kept: $out"; pass
[[ -n "$(env_get UID_HANDOVER)" ]] || fail_ "failure must keep UID_HANDOVER"; pass
rm -f "$T/chown-fails"

# 2. stop comes before any chown, for each service
: > "$T/log"; touch "$T/running.mediastack-kavita" "$T/running.mediastack-audiobookshelf"
( set -e; uid_handover ) >/dev/null
for s in audiobookshelf kavita; do
    stop=$(grep -n "docker stop mediastack-$s" "$T/log" | head -1 | cut -d: -f1)
    own=$(grep -n "chown -R .* $T/config/$s" "$T/log" | head -1 | cut -d: -f1)
    [[ -n "$stop" && -n "$own" && "$stop" -lt "$own" ]] || fail_ "$s: stop must precede chown: $(cat "$T/log")"; pass
done
grep -q "chown -R .* $T/cache/audiobookshelf" "$T/log" || fail_ "audiobookshelf cache must be handed over"; pass
grep -q "find $T/data/media/podcasts -mindepth 1 -user 0" "$T/log" || fail_ "only root-owned media entries may be handed over"; pass
[[ -z "$(env_get UID_HANDOVER)" ]] || fail_ "success must clear UID_HANDOVER"; pass

# 4. second up is a no-op
: > "$T/log"
( set -e; uid_handover ) >/dev/null
[[ ! -s "$T/log" ]] || fail_ "a second handover must do nothing: $(cat "$T/log")"; pass

echo "OK handover: $checks checks"
