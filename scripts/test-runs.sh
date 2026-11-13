#!/usr/bin/env bash
# test-runs.sh — every run recorded in local/runs/ (lib/runs.sh, docs/design-runs.md):
#   * a record: header (verb, commit, who started it, when), every line the run
#     printed, timestamped in the stack's time zone, colours stripped; the
#     footer with the run's own exit code
#   * a record never changes a run: stdout byte for byte when it goes elsewhere
#     than stderr, stdout and stderr in their order when they share a place,
#     the exit code as before; a record that cannot be made is said once
#   * exec keeps one record (upgrade's hand-over); a child process that
#     inherits it writes into it and ends nothing
#   * Ctrl-C, a stop and a hang-up end the record with 130, 143, 129; a killed
#     run has no footer
#   * the verbs whose output is a secret or other people's activity record
#     their header and footer only; a secret .env holds never stays in a record
#   * retention: the newest 20 per verb and options; a failed or unfinished one
#     beyond them stays 30 days
#   * who started it: terminal, panel, systemd <unit>, other
#   * one EXIT trap: hooks only (a second `trap … EXIT` would drop the footer);
#     the sudo keepalive does not hold the record open
# Each case runs main() in its own bash that sources the real entrypoint
# (minus its last line, main "$@"), with fixture verbs added to the registry.
#
#   scripts/test-runs.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
command -v script >/dev/null || { echo "FAIL: needs script(1) (util-linux)" >&2; exit 1; }

lib=$(mktemp .test-runs.XXXXXX)
T=$(mktemp -d); export T
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; for f in "$T"/local/runs/*.log; do [[ -e "$f" ]] && { echo "--- $f" >&2; cat "$f" >&2; }; done; exit 1; }

cat > "$T/fx.sh" <<EOF
source "$PWD/$lib"
LOCAL_DIR=\$T/local; ENV_FILE=\$T/env; CGROUP_FILE=\$T/cgroup
repo_owned() { :; }
sudo() { :; }
VERBS+=("fx~fx~free~Internal~fixture" "fxexec~fxexec~free~Internal~fixture" "fxchild~fxchild~free~Internal~fixture" "fxsleep~fxsleep~free~Internal~fixture")
cmd_fx() {
    echo "out one"; echo "err one" >&2; printf '\e[32mOK\e[0m green\n'; echo "out two"
    echo "secret: hunter2hunter2"
    [[ "\${1:-}" == fail ]] && die "boom"
    printf 'a\\\\b  \n\ttab \n{"j":[1]}\nno-newline'   # last: a run's output need not end its line
    return 0
}
cmd_fxexec()  { echo "before exec"; exec bash "\$T/after.sh"; }
cmd_fxchild() { echo "parent"; bash "\$T/child.sh"; echo "parent again"; }
cmd_fxsleep() { echo "started"; sleep 5; echo "never"; }
EOF
cat > "$T/after.sh" <<EOF
source "\$T/fx.sh"; cmd_fx() { echo "after exec"; exit 3; }; main fx
EOF
cp "$T/after.sh" "$T/child.sh"; sed -i 's/exit 3/return 0/; s/after exec/child/' "$T/child.sh"
printf 'TZ=America/Los_Angeles\nARR_PASSWORD=hunter2hunter2\n' > "$T/env"

reset() { rm -rf "$T/local" "$T/cgroup"; mkdir -p "$T/local"; }
run() { bash -c "source \"\$T/fx.sh\"; main $*"; }   # run VERB ARG... — stdout and stderr where the caller sends them
rec() { ls "$T"/local/runs/*-"$1"-*.log 2>/dev/null | tail -n 1; }
footer() { # footer FILE -> its exit line, once the stamper has written it (it may come a moment after the run)
    local i; for (( i = 0; i < 40; i++ )); do [[ "$(tail -n 1 "$1")" == exit:* ]] && break; sleep 0.05; done
    tail -n 1 "$1"
}

# ---- a record ----
reset; run fx > "$T/o" 2> "$T/e"; rc=$?
f=$(rec fx); [[ -n "$f" && $rc == 0 ]] || fail_ "fx ran and was recorded (rc=$rc)"; pass
[[ "$(footer "$f")" == "exit:     0 after "*s ]] || fail_ "the footer has the exit code"; pass
head -6 "$f" > "$T/h"
grep -qx '# mediastack run' "$T/h" && grep -qx 'verb:     fx' "$T/h" && grep -qE '^commit:   ' "$T/h" \
    && grep -qx 'by:       other' "$T/h" && grep -qE '^started:  2[0-9-]+T[0-9:]+-0[78]:00$' "$T/h" \
    || fail_ "the header: verb, commit, who, when (in .env's TZ, with its offset)"; pass
grep -qE '^[0-9]{2}:[0-9]{2}:[0-9]{2} out one$' "$f" && grep -qE '^[0-9:]{8} err one$' "$f" \
    || fail_ "every line, stdout and stderr, timestamped"; pass
grep -qE '^[0-9:]{8} OK green$' "$f" && ! grep -q $'\e' "$f" || fail_ "colours stripped"; pass
grep -qE '^[0-9:]{8} secret: <secret:ARR_PASSWORD>$' "$f" && ! grep -q hunter2 "$f" || fail_ "a secret .env holds never stays in the record"; pass
[[ "$(stat -c %a "$f")" == 600 ]] || fail_ "the record is its owner's alone"; pass
reset; run fx fail > /dev/null 2>&1 && fail_ "fx fail fails"
[[ "$(footer "$(rec fx)")" == "exit:     1 after "* ]] && grep -qE '^[0-9:]{8} ERROR boom$' "$(rec fx)" \
    || fail_ "a failed run: its error line and exit 1"; pass

# ---- a record never changes a run ----
reset; run fx > "$T/o1" 2> "$T/e1"
bash -c "source \"\$T/fx.sh\"; run_record_start() { :; }; main fx" > "$T/o0" 2> "$T/e0"
cmp -s "$T/o0" "$T/o1" && cmp -s "$T/e0" "$T/e1" || fail_ "stdout and stderr byte for byte, recorded or not"; pass
reset; run fx > "$T/m1" 2>&1
bash -c "source \"\$T/fx.sh\"; run_record_start() { :; }; main fx" > "$T/m0" 2>&1
cmp -s "$T/m0" "$T/m1" || fail_ "stdout and stderr in one place keep their order"; pass
reset; : > "$T/local/runs"; run fx > "$T/o2" 2> "$T/e2"; rc=$?   # a file where the folder goes: no record, even for root
[[ $rc == 0 ]] && cmp -s "$T/o0" "$T/o2" && grep -qF 'this run is not recorded' "$T/e2" \
    || fail_ "no record possible: the run is the same, and says so (rc=$rc)"; pass
reset; run nosuchverb > /dev/null 2>&1 || true
[[ -z "$(ls "$T/local/runs" 2>/dev/null)" ]] || fail_ "an unknown verb is refused before anything is recorded"; pass

# ---- exec and children ----
reset; rc=0; run fxexec > "$T/o" 2>&1 || rc=$?
[[ $rc == 3 && $(ls "$T"/local/runs/*.log | wc -l) == 1 ]] || fail_ "exec keeps one record (rc=$rc)"; pass
f=$(rec fxexec); [[ "$(footer "$f")" == "exit:     3 after "* ]] && grep -q 'before exec' "$f" && grep -q 'after exec' "$f" \
    || fail_ "the exec'd script writes into it and ends it with its own exit code"; pass
reset; run fxchild > "$T/o" 2>&1
f=$(rec fxchild); [[ $(ls "$T"/local/runs/*.log | wc -l) == 1 && "$(footer "$f")" == exit:* && $(grep -c '^exit:' "$f") == 1 ]] \
    && grep -qE '[0-9:]{8} child$' "$f" && grep -q 'parent again' "$f" \
    || fail_ "a child writes into the parent's record and ends nothing"; pass

# ---- how a run ends ----
for s in TERM:143 HUP:129; do
    reset; bash -c "source \"\$T/fx.sh\"; main fxsleep" > /dev/null 2>&1 & p=$!
    sleep 0.6; kill -"${s%%:*}" "$p"; pkill -"${s%%:*}" -P "$p" sleep 2>/dev/null || true; wait "$p" 2>/dev/null || true
    [[ "$(footer "$(rec fxsleep)")" == "exit:     ${s#*:} after "* ]] || fail_ "SIG${s%%:*} ends the record with ${s#*:}"; pass
done
reset; (sleep 0.8; printf '\003'; sleep 1) | script -qec "bash -c 'source \"$T/fx.sh\"; main fxsleep'" /dev/null > /dev/null 2>&1 || true
f=$(rec fxsleep); [[ "$(footer "$f")" == "exit:     130 after "* ]] && grep -qx 'by:       terminal' "$f" \
    || fail_ "Ctrl-C at a terminal ends the record with 130"; pass
reset; bash -c "source \"\$T/fx.sh\"; main fxsleep" > /dev/null 2>&1 & p=$!
sleep 0.6; kill -KILL "$p"; wait "$p" 2>/dev/null || true; sleep 0.5
f=$(rec fxsleep); grep -q 'started' "$f" && ! grep -q '^exit:' "$f" || fail_ "a killed run has no footer: it never finished"; pass

# ---- verbs whose output is not recorded ----
bash -c "source \"$PWD/$lib\"; for v in \"\${RUNS_HEADER_ONLY[@]}\"; do verb_entry \"\$v\" >/dev/null || { echo \"\$v\"; exit 1; }; done" \
    || fail_ "every header-only verb is a verb"; pass
reset; bash -c "source \"\$T/fx.sh\"; VERBS+=(\"credentials~credentials~free~Internal~x\"); cmd_credentials() { echo 'admin: s3cr3t-value'; }; main credentials" > "$T/o" 2>&1
f=$(rec credentials); grep -q 's3cr3t-value' "$T/o" && ! grep -q 's3cr3t' "$f" && grep -q '^output: not recorded' "$f" \
    && [[ "$(footer "$f")" == "exit:     0 after "* ]] || fail_ "credentials: shown, never recorded; header and footer kept"; pass

# ---- retention ----
reset; mkdir -p "$T/local/runs"; cd "$T/local/runs"
for i in $(seq -w 1 25); do printf 'x\n---\nexit:     0 after 1s\n' > "202611${i}-000000-vw-1$i.log"; done
printf 'x\n---\nexit:     1 after 1s\n' > 20261102-000001-vw-901.log
printf 'x\n' > 20261102-000002-vw-902.log
printf 'x\n' > 20261102-000003-vw-903.log; touch -d '40 days ago' 20261102-000003-vw-903.log
printf 'x\n---\nexit:     0 after 1s\n' > 20261101-000000-vw--full-1.log
cd - > /dev/null
bash -c "source \"\$T/fx.sh\"; RUNS_DIR=\$T/local/runs; run_prune"
ls "$T/local/runs" > "$T/kept"
[[ $(grep -c -- '-vw-1' "$T/kept") == 20 ]] && ! grep -q 20261101-000000-vw-101 "$T/kept" && grep -q 20261125-000000-vw-125 "$T/kept" \
    || fail_ "the newest 20 successful runs per verb: $(tr '\n' ' ' < "$T/kept")"; pass
grep -q vw-901 "$T/kept" && grep -q vw-902 "$T/kept" && ! grep -q vw-903 "$T/kept" \
    || fail_ "beyond them, failed and unfinished runs stay 30 days"; pass
grep -q 'vw--full-1' "$T/kept" || fail_ "a verb's options count apart"; pass

# ---- who started it ----
by() { sed -n 4p "$(rec fx)"; }
reset; echo "0::/system.slice/mediastack-people.service" > "$T/cgroup"; run fx > /dev/null 2>&1
[[ "$(by)" == "by:       systemd mediastack-people" ]] || fail_ "a timer's run names its unit: $(by)"; pass
reset; SUDO_USER=olivetin run fx > /dev/null 2>&1 < /dev/null
[[ "$(by)" == "by:       panel" ]] || fail_ "the panel's: $(by)"; pass

# ---- one EXIT trap; the keepalive lets go ----
traps=$(grep -rnE '^[[:space:]]*\(?[[:space:]]*trap .*EXIT' mediastack.sh lib services | grep -vE '^lib/common\.sh:.*trap run_exit_hooks EXIT' || true)
[[ "$(wc -l <<<"$traps")" == 2 && "$traps" == *"lib/backup.sh"*"stopped_restart EXIT"* && "$traps" == *"audiobookshelf.sh"*"link_abs_close"* ]] \
    || fail_ "EXIT traps only in subshells (stopped_run, link-account); the main shell's go through on_exit: $traps"; pass
reset; script -qec "bash -c 'source \"$T/fx.sh\"; id() { echo 1000; }; main fx'" /dev/null > /dev/null 2>&1 || true
f=$(rec fx); sleep 0.3; [[ "$(tail -n 1 "$f")" == exit:* ]] || fail_ "with the sudo keepalive running, the footer comes at once"; pass

echo "OK runs: $checks checks"
