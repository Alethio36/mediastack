#!/usr/bin/env bash
# lib/notify.sh — the notification hub (Apprise, key "mediastack") and the
# `notify` verb. Two streams, each a tag in the hub's configuration:
#   ops    you: errors, the update pipeline, backups, doctor, requests
#   users  the household: new media, restarts, updates
# The stack sends to a stream by its tag (notify ops|users ...). Seerr sends
# every event to the hub tagged with the event's own name (MEDIA_AVAILABLE,
# ISSUE_CREATED, ...); each stream's URLs also carry the names of the events
# that stream receives (NOTIFY_EVENTS), so the hub routes them — nothing
# else decides where a Seerr event goes. Event names are written as Seerr
# sends them (upper case): Apprise versions that lower-case tags do so on
# both sides, older ones compare them as written — either way they match.
#
# The hub itself (sending, its stored configuration, what its answers mean)
# is reached only through the hub interface (hub_*: services/apprise/hub.sh).
#
# Configuration lines mediastack writes look like  ops,MEDIA_PENDING,...=URL.
# A line whose tags are one stream plus event names is mediastack's, and
# `notify set` / `wire apprise` rewrite its tags; any other line (your own
# tags, untagged URLs) is never touched. Each send's outcome is kept per
# stream in local/state/ for `notify status` and doctor.
# What Seerr sends the hub (its agent, its events' bits) is Seerr's:
# services/seerr/hub.sh. Sourced by the entrypoint; relies on lib/common.sh
# and the svc/c_state helpers.

NOTIFY_STREAMS=(ops users)
# which Seerr events each stream receives (Seerr's own names; test -> ops)
declare -A NOTIFY_EVENTS=(
    [users]="MEDIA_AVAILABLE"
    [ops]="MEDIA_PENDING MEDIA_APPROVED MEDIA_AUTO_APPROVED MEDIA_DECLINED MEDIA_FAILED MEDIA_AUTO_REQUESTED ISSUE_CREATED ISSUE_COMMENT ISSUE_RESOLVED ISSUE_REOPENED TEST_NOTIFICATION"
)
NOTIFY_LEGACY_TAGS=(activity) # streams mediastack no longer has

notify_legacy_lines() { # stdin: the stored configuration -> the tags of entries for streams mediastack no longer has (URLs never printed)
    local line tags t
    while IFS= read -r line; do
        if [[ "$line" =~ ^\ {6}-\ tag:\ (.*)$ ]]; then tags=${BASH_REMATCH[1]//,/ }          # YAML
        elif [[ "$line" =~ ^([A-Za-z0-9_\ ,-]+)= ]]; then tags=${BASH_REMATCH[1]//,/ }        # the text format
        else continue; fi
        local -a ta; read -ra ta <<<"$tags"
        for t in "${NOTIFY_LEGACY_TAGS[@]}"; do [[ ${#ta[@]} == 1 && "${ta[0]}" == "$t" ]] && echo "$t"; done
    done
    return 0
}

notify_legacy_note() { # the sentence wire, status and doctor say about a leftover line
    echo "the hub has a URL tagged '$1' — a stream mediastack no longer has (it became ops): nothing is sent to it. Remove that line in Apprise's UI ($(svc_url "$HUB_SVC" 2>/dev/null || echo "port 8000")/cfg/$HUB_KEY)"
}

# ---------------------------------------------------------------- sending --
notify_record() { # notify_record STREAM WHY — keep the latest outcome for status/doctor
    [[ " ${NOTIFY_STREAMS[*]} " == *" $1 "* ]] || return 0
    if [[ -z "$2" ]]; then state_set "notify-$1-ok" "$(date +%s)"
    else state_set "notify-$1-fail" "$(date +%s) $2"; fi
}

NOTIFY_WARNED=0
NOTIFY_TITLE_MAX=240    # characters: Discord's card title takes 256
NOTIFY_BODY_MAX=3800    # characters: its card's text takes 4096 — a longer one would be refused whole
notify() { # notify TAG TITLE BODY [TYPE] — never blocks, never fails the caller; the outcome is recorded
    local tag="$1" title="$2" body="$3" type="${4:-info}" ans why
    (( ${#title} <= NOTIFY_TITLE_MAX )) || title="${title:0:NOTIFY_TITLE_MAX}…"
    (( ${#body} <= NOTIFY_BODY_MAX )) || body="${body:0:NOTIFY_BODY_MAX}"$'\n'"… (cut: the rest is on the host)"
    hub_enabled 2>/dev/null || return 0
    hub_running 2>/dev/null || return 0
    ans=$(hub_send "$tag" "$title" "$body" "$type") || true   # unreachable: judged just below
    why=$(hub_outcome "${ans%%$'\t'*}" "${ans#*$'\t'}")
    notify_record "$tag" "$why"
    [[ -z "$why" ]] && return 0
    if (( ! NOTIFY_WARNED )); then
        warn "notification to '$tag' not delivered: $why (the stack keeps going; ./mediastack.sh notify status)"
        NOTIFY_WARNED=1
    fi
    return 0
}

notify_interruption() { # notify_interruption TITLE BODY [TYPE] — household service-disruption notice
    notify users "$1" "$2" "${3:-warning}"
}

# ------------------------------------------------------- the configuration --
# Stored as Apprise's YAML: per-message values (Seerr's poster) need it. One
# block between two marker lines is mediastack's, rewritten whole from the
# streams' URLs (the model); everything outside it — your own entries — is
# kept as written. A configuration in Apprise's older text format is read too
# (mediastack's lines: one stream plus event names) and written back as YAML,
# your own lines converted entry for entry.
#
# A Discord URL becomes several entries on the same webhook: the stream's own
# messages (tag ops or users) as a card in the message type's colour, and
# Seerr's events, grouped by outcome, as a card with the poster in the group's
# colour (Seerr sends every event as one type). Both through a template of
# mediastack's (services/apprise/discord/), placed where the hub reads it.
# Any other URL is one entry with the stream and its events: Apprise turns the
# markdown into what that service shows.
NOTIFY_MARK_BEGIN="  # >>> mediastack: rewritten by ./mediastack.sh (notify set, wire apprise) — your own entries go outside these two lines"
NOTIFY_MARK_END="  # <<< mediastack"
# the outcome of each Seerr event: its card's colour
declare -A NOTIFY_EVENT_TYPE=(
    [MEDIA_AVAILABLE]=success [MEDIA_APPROVED]=success [MEDIA_AUTO_APPROVED]=success [ISSUE_RESOLVED]=success
    [MEDIA_PENDING]=info [MEDIA_AUTO_REQUESTED]=info [ISSUE_COMMENT]=info [TEST_NOTIFICATION]=info
    [ISSUE_CREATED]=warning [ISSUE_REOPENED]=warning
    [MEDIA_FAILED]=failure [MEDIA_DECLINED]=failure
)
# the poster when Seerr sends none: public (Discord fetches it), in this repository
NOTIFY_NO_POSTER=https://raw.githubusercontent.com/Alethio36/mediastack/stable/services/apprise/assets/no-poster.png
# the event and who when Seerr sends neither: only its own test does
NOTIFY_NO_EVENT=Seerr
NOTIFY_NO_WHO="test"

notify_line_stream() { # notify_line_stream LINE -> the stream when a text-format line is mediastack's (one stream + event names), else nothing
    local tags t s="" known=" ${NOTIFY_STREAMS[*]} ${NOTIFY_EVENTS[*]} "
    [[ "$1" =~ ^([A-Za-z0-9_\ ,-]+)= ]] || return 0
    tags=${BASH_REMATCH[1]//,/ }
    for t in $tags; do
        [[ "$known" == *" $t "* ]] || return 0   # a tag of yours: not mediastack's line
        [[ " ${NOTIFY_STREAMS[*]} " == *" $t "* ]] || continue
        [[ -z "$s" ]] || return 0                # two streams on one line: yours
        s=$t
    done
    echo "$s"
}

notify_url_canon() { # notify_url_canon URL -> a Discord webhook as discord://ID/TOKEN (its other options are mediastack's to set); any other URL as given
    if [[ "$1" =~ ^discord://([^/@?]*@)?([0-9]+)/([^/?\"]+) ]]; then echo "discord://${BASH_REMATCH[2]}/${BASH_REMATCH[3]}"
    elif [[ "$1" =~ ^https://(ptb\.|canary\.)?discord(app)?\.com/api/webhooks/([0-9]+)/([^/?\"]+) ]]; then echo "discord://${BASH_REMATCH[3]}/${BASH_REMATCH[4]}"
    else echo "$1"; fi
}
notify_yaml_q() { local v=${1//\\/\\\\}; printf '"%s"' "${v//\"/\\\"}"; }   # a YAML double-quoted string

NOTIFY_MODEL=""; NOTIFY_YOURS=""; NOTIFY_CFG_WHY=""   # notify_cfg_read's answer
notify_cfg_read() { # notify_cfg_read TEXT — NOTIFY_MODEL ("stream<TAB>url" per line) and NOTIFY_YOURS (your entries, YAML) from the stored configuration; rc 1 with NOTIFY_CFG_WHY
    local line s n=0 in_urls=0 ours=0 url="" tags t
    NOTIFY_MODEL=""; NOTIFY_YOURS=""; NOTIFY_CFG_WHY=""
    if ! grep -qE '^(version|urls):' <<<"$1"; then   # Apprise's text format
        while IFS= read -r line || [[ -n "$line" ]]; do
            n=$((n + 1))
            [[ -n "${line//[[:space:]]/}" ]] || continue
            if [[ "$line" =~ ^[[:space:]]*# ]]; then NOTIFY_YOURS+="  ${line#"${line%%[![:space:]]*}"}"$'\n'; continue; fi
            if [[ "$line" =~ ^[[:space:]]*include[[:space:]] ]]; then
                NOTIFY_CFG_WHY="line $n is an include (${line%% *} …): mediastack cannot carry it into YAML — move it into Apprise's UI, then re-run"; return 1
            fi
            s=$(notify_line_stream "$line")
            if [[ -n "$s" ]]; then notify_model_add "$s" "$(notify_url_canon "${line#*=}")"
            elif [[ "$line" =~ ^([A-Za-z0-9_\ ,-]+)=(.*)$ ]]; then
                tags=$(sed -E 's/[[:space:]]*,[[:space:]]*/, /g; s/^[[:space:]]+|[[:space:]]+$//g' <<<"${BASH_REMATCH[1]}")
                NOTIFY_YOURS+="  - $(notify_yaml_q "${BASH_REMATCH[2]}"):"$'\n'"      - tag: $tags"$'\n'
            else
                NOTIFY_YOURS+="  - $(notify_yaml_q "$line")"$'\n'
            fi
        done <<<"$1"
        return 0
    fi
    # YAML: mediastack's block between the markers, the rest of urls: yours
    grep -qxF -- "$NOTIFY_MARK_BEGIN" <<<"$1" \
        || { NOTIFY_CFG_WHY="the hub's configuration is YAML without mediastack's marker lines — mediastack cannot tell its entries from yours (put the streams back: ./mediastack.sh notify set ops|users)"; return 1; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        if (( ! in_urls )); then [[ "$line" == "urls:" ]] && in_urls=1; continue; fi
        if [[ "$line" == "$NOTIFY_MARK_BEGIN" ]]; then ours=1; continue; fi
        if [[ "$line" == "$NOTIFY_MARK_END" ]]; then ours=0; continue; fi
        if (( ! ours )); then NOTIFY_YOURS+="$line"$'\n'; continue; fi
        if [[ "$line" =~ ^\ \ -\ \"(.*)\":$ ]]; then url=${BASH_REMATCH[1]//\\\"/\"}; url=${url//\\\\/\\}; continue; fi
        [[ "$line" =~ ^\ {6}-\ tag:\ (.*)$ ]] || continue
        tags=" ${BASH_REMATCH[1]//,/ } "
        for t in "${NOTIFY_STREAMS[@]}"; do
            [[ "$tags" == *" $t "* ]] || continue
            if [[ "$url" == discord://* ]]; then notify_model_add "$t" "$(notify_url_canon "$url")"   # its options are mediastack's
            else notify_model_add "$t" "$url"; fi                                                   # any other: as you gave it
        done
    done <<<"$1"
    return 0
}

notify_model_add() { [[ $'\n'"$NOTIFY_MODEL" == *$'\n'"$1"$'\t'"$2"$'\n'* ]] || NOTIFY_MODEL+="$1"$'\t'"$2"$'\n'; }   # notify_model_add STREAM URL — once
notify_stream_events_of() { # notify_stream_events_of STREAM TYPE -> its Seerr events of that outcome, comma-separated ("" for none)
    local e out=""
    for e in ${NOTIFY_EVENTS[$1]}; do [[ "${NOTIFY_EVENT_TYPE[$e]:-info}" != "$2" ]] || out+="${out:+, }$e"; done
    echo "$out"
}
notify_footer() { echo "$(hostname -s 2>/dev/null || echo mediastack) · $1"; }   # notify_footer STREAM -> a card's footer
notify_cfg_render() { # -> the configuration, YAML, from NOTIFY_MODEL and NOTIFY_YOURS
    local s u ty evs foot tdir=/config/$HUB_TEMPLATES_DIR
    [[ -n "${NOTIFY_MODEL//[[:space:]]/}${NOTIFY_YOURS//[[:space:]]/}" ]] || return 0   # nothing left: no configuration (hub_cfg_put removes it)
    printf '%s\n' "# The notification hub's configuration, written by ./mediastack.sh. Your own" \
        "# entries go in urls:, outside mediastack's two marker lines — they are kept." \
        "version: 1" "template:" "  poster: $(notify_yaml_q "$NOTIFY_NO_POSTER")" \
        "  event: $(notify_yaml_q "$NOTIFY_NO_EVENT")" "  who: $(notify_yaml_q "$NOTIFY_NO_WHO")" "urls:" "$NOTIFY_MARK_BEGIN"
    while IFS=$'\t' read -r s u; do
        [[ -n "$s" ]] || continue
        if [[ "$u" == discord://* ]]; then
            foot=$(jq -rn --arg f "$(notify_footer "$s")" '$f | @uri')
            printf '  - %s:\n      - tag: %s\n' "$(notify_yaml_q "$u?avatar=no&template=$tdir/plain.json&:footer=$foot")" "$s"
            for ty in success info warning failure; do
                evs=$(notify_stream_events_of "$s" "$ty"); [[ -n "$evs" ]] || continue
                printf '  - %s:\n      - tag: %s\n' "$(notify_yaml_q "$u?avatar=no&template=$tdir/poster.json&:poster=\${POSTER}&:event=\${EVENT}&:who=\${WHO}&:color=$((16#$(env_get "BRAND_COLOUR_${ty^^}")))&:footer=$foot")" "$evs"
            done
        else
            printf '  - %s:\n      - tag: %s\n' "$(notify_yaml_q "$u")" "$s${NOTIFY_EVENTS[$s]:+, ${NOTIFY_EVENTS[$s]// /, }}"
        fi
    done <<<"$NOTIFY_MODEL"
    printf '%s\n' "$NOTIFY_MARK_END"
    [[ -z "$NOTIFY_YOURS" ]] || printf '%s' "$NOTIFY_YOURS"
}

notify_cfg_edit() { # stdin: the stored configuration; $1 retag|set|clear, $2 STREAM, $3 URLS (set) -> the new one (YAML); dies when it cannot be read
    local mode="$1" stream="${2:-}" urls="${3:-}" u keep="" s
    notify_cfg_read "$(cat)" || die "$NOTIFY_CFG_WHY"
    if [[ "$mode" == set || "$mode" == clear ]]; then
        while IFS=$'\t' read -r s u; do [[ -z "$s" || "$s" == "$stream" ]] || keep+="$s"$'\t'"$u"$'\n'; done <<<"$NOTIFY_MODEL"
        NOTIFY_MODEL=$keep
    fi
    if [[ "$mode" == set ]]; then
        for u in ${urls//,/ }; do NOTIFY_MODEL+="$stream"$'\t'"$(notify_url_canon "$u")"$'\n'; done
    fi
    notify_cfg_render
}

notify_cfg_urls() { # stdin: the stored configuration; $1 STREAM -> that stream's URLs (Discord's as discord://ID/TOKEN)
    notify_cfg_read "$(cat)" || return 0
    awk -F'\t' -v s="$1" '$1 == s { print $2 }' <<<"$NOTIFY_MODEL"
}

notify_url_shown() { # a URL without its secrets: the service, and its host only where that is a plain server name
    local u="$1" scheme rest host
    scheme=${u%%://*}; rest=${u#*://}; host=${rest%%/*}; host=${host##*@}; host=${host%%\?*}
    case "$scheme" in
        http|https|json|jsons|xml|xmls|form|forms|ntfy|ntfys) echo "$scheme${host:+ ($host)}" ;;
        *) echo "$scheme" ;;   # many services keep a token where a host would be — never shown
    esac
}

# ------------------------------------------------------------------- verb --
cmd_notify() {
    local action="${1:-status}"
    (( $# )) && shift
    case "$action" in
        status) (( $# == 0 )) || die "'notify status' takes no arguments"; notify_status ;;
        test)   (( $# <= 1 )) || die "usage: notify test [ops|users]"; notify_test "$@" ;;
        set)    (( $# == 1 )) || die "usage: notify set ops|users"; notify_set "$1" ;;
        clear)  (( $# == 1 )) || die "usage: notify clear ops|users"; notify_clear "$1" ;;
        send)   notify_send_cmd "$@" ;;
        *) die "unknown 'notify' action '$action' (accepts: status, test, set, clear, send)" ;;
    esac
}

notify_need_hub() {
    load_env
    hub_enabled || die "the notification hub ($HUB_SVC) is not enabled — enable it: ./mediastack.sh enable $HUB_SVC"
    hub_running || die "the notification hub ($HUB_SVC) is not running — start it: ./mediastack.sh up"
}

notify_stream_ok() { [[ " ${NOTIFY_STREAMS[*]} " == *" $1 "* ]] || die "unknown stream '$1' (streams: ${NOTIFY_STREAMS[*]})"; }

notify_status() {
    notify_need_hub
    local cfg s u n ok fail
    cfg=$(hub_cfg_get)
    hr "Notifications"
    for s in "${NOTIFY_STREAMS[@]}"; do
        n=0; local shown=""
        while IFS= read -r u; do [[ -n "$u" ]] || continue; n=$((n + 1)); shown+="$(notify_url_shown "$u"), "; done < <(notify_cfg_urls "$s" <<<"$cfg")
        ok=$(state_get "notify-$s-ok"); fail=$(state_get "notify-$s-fail")
        if (( n )); then info "$s: ${shown%, }"; else warn "$s: no URL — set one: ./mediastack.sh notify set $s"; fi
        [[ -n "$ok" ]] && echo "     last delivered: $(printf '%(%F %T)T' "$ok")"
        if [[ -n "$fail" && "${fail%% *}" -gt "${ok:-0}" ]]; then
            warn "     last failure: $(printf '%(%F %T)T' "${fail%% *}") — ${fail#* }"
        fi
    done
    info "Seerr events: ${NOTIFY_EVENTS[users]// /, } -> users; the rest -> ops"
    local t; while IFS= read -r t; do warn "$(notify_legacy_note "$t")"; done < <(notify_legacy_lines <<<"$cfg")
}

notify_test() {
    notify_need_hub
    local s streams=("${NOTIFY_STREAMS[@]}") ans why rc=0
    [[ -n "${1:-}" ]] && { notify_stream_ok "$1"; streams=("$1"); }
    for s in "${streams[@]}"; do
        ans=$(hub_send "$s" "Test on the $s stream" "If you can read this, the **$s** stream works." success) || true   # judged below
        why=$(hub_outcome "${ans%%$'\t'*}" "${ans#*$'\t'}")
        notify_record "$s" "$why"
        if [[ -z "$why" ]]; then ok "$s: the hub delivered the test — check it arrived"
        else fail "$s: $why"; rc=1; fi
    done
    [[ -n "${1:-}" && "$1" != ops ]] || notify_test_apps || rc=1
    return "$rc"
}

notify_test_apps() { # each enabled app that sends to the hub itself asks its own test through: <svc>_notify_test (its folder), on ops
    local s rc=0
    for s in $(svc_enabled_managed); do
        declare -F "${s//-/_}_notify_test" >/dev/null || continue
        "${s//-/_}_notify_test" || rc=1
    done
    return "$rc"
}


notify_urls_ok() { # notify_urls_ok STREAM "URL,URL" — 0 when every entry is one URL; says what it got (masked) or what is wrong
    # the URLs are typed hidden (each is a password), so a doubled or half paste
    # cannot be seen: check its shape, then show its outline (found live: two
    # pastes run together, refused by the hub only when it sent)
    local u bad=0 shown=()
    for u in ${2//,/ }; do
        if [[ ! "$u" =~ ^[A-Za-z][A-Za-z0-9+.-]*://[^[:space:]]+$ ]]; then
            fail "$1: '${u:0:12}…' is not a URL (scheme://…)"; bad=1
        elif [[ "${u#*://}" == *://* ]]; then
            fail "$1: one entry holds two URLs (${u%%://*}://… twice) — a paste ran into another; separate URLs with a comma"; bad=1
        else
            shown+=("$(notify_url_outline "$u")")
        fi
    done
    (( bad )) && return 1
    (( ${#shown[@]} )) && info "$1: ${#shown[@]} URL(s) — ${shown[*]}"
    return 0
}
notify_url_outline() { # notify_url_outline URL -> scheme://host/…last4: enough to recognise, too little to use
    local u=$1 rest host
    rest=${u#*://}; host=${rest%%/*}
    echo "${u%%://*}://${host}/…${u: -4}"
}

notify_set() {
    notify_stream_ok "$1"
    [[ -t 0 ]] || die "notify set is interactive — run it at a terminal."
    notify_need_hub
    explain "Notifications: the $1 stream" \
"Paste one or more Apprise URLs for '$1', comma-separated. They replace the
stream's current URLs; anything else in the hub's configuration is kept.
  Discord   channel -> gear -> Integrations -> Webhooks -> New Webhook
            -> Copy Webhook URL, and paste that https://... URL as-is
  ntfy      ntfy://ntfy.sh/your-topic (subscribe to the topic in the app)
  anything  else: https://github.com/caronc/apprise/wiki"
    while true; do
        ask_token "URLs for $1 (input hidden)" ""
        notify_urls_ok "$1" "$REPLY_VAL" && break
    done
    local cfg; cfg=$(hub_cfg_get | notify_cfg_edit set "$1" "$REPLY_VAL")
    hub_cfg_put "$cfg"
    ok "$1: URLs stored"
    discord_senders_sync
    notify_test "$1"
}

notify_clear() {
    notify_stream_ok "$1"
    notify_need_hub
    confirm "Remove every URL of the '$1' stream? It stops receiving notifications" || { info "Nothing changed."; return 0; }
    hub_cfg_put "$(hub_cfg_get | notify_cfg_edit clear "$1")"
    ok "$1: no URLs — the stream is off (set it again: ./mediastack.sh notify set $1)"
}

notify_send_cmd() { # notify send STREAM TITLE MESSAGE [--type info|success|warning|failure]
    local stream="${1:-}" title="${2:-}" body="${3:-}" type=info
    [[ -n "$stream" && -n "$title" && -n "$body" ]] || die 'usage: notify send ops|users "title" "message" [--type info|success|warning|failure]'
    shift 3
    while (( $# )); do
        case "$1" in
            --type) [[ "${2:-}" =~ ^(info|success|warning|failure)$ ]] || die "--type takes info, success, warning or failure"; type=$2; shift 2 ;;
            *) die "unknown argument '$1' for 'notify send'" ;;
        esac
    done
    notify_stream_ok "$stream"
    notify_need_hub
    local ans why
    ans=$(hub_send "$stream" "$title" "$body" "$type") || true   # judged below
    why=$(hub_outcome "${ans%%$'\t'*}" "${ans#*$'\t'}")
    notify_record "$stream" "$why"
    [[ -z "$why" ]] || die "$stream: not delivered — $why"
    ok "$stream: delivered"
}

# ------------------------------------------------------------------ doctor --
_doctor_notify() {
    hr "doctor: notifications"
    if ! hub_enabled; then info "the notification hub ($HUB_SVC) is off"; return 0; fi
    local s ok fail t cfg
    if hub_running && cfg=$( (hub_cfg_get) 2>/dev/null ); then
        while IFS= read -r t; do warn "$(notify_legacy_note "$t")"; done < <(notify_legacy_lines <<<"$cfg")
    fi
    for s in "${NOTIFY_STREAMS[@]}"; do
        ok=$(state_get "notify-$s-ok"); fail=$(state_get "notify-$s-fail")
        if [[ -n "$fail" && "${fail%% *}" -gt "${ok:-0}" ]]; then
            warn "$s: the last notification failed ($(printf '%(%F %T)T' "${fail%% *}")): ${fail#* } — check: ./mediastack.sh notify test $s"
        elif [[ -n "$ok" ]]; then
            ok "$s: last delivered $(printf '%(%F %T)T' "$ok")"
        else
            info "$s: nothing sent yet (try: ./mediastack.sh notify test $s)"
        fi
    done
    hub_running && _doctor_hub_failures
    return 0
}

NOTIFY_LOG_HOURS=168   # how far back doctor reads the hub's own record of failed sends (a week: some events are rare)
_doctor_hub_failures() { # what the hub could not deliver, whoever sent it — an app posting straight to it is invisible to notify's record
    local out n addr tags who why
    out=$(hub_failed_sends "$NOTIFY_LOG_HOURS") || { warn "hub: $out"; return 0; }
    if [[ -z "$out" ]]; then ok "hub: every send in the last $((NOTIFY_LOG_HOURS / 24)) days was delivered"; return 0; fi
    while read -r n addr tags; do
        who=$(_hub_sender "$addr")
        case " ${NOTIFY_STREAMS[*]} " in
            *" ${tags%%,*} "*) why="its URL(s) refused it — ./mediastack.sh notify test ${tags%%,*}" ;;
            *) why="no stream carries that tag (mediastack's: ${NOTIFY_STREAMS[*]}) — an app mediastack wired still sending an old one is re-pointed by: ./mediastack.sh wire" ;;
        esac
        warn "hub: $n send(s) from $who (tag: ${tags:-none}) not delivered in the last $((NOTIFY_LOG_HOURS / 24)) days: $why"
    done < <(sort <<<"$out" | uniq -c | awk '{ c = $1; sub(/^ *[0-9]+ /, ""); split($0, f, "\t"); print c, f[1], f[2] }')
}
_hub_sender() { # _hub_sender ADDR -> who that is, for people
    local o; o=$(addr_owner "$1")
    case "$o" in
        host) echo "mediastack itself (this host)" ;;
        "")   echo "$1 (nothing on the stack network holds it now)" ;;
        "$(svc_cname gluetun)") echo "the VPN group ($(vpn_group | paste -sd' ' -), all sending as gluetun)" ;;
        *)    echo "$o" ;;
    esac
}
