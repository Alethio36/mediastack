#!/usr/bin/env bash
# lib/runs.sh — every run recorded in local/runs/ (docs/design-runs.md): a
# header, everything the run printed (each line timestamped, colours
# stripped), a footer with its exit status. A record never changes a run: the
# screen gets the same bytes through `tee`, the exit code is the run's own,
# and a record that cannot be written is reported once while the run goes on.
#
#   main ── stdout/stderr ──> tee ──> the screen, as before
#                              └────> run_stamp ──> the record, then its footer
#
# One tee when stdout and stderr go to the same place (a terminal, `2>&1`,
# the journal), so their order is kept exactly; two otherwise, each with its
# own stamper, so a program reading stdout (`list --json`) gets exactly what
# it did before and a line of one stream never splits a line of the other.
# The last stamper to finish writes the footer: the run leaves its exit
# status in <record>.end, and a record with no footer never finished.
# Sourced by the entrypoint; main() calls run_record_start.

RUNS_DIR=""                 # LOCAL_DIR/runs, set when a run starts (a test that moves LOCAL_DIR moves it too)
RUNS_KEEP=20                # per verb and its options: the newest this many
RUNS_KEEP_FAILED_DAYS=30    # a failed or unfinished one beyond them is kept this long
RUNS_FLUSH_WAIT=5           # seconds the end of a run waits for its last output to reach the screen
RUNS_SCRUB_MIN=6            # a secret shorter than this is not looked for (it would match ordinary words)
# their output is a secret (logins, invitation and sign-in links) or other
# people's activity (container logs, and `logs -f` never ends): header and footer only
RUNS_HEADER_ONLY=(credentials invite reset-password set-credentials logs)

RUN_OWNER=0   # 1 in the process that ends the record (the one that opened it, or the script it exec'd)
RUN_TZ=""     # the stack's time zone (.env TZ), for the record's times

run_key() { # run_key VERB ARG... -> the verb and its options, as one file-name part (vpn-watch--full)
    local k=$1 a; shift
    for a in "$@"; do [[ "$a" == -* ]] && k+="${a%%=*}"; done
    echo "${k//[^a-z0-9-]/}"
}

run_date() { # date in the stack's time zone
    if [[ -n "$RUN_TZ" ]]; then TZ="$RUN_TZ" date "$@"; else date "$@"; fi
}

run_by() { # who started this run: terminal | panel | systemd <unit> | other
    local cg=""
    [[ -r "$CGROUP_FILE" ]] && cg=$(<"$CGROUP_FILE")
    if [[ "$cg" =~ /(mediastack-[a-z0-9@-]+)\.service ]]; then echo "systemd ${BASH_REMATCH[1]}"
    elif [[ "${SUDO_USER:-}" == olivetin ]]; then echo panel   # its wrapper runs: sudo -n mediastack.sh …
    elif [[ -t 0 ]]; then echo terminal
    else echo other; fi
}

run_commit() { # the code this run is: short commit and branch
    local c b
    c=$(git -c safe.directory="$SCRIPT_DIR" -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null) || { echo unknown; return 0; }
    b=$(git -c safe.directory="$SCRIPT_DIR" -C "$SCRIPT_DIR" symbolic-ref --short -q HEAD 2>/dev/null) || b=detached
    echo "$c ($b)"
}

run_header_only() { local v; for v in "${RUNS_HEADER_ONLY[@]}"; do [[ "$1" == "$v" ]] && return 0; done; return 1; }

run_same_target() { # stdout and stderr lead to the same place (the same terminal, pipe, socket or file)
    local a b me=$BASHPID   # this process's: inside $( ) BASHPID is the substitution's
    a=$(stat -L -c '%d:%i' "/proc/$me/fd/1" 2>/dev/null) || return 1
    b=$(stat -L -c '%d:%i' "/proc/$me/fd/2" 2>/dev/null) || return 1
    [[ "$a" == "$b" ]]
}

run_succeeded() { [[ "$(tail -n 1 "$1" 2>/dev/null)" == "exit:     0 after "* ]]; }

run_prune() { # per verb and its options, the newest RUNS_KEEP; beyond them a failed or unfinished one stays RUNS_KEEP_FAILED_DAYS days
    local -a files=("$RUNS_DIR"/*.log)
    [[ -e "${files[0]}" ]] || return 0
    local -A seen=()
    local i f n key old=$(( EPOCHSECONDS - RUNS_KEEP_FAILED_DAYS * 86400 ))
    for (( i = ${#files[@]} - 1; i >= 0; i-- )); do   # names start with the time: the newest last
        f=${files[i]}; n=${f##*/}; key=${n:16}; key=${key%-*.log}
        seen[$key]=$(( ${seen[$key]:-0} + 1 ))
        (( seen[$key] > RUNS_KEEP )) || continue
        if run_succeeded "$f" || (( $(stat -c %Y "$f") < old )); then rm -f "$f"; fi
    done
    # what a run killed between its two last steps left behind
    find "$RUNS_DIR" -maxdepth 1 \( -name '*.end' -o -name '*.done' -o -name '*.lock' \) -mmin +1440 -delete 2>/dev/null || true
}

run_secret_pairs() { # KEY<TAB>VALUE for every secret .env holds (the schema's type, family rows included)
    local k t line key v r
    local -a res=()
    [[ -r "$ENV_FILE" ]] || return 0
    while IFS=$'\t' read -r k t _; do
        [[ "$t" == secret ]] || continue
        while [[ "$k" =~ ^(.*)\<[a-z]+\>(.*)$ ]]; do k="${BASH_REMATCH[1]}[A-Z0-9_]+${BASH_REMATCH[2]}"; done
        res+=("^$k\$")
    done < <(env_schema_rows 2>/dev/null)
    while IFS= read -r line; do
        [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || continue
        key=${BASH_REMATCH[1]}; v=${BASH_REMATCH[2]}
        (( ${#v} >= RUNS_SCRUB_MIN )) || continue
        for r in "${res[@]}"; do [[ "$key" =~ $r ]] && { printf '%s\t%s\n' "$key" "$v"; break; }; done
    done < "$ENV_FILE"
}

run_scrub() { # run_scrub FILE — every secret .env holds becomes <secret:KEY> in it (a printed one never stays in a record)
    local f=$1 tmp
    tmp=$(mktemp "$f.XXXXXX") || return 0
    # the secrets reach awk on a pipe, never its command line (ps would show them)
    if awk -F'\t' 'FILENAME == ARGV[1] { k[++n] = $1; v[n] = substr($0, length($1) + 2); next }
        { for (i = 1; i <= n; i++) while ((p = index($0, v[i])) > 0) $0 = substr($0, 1, p - 1) "<secret:" k[i] ">" substr($0, p + length(v[i])); print }' \
        <(run_secret_pairs) "$f" > "$tmp"; then
        cat "$tmp" > "$f"   # in place: the record keeps its owner and mode
    fi
    rm -f "$tmp"
}

run_footer() { # run_footer FILE RC SECONDS
    printf -- '---\nexit:     %s after %ss\n' "$2" "$3" >> "$1" 2>/dev/null || true
}

run_stamp() { # run_stamp FILE STAMPERS — stdin into FILE line by line, timestamped and without colours; the last stamper writes the footer
    set +eE; trap - ERR; trap '' INT HUP TERM PIPE   # outlive Ctrl-C and a dropped session: the end of the run is recorded too
    local f=$1 total=$2 line fd=-1 lk n rc dur re=$'\e\\[[0-9;?]*[A-Za-z]'
    [[ -n "$RUN_TZ" ]] && export TZ="$RUN_TZ"
    exec {fd}>>"$f" || fd=-1
    while IFS= read -r line || [[ -n "$line" ]]; do
        (( fd >= 0 )) || continue   # keep reading, so the screen never waits on a record that stopped
        while [[ "$line" =~ $re ]]; do line=${line/"${BASH_REMATCH[0]}"/}; done
        line=${line//$'\r'/}
        # shellcheck disable=SC2261  # fd is the record (10 or above), never stderr
        printf '%(%T)T %s\n' -1 "$line" >&"$fd" 2>/dev/null && continue
        printf 'mediastack: this run'\''s record stopped (%s cannot be written) — the run carries on\n' "$f" >&2
        exec {fd}>&-; fd=-1
    done
    (( fd >= 0 )) && exec {fd}>&-
    # the last stamper to finish ends the record
    exec {lk}>>"$f.lock" && flock "$lk" || return 0
    n=$(( $(cat "$f.done" 2>/dev/null || echo 0) + 1 ))
    if (( n < total )); then echo "$n" > "$f.done"; return 0; fi
    rm -f "$f.done" "$f.lock"
    run_scrub "$f"
    # the run says how it ended just before its output closes; none: it never finished
    [[ -r "$f.end" ]] || return 0
    read -r rc dur < "$f.end"; rm -f "$f.end"
    run_footer "$f" "$rc" "$dur"
}

# bash's EXIT trap sees $? = 0 after a signal: these note the signal, then let
# it end the run as it always did (the default action, re-raised)
RUN_SIGNALLED=""
run_signal() { RUN_SIGNALLED=$2; trap - "$1"; kill -"$1" "$BASHPID"; }
run_signals_arm() { trap 'run_signal INT 130' INT; trap 'run_signal TERM 143' TERM; trap 'run_signal HUP 129' HUP; }
int_trap_default() { # after a temporary INT trap: back to what this run has (its record's, or bash's own)
    if (( RUN_OWNER )); then trap 'run_signal INT 130' INT; else trap - INT; fi
}

run_gone() { # run_gone PID — the process has ended (exited, or a zombie nobody reaped)
    [[ ! -e "/proc/$1/status" ]] || [[ "$(grep '^State:' "/proc/$1/status" 2>/dev/null)" == *Z* ]]
}

# ---- reading records (unit-failed, doctor) ----
run_records_dir() { echo "${RUNS_DIR:-$LOCAL_DIR/runs}"; }
run_record_of_pid() { # run_record_of_pid PID -> the record that process opened ("" if none)
    local -a f=("$(run_records_dir)"/*-"$1".log)
    [[ "$1" =~ ^[0-9]+$ && -e "${f[-1]}" ]] && echo "${f[-1]}"
    return 0
}
run_record_tail() { # run_record_tail FILE N -> its last N lines of output, without the header or footer
    local i
    # its stamper may still be writing the footer just after the run ended
    for (( i = 0; i < 40; i++ )); do [[ "$(tail -n 1 "$1" 2>/dev/null)" == exit:* ]] && break; sleep 0.05; done
    awk -v n="$2" 'NR > 6 { l[NR] = $0 }
        END { last = NR; if (l[NR] ~ /^exit: / && l[NR - 1] == "---") last = NR - 2
              for (i = last - n + 1; i <= last; i++) if (i > 6) print l[i] }' "$1"
}
run_alive() { # run_alive PID — that run's process is still going (a live mediastack.sh, not a reused pid)
    [[ -r "/proc/$1/cmdline" ]] || return 1
    [[ "$(grep '^State:' "/proc/$1/status" 2>/dev/null)" != *Z* ]] || return 1
    [[ "$(tr '\0' ' ' < "/proc/$1/cmdline")" == *mediastack.sh* ]]
}
run_unfinished() { # run_unfinished DAYS -> one line per run from the last DAYS days that never finished: FILE<TAB>verb<TAB>by<TAB>started
    local f pid since=$(( EPOCHSECONDS - $1 * 86400 ))
    for f in "$(run_records_dir)"/*.log; do
        [[ -e "$f" ]] || continue
        (( $(stat -c %Y "$f") >= since )) || continue
        [[ "$(tail -n 1 "$f")" == exit:* ]] && continue
        pid=${f%.log}; pid=${pid##*-}
        run_alive "$pid" && continue   # still running (this doctor among them)
        printf '%s\t%s\t%s\t%s\n' "$f" "$(sed -n 's/^verb: *//p' "$f")" "$(sed -n 's/^by: *//p' "$f")" "$(sed -n 's/^started: *//p' "$f")"
    done
}

run_record_start() { # run_record_start VERB ARG... — record this run, or carry on the record this process inherited
    on_exit run_record_end   # also arms the EXIT trap: main() may run in a subshell (a test), which has none of its own
    if [[ -n "${MS_RUN_RECORD:-}" ]]; then
        # exec keeps the pid: upgrade's hand-over and install's configure end the record;
        # any other process (configure's questionnaire, update's wire --verify) only writes into it
        [[ "${MS_RUN_PID:-}" == "$BASHPID" ]] && { RUN_OWNER=1; run_signals_arm; }
        return 0
    fi
    RUNS_DIR="$LOCAL_DIR/runs"
    mkdir -p "$RUNS_DIR" 2>/dev/null && repo_owned "$LOCAL_DIR" "$RUNS_DIR" 2>/dev/null \
        || { warn "this run is not recorded: $RUNS_DIR cannot be made" >&2; return 0; }
    run_prune
    [[ -r "$ENV_FILE" ]] && RUN_TZ=$(env_get TZ)
    local f
    f="$RUNS_DIR/$(run_date +%Y%m%d-%H%M%S)-$(run_key "$@")-$BASHPID.log"
    if ! ( umask 077
           { echo "# mediastack run"
             printf 'verb:     %s\n' "$*"
             printf 'commit:   %s\n' "$(run_commit)"
             printf 'by:       %s\n' "$(run_by)"
             printf 'started:  %s\n' "$(run_date --iso-8601=seconds)"
             echo '---'; } > "$f" ) 2>/dev/null; then
        warn "this run is not recorded: $f cannot be written" >&2; return 0
    fi
    repo_owned "$f"
    export MS_RUN_RECORD="$f" MS_RUN_PID=$BASHPID MS_RUN_T0=$EPOCHSECONDS MS_RUN_FDS="" MS_RUN_TEES=""
    RUN_OWNER=1; run_signals_arm
    if run_header_only "$1"; then
        echo "output: not recorded — it prints secrets or other people's activity" >> "$f"
        return 0
    fi
    local o e s1 s2
    exec {o}>&1 {e}>&2
    if run_same_target; then
        exec {s1}> >(run_stamp "$f" 1)
        exec > >(trap '' INT HUP; exec tee -p "/dev/fd/$s1") 2>&1
        MS_RUN_TEES=$!
        MS_RUN_FDS="$o $e $s1"
    else
        exec {s1}> >(run_stamp "$f" 2) {s2}> >(run_stamp "$f" 2)
        exec > >(trap '' INT HUP; exec tee -p "/dev/fd/$s1")
        MS_RUN_TEES=$!
        exec 2> >(trap '' INT HUP; exec tee -p "/dev/fd/$s2" >&"$e")
        MS_RUN_TEES+=" $!"
        MS_RUN_FDS="$o $e $s1 $s2"
    fi
}

run_fds_close() { # in a background helper: let go of the record's pipes, so the record can end without waiting for it
    local o e s1 s2
    read -r o e s1 s2 <<<"${MS_RUN_FDS:-}"
    [[ -n "$s1" ]] && exec {s1}>&-
    [[ -n "$s2" ]] && exec {s2}>&-
    return 0
}

run_record_end() { # run_record_end RC — on exit: restore the screen, let the stamper write the footer
    local rc=${RUN_SIGNALLED:-$1} o e s1 s2 p waited=0
    (( RUN_OWNER )) || return 0
    RUN_OWNER=0
    local f=$MS_RUN_RECORD dur=$(( EPOCHSECONDS - ${MS_RUN_T0:-$EPOCHSECONDS} ))
    if [[ -z "${MS_RUN_FDS:-}" ]]; then run_footer "$f" "$rc" "$dur"; return 0; fi
    printf '%s %s\n' "$rc" "$dur" > "$f.end" 2>/dev/null || true
    read -r o e s1 s2 <<<"$MS_RUN_FDS"
    exec 1>&"$o" 2>&"$e"
    exec {s1}>&- {o}>&- {e}>&-
    [[ -n "$s2" ]] && exec {s2}>&-
    # the screen gets the run's last lines before the shell's prompt does
    for p in $MS_RUN_TEES; do
        while ! run_gone "$p" && (( waited < RUNS_FLUSH_WAIT * 20 )); do sleep 0.05; waited=$((waited + 1)); done
    done
    return 0
}
