#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
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
# Every point records its kind, a note and each service's version (meta);
# `backup list [svc]` shows them newest first, marking the running image
# (current) and rollback's target. rollback goes to the newest point holding
# a different image (a second one undoes the first), --from to any point; it
# shows its plan and asks, and outside a terminal needs --yes.
# The backup timer (backup --auto) skips after a full restore point under 6h
# old (never for a scoped one), waits for a running update or backup (one
# lock; one you start refuses), and waits while someone streams. configure
# asks both schedules in one section; existing installs get a daily backup an
# hour after their update time.
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

# ---- meta: what made each point, and what it ran ----
c_inspect_all() { :; }; svc_cname() { echo "c-$1"; }
svc_digest() { [[ "$1" == nodigest ]] || echo "repo/$1@sha256:${1}d"; }
c_version() { [[ "$1" == c-sonarr ]] && echo 4.0.15; }
mkdir -p "$T/pr"; point_record "$T/pr" manual $'before\nthe move' sonarr bazarr nodigest
[[ "$(cat "$T/pr/images.lock")" == $'sonarr repo/sonarr@sha256:sonarrd\nbazarr repo/bazarr@sha256:bazarrd' ]] \
    || fail_ "images.lock keeps its format (restore reads it): $(cat "$T/pr/images.lock")"; pass
[[ "$(cat "$T/pr/meta")" == $'kind=manual\nnote=before the move\nsonarr 4.0.15 repo/sonarr@sha256:sonarrd\nbazarr - repo/bazarr@sha256:bazarrd' ]] \
    || fail_ "meta: kind, a one-line note, svc version digest ('-' without a version label): $(cat "$T/pr/meta")"; pass
# ---- which image a container runs: store-aware (found live 8 Oct 2026: under ----
# ---- the containerd store a republished index left the db with no digest)  ----
for c in 'postgres:16|postgres' 'ghcr.io/goauthentik/server:2026.8|ghcr.io/goauthentik/server' \
         'registry:5000/app:1|registry:5000/app' 'registry:5000/app|registry:5000/app' 'postgres@sha256:ab|postgres'; do
    [[ "$(image_repo "${c%%|*}")" == "${c#*|}" ]] || fail_ "image_repo ${c%%|*}: $(image_repo "${c%%|*}")"; pass
done
( unset -f svc_digest
  # shellcheck source=/dev/null  # the real svc_digest, past the stub above
  source <(awk '/^svc_digest\(\)/,/^}/' lib/backup.sh)
  svc_image() { echo postgres:16; }
  c_get() { case "$2" in *com.docker.compose.image*) echo "$LABEL" ;; *) echo sha256:index ;; esac; }
  IMAGE_STORE=containerd; LABEL=sha256:platform
  [[ "$(svc_digest db)" == postgres@sha256:platform ]] || fail_ "containerd store: compose's platform digest, pullable: $(svc_digest db)"
  LABEL=""; [[ -z "$(svc_digest db)" ]] || fail_ "containerd store, no label: unknown, not invented"
) || exit 1; pass; pass
c_state() { [[ "$1" == c-gone ]] && echo exited || echo running; }
svc_digest() { [[ "$1" == nodigest || "$1" == gone ]] || echo "repo/$1@sha256:${1}d"; }
warn() { echo "WARN $*"; }
rm -f "$T/log"; mkdir -p "$T/pr2"
out=$(point_record "$T/pr2" manual "" sonarr nodigest gone 2>&1)
[[ "$(cat "$T/pr2/images.lock")" == "sonarr repo/sonarr@sha256:sonarrd" ]] || fail_ "the lock holds what is known: $(cat "$T/pr2/images.lock")"; pass
[[ "$out" == *"No image digest for nodigest"* && "$out" != *gone* ]] || fail_ "a running container without a digest is named, a stopped one is not: $out"; pass
[[ "$(cat "$T/log")" == *"NOTIFY Mediastack restore point incomplete"* ]] || fail_ "the gap reaches ops: $(cat "$T/log" 2>/dev/null)"; pass
unset -f c_state
backup_take() { echo "TAKE $1|$2"; }
[[ "$(cmd_backup --note "before jellyfin 12")" == "TAKE manual|before jellyfin 12" ]] || fail_ "backup --note: a manual point with the note"; pass
[[ "$(cmd_backup)" == "TAKE manual|" ]] || fail_ "backup: a manual point"; pass
( cmd_backup --note ) >/dev/null 2>&1 && fail_ "--note without text is refused"; pass
( cmd_backup --bogus ) >/dev/null 2>&1 && fail_ "an unknown argument is refused"; pass
grep -q 'backup_take update ""' <(awk '/^cmd_update\(\)/,/^}/' lib/backup.sh) || fail_ "a full update's point is kind 'update'"; pass
grep -q 'backup_take manual "before the first wire"' lib/wire.sh || fail_ "the first wire's point is manual, with a note"; pass
grep -q 'point_record "$dest" update-scoped' <(awk '/^preupdate_backup\(\)/,/^}/' lib/backup.sh) || fail_ "a scoped point is kind 'update-scoped'"; pass

# ---- backup list ----
load_env() { :; }; svc_exists() { [[ "$1" == sonarr ]]; }
printf 'BACKUP_ROOT=%s/bl\n' "$T" > "$ENV_FILE"; B=$T/bl
pt() { # pt REL KIND NOTE VERSION DIGEST — a point holding sonarr (KIND "" = no meta)
    mkdir -p "$B/$1"; : > "$B/$1/sonarr.tar.gz"; echo "sonarr repo/sonarr@sha256:$5" > "$B/$1/images.lock"
    [[ -z "$2" ]] || printf 'kind=%s\nnote=%s\nsonarr %s repo/sonarr@sha256:%s\n' "$2" "$3" "$4" "$5" > "$B/$1/meta"
}
pt 20260929-040000 scheduled "" 4.0.15 sonarrd
pt 20260928-030000 update "" 4.0.14 old14
pt 20260927-120000 "" "" "" old13
pt pre-update/20260928-120000 "" "" "" old14
mkdir -p "$B/20260926-000000" "$B/20260930-010000.partial"; printf 'kind=manual\nnote=before the rebuild\n' > "$B/20260926-000000/meta"
cmd_backup_list > "$T/all"; all=$(cat "$T/all")   # not $(...): that drops set -e (found: it hid a crash)
[[ "$(awk 'NR>1 {print $1}' <<<"$all" | tr '\n' ' ')" == "20260929-040000 20260928-120000 20260928-030000 20260927-120000 20260926-000000 " ]] \
    || fail_ "every complete point, both pools, newest first, no .partial: $all"; pass
grep -q '20260926-000000  manual  *before the rebuild' <<<"$all" || fail_ "kind and note shown: $all"; pass
cmd_backup_list sonarr > "$T/one"; one=$(cat "$T/one")
grep -q 'WHEN  *KIND  *SONARR  *NOTE' <<<"$one" || fail_ "the service names the version column: $one"; pass
! grep -q 20260926-000000 <<<"$one" || fail_ "a point without the service is not listed for it"; pass
grep -q '20260929-040000  scheduled  *4.0.15  *current' <<<"$one" || fail_ "the point holding the running image is 'current': $one"; pass
grep -q '20260928-120000  update-scoped  *sha256:old14  *rollback' <<<"$one" || fail_ "rollback's target is marked: $one"; pass
[[ "$(grep -c 'rollback' <<<"$one")" == 1 ]] || fail_ "one rollback target: $one"; pass
grep -q '20260928-030000  update  *4.0.14 *$' <<<"$one" || fail_ "an older version, unmarked: $one"; pass
grep -q '20260928-120000  update-scoped  *sha256:old14' <<<"$one" || fail_ "a scoped point from before meta: update-scoped, its digest: $one"; pass
grep -q '20260927-120000  unknown  *sha256:old13' <<<"$one" || fail_ "a full point from before meta: unknown, its digest: $one"; pass
( cmd_backup_list radarr ) >/dev/null 2>&1 && fail_ "an unknown service is refused"; pass
printf 'BACKUP_ROOT=%s/none\n' "$T" > "$ENV_FILE"
[[ -z "$(cmd_backup_list 2>/dev/null)" ]] || fail_ "no points: a hint, no table"; pass

# ---- rollback: the image that ran before, shown and confirmed first ----
printf 'BACKUP_ROOT=%s/bl\n' "$T" > "$ENV_FILE"
[[ "$(rollback_target "$B" sonarr repo/sonarr@sha256:sonarrd)" == pre-update/20260928-120000 ]] \
    || fail_ "the newest point with a different image (either pool)"; pass
[[ "$(rollback_target "$B" sonarr repo/sonarr@sha256:old14)" == 20260929-040000 ]] \
    || fail_ "after a rollback, the image that ran before it (a second rollback undoes the first)"; pass
[[ "$(rollback_target "$B" sonarr repo/sonarr@sha256:elsewhere)" == 20260929-040000 ]] \
    || fail_ "an image no point holds (update --to): the newest point"; pass
mkdir -p "$T/single/20260929-040000"; : > "$T/single/20260929-040000/sonarr.tar.gz"; echo "sonarr repo/sonarr@sha256:x" > "$T/single/20260929-040000/images.lock"
! rollback_target "$T/single" sonarr repo/sonarr@sha256:x >/dev/null || fail_ "every point holds the running image: none"; pass
[[ "$(point_resolve "$B" 20260928-120000)" == pre-update/20260928-120000 ]] || fail_ "--from finds a scoped point by its timestamp"; pass
[[ "$(point_resolve "$B" pre-update/20260928-120000)" == pre-update/20260928-120000 ]] || fail_ "--from takes the pool-relative form"; pass
! point_resolve "$B" 20260930-010000.partial >/dev/null && ! point_resolve "$B" ../x >/dev/null || fail_ "--from never reaches a .partial or outside the pools"; pass
cmd_restore() { echo "RESTORE $*" >> "$T/rb"; }; confirm() { echo "ASKED" >> "$T/rb"; [[ "${ANSWER:-n}" == y ]]; }
svc_digest() { echo repo/sonarr@sha256:sonarrd; }; c_version() { echo 4.0.15; }; hr() { :; }
rb() { rm -f "$T/rb"; ( cmd_rollback "$@" ) > "$T/rbout" 2>&1; echo "rc=$? $(cat "$T/rb" 2>/dev/null | tr '\n' '|')"; }
[[ "$(rb sonarr < /dev/null)" == "rc=1 " ]] && grep -q "asks first — run it in a terminal, or add --yes" "$T/rbout" \
    || fail_ "outside a terminal without --yes: refused, nothing restored: $(cat "$T/rbout")"; pass
grep -q 'back to:     sha256:old14 (restore point 20260928-120000, update-scoped' "$T/rbout" && grep -q 'running now: 4.0.15' "$T/rbout" \
    && grep -q 'kept as sonarr.pre-restore' "$T/rbout" || fail_ "the plan: target and its point, what runs now, what is replaced and kept: $(cat "$T/rbout")"; pass
[[ "$(rb sonarr --yes)" == "rc=0 RESTORE --service sonarr --from pre-update/20260928-120000|" ]] || fail_ "--yes: restored from the target, no question"; pass
[[ "$(rb sonarr --from 20260927-120000 --yes)" == "rc=0 RESTORE --service sonarr --from 20260927-120000|" ]] || fail_ "--from: that point"; pass
[[ "$(rb sonarr --from 20250101-000000 --yes)" == "rc=1 " ]] && grep -q "No restore point '20250101-000000'" "$T/rbout" || fail_ "--from an unknown point: refused"; pass
[[ "$(rb sonarr --from 20260926-000000 --yes)" == "rc=1 " ]] && grep -q "does not hold sonarr" "$T/rbout" || fail_ "--from a point without the service: refused"; pass
printf 'BACKUP_ROOT=%s/single\n' "$T" > "$ENV_FILE"; svc_digest() { echo repo/sonarr@sha256:x; }
[[ "$(rb sonarr --yes)" == "rc=1 " ]] && grep -q "update sonarr --to <tag>" "$T/rbout" || fail_ "no earlier image: points at update --to, with its caveat: $(cat "$T/rbout")"; pass
[[ "$(rb a b c d)" == "rc=1 " ]] && grep -q "usage: rollback <svc> \[--from TS\] \[--yes\]" "$T/rbout" || fail_ "extra arguments: refused by rollback itself (the registry passes them now)"; pass
grep -q 'rollback {svc:entity=svc_rollback:Service to roll back} --yes~' lib/frontdoor.sh || fail_ "the panel's button passes --yes (it confirms in its own dialog)"; pass

# ---- schedules: the wizard's words and the default backup time ----
for c in "Tue 04:00=05:00" "*-*-* 23:30=00:30" "Tue,Fri 04:00:00=05:00" "=04:00" "*-*-01 03:00=04:00" "hourly=04:00"; do
    [[ "$(sched_time_after "${c%=*}")" == "${c#*=}" ]] || fail_ "an hour after '${c%=*}': $(sched_time_after "${c%=*}")"; pass
done
[[ "$(sched_words "*-*-* 05:00")|$(sched_words "Mon..Fri 03:00")|$(sched_words "")|$(sched_words "Tue 04:00")" == "daily 05:00|weekdays 03:00|never|Tue 04:00" ]] \
    || fail_ "schedules in the wizard's words"; pass
digest_short repo/x@sha256:baba630419915985442f315f08b0cf46d9f4c8a0cc4bd38e94a6d35751dd5ef5 | grep -qx 'sha256:baba63041991' || fail_ "a digest is shown as docker does (12 hex)"; pass

# ---- the scheduled backup: skip, lock, streams ----
printf 'BACKUP_ROOT=%s/sk\nUPDATE_DEFER_IF_ACTIVE=false\n' "$T" > "$ENV_FILE"; mkdir -p "$T/sk"
MAINT_LOCK=$T/maint.lock; MAINT_WAIT=1; load_env() { :; }; warn() { echo "WARN $*"; }; ok() { echo "OK $*"; }; info() { :; }
notify() { echo "NOTIFY $2"; }
backup_take() { echo "TAKE $1"; }
sched() { ( MAINT_LOCKED=0; backup_scheduled ) 2>&1; }
ago() { date -d "-$1 hours" +%Y%m%d-%H%M%S; }
mkdir -p "$T/sk/$(ago 2)"; [[ "$(sched)" == *"is 2h old and covers every service — this scheduled backup is skipped"* ]] || fail_ "a full point 2h old: skipped"; pass
rm -rf "$T/sk"/*; mkdir -p "$T/sk/$(ago 0)"; [[ "$(sched)" == *"is under an hour old and covers"* ]] || fail_ "minutes old: 'under an hour', not '0h'"; pass
rm -rf "$T/sk"/*; mkdir -p "$T/sk/$(ago 7)"; [[ "$(sched)" == *"TAKE scheduled"* ]] || fail_ "a full point 7h old: runs, kind scheduled"; pass
rm -rf "$T/sk"/*; mkdir -p "$T/sk/$(ago 30)" "$T/sk/pre-update/$(ago 1)"
[[ "$(sched)" == *"TAKE scheduled"* ]] || fail_ "a fresh scoped (update <svc>) point never counts: the backup runs"; pass
rm -rf "$T/sk"/*; [[ "$(sched)" == *"TAKE scheduled"* ]] || fail_ "no point at all: runs"; pass
( exec 8<"$MAINT_LOCK"; flock 8; sleep 4 ) & holder=$!; sleep 0.5
out=$(sched) || true
[[ "$out" == *"NOTIFY Mediastack scheduled backup skipped"* && "$out" != *TAKE* ]] || fail_ "the lock held past the wait: skipped, alerted: $out"; pass
out=$( ( MAINT_LOCKED=0; maint_lock backup 0 ) 2>&1 ) && fail_ "a run you start refuses while the lock is held"
[[ "$out" == *"Another update or backup is running — backup refused"* ]] || fail_ "says why: $out"; pass
wait "$holder"
MAINT_WAIT=5; ( exec 8<"$MAINT_LOCK"; flock 8; sleep 1 ) & holder=$!; sleep 0.3
[[ "$(sched)" == *"TAKE scheduled"* ]] || fail_ "a timer's run waits for the lock, then runs"; pass
wait "$holder"; MAINT_WAIT=1
printf 'BACKUP_ROOT=%s/sk\nUPDATE_DEFER_IF_ACTIVE=true\nUPDATE_DEFER_MAX_MIN=0\nUPDATE_DEFER_ACTION=skip\n' "$T" > "$ENV_FILE"
jellyfin_sessions_active() { return 0; }
out=$(sched); [[ "$out" == *"SKIPPING this backup run"* && "$out" != *TAKE* ]] || fail_ "streaming past the longest wait, action skip: skipped: $out"; pass
sed -i 's/UPDATE_DEFER_ACTION=skip/UPDATE_DEFER_ACTION=proceed/' "$ENV_FILE"
[[ "$(sched)" == *"proceeding anyway"*"TAKE scheduled"* ]] || fail_ "action proceed: runs"; pass
( cmd_backup --auto --note x ) >/dev/null 2>&1 && fail_ "--auto takes no note"; pass
grep -q 'maint_lock "the scheduled update" "$MAINT_WAIT"' lib/backup.sh && grep -q 'maint_lock update 0' lib/backup.sh \
    && grep -q 'defer_while_streaming update' <(awk '/^cmd_update\(\)/,/^}/' lib/backup.sh) || fail_ "update holds the same lock and deferral"; pass
grep -q 'maint_lock backup 0' <(awk '/^backup_take\(\)/,/^}/' lib/backup.sh) || fail_ "every restore point takes the lock (update's is re-entry)"; pass
# wire talks to the apps an update or backup stops and recreates: it refuses
# while one runs (found live: a wire --verify during the 04:00 update)
grep -q 'maint_lock wire 0' <(awk '/^cmd_wire\(\)/,/^}/' lib/wire.sh) || fail_ "wire takes the maintenance lock"; pass
# after every stack start Prowlarr re-tests its indexers once FlareSolverr is
# healthy: a cold FlareSolverr failed its first requests and the arrs reported
# "all indexers unavailable" nightly (found live)
grep -q 'healthcheck:' services/flaresolverr/compose.yml || fail_ "flaresolverr needs a healthcheck (the start waits on it)"; pass
grep -q '^    prowlarr_indexers_retest' <(awk '/^cmd_up\(\)/,/^}/' mediastack.sh) \
    && grep -q '^    prowlarr_indexers_retest' <(awk '/^backup_take\(\)/,/^}/' lib/backup.sh) \
    && grep -q '^    prowlarr_indexers_retest' <(awk '/^cmd_update\(\)/,/^}/' lib/backup.sh) \
    || fail_ "up, a restore point and an update each end with prowlarr_indexers_retest"; pass
( info() { echo ":: $*"; }; ok() { echo "OK $*"; }; warn() { echo "WARN $*"; }
  svc_enabled() { return 0; }; c_state() { echo running; }; svc_cname() { echo "$1"; }
  arr_key() { echo k; }; arr_url() { echo http://p; }; arr_apiver() { echo v1; }
  http_ready() { return 0; }; wait_verdict() { return 0; }
  api() { echo "$1 $2 timeout=${API_TIMEOUT:-20}" >> "$T/rt.calls"; case "$2" in *indexer/testall) printf '%s' "$RT_OUT" ;; *) echo '[]' ;; esac; }
  : > "$T/rt.calls"; RT_OUT='[{"id":2,"isValid":false},{"id":5,"isValid":true}]'
  out=$(prowlarr_indexers_retest 2>&1)
  [[ "$out" == *"still failing after the start (ids: 2)"* ]] || fail_ "a failing indexer is named: $out"
  grep -q 'indexerproxy/testall' "$T/rt.calls" && grep -q '/indexer/testall' "$T/rt.calls" || fail_ "proxies, then indexers, are re-tested"
  # a test waits on Cloudflare challenges: api's 20s default timed it out (live)
  ! grep -qE 'testall timeout=20$' "$T/rt.calls" && grep -qE 'indexer/testall timeout=[0-9]{3}$' "$T/rt.calls" || fail_ "the re-tests get a long timeout: $(cat "$T/rt.calls")"
  RT_OUT='[{"id":2,"isValid":true}]'; [[ "$(prowlarr_indexers_retest 2>&1)" == *"every indexer answers"* ]] || fail_ "all good is said"
  RT_OUT='[]'; [[ "$(prowlarr_indexers_retest 2>&1)" == *"no indexers yet"* ]] || fail_ "none is not 'all good'"
  wait_verdict() { declare -gA VERDICT_WHY=([flaresolverr]="is unhealthy"); return 1; }; : > "$T/rt.calls"
  [[ "$(prowlarr_indexers_retest 2>&1)" == *"not re-tested — flaresolverr is unhealthy"* && ! -s "$T/rt.calls" ]] || fail_ "an unhealthy flaresolverr: no test, and said why"
) || exit 1; pass
grep -q 'apply_timer mediastack-backup .* "backup --auto" BACKUP_SCHEDULE' lib/backup.sh || fail_ "apply-timer installs the backup timer"; pass

# ---- schedules run in .env's TZ, not the host's (found live 8 Oct 2026) ----
( systemd-analyze() { [[ "$1" == calendar ]]; }; timer_write() { echo "WRITE $4"; }
  systemctl() { :; }; ok() { :; }
  printf 'UPDATE_SCHEDULE=*-*-* 04:00\nTZ=Europe/Berlin\n' > "$ENV_FILE"
  [[ "$(apply_timer mediastack-update d "update --auto" UPDATE_SCHEDULE l)" == "WRITE *-*-* 04:00 Europe/Berlin" ]] \
      || fail_ "the schedule carries TZ: $(apply_timer mediastack-update d "update --auto" UPDATE_SCHEDULE l)"
  printf 'UPDATE_SCHEDULE=Tue 04:00\n' > "$ENV_FILE"
  [[ "$(apply_timer mediastack-update d "update --auto" UPDATE_SCHEDULE l)" == "WRITE Tue 04:00" ]] || fail_ "no TZ: the host's zone, as written"
  printf 'UPDATE_SCHEDULE=*-*-* 04:00 Europe/Berlin\nTZ=Europe/Berlin\n' > "$ENV_FILE"
  out=$( ( apply_timer mediastack-update d "update --auto" UPDATE_SCHEDULE l ) 2>&1 ) && fail_ "a zone in the schedule must refuse"
  [[ "$out" == *"names a time zone"*"remove it from UPDATE_SCHEDULE"* ]] || fail_ "the refusal says why and what to do: $out"
) || exit 1; pass; pass; pass

# ---- migration 29 -> 30 ----
printf 'UPDATE_SCHEDULE=Tue 04:00\n' > "$ENV_FILE"; migrate_env_29_to_30 >/dev/null
[[ "$(env_get BACKUP_SCHEDULE)" == "*-*-* 05:00" ]] || fail_ "an existing install: daily, an hour after its updates"; pass
printf 'UPDATE_SCHEDULE=\n' > "$ENV_FILE"; migrate_env_29_to_30 >/dev/null
[[ "$(env_get BACKUP_SCHEDULE)" == "*-*-* 04:00" ]] || fail_ "updates off: daily 04:00"; pass
printf 'UPDATE_SCHEDULE=Tue 04:00\nBACKUP_SCHEDULE=\n' > "$ENV_FILE"; migrate_env_29_to_30 >/dev/null
[[ "$(env_get BACKUP_SCHEDULE)" == "" ]] || fail_ "a BACKUP_SCHEDULE already there is never changed"; pass

# ---- configure: both schedules, one section ----
hr() { echo "== $*"; }; explain() { :; }; fail() { echo "FAIL $*"; }; info() { echo ":: $*"; }
wiz() { printf '%b' "$1" | _configure_schedule 2>&1; echo "U=$(env_get UPDATE_SCHEDULE)|B=$(env_get BACKUP_SCHEDULE)"; }
: > "$ENV_FILE"
out=$(wiz '\n\n\n\n\n\n'); [[ "$out" == *"U=Tue 04:00|B=*-*-* 05:00" ]] || fail_ "all defaults: weekly Tue 04:00, backups daily 05:00: $out"; pass
[[ "$out" == *"2) weekly      one day a week (recommended)"* && "$out" == *"1) daily       every day at a time you pick (recommended)"* ]] || fail_ "each menu marks its suggestion: $out"; pass
[[ "$out" == *"the update's restore point counts; the backup skips"* ]] || fail_ "the summary says how they meet: $out"; pass
: > "$ENV_FILE"; out=$(wiz '1\n02:30\n\n\n\n'); [[ "$out" == *"U=*-*-* 02:30|B=*-*-* 03:30" ]] || fail_ "daily updates at 02:30: the backup suggests 03:30: $out"; pass
: > "$ENV_FILE"; out=$(wiz '1\n04:00\n1\n03:00\n\n'); [[ "$out" == *"backup runs first, so that day gets two restore points"* && "$out" == *"U=*-*-* 04:00|B=*-*-* 03:00" ]] \
    || fail_ "a backup before the update: kept, with a note: $out"; pass
: > "$ENV_FILE"; out=$(wiz '6\n6\n\n'); [[ "$out" == *"No automatic restore points at all"* && "$out" == *"U=|B=" ]] || fail_ "both never: a warning: $out"; pass
out=$(wiz '6\n6\nn\n2\nWed\n03:00\n\n\n\n'); [[ "$out" == *"U=Wed 03:00|B=*-*-* 04:00" ]] || fail_ "'n' asks both again: $out"; pass
out=$(wiz '\n\n\n'); [[ "$out" == *"0) keep current: Wed 03:00"* && "$out" == *"U=Wed 03:00|B=*-*-* 04:00" ]] || fail_ "a re-run keeps both on Enter: $out"; pass
out=$(wiz '5\nevery day\n5\n*-*-01 03:00\n\n\n\n'); [[ "$out" == *"'every day' is not a valid schedule"* && "$out" == *"U=*-*-01 03:00|"* ]] || fail_ "a custom expression is validated: $out"; pass

echo "OK restore-point: $checks checks"
