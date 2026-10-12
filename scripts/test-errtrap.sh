#!/usr/bin/env bash
# test-errtrap.sh — the entrypoint's ERR trap (on_err, lib/common.sh):
#   * an unguarded failure prints ONE line naming exit code, file:line, the
#     function chain and the command as written (no expanded secret); the
#     run's exit code is the failing command's
#   * an unguarded $( ) that fails is named once, at the caller's line
#   * handled failures are silent: under if, ||, &&, and inside a $( ) whose
#     caller handles it
#   * die prints only its own message; a die inside an unguarded $( ) adds
#     the one line naming where it was called from
#   * a ( ) subshell's failure is named once (its own line, not its exit too);
#     a false (( )) is named like any other failure
#   * stopped_run's EXIT guard (lib/backup.sh) still restarts what it stopped,
#     called guarded (the way backup calls it) and unguarded
# Each case runs in its own bash that sources the real entrypoint (minus its
# last line, main "$@"), so set -E and the trap are the ones shipped.
#
#   scripts/test-errtrap.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-errtrap.XXXXXX)
T=$(mktemp -d); export T   # fx.sh's stubs record into it
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"

cat > "$T/fx.sh" <<'EOF'
secret=hunter2
f_fail()   { test "$secret" = nope; echo "f_fail went on"; }   # FX:fail
f_outer()  { f_fail; }
f_ret()    { return 3; }
f_subst()  { local x; x=$(grep -q nomatch /dev/null); echo "f_subst went on"; }   # FX:subst
f_die()    { die "boom"; }
f_diesub() { local x; x=$(f_die); echo "f_diesub went on"; }   # FX:diesub
f_sub()    { ( true; test "$secret" = nope ); echo "f_sub went on"; }   # FX:sub
f_arith()  { local n=0; (( n > 0 )); echo "f_arith went on"; }   # FX:arith
# stopped_run's world, stubbed: compose and sudo record, the marker lives in $T
DC()         { echo "DC $*" >> "$T/dc"; }
sudo()       { "$@"; }
repo_owned() { :; }
notify()     { :; }
EOF
line_of() { grep -n "FX:$1" "$T/fx.sh" | cut -d: -f1; }

# run 'CODE' -> rc in $rc, stdout in $T/out, stderr in $T/err
run() {
    rc=0
    bash -c "source '$lib'; LOCAL_DIR='$T/local'; STOP_MARKER='$T/local/marker'; source '$T/fx.sh'; $1" \
        > "$T/out" 2> "$T/err" || rc=$?
}
checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; echo "--- stderr:" >&2; cat "$T/err" >&2; exit 1; }
trap_lines() { grep -c 'unhandled failure' "$T/err" || true; }

# ---- the entrypoint installs it ----
grep -qx 'set -Eeuo pipefail.*' mediastack.sh || fail_ "mediastack.sh does not set -E"; pass
grep -qx 'trap on_err ERR.*' mediastack.sh || fail_ "mediastack.sh does not install on_err"; pass

# ---- unguarded failure: one line, file:line, chain, command as written, exit code kept ----
run 'f_outer; echo after'
(( rc == 1 )) || fail_ "unguarded: exit $rc, expected 1"; pass
[[ $(wc -l < "$T/err") -eq 1 ]] || fail_ "unguarded: expected exactly one line"; pass
grep -qF "unhandled failure (exit 1) at $T/fx.sh:$(line_of fail) in f_fail < f_outer: test \"\$secret\" = nope" "$T/err" \
    || fail_ "unguarded: line does not name exit, file:line, chain and command"; pass
! grep -q hunter2 "$T/err" || fail_ "unguarded: the expanded secret was printed"; pass
! grep -qE 'went on|after' "$T/out" || fail_ "unguarded: the run went on"; pass

run 'f_ret'
(( rc == 3 && $(trap_lines) == 1 )) || fail_ "return 3: exit $rc with $(trap_lines) line(s), expected 3 and 1"; pass

# ---- unguarded $( ): named once, at the caller ----
run 'f_subst'
(( rc == 1 && $(trap_lines) == 1 )) || fail_ "unguarded \$( ): exit $rc with $(trap_lines) line(s)"; pass
grep -qF "fx.sh:$(line_of subst) in f_subst: x=\$(grep -q nomatch /dev/null)" "$T/err" \
    || fail_ "unguarded \$( ): not named at the caller's line"; pass

# ---- handled failures are silent ----
for code in 'if f_fail; then :; fi' 'f_fail || :' 'f_fail && :' 'x=$(f_outer) || :' 'x=$(false; echo y)'; do
    run "$code; echo done"
    (( rc == 0 )) && [[ ! -s "$T/err" ]] && grep -qx "done" "$T/out" || fail_ "handled ($code) was not silent"; pass
done

# ---- die: its own message only ----
run 'f_die'
(( rc == 1 )) && [[ "$(cat "$T/err")" == "ERROR boom" ]] || fail_ "die printed more than its own message"; pass
run 'f_diesub'
(( rc == 1 )) && grep -qx "ERROR boom" "$T/err" && (( $(wc -l < "$T/err") == 2 )) \
    && grep -qF "fx.sh:$(line_of diesub) in f_diesub: x=\$(f_die)" "$T/err" \
    || fail_ "die inside an unguarded \$( ): expected its message plus the caller's line"; pass

# ---- ( ) subshell: named once ----
run 'f_sub'
(( rc == 1 && $(trap_lines) == 1 )) || fail_ "( ) subshell: $(trap_lines) line(s), expected 1"; pass
grep -qF "fx.sh:$(line_of sub) in f_sub: test \"\$secret\" = nope" "$T/err" || fail_ "( ) subshell: not its own line"; pass

# ---- a false (( )) is not a subshell: named ----
run 'f_arith'
(( rc == 1 && $(trap_lines) == 1 )) && grep -qF "fx.sh:$(line_of arith) in f_arith: (( n > 0 ))" "$T/err" \
    || fail_ "a false (( )) under set -e was not named"; pass

# ---- stopped_run's EXIT guard still restarts ----
run 'rc2=0; stopped_run backup "" false || rc2=$?; echo "rc=$rc2"'
grep -qx 'rc=1' "$T/out" && grep -qx 'DC up -d' "$T/dc" && [[ ! -e "$T/local/marker" ]] \
    || fail_ "guarded stopped_run: services not restarted or rc lost"; pass
(( $(trap_lines) == 0 )) || fail_ "guarded stopped_run: the trap spoke"; pass
rm -f "$T/dc"
run 'stopped_run backup "" false; echo after'
(( rc == 1 )) && grep -qx 'DC up -d' "$T/dc" && ! grep -q after "$T/out" \
    || fail_ "unguarded stopped_run: services not restarted, or the run went on"; pass
(( $(trap_lines) == 1 )) || fail_ "unguarded stopped_run: $(trap_lines) line(s), expected 1"; pass

echo "OK errtrap: $checks checks"
