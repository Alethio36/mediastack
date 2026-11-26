#!/usr/bin/env bash
# lib/roles.sh — wiring by role. A provider ships, per consumer type, how that
# consumer reaches it: services/<provider>/provides/<role>.<consumer>.json.
# A template is data and {placeholders} only — anything that needs a decision
# is code in the provider's or the consumer's folder. The consumer's code is
# written once against the role, so a new provider is a new folder.
# Sourced by the entrypoint; relies on lib/common.sh, lib/addr.sh and the
# svc_* helpers at call time.
#
# Placeholders (the whole vocabulary — anything else fails loud):
#   {self.host} {self.port} {self.addr}   how the consumer reaches the provider
#                                         (VPN-aware: svc_host / svc_cport / svc_addr);
#                                         a value that is exactly "{self.port}" becomes a number
#   {env.NAME}                            a setting from .env
ROLES=(download-client live-tv)
# each role's consumers: the apps that hold an entry for its provider — each a
# wire role, which re-points its entries when a VPN toggle moves the provider
declare -A ROLE_CONSUMERS=([download-client]="arr prowlarr cleanuparr" [live-tv]="jellyfin")
# the .env setting naming the provider the stack uses when several are enabled
# (empty: the first in priority order); the others' entries are switched off.
# A role without one always takes the first in priority order.
declare -A ROLE_SETTING=([download-client]=DOWNLOAD_CLIENT)

role_consumers() { echo "${ROLE_CONSUMERS[$1]:-}"; }                       # role_consumers ROLE -> its consumers
role_consumer_first() { local c; c=$(role_consumers "$1"); echo "${c%% *}"; }   # the one whose templates say which providers exist

role_file() { echo "services/$1/provides/$2.$3.json"; }   # role_file PROVIDER ROLE CONSUMER

role_providers() { # role_providers ROLE CONSUMER -> enabled providers with a template for it, by .priority (then name)
    local f p
    for f in services/*/provides/"$1.$2".json; do
        [[ -e "$f" ]] || continue
        p=${f#services/}; p=${p%%/*}
        svc_enabled "$p" || continue
        printf '%s\t%s\n' "$(jq -r '.priority // 50' "$f")" "$p"
    done | sort -n -k1,1 -k2,2 | cut -f2
}

role_all_providers() { # role_all_providers ROLE CONSUMER -> every provider shipping a template for it, enabled or not
    local f p
    for f in services/*/provides/"$1.$2".json; do
        [[ -e "$f" ]] || continue
        p=${f#services/}; echo "${p%%/*}"
    done
}

role_pick() { # role_pick ROLE -> the one provider the stack uses ("" when none is enabled); dies on a setting it cannot honour
    local var="${ROLE_SETTING[$1]:-}" want="" enabled
    if [[ -n "$var" ]]; then want=$(env_get "$var"); fi
    enabled=$(role_providers "$1" "$(role_consumer_first "$1")")
    if [[ -n "$want" ]]; then
        grep -qx "$want" <<<"$enabled" \
            || die "$var=$want, but $want is not an enabled $1 (enabled: ${enabled//$'\n'/ }) — enable it, or change it: ./mediastack.sh configure"
        echo "$want"
    else
        head -1 <<<"$enabled"
    fi
}

role_pick_note() { # role_pick_note ROLE -> one line naming the choice, when there is one to make
    local chosen others
    chosen=$(role_pick "$1")
    others=$(role_providers "$1" "$(role_consumer_first "$1")" | { grep -vx "$chosen" || true; } | paste -sd' ' -)   # none left is no error
    [[ -n "$others" ]] || return 0
    if [[ -n "${ROLE_SETTING[$1]:-}" ]]; then info "$1: $chosen (also enabled: $others) — change: ./mediastack.sh configure, then: ./mediastack.sh wire"
    else info "$1: $chosen (also enabled: $others — the first in priority order is the one wired)"; fi
}

role_entry_name() { # role_entry_name PROVIDER ROLE CONSUMER -> the name its entry carries in the consumer (no resolving needed)
    jq -r '.name' "$(role_file "$@")"
}

role_env_names() { # role_env_names PROVIDER ROLE CONSUMER -> the .env settings its template reads
    { grep -oE '\{env\.[A-Z0-9_]+\}' "$(role_file "$@")" || true; } | sed -E 's/\{env\.([A-Z0-9_]+)\}/\1/' | sort -u   # none is no error
}

role_env_missing() { # role_env_missing PROVIDER ROLE CONSUMER -> the settings it needs that .env leaves empty
    local v; for v in $(role_env_names "$@"); do [[ -n "$(env_get "$v")" ]] || echo "$v"; done
}

role_entry() { # role_entry PROVIDER ROLE CONSUMER -> the template, resolved (JSON); dies on an unknown placeholder
    local p="$1" f env="{}" v bad
    [[ " ${ROLES[*]} " == *" $2 "* ]] || die "role: unknown role '$2' (roles: ${ROLES[*]})"
    [[ " $(role_consumers "$2") " == *" $3 "* ]] || die "role: $3 is no consumer of $2 (its consumers: $(role_consumers "$2"))"
    f=$(role_file "$@")
    [[ -r "$f" ]] || die "role: $p ships no $2 template for $3 ($f)"
    jq -e . "$f" >/dev/null 2>&1 || die "role: $f is not valid JSON"
    # the template's own placeholders, checked before anything is filled in (a
    # value from .env is never read as one)
    bad=$({ grep -oE '\{[^{}" ]+\}' "$f" || true; } | { grep -vxE '\{self\.(host|port|addr)\}|\{env\.[A-Z0-9_]+\}' || true; } | sort -u | paste -sd' ' -)   # none is no error
    [[ -z "$bad" ]] || die "role: $f uses placeholders that do not exist: $bad"
    for v in $(role_env_names "$@"); do env=$(jq -c --arg k "$v" --arg val "$(env_get "$v")" '. + {($k): $val}' <<<"$env"); done
    jq -c --arg host "$(svc_host "$p")" --arg addr "$(svc_addr "$p")" --argjson port "$(svc_cport "$p")" --argjson env "$env" '
        ({host: $host, addr: $addr, port: ($port | tostring)}) as $self
        | walk(if type == "string" then
                   if . == "{self.port}" then $port
                   else gsub("\\{self\\.(?<k>host|addr|port)\\}"; $self[.k]) | gsub("\\{env\\.(?<k>[A-Z0-9_]+)\\}"; $env[.k])
                   end
               else . end)' "$f"
}

role_login_fields() { # role_login_fields LIST-JSON ENTRY-NAME ENTRY-JSON -> field=value lines to re-send on a re-point
    # an entry that authenticates by API key takes no username/password (the
    # arrs and Prowlarr reject both at once); otherwise the template's own login
    [[ -n "$(arr_entry_field "$1" "$2" apiKey)" ]] && return 0
    jq -r '.fields | to_entries[] | select(.key == "username" or .key == "password") | "\(.key)=\(.value)"' <<<"$3"
}

dl_login_follow() { # dl_login_follow PROVIDER — after a download client's login changed (set-credentials): every copy of it follows —
    # the arr family's entries (by mediastack's own entry name), then each enabled
    # service's <svc>_dl_login_resync PROVIDER, found by its name (Cleanuparr, LazyLibrarian)
    local s
    arr_dl_login_resync "$1"
    for s in $(svc_enabled_managed); do
        if declare -F "${s//-/_}_dl_login_resync" >/dev/null; then "${s//-/_}_dl_login_resync" "$1"; fi
    done
    return 0
}
