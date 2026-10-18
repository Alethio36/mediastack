#!/usr/bin/env bash
# soak.sh — simulated days of use on a TEST BOX (never a stack you keep).
#
# Each simulated day runs the stack's night jobs (manifest, update, backup —
# whichever timers are enabled, on the days and times their OnCalendar says)
# with the clock moved forward by faketime, inside transient systemd units
# named like the real ones (so the script sees a scheduled run), then judges
# the day:
#   * every night job exited 0
#   * doctor: no FAIL line beyond the known file's patterns, and no
#     notification stream whose last send failed
#   * wire --verify: no drift
#   * containers: all running, none unhealthy, no restart count went up
#   * restore points: no more than the retention keeps
# Before the simulated days, each enabled timer's real unit runs once at the
# real time: the units themselves are proven, not only their commands.
#
# Not covered (the clock is the script's alone): anything run through sudo,
# and the containers, see the real time; a check that reads a timestamp they
# wrote is judged against real time, not the simulated day.
#
# It leaves restore points, manifests and state dated in the future: REVERT
# THE BOX (its snapshot) afterwards. It refuses to run without --test-box.
#
#   scripts/soak.sh --test-box [--days N] [--known FILE]   run (exit 1 if any day failed)
#   scripts/soak.sh --plan [--days N]                       print the simulated schedule only
#
# The known file holds one extended regex per line (# comments) for doctor
# FAIL lines expected on this box (e.g. "No indexers" on a fresh install);
# entries that matched nothing are reported, so a stale one surfaces.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO=$PWD

die() { echo "soak: $*" >&2; exit 1; }
DAYS=7 KNOWN="" PLAN=0 TESTBOX=0
while (( $# )); do
    case "$1" in
        --days)     DAYS=${2:?--days needs a number}; shift 2 ;;
        --known)    KNOWN=${2:?--known needs a file}; shift 2 ;;
        --plan)     PLAN=1; shift ;;
        --test-box) TESTBOX=1; shift ;;
        *) die "unknown argument: $1" ;;
    esac
done
[[ "$DAYS" =~ ^[1-9][0-9]?$ ]] || die "--days takes 1-99 (got: $DAYS)"
[[ -z "$KNOWN" || -r "$KNOWN" ]] || die "known file not readable: $KNOWN"

JOBS=(manifest update backup)   # the night jobs with timers (lib/backup.sh apply_timer)
unit_cmd() { # unit_cmd JOB -> the ExecStart its real unit runs ("" when the timer is not enabled)
    systemctl is-enabled --quiet "mediastack-$1.timer" 2>/dev/null || return 0
    sed -n 's/^ExecStart=//p' "/etc/systemd/system/mediastack-$1.service" | head -1
}
unit_calendar() { sed -n 's/^OnCalendar=//p' "/etc/systemd/system/mediastack-$1.timer" | head -1; }

# ---- the simulated schedule: "YYYY-MM-DD HH:MM:SS JOB" lines, in time order ----
START=$(date '+%F %T')
# by epoch: GNU date reads "<time> + N days" as a timezone offset
END=$(date -d "@$(( $(date -d "$START" +%s) + DAYS * 86400 ))" '+%F %T')
schedule() {
    local job cal t
    for job in "${JOBS[@]}"; do
        [[ -n "$(unit_cmd "$job")" ]] || continue
        cal=$(unit_calendar "$job")
        [[ -n "$cal" ]] || die "mediastack-$job.timer has no OnCalendar"
        # systemd's own reading of the calendar: weekly jobs land on their day
        t=$(systemd-analyze calendar --base-time="$START" --iterations=$((DAYS * 2 + 2)) "$cal" 2>&1) \
            || die "systemd cannot read mediastack-$job.timer's OnCalendar '$cal': $t"
        sed -nE 's/^ *(Next elapse|Iteration #[0-9]+): [A-Za-z]{3} ([0-9-]+ [0-9:]+).*/\2/p' <<<"$t" \
            | while read -r t; do if [[ "$t" < "$END" ]]; then echo "$t $job"; fi; done
    done | sort
}

command -v systemd-analyze >/dev/null || die "systemd-analyze is missing"
systemd-analyze calendar --base-time="$START" --iterations=1 '*-*-* 00:00' >/dev/null 2>&1 \
    || die "this systemd-analyze has no --base-time (systemd 248+ needed)"
SCHED=$(schedule)
[[ -n "$SCHED" ]] || die "no enabled night-job timers (mediastack-{manifest,update,backup}.timer) — nothing to simulate"

if (( PLAN )); then
    echo "simulated schedule, $DAYS day(s) from $START:"
    sed 's/^/  /' <<<"$SCHED"
    exit 0
fi

# ---- preconditions ----
(( TESTBOX )) || die "this writes restore points, manifests and state dated in the future.
  Run it only on a test box you will revert to its snapshot afterwards, with: --test-box"
(( $(id -u) != 0 )) || die "run it as the stack's operator (it uses sudo), not as root"
command -v faketime >/dev/null || die "faketime is missing: sudo apt install faketime"
command -v jq >/dev/null || die "jq is missing"
[[ -f .env ]] || die "no .env — run it from a configured stack's folder"
sudo -v || die "sudo is needed"
( while kill -0 $$ 2>/dev/null; do sudo -n -v 2>/dev/null; sleep 60; done ) </dev/null >/dev/null 2>&1 &
KEEPALIVE=$!
trap 'kill $KEEPALIVE 2>/dev/null || true' EXIT

LOG="$HOME/soak-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
envget() { sed -n "s/^$1=//p" .env | tail -1; }
strip() { sed -E 's/\x1b\[[0-9;]*m//g'; }

# ---- the day's verdict pieces ----
FAILED_DAYS=0 DAY_PROBLEMS=()
problem() { DAY_PROBLEMS+=("$1"); echo "  PROBLEM: $1"; }
declare -A KNOWN_HIT=()
known_patterns() { [[ -n "$KNOWN" ]] && grep -vE '^\s*(#|$)' "$KNOWN" || true; }
is_known() { # is_known LINE -> 0 when a known pattern matches it (and marks that pattern used)
    local p
    while IFS= read -r p; do
        if grep -qE -- "$p" <<<"$1"; then KNOWN_HIT[$p]=1; return 0; fi
    done < <(known_patterns)
    return 1
}
containers() { # NAME STATE STATUS RESTARTS for this stack's containers
    local ids
    ids=$(sudo docker ps -aq --filter "label=com.docker.compose.project.working_dir=$REPO")
    [[ -n "$ids" ]] || return 0
    # shellcheck disable=SC2086  # a word list of ids
    sudo docker inspect $ids | jq -r '.[] | [(.Name|ltrimstr("/")), .State.Status, (.State.Health.Status // "-"), .RestartCount] | @tsv'
}
declare -A RESTARTS=()
note_restarts() { local n s h r; while IFS=$'\t' read -r n s h r; do RESTARTS[$n]=$r; done < <(containers); }
judge_containers() {
    local i n s h r settled=0
    for (( i = 0; i < 36; i++ )); do   # up to 3 min for health checks to settle after the night
        containers | awk -F'\t' '$3 == "starting"' | grep -q . || { settled=1; break; }
        sleep 5
    done
    (( settled )) || problem "containers still starting their health checks after 3 minutes"
    while IFS=$'\t' read -r n s h r; do
        [[ "$s" == running ]] || problem "container $n is $s"
        [[ "$h" == unhealthy ]] && problem "container $n is unhealthy"
        if [[ -n "${RESTARTS[$n]:-}" ]] && (( r > RESTARTS[$n] )); then
            problem "container $n restarted on its own ($((r - RESTARTS[$n])) time(s))"
        fi
        RESTARTS[$n]=$r
    done < <(containers)
}
judge_points() {
    local broot keep n
    broot=$(envget BACKUP_ROOT); broot=${broot:-./backups}
    [[ "$broot" == /* ]] || broot="$REPO/${broot#./}"
    local kd kw km
    kd=$(envget BACKUP_KEEP_DAILY); kw=$(envget BACKUP_KEEP_WEEKLY); km=$(envget BACKUP_KEEP_MONTHLY)
    keep=$(( ${kd:-7} + ${kw:-4} + ${km:-6} ))   # empty means the schema's default
    n=$(sudo find "$broot" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
        -regex '.*/[0-9]{8}-[0-9]{6}' 2>/dev/null | wc -l)
    echo "  restore points: $n (retention keeps at most $keep)"
    (( n <= keep )) || problem "$n restore points — retention keeps at most $keep"
}
judge_doctor() { # judge_doctor FAKE-TIME
    local out line
    out=$(FAKETIME_DONT_RESET=1 faketime -f "@$1" ./mediastack.sh doctor 2>&1 | strip || true)
    while IFS= read -r line; do
        [[ "$line" == "FAIL doctor:"* ]] && continue
        is_known "$line" || problem "doctor: ${line#FAIL }"
    done < <(grep '^FAIL ' <<<"$out" || true)
    grep -q 'the last notification failed' <<<"$out" \
        && problem "doctor: a notification stream's last send failed ($(grep -m1 'the last notification failed' <<<"$out"))"
    return 0
}
judge_wire() { # judge_wire FAKE-TIME
    local out
    if ! out=$(FAKETIME_DONT_RESET=1 faketime -f "@$1" ./mediastack.sh wire --verify 2>&1 | strip); then
        problem "wire --verify: $(grep -E '^(FAIL|  would:)' <<<"$out" | head -5 | tr '\n' ' ')"
    fi
}
run_job() { # run_job JOB FAKE-TIME|"" -> the job's unit, under the simulated clock when given
    local job=$1 at=$2 cmd unit rc=0
    cmd=$(unit_cmd "$job")
    unit="mediastack-soak-$job-$(date +%s%N | tail -c 7)"   # a mediastack-*.service: the script sees a scheduled run
    if [[ -n "$at" ]]; then
        # shellcheck disable=SC2086  # the unit's ExecStart, word-split as systemd does
        sudo systemd-run --quiet --wait --pipe --collect --unit="$unit" -p WorkingDirectory="$REPO" \
            -E FAKETIME_DONT_RESET=1 /usr/bin/faketime -f "@$at" $cmd </dev/null | strip | sed 's/^/    | /' || rc=$?
    else
        sudo systemctl start --wait "mediastack-$job.service" || rc=$?
    fi
    (( rc == 0 )) && echo "  $job: ok" || problem "$job (${at:-real time}) exited $rc — journal: journalctl -u ${at:+$unit}${at:-mediastack-$job.service}"
}

# ---- run ----
echo "soak: $DAYS simulated day(s) from $START on $(hostname) — log: $LOG"
echo "== the real units, once, at the real time"
DAY_PROBLEMS=()
for job in "${JOBS[@]}"; do [[ -n "$(unit_cmd "$job")" ]] && run_job "$job" ""; done
note_restarts
(( ${#DAY_PROBLEMS[@]} )) && FAILED_DAYS=$((FAILED_DAYS + 1))

for d in $(cut -d' ' -f1 <<<"$SCHED" | uniq); do
    echo "== simulated $d"
    DAY_PROBLEMS=()
    last=""
    while read -r day t job; do
        [[ "$day" == "$d" ]] || continue
        echo "  $t $job"
        run_job "$job" "$day $t"
        last="$day $t"
    done <<<"$SCHED"
    # the day's checks: noon, or half an hour after a late job
    verdict=$(date -d "$d 12:00:00" '+%F %T')
    later=$(date -d "@$(( $(date -d "$last" +%s) + 1800 ))" '+%F %T')
    [[ "$later" > "$verdict" ]] && verdict=$later
    judge_containers
    judge_doctor "$verdict"
    judge_wire "$verdict"
    judge_points
    if (( ${#DAY_PROBLEMS[@]} )); then FAILED_DAYS=$((FAILED_DAYS + 1)); echo "  day $d: ${#DAY_PROBLEMS[@]} problem(s)"
    else echo "  day $d: clean"; fi
done

echo "== known file"
while IFS= read -r p; do
    [[ -n "${KNOWN_HIT[$p]:-}" ]] && echo "  used:   $p" || echo "  UNUSED: $p (stale? it matched nothing)"
done < <(known_patterns)
echo "== soak: $FAILED_DAYS failed run(s) out of $(( $(cut -d' ' -f1 <<<"$SCHED" | uniq | wc -l) + 1 )) — log: $LOG"
echo "   Now revert this box to its snapshot: it holds restore points and state dated in the future."
(( FAILED_DAYS == 0 ))
