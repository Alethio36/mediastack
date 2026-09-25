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

confirm() { # confirm "question" -> 0 yes / 1 no
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

# ------------------------------------------------------------- env layer --
# Every root a deployment has, in .env: where each kind of state lives.
# shellcheck disable=SC2034  # read by the entrypoint and lib/doctor.sh
ROOTS=(CONFIG_ROOT DATA_ROOT CACHE_ROOT TRANSCODE_ROOT BACKUP_ROOT)
env_get() { # env_get VAR [default]
    local line
    line=$(grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -n1 || true)
    if [[ -n "$line" ]]; then echo "${line#*=}"; else echo "${2-}"; fi
}

env_del() { sed -i "/^$1=/d" "$ENV_FILE"; } # remove a variable entirely

env_set() { # env_set VAR value  (idempotent upsert, preserves file order)
    local var="$1" val="$2"
    touch "$ENV_FILE"
    if grep -qE "^${var}=" "$ENV_FILE"; then
        # sed with | delimiter; escape | and & in value
        local esc=${val//\\/\\\\}; esc=${esc//|/\\|}; esc=${esc//&/\\&}
        sed -i "s|^${var}=.*|${var}=${esc}|" "$ENV_FILE"
    else
        echo "${var}=${val}" >> "$ENV_FILE"
    fi
}

# --------------------------------------------------------------- prompts --
# Interactive questions shared by configure, new-service, traefik-setup and
# wire. Each answer lands in REPLY_VAL.
explain() { echo; hr "$1"; shift; printf '%s\n' "$@"; echo; }

ask() { # ask VAR "prompt" "default" -> sets REPLY_VAL
    local def="$3" ans
    read -r -p "$2 [${def}]: " ans
    REPLY_VAL="${ans:-$def}"
}

ask_token() { # ask_token "prompt" "current" -> REPLY_VAL; pasted secrets:
    # hidden input, single entry (no typo-confirm — it's pasted), Enter
    # keeps the current value when one exists, empty is refused otherwise.
    local a hint=""
    [[ -n "${2:-}" ]] && hint=" [Enter keeps the current one]"
    while true; do
        read -r -s -p "$1${hint}: " a; echo
        if [[ -z "$a" ]]; then
            [[ -n "${2:-}" ]] && { REPLY_VAL="$2"; info "keeping the current value"; return 0; }
            warn "this value is required — paste it (input is hidden)"
            continue
        fi
        REPLY_VAL="$a"; return 0
    done
}

ask_secret() { # ask_secret "prompt" "generated-default" -> REPLY_VAL
    # Never echoes. Enter accepts the generated default (view: credentials);
    # a typed password must be entered twice to guard against blind typos.
    local a b
    while true; do
        read -r -s -p "$1 [Enter = accept a generated one]: " a; echo
        if [[ -z "$a" ]]; then
            REPLY_VAL="$2"
            info "using a generated password — view any time: ./mediastack.sh credentials"
            return 0
        fi
        read -r -s -p "Confirm password: " b; echo
        [[ "$a" == "$b" ]] && { REPLY_VAL="$a"; return 0; }
        fail "Passwords do not match — try again."
    done
}

ask_time() { # 24h HH:MM prompt with validation -> REPLY_VAL
    while true; do
        ask UPD_TIME "Time (24h, HH:MM)" "04:00"
        [[ "$REPLY_VAL" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] && return 0
        fail "'$REPLY_VAL' is not a valid HH:MM time (e.g. 04:00, 23:30)."
    done
}


# ------------------------------------------------------------ filesystem --
abspath() { case "$1" in /*) echo "$1" ;; *) echo "$SCRIPT_DIR/${1#./}" ;; esac; }
fstype_of() { findmnt -rn -o FSTYPE --target "$1" 2>/dev/null || echo unknown; }
fsdev_of()  { stat -c %d "$1" 2>/dev/null || echo 0; }
