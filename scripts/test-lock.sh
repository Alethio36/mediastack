#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# scripts/test-lock.sh — the maintenance lock guards every verb that changes the stack:
#   * every verb's registry line says how (lock, own or read: VERBS, mediastack.sh)
#   * the verbs found running without it (whole-code audit, 26 Nov 2026) take it
#   * an `own` verb's function takes it itself; a `lock` verb gets it from main()
#   * main() refuses a `lock` verb while another run holds the lock, lets a
#     `read` verb run, and a child of the holder runs inside the hold
#   * the menu runs each verb through the dispatcher, never its function in-process
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-lock.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"; [[ -z "${holder:-}" ]] || kill "$holder" 2>/dev/null || true' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

lock_of() { local e; e=$(verb_entry "$1") || fail_ "$1 is not a verb"; echo "${e##*~}"; }

# ---- every verb says how ----
for e in "${VERBS[@]}"; do
    [[ "${e##*~}" =~ ^(lock|own|read)$ ]] || fail_ "'${e%%~*}' has no lock column (lock, own or read): $e"
    [[ "$(tr -cd '~' <<<"$e" | wc -c)" == 5 ]] || fail_ "'${e%%~*}' has six fields, the lock last"
done; pass

# ---- what changes the stack takes it ----
for v in up down enable disable configure set-credentials rotate-secrets wire restore rollback upgrade brand notify \
         set-user-facing traefik-setup trash-sync vpn vpn-apply fix-perms new-service frontdoor-install uninstall leak-test \
         apply-timer unpin add-mount install; do
    [[ "$(lock_of "$v")" == lock ]] || fail_ "'$v' changes the stack: its registry line takes the lock (got $(lock_of "$v"))"
done; pass
# an `own` verb takes it in its own function (a timer's run waits or skips there)
for e in "${VERBS[@]}"; do
    [[ "${e##*~}" == own ]] || continue
    v=${e%%~*}; fn="cmd_${v//-/_}"
    body=$(declare -f "$fn") || fail_ "$fn is not defined"
    # it, or a function it calls (backup's take and scheduled paths), takes the lock
    for f in $(grep -oE '\b[a-z][a-z0-9_]+\b' <<<"$body" | sort -u); do
        [[ "$f" != "$fn" ]] && declare -F "$f" >/dev/null && body+=$(declare -f "$f")
    done
    grep -E 'maint_(try_)?lock' <<<"$body" >/dev/null || fail_ "$v is 'own' but $fn (nor what it calls) never takes the lock"
done; pass

# ---- main(): refused while held, read verbs run, a child of the holder runs inside ----
MAINT_LOCK=$T/lock; : > "$MAINT_LOCK"; MAINT_SHORT_WAIT=1
run_record_start() { :; }; sudo_keepalive() { :; }; stack_down_since() { :; }
cmd_down() { echo DOWN-RAN; }; cmd_status() { echo STATUS-RAN; }
( exec 9<"$MAINT_LOCK"; flock 9; while sleep 0.2; do :; done ) & holder=$!   # short sleeps: each lets the descriptor go when killed
for _ in $(seq 1 50); do flock -n "$MAINT_LOCK" true || break; sleep 0.1; done   # the holder has it
out=$( (main down) 2>&1 ) && fail_ "down ran while another run held the lock: $out"
[[ "$out" == *"refused"* && "$out" != *DOWN-RAN* ]] || fail_ "down is refused, and says so: $out"; pass
[[ "$( (main status) 2>&1)" == *STATUS-RAN* ]] || fail_ "a read verb runs while the lock is held"; pass
kill "$holder"; wait "$holder" 2>/dev/null || true; holder=""
for _ in $(seq 1 50); do flock -n "$MAINT_LOCK" true && break; sleep 0.1; done   # free again
out=$( (MAINT_LOCKED=0; main down; bash -c 'echo "child sees MAINT_LOCKED=$MAINT_LOCKED"') 2>&1 )
[[ "$out" == *DOWN-RAN*"child sees MAINT_LOCKED=1"* ]] || fail_ "with the lock free, down runs, and a child it starts runs inside the hold: $out"; pass
( VERBS+=("ghost~ghost~none~Other~a verb with no lock column"); cmd_ghost() { :; }
  out=$( (main ghost) 2>&1 ) && exit 1; [[ "$out" == *"has no lock column"* ]] ) 2>/dev/null \
    || fail_ "a registry line with no lock column is refused at dispatch"; pass

# ---- the menu goes through the dispatcher ----
! declare -f cmd_menu | grep -E '"cmd_' >/dev/null || fail_ "the menu calls a verb's function in-process — it would skip the lock"; pass

echo "OK lock: $checks checks"
