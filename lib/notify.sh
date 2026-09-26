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
# Configuration lines mediastack writes look like  ops,MEDIA_PENDING,...=URL.
# A line whose tags are one stream plus event names is mediastack's, and
# `notify set` / `wire apprise` rewrite its tags; any other line (your own
# tags, untagged URLs) is never touched. Each send's outcome is kept per
# stream in local/state/ for `notify status` and doctor.
# Sourced by the entrypoint; relies on lib/common.sh, the svc/c_state helpers
# and, for Seerr's own test, SEERR_API_KEY at call time.

NOTIFY_KEY=mediastack
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
# shellcheck disable=SC2034  # these three are read by wire_seerr (lib/integrations.sh)
SEERR_HUB_PAYLOAD='{"title":"Seerr","body":"{{event}}\n{{subject}}\n{{message}}","tag":"{{notification_type}}","type":"info"}'
# what wire seerr wrote before per-event routing (every event to ops) —
# recognised so an agent mediastack made is upgraded, a hand-edited one kept
# shellcheck disable=SC2034
SEERR_HUB_PAYLOAD_V1='{"title":"Seerr","body":"{{event}}\n{{subject}}\n{{message}}","tag":"ops","type":"info"}'
# shellcheck disable=SC2034
SEERR_HUB_TYPES_V1=222

apprise_url() { local p; p=$(svc_hostport apprise) || return 1; echo "http://127.0.0.1:$p"; }

seerr_hub_types() { # the agent's types: every routed event's bit, summed
    local e n=0
    for e in "${!SEERR_EVENT_BIT[@]}"; do n=$(( n + SEERR_EVENT_BIT[$e] )); done
    echo "$n"
}

notify_tagline() { # notify_tagline STREAM -> the tags mediastack writes on that stream's URLs
    local t; t="$1 ${NOTIFY_EVENTS[$1]}"; echo "${t// /,}"
}

# ---------------------------------------------------------------- sending --
notify_post() { # notify_post TAG TITLE BODY TYPE -> "code<TAB>body" of the hub's answer; rc 1 when unreachable
    local out
    out=$(curl -sS -m 10 -X POST -H "Content-Type: application/json" \
          -d "$(jq -cn --arg t "$2" --arg b "$3" --arg g "$1" --arg y "$4" \
                '{title:$t,body:$b,tag:$g,type:$y,format:"markdown"}')" \
          -w $'\n%{http_code}' "$(apprise_url)/notify/$NOTIFY_KEY" 2>&1) || { printf '000\t%s\n' "$(oneline "$out")"; return 1; }
    printf '%s\t%s\n' "${out##*$'\n'}" "$(oneline "${out%$'\n'*}")"
}

notify_outcome() { # notify_outcome CODE BODY -> "" when delivered, else why not (for people)
    case "$1" in
        200) ;;
        204) echo "nothing is set up for this stream (no URL carries its tag): ./mediastack.sh notify set <stream>" ;;
        000) echo "the hub is unreachable: $2" ;;
        *)   echo "the hub answered HTTP $1${2:+: $2}" ;;
    esac
}

notify_record() { # notify_record STREAM WHY — keep the latest outcome for status/doctor
    [[ " ${NOTIFY_STREAMS[*]} " == *" $1 "* ]] || return 0
    if [[ -z "$2" ]]; then state_set "notify-$1-ok" "$(date +%s)"
    else state_set "notify-$1-fail" "$(date +%s) $2"; fi
}

NOTIFY_WARNED=0
notify() { # notify TAG TITLE BODY [TYPE] — never blocks, never fails the caller; the outcome is recorded
    local tag="$1" title="$2" body="$3" type="${4:-info}" ans why
    svc_enabled apprise 2>/dev/null || return 0
    [[ "$(c_state "$(svc_cname apprise)" 2>/dev/null)" == running ]] || return 0
    ans=$(notify_post "$tag" "$title" "$body" "$type") || true   # unreachable: judged just below
    why=$(notify_outcome "${ans%%$'\t'*}" "${ans#*$'\t'}")
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
notify_cfg_get() { # the hub's stored configuration text (empty when none)
    local out code
    out=$(curl -sS -m 10 -X POST -w $'\n%{http_code}' "$(apprise_url)/get/$NOTIFY_KEY" 2>&1) \
        || die "the notification hub is unreachable: $(oneline "$out")"
    code=${out##*$'\n'}
    case "$code" in
        200) printf '%s\n' "${out%$'\n'*}" ;;
        204|404) ;;   # nothing stored yet
        *) die "the notification hub refused to show its configuration [HTTP $code]: $(oneline "${out%$'\n'*}")" ;;
    esac
}

notify_cfg_put() { # notify_cfg_put TEXT — store it (empty: remove the configuration)
    local out code
    if [[ -z "$(grep -v '^[[:space:]]*$' <<<"$1" || true)" ]]; then   # nothing left to store
        out=$(curl -sS -m 10 -X POST -w $'\n%{http_code}' "$(apprise_url)/del/$NOTIFY_KEY" 2>&1) || die "the hub is unreachable: $(oneline "$out")"
    else
        out=$(curl -sS -m 10 -X POST -H "Content-Type: application/json" \
              -d "$(jq -cn --arg c "$1" '{config:$c,format:"text"}')" \
              -w $'\n%{http_code}' "$(apprise_url)/add/$NOTIFY_KEY" 2>&1) || die "the hub is unreachable: $(oneline "$out")"
    fi
    code=${out##*$'\n'}
    [[ "$code" =~ ^2 ]] || die "the hub rejected the configuration [HTTP $code]: $(oneline "${out%$'\n'*}")
  Check the URL against https://github.com/caronc/apprise/wiki"
}

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
    svc_enabled apprise || die "the notification hub (apprise) is not enabled — enable it: ./mediastack.sh enable apprise"
    [[ "$(c_state "$(svc_cname apprise)")" == running ]] || die "the notification hub (apprise) is not running — start it: ./mediastack.sh up"
}

notify_stream_ok() { [[ " ${NOTIFY_STREAMS[*]} " == *" $1 "* ]] || die "unknown stream '$1' (streams: ${NOTIFY_STREAMS[*]})"; }

notify_status() {
    notify_need_hub
    local cfg s u n ok fail
    cfg=$(notify_cfg_get)
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
}

notify_test() {
    notify_need_hub
    local s streams=("${NOTIFY_STREAMS[@]}") ans why rc=0
    [[ -n "${1:-}" ]] && { notify_stream_ok "$1"; streams=("$1"); }
    for s in "${streams[@]}"; do
        ans=$(notify_post "$s" "Mediastack test" "A test on the $s stream — if you can read this, it works." info) || true   # judged below
        why=$(notify_outcome "${ans%%$'\t'*}" "${ans#*$'\t'}")
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
    local cfg; cfg=$(notify_cfg_get | notify_cfg_edit set "$1" "$REPLY_VAL")
    notify_cfg_put "$cfg"
    ok "$1: URLs stored"
    notify_test "$1"
}

notify_clear() {
    notify_stream_ok "$1"
    notify_need_hub
    confirm "Remove every URL of the '$1' stream? It stops receiving notifications" || { info "Nothing changed."; return 0; }
    notify_cfg_put "$(notify_cfg_get | notify_cfg_edit clear "$1")"
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
    ans=$(notify_post "$stream" "$title" "$body" "$type") || true   # judged below
    why=$(notify_outcome "${ans%%$'\t'*}" "${ans#*$'\t'}")
    notify_record "$stream" "$why"
    [[ -z "$why" ]] || die "$stream: not delivered — $why"
    ok "$stream: delivered"
}

# ------------------------------------------------------------------ doctor --
_doctor_notify() {
    hr "doctor: notifications"
    if ! svc_enabled apprise; then info "the notification hub (apprise) is off"; return 0; fi
    local s ok fail
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
