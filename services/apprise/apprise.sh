#!/usr/bin/env bash
# services/apprise/apprise.sh — the `wire apprise` role (the hub interface:
# hub.sh; streams, routing and the `notify` verb: lib/notify.sh).
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

apprise_brand_apply() { # the kit (lib/brand.sh) reaches the running hub: its colours, mediastack's entries, the Discord senders
    # the colours of mediastack's own messages are the hub's start-up setting
    # (compose.yml): compose recreates it when they changed, and leaves it be when not
    DC up -d --no-deps "$HUB_SVC" >/dev/null || die "the notification hub did not start again — see compose's message above; ./mediastack.sh logs $HUB_SVC"
    http_ready "$HUB_SVC" "$(hub_local_url)/status" '^2' || die "the notification hub did not answer after its restart — ./mediastack.sh logs $HUB_SVC"
    # the colours of Seerr's cards are in mediastack's entries: rewritten from the kit
    local cur want
    cur=$(hub_cfg_get)
    if [[ -z "$cur" ]]; then info "no notification URLs stored yet — the kit applies when you set one: ./mediastack.sh notify set ops"; return 0; fi
    notify_cfg_read "$cur" || die "notifications: $NOTIFY_CFG_WHY"
    want=$(notify_cfg_render)
    if [[ "$cur" != "$want" ]]; then hub_cfg_put "$want"; ok "notification entries updated"; fi
    discord_senders_sync
}

wire_apprise() {
    hr "wire: apprise"
    svc_enabled apprise || { info "apprise not enabled — skipped"; return 0; }
    wire_gate apprise
    http_ready apprise "$(hub_local_url)/status" '^2' || return 0
    wire_arrs_ready || true

    # --- notification endpoints: stored once under key 'mediastack';
    # an existing config is never touched (edit in apprise's UI or re-add)
    code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -X POST "$(hub_local_url)/get/mediastack" 2>/dev/null || echo 000)
    if [[ "$code" == 200 ]]; then
        state_set "$NOTIFY_STORED_STATE" yes   # configure asks no more
        if [[ -n "$(state_get "$NOTIFY_URLS_STATE")" ]]; then
            warn "the URLs configure recorded were not used: the hub already has endpoints (change them: ./mediastack.sh notify set)"
            state_del "$NOTIFY_URLS_STATE"
        fi
        # the URLs are yours (notify set / Apprise's UI); mediastack's block is
        # rewritten from them (Seerr's routing, the cards, a text-format
        # configuration made YAML) and the rest kept as written
        local cur want
        cur=$(hub_cfg_get)
        if ! notify_cfg_read "$cur"; then wfail "notifications: $NOTIFY_CFG_WHY"; return 0; fi
        want=$(notify_cfg_render)
        local t; while IFS= read -r t; do warn "$(notify_legacy_note "$t")"; done < <(notify_legacy_lines <<<"$cur")
        if [[ "$cur" == "$want" ]]; then
            ok "notification endpoints configured, routing current (manage: ./mediastack.sh notify)"
        elif w_would "rewrite mediastack's notification entries: each stream's messages as cards, Seerr's events routed (${NOTIFY_EVENTS[users]// /, } -> users, the rest -> ops) with their posters$(grep -qE '^(version|urls):' <<<"$cur" || echo "; the configuration becomes YAML, your own lines kept")"; then
            hub_cfg_put "$want"
            ok "notification entries updated"
        fi
        if (( ! WIRE_DRY )); then hub_templates_sync; discord_senders_sync; fi
    elif [[ -z "$(state_get "$NOTIFY_URLS_STATE")" ]]; then
        info "no notification URLs to store — ./mediastack.sh configure asks them (or: ./mediastack.sh notify set)"
    else
        # configure's URLs (services/apprise/questions.sh): handed over once, then deleted
        local u s
        NOTIFY_MODEL=""
        # shellcheck disable=SC2034  # read by notify_cfg_render (lib/notify.sh)
        NOTIFY_YOURS=""
        for s in "${NOTIFY_STREAMS[@]}"; do
            for u in $(notify_pending "$s" | tr ',' ' '); do NOTIFY_MODEL+="$s"$'\t'"$(notify_url_canon "$u")"$'\n'; done
        done
        if w_would "store the notification endpoints configure recorded, under key 'mediastack'"; then
            ( hub_cfg_put "$(notify_cfg_render)" ) || { wfail "the hub did not take the endpoints configure recorded (its answer is above) — check the URL syntax against https://github.com/caronc/apprise/wiki"; return 0; }
            ok "notification endpoints stored"
            discord_senders_sync
            state_del "$NOTIFY_URLS_STATE"; state_set "$NOTIFY_STORED_STATE" yes
            notify ops "Notifications are on" "This is your **ops** stream: errors, updates, backups, the VPN and requests. The household's news goes to **users**." success
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
