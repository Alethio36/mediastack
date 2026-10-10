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
ROLES=(download-client)
ROLE_CONSUMERS=(arr prowlarr cleanuparr)

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

role_env_names() { # role_env_names PROVIDER ROLE CONSUMER -> the .env settings its template reads
    grep -oE '\{env\.[A-Z0-9_]+\}' "$(role_file "$@")" | sed -E 's/\{env\.([A-Z0-9_]+)\}/\1/' | sort -u
}

role_env_missing() { # role_env_missing PROVIDER ROLE CONSUMER -> the settings it needs that .env leaves empty
    local v; for v in $(role_env_names "$@"); do [[ -n "$(env_get "$v")" ]] || echo "$v"; done
}

role_entry() { # role_entry PROVIDER ROLE CONSUMER -> the template, resolved (JSON); dies on an unknown placeholder
    local p="$1" f env="{}" v bad
    [[ " ${ROLES[*]} " == *" $2 "* ]] || die "role: unknown role '$2' (roles: ${ROLES[*]})"
    [[ " ${ROLE_CONSUMERS[*]} " == *" $3 "* ]] || die "role: unknown consumer '$3' (consumers: ${ROLE_CONSUMERS[*]})"
    f=$(role_file "$@")
    [[ -r "$f" ]] || die "role: $p ships no $2 template for $3 ($f)"
    jq -e . "$f" >/dev/null 2>&1 || die "role: $f is not valid JSON"
    # the template's own placeholders, checked before anything is filled in (a
    # value from .env is never read as one)
    bad=$(grep -oE '\{[^{}" ]+\}' "$f" | grep -vxE '\{self\.(host|port|addr)\}|\{env\.[A-Z0-9_]+\}' | sort -u | paste -sd' ' -)
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
