#!/usr/bin/env bash
# test-sudo-keepalive.sh — sudo_keepalive (lib/common.sh):
#   * in a terminal, as a normal user: sudo's password is renewed with
#     `sudo -n -v` (never a form that could ask) until the run ends
#   * the renewals stop when the run ends, however it ends (exit, die)
#   * no terminal, or root: nothing is started
# Each case runs in its own bash that sources the real entrypoint (minus its
# last line, main "$@"); sudo and id are stubs; `script` gives a terminal.
#
#   scripts/test-sudo-keepalive.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
command -v script >/dev/null || { echo "FAIL: needs script(1) (util-linux)" >&2; exit 1; }

lib=$(mktemp .test-sudo-keepalive.XXXXXX)
T=$(mktemp -d); export T
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

# run_case NAME UID END TTY — a run that lasts 3s with renewals every 1s, then ends by END (exit|die)
run_case() {
    cat > "$T/$1.sh" <<CASE
source "$PWD/$lib"
sudo() { echo "\$*" >> "$T/$1.calls"; }
id()   { echo $2; }
SUDO_KEEPALIVE_EVERY=1
sudo_keepalive
sleep 3
case $3 in exit) exit 0 ;; die) die "ended by die" ;; esac
CASE
    : > "$T/$1.calls"
    if [[ $4 == tty ]]; then script -qec "bash $T/$1.sh" /dev/null >/dev/null 2>&1 || true
    else bash "$T/$1.sh" </dev/null >/dev/null 2>&1 || true; fi
}
count() { wc -l < "$T/$1.calls"; }

run_case user 1000 exit tty
n=$(count user); (( n >= 2 )) || fail_ "a user's run in a terminal renews sudo while it lives (got $n renewals in 3s)"; pass
grep -qvx -- '-n -v' "$T/user.calls" && fail_ "every renewal is 'sudo -n -v' (one that never asks): $(sort -u "$T/user.calls" | tr '\n' ' ')"; pass
sleep 2; (( $(count user) == n )) || fail_ "the renewals stop when the run exits"; pass

run_case died 1000 die tty
n=$(count died); sleep 2; (( n >= 2 && $(count died) == n )) || fail_ "a run ended by die stops its renewals too"; pass

run_case notty 1000 exit notty
(( $(count notty) == 0 )) || fail_ "no terminal: nothing is renewed"; pass

run_case root 0 exit tty
(( $(count root) == 0 )) || fail_ "root: nothing is renewed"; pass

# a lock the run already holds when the renewals start (upgrade hands the
# maintenance lock across its exec) is free the moment the run ends — the
# loop's leftover sleep must not keep it (found live, Nov 2026)
cat > "$T/lock.sh" <<CASE
source "$PWD/$lib"
sudo() { :; }
id()   { echo 1000; }
SUDO_KEEPALIVE_EVERY=30
exec 8<"$T/lock"; flock -n 8 || exit 3
sudo_keepalive
sleep 1   # the run's work: the loop is in its sleep by now
exit 0
CASE
: > "$T/lock"
# checked inside the same terminal session: when script(1) ends, the hangup
# would kill a leftover sleep and hide the bug (an SSH session goes on)
script -qec "bash $T/lock.sh; sleep 0.5; (exec 9<$T/lock; flock -n 9) && echo free > $T/lock.result || echo held > $T/lock.result" /dev/null >/dev/null 2>&1 || true
[[ "$(cat "$T/lock.result" 2>/dev/null)" == free ]] || fail_ "the lock is free once the run has ended (a renewal's sleep still holds it: $(cat "$T/lock.result" 2>/dev/null))"; pass

echo "test-sudo-keepalive: $checks checks passed"
