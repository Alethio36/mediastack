#!/usr/bin/env bash
# services/_arr/arr.sh — the arr family (radarr, radarr-4k, sonarr,
# sonarr-anime, lidarr): one implementation for every instance — API client,
# per-type facts (ARR_META), login, readiness and the `wire arr` role. The
# instances themselves are compose-only: services/<instance>/compose.yml.
# Sourced by the entrypoint; relies on lib/wire.sh, lib/addr.sh and the
# entrypoint's helpers at call time.

arr_key() { # arr_key <svc> -> api key from its config.xml ("" while initialising)
    sudo grep -oP '<ApiKey>\K[^<]+' "$(env_get CONFIG_ROOT)/$1/config.xml" 2>/dev/null | head -1 || true
}

arr_url() { local p; p=$(svc_hostport "$1") || return 1; echo "http://127.0.0.1:$p"; }

arr_repoint() { # arr_repoint [--force] <api base> <key> <resource> <list JSON> <entry name> field=value...
    # PUT the entry back with just those fields changed. Secrets the API masked
    # on GET ("********") go back as-is and the app keeps its stored value — the
    # same round trip its own UI does (Servarr SchemaBuilder.ReadFromSchema).
    # --force saves without the app's own connection test (forceSave): for an
    # entry whose test reaches past the stack (a notification), so a slow
    # outside service cannot block a change of where mediastack points it.
    local q=""; [[ "${1:-}" == --force ]] && { q="?forceSave=true"; shift; }
    local base="$1" key="$2" res="$3" list="$4" name="$5" kv entry; shift 5
    entry=$(jq -c --arg n "$name" '[.[]? | select(.name == $n)][0] // empty' <<<"$list")
    [[ -n "$entry" ]] || { echo "entry '$name' is gone"; return 1; }
    for kv in "$@"; do
        entry=$(jq -c --arg f "${kv%%=*}" --arg v "${kv#*=}" \
            '.fields |= map(if .name == $f then .value = (if (.value | type) == "number" then ($v | tonumber) else $v end) else . end)' <<<"$entry")
    done
    api PUT "$base/$res/$(jq -r '.id' <<<"$entry")$q" "$key" "$entry"
}
arr_entry_enable() { # arr_entry_enable <api base> <key> <resource> <list JSON> <entry name> true|false
    # PUT the entry back with only .enable changed; switching one off skips the
    # app's own connection test (forceSave) — the client may well be gone
    local entry q=""; [[ "$6" == false ]] && q="?forceSave=true"
    entry=$(jq -c --arg n "$5" --argjson on "$6" '[.[]? | select(.name == $n)][0] // empty | .enable = $on' <<<"$4")
    [[ -n "$entry" ]] || { echo "entry '$5' is gone"; return 1; }
    api PUT "$1/$3/$(jq -r '.id' <<<"$entry")$q" "$2" "$entry"
}
arr_entry_fields() { # arr_entry_fields <list JSON> <entry name> -> "field=value" lines
    jq -r --arg n "$2" '.[]? | select(.name == $n) | .fields[]? | "\(.name)=\(.value // "" | tostring)"' <<<"$1" 2>/dev/null || true
}
arr_entry_field() { # arr_entry_field <list JSON> <entry name> <field> -> value
    arr_entry_fields "$1" "$2" | sed -n "s/^$3=//p" | head -1
}
# ARR_META — every per-type fact wire needs, one row per arr type, so a new
# type (readarr, whisparr) is a row here instead of a hunt through recipes.
#   api       API version path            impl      Prowlarr implementation name
#   catfield  download-client category    major     app major (cleanuparr's "version")
#   jftype    Jellyfin collection type    jfname    default Jellyfin library name
declare -A ARR_META=(
    [sonarr.api]=v3  [sonarr.impl]=Sonarr [sonarr.catfield]=tvCategory    [sonarr.major]=4 [sonarr.jftype]=tvshows [sonarr.jfname]="TV Shows"
    [radarr.api]=v3  [radarr.impl]=Radarr [radarr.catfield]=movieCategory [radarr.major]=6 [radarr.jftype]=movies  [radarr.jfname]=Movies
    [lidarr.api]=v1  [lidarr.impl]=Lidarr [lidarr.catfield]=musicCategory [lidarr.major]=3 [lidarr.jftype]=music   [lidarr.jfname]=Music
)
arr_known() { [[ -n "${ARR_META[${1:-?}.api]:-}" ]]; }   # arr_known TYPE — a type wire supports
arr_meta() { # arr_meta TYPE FIELD — dies loud on a gap: a wrong default here is a silent misconfig
    local v="${ARR_META[${1:-?}.$2]:-}"
    [[ -n "$v" ]] || die "arr type '${1:-<none>}' has no '$2' in ARR_META (services/_arr/arr.sh)"
    echo "$v"
}
arr_apiver() { # prowlarr speaks v1; every arr instance its type's version
    [[ "$1" == prowlarr ]] && { echo v1; return; }
    arr_meta "$(svc_label "$1" mediastack.arrtype)" api
}

arr_pretty_name() { # sonarr-anime -> "Sonarr (Anime)", radarr-4k -> "Radarr (4K)"
    local s="$1" ty suffix
    ty=$(svc_label "$s" mediastack.arrtype)
    suffix=${s#"$ty"}; suffix=${suffix#-}
    case "$suffix" in
        "")    echo "${ty^}" ;;
        4k)    echo "${ty^} (4K)" ;;
        anime) echo "${ty^} (Anime)" ;;
        *)     echo "${ty^} (${suffix^})" ;;
    esac
}

arr_instance_name() { # brand the instance so notifications are tellable apart;
                      # only replaces the stock default — a custom name is yours
    local s="$1" key ep cur have want
    key=$(arr_key "$s"); [[ -n "$key" ]] || return 0
    ep="$(arr_url "$s")/api/$(arr_apiver "$s")/config/host"
    cur=$(api GET "$ep" "$key" || true)   # soft read: a failed read shows as a change; the write that follows fails loud
    have=$(jq -r '.instanceName // empty' <<<"$cur" 2>/dev/null)
    want=$(arr_pretty_name "$s")
    # one-off (stays inline, not an ensure_field concern): a custom name — non-empty,
    # different from what we'd set, and not the stock lowercase default — is the
    # operator's, so never touch it. Must check "!= want" first so a correctly
    # branded instance (e.g. "Radarr (4K)") reads as already-set, not custom.
    if [[ -n "$have" && "$have" != "$want" && "${have,,}" != "$(svc_label "$s" mediastack.arrtype)" ]]; then
        ok "$s: instance name '$have' (custom) — untouched"; return 0
    fi
    ensure_field "$s" "$ep" "$key" "$cur" instanceName "$want" "instance name"
}

arr_login() { # the arr's own login: "external" (trust the gate) when gate_trusted, the shared forms login otherwise
    local s="$1" key url cur
    gate_trusted "$s" || { arr_forms_login "$s"; return; }
    key=$(arr_key "$s"); [[ -n "$key" ]] || return 0
    url=$(arr_url "$s")
    cur=$(api GET "$url/api/$(arr_apiver "$s")/config/host" "$key" || true)   # soft read: a failed read shows as a change; the write that follows fails loud
    local match=no
    jq -e '.authenticationMethod == "external"' <<<"$cur" >/dev/null 2>&1 && match=yes
    # external: the arr trusts what is in front of it — the portal; its API
    # still demands the API key (companion apps reach /api past the gate)
    ensure_resource "$match" "$s: trust the portal (one login) — reachable only through it" \
        "$s: trusts the portal" "$s: could not switch to trusting the portal — check: logs $s" \
        -- api PUT "$url/api/$(arr_apiver "$s")/config/host" "$key" "$(jq -c '.authenticationMethod="external"' <<<"$cur")"
}

arr_forms_login() { # shared operator login on an arr-family UI; idempotent
    local s="$1" auser apass key url cur body verb=enable match=no
    [[ "${2:-}" == force ]] && verb=rotate
    auser=$(env_get ARR_USER); apass=$(env_get ARR_PASSWORD)
    [[ -n "$auser" && -n "$apass" ]] || { info "$s: shared arr login not set yet — 'wire arr' creates it"; return 0; }
    key=$(arr_key "$s"); [[ -n "$key" ]] || return 0
    url=$(arr_url "$s")
    cur=$(api GET "$url/api/$(arr_apiver "$s")/config/host" "$key" || true)   # soft read: a failed read shows as a change; the write that follows fails loud
    # match on the readable subset (the password is write-only); a forced
    # rotate never matches — one-off, stays inline
    [[ "${2:-}" != force ]] && jq -e --arg u "$auser" '.authenticationMethod=="forms" and .username==$u' <<<"$cur" >/dev/null 2>&1 && match=yes
    body=$(jq -c --arg u "$auser" --arg p "$apass" \
        '.authenticationMethod="forms" | .authenticationRequired="enabled"
         | .username=$u | .password=$p | .passwordConfirmation=$p' <<<"$cur")
    ensure_resource "$match" "$s: $verb forms login for '$auser'" \
        "$s: forms login already set for '$auser'" "$s: auth setup rejected by the API — set it once in its UI; check: logs $s" \
        -- api PUT "$url/api/$(arr_apiver "$s")/config/host" "$key" "$body"
}

# container "running" is not API "ready" — after a cold restart the arrs
# answer errors for a few seconds. Poll each instance before touching it.
arr_api_ready() { # arr_api_ready <svc> <shared-deadline-epoch> -> 0 ready
    local key; key=$(arr_key "$1")
    [[ -n "$key" ]] || { wfail "$1: no API key readable from its config — is it initialised? (./mediastack.sh wire arr)"; return 1; }
    http_ready --until "$2" "$1" "$(arr_url "$1")/api/$(arr_apiver "$1")/system/status" '^200$' -H "X-Api-Key: $key"
}
wire_arrs_ready() { # every arr-family API answering before a role reads or writes it
    # `up` runs roles right after recreating the VPN group, when the containers
    # run (wire_gate passes) but their APIs still refuse — and a refused read
    # must never look like "nothing configured". One shared budget; remembered
    # for the rest of this run.
    (( WIRE_ARRS_OK )) && return 0
    local s deadline=$(( $(date +%s) + API_WAIT )) rc=0
    for s in $(arr_instances) $(svc_enabled prowlarr && echo prowlarr); do
        arr_api_ready "$s" "$deadline" || rc=1
    done
    (( rc )) || WIRE_ARRS_OK=1
    return $rc
}

# shellcheck disable=SC2120  # type argument is optional by design
arr_instances() { # arr_instances [type] -> enabled arr services (optionally by type)
    local s t
    for s in $(svc_enabled_managed); do
        t=$(svc_label "$s" mediastack.arrtype)
        [[ -n "$t" ]] || continue
        [[ -z "${1:-}" || "$t" == "$1" ]] || continue
        echo "$s"
    done
}

# ---- arr root folders + download client ----
wire_arr() {
    hr "wire: arr instances (root folders + download client + recycle bin)"
    local insts; insts=$(arr_instances)
    [[ -n "$insts" ]] || { info "no arr instances enabled"; return 0; }
    wire_gate $insts
    wire_arrs_ready || true
    local recycle_ok=1   # the bin's placement is checked once, before any arr
    if recycle_on; then recycle_prepare || recycle_ok=0; fi
    # --- arr login (the first-run "authentication required" gate) ---
    local auser apass
    auser=$(env_get ARR_USER); apass=$(env_get ARR_PASSWORD)
    if [[ -z "$auser" || -z "$apass" ]]; then
        if (( WIRE_DRY )); then
            w_would "set one shared login on every arr instance (the first-run auth gate)" || true
        else
            explain "Arr login" \
"The arrs refuse to serve their UI until an authentication method and
login are set. One login is used for ALL instances (they share one
operator). Stored in .env (view: credentials)."
            ask ARR_U "Username" "${auser:-admin}"; auser="$REPLY_VAL"
            ask_secret "Password" "$(head -c12 /dev/urandom | base64 | tr -d '=+/')"; apass="$REPLY_VAL"
            env_set ARR_USER "$auser"; env_set ARR_PASSWORD "$apass"
        fi
    fi
    # the download client: the one the role picks (DOWNLOAD_CLIENT, else the
    # first enabled in priority order — lib/roles.sh); the others' entries
    # mediastack made are switched off, never deleted
    local dl miss
    dl=$(role_pick download-client)
    role_pick_note download-client
    if [[ -n "$dl" ]]; then
        miss=$(role_env_missing "$dl" download-client arr | paste -sd' ' -)
        if [[ -n "$miss" ]]; then
            if (( WIRE_DRY )); then
                info "$dl: download-client previews pend on its credentials ($miss) — they're created earlier in the same real run"
            else
                warn "$dl credentials not set ($miss; scoped run?) — download-client wiring skipped; a full 'wire' sets them"
            fi
            dl=""
        fi
    fi
    local s key url root t catfield cat cur
    for s in $insts; do
        key=$(arr_key "$s")
        [[ -n "$key" ]] || { wfail "$s: no ApiKey in config.xml yet (still initialising?) — re-run wire in a minute"; continue; }
        url=$(arr_url "$s"); root=$(svc_label "$s" mediastack.rootfolder)
        # authentication — its own forms login, or trusting the portal (gate_trusted)
        arr_login "$s"
        arr_instance_name "$s"
        (( recycle_ok )) && arr_recycle "$s" "$url" "$key"
        # root folder
        t=$(svc_label "$s" mediastack.arrtype)
        cur=$(api GET "$url/api/$(arr_apiver "$s")/rootfolder" "$key") \
            || { wfail "$s: could not read its root folders — nothing created [$(oneline "$cur")]"; continue; }
        local rexists=no; grep -q "\"path\":\"$root\"" <<<"${cur//[[:space:]]/}" && rexists=yes
        local rbody
        if [[ "$t" == lidarr ]]; then
            # lidarr root folders carry library defaults (unlike sonarr/radarr);
            # profile IDs 1 = the built-in Standard profiles on a fresh install
            rbody="{\"name\":\"Music\",\"path\":\"$root\",\"defaultMetadataProfileId\":1,\"defaultQualityProfileId\":1,\"defaultMonitorOption\":\"all\",\"defaultTags\":[]}"
        else
            rbody="{\"path\":\"$root\"}"
        fi
        ensure_resource "$rexists" "$s: register root folder $root" \
            "$s: root folder $root registered" "$s: root folder rejected" \
            -- api POST "$url/api/$(arr_apiver "$s")/rootfolder" "$key" "$rbody"
        # the download client, with this arr's category
        [[ -n "$dl" ]] || continue
        cat=$(svc_label "$s" mediastack.category)
        catfield=$(arr_meta "$t" catfield)
        local base; base="$url/api/$(arr_apiver "$s")"
        cur=$(api GET "$base/downloadclient" "$key") \
            || { wfail "$s: could not read its download clients — nothing created [$(oneline "$cur")]"; continue; }
        local e name disp dexists dbody p other out
        e=$(role_entry "$dl" download-client arr); name=$(jq -r '.name' <<<"$e"); disp=$(jq -r '.implementationName' <<<"$e")
        dexists=no; [[ -n "$(jq -r --arg n "$name" '.[]? | select(.name == $n) | .id' <<<"$cur")" ]] && dexists=yes
        dbody=$(jq -c --arg cf "$catfield" --arg cat "$cat" '{enable: true, protocol, priority,
            removeCompletedDownloads, removeFailedDownloads, name, implementation, implementationName, configContract,
            fields: ([.fields | to_entries[] | {name: .key, value}] + [{name: $cf, value: $cat}])}' <<<"$e")
        if [[ "$dexists" == yes ]]; then
            local dst; dst="$(arr_entry_field "$cur" "$name" host):$(arr_entry_field "$cur" "$name" port)"
            if addr_stale "$s -> $dl" "$dl" "$dst"; then
                local -a login; mapfile -t login < <(role_login_fields "$cur" "$name" "$e")
                addr_repoint "$s -> $dl" "$dst" "$(svc_addr "$dl")" -- \
                    arr_repoint "$base" "$key" downloadclient "$cur" "$name" \
                    "host=$(svc_host "$dl")" "port=$(svc_cport "$dl")" "${login[@]}"
                # the re-point changed the entry: what follows works from what it is now
                if (( ! WIRE_DRY )); then
                    cur=$(api GET "$base/downloadclient" "$key") \
                        || { wfail "$s: could not re-read its download clients [$(oneline "$cur")]"; continue; }
                fi
            fi
            if [[ "$(jq -r --arg n "$name" '.[]? | select(.name == $n) | .enable' <<<"$cur")" == false ]] \
                && w_would "$s: switch $disp back on — it is the download client"; then
                out=$(arr_entry_enable "$base" "$key" downloadclient "$cur" "$name" true) \
                    && ok "$s: $disp switched back on" || wfail "$s: switching $disp back on was rejected — $(oneline "$out")"
            fi
        fi
        ensure_resource "$dexists" "$s: register $disp (category $cat)" \
            "$s: download client $disp registered" "$s: download client $disp registration failed — check: logs $s" \
            -- api POST "$base/downloadclient" "$key" "$dbody"
        for p in $(role_all_providers download-client arr); do
            [[ "$p" == "$dl" ]] && continue
            other=$(role_entry_name "$p" download-client arr)
            [[ "$(jq -r --arg n "$other" '.[]? | select(.name == $n) | .enable' <<<"$cur")" == true ]] || continue
            w_would "$s: switch off '$other' — the download client is $dl" || continue
            out=$(arr_entry_enable "$base" "$key" downloadclient "$cur" "$other" false) \
                && ok "$s: '$other' switched off (kept, not deleted)" || wfail "$s: switching off '$other' was rejected — $(oneline "$out")"
        done
    done
}

sc_rotate_arr() { # USER PASS — every arr-family app + cleanuparr follows
        local user="$1" pass="$2" olduser oldpass s
        olduser=$(env_get ARR_USER); oldpass=$(env_get ARR_PASSWORD)
        env_set ARR_USER "$user"; env_set ARR_PASSWORD "$pass"
        for s in $(arr_instances) prowlarr; do
            svc_enabled "$s" || continue
            arr_forms_login "$s" force   # the new password is stored either way (the login it falls back to)
            arr_login "$s"               # and, behind the portal, it goes back to trusting it
        done
        if svc_enabled cleanuparr && [[ "$(c_state "$(svc_cname cleanuparr)")" == running ]]; then
            local lout ltok
            lout=$(cup_api POST /auth/login "" "$(jq -cn --arg u "$olduser" --arg p "$oldpass" '{username:$u,password:$p}')" || true)
            ltok=$(jq -r '.tokens.accessToken // empty' <<<"$lout" 2>/dev/null)
            if [[ -n "$ltok" ]]; then
                cup_api PUT /account/password "Authorization: Bearer $ltok" \
                    "$(jq -cn --arg c "$oldpass" --arg n "$pass" '{currentPassword:$c,newPassword:$n}')" >/dev/null \
                    && ok "cleanuparr account password rotated in step" \
                    || warn "cleanuparr refused the password change [HTTP $(cup_code)] — change it in its UI (login: '$olduser' + the OLD password)"
            else
                warn "could not sign in to cleanuparr with the previous login — rotate its password in its UI"
            fi
            [[ "$user" != "$olduser" ]] && warn "cleanuparr's username stays '$olduser' (no API to change it)"
        fi
        ok "arr login rotated — view: ./mediastack.sh credentials"
}
