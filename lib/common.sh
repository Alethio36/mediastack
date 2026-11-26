#!/usr/bin/env bash
# lib/common.sh — shared base for mediastack.sh and its libraries: terminal
# colours, output primitives, and .env access. Sourced first by the entrypoint
# (after SCRIPT_DIR and ENV_FILE are set); not executed directly.

# ---------------------------------------------------------------- output --
# shellcheck disable=SC2034  # colour vars are consumed by callers in the entrypoint and other libs
if [[ -t 1 ]]; then
    C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YLW=$'\e[33m'; C_BLU=$'\e[34m'
    C_BLD=$'\e[1m'; C_RST=$'\e[0m'
else
    C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_BLD=""; C_RST=""
fi
info()  { echo "${C_BLU}::${C_RST} $*"; }
ok()    { echo "${C_GRN}OK${C_RST} $*"; }
warn()  { echo "${C_YLW}WARN${C_RST} $*"; }
fail()  { echo "${C_RED}FAIL${C_RST} $*"; }
die()   { echo "${C_RED}ERROR${C_RST} $*" >&2; exit 1; }
hr()    { echo "── $* ────────────────────────────────────────────"; }

# The entrypoint's ERR trap (set -E carries it into functions). An unguarded
# command that fails ends the run under set -e; this names it in one line.
# BASH_COMMAND is the command's text before expansion, so no secret value is
# printed. Only the main shell reports — that is where a failure ends the
# run: a failing $( ), ( ) or pipeline part is named once, by the line in
# the main shell that it fails, and a process substitution's failure, whose
# status nothing reads, is not named at all. Silent wherever the failure is
# handled (bash skips the trap under if/while/!/&&/||). The exit code is
# untouched; exit (and so die) never fires the trap.
on_err() {
    local rc=$? cmd=${BASH_COMMAND//$'\n'/ } src chain="" i
    [[ $- == *e* ]] && (( BASH_SUBSHELL == 0 )) || return 0
    src=${BASH_SOURCE[1]:-$0}; src=${src#"$SCRIPT_DIR"/}; src=${src#./}   # no [1] at a bash -c top level
    # FUNCNAME[0] is on_err; bash's own "main" for a script's top level is the
    # entry called from line 0 (absent under bash -c, where the tests run)
    for (( i = 1; i < ${#FUNCNAME[@]}; i++ )); do
        (( BASH_LINENO[i] == 0 )) || chain+="${chain:+ < }${FUNCNAME[i]}"
    done
    echo "${C_RED}ERROR${C_RST} unhandled failure (exit $rc) at $src:${BASH_LINENO[0]}${chain:+ in $chain}: $cmd" >&2
}

# What runs at exit, in the main shell: one EXIT trap, armed by the first
# hook, runs every hook, newest first, each given the run's exit status. A
# second `trap … EXIT` would silently replace the others — the run record's
# footer among them — so code adds a hook here instead.
EXIT_HOOKS=()
on_exit() { EXIT_HOOKS+=("$1"); trap run_exit_hooks EXIT; }   # on_exit FUNCTION — call FUNCTION RC when the run ends
run_exit_hooks() {
    local rc=$? i
    for (( i = ${#EXIT_HOOKS[@]} - 1; i >= 0; i-- )); do "${EXIT_HOOKS[i]}" "$rc" || true; done
}

# sudo forgets the password after a gap with no sudo call (15 min on Debian),
# and one long step (a first image pull) is such a gap. A background loop
# renews it while this run lives. -n: it never asks, so it only keeps a
# password already typed in this run's terminal. Root (the panel, the
# timers) needs none; without a terminal there is no terminal's ticket.
SUDO_KEEPALIVE_EVERY=60   # seconds
sudo_keepalive() {
    (( $(id -u) == 0 )) && return 0
    [[ -t 0 ]] || return 0
    local parent=$$
    # 8<&- 9<&-: a lock this run already holds (upgrade hands the maintenance
    # lock across its exec; audit's is fd 9) must not be inherited — killed at
    # exit, the loop leaves its `sleep` behind, and that would hold the lock
    # for up to a minute after the run (found live, Nov 2026: `up` refused)
    (
        trap - ERR; set +e   # a renewal before the first sudo fails, quietly
        run_fds_close        # nor the run record's pipe, which would hold its footer back until the last sleep ends
        while kill -0 "$parent" 2>/dev/null; do
            sudo -n -v
            sleep "$SUDO_KEEPALIVE_EVERY"
        done
    ) </dev/null >/dev/null 2>&1 8<&- 9<&- &
    SUDO_KEEPALIVE_PID=$!
    on_exit sudo_keepalive_stop
}
sudo_keepalive_stop() { kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true; }

# configure's check pass (lib/answers.sh) asks nothing: a question reached
# there lacks its guard, and asking would hang an unattended run
prompt_guard() { [[ "${ANSWERS_PASS:-}" != check ]] || die "configure's check reached the question '$1' — it has no answers-file guard (a bug)"; }

confirm_yes() { # confirm_yes "question" -> 0 yes (also Enter, or input that has ended) / 1 no
    prompt_guard "$1"
    local ans
    read -r -p "$1 [Y/n]: " ans || true
    [[ -z "$ans" || "${ans,,}" == y || "${ans,,}" == yes ]]
}

hidden_clean() { # hidden_clean VALUE -> HIDDEN_VAL: without terminal escape sequences or control characters (says so when it took any)
    # an arrow key pressed while pasting into a hidden prompt arrives as ESC [ B,
    # unseen — it glued ^[[B onto a webhook URL (found live, Oct 2026)
    local c
    c=$(printf '%s' "$1" | sed -E $'s/\x1b\\[[0-9;?]*[ -/]*[@-~]//g; s/\x1bO[A-Za-z]//g; s/[[:cntrl:]]//g')
    if [[ "$c" != "$1" ]]; then warn "took $(( ${#1} - ${#c} )) terminal control character(s) out of what you pasted (an arrow key?)"; fi
    HIDDEN_VAL=$c
}

ask_hidden() { # ask_hidden "prompt" -> REPLY_VAL, typed without echo; empty is an answer
    prompt_guard "$1"
    local a
    read -r -s -p "$1: " a || [[ -n "$a" ]] || { echo; die "no answer to '$1': the input ended"; }
    echo; hidden_clean "$a"; REPLY_VAL=$HIDDEN_VAL
}

table_print() { # TSV on stdin, its first line the heading -> columns aligned, two spaces apart
    awk -F'\t' '{ for (i = 1; i <= NF; i++) { c[NR, i] = $i; if (length($i) > w[i]) w[i] = length($i) } n = NR; if (NF > f) f = NF }
        END { for (r = 1; r <= n; r++) { line = ""; for (i = 1; i <= f; i++) line = line sprintf(i < f ? "%-" w[i] + 2 "s" : "%s", c[r, i]); print line } }'
}

confirm() { # confirm "question" -> 0 yes / 1 no
    prompt_guard "$1"
    local ans
    read -r -p "$1 [y/N]: " ans
    [[ "${ans,,}" == y || "${ans,,}" == yes ]]
}

ts_age_hours() { # ts_age_hours YYYYMMDD-HHMMSS[...] -> whole hours since then; rc 1 if unparseable
    local t
    [[ "$1" =~ ^([0-9]{8})-([0-9]{2})([0-9]{2})([0-9]{2}) ]] || return 1
    t=$(date -d "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}:${BASH_REMATCH[3]}:${BASH_REMATCH[4]}" +%s 2>/dev/null) || return 1
    echo $(( ( $(date +%s) - t ) / 3600 ))
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed. Run: ./mediastack.sh install"; }

SYSTEMD_DIR=/etc/systemd/system   # every mediastack unit is SYSTEMD_DIR/mediastack-* (lib/footprint.sh)

# ------------------------------------------------------------- env layer --
# Every root a deployment has, in .env: where each kind of state lives.
# shellcheck disable=SC2034  # read by the entrypoint and lib/doctor.sh
ROOTS=(CONFIG_ROOT DATA_ROOT CACHE_ROOT TRANSCODE_ROOT BACKUP_ROOT)
repo_owned() { # repo_owned <path>... — what the script makes in the repo belongs to the repo's owner
    # The panel and every timer run this script as root; the operator's CLI runs
    # it as themselves. A file or folder a root run created would otherwise lock
    # the operator out of it (a root-owned local/ refuses their overlay, a
    # root-owned local/pins.yml refuses their pin). Root hands it over; a normal
    # user already owns what they create, so this is a no-op for them.
    (( $(id -u) == 0 )) || return 0
    chown "$(stat -c '%u:%g' "$SCRIPT_DIR")" "$@"
}

gen_secret() { # gen_secret N -> N letters and digits from /dev/urandom
    local s=""
    while (( ${#s} < $1 )); do s+=$(head -c 64 /dev/urandom | base64 -w0 | tr -dc 'A-Za-z0-9'); done
    echo "${s:0:$1}"
}

# .env has two readers: compose, with a parser of its own (bare, a $ starts a
# variable, a leading quote quotes, a space at either end is trimmed and a
# ' #' starts a comment), and the script, through env_get. A value either
# reads alike bare, or is written in compose's double-quoted form with \, "
# and $ escaped (\\ \" \$) — that form holds any one-line value, spaces,
# quotes, $ and \ included (proven against compose: scripts/test-secrets.sh).
# env_set writes the quoted form only where the bare one would be misread, so
# an ordinary value stays as it always was; env_get reads both.
env_needs_quotes() { # env_needs_quotes VALUE — rc 0 when its bare form would read differently in compose
    [[ "$1" == *'$'* || "$1" =~ ^[\"\'] || "$1" =~ ^[[:space:]] || "$1" =~ [[:space:]]$ || "$1" =~ [[:space:]]# ]]
}
env_encode() { # env_encode VALUE -> the .env form both readers read as VALUE
    local v=$1
    env_needs_quotes "$v" || { printf '%s\n' "$v"; return 0; }
    v=${v//\\/\\\\}; v=${v//\"/\\\"}; v=${v//\$/\\\$}
    printf '"%s"\n' "$v"
}
env_decode() { # env_decode RAW -> the value a well-formed .env form stands for (env_raw_problem says whether it is)
    local r=$1 out="" i c
    if [[ ${#r} -lt 2 || "$r" != \"*\" ]]; then printf '%s\n' "$r"; return 0; fi
    r=${r:1:${#r}-2}
    for (( i = 0; i < ${#r}; i++ )); do
        c=${r:i:1}
        if [[ "$c" == \\ ]]; then i=$((i + 1)); c=${r:i:1}; fi   # \\ \" \$: the character itself
        out+=$c
    done
    printf '%s\n' "$out"
}
env_raw_problem() { # env_raw_problem KEY RAW [hidden] -> why RAW is no .env form both readers read alike ("" when it is); hidden: a secret, never shown
    local k=$1 r=$2 shown="'$2'" inner i c
    [[ "$r" == [\"\']* ]] && shown=$r   # a quoted value shows as written
    [[ "${3:-}" == hidden ]] && shown="(hidden)"
    case "$r" in
        \'*) echo "$k=$shown is in single quotes, which compose and the script read differently — write it bare, or in double quotes with \\ \" and \$ escaped"; return ;;
        \"*)
            if [[ ${#r} -lt 2 || "$r" != *\" ]]; then
                # a closing quote with text after it (a comment), or none at all
                if [[ "${r:1}" =~ (^|[^\\])(\\\\)*\" ]]; then echo "$k=$shown has text after its closing quote — a comment goes on its own line above"
                else echo "$k=$shown opens a double quote it never closes"; fi
                return
            fi
            inner=${r:1:${#r}-2}
            for (( i = 0; i < ${#inner}; i++ )); do
                c=${inner:i:1}
                if [[ "$c" == \\ ]]; then
                    i=$((i + 1)); c=${inner:i:1}
                    [[ "$c" == \\ || "$c" == \" || "$c" == \$ ]] && continue
                    [[ -z "$c" ]] && { echo "$k=$shown opens a double quote it never closes (its last quote is escaped)"; return; }
                    echo "$k=$shown holds \\$c in double quotes, which compose reads as an escape — write a backslash as \\\\"; return
                elif [[ "$c" == \" ]]; then echo "$k=$shown has a \" inside its quotes — write it as \\\" (or a comment after it goes on its own line above)"; return
                elif [[ "$c" == \$ ]]; then echo "$k=$shown has a \$ inside its quotes, which compose reads as a variable — write it as \\\$"; return
                fi
            done
            return ;;
    esac
    if [[ "$r" == *'$'* ]]; then echo "$k=$shown holds a \$, which compose reads as a variable — write the value in double quotes with \$ escaped: $k=\"…\\\$…\""; return; fi
    if [[ "$r" =~ [[:space:]]# ]]; then echo "$k=$shown has a comment after the value: the script reads it as part of the value. Move the comment to its own line above."; return; fi
    if [[ "$r" =~ ^[[:space:]] || "$r" =~ [[:space:]]$ ]]; then echo "$k=$shown starts or ends with a space, which compose drops and the script keeps — put the value in double quotes"; return; fi
}

# One rule for every secret — a password, key or token, typed, pasted or
# answered: it fits on one line, with no control characters (a newline or a
# tab). Everything else is carried exactly — spaces, quotes, $ and \ through
# the quoted .env form above, and every API call encodes its own (jq --arg,
# --data-urlencode, base64). A limit an app has of its own belongs to that
# app's login (<stem>_logins options, lib/logins.sh), never here.
secret_ok() { # secret_ok VALUE — rc 0 when VALUE passes the rule (empty passes: whether it may be empty is the caller's)
    [[ ! "$1" =~ [[:cntrl:]] ]]
}
SECRET_RULE="one line, with no control characters (a newline or a tab)"
secret_problem() { secret_ok "$1" || echo "$SECRET_RULE"; }   # secret_problem VALUE -> why it cannot be a secret ("" when it can)

# KEY -> what an empty or absent KEY means: the .env schema's default column,
# loaded once per run (env_defaults_load, lib/env.sh) — the only place one is written
declare -gA ENV_DEFAULT=()
env_or_note() { local v; v=$(env_get "$1"); echo "${v:-$2}"; }   # env_or_note <key> <note> — for display: the value, or the note when it has none
uid_max() { # the highest numeric <SVC>_UID in .env; empty when there is none (the callers fall back to UID_BASE)
    # no UID yet is an answer, an unreadable .env a failure: written as a pipe,
    # grep's "no match" ended the run under pipefail before any fallback (Nov 2026)
    local l; l=$(grep -E '_UID=[0-9]+' "$ENV_FILE") || [[ $? == 1 ]] || return 1
    cut -d= -f2 <<<"$l" | sort -n | tail -1
}
env_get() { # env_get <key> -> its .env value; empty or absent: the schema's default (none: empty)
    # one rule for both readers of .env: compose's ${KEY:-x} means the same
    (( $# == 1 )) || die "env_get $1: a default is written in the .env schema (lib/env.schema.tsv, services/*/env.tsv), never at the call"
    local line v
    line=$(grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -n1 || true)
    v=$(env_decode "${line#*=}")   # the value, as compose reads it too (env_encode)
    # printf, not echo: a value such as -n or -e is a value, never an option
    if [[ -n "$line" && -n "$v" ]]; then printf '%s\n' "$v"; else printf '%s\n' "${ENV_DEFAULT[$1]-}"; fi
}

env_del() { sed -i "/^$1=/d" "$ENV_FILE"; } # remove a variable entirely

# Pending work the script tracks for itself (a re-point after a VPN toggle, an
# ownership handover) — not settings, so not in .env: one file per marker in
# local/state/, holding its value. Absent = nothing pending.
state_get() { cat "$STATE_DIR/$1" 2>/dev/null || true; }   # nothing pending reads as empty
state_set() {
    mkdir -p "$STATE_DIR"; repo_owned "$LOCAL_DIR" "$STATE_DIR"
    printf '%s\n' "$2" > "$STATE_DIR/$1"; repo_owned "$STATE_DIR/$1"
}
state_del() { rm -f "$STATE_DIR/$1"; }

env_set() { # env_set VAR value  (idempotent upsert, preserves file order)
    local var="$1" val
    # a newline would end the value and start a line of its own — a key of
    # whoever wrote the value. Every writer checks where it asks; this is the backstop
    [[ ! "$2" =~ [[:cntrl:]] ]] || die "refusing to write $var: a value in .env must be $SECRET_RULE"
    val=$(env_encode "$2")   # quoted only where compose would read it differently
    [[ -e "$ENV_FILE" ]] || { ( umask 077; : > "$ENV_FILE" ); repo_owned "$ENV_FILE"; }
    if grep -qE "^${var}=" "$ENV_FILE"; then
        # sed with | delimiter; escape | and & in value. The script goes in on
        # stdin (-f -): a value is often a secret, and ps shows a command line
        local esc=${val//\\/\\\\}; esc=${esc//|/\\|}; esc=${esc//&/\\&}
        printf 's|^%s=.*|%s=%s|\n' "$var" "$var" "$esc" | sed -i -f - "$ENV_FILE"
    else
        echo "${var}=${val}" >> "$ENV_FILE"
    fi
}

# --------------------------------------------------------------- prompts --
# Interactive questions shared by configure, new-service, traefik-setup and
# wire. Each answer lands in REPLY_VAL.
explain() { echo; hr "$1"; shift; printf '%s\n' "$@"; echo; }

ask_valid() { # ask_valid TYPE VAR "prompt" "default" "what it must be" -> REPLY_VAL, once env_type_ok TYPE accepts it
    # A refused answer is said and asked again — and never becomes the default
    # (found live: "alethio36" refused as an email, then offered as the default,
    # so Enter re-sent it until someone typed the whole address)
    while true; do
        ask "$2" "$3" "$4"
        env_type_ok "$1" "$REPLY_VAL" && return 0
        fail "'$REPLY_VAL' is not $5."
    done
}

# How every question looks (test-prompts.sh holds them to it):
#   a value             Prompt [default]:          no brackets when there is no default
#   one of a few words  Prompt (a/b/c) [default]:  the choices in ( ), the default in [ ]
#   yes or no           Question? [Y/n] / [y/N]:   confirm_yes / confirm — the capital is the default
#   hidden input        Prompt (input hidden):     and "Enter = ..." for what an empty answer does
ask() { # ask VAR "prompt" "default" -> sets REPLY_VAL
    prompt_guard "$2"
    local def="$3" ans hint=""
    [[ -n "$def" ]] && hint=" [$def]"
    # input that has ended is no answer: a question asked again would spin forever.
    # -e: line editing in a terminal (arrows move the cursor, Tab completes a path)
    read -e -r -p "$2$hint: " ans || [[ -n "$ans" ]] || die "no answer to '$2': the input ended"
    REPLY_VAL="${ans:-$def}"
}

ask_token() { # ask_token "prompt" "current" [optional] -> REPLY_VAL; pasted secrets:
    # hidden input, single entry (no typo-confirm — it's pasted), Enter
    # keeps the current value when one exists, skips ("") when optional,
    # and is refused otherwise.
    prompt_guard "$1"
    local a hint=""
    [[ -n "${2:-}" ]] && hint=" [Enter keeps the current one]"
    while true; do
        read -r -s -p "$1${hint}: " a || [[ -n "$a" ]] || { echo; die "no answer to '$1': the input ended"; }; echo
        hidden_clean "$a"; a=$HIDDEN_VAL
        if [[ -z "$a" ]]; then
            [[ -n "${2:-}" ]] && { REPLY_VAL="$2"; info "keeping the current value"; return 0; }
            [[ "${3:-}" == optional ]] && { REPLY_VAL=""; return 0; }
            warn "this value is required — paste it (input hidden)"
            continue
        fi
        REPLY_VAL="$a"; return 0
    done
}

ask_secret_token() { # ask_secret_token "prompt" "current" [optional] -> REPLY_VAL: a pasted secret for .env (ask_token), asked again until it passes the rule
    while true; do
        ask_token "$@"
        secret_ok "$REPLY_VAL" && return 0
        fail "That won't do: a secret must be $SECRET_RULE."
        set -- "$1" "" "${3:-}"   # Enter must not keep a refused value
    done
}

ask_secret() { # ask_secret "prompt" "generated-default" -> REPLY_VAL
    # Never echoes. Enter accepts the generated default (view: credentials);
    # a typed password must be entered twice to guard against blind typos.
    prompt_guard "$1"
    local a b
    while true; do
        # IFS=: a space typed at either end is kept, and refused, never trimmed unseen
        IFS= read -r -s -p "$1 [Enter = accept a generated one]: " a || [[ -n "$a" ]] || { echo; die "no answer to '$1': the input ended"; }; echo
        if [[ -z "$a" ]]; then
            REPLY_VAL="$2"
            info "using a generated password — view any time: ./mediastack.sh credentials"
            return 0
        fi
        IFS= read -r -s -p "Confirm password: " b || [[ -n "$b" ]] || { echo; die "no answer to 'Confirm password': the input ended"; }; echo
        [[ "$a" == "$b" ]] || { fail "Passwords do not match — try again."; continue; }
        secret_ok "$a" || { fail "That password won't do: $SECRET_RULE."; continue; }
        REPLY_VAL="$a"; return 0
    done
}

ask_time() { # ask_time [DEFAULT] — 24h HH:MM prompt with validation -> REPLY_VAL
    while true; do
        ask UPD_TIME "Time (24h, HH:MM)" "${1:-04:00}"
        [[ "$REPLY_VAL" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] && return 0
        fail "'$REPLY_VAL' is not a valid HH:MM time (e.g. 04:00, 23:30)."
    done
}

sched_time_after() { # sched_time_after EXPR -> HH:MM one hour after EXPR's time (04:00 when EXPR has none)
    local h m
    [[ "$1" =~ ([0-9]{1,2}):([0-9]{2})(:[0-9]{2})?$ ]] || { echo 04:00; return 0; }
    h=$(( (10#${BASH_REMATCH[1]} + 1) % 24 )); m=${BASH_REMATCH[2]}
    printf '%02d:%s\n' "$h" "$m"
}
sched_words() { # sched_words EXPR -> the wizard's words for it ("never" when empty)
    case "$1" in
        "")                  echo never ;;
        "*-*-* "*)           echo "daily ${1#"*-*-* "}" ;;
        "Mon..Fri "*)        echo "weekdays ${1#Mon..Fri }" ;;
        "Sat,Sun "*)         echo "weekends ${1#Sat,Sun }" ;;
        *)                   echo "$1" ;;
    esac
}

# ------------------------------------------------------------ filesystem --
abspath() { case "$1" in /*) echo "$1" ;; *) echo "$SCRIPT_DIR/${1#./}" ;; esac; }
# scurl: curl with what it carries off its command line, which ps shows any
# user on the host — the headers (keys, tokens), the login, the body, the
# cookie and the URL (some carry a key: ?apikey=, a webhook's token) go into a
# config read through a pipe; only the timing and output options stay. Takes
# curl's own options; one it does not know is refused (a valued one would
# take the next argument for a URL). Inside a container (another curl, not
# the host's), a line may run curl itself, marked: # curl-ok: <why>
scurl() {
    local cfg="" a v
    local -a keep=()
    while (( $# )); do
        a=$1; shift
        case "$a" in
            -H|--header|-u|--user|-d|--data|--data-raw|--data-binary|--data-urlencode|-b|--cookie)
                (( $# )) || die "scurl: $a needs a value"
                case "$a" in -H) a=header ;; -u) a=user ;; -d) a=data ;; -b) a=cookie ;; *) a=${a#--} ;; esac
                # curl's config: a quoted value takes \\ \" \t \n \r as escapes
                v=${1//\\/\\\\}; v=${v//\"/\\\"}; v=${v//$'\t'/\\t}; v=${v//$'\n'/\\n}; v=${v//$'\r'/\\r}
                cfg+="$a = \"$v\""$'\n'; shift ;;
            -m|--max-time|--connect-timeout|-X|--request|-o|--output|-w|--write-out|-c|--cookie-jar|-D|--dump-header)
                (( $# )) || die "scurl: $a needs a value"
                keep+=("$a" "$1"); shift ;;
            -*)
                [[ "$a" =~ ^-[sSfL46]+$ || "$a" =~ ^--(silent|show-error|fail|location|ipv4|ipv6)$ ]] \
                    || die "scurl: '$a' is not an option it knows — add it to scurl (lib/common.sh), with a value or without"
                keep+=("$a") ;;
            *)
                v=${a//\\/\\\\}; v=${v//\"/\\\"}
                cfg+="url = \"$v\""$'\n' ;;
        esac
    done
    command curl -K <(printf '%s' "$cfg") "${keep[@]}"   # curl-ok: scurl itself
}

# A root is deleted whole by nuke (CONFIG/CACHE/TRANSCODE) or uninstall (CONFIG):
# never a system or shared folder, the home folder, or one holding this repo.
ROOT_SHARED=(/ /bin /boot /dev /etc /home /lib /lib32 /lib64 /media /mnt /opt /proc /root /run /sbin /srv /sys /tmp /usr /var)
root_unsafe() { # root_unsafe PATH -> why PATH can never be a mediastack root ("" when it can)
    local p s; p=$(realpath -m -- "$(abspath "$1")")
    for s in "${ROOT_SHARED[@]}"; do
        [[ "$p" == "$s" ]] && { echo "'$p' is a system or shared folder — mediastack's roots are its own (nuke deletes them whole): give it a folder of its own"; return 0; }
    done
    [[ -n "${HOME:-}" && "$p" == "$(realpath -m -- "$HOME")" ]] && { echo "'$p' is your home folder — mediastack's roots are its own (nuke deletes them whole): give it a folder of its own"; return 0; }
    local repo; repo=$(realpath -m -- "$SCRIPT_DIR")   # paths compared resolved: a symlinked checkout is still the repo
    [[ "$repo/" == "$p/"* ]] && { echo "'$p' holds this repo folder ($repo) — nuke would delete the repo with it: give it a folder of its own"; return 0; }
    return 0
}
fstype_of() { findmnt -rn -o FSTYPE --target "$1" 2>/dev/null || echo unknown; }
fsdev_of()  { stat -c %d "$1" 2>/dev/null || echo 0; }
fs_source_of() { # the device behind a path; a btrfs subvolume ("/dev/sda2[/@x]") counts as its filesystem
    local src; src=$(timeout 5 findmnt -rn -o SOURCE --target "$1" 2>/dev/null | sed -n 1p) || true
    echo "${src%%\[*}"
}
fs_shared() { # fs_shared PATH PATH -> the source both live on (exit 1 when they differ or either is unknown)
    local a b; a=$(fs_source_of "$1"); b=$(fs_source_of "$2")
    [[ -n "$a" && "$a" == "$b" ]] && echo "$a"
}
