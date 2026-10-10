#!/usr/bin/env bash
# services/seerr/seerr.sh — Seerr's API client and its `wire seerr` role.
# Sourced by the entrypoint; relies on lib/wire.sh, lib/addr.sh and the
# entrypoint's helpers at call time.

# ---- seerr (wave 4) ----
# Seerr federates auth to jellyfin (users sign in with their jellyfin logins;
# no seerr-local passwords exist here). Wire bootstraps an UNINITIALISED
# seerr only: first sign-in as the jellyfin admin (which creates seerr's
# owner), library sync + enable, one server entry per arr, initialise. An
# initialised seerr is never touched — its settings are GUI territory.
seerr_url() { local p; p=$(svc_hostport seerr) || return 1; echo "http://127.0.0.1:$p"; }
SEERR_CODE_F="${TMPDIR:-/tmp}/.mediastack-seerr-code.$$"
seerr_code() { cat "$SEERR_CODE_F" 2>/dev/null || echo 000; }
seerr_api() { # seerr_api METHOD PATH JAR [json-body] -> body; rc = http 2xx
    local m="$1" p="$2" jar="$3" b="${4:-}" out code
    if ! out=$(curl -sS -m 30 -X "$m" -b "$jar" -c "$jar" -H "Content-Type: application/json" \
          ${b:+-d "$b"} -w $'\n%{http_code}' "$(seerr_url)/api/v1$p" 2>&1); then
        printf '000' > "$SEERR_CODE_F"; echo "$out"; return 1
    fi
    code=${out##*$'\n'}; printf '%s' "$code" > "$SEERR_CODE_F"
    echo "${out%$'\n'*}"
    [[ "$code" =~ ^2 ]]
}

wire_seerr() {
    hr "wire: seerr"
    svc_enabled seerr || { info "seerr not enabled — skipped"; return 0; }
    svc_enabled jellyfin || { wfail "seerr is enabled but jellyfin is not — seerr cannot function without it"; return 1; }
    wire_gate seerr jellyfin
    # /settings/public, not /status: /status asks GitHub for the latest release
    # on every call, so without outbound DNS it outlasts the probe (seen live:
    # EAI_AGAIN on api.github.com, HTTP 000 for 90s on a healthy seerr)
    http_ready seerr "$(seerr_url)/api/v1/settings/public" '^200$' || return 1
    local jar pub
    jar=$(mktemp)
    pub=$(seerr_api GET /settings/public "$jar" || true)   # soft read: unread = uninitialised: the hostname re-send below is handled as already configured
    local seerr_initialized=false
    [[ "$(jq -r '.initialized' <<<"$pub" 2>/dev/null)" == true ]] && seerr_initialized=true
    local juser jpass
    juser=$(env_get JELLYFIN_ADMIN_USER); jpass=$(env_get JELLYFIN_ADMIN_PASSWORD)
    if [[ -z "$juser" || -z "$jpass" ]]; then
        if (( WIRE_DRY )); then
            w_would "bootstrap seerr (sign in as the jellyfin admin, sync + enable libraries, add the arrs, initialise)" || true
        else
            wfail "seerr bootstrap needs the jellyfin admin login — run 'wire jellyfin' first (a full 'wire' does both in order)"
        fi
        rm -f "$jar"; return 0
    fi
    if $seerr_initialized; then
        # initialised = its settings are yours; wire only CREATES missing arr
        # entries (matched by name), mirroring the jellyfin library contract
        if ! w_would "verify seerr's arr entries (create missing only — nothing existing is touched)"; then rm -f "$jar"; return 0; fi
    else
        if ! w_would "bootstrap seerr: jellyfin sign-in ('$juser'), libraries, arr servers, initialise"; then rm -f "$jar"; return 0; fi
    fi

    # the API demands the hostname iff seerr does not have one yet: a prior
    # partial bootstrap leaves it stored, and re-sending it is a hard 500
    local jfport out
    jfport=$(svc_label jellyfin mediastack.port)
    out=$(seerr_api POST /auth/jellyfin "$jar" "$(jq -cn --arg u "$juser" --arg p "$jpass" --arg h "$(svc_host jellyfin)" --argjson port "$jfport" \
          '{username:$u,password:$p,hostname:$h,port:$port,useSsl:false,urlBase:"",serverType:2}')") || {
        if grep -q "already configured" <<<"$out"; then
            $seerr_initialized || info "seerr already holds the jellyfin hostname (earlier attempt) — signing in without it"
            out=$(seerr_api POST /auth/jellyfin "$jar" "$(jq -cn --arg u "$juser" --arg p "$jpass" \
                  '{username:$u,password:$p,serverType:2}')") \
                || { wfail "seerr rejected the jellyfin sign-in [HTTP $(seerr_code)]: $(head -c200 <<<"$out")"; rm -f "$jar"; return 1; }
        else
            wfail "seerr rejected the jellyfin sign-in [HTTP $(seerr_code)]: $(head -c200 <<<"$out")"; rm -f "$jar"; return 1
        fi
    }
    ok "signed in — seerr owner is jellyfin admin '$juser'"

    if ! $seerr_initialized; then
    # v3.4.1 API: ?sync=true fetches from jellyfin and returns the list;
    # ?enable=<csv-ids> declares the complete enabled set in one call
    local libs ids n
    libs=$(seerr_api GET "/settings/jellyfin/library?sync=true" "$jar") \
        || { wfail "library sync failed [HTTP $(seerr_code)]: $(head -c200 <<<"$libs")"; rm -f "$jar"; return 1; }
    ids=$(jq -r '[.[].id] | join(",")' <<<"$libs" 2>/dev/null)
    [[ -n "$ids" ]] || { wfail "seerr returned no libraries from jellyfin — are the libraries created? re-run 'wire jellyfin' first: $(head -c200 <<<"$libs")"; rm -f "$jar"; return 1; }
    libs=$(seerr_api GET "/settings/jellyfin/library?enable=$ids" "$jar") \
        || { wfail "enabling libraries failed [HTTP $(seerr_code)]: $(head -c200 <<<"$libs")"; rm -f "$jar"; return 1; }
    n=$(jq '[.[] | select(.enabled)] | length' <<<"$libs" 2>/dev/null)
    ok "libraries synced — ${n:-0} enabled"
    fi

    # one server entry per arr instance, connection details straight from the
    # stack's own labels/keys. The arrs live in gluetun's network namespace,
    # so 'gluetun' is their in-network hostname. Existing entries (matched by
    # name) are never touched — create-if-missing only.
    local have_radarr have_sonarr set_radarr set_sonarr
    wire_arrs_ready || true
    set_radarr=$(seerr_api GET /settings/radarr "$jar") \
        || { wfail "seerr: could not read its radarr servers — nothing created [HTTP $(seerr_code)]"; rm -f "$jar"; return 1; }
    set_sonarr=$(seerr_api GET /settings/sonarr "$jar") \
        || { wfail "seerr: could not read its sonarr servers — nothing created [HTTP $(seerr_code)]"; rm -f "$jar"; return 1; }
    have_radarr=$(jq -r '[.[].name] | join(" ")' <<<"$set_radarr" 2>/dev/null || true)
    have_sonarr=$(jq -r '[.[].name] | join(" ")' <<<"$set_sonarr" 2>/dev/null || true)
    local s ty key port root profs pid pname body ep is4k
    for s in $(arr_instances); do
        ty=$(svc_label "$s" mediastack.arrtype)
        [[ "$ty" == radarr || "$ty" == sonarr ]] || { info "$s: seerr does not manage $ty — skipped"; continue; }
        if [[ "$ty" == radarr && " $have_radarr " == *" $s "* ]] || [[ "$ty" == sonarr && " $have_sonarr " == *" $s "* ]]; then
            ok "$s already in seerr — untouched (yours to manage in the GUI)"
            local sset sentry sst
            if [[ "$ty" == radarr ]]; then sset=$set_radarr; else sset=$set_sonarr; fi
            sentry=$(jq -c --arg n "$s" '[.[]? | select(.name == $n)][0] // empty' <<<"$sset")
            sst="$(jq -r '.hostname // ""' <<<"$sentry"):$(jq -r '.port // ""' <<<"$sentry")"
            if addr_stale "seerr -> $s" "$s" "$sst"; then
                addr_repoint "seerr -> $s" "$sst" "$(svc_addr "$s")" -- \
                    seerr_api PUT "/settings/$ty/$(jq -r '.id' <<<"$sentry")" "$jar" \
                    "$(jq -c --arg h "$(svc_host "$s")" --argjson p "$(svc_cport "$s")" '.hostname = $h | .port = $p' <<<"$sentry")"
            fi
            continue
        fi
        key=$(arr_key "$s"); port=$(svc_label "$s" mediastack.port); root=$(svc_label "$s" mediastack.rootfolder)
        [[ -n "$key" ]] || { wfail "$s: no ApiKey readable — is it initialised? re-run wire in a minute"; continue; }
        profs=$(api GET "$(arr_url "$s")/api/$(arr_apiver "$s")/qualityprofile" "$key" || true)   # soft read: empty FAILs below: that seerr entry is skipped
        pid=$(jq -r --arg n "$(env_get "TRASH_PROFILE_$(uvar "$s")")" \
              '(map(select(.name==$n)) + .)[0].id // empty' <<<"$profs" 2>/dev/null)
        pname=$(jq -r --arg n "$(env_get "TRASH_PROFILE_$(uvar "$s")")" \
              '(map(select(.name==$n)) + .)[0].name // empty' <<<"$profs" 2>/dev/null)
        [[ -n "$pid" ]] || { wfail "$s: could not read a quality profile from its API — seerr entry skipped"; continue; }
        is4k=false; [[ "$s" == *-4k ]] && is4k=true
        body=$(jq -cn --arg name "$s" --argjson port "$port" --arg key "$key" \
                     --argjson pid "$pid" --arg pname "$pname" --arg root "$root" --argjson is4k "$is4k" \
                     --arg host "$(svc_host "$s")" \
              '{name:$name,hostname:$host,port:$port,apiKey:$key,useSsl:false,baseUrl:"",
                activeProfileId:$pid,activeProfileName:$pname,activeDirectory:$root,
                tags:[],is4k:$is4k,isDefault:true,syncEnabled:true,preventSearch:false,
                tagRequests:false,overrideRule:[]}')
        ep="/settings/$ty"
        [[ "$ty" == radarr ]] && body=$(jq -c '. + {minimumAvailability:"released"}' <<<"$body")
        [[ "$ty" == sonarr ]] && body=$(jq -c '. + {enableSeasonFolders:true}' <<<"$body")
        # seerr's default server per type: the base instance, or the 4K one
        # (4K has its own default slot); any other extra instance is opt-in
        [[ "$s" == "$ty" || "$is4k" == true ]] || body=$(jq -c '. + {isDefault:false}' <<<"$body")
        out=$(seerr_api POST "$ep/test" "$jar" "$body") \
            || { wfail "$s: seerr could not reach it [HTTP $(seerr_code)]: $(head -c200 <<<"$out")"; continue; }
        out=$(seerr_api POST "$ep" "$jar" "$body") \
            && ok "$s added to seerr (profile '$pname'${is4k:+, 4k=$is4k})" \
            || wfail "$s: seerr rejected the server entry [HTTP $(seerr_code)]: $(head -c200 <<<"$out")"
    done

    # request/media/issue events -> the hub, each tagged with its own event
    # name so the hub routes it to its stream (lib/notify.sh: NOTIFY_EVENTS).
    # An agent mediastack made is kept current (the one from before per-event
    # routing is upgraded); one edited in Seerr's UI is left alone — except
    # its address, when mediastack made it and a VPN toggle moved apprise.
    if svc_enabled apprise && [[ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST "$(apprise_url)/get/mediastack" 2>/dev/null || echo 000)" == 200 ]]; then
        local wh want_t hub next
        want_t=$(seerr_hub_types); hub="http://$(svc_addr apprise)/notify/mediastack"
        if ! wh=$(seerr_api GET /settings/notifications/webhook "$jar"); then
            wfail "seerr: could not read its webhook settings — left as they are [HTTP $(seerr_code)]"
        elif [[ "$(jq -r '.enabled' <<<"$wh" 2>/dev/null)" == true ]]; then
            next=$(seerr_agent_next "$wh")
            case "$next" in
                same)  ok "seerr sends its events to the hub, routed per stream" ;;
                yours) ok "seerr's webhook agent has a template set in its UI — untouched (per-stream routing needs the tag {{notification_type}})" ;;
                *)     if w_would "seerr: route its events per stream (${NOTIFY_EVENTS[users]// /, } -> users, the rest -> ops) — the events it has on and its poster setting stay as they are"; then
                           out=$(seerr_api POST /settings/notifications/webhook "$jar" "$next") \
                               && { ok "seerr's events now route per stream"; wh=$next; } \
                               || wfail "seerr rejected the updated webhook agent [HTTP $(seerr_code)]: $(head -c200 <<<"$out")"
                       fi ;;
            esac
            local wst; wst=$(addr_of "$(jq -r '.options.webhookUrl // ""' <<<"$wh")")
            if addr_stale "seerr -> apprise" apprise "$wst"; then
                addr_repoint "seerr -> apprise" "$wst" "$(svc_addr apprise)" -- \
                    seerr_api POST /settings/notifications/webhook "$jar" \
                    "$(jq -c --arg u "$hub" '.options.webhookUrl = $u' <<<"$wh")"
            fi
        elif w_would "notify the hub on requests, availability and issues, routed per stream"; then
            out=$(seerr_api POST /settings/notifications/webhook "$jar" "$(jq -cn --arg u "$hub" --arg p "$SEERR_HUB_PAYLOAD" --argjson t "$want_t" '
                {enabled:true, embedPoster:false, types:$t,
                 options:{webhookUrl:$u, authHeader:"", jsonPayload:$p}}')") \
                && ok "seerr now notifies the hub" \
                || wfail "seerr rejected the webhook agent [HTTP $(seerr_code)]: $(head -c200 <<<"$out")"
        fi
    fi
    if $seerr_initialized; then
        rm -f "$jar"
        ok "seerr arr entries verified"
        return 0
    fi
    out=$(seerr_api POST /settings/initialize "$jar") \
        || { wfail "seerr initialise call failed [HTTP $(seerr_code)]: $(head -c200 <<<"$out")"; rm -f "$jar"; return 1; }
    local skey
    skey=$(seerr_api GET /settings/main "$jar" | jq -r '.apiKey // empty' 2>/dev/null || true)   # soft read: optional: stored only when read
    [[ -n "$skey" ]] && env_set SEERR_API_KEY "$skey"
    rm -f "$jar"
    ok "seerr initialised — users sign in with their jellyfin logins"
}
