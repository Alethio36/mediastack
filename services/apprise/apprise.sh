#!/usr/bin/env bash
# services/apprise/apprise.sh — the `wire apprise` role (sending, routing
# and the `notify` verb: lib/notify.sh).
# Sourced by the entrypoint; relies on lib/wire.sh, lib/addr.sh and the
# entrypoint's helpers at call time.

# ---- apprise: the notification hub (sending, routing, `notify`: lib/notify.sh) ----
# The hub entry each arr (and Prowlarr) keeps is mediastack's — named
# mediastack-apprise — and so is its tag: it decides which stream the events
# reach. An entry made before the ops/users split still says "activity", which
# no hub line carries, so the hub answers 424 and the event is lost. Checked on
# every run like the entry's address; everything else in it stays as you set it.
# Both are saved with forceSave: the app's own test would send a message out to
# your endpoint, and a slow one must not block where mediastack points the
# entry (delivery is what `notify test` checks).
APPRISE_ENTRY_TAGS='["ops"]'
apprise_entry_tag() { # apprise_entry_tag <svc> <api base> <key> <notification list JSON>
    local s="$1" base="$2" key="$3" notes="$4" have entry out
    have=$(arr_entry_field "$notes" mediastack-apprise tags)
    [[ "$have" == "$APPRISE_ENTRY_TAGS" ]] && { ok "$s: its hub entry is tagged ops"; return 0; }
    w_would "$s: re-tag its hub entry ${have:-<none>} -> $APPRISE_ENTRY_TAGS (the stream its events belong to)" || return 0
    # the entry as read, only its tags changed: masked secrets go back as-is
    entry=$(jq -c --argjson t "$APPRISE_ENTRY_TAGS" \
        '[.[]? | select(.name == "mediastack-apprise")][0] | .fields |= map(if .name == "tags" then .value = $t else . end)' <<<"$notes")
    if out=$(api PUT "$base/notification/$(jq -r '.id' <<<"$entry")?forceSave=true" "$key" "$entry"); then
        ok "$s: hub entry re-tagged to ops"
    else
        wfail "$s: re-tagging its hub entry was rejected — $(oneline "$out")"
    fi
}

wire_apprise() {
    hr "wire: apprise"
    svc_enabled apprise || { info "apprise not enabled — skipped"; return 0; }
    wire_gate apprise
    http_ready apprise "$(apprise_url)/status" '^2' || return 1
    wire_arrs_ready || true

    # --- notification endpoints: stored once under key 'mediastack';
    # an existing config is never touched (edit in apprise's UI or re-add)
    code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -X POST "$(apprise_url)/get/mediastack" 2>/dev/null || echo 000)
    if [[ "$code" == 200 ]]; then
        # the URLs are yours (notify set / Apprise's UI); only the event tags on
        # the lines mediastack wrote are kept current, so Seerr's events route
        local cur want
        cur=$(notify_cfg_get); want=$(notify_cfg_edit retag <<<"$cur")
        local t; while IFS= read -r t; do warn "$(notify_legacy_note "$t")"; done < <(notify_legacy_lines <<<"$cur")
        if [[ "$cur" == "$want" ]]; then
            ok "notification endpoints configured, routing current (manage: ./mediastack.sh notify)"
        elif w_would "tag the streams' URLs with the Seerr events each receives (${NOTIFY_EVENTS[users]// /, } -> users, the rest -> ops)"; then
            notify_cfg_put "$want"
            ok "notification routing updated"
        fi
    elif (( WIRE_DRY )); then
        w_would "store notification endpoints (URLs asked per tag on the real run)" || true
    elif [[ ! -t 0 ]]; then
        info "no notification endpoints stored yet — run './mediastack.sh wire apprise' interactively to add them"
    else
        explain "Notifications (Apprise)" \
"One hub, two streams — give each one or more Apprise URLs
(comma-separated), or leave blank to skip a stream:
  ops    you: errors, update pipeline, backups, doctor, requests
  users  household: new media, restarts, updates, invites
Getting a URL:
  Discord   channel -> gear -> Integrations -> Webhooks -> New Webhook
            -> Copy Webhook URL, and paste that https://... URL as-is
  ntfy      pick any unique topic name: ntfy://ntfy.sh/your-topic
            (subscribe to the topic in the ntfy app — zero signup)
  anything  else: https://github.com/caronc/apprise/wiki"
        local ops_u usr_u cfg="" u
        ask AP_OPS "URLs for ops" ""; ops_u="$REPLY_VAL"
        ask AP_USR "URLs for users" ""; usr_u="$REPLY_VAL"
        for u in ${ops_u//,/ }; do cfg+="$(notify_tagline ops)=$u"$'\n'; done
        for u in ${usr_u//,/ }; do cfg+="$(notify_tagline users)=$u"$'\n'; done
        if [[ -z "$cfg" ]]; then
            info "no URLs given — notifications stay off until 'wire apprise' stores some"
        elif w_would "store the notification endpoints under key 'mediastack'"; then
            local resp acode
            resp=$(curl -sS -m 10 -X POST -H "Content-Type: application/json" \
                   -d "$(jq -cn --arg c "$cfg" '{config:$c,format:"text"}')" \
                   -w $'\n%{http_code}' "$(apprise_url)/add/mediastack" 2>&1) \
                || { wfail "apprise unreachable while storing config: $(head -c200 <<<"$resp")"; return 1; }
            acode=${resp##*$'\n'}
            [[ "$acode" =~ ^2 ]] \
                || { wfail "apprise rejected the config [HTTP $acode]: $(head -c200 <<<"${resp%$'\n'*}")
     check the URL syntax against https://github.com/caronc/apprise/wiki"; return 1; }
            ok "notification endpoints stored"
            notify ops "Mediastack" "Notifications are wired up — this is your ops stream." info
            info "a test notification went to the ops stream — check it arrived"
        fi
    fi

    # --- each arr notifies the hub (tag: ops); create-if-missing by
    # name, schema-driven so per-type event flags stay version-proof
    local s ty key url ver have schema tmpl body resp
    for s in $(arr_instances); do
        ty=$(svc_label "$s" mediastack.arrtype)
        arr_known "$ty" || continue
        key=$(arr_key "$s"); url=$(arr_url "$s"); ver=$(arr_apiver "$s")
        [[ -n "$key" ]] || { wfail "$s: no ApiKey readable — re-run wire in a minute"; continue; }
        local notes; notes=$(api GET "$url/api/$ver/notification" "$key") \
            || { wfail "$s: could not read its notifications — nothing created [$(oneline "$notes")]"; continue; }
        have=$(jq -r '[.[].name] | join(" ")' <<<"$notes" 2>/dev/null || true)
        if [[ " $have " == *" mediastack-apprise "* ]]; then
            ok "$s already notifies the hub"
            local nst; nst=$(addr_of "$(arr_entry_field "$notes" mediastack-apprise serverUrl)")
            if addr_stale "$s -> apprise" apprise "$nst"; then
                addr_repoint "$s -> apprise" "$nst" "$(svc_addr apprise)" -- \
                    arr_repoint --force "$url/api/$ver" "$key" notification "$notes" mediastack-apprise "serverUrl=http://$(svc_addr apprise)"
                # the re-point changed the entry: the tag check works from what it is now
                if (( ! WIRE_DRY )); then
                    notes=$(api GET "$url/api/$ver/notification" "$key") \
                        || { wfail "$s: could not re-read its notifications — tag not checked [$(oneline "$notes")]"; continue; }
                fi
            fi
            apprise_entry_tag "$s" "$url/api/$ver" "$key" "$notes"
            continue
        fi
        if ! w_would "$s: notify the hub on grab/import/health (tag: ops)"; then continue; fi
        schema=$(api GET "$url/api/$ver/notification/schema" "$key") \
            || { wfail "$s: could not read its notification types — nothing created [$(oneline "$schema")]"; continue; }
        tmpl=$(jq -c '[.[] | select(.implementation=="Apprise")][0] // empty' <<<"$schema" 2>/dev/null)
        [[ -n "$tmpl" ]] || { wfail "$s: its API offers no Apprise notification type — is the image very old?"; continue; }
        body=$(jq -c --arg srv "http://$(svc_addr apprise)" '
            .name = "mediastack-apprise"
            | .fields = [ .fields[]
                | if .name == "serverUrl"         then .value = $srv
                  elif .name == "configurationKey" then .value = "mediastack"
                  elif .name == "tags"             then .value = ["ops"]
                  else . end ]
            | reduce ("onGrab","onDownload","onUpgrade","onReleaseImport",
                      "onImportComplete","onHealthIssue","onHealthRestored",
                      "onApplicationUpdate") as $k
                (.; if has($k) then .[$k] = true else . end)' <<<"$tmpl")
        resp=$(api POST "$url/api/$ver/notification" "$key" "$body") \
            && ok "$s now notifies the hub" \
            || wfail "$s: notification connection rejected: $(head -c200 <<<"$resp")"
    done
    # prowlarr too — indexer/health events are ops signal
    if svc_enabled prowlarr; then
        key=$(arr_key prowlarr); url=$(arr_url prowlarr); ver=$(arr_apiver prowlarr)
        local pnotes=""
        if ! pnotes=$(api GET "$url/api/$ver/notification" "$key"); then
            wfail "prowlarr: could not read its notifications — nothing created [$(oneline "$pnotes")]"
        elif [[ " $(jq -r '[.[].name] | join(" ")' <<<"$pnotes" 2>/dev/null) " == *" mediastack-apprise "* ]]; then
            ok "prowlarr already notifies the hub"
            local pst pok=1; pst=$(addr_of "$(arr_entry_field "$pnotes" mediastack-apprise serverUrl)")
            if addr_stale "prowlarr -> apprise" apprise "$pst"; then
                addr_repoint "prowlarr -> apprise" "$pst" "$(svc_addr apprise)" -- \
                    arr_repoint --force "$url/api/$ver" "$key" notification "$pnotes" mediastack-apprise "serverUrl=http://$(svc_addr apprise)"
                if (( ! WIRE_DRY )); then
                    pnotes=$(api GET "$url/api/$ver/notification" "$key") \
                        || { wfail "prowlarr: could not re-read its notifications — tag not checked [$(oneline "$pnotes")]"; pok=0; }
                fi
            fi
            if (( pok )); then apprise_entry_tag prowlarr "$url/api/$ver" "$key" "$pnotes"; fi
        elif w_would "prowlarr: notify the hub on indexer/health events (tag: ops)"; then
            schema=$(api GET "$url/api/$ver/notification/schema" "$key" || true)   # soft read: create path only: an empty schema FAILs below, nothing created
            tmpl=$(jq -c '[.[] | select(.implementation=="Apprise")][0] // empty' <<<"$schema" 2>/dev/null)
            if [[ -z "$tmpl" ]]; then
                wfail "prowlarr: its API offers no Apprise notification type — is the image very old?"
            else
                body=$(jq -c --arg srv "http://$(svc_addr apprise)" '
                    .name = "mediastack-apprise"
                    | .fields = [ .fields[]
                        | if .name == "serverUrl"          then .value = $srv
                          elif .name == "configurationKey" then .value = "mediastack"
                          elif .name == "tags"             then .value = ["ops"]
                          else . end ]
                    | reduce ("onHealthIssue","onHealthRestored","onApplicationUpdate") as $k
                        (.; if has($k) then .[$k] = true else . end)' <<<"$tmpl")
                resp=$(api POST "$url/api/$ver/notification" "$key" "$body") \
                    && ok "prowlarr now notifies the hub" \
                    || wfail "prowlarr: notification connection rejected: $(head -c200 <<<"$resp")"
            fi
        fi
    fi
}
