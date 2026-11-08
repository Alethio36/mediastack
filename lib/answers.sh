#!/usr/bin/env bash
# lib/answers.sh — the answers file (docs/design-answers.md): configure's
# questions answered ahead, in .env syntax. A written answer is used; a blank
# one keeps what is set, else takes the recommendation, else is asked — and
# with no terminal, every answer that would be asked is missing.
#
# Two passes, both the questionnaire itself:
#   check  on a scratch copy of .env and local/state, nothing asked: every
#          refused or missing answer is collected, then listed at once
#   apply  the real run, once the check found nothing
# A section uses `answer KEY` before it asks, runs its own check on what it
# got, and reports a refusal with answer_refused. Where it would ask, pass 1
# calls q_unasked instead: the question is asked in pass 2, or (no terminal)
# its answer is missing. Sourced by the entrypoint; relies on lib/common.sh
# and lib/env.sh at call time.

ANSWERS_FILE=""                  # configure --answers FILE; "" = none
ANSWERS_PASS=""                  # "" (no file) | check | apply
ANSWERS_PROBLEMS=""              # pass 1: the file its problems are collected in
declare -gA ANSWER=()            # KEY -> the written answer (only written ones are here)
# words that stand for an empty value, which is never an answer itself
declare -gA ANSWER_WORDS=([UPDATE_SCHEDULE]=never [BACKUP_SCHEDULE]=never [VPN_SERVER_COUNTRIES]=auto)
# names the questions take in any case and record lowercase: the file does the same
ANSWER_LOWER=" SMTP_HOST STACK_DOMAIN VPN_PROVIDER "

answer() { # answer KEY -> REPLY_VAL = the written answer, rc 0; rc 1 when the file leaves it blank (or there is none)
    [[ -n "${ANSWER[$1]+set}" ]] || return 1
    # shellcheck disable=SC2034  # read by the caller, as every prompt's answer is
    REPLY_VAL=${ANSWER[$1]}
}
answers_any() { local k; for k in "$@"; do [[ -n "${ANSWER[$k]+set}" ]] && return 0; done; return 1; }   # answers_any KEY... — one of them written
answers_checking() { [[ "$ANSWERS_PASS" == check ]]; }
q_terminal() { [[ -t 0 || -n "${Q_TERMINAL:-}" ]]; }   # someone to ask (Q_TERMINAL: tests feed answers on a pipe)

answer_refused() { # answer_refused MESSAGE — pass 1 collects it; any later is a bug in pass 1, so it stops
    if answers_checking; then printf '%s\n' "$1" >> "$ANSWERS_PROBLEMS"; return 0; fi
    die "answers file: $1"
}
q_unasked() { # q_unasked TITLE KEYS — pass 1 at a question pass 2 would ask: with no terminal its answer is missing
    q_terminal || answer_refused "$1 is not answered — set $2"
}
q_answered() { # q_answered TITLE VALUE [secret] — said like quick's recommended answers
    if [[ "${3:-}" == secret ]]; then info "$1: set (from the answers file)"; else info "$1: ${2:-(empty)} (from the answers file)"; fi
}

answers_load() { # answers_load FILE — ANSWER from it; every problem with the file itself through answer_refused
    local f=$1 n=0 line k v row t e r
    [[ -f "$f" && -r "$f" ]] || { answer_refused "$f is not a readable file"; return 0; }
    [[ "$(stat -c %u "$f")" == "$(id -u)" ]] || answer_refused "$f is not yours — it holds secrets: make it yours (chown) and readable by you alone (chmod 600)"
    (( 8#$(stat -c %a "$f") & 8#077 )) && answer_refused "$f can be read by others ($(stat -c %a "$f")) — it holds secrets: chmod 600 $f"
    declare -A seen=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        if [[ ! "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
            answer_refused "line $n is not KEY=value"; continue
        fi
        k=${BASH_REMATCH[1]}; v=${BASH_REMATCH[2]}
        [[ -z "${seen[$k]:-}" ]] || { answer_refused "$k is answered twice (lines ${seen[$k]} and $n)"; continue; }
        seen[$k]=$n
        row=$(env_schema_known <(echo "$k=") all 6) || true
        r=$(cut -f2 <<<"$row")
        if [[ -z "$row" || "$r" == - ]]; then
            answer_refused "$k is no question configure asks (a typo, or a setting for .env itself)"; continue
        fi
        [[ -n "$v" ]] || continue   # blank: not answered
        [[ "$ANSWER_LOWER" != *" $k "* ]] || v=${v,,}
        if [[ -n "${ANSWER_WORDS[$k]:-}" && "$v" == "${ANSWER_WORDS[$k]}" ]]; then ANSWER[$k]=""; continue; fi
        t=$(env_schema_known <(echo "$k=") all 2 | cut -f2); e=$(cut -f3 <<<"$row")
        r=$(env_value_problem "$k" "$v" "$t" "$e")
        [[ -z "$r" ]] || { answer_refused "$r"; continue; }
        ANSWER[$k]=$v
    done < "$f"
}

questionnaire_answers_run() { # questionnaire_answers_run FILE [--fresh] — pass 1 on a scratch copy, then (nothing found) pass 2; rc 4 with the list
    local file=$1 scratch rc=0; shift
    scratch=$(mktemp -d)
    # shellcheck disable=SC2034  # read by the questionnaire's sections
    ANSWERS_FILE=$file; ANSWERS_PROBLEMS=$scratch/problems; : > "$ANSWERS_PROBLEMS"
    ANSWERS_PASS=check
    answers_load "$file"
    if [[ ! -s "$ANSWERS_PROBLEMS" ]]; then
        # the scratch copy lives in /tmp, never in the repo: nothing to hand to the repo's owner
        mkdir "$scratch/state"; cat "$ENV_FILE" > "$scratch/env"
        [[ ! -d "$STATE_DIR" ]] || cp -a "$STATE_DIR/." "$scratch/state/"
        ( ENV_FILE=$scratch/env STATE_DIR=$scratch/state; questionnaire_run "$@" ) > "$scratch/out" 2>&1 || rc=$?
        if (( rc )); then
            answer_refused "the check stopped before the end (exit $rc): $(grep -E 'ERROR' "$scratch/out" | tail -1 | sed 's/\x1b\[[0-9;]*m//g')"
        fi
    fi
    if [[ -s "$ANSWERS_PROBLEMS" ]]; then
        fail "the answers file $file: $(grep -c . "$ANSWERS_PROBLEMS") problem(s) — nothing was asked or written:"
        sed 's/^/  * /' "$ANSWERS_PROBLEMS" >&2
        rm -rf "$scratch"
        return 4
    fi
    rm -rf "$scratch"
    ANSWERS_PASS=apply
    questionnaire_run "$@"
}
