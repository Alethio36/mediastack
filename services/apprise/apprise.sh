#!/usr/bin/env bash
# services/apprise/apprise.sh — the `wire apprise` role (the hub interface:
# hub.sh; streams, routing and the `notify` verb: lib/notify.sh).
# Sourced by the entrypoint; relies on lib/wire.sh, lib/addr.sh and the
# entrypoint's helpers at call time.

# ---- apprise: the notification hub (sending, routing, `notify`: lib/notify.sh) ----
# The hub entries each arr (and Prowlarr) keeps are mediastack's, by name, and
# so are their tag (the stream their events reach: an entry made before the
# ops/users split said "activity", which no hub line carries — 424, the event
# lost), their Apprise type and which events each sends. The app sends every
# event of an entry as that entry's one type (Servarr's Apprise.cs: one
# NotificationType per entry), and the type is the card's colour: a single
# entry made "Health Check Failure" a blue info card (seen 24 Nov 2026). So
# three: the news (info), a health check failing (failure — only errors: its
# "include health warnings" stays off) and one restored (success). Checked on
# every run like their address; every other setting in them stays as you set
# it. Saved with forceSave: the app's own test would send a message out to
# your endpoint, and a slow one must not block where mediastack points them
# (delivery is what `notify test` checks).
APPRISE_ENTRY_TAGS='["ops"]'
APPRISE_TYPES=(info success warning failure)   # Servarr's AppriseNotificationType: the select's values 0-3, in order
APPRISE_ARR_ENTRIES=(   # name<TAB>type<TAB>events ("-": the app's news events, given per app)
    "mediastack-apprise"$'\t'"info"$'\t'"-"
    "mediastack-apprise-health"$'\t'"failure"$'\t'"onHealthIssue"
    "mediastack-apprise-restored"$'\t'"success"$'\t'"onHealthRestored"
)
APPRISE_ARR_NEWS="onGrab onDownload onUpgrade onReleaseImport onImportComplete onApplicationUpdate"   # an arr's
APPRISE_PROWLARR_NEWS="onApplicationUpdate"                                                         # Prowlarr's

apprise_type_num() { local i; for i in "${!APPRISE_TYPES[@]}"; do [[ "${APPRISE_TYPES[$i]}" == "$1" ]] && { echo "$i"; return 0; }; done; return 1; }

apprise_entry_want() { # apprise_entry_want ENTRY-JSON NAME TYPE "EVENTS" "ALL-EVENTS" -> the entry as mediastack wants it: its name, tag and type, and of the hub's events exactly its own on
    jq -c --arg n "$2" --argjson ty "$(apprise_type_num "$3")" --argjson t "$APPRISE_ENTRY_TAGS" --arg on "$4" --arg all "$5" '
        ($on | split(" ")) as $on | ($all | split(" ")) as $all
        | .name = $n
        | .fields = [ .fields[] | if .name == "tags" then .value = $t elif .name == "notificationType" then .value = $ty else . end ]
        | reduce $all[] as $k (.; if has($k) then .[$k] = ($on | index($k) != null) else . end)' <<<"$1"
}
apprise_entry_drift() { # apprise_entry_drift HAVE-JSON WANT-JSON "ALL-EVENTS" -> what differs, in words ("" when nothing)
    [[ -n "$1" && -n "$2" ]] || return 0
    jq -rn --argjson h "$1" --argjson w "$2" --arg all "$3" '
        def f($e; $n): [$e.fields[]? | select(.name == $n) | .value][0];
        ["info","success","warning","failure"] as $ty
        | [ (if f($h; "tags") != f($w; "tags") then "re-tag \(f($h; "tags") // [] | tojson) -> \(f($w; "tags") | tojson)" else empty end),
            (if f($h; "notificationType") != f($w; "notificationType") then "type \($ty[f($h; "notificationType") // 0] // "?") -> \($ty[f($w; "notificationType")])" else empty end),
            ([$all | split(" ")[] | . as $k | select($w | has($k)) | select($h[$k] != $w[$k]) | "\(.) \(if $w[.] then "on" else "off" end)"] | if length > 0 then join(", ") else empty end)
          ] | join("; ")'
}
apprise_entry_typed() { # apprise_entry_typed SVC ENTRY-JSON — its Apprise form has the type field; else a failure, never "current" (nothing to set would differ from nothing)
    jq -e '[.fields[]? | select(.name == "notificationType")] | length > 0' <<<"$2" >/dev/null 2>&1 && return 0
    wfail "$1: its Apprise form has no notification type — its health messages cannot take their colour (an older $1?)"
    return 1
}
apprise_entry_sync() { # apprise_entry_sync SVC API-BASE KEY LIST-JSON NAME TYPE "EVENTS" "ALL-EVENTS" — an existing entry made what mediastack wants: tag, type, events
    local s="$1" base="$2" key="$3" name="$5" have want drift out
    have=$(jq -c --arg n "$name" '[.[]? | select(.name == $n)][0]' <<<"$4")
    apprise_entry_typed "$s" "$have" || return 0
    want=$(apprise_entry_want "$have" "$name" "$6" "$7" "$8")
    drift=$(apprise_entry_drift "$have" "$want" "$8")
    [[ -n "$drift" ]] || { ok "$s: its hub entry $name is current ($6)"; return 0; }
    w_would "$s: its hub entry $name: $drift" || return 0
    # the entry as read, only those changed: masked secrets go back as-is
    if out=$(api PUT "$base/notification/$(jq -r '.id' <<<"$have")?forceSave=true" "$key" "$want"); then
        ok "$s: its hub entry $name: $drift"
    else
        wfail "$s: its hub entry $name was refused ($drift) — $(oneline "$out")"
    fi
}

apprise_arr_hub() { # apprise_arr_hub SVC "NEWS-EVENTS" — the app's hub entries (APPRISE_ARR_ENTRIES): re-pointed, made current, made when missing
    local s="$1" news="$2" key url ver notes row name type evs all have schema="" tmpl body resp st
    key=$(arr_key "$s"); url=$(arr_url "$s"); ver=$(arr_apiver "$s")
    [[ -n "$key" ]] || { wfail "$s: no ApiKey readable — re-run wire in a minute"; return 0; }
    notes=$(api GET "$url/api/$ver/notification" "$key") \
        || { wfail "$s: could not read its notifications — nothing created [$(oneline "$notes")]"; return 0; }
    all="$news onHealthIssue onHealthRestored"
    for row in "${APPRISE_ARR_ENTRIES[@]}"; do
        IFS=$'\t' read -r name type evs <<<"$row"
        [[ "$evs" != - ]] || evs=$news
        have=$(jq -r '[.[].name] | join(" ")' <<<"$notes" 2>/dev/null || true)
        if [[ " $have " == *" $name "* ]]; then
            st=$(addr_of "$(arr_entry_field "$notes" "$name" serverUrl)")
            if addr_stale "$s -> apprise" apprise "$st"; then
                addr_repoint "$s -> apprise" "$st" "$(svc_addr apprise)" -- \
                    arr_repoint --force "$url/api/$ver" "$key" notification "$notes" "$name" "serverUrl=http://$(svc_addr apprise)"
                # the re-point changed the entry: the rest is checked against what it is now
                if (( ! WIRE_DRY )); then
                    notes=$(api GET "$url/api/$ver/notification" "$key") \
                        || { wfail "$s: could not re-read its notifications — its hub entries not checked [$(oneline "$notes")]"; return 0; }
                fi
            fi
            apprise_entry_sync "$s" "$url/api/$ver" "$key" "$notes" "$name" "$type" "$evs" "$all"
            continue
        fi
        w_would "$s: notify the hub of ${evs// /, } as $type (entry $name, tag ops)" || continue
        if [[ -z "$schema" ]]; then
            schema=$(api GET "$url/api/$ver/notification/schema" "$key") \
                || { wfail "$s: could not read its notification types — nothing created [$(oneline "$schema")]"; return 0; }
        fi
        tmpl=$(jq -c '[.[] | select(.implementation=="Apprise")][0] // empty' <<<"$schema" 2>/dev/null)
        [[ -n "$tmpl" ]] || { wfail "$s: its API offers no Apprise notification type — is the image very old?"; return 0; }
        apprise_entry_typed "$s" "$tmpl" || return 0
        body=$(apprise_entry_want "$tmpl" "$name" "$type" "$evs" "$all" | jq -c --arg srv "http://$(svc_addr apprise)" '
            .fields = [ .fields[] | if .name == "serverUrl" then .value = $srv elif .name == "configurationKey" then .value = "mediastack" else . end ]')
        resp=$(api POST "$url/api/$ver/notification" "$key" "$body") \
            && ok "$s now notifies the hub of ${evs// /, } ($type)" \
            || wfail "$s: notification connection $name rejected: $(head -c200 <<<"$resp")"
    done
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

    # --- each arr, and Prowlarr, notifies the hub (tag: ops): its three entries
    local s ty
    for s in $(arr_instances); do
        ty=$(svc_label "$s" mediastack.arrtype)
        arr_known "$ty" || continue
        apprise_arr_hub "$s" "$APPRISE_ARR_NEWS"
    done
    # prowlarr too — indexer/health events are ops signal
    if svc_enabled prowlarr; then apprise_arr_hub prowlarr "$APPRISE_PROWLARR_NEWS"; fi
}
