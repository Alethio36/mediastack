#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-notify.sh — the notification hub's routing and the `notify` verb.
#   * every Seerr event goes to exactly one stream, and the agent's types are
#     the sum of their bits; the payload tags each event with its own name
#   * the configuration: a line is mediastack's only when its tags are one
#     stream plus event names — `set`/`clear`/re-tagging touch those lines and
#     never yours (your own tags, two streams on a line, untagged URLs)
#   * URLs are shown without their secrets
#   * a send's outcome is judged by the hub's answer (a 204/424 is not
#     "delivered") and recorded per stream; `send` checks its arguments
#   * an arr's hub entry carries mediastack's tag (ops): --verify names a stale
#     one, wire re-tags it and changes nothing else
#
#   scripts/test-notify.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-notify.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }
STATE_DIR=$T/state; LOCAL_DIR=$T; warn() { echo "WARN $*" >> "$T/out"; }

# ---- routing ----
declare -A seen=()
for s in "${NOTIFY_STREAMS[@]}"; do for e in ${NOTIFY_EVENTS[$s]}; do
    [[ -z "${seen[$e]:-}" ]] || fail_ "$e is routed to two streams"
    seen[$e]=$s
done; done; pass
for e in "${!SEERR_EVENT_BIT[@]}"; do [[ -n "${seen[$e]:-}" ]] || fail_ "Seerr sends $e but no stream receives it"; done; pass
for e in "${!seen[@]}"; do [[ "$e" == TEST_NOTIFICATION || -n "${SEERR_EVENT_BIT[$e]:-}" ]] || fail_ "$e is routed but Seerr has no such event"; done; pass
[[ "$(seerr_hub_types)" == 8158 ]] || fail_ "agent types: $(seerr_hub_types) (every event but the test: 8158)"; pass
[[ "$(jq -r .tag <<<"$SEERR_HUB_PAYLOAD")" == '{{notification_type}}' ]] || fail_ "the payload must tag each event with its own name"; pass
for p in "${SEERR_HUB_PAYLOADS_BEFORE[@]}"; do
    [[ "$(jq -c 'del(.tag)' <<<"$SEERR_HUB_PAYLOAD")" == "$(jq -c 'del(.tag)' <<<"$p")" ]] \
        || fail_ "only the tag may differ from a template mediastack wrote before (the wording stays Seerr's)"; pass
done

# ---- Seerr's agent: the template is mediastack's, the events and poster are yours ----
agent() { jq -cn --arg p "$1" --argjson t "$2" --argjson e "$3" \
    '{enabled:true, embedPoster:$e, types:$t, options:{webhookUrl:"http://gluetun:8000/notify/mediastack", jsonPayload:$p, authHeader:"", customHeaders:[], supportVariables:false}}'; }
# found live on testhost: the first template (tag activity), events and poster changed in Seerr's UI
got=$(seerr_agent_next "$(agent "${SEERR_HUB_PAYLOADS_BEFORE[0]}" 4062 true)")
[[ "$(jq -r .options.jsonPayload <<<"$got")" == "$SEERR_HUB_PAYLOAD" && "$(jq -c '[.types, .embedPoster, .options.customHeaders, .options.webhookUrl]' <<<"$got")" == '[4062,true,[],"http://gluetun:8000/notify/mediastack"]' ]] \
    || fail_ "an old template with events you chose: template updated, your events and poster kept: $got"; pass
got=$(seerr_agent_next "$(agent "${SEERR_HUB_PAYLOADS_BEFORE[1]}" 222 false)")
[[ "$(jq -r .types <<<"$got")" == 8158 && "$(jq -r .options.jsonPayload <<<"$got")" == "$SEERR_HUB_PAYLOAD" ]] || fail_ "still the old default events: raised to the current ones: $got"; pass
[[ "$(seerr_agent_next "$(agent "$SEERR_HUB_PAYLOAD" 8158 false)")" == same ]] || fail_ "current agent: nothing to change"; pass
[[ "$(seerr_agent_next "$(agent "$SEERR_HUB_PAYLOAD" 4062 true)")" == same ]] || fail_ "current template, your events: nothing to change"; pass
[[ "$(seerr_agent_next "$(agent '{"title":"mine","tag":"x"}' 222 false)")" == yours ]] || fail_ "a template of yours: never touched"; pass

# ---- leftover lines for streams mediastack no longer has ----
[[ "$(notify_legacy_lines <<<$'activity=discord://1/tokenX
activity,ops=discord://2/tokenY
ops=discord://3/tokenZ' | tr '\n' ' ')" == "activity " ]] \
    || fail_ "only a line tagged just 'activity' is a leftover — and its URL is never printed"; pass

# ---- the configuration ----
cfg='# my hub
ops=discord://111/tokenA
users=https://discord.com/api/webhooks/222/tokenB
ops,MEDIA_PENDING=ntfy://ntfy.sh/ops-topic
mine,alerts=ntfy://ntfy.sh/mine
users,ops=mailto://me:pw@example.com
ops,custom=discord://333/tokenC
json://hook.example.com/in?x=1'
got=$(notify_cfg_edit retag <<<"$cfg")
want="# my hub
$(notify_tagline ops)=discord://111/tokenA
$(notify_tagline users)=https://discord.com/api/webhooks/222/tokenB
$(notify_tagline ops)=ntfy://ntfy.sh/ops-topic
mine,alerts=ntfy://ntfy.sh/mine
users,ops=mailto://me:pw@example.com
ops,custom=discord://333/tokenC
json://hook.example.com/in?x=1"
[[ "$got" == "$want" ]] || fail_ "retag: only mediastack's lines get the event tags:
$(diff <(echo "$want") <(echo "$got") || true)"; pass
[[ "$(notify_cfg_edit retag <<<"$got")" == "$got" ]] || fail_ "retagging twice must change nothing"; pass
got=$(notify_cfg_edit set users "ntfy://ntfy.sh/family, discord://444/tokenD" <<<"$want")
[[ "$(grep -c "^$(notify_tagline users)=" <<<"$got")" == 2 && "$got" != *tokenB* && "$got" == *"users,ops=mailto"* && "$got" == *"mine,alerts"* ]] \
    || fail_ "set: replace that stream's lines only: $got"; pass
got=$(notify_cfg_edit clear ops <<<"$want")
[[ "$got" != *tokenA* && "$got" != *ops-topic* && "$got" == *"ops,custom=discord://333/tokenC"* && "$got" == *tokenB* ]] \
    || fail_ "clear: remove that stream's lines only: $got"; pass
[[ "$(notify_cfg_urls users <<<"$want" | tr '\n' ' ')" == "https://discord.com/api/webhooks/222/tokenB mailto://me:pw@example.com " ]] \
    || fail_ "a stream's URLs are every line carrying its tag"; pass

# ---- URLs without their secrets ----
for u in discord://111/tokenA https://discord.com/api/webhooks/222/tokenB mailto://me:pw@example.com ntfy://user:pw@ntfy.sh/topic \
         tgram://123:tokenbot/-100chat pover://userkey@tokenapp; do
    shown=$(notify_url_shown "$u")
    [[ "$shown" != *token* && "$shown" != *pw* && "$shown" != *topic* && "$shown" != *userkey* ]] || fail_ "a secret shows: $u -> $shown"; pass
done
[[ "$(notify_url_shown ntfy://ntfy.sh/topic)" == "ntfy (ntfy.sh)" ]] || fail_ "the service and host should show"; pass

# ---- sending: judged by the hub's answer, recorded per stream ----
svc_enabled() { return 0; }; svc_cname() { echo x; }; c_state() { echo running; }; apprise_url() { echo http://hub; }
CODE=200
curl() { printf 'body\n%s' "$CODE"; }
notify ops "t" "b"
[[ -n "$(state_get notify-ops-ok)" && -z "$(state_get notify-ops-fail)" ]] || fail_ "a 200 must be recorded as delivered"; pass
CODE=424; rm -f "$T/out"; notify users "t" "b"; notify users "t" "b"
[[ "$(state_get notify-users-fail)" == *"HTTP 424"* && -z "$(state_get notify-users-ok)" ]] || fail_ "a 424 is not delivered: $(state_get notify-users-fail)"; pass
[[ "$(grep -c WARN "$T/out")" == 1 ]] || fail_ "one warning per run, not one per send"; pass
[[ "$(notify_outcome 204 '')" == *"notify set"* ]] || fail_ "204: nothing set up for the stream — say how to fix it"; pass
CODE=200; state_del notify-ops-ok; svc_enabled() { return 1; }; notify ops t b
[[ -z "$(state_get notify-ops-ok)" ]] || fail_ "the hub off: nothing sent, nothing recorded"; pass

# ---- notify send: its arguments ----
for bad in "" "ops" "ops t" "family t m" "ops t m --type loud" "ops t m --bogus"; do
    # shellcheck disable=SC2086  # the cases are word lists
    if (notify_send_cmd $bad) 2>/dev/null; then fail_ "notify send $bad must be refused"; fi; pass
done

# ---- an arr's hub entry carries mediastack's tag (wire apprise) ----
# An entry made before the ops/users split kept "activity", which no hub line
# carries: every arr event was answered 424 and lost. --verify must name it,
# a real run re-tags it and nothing else, and a right tag is left alone.
notes='[{"id":3,"name":"yours","fields":[{"name":"tags","value":["mine"]}]},
 {"id":7,"name":"mediastack-apprise","fields":[{"name":"serverUrl","value":"http://gluetun:8000"},
  {"name":"configurationKey","value":"mediastack"},{"name":"authPassword","value":"********"},
  {"name":"tags","value":["activity"]}]}]'
api() { echo "$1 $2" >> "$T/calls"; [[ "$1" == PUT ]] && printf '%s' "$4" > "$T/put"; return "${API_RC:-0}"; }
: > "$T/calls"; WIRE_DRY=1; WIRE_CHANGES=0
apprise_entry_tag radarr http://h/api/v3 k "$notes" > "$T/o"
grep -qF 'would: radarr: re-tag its hub entry ["activity"] -> ["ops"]' "$T/o" || fail_ "--verify must name the stale tag: $(cat "$T/o")"; pass
(( WIRE_CHANGES == 1 )) && [[ ! -s "$T/calls" ]] || fail_ "--verify counts the drift and writes nothing"; pass
: > "$T/calls"; WIRE_DRY=0; WIRE_CHANGES=0
apprise_entry_tag radarr http://h/api/v3 k "$notes" > "$T/o"
[[ "$(cat "$T/calls")" == "PUT http://h/api/v3/notification/7" ]] || fail_ "one PUT, to mediastack's entry: $(cat "$T/calls")"; pass
[[ "$(jq -c '.fields | map({(.name): .value}) | add' "$T/put")" == '{"serverUrl":"http://gluetun:8000","configurationKey":"mediastack","authPassword":"********","tags":["ops"]}' ]] \
    || fail_ "only the tags change; a masked secret goes back as-is: $(cat "$T/put")"; pass
grep -q 'radarr: hub entry re-tagged to ops' "$T/o" || fail_ "the re-tag is reported"; pass
: > "$T/calls"; WIRE_CHANGES=0
apprise_entry_tag radarr http://h/api/v3 k "${notes/\[\"activity\"\]/[\"ops\"]}" > "$T/o"
[[ ! -s "$T/calls" ]] && (( WIRE_CHANGES == 0 )) || fail_ "a right tag is left alone"; pass
WIRE_FAILS=0; API_RC=1
apprise_entry_tag radarr http://h/api/v3 k "$notes" > "$T/o" 2>&1
(( WIRE_FAILS == 1 )) || fail_ "a refused re-tag is a wire failure"; pass
unset API_RC
# both owners of a hub entry (each arr, and Prowlarr) check it, after any re-point
body=$(declare -f wire_apprise)
[[ "$(grep -c 'apprise_entry_tag' <<<"$body")" == 2 ]] || fail_ "wire_apprise must check the tag for the arrs and for prowlarr"; pass
[[ "$(grep -c 'tag not checked' <<<"$body")" == 2 ]] || fail_ "a re-point must be re-read before the tag check (else the second PUT undoes it)"; pass

echo "OK notify: $checks checks"
