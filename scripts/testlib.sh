#!/usr/bin/env bash
# testlib.sh — helpers the tests share; sourced after the entrypoint, with $T
# set (the test's scratch directory).
#
# as_run CMD [ARG...] — CMD run the way a run runs it: its own subshell, with
# set -eE and the entrypoint's ERR trap, so a failure a run would stop on
# stops it here too. Its status in RC, its output (stdout and stderr) in
# OUT; it returns 0 itself, in a test with set -e on or off
# (it puts the caller's -e back as it was). Call it plainly and read RC after
# it: in a condition (`as_run … || fail_`, `if as_run`, `! as_run`) bash
# ignores set -e inside it, subshells included, and the check is blind again
# (scripts/check-test-runners.sh fails such a call). For stubs only this call
# should see, pass a string: as_run eval 'curl() { …; }; wire_x'.
as_run() {
    local e=0 f; [[ $- == *e* ]] && e=1
    f=$(mktemp)
    set +e   # the caller's -e off: a failure here is RC, not the end of the test
    ( set -eE; trap on_err ERR; "$@" ) > "$f" 2>&1
    # shellcheck disable=SC2034  # RC and OUT: read by the test that called it
    RC=$?
    if (( e )); then set -e; fi
    # shellcheck disable=SC2034
    OUT=$(cat "$f"); rm -f "$f"
    return 0
}
