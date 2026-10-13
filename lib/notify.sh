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
# Sourced by the entrypoint; relies on lib/common.sh, the svc/c_state helpers
# and, for Seerr's own test, SEERR_API_KEY at call time.

NOTIFY_STREAMS=(ops users)
# which Seerr events each stream receives (Seerr's own names; test -> ops)
declare -A NOTIFY_EVENTS=(
    [users]="MEDIA_AVAILABLE"
    [ops]="MEDIA_PENDING MEDIA_APPROVED MEDIA_AUTO_APPROVED MEDIA_DECLINED MEDIA_FAILED MEDIA_AUTO_REQUESTED ISSUE_CREATED ISSUE_COMMENT ISSUE_RESOLVED ISSUE_REOPENED TEST_NOTIFICATION"
)
# Seerr's bit per event (server/lib/notifications/index.ts); the agent's
# "types" is their sum — every event but the test, which is always sent
declare -A SEERR_EVENT_BIT=(
    [MEDIA_PENDING]=2 [MEDIA_APPROVED]=4 [MEDIA_AVAILABLE]=8 [MEDIA_FAILED]=16
    [MEDIA_DECLINED]=64 [MEDIA_AUTO_APPROVED]=128 [ISSUE_CREATED]=256 [ISSUE_COMMENT]=512
    [ISSUE_RESOLVED]=1024 [ISSUE_REOPENED]=2048 [MEDIA_AUTO_REQUESTED]=4096
)
# the payload Seerr sends: its own wording, the event name as the tag
# shellcheck disable=SC2034  # these three are read by wire_seerr (services/seerr/seerr.sh)
SEERR_HUB_PAYLOAD='{"title":"Seerr","body":"{{event}}\n{{subject}}\n{{message}}","tag":"{{notification_type}}","type":"info"}'
# every template wire seerr wrote before (tag "activity", the stream before
# ops; then "ops"): a template mediastack wrote is mediastack's to update —
# the events turned on and the poster setting stay whoever set them
SEERR_HUB_PAYLOADS_BEFORE=(
    '{"title":"Seerr","body":"{{event}}\n{{subject}}\n{{message}}","tag":"activity","type":"info"}'
    '{"title":"Seerr","body":"{{event}}\n{{subject}}\n{{message}}","tag":"ops","type":"info"}'
)
SEERR_HUB_TYPES_BEFORE=222   # the events every earlier version turned on
NOTIFY_LEGACY_TAGS=(activity) # streams mediastack no longer has


seerr_agent_next() { # seerr_agent_next AGENT-JSON -> the agent as it should be; "same" when current; "yours" when not mediastack's
    local have_p have_t want_t p mine=0
    have_p=$(jq -r '.options.jsonPayload // ""' <<<"$1"); have_t=$(jq -r '.types // 0' <<<"$1")
    want_t=$(seerr_hub_types)
    [[ "$have_p" == "$SEERR_HUB_PAYLOAD" ]] && mine=1
    for p in "${SEERR_HUB_PAYLOADS_BEFORE[@]}"; do [[ "$have_p" == "$p" ]] && mine=1; done
    (( mine )) || { echo yours; return 0; }
    # the template is mediastack's; the events turned on stay as set, unless
    # still the old default — then the current one (it adds the issue events)
    [[ "$have_t" == "$SEERR_HUB_TYPES_BEFORE" ]] && have_t=$want_t
    if [[ "$have_p" == "$SEERR_HUB_PAYLOAD" && "$have_t" == "$(jq -r '.types // 0' <<<"$1")" ]]; then echo same; return 0; fi
    jq -c --arg p "$SEERR_HUB_PAYLOAD" --argjson t "$have_t" '.types = $t | .options.jsonPayload = $p' <<<"$1"
}

notify_legacy_lines() { # stdin: config text -> the tags of lines for streams mediastack no longer has (URLs never printed)
    local line tags t
    while IFS= read -r line; do
        [[ "$line" =~ ^([A-Za-z0-9_\ ,-]+)= ]] || continue
        tags=${BASH_REMATCH[1]//,/ }
        for t in "${NOTIFY_LEGACY_TAGS[@]}"; do [[ " $tags " == " $t " ]] && echo "$t"; done
    done
    return 0
}

notify_legacy_note() { # the sentence wire, status and doctor say about a leftover line
    echo "the hub has a URL tagged '$1' — a stream mediastack no longer has (it became ops): nothing is sent to it. Remove that line in Apprise's UI ($(svc_url "$HUB_SVC" 2>/dev/null || echo "port 8000")/cfg/$HUB_KEY)"
}

seerr_hub_types() { # the agent's types: every routed event's bit, summed
    local e n=0
    for e in "${!SEERR_EVENT_BIT[@]}"; do n=$(( n + SEERR_EVENT_BIT[$e] )); done
    echo "$n"
}

notify_tagline() { # notify_tagline STREAM -> the tags mediastack writes on that stream's URLs
    local t; t="$1 ${NOTIFY_EVENTS[$1]}"; echo "${t// /,}"
}

# ---------------------------------------------------------------- sending --
notify_record() { # notify_record STREAM WHY — keep the latest outcome for status/doctor
    [[ " ${NOTIFY_STREAMS[*]} " == *" $1 "* ]] || return 0
    if [[ -z "$2" ]]; then state_set "notify-$1-ok" "$(date +%s)"
    else state_set "notify-$1-fail" "$(date +%s) $2"; fi
}

NOTIFY_WARNED=0
notify() { # notify TAG TITLE BODY [TYPE] — never blocks, never fails the caller; the outcome is recorded
    local tag="$1" title="$2" body="$3" type="${4:-info}" ans why
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
notify_line_stream() { # notify_line_stream LINE -> the stream when the line is mediastack's (one stream + event names), else nothing
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

notify_cfg_edit() { # stdin: config text; $1 retag|set|clear, $2 STREAM, $3 URLS (set) -> the new text
    local mode="$1" stream="${2:-}" urls="${3:-}" line s u
    while IFS= read -r line || [[ -n "$line" ]]; do
        s=$(notify_line_stream "$line")
        if [[ -z "$s" ]]; then printf '%s\n' "$line"; continue; fi
        case "$mode" in
            retag) printf '%s=%s\n' "$(notify_tagline "$s")" "${line#*=}" ;;
            set|clear) [[ "$s" == "$stream" ]] || printf '%s=%s\n' "$(notify_tagline "$s")" "${line#*=}" ;;
        esac
    done
    if [[ "$mode" == set ]]; then
        for u in ${urls//,/ }; do printf '%s=%s\n' "$(notify_tagline "$stream")" "$u"; done
    fi
}

notify_cfg_urls() { # stdin: config text; $1 STREAM -> that stream's URLs (every line carrying its tag)
    local line tags
    while IFS= read -r line; do
        [[ "$line" =~ ^([A-Za-z0-9_\ ,-]+)=(.*)$ ]] || continue
        tags=" ${BASH_REMATCH[1]//,/ } "
        [[ "$tags" == *" $1 "* ]] && printf '%s\n' "${BASH_REMATCH[2]}"
    done
    return 0
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
        ans=$(hub_send "$s" "Mediastack test" "A test on the $s stream — if you can read this, it works." info) || true   # judged below
        why=$(hub_outcome "${ans%%$'\t'*}" "${ans#*$'\t'}")
        notify_record "$s" "$why"
        if [[ -z "$why" ]]; then ok "$s: the hub delivered the test — check it arrived"
        else fail "$s: $why"; rc=1; fi
    done
    [[ -n "${1:-}" && "$1" != ops ]] || notify_test_seerr || rc=1
    return "$rc"
}

notify_test_seerr() { # ask Seerr to send its own test through its hub agent: proves Seerr -> hub -> ops
    svc_enabled seerr && [[ "$(c_state "$(svc_cname seerr)")" == running ]] || return 0
    local key cur out code
    key=$(env_get SEERR_API_KEY)
    [[ -n "$key" ]] || { info "seerr: no API key stored yet (wire seerr) — its test skipped"; return 0; }
    cur=$(curl -sS -m 10 -H "X-Api-Key: $key" "$(seerr_url)/api/v1/settings/notifications/webhook" 2>&1) \
        || { fail "seerr: unreachable — $(oneline "$cur")"; return 1; }
    jq -e '.enabled' <<<"$cur" >/dev/null 2>&1 || { info "seerr: its hub agent is off — its test skipped (wire seerr sets it up)"; return 0; }
    out=$(curl -sS -m 20 -X POST -H "X-Api-Key: $key" -H "Content-Type: application/json" -d "$cur" \
          -w $'\n%{http_code}' "$(seerr_url)/api/v1/settings/notifications/webhook/test" 2>&1) || true   # judged by its code
    code=${out##*$'\n'}
    if [[ "$code" =~ ^2 ]]; then ok "seerr: sent its own test through the hub — it should arrive on ops (the route Seerr's events take)"
    else fail "seerr: its test failed [HTTP $code]: $(oneline "${out%$'\n'*}")"; return 1; fi
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
    ask_token "URLs for $1" ""
    local cfg; cfg=$(hub_cfg_get | notify_cfg_edit set "$1" "$REPLY_VAL")
    hub_cfg_put "$cfg"
    ok "$1: URLs stored"
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
    return 0
}
