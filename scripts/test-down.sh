#!/usr/bin/env bash
# test-down.sh — a stack stopped with `down` stays down until `up`:
#   * `down` leaves the mark; `up` lifts it before anything else
#   * inside one of the stack's own systemd units (timers, the boot guard, the
#     failure notice) every verb skips while the mark stands, exiting 0;
#     the same verb run by hand, or with no mark, runs
#   * a backup of the whole stack stops and starts again only what was
#     running: a stopped stack is backed up cold and stays stopped
#   * a start other than `up` says once that scheduled jobs stay paused
# Each case runs in its own bash that sources the real entrypoint (minus its
# last line, main "$@") with Docker and the host stubbed.
#
#   scripts/test-down.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-down.XXXXXX)
T=$(mktemp -d); export T
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"

cat > "$T/fx.sh" <<'EOF'
LOCAL_DIR=$T/local; STATE_DIR=$T/local/state; STOP_MARKER=$T/local/marker
CGROUP_FILE=$T/cgroup
load_env()   { :; }
repo_owned() { :; }
notify()     { :; }
sudo()       { echo "sudo $*" >> "$T/sudo"; }
# compose: ps answers from $T/ps (a missing file is a failed ps); the rest is
# recorded. REAL_DC=1 keeps the entrypoint's own wrapper (its docker call goes to sudo)
[[ -n "${REAL_DC:-}" ]] || DC() {
    if [[ "$1" == ps ]]; then cat "$T/ps"; return; fi
    echo "DC $*" >> "$T/dc"
}
EOF

# run 'CODE' -> rc in $rc, stdout+stderr in $T/out
run() {
    rc=0
    bash -c "source '$lib'; source '$T/fx.sh'; $1" > "$T/out" 2>&1 || rc=$?
}
reset() { rm -rf "$T/local" "$T/dc" "$T/sudo" "$T/ps" "$T/ran" "$T/cgroup"; mkdir -p "$T/local/state"; }
mark()  { echo "2026-10-14 10:00 PDT" > "$T/local/state/stack-down"; }
unit()  { echo "0::$1" > "$T/cgroup"; }
checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; echo "--- output:" >&2; cat "$T/out" >&2; exit 1; }

# ---- down marks, up lifts first ----
reset
run 'cmd_down'
[[ $rc == 0 && -s "$T/local/state/stack-down" ]] || fail_ "down leaves the mark"; pass
grep -q 'DC down --volumes' "$T/dc" || fail_ "down stops the stack"; pass
grep -q 'paused until' "$T/out" || fail_ "down says scheduled jobs are paused"; pass
run 'vpn_gen() { exit 7; }; cmd_up'   # stop up at its first step after the lift
[[ $rc == 7 && ! -e "$T/local/state/stack-down" ]] || fail_ "up lifts the mark before anything else (rc=$rc)"; pass

# ---- the stack's own units skip while the mark stands ----
stub='cmd_update() { echo ran > "$T/ran"; }; cmd_backup() { echo ran > "$T/ran"; }'
for u in /system.slice/mediastack-update.service \
         /system.slice/mediastack-vpnguard.service \
         '/system.slice/system-mediastack\x2dfailure.slice/mediastack-failure@mediastack-update.service.service'; do
    reset; mark; unit "$u"
    run "$stub; main update --auto"
    [[ $rc == 0 && ! -e "$T/ran" ]] || fail_ "a run inside $u skips while down (rc=$rc)"; pass
    grep -q "skipping 'update --auto'" "$T/out" || fail_ "the skip names the verb"; pass
done
reset; mark; unit /system.slice/mediastack-backup.service
run "$stub; main backup --auto"
[[ $rc == 0 && ! -e "$T/ran" ]] || fail_ "the scheduled backup skips while down"; pass

reset; mark; unit /user.slice/user-1000.slice/session-3.scope
run "$stub; main update --auto"
[[ $rc == 0 && -e "$T/ran" ]] || fail_ "a verb run by hand runs while down"; pass
reset; unit /system.slice/mediastack-update.service
run "$stub; main update --auto"
[[ $rc == 0 && -e "$T/ran" ]] || fail_ "with no mark the scheduled job runs"; pass
reset; mark; rm -f "$T/cgroup"
run "$stub; main update --auto"
[[ $rc == 0 && -e "$T/ran" ]] || fail_ "no cgroup file reads as not scheduled"; pass

# ---- a whole-stack backup starts again only what it stopped ----
job='job() { echo ran > "$T/ran"; }'
reset; : > "$T/ps"
run "$job; stopped_run backup '' job"
[[ $rc == 0 && -e "$T/ran" ]] || fail_ "with nothing running the backup still runs (rc=$rc)"; pass
[[ ! -e "$T/dc" && ! -e "$T/local/marker" ]] || fail_ "with nothing running nothing is stopped or started: $(cat "$T/dc" 2>/dev/null)"; pass

reset; printf 'radarr\nsonarr\n' > "$T/ps"
run "$job; stopped_run backup '' job"
[[ $rc == 0 && -e "$T/ran" ]] || fail_ "the backup runs (rc=$rc)"; pass
grep -qx 'DC stop radarr sonarr' "$T/dc" || fail_ "what is running is stopped: $(cat "$T/dc")"; pass
grep -qx 'DC up -d radarr sonarr' "$T/dc" || fail_ "and only that starts again: $(cat "$T/dc")"; pass

reset   # no $T/ps: compose cannot list
run "$job; stopped_run backup '' job"
[[ $rc == 1 && ! -e "$T/ran" && ! -e "$T/dc" ]] || fail_ "a failed listing stops the backup before anything (rc=$rc)"; pass
grep -q 'could not list the running services' "$T/out" || fail_ "and says why"; pass

reset; printf 'radarr\n' > "$T/ps"
run "$job; stopped_run 'pre-update restore point (sonarr)' sonarr job"
grep -qx 'DC stop sonarr' "$T/dc" && grep -qx 'DC up -d sonarr' "$T/dc" || fail_ "named services are used as given: $(cat "$T/dc")"; pass

# ---- a start other than up says the jobs stay paused, once ----
reset; mark
REAL_DC=1 run 'DC up -d radarr; DC start sonarr'
[[ $(grep -c 'stay paused' "$T/out") == 1 ]] || fail_ "one warning per run"; pass
grep -q 'docker compose .* up -d radarr' "$T/sudo" || fail_ "the start still happens"; pass
reset
REAL_DC=1 run 'DC up -d radarr'
! grep -q 'stay paused' "$T/out" || fail_ "no warning without the mark"; pass

echo "test-down: $checks checks passed"
