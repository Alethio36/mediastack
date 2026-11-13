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

ANSWERS_ON=""                    # 1 when answers were given (a file, the flags, or both)
ANSWERS_PASS=""                  # "" (none given) | check | apply
ANSWERS_PROBLEMS=""              # pass 1: the file its problems are collected in
declare -gA ANSWER=()            # KEY -> the written answer (only written ones are here)
# words that stand for an empty value, which is never an answer itself
declare -gA ANSWER_WORDS=([UPDATE_SCHEDULE]=never [BACKUP_SCHEDULE]=never [VPN_SERVER_COUNTRIES]=auto)
# names the questions take in any case and record lowercase: the file does the same
ANSWER_LOWER=" SMTP_HOST STACK_DOMAIN VPN_PROVIDER "
# a yes/no answer: these words in any case, recorded in the form its key keeps
ANSWER_YES=" yes y true "; ANSWER_NO=" no n false "

answer_yesno() { # answer_yesno TYPE VALUE -> the value its key keeps (true|false for bool, yes|no for enum:yes|no); rc 1 for any other word
    local v=${2,,} on off
    case "$1" in bool) on=true; off=false ;; enum:yes\|no) on=yes; off=no ;; *) return 1 ;; esac
    if [[ "$ANSWER_YES" == *" $v "* ]]; then echo "$on"
    elif [[ "$ANSWER_NO" == *" $v "* ]]; then echo "$off"
    else return 1; fi
}

answer() { # answer KEY -> REPLY_VAL = the written answer, rc 0; rc 1 when the file leaves it blank (or there is none)
    [[ -n "${ANSWER[$1]+set}" ]] || return 1
    # shellcheck disable=SC2034  # read by the caller, as every prompt's answer is
    REPLY_VAL=${ANSWER[$1]}
}
answers_any() { local k; for k in "$@"; do [[ -n "${ANSWER[$k]+set}" ]] && return 0; done; return 1; }   # answers_any KEY... — one of them written
answers_checking() { [[ "$ANSWERS_PASS" == check ]]; }
answers_on() { [[ -n "$ANSWERS_ON" ]]; }   # answers were given: a blank mode is quick, optional ones stay unset with no one to ask
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

# ---------------------------------------------------- the options, given --
# install, configure and the questionnaire take the same four; install hands
# them to configure, configure to the questionnaire
ANSWERS_OPTS=()   # the answers options as given (the file's path made absolute)
ANSWERS_REST=()   # every other argument
answers_opts() { # answers_opts ARG... -> ANSWERS_OPTS, ANSWERS_REST
    ANSWERS_OPTS=(); ANSWERS_REST=()
    local v
    while (( $# )); do
        case "$1" in
            --answers|--domain|--services|--signin)
                [[ -n "${2:-}" && "$2" != --* ]] || die "$1: give it a value (docs/design-answers.md)"
                v=$2
                if [[ "$1" == --answers ]]; then
                    [[ "$v" == /* ]] || v=$CALLER_DIR/$v
                    [[ -f "$v" ]] || die "--answers: $2 is not a file"
                fi
                ANSWERS_OPTS+=("$1" "$v"); shift 2 ;;
            *) ANSWERS_REST+=("$1"); shift ;;
        esac
    done
}

# shellcheck disable=SC2034  # read by the services question (lib/questionnaire.sh)
ANSWER_SERVICES=""   # --services: exactly these run (the file's ENABLE_ lines give way), " a b "

# shellcheck disable=SC2034  # ANSWER_SERVICES: read by the services question
answers_flags() { # answers_flags --domain D | --signin X | --services a,b ... — into the answers, over the file's
    local t
    while (( $# )); do
        case "$1" in
            --domain)   t=$(env_value_problem STACK_DOMAIN "${2,,}" domain no)
                        if [[ -z "$t" ]]; then ANSWER[STACK_DOMAIN]=${2,,}; else answer_refused "--domain: $t"; fi ;;
            --signin)   t=$(env_value_problem SIGNIN "$2" 'enum:none|wizarr|authentik' no)
                        if [[ -z "$t" ]]; then ANSWER[SIGNIN]=$2; else answer_refused "--signin: $t"; fi ;;
            --services) if [[ "$2" =~ ^[a-z0-9-]+(,[a-z0-9-]+)*$ ]]; then ANSWER_SERVICES=" ${2//,/ } "
                        else answer_refused "--services: '$2' is not service names, comma-separated"; fi ;;
        esac
        shift 2
    done
}

answers_load() { # answers_load FILE — ANSWER from it; every problem with the file itself through answer_refused
    local f=$1 n=0 line k v t e r
    local -A rec=() typ=() emp=()
    [[ -f "$f" && -r "$f" ]] || { answer_refused "$f is not a readable file"; return 0; }
    [[ "$(stat -c %u "$f")" == "$(id -u)" ]] || answer_refused "$f is not yours — it holds secrets: make it yours (chown) and readable by you alone (chmod 600)"
    (( 8#$(stat -c %a "$f") & 8#077 )) && answer_refused "$f can be read by others ($(stat -c %a "$f")) — it holds secrets: chmod 600 $f"
    # Windows line endings: every value would carry a hidden \r — a checked one
    # refused for a reason nobody can see, a token or password taken with it
    if grep -q $'\r' "$f"; then
        answer_refused "$f has Windows line endings (CRLF) — convert it: sed -i 's/\\r\$//' $f"
        return 0
    fi
    declare -A seen=()
    # the schema's word on every key in the file: one pass for its recommendation, one for its type
    while IFS=$'\t' read -r k r e _; do rec[$k]=$r; emp[$k]=$e; done < <(env_schema_known "$f" all 6)
    while IFS=$'\t' read -r k t _; do typ[$k]=$t; done < <(env_schema_known "$f" all 2)
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        if [[ ! "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
            answer_refused "line $n is not KEY=value"; continue
        fi
        k=${BASH_REMATCH[1]}; v=${BASH_REMATCH[2]}
        [[ -z "${seen[$k]:-}" ]] || { answer_refused "$k is answered twice (lines ${seen[$k]} and $n)"; continue; }
        seen[$k]=$n
        r=${rec[$k]:-}
        if [[ -z "$r" || "$r" == - ]]; then
            answer_refused "$k is no question configure asks (a typo, or a setting for .env itself)"; continue
        fi
        [[ -n "$v" ]] || continue   # blank: not answered
        [[ "$ANSWER_LOWER" != *" $k "* ]] || v=${v,,}
        if [[ -n "${ANSWER_WORDS[$k]:-}" && "$v" == "${ANSWER_WORDS[$k]}" ]]; then ANSWER[$k]=""; continue; fi
        case "${typ[$k]}" in
            bool|"enum:yes|no")   # yes, no, y, n, true or false, in any case
                t=$(answer_yesno "${typ[$k]}" "$v") || { answer_refused "$k='$v' is not yes or no (yes, no, y, n, true, false)"; continue; }
                v=$t ;;
            path|file) v=$(abspath "${v/#\~/$HOME}") ;;   # as a typed path is read: ~ is home, relative is the repo's
        esac
        r=$(env_value_problem "$k" "$v" "${typ[$k]}" "${emp[$k]}")
        [[ -z "$r" ]] || { answer_refused "$r"; continue; }
        ANSWER[$k]=$v
    done < "$f"
}

questionnaire_answers_run() { # questionnaire_answers_run ANSWERS-OPTIONS... [-- ARGS] — pass 1 on a scratch copy, then (nothing found) pass 2; rc 4 with the list
    local file="" scratch rc=0 given="the answers" flags=()
    while (( $# )); do
        case "$1" in
            --answers) file=$2; shift 2 ;;
            --) shift; break ;;
            *) flags+=("$1" "$2"); shift 2 ;;
        esac
    done
    [[ -z "$file" ]] || given="the answers file $file"
    (( ${#flags[@]} )) && given+=" and ${flags[*]}"
    scratch=$(mktemp -d)
    # shellcheck disable=SC2034  # read by the questionnaire's sections
    ANSWERS_ON=1; ANSWERS_PROBLEMS=$scratch/problems; : > "$ANSWERS_PROBLEMS"
    ANSWERS_PASS=check
    [[ -z "$file" ]] || answers_load "$file"
    answers_flags "${flags[@]}"
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
        fail "$given: $(grep -c . "$ANSWERS_PROBLEMS") problem(s) — nothing was asked or written:"
        sed 's/^/  * /' "$ANSWERS_PROBLEMS" >&2
        rm -rf "$scratch"
        return 4
    fi
    rm -rf "$scratch"
    ANSWERS_PASS=apply
    questionnaire_run "$@"
}
