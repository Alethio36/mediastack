#!/usr/bin/env bash
# lib/common.sh — shared base for mediastack.sh and its libraries: terminal
# colours, output primitives, and .env access. Sourced first by the entrypoint
# (after SCRIPT_DIR and ENV_FILE are set); not executed directly.

# ------------------------------------------------------------------ output --
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

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed. Run: ./mediastack.sh install"; }

# --------------------------------------------------------------- env layer --
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
