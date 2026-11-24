#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-script-updates.sh — knowing mediastack itself has an upgrade
# (SCRIPT_UPDATES=notify; lib/lifecycle.sh, doctor's "mediastack itself"):
#   * script_behind against a real clone: current, behind (newest five),
#     ahead, off (nothing fetched), no branch followed, a fetch that fails
#   * a root run's git is the repo owner's (setpriv), and never prompts
#   * the update run tells ops once per new tip, and once of a check that
#     cannot run; current clears both
#   * doctor's section; the update run asks before anything can refuse it
# Sources the real entrypoint (minus its last line, main "$@"); the remote is
# a bare repository in a scratch folder.
#
#   scripts/test-script-updates.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO=$PWD

lib=$(mktemp .test-script-updates.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

g() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=stable -c advice.detachedHead=false -c push.negotiate=false "$@"; }
commit() { # commit DIR SUBJECT
    echo "$2" >> "$1/f"; g -C "$1" add f; g -C "$1" commit -qm "$2"
}
g init -q --bare "$T/origin.git"
g clone -q "$T/origin.git" "$T/up" 2>/dev/null; commit "$T/up" "first"; g -C "$T/up" push -q origin HEAD:stable
g clone -q -b stable "$T/origin.git" "$T/install"
SCRIPT_DIR=$T/install
ENV_FILE=$T/.env; printf 'SCRIPT_UPDATES=notify\n' > "$ENV_FILE"
STATE_DIR=$T/state; mkdir -p "$STATE_DIR"
info() { echo ":: $*"; }; ok() { echo "OK $*"; }; warn() { echo "WARN $*"; }
notify() { echo "$*" >> "$T/notes"; }
upstream_push() { local i; for i in "$@"; do commit "$T/up" "$i"; done; g -C "$T/up" push -q origin HEAD:stable; }

# ---- script_behind ----
script_behind
[[ "$SB_STATE" == current && "$SB_UP" == origin/stable && "$SB_N" == 0 && "$SB_AHEAD" == 0 ]] || fail_ "up to date: current, following origin/stable ($SB_STATE $SB_UP $SB_N $SB_WHY)"; pass
upstream_push c2 c3 c4 c5 c6 c7 c8
script_behind
[[ "$SB_STATE" == behind && "$SB_N" == 7 && "$SB_TIP" == "$(g -C "$T/up" rev-parse --short HEAD)" ]] || fail_ "seven new upstream: behind 7, its tip ($SB_STATE $SB_N $SB_TIP)"; pass
[[ "$(wc -l <<<"$SB_LOG")" == 5 && "$(sed -n 1p <<<"$SB_LOG")" == *" c8" && "$(sed -n 5p <<<"$SB_LOG")" == *" c4" ]] || fail_ "the newest five, newest first: $SB_LOG"; pass
[[ "$(cat "$T/install/f")" == first && "$(g -C "$T/install" rev-list --count HEAD)" == 1 ]] || fail_ "a fetch, never a pull: the checkout unchanged"; pass
commit "$T/install" "local"
script_behind; [[ "$SB_AHEAD" == 1 && "$SB_STATE" == behind ]] || fail_ "a local commit: ahead 1 ($SB_AHEAD)"; pass
g -C "$T/install" reset -q --hard HEAD~1
printf 'SCRIPT_UPDATES=off\n' > "$ENV_FILE"; g -C "$T/install" remote set-url origin "$T/nowhere.git"
script_behind; [[ "$SB_STATE" == off ]] || fail_ "off: not asked, nothing fetched ($SB_STATE $SB_WHY)"; pass
printf 'SCRIPT_UPDATES=notify\n' > "$ENV_FILE"
script_behind; [[ "$SB_STATE" == unknown && "$SB_WHY" == "git fetch origin stable failed: "*"cannot type a key's passphrase"* ]] || fail_ "a fetch that fails: unknown, saying why ($SB_WHY)"; pass
g -C "$T/install" remote set-url origin "$T/origin.git"
g -C "$T/install" checkout -q --detach
script_behind; [[ "$SB_STATE" == unknown && "$SB_WHY" == *"follows no branch"*"branch -u origin/stable"* ]] || fail_ "detached: unknown, the fix named ($SB_WHY)"; pass
g -C "$T/install" checkout -q stable

# ---- a root run's git is the owner's, and never prompts ----
o=$( id() { echo 0; }
     stat() { case "$1 $2" in "-c %u") echo 1234 ;; "-c %g") echo 2345 ;; *) command stat "$@" ;; esac; }
     getent() { echo "u:x:1234:2345::/home/u:/bin/sh"; }
     setpriv() { echo "$*" > "$T/sp"; while [[ $1 == --* ]]; do shift; done; "$@"; }
     script_git rev-parse --abbrev-ref HEAD; cat "$T/sp" )
[[ "$o" == $'stable\n--reuid=1234 --regid=2345 --clear-groups env HOME=/home/u GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND=ssh -o BatchMode=yes timeout '"$SCRIPT_FETCH_TIMEOUT"' git -C '"$T/install"' rev-parse --abbrev-ref HEAD' ]] \
    || fail_ "root: git as the repo's owner (its uid, gid and home), no prompt, bounded: $o"; pass
o=$( setpriv() { echo USED; }; script_git rev-parse --abbrev-ref HEAD )
[[ "$o" == stable ]] || fail_ "not root: git as itself: $o"; pass

# ---- the update run tells ops once per new tip ----
rm -f "$T/notes"
o=$(script_behind_tell_ops)
[[ "$(wc -l < "$T/notes")" -ge 1 ]] && grep -q '^ops An upgrade is available 7 new commit(s) on `origin/stable`:' "$T/notes" \
    && grep -q '…and 2 more' "$T/notes" && grep -q 'Upgrade on the host: `./mediastack.sh upgrade`' "$T/notes" && grep -q ' info$' "$T/notes" \
    || fail_ "behind, first time: ops told, five subjects and how many more, the verb: $(cat "$T/notes" 2>/dev/null)"; pass
[[ "$(state_get script-behind-told)" == "$(g -C "$T/up" rev-parse --short HEAD)" ]] || fail_ "the tip told is kept"; pass
rm -f "$T/notes"; o=$(script_behind_tell_ops)
[[ ! -f "$T/notes" ]] && grep -q 'ops was told of' <<<"$o" || fail_ "the same tip again: not told twice: $o"; pass
upstream_push c9
rm -f "$T/notes"; script_behind_tell_ops >/dev/null
grep -q '8 new commit(s)' "$T/notes" || fail_ "a new tip: told again"; pass
g -C "$T/install" pull -q --ff-only
rm -f "$T/notes"; o=$(script_behind_tell_ops)
[[ ! -f "$T/notes" && -z "$(state_get script-behind-told)" ]] && grep -q 'OK mediastack is current with origin/stable' <<<"$o" || fail_ "upgraded: current, the record cleared: $o"; pass
g -C "$T/install" remote set-url origin "$T/nowhere.git"
rm -f "$T/notes"; o=$(script_behind_tell_ops)
grep -q '^ops Cannot check for upgrades git fetch origin stable failed' "$T/notes" && grep -q ' warning$' "$T/notes" && grep -q '^WARN mediastack could not check its branch' <<<"$o" \
    || fail_ "a check that cannot run: warned, ops told: $o $(cat "$T/notes" 2>/dev/null)"; pass
rm -f "$T/notes"; script_behind_tell_ops >/dev/null
[[ ! -f "$T/notes" ]] || fail_ "the same failure next run: ops not told again"; pass
g -C "$T/install" remote set-url origin "$T/origin.git"; script_behind_tell_ops >/dev/null
[[ -z "$(state_get script-check-failed)" ]] || fail_ "the check works again: its failure forgotten (the next one is told)"; pass
printf 'SCRIPT_UPDATES=off\n' > "$ENV_FILE"; rm -f "$T/notes"; o=$(script_behind_tell_ops)
[[ ! -f "$T/notes" && -z "$o" ]] || fail_ "off: silent: $o"; pass
printf 'SCRIPT_UPDATES=notify\n' > "$ENV_FILE"

# ---- doctor's section ----
upstream_push c10 c11
o=$(_doctor_upstream)
grep -q 'WARN mediastack is 2 commit(s) behind origin/stable — upgrade: ./mediastack.sh upgrade' <<<"$o" && grep -q ' c11$' <<<"$o" \
    || fail_ "doctor, behind: a warning (not a failure), the subjects: $o"; pass
[[ "$D_FAILS" == 0 ]] || fail_ "doctor, behind: never a doctor failure (the stack runs)"; pass
g -C "$T/install" pull -q --ff-only
grep -q "OK mediastack is current with origin/stable ($(g -C "$T/up" rev-parse --short HEAD))" <<<"$(_doctor_upstream)" || fail_ "doctor, current"; pass
printf 'SCRIPT_UPDATES=off\n' > "$ENV_FILE"
grep -q 'not checked against its branch (SCRIPT_UPDATES=off)' <<<"$(_doctor_upstream)" || fail_ "doctor, off"; pass
printf 'SCRIPT_UPDATES=notify\n' > "$ENV_FILE"; commit "$T/install" "mine"
grep -q 'WARN this checkout has 1 commit(s) that origin/stable does not' <<<"$(_doctor_upstream)" || fail_ "doctor, ahead: warned (upgrade cannot fast-forward)"; pass
[[ " ${DOCTOR_SECTIONS[*]} " == *" upstream "* ]] || fail_ "doctor runs the section"; pass

# ---- the update run asks first, auto runs only ----
cd "$REPO"
u=$(awk '/^cmd_update\(\)/,/^}/' lib/backup.sh)
[[ "$(grep -n 'if (( auto && ! dry )); then script_behind_tell_ops; fi' <<<"$u" | cut -d: -f1)" -lt "$(grep -n 'leak_gate_refuse "update"' <<<"$u" | cut -d: -f1)" ]] \
    && [[ "$(grep -n 'script_behind_tell_ops' <<<"$u" | cut -d: -f1)" -lt "$(grep -n 'defer_while_streaming' <<<"$u" | cut -d: -f1)" ]] \
    || fail_ "update: ops hears of an upgrade before a leak gate or a deferral can stop the run"; pass
! grep -qE 'git (pull|merge|reset|checkout)' <(awk '/^script_git\(\)/,/^script_behind_tell_ops\(\)/' lib/lifecycle.sh) \
    || fail_ "the check never changes the checkout"; pass

echo "OK script-updates: $checks checks"
