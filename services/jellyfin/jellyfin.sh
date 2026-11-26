#!/usr/bin/env bash
# services/jellyfin/jellyfin.sh — Jellyfin's API client, plugins (LDAP
# sign-in), its question (the server name), transcode path and its `wire
# jellyfin` role.
# Sourced by the entrypoint; relies on lib/wire.sh, lib/addr.sh and the
# entrypoint's helpers at call time.

JF_LDAP_GUID=958aad66-3784-4d2a-b89a-a7b6fab6e25c           # "LDAP Authentication" (jellyfin/jellyfin-plugin-ldapauth)
JF_LDAP_PROVIDER=Jellyfin.Plugin.LDAP_Auth.LdapAuthenticationProviderPlugin   # AuthenticationProviderId of users it created

jf_plugin_ids() { # jf_plugin_ids PLUGINS-JSON -> "|id|id|" (dashes removed, lower case)
    # by ID, not name: a plugin can load under another name than its catalog
    # entry (found live: "LDAP Authentication" loads as "LDAP-Auth")
    # not JSON (a startup page) is no plugin seen: the caller FAILs what it misses
    jq -r '"|" + ([.[].Id | ascii_downcase | gsub("-"; "")] | join("|")) + "|"' <<<"$1" 2>/dev/null || echo "||"
}
jf_guid() { tr -d '-' <<<"$1" | tr '[:upper:]' '[:lower:]'; }

jf_repo_reach() { # jf_repo_reach URL -> "" when Jellyfin itself reaches it; else what stopped it (asked from inside its container)
    local out code msg
    out=$(sudo docker exec "$(svc_cname jellyfin)" curl -sS -m 10 -o /dev/null -w '\n%{http_code}' "$1" 2>&1) || true   # curl-ok: inside a container
    code=${out##*$'\n'}; msg=${out%$'\n'*}; [[ "$out" == *$'\n'* ]] || msg=""
    [[ "$code" =~ ^[23][0-9][0-9]$ ]] && return 0
    if [[ -n "$msg" ]]; then oneline "$msg"; else echo "HTTP ${code:-none}"; fi
}

jf_catalog_reason() { # jf_catalog_reason TOKEN -> why Jellyfin has nothing to install (", <reason>"), or "" when its catalog is not empty
    # Jellyfin answers 404 to an install when its catalog is empty, and it is
    # empty when it cannot reach its repository (found live, Oct 2026: a
    # network block refused repo.jellyfin.org) — say that, not just "404"
    local pk n repos url why=""
    pk=$(jf_api GET /Packages "$1" 2>/dev/null) || return 0
    n=$(jq 'length' <<<"$pk" 2>/dev/null || echo "?")
    [[ "$n" == 0 ]] || return 0
    repos=$(jf_api GET /Repositories "$1" 2>/dev/null) || { echo ", Jellyfin's plugin catalog is empty"; return 0; }
    while IFS= read -r url; do
        [[ -n "$url" ]] || continue
        local r; r=$(jf_repo_reach "$url")
        [[ -n "$r" ]] && why+="$url: $r; "
    done < <(jq -r '.[] | select(.Enabled) | .Url' <<<"$repos" 2>/dev/null)
    if [[ -n "$why" ]]; then echo ", Jellyfin's plugin catalog is empty — Jellyfin cannot reach its repository (${why%; }); something on this network blocks it"
    else echo ", Jellyfin's plugin catalog is empty (its repository answers now — retry)"; fi
}

# Jellyfin reads its plugins and its network settings only at start. Each step
# that changes one queues it (JF_RESTART_FOR), and wire restarts it once for all
# of them, then reads each back (jf_restart_pending): a first wire used to
# restart it up to three times — its proxies, the Webhook plugin, the LDAP
# plugin — each with its own notice to the household (the audit, 26 Nov 2026).
JF_RESTART_FOR=()      # what this run changed that Jellyfin reads at start
JF_PLUGINS_LOADED=()   # "Name|GUID" installed this run: checked loaded after the restart
JF_PROXIES_CHANGED=""  # its Known proxies written this run: read back after the restart
jf_plugins_ensure() { # jf_plugins_ensure TOKEN "Name|GUID|why"... — install what is missing; its restart is jf_restart_pending's
    local tok="$1"; shift
    local plist plugins spec name guid why missing=() mguids=()
    plist=$(jf_api GET /Plugins "$tok") \
        || { wfail "could not list jellyfin plugins [HTTP $(jf_code)] — nothing installed, jellyfin not restarted"; return 1; }
    plugins=$(jf_plugin_ids "$plist")
    for spec in "$@"; do
        IFS='|' read -r name guid why <<<"$spec"
        if [[ "$plugins" == *"|$(jf_guid "$guid")|"* ]]; then ok "$name plugin installed"; continue; fi
        w_would "install Jellyfin's $name plugin ($why)" || continue
        if ! jf_api POST "/Packages/Installed/$(jq -rn --arg n "$name" '$n|@uri')?assemblyGuid=$guid" "$tok" >/dev/null; then
            local code; code=$(jf_code)
            wfail "$name plugin install rejected [HTTP $code]$(jf_catalog_reason "$tok") — then: ./mediastack.sh wire jellyfin"; return 1
        fi
        missing+=("$name"); mguids+=("$guid")
    done
    (( ${#missing[@]} )) || return 0
    info "plugin(s) downloaded (${missing[*]}) — they load at jellyfin's restart, below"
    JF_RESTART_FOR+=("plugins (${missing[*]})")
    for i in "${!missing[@]}"; do JF_PLUGINS_LOADED+=("${missing[$i]}|${mguids[$i]}"); done
}

jf_restart_pending() { # jf_restart_pending TOKEN — one restart for all this run changed that Jellyfin reads at start, then each read back
    local tok="$1" plist plugins spec name guid rc=0
    (( ${#JF_RESTART_FOR[@]} )) || return 0
    info "jellyfin reads $(printf '%s, ' "${JF_RESTART_FOR[@]}" | sed 's/, $//') at start — restarting it once..."
    JF_RESTART_FOR=()
    is_user_facing jellyfin && notify_interruption "Jellyfin maintenance" "Jellyfin is restarting briefly for maintenance — back in a moment."
    DC restart jellyfin >/dev/null 2>&1 || { wfail "jellyfin restart failed — restart it, then re-run wire jellyfin"; return 1; }
    jf_ready || return 1
    if (( ${#JF_PLUGINS_LOADED[@]} )); then
        plist=$(jf_api GET /Plugins "$tok" || true)   # soft read: re-check after the install: empty FAILs below
        plugins=$(jf_plugin_ids "$plist")
        for spec in "${JF_PLUGINS_LOADED[@]}"; do
            name=${spec%%|*}; guid=${spec#*|}
            if [[ "$plugins" == *"|$(jf_guid "$guid")|"* ]]; then ok "$name plugin installed and loaded"
            else wfail "$name plugin not visible after restart — check Dashboard -> Plugins (a repository fetch may have failed)"; rc=1; fi
        done
        JF_PLUGINS_LOADED=()
    fi
    if [[ -n "$JF_PROXIES_CHANGED" ]]; then JF_PROXIES_CHANGED=""; JF_AFTER_RESTART=1 jf_known_proxies "$tok"; fi
    return $rc
}

jf_plugins_wanted() { # the plugins this stack's Jellyfin needs, installed together (loaded by one restart, jf_restart_pending's)
    local specs=()
    # Webhook: its only consumer is WatchState (the hub hears Seerr, not Jellyfin)
    if svc_enabled watchstate; then specs+=("Webhook|71552A5A-5C5C-4350-A2AE-EBE451A30173|WatchState's webhooks need it"); fi
    if signin_is authentik && [[ -n "$(env_get AUTHENTIK_LDAP_TOKEN)" ]]; then specs+=("LDAP Authentication|$JF_LDAP_GUID|portal accounts sign in to Jellyfin"); fi
    (( ${#specs[@]} )) || return 0
    jf_plugins_ensure "$1" "${specs[@]}" || true   # a failure is reported by it
}


jf_ldap_want() { # the LDAP plugin's settings mediastack manages, as JSON (the rest stay yours)
    local dn=dc=ldap,dc=mediastack host skip=false groups
    host="$(env_get AUTHENTIK_LDAP_HOST).$(env_get STACK_DOMAIN)"
    # a staging certificate is not trusted inside Jellyfin: checking waits for a trusted one
    certs_trusted || skip=true
    # who may open Jellyfin (decision 11): admins, those granted it, and the
    # household while its tier is frontend — the LDAP application's
    # bindings say the same (ak_ldap_rule)
    groups="$PORTAL_ADMIN app-jellyfin"
    [[ "$(svc_tier jellyfin)" == frontend ]] && groups="$PORTAL_FRONTEND $groups"
    jq -cn --arg host "$host" --arg dn "$dn" --arg pw "$(env_get AUTHENTIK_LDAP_BIND_PASSWORD)" --argjson skip "$skip" \
        --arg groups "$groups" --arg ad "$PORTAL_ADMIN" '{
        LdapServer: $host, LdapPort: 443, UseSsl: true, UseStartTls: false, SkipSslVerify: $skip,
        LdapBindUser: ("cn=mediastack-ldap-search,ou=users," + $dn), LdapBindPassword: $pw,
        LdapBaseDn: $dn, LdapAdminBaseDn: $dn,
        LdapSearchFilter: ("(|" + ([$groups | split(" ")[] | "(memberOf=cn=" + . + ",ou=groups," + $dn + ")"] | join("")) + ")"),
        LdapAdminFilter: ("(memberOf=cn=" + $ad + ",ou=groups," + $dn + ")"),
        LdapSearchAttributes: "uid, cn, mail, displayName", LdapUidAttribute: "uid", LdapUsernameAttribute: "cn",
        CreateUsersFromLdap: true, EnableAllFolders: true, AllowPassChange: false }'
}

jf_ldap_configure() { # point the LDAP plugin at authentik's outpost — only the settings mediastack manages
    local tok="$1" cur want merged
    cur=$(jf_api GET "/Plugins/$JF_LDAP_GUID/Configuration" "$tok") \
        || { wfail "could not read the LDAP plugin's settings [HTTP $(jf_code)]"; return 1; }
    want=$(jf_ldap_want)
    if jq -e --argjson w "$want" '. as $c | $w | to_entries | all(.value == $c[.key])' <<<"$cur" >/dev/null 2>&1; then
        ok "LDAP plugin points at the portal ($(jq -r '.LdapServer' <<<"$want"), certificate checking $( [[ "$(jq -r '.SkipSslVerify' <<<"$want")" == true ]] && echo "off until production certificates" || echo on))"
        return 0
    fi
    w_would "point Jellyfin's LDAP plugin at the portal: $(jq -r '.LdapServer' <<<"$want"):443 (LDAPS), whoever may open Jellyfin (its tier: $(svc_tier jellyfin)) may sign in, new users get every library" || return 0
    merged=$(jq -c --argjson w "$want" '. + $w' <<<"$cur")
    jf_api POST "/Plugins/$JF_LDAP_GUID/Configuration" "$tok" "$merged" >/dev/null \
        && ok "LDAP plugin configured — portal accounts sign in to Jellyfin (created on their first sign-in)" \
        || wfail "Jellyfin rejected the LDAP plugin's settings [HTTP $(jf_code)]"
}

jf_admin_sync() { # directory users in the portal's admin group are Jellyfin administrators; other directory users are not
    # (the plugin sets this only when it creates a user). Local accounts — the
    # stack's own admin above all — are never touched.
    local tok="$1" out admins users u name id pol want
    out=$(signin_admins) || { wfail "authentik: the $PORTAL_ADMIN group is unreadable — Jellyfin admin rights not synced: $(oneline "$out")"; return 1; }
    admins=" $(jq -r '[.results[].username] | join(" ")' <<<"$out") "
    users=$(jf_api GET /Users "$tok") || { wfail "could not list jellyfin users [HTTP $(jf_code)]"; return 1; }
    while IFS= read -r u; do
        [[ -n "$u" ]] || continue
        name=$(jq -r '.Name' <<<"$u"); id=$(jq -r '.Id' <<<"$u")
        want=false; [[ "$admins" == *" $name "* ]] && want=true
        [[ "$(jq -r '.Policy.IsAdministrator' <<<"$u")" == "$want" ]] && continue
        w_would "Jellyfin: $name $( [[ $want == true ]] && echo "becomes an administrator (in $PORTAL_ADMIN)" || echo "is no longer an administrator (not in $PORTAL_ADMIN)")" || continue
        pol=$(jq -c --argjson w "$want" '.Policy | .IsAdministrator = $w' <<<"$u")
        jf_api POST "/Users/$id/Policy" "$tok" "$pol" >/dev/null && ok "Jellyfin: $name administrator = $want" \
            || wfail "Jellyfin rejected $name's admin change [HTTP $(jf_code)]"
    done < <(jq -c --arg p "$JF_LDAP_PROVIDER" '.[] | select(.Policy.AuthenticationProviderId == $p)' <<<"$users")
    return 0
}

jf_ldap() { # with the portal: Jellyfin checks passwords against it (LDAP), admin rights follow the admin group
    local tok="$1"
    signin_is authentik || return 0
    [[ -n "$(env_get AUTHENTIK_LDAP_TOKEN)" ]] || { info "the portal's LDAP outpost has no token yet — run 'wire authentik' first, then 'wire jellyfin'"; return 0; }
    # installed by jf_plugins_wanted, loaded by jf_restart_pending; not there: its failure was said there (a dry run: not installed yet)
    jf_api GET "/Plugins/$JF_LDAP_GUID/Configuration" "$tok" >/dev/null || return 0
    jf_ldap_configure "$tok" || return 0
    people_follow_on jellyfin
    jf_admin_sync "$tok"
}

jellyfin_people_follow() { # lib/people.sh: the sign-in filter, who may sign in, then admin rights — each follows the portal
    local tok; tok=$(env_get JELLYFIN_API_KEY)
    [[ -n "$tok" ]] || { wfail "jellyfin: no API key in .env (JELLYFIN_API_KEY) — ./mediastack.sh wire jellyfin makes one"; return 0; }
    jf_ldap_filter_follow "$tok" || true   # its failures are counted (WIRE_FAILS)
    jf_people_access "$tok"
    jf_admin_sync "$tok" || true
}

jf_ldap_filter_follow() { # TOKEN — the plugin's search filter matches the rule (a tier moved since wire); silent when it does
    local cur
    cur=$(jf_api GET "/Plugins/$JF_LDAP_GUID/Configuration" "$1") || { wfail "could not read the LDAP plugin's settings [HTTP $(jf_code)]"; return 1; }
    [[ "$(jq -r '.LdapSearchFilter // ""' <<<"$cur")" == "$(jf_ldap_want | jq -r '.LdapSearchFilter')" ]] && return 0
    jf_ldap_configure "$1"
}

# who may sign in (docs/design-access.md, decision 12): a directory user the
# portal no longer lets open Jellyfin — account deactivated or deleted, its
# tier, a grant taken away — is disabled (an open session's next request is
# refused, proven live) and signed out of every device (apps go to sign-in
# instead of spinning). Jellyfin 12.4 ends a disabled person's sign-ins itself
# (proven live 18 Nov 2026: their device gone, none left for the sign-out), so
# the devices are counted before the disable, and the sign-out after it takes
# whatever another version leaves. A person deleted from the portal is also
# renamed removed-<name>-<date> (as Navidrome's): someone who signs up later
# under that name gets a fresh account instead of taking over the old one
# (decided 18 Nov 2026); the renamed one is never looked at again. Allowed again, only someone the stack disabled
# (local/jellyfin-people) is enabled again: their portal password signs in as
# before. Someone an admin disabled by hand stays disabled; local accounts
# (the stack's own above all) are never touched.
jf_person_set() { # jf_person_set TOKEN USER-JSON true|false — IsDisabled written, then read back
    local id pol out
    id=$(jq -r '.Id' <<<"$2")
    pol=$(jq -c --argjson d "$3" '.Policy | .IsDisabled = $d' <<<"$2")
    out=$(jf_api POST "/Users/$id/Policy" "$1" "$pol") || { echo "Jellyfin refused it [HTTP $(jf_code)]: $(oneline "$out")"; return 1; }
    out=$(jf_api GET "/Users/$id" "$1") || { echo "it answered, but the account is unreadable now [HTTP $(jf_code)]"; return 1; }
    [[ "$(jq -r '.Policy.IsDisabled' <<<"$out")" == "$3" ]] || { echo "it answered, but the change did not hold"; return 1; }
}

jf_person_rename() { # jf_person_rename TOKEN USER-JSON NEW — its name changed, then read back
    local id dto out
    id=$(jq -r '.Id' <<<"$2")
    dto=$(jf_api GET "/Users/$id" "$1") || { echo "its account is unreadable [HTTP $(jf_code)]"; return 1; }
    out=$(jf_api POST "/Users?userId=$id" "$1" "$(jq -c --arg n "$3" '.Name = $n' <<<"$dto")") \
        || { echo "Jellyfin refused the new name [HTTP $(jf_code)]: $(oneline "$out")"; return 1; }
    out=$(jf_api GET "/Users/$id" "$1") || { echo "it answered, but the account is unreadable now [HTTP $(jf_code)]"; return 1; }
    [[ "$(jq -r '.Name' <<<"$out")" == "$3" ]] || { echo "it answered, but the name did not change"; return 1; }
}

jf_person_off() { # jf_person_off TOKEN USER-JSON NAME WHY — disabled and signed out; rc 1 (a failure said) when still able to sign in
    local tok=$1 u=$2 name=$3 why=$4 uid devs n out
    uid=$(jq -r '.Id' <<<"$u")
    # counted first: the disable itself ends them (Jellyfin 12.4, above)
    if devs=$(jf_devices "$tok"); then n=$(awk -F'\t' -v u="$uid" '$2 == u' <<<"$devs" | wc -l); else n="?"; fi
    if ! out=$(jf_person_set "$tok" "$u" true); then wfail "jellyfin: '$name' ($why) still signs in — $out"; return 1; fi
    people_set jellyfin "$name" off
    if jf_signout_uid "$tok" "$uid" "$name"; then
        [[ "$n" == "?" ]] && n=$JF_SIGNED_OUT
        ok "jellyfin: '$name' can no longer sign in ($why) — signed out of $n device(s)"
    else
        wfail "jellyfin: '$name' is disabled ($why), but still signed in somewhere — $JF_SIGNOUT_WHY (their next request is refused all the same)"
    fi
}

jf_people_access() { # jf_people_access TOKEN — directory users follow the rule (see above)
    local tok=$1 portal users u name pu st why out new
    portal=$(signin_people) || { wfail "authentik: its people are unreadable — Jellyfin's sign-ins not checked: $(oneline "$portal")"; return 0; }
    # a group the rule reads missing: nobody would be in it — everyone cut off, unasked
    why=$(people_rule_ready) || { wfail "$why — Jellyfin's sign-ins left as they are"; return 0; }
    users=$(jf_api GET /Users "$tok") || { wfail "could not list jellyfin users [HTTP $(jf_code)]"; return 0; }
    while IFS= read -r u; do
        [[ -n "$u" ]] || continue
        name=$(jq -r '.Name' <<<"$u")
        st=$(people_get jellyfin "$name")
        [[ "$st" == removed ]] && continue   # a deleted person's, renamed: never looked at again
        pu=$(jq -c --arg n "${name,,}" '[.results[]? | select((.username | ascii_downcase) == $n)][0] // empty' <<<"$portal")
        if [[ -n "$pu" ]] && people_may "$pu" jellyfin; then
            [[ "$st" == off ]] || continue
            if [[ "$(jq -r '.Policy.IsDisabled' <<<"$u")" != true ]]; then   # an admin turned them on already
                (( WIRE_DRY )) || people_set jellyfin "$name" ""; continue
            fi
            w_would "jellyfin: '$name' may sign in again" || continue
            if out=$(jf_person_set "$tok" "$u" false); then
                people_set jellyfin "$name" ""
                ok "jellyfin: '$name' may sign in again — their portal password, as before"
            else wfail "jellyfin: '$name' may open Jellyfin again, but is still disabled — $out"; fi
            continue
        fi
        if [[ -z "$pu" ]]; then   # deleted from the portal: off, then renamed — even one an admin had disabled (the name is the risk)
            new="removed-$name-$(date +%Y%m%d)"
            w_would "jellyfin: '$name' (portal account deleted) is disabled, signed out and kept as '$new' — their history stays, the name free for someone new" || continue
            if [[ "$(jq -r '.Policy.IsDisabled' <<<"$u")" != true ]]; then jf_person_off "$tok" "$u" "$name" "portal account deleted" || continue; fi
            if ! out=$(jf_person_rename "$tok" "$u" "$new"); then wfail "jellyfin: '$name' (portal account deleted) is disabled, but keeps its name — $out"; continue; fi
            people_set jellyfin "$name" ""; people_set jellyfin "$new" removed
            ok "jellyfin: '$name' (portal account deleted) kept as '$new'"
            notify ops "Jellyfin" "$name can no longer sign in to Jellyfin: their portal account was deleted. Their Jellyfin account is kept as $new." info
            continue
        fi
        [[ "$(jq -r '.Policy.IsDisabled' <<<"$u")" == true ]] && continue   # off already: the stack's (recorded) or an admin's (left)
        if [[ "$(jq -r '.is_active' <<<"$pu")" != true ]]; then why="portal account deactivated"
        else why="may no longer open Jellyfin"; fi
        w_would "jellyfin: '$name' ($why) is disabled and signed out — their history stays" || continue
        jf_person_off "$tok" "$u" "$name" "$why" || continue
        notify ops "Jellyfin" "$name can no longer sign in to Jellyfin: $why. Allowed again, they sign in with their portal password." info
    done < <(jq -c --arg p "$JF_LDAP_PROVIDER" '.[] | select(.Policy.AuthenticationProviderId == $p)' <<<"$users")
    return 0
}

jellyfin_logins() { printf "Jellyfin's admin (the operator's, and Seerr's owner)\tJELLYFIN_ADMIN_USER\tJELLYFIN_ADMIN_PASSWORD\treserve\n"; }   # lib/logins.sh
jellyfin_summary() { printf 'jellyfin name\t%s\n' "$(env_get JELLYFIN_SERVER_NAME)"; }   # its line of configure's summary

jf_server_name_problem() { # jf_server_name_problem NAME -> why not ("" when fine)
    case "$1" in
        *[\$\"\'\`\\]*) echo "Leave out \$, quotes, backslashes and backticks — .env cannot hold them safely." ;;
        *[![:space:]]*) ;;
        *) echo "The server needs a name." ;;
    esac
}

jellyfin_questions() { # the questionnaire's hook: the name Jellyfin's apps and casting show (wire sets it once)
    local cur p; cur=$(env_get JELLYFIN_SERVER_NAME)
    if answer JELLYFIN_SERVER_NAME; then
        p=$(jf_server_name_problem "$REPLY_VAL"); [[ -z "$p" ]] || answer_refused "JELLYFIN_SERVER_NAME: $p"
        env_set JELLYFIN_SERVER_NAME "$REPLY_VAL"; q_answered "Jellyfin server name" "$REPLY_VAL"; return 0
    fi
    if q_quick; then env_set JELLYFIN_SERVER_NAME "$cur"; q_took "Jellyfin server name" "$cur"; return 0; fi
    if answers_checking; then q_unasked "Jellyfin server name" JELLYFIN_SERVER_NAME; return 0; fi
    while true; do
        ask JELLYFIN_SERVER_NAME "Jellyfin server name (shows in its apps and when casting)" "$cur"
        p=$(jf_server_name_problem "$REPLY_VAL"); [[ -z "$p" ]] && break
        fail "$p"
    done
    env_set JELLYFIN_SERVER_NAME "$REPLY_VAL"
}

jf_server_name() { # the name apps/casting show, set once: only while it is still the container's ID hash
    local tok="$1" cfg have want
    cfg=$(jf_api GET /System/Configuration "$tok") \
        || { wfail "could not read jellyfin's settings to check its server name [HTTP $(jf_code)]: $(oneline "$cfg")"; return 0; }
    have=$(jq -r '.ServerName // empty' <<<"$cfg")
    if [[ -n "$have" && ! "$have" =~ ^[0-9a-f]{12}$ ]]; then
        ok "server name '$have'"
        return 0
    fi
    want=$(env_get JELLYFIN_SERVER_NAME)
    w_would "name the Jellyfin server '$want'" || return 0
    jf_api POST /System/Configuration "$tok" "$(jq -c --arg n "$want" '.ServerName=$n' <<<"$cfg")" >/dev/null \
        && ok "server name set to '$want'" \
        || wfail "Jellyfin rejected the server name [HTTP $(jf_code)] — set it in Dashboard -> General"
}

JF_TRANSCODE_PATH=/cache/transcodes   # inside the container; ${TRANSCODE_ROOT}/jellyfin on the host
jf_transcode_path() { # transcodes belong on the cache volume, not in /config
    # Jellyfin's default is <data>/transcodes = /config/data/transcodes: the
    # config volume, which backup archives and which sits wherever CONFIG_ROOT
    # does. Segments are written at source bitrate for the whole session.
    local tok="$1" cfg have
    cfg=$(jf_api GET /System/Configuration/encoding "$tok" || true)   # soft read: judged on the next line
    [[ "$(jf_code)" =~ ^2 ]] || { wfail "could not read jellyfin's encoding settings [HTTP $(jf_code)]: $(head -c200 <<<"$cfg")"; return 0; }
    have=$(jq -r '.TranscodingTempPath // empty' <<<"$cfg" 2>/dev/null)
    if [[ "$have" == "$JF_TRANSCODE_PATH" ]]; then ok "transcodes go to $JF_TRANSCODE_PATH (the cache volume)"; return 0; fi
    w_would "point jellyfin's transcodes at $JF_TRANSCODE_PATH (now: ${have:-the default, /config/data/transcodes})" || return 0
    jf_api POST /System/Configuration/encoding "$tok" "$(jq -c --arg p "$JF_TRANSCODE_PATH" '.TranscodingTempPath=$p' <<<"$cfg")" >/dev/null \
        && ok "transcodes now go to $JF_TRANSCODE_PATH" \
        || wfail "Jellyfin rejected the transcode path [HTTP $(jf_code)] — set Dashboard -> Playback -> Transcoding -> Transcode path to $JF_TRANSCODE_PATH"
}

# Behind Traefik, Jellyfin must trust Traefik's address to read each client's
# own address from the forwarded header — otherwise every client looks like
# Traefik (one address in sessions and logs, everyone local). Jellyfin reads
# its proxies at start: a change restarts it once. Proven live on Jellyfin 12
# (Oct 2026): before, every session came from Traefik's address; after, the
# client's own — and with "LAN networks" left empty it still counts the private
# ranges as local, so nothing else needs setting. Other entries stay yours.
jf_proxy_trusted() { # jf_proxy_trusted NETWORK-JSON ADDRESS -> "true" | "false" | "" (no KnownProxies: the setting moved)
    jq -r --arg a "$2" 'if has("KnownProxies") then ((.KnownProxies // []) | index($a) != null) else "" end' <<<"$1" 2>/dev/null
}
jf_known_proxies() {
    local tok="$1" cfg addr have want new
    addr=$(env_get TRAEFIK_ADDRESS)
    if svc_enabled traefik; then want=true; else want=false; fi
    cfg=$(jf_api GET /System/Configuration/network "$tok") \
        || { wfail "could not read jellyfin's network settings [HTTP $(jf_code)]: $(head -c200 <<<"$cfg")"; return 0; }
    have=$(jf_proxy_trusted "$cfg" "$addr")
    [[ -n "$have" ]] || { wfail "jellyfin's network settings have no KnownProxies — the setting moved in this version; set Dashboard -> Networking -> Known proxies by hand (Traefik: $addr)"; return 0; }
    if [[ "$have" == "$want" ]]; then
        if (( ${JF_AFTER_RESTART:-0} )) && [[ "$want" == true ]]; then ok "jellyfin now trusts Traefik ($addr) — sessions show each client's own address"
        elif (( ${JF_AFTER_RESTART:-0} )); then ok "jellyfin no longer trusts $addr"
        elif [[ "$want" == true ]]; then ok "jellyfin trusts Traefik ($addr) to name each client's own address"
        else ok "jellyfin trusts no proxy of the stack's (Traefik is off)"; fi
        return 0
    fi
    if (( ${JF_AFTER_RESTART:-0} )); then
        wfail "jellyfin's Known proxies did not read back as changed after its restart [HTTP $(jf_code)]: $(jq -c '.KnownProxies' <<<"$cfg" 2>/dev/null || head -c200 <<<"$cfg") — check Dashboard -> Networking"
        return 0
    fi
    if [[ "$want" == true ]]; then
        w_would "jellyfin: trust Traefik ($addr) to name each client's own address (one jellyfin restart)" || return 0
        new=$(jq -c --arg a "$addr" '.KnownProxies = ((.KnownProxies // []) + [$a])' <<<"$cfg")
    else
        w_would "jellyfin: stop trusting $addr — Traefik is off, so that address could be anyone's (one jellyfin restart)" || return 0
        new=$(jq -c --arg a "$addr" '.KnownProxies = ((.KnownProxies // []) - [$a])' <<<"$cfg")
    fi
    jf_api POST /System/Configuration/network "$tok" "$new" >/dev/null \
        || { wfail "jellyfin rejected its network settings [HTTP $(jf_code)] — set Dashboard -> Networking -> Known proxies by hand"; return 0; }
    JF_RESTART_FOR+=("its proxies"); JF_PROXIES_CHANGED=1   # restarted once with the rest, then read back (jf_restart_pending)
}

# ---- jellyfin (wave 4) ----
# Wire's jellyfin surface is deliberately tiny: complete the first-run wizard
# (once, ever — the API gate closes itself), create libraries whose PATH is
# not yet covered, and mint the stack's API key. It never updates or deletes
# anything: rename/merge/tune libraries in the GUI freely — wire matches by
# path, not name, so it will not recreate or touch them.
JF_AUTH_HDR='Authorization: MediaBrowser Client="mediastack", Device="mediastack", DeviceId="mediastack-wire", Version="1.0"'
# The token rides INSIDE the MediaBrowser header. Jellyfin 12.0 disables the
# legacy carriers (X-Emby-Token / X-Emby-Authorization / ?api_key=) by default
# and a migration switches them off on existing installs, so they 401.
jf_auth_hdr() { printf '%s%s' "$JF_AUTH_HDR" "${1:+, Token=\"$1\"}"; }
# jf_api runs inside $( ) at every call site, so a plain global would be lost
# to the subshell — the last HTTP code crosses back via a per-PID file.
JF_CODE_F="${TMPDIR:-/tmp}/.mediastack-jf-code.$$"
jf_code() { cat "$JF_CODE_F" 2>/dev/null || echo 000; }
jf_url() { local p; p=$(svc_hostport jellyfin) || return 1; echo "http://127.0.0.1:$p"; }
jf_api() { # jf_api METHOD PATH TOKEN [json-body] -> body on stdout; rc = http 2xx
    local m="$1" p="$2" tok="$3" b="${4:-}" out code
    out=$(scurl -sS -m 20 -X "$m" -H "$(jf_auth_hdr "$tok")" \
          -H "Content-Type: application/json" \
          ${b:+-d "$b"} -w $'\n%{http_code}' "$(jf_url)$p" 2>&1) \
        || { local rc=$?; printf '000' > "$JF_CODE_F"; api_timed_out "$rc" && api_unanswered "$m" 20 || echo "$out"; return 1; }
    code=${out##*$'\n'}; printf '%s' "$code" > "$JF_CODE_F"
    echo "${out%$'\n'*}"
    [[ "$code" =~ ^2 ]]
}
# ready is when the API answers: /health says 200 between the restart's two
# phases while the API still answers 503 (measured live, 14 Oct 2026)
# Ready means the real server. While it loads, Jellyfin 12 runs a temporary
# setup server that can answer /System/Info/Public with 200, then drops every
# connection as the real one takes over (proven live on 12.2, Oct 2026: 200,
# then 000, then 503, then 200 only after "Startup complete"). So: its own
# "Startup complete" since this container started, then the API.
JF_STARTED_LINE='Main: Startup complete'
jf_ready() {
    local cn since t0 log
    cn=$(svc_cname jellyfin); since=$(c_get "$cn" '.State.StartedAt'); t0=$(date +%s)
    [[ -n "$since" ]] || { wfail "jellyfin's container has no start time — is it running? (./mediastack.sh status)"; return 1; }
    # read whole, then search: piped into grep -q, docker would die of SIGPIPE
    # and pipefail would call a found line "not found" (caught by the test)
    while log=$(sudo docker logs --since "$since" "$cn" 2>&1 || true); ! grep -qF "$JF_STARTED_LINE" <<<"$log"; do
        if (( $(date +%s) - t0 >= API_WAIT )); then
            wfail "jellyfin never logged '$JF_STARTED_LINE' within ${API_WAIT}s of starting — inspect: ./mediastack.sh logs jellyfin"
            return 1
        fi
        sleep 2
    done
    http_ready jellyfin "$(jf_url)/System/Info/Public" '^200$'
}
jf_libname() { # jf_libname <arr service> <media subdir> -> default library name
    # an instance names its own library (mediastack.jflibrary: "Movies (4K)");
    # otherwise its type's name; a type wire doesn't know, its folder's name
    local n ty; n=$(svc_label "$1" mediastack.jflibrary); ty=$(svc_label "$1" mediastack.arrtype)
    if [[ -n "$n" ]]; then echo "$n"
    elif arr_known "$ty"; then arr_meta "$ty" jfname
    else echo "${2^}"; fi
}

wire_jellyfin() {
    hr "wire: jellyfin"
    svc_enabled jellyfin || { info "jellyfin not enabled — skipped"; return 0; }
    wire_gate jellyfin
    jf_ready || return 0
    local pub completed juser jpass
    pub=$(jf_api GET /System/Info/Public "" || true)   # soft read: checked two lines below
    # NB: jq's // operator treats false as missing — read booleans plainly
    completed=$(jq -r '.StartupWizardCompleted' <<<"$pub" 2>/dev/null)
    [[ "$completed" == true || "$completed" == false ]] \
        || { wfail "jellyfin gave no readable public info [HTTP $(jf_code)]: $(head -c200 <<<"$pub")"; return 0; }
    juser=$(env_get JELLYFIN_ADMIN_USER); jpass=$(env_get JELLYFIN_ADMIN_PASSWORD)

    # --- first-run wizard: only ever runs while jellyfin says it is unclaimed.
    # This also closes a real hole: an unconfigured jellyfin lets ANY visitor
    # create the admin account.
    if [[ "$completed" == false ]]; then
        # the admin — the operator's and recovery login, Seerr's owner — is one
        # of the stack's own logins: configure records it (lib/logins.sh)
        if [[ -z "$juser" || -z "$jpass" ]]; then
            wfail "jellyfin's admin login is not in .env (JELLYFIN_ADMIN_USER / JELLYFIN_ADMIN_PASSWORD) — ./mediastack.sh up records one, then re-run wire"
            return 0
        fi
        if [[ -n "$juser" && -n "$jpass" ]] && w_would "complete jellyfin's first-run wizard (admin '$juser', remote access on, UPnP off)"; then
            local step out
            for step in cfg getuser postuser remote complete; do
                case "$step" in
                    cfg)      out=$(jf_api POST /Startup/Configuration "" '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}') ;;
                    getuser)  out=$(jf_api GET /Startup/User "") ;;  # initialises the first-user record
                    postuser) out=$(jf_api POST /Startup/User "" "$(jq -cn --arg u "$juser" --arg p "$jpass" '{Name:$u,Password:$p}')") ;;
                    remote)   out=$(jf_api POST /Startup/RemoteAccess "" '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}') ;;
                    complete) out=$(jf_api POST /Startup/Complete "") ;;
                esac || { wfail "jellyfin wizard step '$step' rejected [HTTP $(jf_code)]: $(head -c200 <<<"$out")"; return 0; }
            done
            ok "first-run wizard completed — admin '$juser'"
        fi
    else
        ok "first-run wizard already completed"
    fi

    # --- everything below needs an admin session
    if [[ -z "$juser" || -z "$jpass" ]]; then
        if (( WIRE_DRY )); then
            w_pends "library/API-key previews pend on the admin login — created earlier in the same real run"
        else
            info "jellyfin was configured outside wire and no JELLYFIN_ADMIN_USER/PASSWORD is in .env — libraries and the stack API key stay manual (set them in .env to let wire manage those)"
        fi
        return 0
    fi
    local auth tok
    auth=$(jf_api POST /Users/AuthenticateByName "" "$(jq -cn --arg u "$juser" --arg p "$jpass" '{Username:$u,Pw:$p}')") \
        || { (( WIRE_DRY )) && { info "cannot verify further without logging in — real run continues from here"; return 0; }
             wfail "jellyfin rejected the admin login from .env [HTTP $(jf_code)]: $(head -c200 <<<"$auth")"; return 0; }
    tok=$(jq -r '.AccessToken // empty' <<<"$auth")
    [[ -n "$tok" ]] || { wfail "jellyfin login succeeded but returned no token: $(head -c200 <<<"$auth")"; return 0; }
    jf_server_name "$tok"
    jf_transcode_path "$tok"
    jf_known_proxies "$tok"
    jf_plugins_wanted "$tok"
    jf_restart_pending "$tok" || true   # a failure is reported by it
    jf_ldap "$tok"
    jf_livetv "$tok"   # the live-tv role's provider as its tuner and guide (services/jellyfin/livetv.sh)

    # --- libraries: create-if-path-missing, derived from the arrs' own
    # rootfolder labels. Match by the HOST directory a library's location
    # resolves to through the container's mounts, not by the container path:
    # a migrated jellyfin sees the same tree under an alias (an extra mount
    # in the override, e.g. /data/tvshows) and must not be offered a twin
    # at /media/tv. GUI renames/merges are respected the same way.
    local vf droot jcn; vf=$(jf_api GET /Library/VirtualFolders "$tok" || true)   # soft read: checked on the next line
    [[ "$(jf_code)" =~ ^2 ]] || { wfail "could not list jellyfin libraries [HTTP $(jf_code)]: $(head -c200 <<<"$vf")"; return 0; }
    droot=$(env_get DATA_ROOT); jcn=$(svc_cname jellyfin)
    local -A covered=()   # host dir -> the container location a library uses for it
    local loc hp
    while IFS= read -r loc; do
        [[ -n "$loc" ]] || continue
        hp=$(c_host_path "$jcn" "$loc")
        [[ -n "$hp" ]] || { warn "jellyfin library location $loc is not backed by any mount of the container — a library pointing at nothing"; continue; }
        covered[$(readlink -f "$hp" 2>/dev/null || echo "$hp")]=$loc
    done < <(jq -r '.[].Locations[]?' <<<"$vf")
    local -A seen=()
    local s rf base path hdir ty ctype lname enc_n enc_p resp
    for s in $(arr_instances); do
        rf=$(svc_label "$s" mediastack.rootfolder); base=${rf##*/}
        [[ -n "$base" && -z "${seen[$base]:-}" ]] || continue; seen[$base]=1
        path="/media/$base"
        hdir=$(readlink -f "$droot/media/$base" 2>/dev/null || echo "$droot/media/$base")
        ty=$(svc_label "$s" mediastack.arrtype)
        arr_known "$ty" || continue
        ctype=$(arr_meta "$ty" jftype)
        if [[ -n "${covered[$hdir]:-}" ]]; then
            if [[ "${covered[$hdir]}" == "$path" ]]; then
                ok "a library already covers $path — untouched (yours to manage in the GUI)"
            else
                ok "a library already covers $hdir (as ${covered[$hdir]} inside the container) — untouched (yours to manage in the GUI)"
            fi
            continue
        fi
        # its default name — rename it in Jellyfin if you like: wire never renames a library
        lname=$(jf_libname "$s" "$base")
        if (( WIRE_DRY )); then
            w_would "create jellyfin library '$lname' -> $path (${ctype})" || true
            continue
        fi
        # jellyfin sees /media read-only; the host dir must exist or the
        # library is born broken. Same ownership pattern as configure's tree.
        sudo test -d "$droot/media/$base" \
            || { sudo install -d -m 2775 -g mediacenter "$droot/media/$base" && info "created $droot/media/$base (was missing)"; }
        if w_would "create jellyfin library '$lname' -> $path"; then
            enc_n=$(jq -rn --arg v "$lname" '$v|@uri'); enc_p=$(jq -rn --arg v "$path" '$v|@uri')
            resp=$(jf_api POST "/Library/VirtualFolders?name=${enc_n}&collectionType=${ctype}&paths=${enc_p}&refreshLibrary=true" "$tok" '{"LibraryOptions":{}}') \
                && ok "library '$lname' created" \
                || wfail "library '$lname' rejected [HTTP $(jf_code)]: $(head -c200 <<<"$resp")"
        fi
    done

    # --- one API key for the stack (update-defer streaming check + doctor)
    local keys have
    keys=$(jf_api GET /Auth/Keys "$tok") \
        || { wfail "could not list jellyfin API keys [HTTP $(jf_code)] — nothing created"; return 0; }
    have=$(jq -r '.Items[]? | select(.AppName=="mediastack") | .AccessToken' <<<"$keys" 2>/dev/null | sed -n 1p)
    if [[ -n "$have" ]]; then
        [[ "$(env_get JELLYFIN_API_KEY)" == "$have" ]] || env_set JELLYFIN_API_KEY "$have"
        ok "stack API key present"
    elif w_would "mint a jellyfin API key for the stack (app 'mediastack')"; then
        jf_api POST "/Auth/Keys?app=mediastack" "$tok" >/dev/null \
            || { wfail "API key creation rejected [HTTP $(jf_code)]"; return 0; }
        keys=$(jf_api GET /Auth/Keys "$tok" || true)   # soft read: re-read after creating the key: empty FAILs below
        have=$(jq -r '.Items[]? | select(.AppName=="mediastack") | .AccessToken' <<<"$keys" 2>/dev/null | sed -n 1p)
        [[ -n "$have" ]] || { wfail "API key created but not readable back — check Dashboard -> API Keys"; return 0; }
        env_set JELLYFIN_API_KEY "$have"
        ok "stack API key minted and stored (JELLYFIN_API_KEY)"
    fi
    jellyfin_brand_apply   # the household's kit on Jellyfin (services/jellyfin/kit.sh)
}

sc_explain_jellyfin() { echo "Seerr federates to Jellyfin (nothing to change there) and Wizarr connects
by API key (unchanged). Only this password and .env move."; }   # set-credentials jellyfin (lib/access.sh)
jellyfin_credentials() { # credentials (lib/access.sh): who signs in with that admin
    signin_is authentik && echo "with the portal, that admin is the stack's own local account (and the emergency login) — people sign in with their portal accounts; Jellyfin admin rights follow the portal's $PORTAL_ADMIN group"
    return 0
}
jellyfin_api_key() { env_get JELLYFIN_API_KEY; }   # credentials' keys for your apps (lib/access.sh) — dashboards, Wizarr's Add Server
sc_rotate_jellyfin() { # PASS — the Jellyfin admin (Seerr/Wizarr unaffected)
        local npass="$1" juser jpass auth tok
        svc_enabled jellyfin || { info "jellyfin not enabled — skipped"; return 0; }
        juser=$(env_get JELLYFIN_ADMIN_USER); jpass=$(env_get JELLYFIN_ADMIN_PASSWORD)
        [[ -n "$juser" && -n "$jpass" ]] || die "no Jellyfin admin stored — run 'wire jellyfin' first"
        auth=$(jf_api POST /Users/AuthenticateByName "" "$(jq -cn --arg u "$juser" --arg p "$jpass" '{Username:$u,Pw:$p}')") \
            || die "Jellyfin rejected the stored admin login [HTTP $(jf_code)] — is .env stale?"
        tok=$(jq -r '.AccessToken // empty' <<<"$auth")
        jf_api POST /Users/Password "$tok" "$(jq -cn --arg c "$jpass" --arg n "$npass" '{CurrentPw:$c,NewPw:$n}')" >/dev/null \
            || die "Jellyfin refused the password change [HTTP $(jf_code)]"
        jf_api POST /Users/AuthenticateByName "" "$(jq -cn --arg u "$juser" --arg p "$npass" '{Username:$u,Pw:$p}')" >/dev/null \
            || die "verification sign-in with the NEW password failed — check Jellyfin's users in its dashboard"
        env_set JELLYFIN_ADMIN_PASSWORD "$npass"
        ok "Jellyfin admin password rotated and verified"
}

jellyfin_doctor() { # doctor: apps — claimed, and the stack key works
    local jpub
    jpub=$(scurl -s -m 10 "$(jf_url)/System/Info/Public" 2>/dev/null || true)
    case "$(jq -r '.StartupWizardCompleted' <<<"$jpub" 2>/dev/null)" in
        true)  ok "jellyfin first-run wizard completed" ;;
        false) d_fail "jellyfin first-run wizard NOT completed" "an unclaimed jellyfin lets any visitor create the admin account" "./mediastack.sh wire jellyfin" ;;
        *)     warn "jellyfin public info unreadable — API may still be warming up" ;;
    esac
    # the stack key must open an authenticated endpoint: update's session
    # check, backup and wire all ride on it
    local jkey; jkey=$(env_get JELLYFIN_API_KEY)
    if [[ -n "$jkey" ]]; then
        jf_api GET /System/Info "$jkey" >/dev/null 2>&1 || true   # soft read: judged by its HTTP status below
        case "$(jf_code)" in
            2*)  ok "jellyfin accepts the stack API key (JELLYFIN_API_KEY)" ;;
            401) d_fail "jellyfin rejects the stack API key (HTTP 401)" "the key was revoked, or the server refuses the auth carrier (Jellyfin 12+ disables legacy X-Emby-Token/api_key)" "./mediastack.sh wire jellyfin  # re-mints the key; script auth is already on the MediaBrowser header" ;;
            *)   warn "jellyfin API key check inconclusive (HTTP $(jf_code))" ;;
        esac
        jellyfin_doctor_proxies "$jkey"
        jellyfin_doctor_plugins "$jkey"
    fi
}

jellyfin_doctor_plugins() { # jellyfin_doctor_plugins KEY — the plugins the stack depends on are loaded; their repository is reachable
    local plist need=() spec name guid why st
    signin_is authentik && need+=("LDAP Authentication|$JF_LDAP_GUID|portal accounts cannot sign in to Jellyfin")
    svc_enabled watchstate && need+=("Webhook|71552A5A-5C5C-4350-A2AE-EBE451A30173|WatchState gets no play events from Jellyfin")
    if (( ${#need[@]} )); then
        plist=$(jf_api GET /Plugins "$1" 2>/dev/null) || { warn "jellyfin's plugins unreadable [HTTP $(jf_code)] — not checked"; plist=""; }
        if [[ -n "$plist" ]]; then
            for spec in "${need[@]}"; do
                IFS='|' read -r name guid why <<<"$spec"
                st=$(jq -r --arg g "$(jf_guid "$guid")" '.[] | select((.Id | ascii_downcase | gsub("-"; "")) == $g) | .Status' <<<"$plist" 2>/dev/null | sed -n 1p)
                case "$st" in
                    Active) ok "jellyfin: $name plugin loaded" ;;
                    "")     d_fail "jellyfin: $name plugin is not installed" "$why" "./mediastack.sh wire jellyfin" ;;
                    *)      d_fail "jellyfin: $name plugin is $st, not loaded" "$why" "./mediastack.sh restart jellyfin — still not Active: reinstall it in Dashboard -> Plugins" ;;
                esac
            done
        fi
    fi
    # updates and installs need the repository: a block shows here, not as a bare 404 later
    local repos url r
    repos=$(jf_api GET /Repositories "$1" 2>/dev/null) || return 0
    while IFS= read -r url; do
        [[ -n "$url" ]] || continue
        r=$(jf_repo_reach "$url")
        if [[ -z "$r" ]]; then ok "jellyfin reaches its plugin repository ($url)"
        else warn "jellyfin cannot reach its plugin repository ($url: $r) — plugin installs and updates fail; something on this network blocks it"; fi
    done < <(jq -r '.[] | select(.Enabled) | .Url' <<<"$repos" 2>/dev/null)
}

jellyfin_doctor_proxies() { # jellyfin_doctor_proxies KEY — behind Traefik, Jellyfin trusts it (else every client looks like Traefik)
    svc_enabled traefik || return 0
    local cfg addr; addr=$(env_get TRAEFIK_ADDRESS)
    cfg=$(jf_api GET /System/Configuration/network "$1" 2>/dev/null) \
        || { warn "jellyfin's network settings unreadable [HTTP $(jf_code)] — Known proxies not checked"; return 0; }
    case "$(jf_proxy_trusted "$cfg" "$addr")" in
        true)  ok "jellyfin trusts Traefik ($addr) — sessions show each client's own address" ;;
        false) d_fail "jellyfin does not trust Traefik ($addr) as its proxy" \
                   "every client looks like Traefik: one address in sessions and logs, everyone counted as local" \
                   "./mediastack.sh wire jellyfin  # adds it to Known proxies (one jellyfin restart)" ;;
        *)     warn "jellyfin's network settings have no KnownProxies — check Dashboard -> Networking -> Known proxies holds $addr" ;;
    esac
}

jellyfin_doctor_transcodes() { # jellyfin_doctor_transcodes <CONFIG_ROOT> (doctor: host resources)
    # transcodes on the config volume: Jellyfin's default until `wire jellyfin`
    # points it at /cache; a session that died leaves its segments behind
    local croot="$1" jt jmb
    jt="$croot/jellyfin/data/transcodes"
    if sudo test -d "$jt"; then
        jmb=$(sudo du -sm "$jt" 2>/dev/null | cut -f1)
        [[ -n "$jmb" ]] || jmb=UNKNOWN
        if [[ "$jmb" == UNKNOWN ]]; then
            warn "jellyfin transcodes: could not size $jt"
        elif (( jmb >= 1024 )); then
            warn "jellyfin: ${jmb}MB of transcode segments on the CONFIG volume ($jt) — './mediastack.sh wire jellyfin' moves transcodes to TRANSCODE_ROOT; segments from a dead session clear when jellyfin restarts"
        else
            ok "jellyfin transcodes on the config volume: ${jmb}MB"
        fi
    fi
}

# ---- link-account: Jellyfin's part (the verb: lib/link.sh) ----
link_jf_candidates() { # USERS-JSON -> its local accounts, the stack's admin left out
    jq -c --arg p "$JF_LDAP_PROVIDER" --arg s "$(env_get JELLYFIN_ADMIN_USER)" '[.[]
        | select(.Policy.AuthenticationProviderId != $p and (.Name | ascii_downcase) != ($s | ascii_downcase))
        | {name: .Name, id: .Id, admin: .Policy.IsAdministrator}]' <<<"$1"
}
link_jf_conflict() { # USERS-JSON CANDIDATE PORTAL-USER -> the name of another account already called that (Jellyfin names are case-insensitive)
    jq -r --arg id "$(jq -r '.id' <<<"$2")" --arg w "${3,,}" '[.[] | select(.Id != $id and (.Name | ascii_downcase) == $w) | .Name] | first // empty' <<<"$1"
}
link_jf_do() { # TOKEN CANDIDATE PORTAL-USER
    local tok="$1" id who="$3" u
    id=$(jq -r '.id' <<<"$2")
    u=$(jf_api GET "/Users/$id" "$tok") || { fail "jellyfin: the account is unreadable [HTTP $(jf_code)]"; return 1; }
    if [[ "$(jq -r '.Name' <<<"$u")" != "$who" ]]; then
        jf_api POST "/Users?userId=$id" "$tok" "$(jq -c --arg n "$who" '.Name = $n' <<<"$u")" >/dev/null \
            || { fail "jellyfin refused the rename to '$who' [HTTP $(jf_code)]"; return 1; }
    fi
    # the plugin adopts an existing account by name only when its login method is the plugin's
    jf_api POST "/Users/$id/Policy" "$tok" "$(jq -c --arg p "$JF_LDAP_PROVIDER" '.Policy | .AuthenticationProviderId = $p | .PasswordResetProviderId = $p' <<<"$u")" >/dev/null \
        || { fail "jellyfin refused the login-method change [HTTP $(jf_code)]"; return 1; }
    u=$(jf_api GET "/Users/$id" "$tok") \
        && jq -e --arg n "$who" --arg p "$JF_LDAP_PROVIDER" '.Name == $n and .Policy.AuthenticationProviderId == $p' <<<"$u" >/dev/null \
        || { fail "jellyfin answered, but the account is not '$who' on the portal's login"; return 1; }
    ok "jellyfin: '$who' signs in with the portal password from now on (same account: history kept)"
}

jellyfin_sessions_active() {
    local key host; key=$(env_get JELLYFIN_API_KEY); host=$(jf_url)
    [[ -n "$key" ]] || return 1
    local n
    n=$(scurl -fsS --max-time 5 -H "$(jf_auth_hdr "$key")" "$host/Sessions" 2>/dev/null \
        | jq '[.[] | select(.NowPlayingItem != null)] | length' 2>/dev/null || echo 0)
    (( n > 0 ))
}

support_jellyfin() { # support: its version, plugins, transcoding, libraries and the proxies it trusts
    local tok out
    sp_running jellyfin || return 0
    tok=$(env_get JELLYFIN_API_KEY); [[ -n "$tok" ]] || { echo "no stack API key yet (wire jellyfin makes it)"; return 0; }
    out=$(jf_api GET /System/Info "$tok") && jq -r '"version \(.Version)\(if .HasPendingRestart then ", a restart is pending" else "" end)"' <<<"$out" || echo "system info unreadable: $(oneline "$out")"
    out=$(jf_api GET /Plugins "$tok") && jq -r '.[] | "plugin \(.Name) \(.Version): \(.Status)"' <<<"$out" || echo "plugins unreadable: $(oneline "$out")"
    out=$(jf_api GET /System/Configuration/encoding "$tok") && jq -r '"transcoding: to \(.TranscodingTempPath // "the default"), hardware \(.HardwareAccelerationType // "none")"' <<<"$out" || echo "transcoding settings unreadable: $(oneline "$out")"
    # its network settings, where KnownProxies lives (as wire and doctor read it: jf_known_proxies)
    out=$(jf_api GET /System/Configuration/network "$tok") && jq -r 'if has("KnownProxies") then "trusted proxies: \((.KnownProxies // []) | if length == 0 then "none" else join(", ") end)" else "trusted proxies: not in its network settings (the setting moved?)" end' <<<"$out" || echo "network settings unreadable: $(oneline "$out")"
    out=$(jf_api GET /Library/VirtualFolders "$tok") && jq -r '.[] | "library \(.Name) (\(.CollectionType // "mixed")): \((.Locations // []) | join(", "))"' <<<"$out" || echo "libraries unreadable: $(oneline "$out")"
    return 0
}

# ---- rotate-secrets (lib/rotate.sh) ----
jellyfin_secrets() {
    svc_enabled jellyfin && [[ -n "$(env_get JELLYFIN_API_KEY)" ]] || return 0
    printf 'JELLYFIN_API_KEY\t%s\n' "$(signin_is wizarr && echo wizarr-jellyfin)"
}
jellyfin_secret_rotate() { # a new stack key minted beside the old one; the old one deleted only once the new one opens Jellyfin
    local old new keys url
    old=$(env_get JELLYFIN_API_KEY); url="$(jf_url)/System/Info"
    http_ready jellyfin "$(jf_url)/System/Info/Public" '^200$' || return 1   # after the restore point's restart: up before it is asked
    jf_api POST "/Auth/Keys?app=mediastack" "$old" >/dev/null || { fail "jellyfin: refused a new key [HTTP $(jf_code)]"; return 1; }
    keys=$(jf_api GET /Auth/Keys "$old") \
        || { fail "jellyfin: its keys are unreadable [HTTP $(jf_code)] — a spare key named mediastack may sit in Dashboard -> API Keys"; return 1; }
    new=$(jq -r --arg o "$old" '[.Items[]? | select(.AppName == "mediastack" and .AccessToken != $o) | .AccessToken][0] // empty' <<<"$keys")
    [[ -n "$new" ]] || { fail "jellyfin: the new key is not in its list"; return 1; }
    rotate_journal_hold JELLYFIN_API_KEY "$old" "$new"
    if ! [[ "$(rotate_http_code "$url" "$(jf_auth_hdr "$new")")" =~ ^2 ]]; then
        fail "jellyfin: the new key does not open it — deleted, the old one kept"
        jf_api DELETE "/Auth/Keys/$new" "$old" >/dev/null || true
        rotate_journal_release; return 1
    fi
    env_set JELLYFIN_API_KEY "$new"
    jf_api DELETE "/Auth/Keys/$old" "$new" >/dev/null || { fail "jellyfin: the old key was not deleted [HTTP $(jf_code)]"; return 2; }
    rotate_proven jellyfin "$url" "$(jf_auth_hdr "$new")" "$(jf_auth_hdr "$old")" || return 2
    rotate_journal_release
}

jellyfin_disabled() { # NAME — rc 0 when Jellyfin has NAME disabled (reset-password with Wizarr says so); dies when it cannot tell
    local key users
    key=$(env_get JELLYFIN_API_KEY)
    [[ -n "$key" ]] || die "no Jellyfin API key in .env — run: ./mediastack.sh wire jellyfin"
    users=$(jf_api GET /Users "$key") || die "jellyfin refused its user list [HTTP $(jf_code)]: $(oneline "$users")"
    jq -e --arg n "${1,,}" 'any(.[]?; (.Name | ascii_downcase) == $n and .Policy.IsDisabled == true)' <<<"$users" >/dev/null
}

# signout: Jellyfin's devices, as its API has them (read in v12.4's source and
# proven live 16 Nov 2026). Each /Devices entry is one sign-in, owned by its
# LastUserId; ?userId= is NOT that — it lists every device the person may use
# (all of them, by default). Removing a device ID ends every sign-in on it
# (the person's next request goes to sign-in), whoever's — so a device two
# people share is signed out for both, and the other is named.
jf_devices() { # KEY -> "deviceId<TAB>ownerId<TAB>ownerName" per sign-in; rc 1 (Jellyfin's answer on stdout) when refused
    local out
    out=$(jf_api GET /Devices "$1") || { echo "$out"; return 1; }
    jq -r '.Items[]? | [.Id, .LastUserId, .LastUserName] | @tsv' <<<"$out"
}
JF_SIGNED_OUT=0 JF_SIGNOUT_WHY=""
jf_signout_uid() { # jf_signout_uid KEY UID NAME — every sign-in UID has ends: rc 0 (JF_SIGNED_OUT devices), rc 1 (JF_SIGNOUT_WHY)
    local key=$1 uid=$2 list ids d other n left out codes=""
    JF_SIGNED_OUT=0 JF_SIGNOUT_WHY=""
    list=$(jf_devices "$key") || { JF_SIGNOUT_WHY="jellyfin refused its device list [HTTP $(jf_code)]: $(oneline "$list")"; return 1; }
    ids=$(awk -F'\t' -v u="$uid" '$2 == u {print $1}' <<<"$list" | sort -u)
    [[ -n "$ids" ]] || return 0
    n=$(wc -l <<<"$ids")
    while IFS= read -r d; do
        other=$(awk -F'\t' -v d="$d" -v u="$uid" '$1 == d && $2 != u {print $3}' <<<"$list" | sort -u | paste -sd, -)
        [[ -z "$other" ]] || warn "jellyfin: one of $3's devices is shared — signed out for $other too"
        out=$(jf_api DELETE "/Devices?id=$(jq -rn --arg s "$d" '$s | @uri')" "$key") || codes+=" $(jf_code): $(oneline "$out");"
    done <<<"$ids"
    # read back: the person's own sign-ins, not what each call answered
    list=$(jf_devices "$key") || { JF_SIGNOUT_WHY="jellyfin refused its device list after the sign-out [HTTP $(jf_code)]: $(oneline "$list")"; return 1; }
    left=$(awk -F'\t' -v u="$uid" '$2 == u' <<<"$list" | wc -l)
    (( left == 0 )) || { JF_SIGNOUT_WHY="still signed in on $left of $n device(s)${codes:+ — Jellyfin said:${codes%;}}"; return 1; }
    JF_SIGNED_OUT=$n
}

jellyfin_signout() { # NAME — every Jellyfin sign-in NAME has ends; their password is untouched
    local key admin users uid
    key=$(env_get JELLYFIN_API_KEY)
    [[ -n "$key" ]] || die "no Jellyfin API key in .env — run: ./mediastack.sh wire jellyfin"
    admin=$(env_get JELLYFIN_ADMIN_USER)
    [[ -z "$admin" || "${1,,}" != "${admin,,}" ]] \
        || die "'$1' is the stack's own Jellyfin admin — Seerr and wire sign in as it, so it is never signed out"
    users=$(jf_api GET /Users "$key") || die "jellyfin refused its user list [HTTP $(jf_code)]: $(oneline "$users")"
    uid=$(jq -r --arg n "${1,,}" 'first(.[]? | select((.Name | ascii_downcase) == $n) | .Id) // empty' <<<"$users")
    [[ -n "$uid" ]] || die "jellyfin has no user '$1' (its users: Jellyfin's dashboard → Users)"
    jf_signout_uid "$key" "$uid" "$1" || die "jellyfin: $1 — $JF_SIGNOUT_WHY"
    if (( JF_SIGNED_OUT == 0 )); then ok "jellyfin: $1 is signed in on no device — nothing to sign out"
    else ok "jellyfin: $1 signed out of $JF_SIGNED_OUT device(s) — each goes to sign-in on its next request (an app may spin until reopened)"; fi
}
