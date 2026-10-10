#!/usr/bin/env bash
# services/jellyfin/jellyfin.sh — Jellyfin's API client, plugins (LDAP
# sign-in), server name, transcode path and its `wire jellyfin` role.
# Sourced by the entrypoint; relies on lib/wire.sh, lib/addr.sh and the
# entrypoint's helpers at call time.

JF_LDAP_GUID=958aad66-3784-4d2a-b89a-a7b6fab6e25c           # "LDAP Authentication" (jellyfin/jellyfin-plugin-ldapauth)
JF_LDAP_PROVIDER=Jellyfin.Plugin.LDAP_Auth.LdapAuthenticationProviderPlugin   # AuthenticationProviderId of users it created

jf_plugin_ids() { # jf_plugin_ids PLUGINS-JSON -> "|id|id|" (dashes removed, lower case)
    # by ID, not name: a plugin can load under another name than its catalog
    # entry (found live: "LDAP Authentication" loads as "LDAP-Auth")
    jq -r '"|" + ([.[].Id | ascii_downcase | gsub("-"; "")] | join("|")) + "|"' <<<"$1" 2>/dev/null
}
jf_guid() { tr -d '-' <<<"$1" | tr '[:upper:]' '[:lower:]'; }

jf_plugins_ensure() { # jf_plugins_ensure TOKEN "Name|GUID|why"... — install what is missing, then ONE jellyfin restart
    local tok="$1"; shift
    local plist plugins spec name guid why missing=() mguids=()
    plist=$(jf_api GET /Plugins "$tok") \
        || { wfail "could not list jellyfin plugins [HTTP $(jf_code)] — nothing installed, jellyfin not restarted"; return 1; }
    plugins=$(jf_plugin_ids "$plist")
    for spec in "$@"; do
        IFS='|' read -r name guid why <<<"$spec"
        if [[ "$plugins" == *"|$(jf_guid "$guid")|"* ]]; then ok "$name plugin installed"; continue; fi
        w_would "install Jellyfin's $name plugin ($why)" || continue
        jf_api POST "/Packages/Installed/$(jq -rn --arg n "$name" '$n|@uri')?assemblyGuid=$guid" "$tok" >/dev/null \
            || { wfail "$name plugin install rejected [HTTP $(jf_code)] — install it in Dashboard -> Plugins -> Catalog"; return 1; }
        missing+=("$name"); mguids+=("$guid")
    done
    (( ${#missing[@]} )) || return 0
    info "plugin(s) downloaded (${missing[*]}) — restarting jellyfin once to load them..."
    is_user_facing jellyfin && notify_interruption "Jellyfin maintenance" "Jellyfin is restarting briefly for maintenance — back in a moment."
    DC restart jellyfin >/dev/null 2>&1 || { wfail "jellyfin restart failed — restart it, then re-run wire jellyfin"; return 1; }
    jf_ready || return 1
    plist=$(jf_api GET /Plugins "$tok" || true)   # soft read: re-check after the install: empty FAILs below
    plugins=$(jf_plugin_ids "$plist")
    local i rc=0
    for i in "${!missing[@]}"; do
        if [[ "$plugins" == *"|$(jf_guid "${mguids[$i]}")|"* ]]; then ok "${missing[$i]} plugin installed and loaded"
        else wfail "${missing[$i]} plugin not visible after restart — check Dashboard -> Plugins (a repository fetch may have failed)"; rc=1; fi
    done
    return $rc
}

jf_plugin_webhook() { # its consumer is WatchState (the hub hears Seerr, not Jellyfin)
    jf_plugins_ensure "$1" "Webhook|71552A5A-5C5C-4350-A2AE-EBE451A30173|WatchState's webhooks need it"
}

jf_ldap_want() { # the LDAP plugin's settings mediastack manages, as JSON (the rest stay yours)
    local dn=dc=ldap,dc=mediastack host skip=false
    host="$(env_get AUTHENTIK_LDAP_HOST ldap).$(env_get TRAEFIK_DOMAIN)"
    # a staging certificate is not trusted inside Jellyfin: checking waits for production ones
    [[ "$(env_get ACME_ENV production)" == production ]] || skip=true
    jq -cn --arg host "$host" --arg dn "$dn" --arg pw "$(env_get AUTHENTIK_LDAP_BIND_PASSWORD)" --argjson skip "$skip" '{
        LdapServer: $host, LdapPort: 443, UseSsl: true, UseStartTls: false, SkipSslVerify: $skip,
        LdapBindUser: ("cn=mediastack-ldap-search,ou=users," + $dn), LdapBindPassword: $pw,
        LdapBaseDn: $dn, LdapAdminBaseDn: $dn,
        LdapSearchFilter: ("(|(memberOf=cn=media-users,ou=groups," + $dn + ")(memberOf=cn=admins,ou=groups," + $dn + "))"),
        LdapAdminFilter: ("(memberOf=cn=admins,ou=groups," + $dn + ")"),
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
    w_would "point Jellyfin's LDAP plugin at the portal: $(jq -r '.LdapServer' <<<"$want"):443 (LDAPS), media-users and admins may sign in, new users get every library" || return 0
    merged=$(jq -c --argjson w "$want" '. + $w' <<<"$cur")
    jf_api POST "/Plugins/$JF_LDAP_GUID/Configuration" "$tok" "$merged" >/dev/null \
        && ok "LDAP plugin configured — portal accounts sign in to Jellyfin (created on their first sign-in)" \
        || wfail "Jellyfin rejected the LDAP plugin's settings [HTTP $(jf_code)]"
}

jf_admin_sync() { # directory users in authentik's `admins` are Jellyfin administrators; other directory users are not
    # (the plugin sets this only when it creates a user). Local accounts — the
    # stack's own admin above all — are never touched.
    local tok="$1" out admins users u name id pol want
    out=$(ak_api GET "/core/users/?groups_by_name=admins&page_size=500") || { wfail "authentik: admins unreadable — Jellyfin admin rights not synced"; return 1; }
    admins=" $(jq -r '[.results[].username] | join(" ")' <<<"$out") "
    users=$(jf_api GET /Users "$tok") || { wfail "could not list jellyfin users [HTTP $(jf_code)]"; return 1; }
    while IFS= read -r u; do
        [[ -n "$u" ]] || continue
        name=$(jq -r '.Name' <<<"$u"); id=$(jq -r '.Id' <<<"$u")
        want=false; [[ "$admins" == *" $name "* ]] && want=true
        [[ "$(jq -r '.Policy.IsAdministrator' <<<"$u")" == "$want" ]] && continue
        w_would "Jellyfin: $name $( [[ $want == true ]] && echo "becomes an administrator (in admins)" || echo "is no longer an administrator (not in admins)")" || continue
        pol=$(jq -c --argjson w "$want" '.Policy | .IsAdministrator = $w' <<<"$u")
        jf_api POST "/Users/$id/Policy" "$tok" "$pol" >/dev/null && ok "Jellyfin: $name administrator = $want" \
            || wfail "Jellyfin rejected $name's admin change [HTTP $(jf_code)]"
    done < <(jq -c --arg p "$JF_LDAP_PROVIDER" '.[] | select(.Policy.AuthenticationProviderId == $p)' <<<"$users")
    return 0
}

jf_ldap() { # with the portal: Jellyfin checks passwords against it (LDAP), admin rights follow `admins`
    local tok="$1"
    svc_enabled authentik || return 0
    [[ -n "$(env_get AUTHENTIK_LDAP_TOKEN)" ]] || { info "the portal's LDAP outpost has no token yet — run 'wire authentik' first, then 'wire jellyfin'"; return 0; }
    jf_plugins_ensure "$tok" "LDAP Authentication|$JF_LDAP_GUID|portal accounts sign in to Jellyfin" || return 1
    (( WIRE_DRY )) && ! jf_api GET "/Plugins/$JF_LDAP_GUID/Configuration" "$tok" >/dev/null && return 0   # not installed yet: nothing to compare
    jf_ldap_configure "$tok" || return 1
    jf_admin_sync "$tok"
}

jf_server_name() { # the name apps/casting show; container default is the ID hash
    local tok="$1" cfg have want
    cfg=$(jf_api GET /System/Configuration "$tok" || true)   # soft read: a failed read shows as a change; the write that follows fails loud
    have=$(jq -r '.ServerName // empty' <<<"$cfg" 2>/dev/null)
    if [[ -n "$have" && ! "$have" =~ ^[0-9a-f]{12}$ ]]; then
        ok "server name '$have'"
        return 0
    fi
    if (( WIRE_DRY )); then w_would "name the Jellyfin server (asked on the real run)" || true; return 0; fi
    [[ -t 0 ]] || { info "server name still the container ID — run 'wire jellyfin' interactively to set it"; return 0; }
    ask JF_SRVNAME "Server name (shows in Jellyfin apps and casting)" "Jellyfin"
    want="$REPLY_VAL"
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
    cfg=$(jf_api GET /System/Configuration/encoding "$tok" || true)   # soft read: a failed read shows as a change; the write that follows fails loud
    [[ "$(jf_code)" =~ ^2 ]] || { wfail "could not read jellyfin's encoding settings [HTTP $(jf_code)]: $(head -c200 <<<"$cfg")"; return 1; }
    have=$(jq -r '.TranscodingTempPath // empty' <<<"$cfg" 2>/dev/null)
    if [[ "$have" == "$JF_TRANSCODE_PATH" ]]; then ok "transcodes go to $JF_TRANSCODE_PATH (the cache volume)"; return 0; fi
    w_would "point jellyfin's transcodes at $JF_TRANSCODE_PATH (now: ${have:-the default, /config/data/transcodes})" || return 0
    jf_api POST /System/Configuration/encoding "$tok" "$(jq -c --arg p "$JF_TRANSCODE_PATH" '.TranscodingTempPath=$p' <<<"$cfg")" >/dev/null \
        && ok "transcodes now go to $JF_TRANSCODE_PATH" \
        || wfail "Jellyfin rejected the transcode path [HTTP $(jf_code)] — set Dashboard -> Playback -> Transcoding -> Transcode path to $JF_TRANSCODE_PATH"
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
    if ! out=$(curl -sS -m 20 -X "$m" -H "$(jf_auth_hdr "$tok")" \
          -H "Content-Type: application/json" \
          ${b:+-d "$b"} -w $'\n%{http_code}' "$(jf_url)$p" 2>&1); then
        printf '000' > "$JF_CODE_F"; echo "$out"; return 1
    fi
    code=${out##*$'\n'}; printf '%s' "$code" > "$JF_CODE_F"
    echo "${out%$'\n'*}"
    [[ "$code" =~ ^2 ]]
}
jf_ready() { http_ready jellyfin "$(jf_url)/health" '^200$'; }
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
    jf_ready || return 1
    local pub completed juser jpass
    pub=$(jf_api GET /System/Info/Public "" || true)   # soft read: checked two lines below
    # NB: jq's // operator treats false as missing — read booleans plainly
    completed=$(jq -r '.StartupWizardCompleted' <<<"$pub" 2>/dev/null)
    [[ "$completed" == true || "$completed" == false ]] \
        || { wfail "jellyfin gave no readable public info [HTTP $(jf_code)]: $(head -c200 <<<"$pub")"; return 1; }
    juser=$(env_get JELLYFIN_ADMIN_USER); jpass=$(env_get JELLYFIN_ADMIN_PASSWORD)

    # --- first-run wizard: only ever runs while jellyfin says it is unclaimed.
    # This also closes a real hole: an unconfigured jellyfin lets ANY visitor
    # create the admin account.
    if [[ "$completed" == false ]]; then
        if [[ -z "$juser" || -z "$jpass" ]]; then
            if (( WIRE_DRY )); then
                w_would "complete jellyfin's first-run wizard (admin login asked on the real run)" || true
            elif [[ ! -t 0 ]]; then
                wfail "jellyfin's first-run wizard is incomplete and there is no terminal to ask for the admin login — run './mediastack.sh wire jellyfin' interactively"
                return 1
            else
                explain "Jellyfin admin" \
"Jellyfin needs one administrator account. This is the operator/recovery
login (it also signs in to Seerr as its owner) — your household gets
their own accounts later via invites. Everything else about Jellyfin
(look, libraries' settings, users) stays yours to manage in its GUI;
wire only performs this minimum first-run. Stored in .env (view:
credentials)."
                ask JF_U "Admin username" "${juser:-admin}"; juser="$REPLY_VAL"
                ask_secret "Admin password" "$(head -c12 /dev/urandom | base64 | tr -d '=+/')"; jpass="$REPLY_VAL"
                env_set JELLYFIN_ADMIN_USER "$juser"; env_set JELLYFIN_ADMIN_PASSWORD "$jpass"
            fi
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
                esac || { wfail "jellyfin wizard step '$step' rejected [HTTP $(jf_code)]: $(head -c200 <<<"$out")"; return 1; }
            done
            ok "first-run wizard completed — admin '$juser'"
        fi
    else
        ok "first-run wizard already completed"
    fi

    # --- everything below needs an admin session
    if [[ -z "$juser" || -z "$jpass" ]]; then
        if (( WIRE_DRY )); then
            info "library/API-key previews pend on the admin login — created earlier in the same real run"
        else
            info "jellyfin was configured outside wire and no JELLYFIN_ADMIN_USER/PASSWORD is in .env — libraries and the stack API key stay manual (set them in .env to let wire manage those)"
        fi
        return 0
    fi
    local auth tok
    auth=$(jf_api POST /Users/AuthenticateByName "" "$(jq -cn --arg u "$juser" --arg p "$jpass" '{Username:$u,Pw:$p}')") \
        || { (( WIRE_DRY )) && { info "cannot verify further without logging in — real run continues from here"; return 0; }
             wfail "jellyfin rejected the admin login from .env [HTTP $(jf_code)]: $(head -c200 <<<"$auth")"; return 1; }
    tok=$(jq -r '.AccessToken // empty' <<<"$auth")
    [[ -n "$tok" ]] || { wfail "jellyfin login succeeded but returned no token: $(head -c200 <<<"$auth")"; return 1; }
    jf_server_name "$tok"
    jf_transcode_path "$tok"
    jf_plugin_webhook "$tok"
    jf_ldap "$tok"

    # --- libraries: create-if-path-missing, derived from the arrs' own
    # rootfolder labels. Match by the HOST directory a library's location
    # resolves to through the container's mounts, not by the container path:
    # a migrated jellyfin sees the same tree under an alias (an extra mount
    # in the override, e.g. /data/tvshows) and must not be offered a twin
    # at /media/tv. GUI renames/merges are respected the same way.
    local vf droot jcn; vf=$(jf_api GET /Library/VirtualFolders "$tok" || true)   # soft read: checked on the next line
    [[ "$(jf_code)" =~ ^2 ]] || { wfail "could not list jellyfin libraries [HTTP $(jf_code)]: $(head -c200 <<<"$vf")"; return 1; }
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
        if (( WIRE_DRY )); then
            w_would "create jellyfin library for $path (${ctype}; name asked on the real run)" || true
            continue
        fi
        if [[ ! -t 0 ]]; then
            info "$path has no library yet — creation asks for a name, so it only happens interactively: ./mediastack.sh wire jellyfin"
            continue
        fi
        # jellyfin sees /media read-only; the host dir must exist or the
        # library is born broken. Same ownership pattern as configure's tree.
        sudo test -d "$droot/media/$base" \
            || { sudo install -d -m 2775 -g mediacenter "$droot/media/$base" && info "created $droot/media/$base (was missing)"; }
        ask JF_LN "Library name for $path" "$(jf_libname "$s" "$base")"; lname="$REPLY_VAL"
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
        || { wfail "could not list jellyfin API keys [HTTP $(jf_code)] — nothing created"; return 1; }
    have=$(jq -r '.Items[]? | select(.AppName=="mediastack") | .AccessToken' <<<"$keys" 2>/dev/null | head -1)
    if [[ -n "$have" ]]; then
        [[ "$(env_get JELLYFIN_API_KEY)" == "$have" ]] || env_set JELLYFIN_API_KEY "$have"
        ok "stack API key present"
    elif w_would "mint a jellyfin API key for the stack (app 'mediastack')"; then
        jf_api POST "/Auth/Keys?app=mediastack" "$tok" >/dev/null \
            || { wfail "API key creation rejected [HTTP $(jf_code)]"; return 1; }
        keys=$(jf_api GET /Auth/Keys "$tok" || true)   # soft read: re-read after creating the key: empty FAILs below
        have=$(jq -r '.Items[]? | select(.AppName=="mediastack") | .AccessToken' <<<"$keys" 2>/dev/null | head -1)
        [[ -n "$have" ]] || { wfail "API key created but not readable back — check Dashboard -> API Keys"; return 1; }
        env_set JELLYFIN_API_KEY "$have"
        ok "stack API key minted and stored (JELLYFIN_API_KEY)"
    fi
}
