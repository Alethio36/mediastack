#!/usr/bin/env bash
# lib/logins.sh — the stack's own logins (docs/design-install.md, "The
# stack's own logins"): the download clients', the arrs', Jellyfin's admin,
# the roots of Audiobookshelf and Kavita, the dashboard's. One username for
# all (STACK_USER), the passwords generated, unified or typed for each
# (STACK_LOGINS). Each login is declared by the service that owns it — a
# `<stem>_logins` function in its folder; the stem is the service's name, or
# its mediastack.logins label when several share one login (the arrs) —
# printing one TSV line per login:
#   title  USER_KEY|-  PASS_KEY  [reserve] [pw_max=N] [user_min=N] [user_re=ERE]
# `reserve`: a person joining the portal under this name could be taken for
# the account (authentik refuses it at sign-up). The questionnaire asks;
# logins_fill records what is missing without asking (up, enable). Sourced
# by the entrypoint; relies on lib/common.sh and the service helpers.

LOGIN_PW_MIN=12                  # a typed password: at least this long
LOGIN_FORBIDDEN='[[:space:]$"'"'"'\\`]'   # whitespace and $ " ' \ ` break .env and compose's interpolation
LOGIN_USER_RE='^[A-Za-z0-9._-]+$'         # the one username: what every login accepts

logins_list() { # the enabled services' logins, one TSV line each, a shared one once
    local s stem f
    local -A seen=()
    for s in $(svc_enabled_managed); do
        stem=$(svc_label "$s" mediastack.logins); stem=${stem:-$s}
        [[ -z "${seen[$stem]:-}" ]] || continue; seen[$stem]=1
        f="${stem//-/_}_logins"
        if declare -F "$f" >/dev/null; then "$f"; fi
    done
}

login_opt() { # login_opt "LINE" NAME -> the value of NAME=... in its options ("" when absent); NAME alone: "yes" when present
    local o
    for o in $(cut -f4- <<<"$1" | tr '\t' ' '); do
        [[ "$o" == "$2" ]] && { echo yes; return 0; }
        [[ "$o" == "$2="* ]] && { echo "${o#*=}"; return 0; }
    done
}

login_user_problem() { # login_user_problem NAME -> why NAME cannot be the stack's username ("" when it can)
    local n=$1 l m re
    [[ "$n" =~ $LOGIN_USER_RE ]] || { echo "use letters, digits and . _ - only"; return 0; }
    while IFS= read -r l; do
        [[ -n "$l" && "$(cut -f2 <<<"$l")" != - ]] || continue
        m=$(login_opt "$l" user_min); re=$(login_opt "$l" user_re)
        if [[ -n "$m" ]] && (( ${#n} < m )); then echo "$(cut -f1 <<<"$l") needs at least $m characters"; return 0; fi
        if [[ -n "$re" && ! "$n" =~ $re ]]; then echo "$(cut -f1 <<<"$l") refuses that name"; return 0; fi
    done < <(logins_list)
}

login_pass_problem() { # login_pass_problem PASS [PASS_KEY] -> why PASS cannot be that login's (every login's without one); "" when it can
    local p=$1 key=${2:-} l m
    (( ${#p} >= LOGIN_PW_MIN )) || { echo "at least $LOGIN_PW_MIN characters"; return 0; }
    [[ ! "$p" =~ $LOGIN_FORBIDDEN ]] || { echo "no spaces, and none of \$ \" ' \\ or the backtick — .env and compose cannot hold them safely"; return 0; }
    while IFS= read -r l; do
        [[ -n "$l" ]] || continue
        [[ -z "$key" || "$(cut -f3 <<<"$l")" == "$key" ]] || continue
        m=$(login_opt "$l" pw_max)
        if [[ -n "$m" ]] && (( ${#p} > m )); then echo "$(cut -f1 <<<"$l") takes at most $m characters"; return 0; fi
    done < <(logins_list)
}

login_pass_ask() { # login_pass_ask PROMPT [PASS_KEY] -> REPLY_VAL: typed twice and passing the rules (that login's, or every one's); Enter: generated
    local why
    while true; do
        ask_secret "$1" "$(login_generate)"
        why=$(login_pass_problem "$REPLY_VAL" "${2:-}")
        [[ -n "$why" ]] || return 0
        fail "That password won't do: $why."
    done
}

login_generate() { gen_secret 16; }   # exactly 16 letters and digits: passes every rule

login_missing() { # the logins whose username or password is not recorded yet, as logins_list prints them
    local l uk pk
    while IFS= read -r l; do
        [[ -n "$l" ]] || continue
        uk=$(cut -f2 <<<"$l"); pk=$(cut -f3 <<<"$l")
        if [[ -z "$(env_get "$pk")" ]] || [[ "$uk" != - && -z "$(env_get "$uk")" ]]; then echo "$l"; fi
    done < <(logins_list)
}

login_unified_password() { # the one password a unified stack shares ("" when no login is set yet); rc 2 when the set ones differ
    local l p
    local -A seen=()
    while IFS= read -r l; do
        [[ -n "$l" ]] || continue
        p=$(env_get "$(cut -f3 <<<"$l")")
        if [[ -n "$p" ]]; then seen[$p]=1; fi
    done < <(logins_list)
    (( ${#seen[@]} <= 1 )) || return 2
    for p in "${!seen[@]}"; do echo "$p"; done
}

login_record() { # login_record "LINE" PASS — the stack's username (where the login has one) and PASS, written where they are empty
    local uk pk
    uk=$(cut -f2 <<<"$1"); pk=$(cut -f3 <<<"$1")
    [[ "$uk" == - || -n "$(env_get "$uk")" ]] || env_set "$uk" "$(env_get STACK_USER)"
    [[ -n "$(env_get "$pk")" ]] || env_set "$pk" "$2"
}

logins_fill() { # the missing logins, recorded without asking (up, enable): generated, or unified with the shared password
    local l pw mode; mode=$(env_get STACK_LOGINS)
    while IFS= read -r l; do
        [[ -n "$l" ]] || continue
        case "$mode" in
            generated) pw=$(login_generate) ;;
            unified)   pw=$(login_unified_password) \
                           || die "$(cut -f1 <<<"$l") has no login yet, and the logins' passwords differ, so there is no one password to share — make them one: ./mediastack.sh set-credentials all"
                       [[ -n "$pw" ]] || die "$(cut -f1 <<<"$l"): no login is set yet to share the unified password with — run: ./mediastack.sh configure" ;;
            *)         die "$(cut -f1 <<<"$l") has no login yet and STACK_LOGINS=each types every one — run: ./mediastack.sh configure" ;;
        esac
        login_record "$l" "$pw"
        info "$(cut -f1 <<<"$l"): login recorded (see: ./mediastack.sh credentials)"
    done < <(login_missing)
}

logins_reserved() { # the names a person may not join the portal under: the logins marked reserve, comma-separated
    local l uk n
    while IFS= read -r l; do
        [[ -n "$l" && -n "$(login_opt "$l" reserve)" ]] || continue
        uk=$(cut -f2 <<<"$l"); [[ "$uk" != - ]] || continue
        n=$(env_get "$uk")
        if [[ -n "$n" ]]; then echo "$n"; fi
    done < <(logins_list) | sort -u | paste -sd, -
}
