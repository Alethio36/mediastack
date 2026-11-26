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
#     one, wire re-tags it and changes nothing else; mediastack's own writes
#     to it skip the app's test (forceSave), a download client's do not
#   * Apprise defaults outside the VPN; the schema-32 migration marks its
#     callers for re-pointing only where it actually moves
#   * the hub is reached only through its interface (hub_*): nothing outside
#     services/apprise/ speaks its HTTP API, and every interface name exists
#   * doctor reads the hub's own log for sends it could not deliver, whoever
#     sent them (an app posting straight to it), and names the sender: a
#     container, the VPN group (all as gluetun), this host, or an address
#     nobody holds now — and the tag, with why it failed
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
# shellcheck source=scripts/testlib.sh
source scripts/testlib.sh   # as_run: the code under test as a run runs it

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
    jq -e . <<<"$p" >/dev/null || fail_ "a template mediastack wrote before is JSON: $p"; pass
    [[ "$p" != "$SEERR_HUB_PAYLOAD" ]] || fail_ "the current template is not among the earlier ones"; pass
done
[[ "$(jq -r '.title, .format, .template.poster' <<<"$SEERR_HUB_PAYLOAD" | paste -sd'|')" == '{{subject}}|markdown|{{image}}' ]] \
    || fail_ "Seerr's card: its title, markdown, the poster as the hub's per-message value"; pass
# found live on anzac4: Seerr's own test has no event and nobody asking, and
# "**{{event}}** · {{requestedBy_username}}" in its text showed as "**·" —
# the event and who are per-message values now, a blank one the default's
[[ "$(jq -r '.template.event, .template.who' <<<"$SEERR_HUB_PAYLOAD" | paste -sd'|')" == '{{event}}|{{requestedBy_username}}{{reportedBy_username}}' ]] \
    || fail_ "Seerr's event and who asked: the hub's per-message values"; pass
[[ "$(jq -r .body <<<"$SEERR_HUB_PAYLOAD")" == $'{{message}}\xe2\x80\x8b' ]] \
    || fail_ "Seerr's text: its overview alone, never empty (the hub refuses an empty text)"; pass

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
[[ "$(notify_legacy_lines <<<$'  - "discord://1/tokenX":\n      - tag: activity\n  - "discord://2/tokenY":\n      - tag: activity, ops' | tr '\n' ' ')" == "activity " ]] \
    || fail_ "the same in YAML"; pass

# ---- the configuration: a text-format one read, YAML written ----
hostname() { echo testhost; }
HUB_TEMPLATES_DIR=mediastack-templates
cfg='# my hub
ops=discord://111/tokenA
users=https://discord.com/api/webhooks/222/tokenB
ops,MEDIA_PENDING=ntfy://ntfy.sh/ops-topic
mine,alerts=ntfy://ntfy.sh/mine
users,ops=mailto://me:pw@example.com
ops,custom=discord://333/tokenC
json://hook.example.com/in?x=1'
notify_cfg_read "$cfg" || fail_ "a text-format configuration reads: $NOTIFY_CFG_WHY"
[[ "$NOTIFY_MODEL" == $'ops\tdiscord://111/tokenA\nusers\tdiscord://222/tokenB\nops\tntfy://ntfy.sh/ops-topic\n' ]] \
    || fail_ "mediastack's lines: each stream's URLs, a Discord webhook as discord://ID/TOKEN: [$NOTIFY_MODEL]"; pass
[[ "$NOTIFY_YOURS" == *'  # my hub'* && "$NOTIFY_YOURS" == *$'  - "ntfy://ntfy.sh/mine":\n      - tag: mine, alerts'* && "$NOTIFY_YOURS" == *$'  - "mailto://me:pw@example.com":\n      - tag: users, ops'* \
   && "$NOTIFY_YOURS" == *$'  - "discord://333/tokenC":\n      - tag: ops, custom'* && "$NOTIFY_YOURS" == *'  - "json://hook.example.com/in?x=1"'* ]] \
    || fail_ "your lines become YAML entries one for one (comment, tags, an untagged URL): [$NOTIFY_YOURS]"; pass
got=$(notify_cfg_edit retag <<<"$cfg")
grep -qx 'version: 1' <<<"$got" && grep -qxF "  poster: \"$NOTIFY_NO_POSTER\"" <<<"$got" && grep -qxF "$NOTIFY_MARK_BEGIN" <<<"$got" && grep -qxF "$NOTIFY_MARK_END" <<<"$got" \
    || fail_ "YAML, the placeholder poster as its default, mediastack's markers: $got"; pass
grep -qxF '  event: "Seerr"' <<<"$got" && grep -qxF '  who: "test"' <<<"$got" \
    || fail_ "YAML: Seerr's test reads \"Seerr · test\" (the event and who's defaults): $got"; pass
# Nick, on the first live card: the thumbnail (Discord's ~80 px) is too small — the large image slot
grep -qF '"image":{"url":"{{poster}}"}' services/apprise/discord/poster.json && ! grep -q thumbnail services/apprise/discord/poster.json \
    || fail_ "Seerr's poster: the card's large image, not the thumbnail"; pass
for t in services/apprise/discord/*.json; do   # every {{token}} a template uses is Apprise's own or one the entries pass
    while read -r k; do [[ "$k" == app_* || " footer poster event who color " == *" $k "* ]] || fail_ "$t uses {{$k}}, which no entry passes"; done \
        < <(grep -oE '\{\{[a-z_]+\}\}' "$t" | tr -d '{}' | sort -u)
    pass
done
d=$(sed -n "/^  - \"discord:\/\/111\/tokenA?/{p;n;p}" <<<"$got")
plain="  - \"discord://111/tokenA?avatar=no&template=/config/mediastack-templates/plain.json&:footer=testhost%20%C2%B7%20ops\":"$'\n'"      - tag: ops"
[[ "$d" == "$plain"* ]] || fail_ "a Discord URL: the stream's own messages as a card (no avatar of Apprise's, its footer): [$d]"; pass
for ty in success info warning failure; do
    evs=$(notify_stream_events_of ops "$ty"); [[ -n "$evs" ]] || continue
    grep -qF "template=/config/mediastack-templates/poster.json&:poster=\${POSTER}&:event=\${EVENT}&:who=\${WHO}&:color=$((16#$(env_get "BRAND_COLOUR_${ty^^}")))&" <<<"$got" && grep -qxF "      - tag: $evs" <<<"$got" \
        || fail_ "ops's $ty Seerr events ($evs): one card entry with the poster and that colour"; pass
done
[[ "$(grep -c 'discord://222/tokenB' <<<"$got")" == 2 ]] && grep -qxF '      - tag: MEDIA_AVAILABLE' <<<"$got" || fail_ "users on Discord: its messages, and Seerr's one event with the poster"; pass
grep -qxF '      - tag: ops, MEDIA_PENDING, MEDIA_APPROVED, MEDIA_AUTO_APPROVED, MEDIA_DECLINED, MEDIA_FAILED, MEDIA_AUTO_REQUESTED, ISSUE_CREATED, ISSUE_COMMENT, ISSUE_RESOLVED, ISSUE_REOPENED, TEST_NOTIFICATION' <<<"$got" \
    && grep -q '^  - "ntfy://ntfy.sh/ops-topic":$' <<<"$got" || fail_ "any other URL: one entry, the stream and its events: $got"; pass
for e in "${!NOTIFY_EVENT_TYPE[@]}"; do [[ -n "${SEERR_EVENT_BIT[$e]:-}" || "$e" == TEST_NOTIFICATION ]] || fail_ "$e has a colour and Seerr has no such event"; pass; done
for e in "${!SEERR_EVENT_BIT[@]}"; do [[ -n "${NOTIFY_EVENT_TYPE[$e]:-}" ]] || fail_ "Seerr's $e has no outcome (its card's colour)"; pass; done
[[ "$(sed -n "/^$(sed 's/[^^]/[&]/g; s/\^/\\^/g' <<<"$NOTIFY_MARK_END")$/,\$p" <<<"$got" | tail -n +2)" == "${NOTIFY_YOURS%$'\n'}" ]] || fail_ "your entries follow mediastack's block, as converted"; pass
[[ "$(notify_cfg_edit retag <<<"$got")" == "$got" ]] || fail_ "read back and written again: the same (YAML round trip)"; pass
got2=$(notify_cfg_edit set users "ntfy://ntfy.sh/family, https://discord.com/api/webhooks/444/tokenD" <<<"$got")
notify_cfg_read "$got2"
[[ "$NOTIFY_MODEL" == $'ops\tdiscord://111/tokenA\nops\tntfy://ntfy.sh/ops-topic\nusers\tntfy://ntfy.sh/family\nusers\tdiscord://444/tokenD\n' && "$got2" != *tokenB* && "$got2" == *"mailto://me:pw@example.com"* ]] \
    || fail_ "set: that stream's URLs replaced, the rest and yours kept: [$NOTIFY_MODEL]"; pass
got2=$(notify_cfg_edit clear ops <<<"$got"); notify_cfg_read "$got2"
[[ "$NOTIFY_MODEL" == $'users\tdiscord://222/tokenB\n' && "$got2" == *"discord://333/tokenC"* ]] || fail_ "clear: that stream's URLs only: [$NOTIFY_MODEL]"; pass
[[ "$(notify_cfg_urls users <<<"$got" | tr '\n' ' ')" == "discord://222/tokenB " ]] || fail_ "a stream's URLs, from mediastack's block"; pass
[[ -z "$(notify_cfg_edit clear users <<<"$(notify_cfg_edit clear ops <<<'ops=ntfy://ntfy.sh/a
users=ntfy://ntfy.sh/b')")" ]] || fail_ "nothing left: no configuration (the hub's is removed)"; pass
( notify_cfg_edit retag <<<$'version: 1\nurls:\n  - "ntfy://ntfy.sh/x"' ) 2>"$T/err" && fail_ "YAML without mediastack's markers: refused"
grep -q "without mediastack's marker lines" "$T/err" || fail_ "saying why: $(cat "$T/err")"; pass
( notify_cfg_edit retag <<<$'ops=ntfy://ntfy.sh/a\ninclude http://example.com/more.cfg' ) 2>"$T/err" && fail_ "an include: refused"
grep -q "line 2 is an include" "$T/err" || fail_ "naming the line: $(cat "$T/err")"; pass
[[ "$(notify_url_canon 'discord://bot@111/tokA?avatar=yes')" == discord://111/tokA && "$(notify_url_canon https://discordapp.com/api/webhooks/9/t-k)" == discord://9/t-k \
   && "$(notify_url_canon 'ntfys://ntfy.example/t?priority=5')" == 'ntfys://ntfy.example/t?priority=5' ]] || fail_ "a Discord URL's own options are mediastack's; any other kept as given"; pass
unset -f hostname

# ---- the templates: valid JSON once filled, where the hub reads them ----
for f in services/apprise/discord/*.json; do
    sed 's/{{app_color_int}}/1/; s/{{color}}/1/' "$f" | jq -e '.embeds[0].title and .embeds[0].description and .embeds[0].footer.text' >/dev/null || fail_ "$f: a card once filled"; pass
done
sudo() { echo "$*" >> "$T/sudo"; [[ "$1" != cmp ]]; }   # cmp: differs
eval "real_$(declare -f env_get)"
: > "$T/sudo"; env_get() { case "$1" in CONFIG_ROOT) echo /cfg ;; APPRISE_UID) echo 13010 ;; MEDIA_GROUP_GID) echo 13000 ;; esac; }
hub_templates_sync
grep -q "install -d -m 755 -o 13010 -g 13000 /cfg/apprise/mediastack-templates" "$T/sudo" && grep -q "install -m 644 -o 13010 -g 13000 .*/plain.json /cfg/apprise/mediastack-templates/plain.json" "$T/sudo" \
    || fail_ "the templates go to the hub's folder, its own: $(cat "$T/sudo")"; pass
unset -f sudo; eval "$(declare -f real_env_get | sed '1s/^real_//')"

# ---- the sender on Discord: the webhook's own name and icon ----
DREQ=$T/dreq; : > "$DREQ"; DGET='{"name":"mediastack","avatar":null}'; DPATCH='{"name":"Mediastack","avatar":"abc123"}'; DCODE=200
curl() {
    local a; for a in "$@"; do [[ "$a" == PATCH ]] && { cat > "$T/dbody"; echo PATCH >> "$DREQ"; printf '%s\n%s' "$DPATCH" "$DCODE"; return 0; }; done
    echo GET >> "$DREQ"; printf '%s\n200' "$DGET"
}
ENV_FILE=$T/brand.env; : > "$ENV_FILE"
out=$(discord_sender_sync discord://555/tok); [[ "$out" == "set: Mediastack, with mediastack's icon" && "$(paste -sd' ' "$DREQ")" == "GET PATCH" ]] || fail_ "first time: name and icon set ($out)"; pass
jq -e '.name == "Mediastack" and (.avatar | startswith("data:image/png;base64,iVBOR"))' "$T/dbody" >/dev/null || fail_ "the icon goes up as image data, from this host — no public address"; pass
DGET=$DPATCH; : > "$DREQ"; out=$(discord_sender_sync discord://555/tok)
[[ "$out" == "current: Mediastack, with its icon (already set)" && "$(paste -sd' ' "$DREQ")" == GET ]] || fail_ "the same again: nothing sent ($out)"; pass
DGET='{"name":"Our house","avatar":"mine99"}'; : > "$DREQ"; out=$(discord_sender_sync discord://555/tok)
[[ "$out" == yours:* && "$(paste -sd' ' "$DREQ")" == GET ]] || fail_ "changed in Discord: yours, left alone ($out)"; pass
DCODE=400; state_del discord-sender-555; out=$(discord_sender_sync discord://555/tok) && fail_ "refused: said"
[[ "$out" == *"HTTP 400"* ]] || fail_ "with Discord's answer: $out"; pass
discord_sender_sync ntfy://x >/dev/null && fail_ "not a Discord webhook: no"; pass
# the kit: a new name or icon is sent again (mediastack set the one there); one Discord refuses is not
DCODE=200; DPATCH='{"name":"Our House","avatar":"def456"}'; DGET='{"name":"Mediastack","avatar":"abc123"}'
state_set discord-sender-555 "Mediastack"$'\t'"abc123"$'\t'"$(discord_sender_want)"
echo 'PORTAL_TITLE="Our House"' > "$ENV_FILE"; : > "$DREQ"; out=$(discord_sender_sync discord://555/tok)
[[ "$out" == "set: Our House, with mediastack's icon" && "$(paste -sd' ' "$DREQ")" == "GET PATCH" ]] && jq -e '.name == "Our House"' "$T/dbody" >/dev/null \
    || fail_ "the kit's name changed: the webhook takes it ($out)"; pass
BRAND_DIR=$T/branding; mkdir -p "$BRAND_DIR"; cp services/apprise/assets/icon.png "$BRAND_DIR/icon.png"; printf 'x' >> "$BRAND_DIR/icon.png"
DGET=$DPATCH; DPATCH='{"name":"Our House","avatar":"ghi789"}'; : > "$DREQ"; out=$(discord_sender_sync discord://555/tok)
[[ "$out" == "set: Our House, with your icon" && "$(paste -sd' ' "$DREQ")" == "GET PATCH" ]] || fail_ "your icon in custom/branding/: the webhook takes it ($out)"; pass
echo 'PORTAL_TITLE="Discord Night"' > "$ENV_FILE"; DGET=$DPATCH; : > "$DREQ"; out=$(discord_sender_sync discord://555/tok) && fail_ "a name Discord refuses: not sent"
[[ "$out" == *"the name 'Discord Night' (PORTAL_TITLE)"*configure* && "$(paste -sd' ' "$DREQ")" == GET ]] || fail_ "a name Discord refuses: said before anything is sent ($out)"; pass
rm -rf "$BRAND_DIR"; BRAND_DIR=$CUSTOM_DIR/branding; : > "$ENV_FILE"
unset -f curl

# ---- a message too long for a card is cut, never refused whole ----
svc_enabled() { return 0; }; svc_cname() { echo x; }; c_state() { echo running; }
real_hub_send=$(declare -f hub_send)
hub_send() { printf '%s' "$2" > "$T/title"; printf '%s' "$3" > "$T/body"; printf '200\tok\n'; }
notify ops "$(printf 'T%.0s' {1..300})" "$(printf 'b%.0s' {1..5000})"
(( $(wc -m < "$T/title") <= 256 && $(wc -m < "$T/body") <= 4096 )) && grep -q 'cut: the rest is on the host' "$T/body" || fail_ "title and text cut to fit a card, saying so"; pass
eval "$real_hub_send"

# ---- URLs without their secrets ----
for u in discord://111/tokenA https://discord.com/api/webhooks/222/tokenB mailto://me:pw@example.com ntfy://user:pw@ntfy.sh/topic \
         tgram://123:tokenbot/-100chat pover://userkey@tokenapp; do
    shown=$(notify_url_shown "$u")
    [[ "$shown" != *token* && "$shown" != *pw* && "$shown" != *topic* && "$shown" != *userkey* ]] || fail_ "a secret shows: $u -> $shown"; pass
done
[[ "$(notify_url_shown ntfy://ntfy.sh/topic)" == "ntfy (ntfy.sh)" ]] || fail_ "the service and host should show"; pass

# ---- sending: judged by the hub's answer, recorded per stream ----
svc_enabled() { return 0; }; svc_cname() { echo x; }; c_state() { echo running; }; hub_local_url() { echo http://hub; }
CODE=200
curl() { printf 'body\n%s' "$CODE"; }
notify ops "t" "b"
[[ -n "$(state_get notify-ops-ok)" && -z "$(state_get notify-ops-fail)" ]] || fail_ "a 200 must be recorded as delivered"; pass
CODE=424; rm -f "$T/out"; notify users "t" "b"; notify users "t" "b"
[[ "$(state_get notify-users-fail)" == *"HTTP 424"* && -z "$(state_get notify-users-ok)" ]] || fail_ "a 424 is not delivered: $(state_get notify-users-fail)"; pass
[[ "$(grep -c WARN "$T/out")" == 1 ]] || fail_ "one warning per run, not one per send"; pass
[[ "$(hub_outcome 204 '')" == *"notify set"* ]] || fail_ "204: nothing set up for the stream — say how to fix it"; pass
CODE=200; state_del notify-ops-ok; svc_enabled() { return 1; }; notify ops t b
[[ -z "$(state_get notify-ops-ok)" ]] || fail_ "the hub off: nothing sent, nothing recorded"; pass

# ---- notify send: its arguments ----
for bad in "" "ops" "ops t" "family t m" "ops t m --type loud" "ops t m --bogus"; do
    # shellcheck disable=SC2086  # the cases are word lists
    if (notify_send_cmd $bad) 2>/dev/null; then fail_ "notify send $bad must be refused"; fi; pass
done

# ---- an arr's hub entries: mediastack's tag, their Apprise type, their events (wire apprise) ----
# An entry made before the ops/users split kept "activity", which no hub line
# carries: every arr event was answered 424 and lost. And one entry sends every
# event as its one type: "Health Check Failure" came as a blue info card (24 Nov
# 2026). Three entries: the news (info), a failing check (failure), one restored
# (success). --verify names what differs, a real run changes only that.
notes='[{"id":3,"name":"yours","fields":[{"name":"tags","value":["mine"]}]},
 {"id":7,"name":"mediastack-apprise","onGrab":true,"onDownload":true,"onHealthIssue":true,"onHealthRestored":true,"onApplicationUpdate":true,
  "fields":[{"name":"serverUrl","value":"http://gluetun:8000"},{"name":"configurationKey","value":"mediastack"},{"name":"authPassword","value":"********"},
  {"name":"notificationType","value":0},{"name":"tags","value":["activity"]}]}]'
ALL="$APPRISE_ARR_NEWS onHealthIssue onHealthRestored"
api() { echo "$1 $2" >> "$T/calls"; [[ "$1" == PUT ]] && printf '%s' "$4" > "$T/put"; [[ "$1" == POST ]] && printf '%s\n' "$4" >> "$T/post"; return "${API_RC:-0}"; }
sync_() { apprise_entry_sync radarr http://h/api/v3 k "$1" mediastack-apprise info "$APPRISE_ARR_NEWS" "$ALL"; }
: > "$T/calls"; WIRE_DRY=1; WIRE_CHANGES=0
sync_ "$notes" > "$T/o"
grep -qF 'would: radarr: its hub entry mediastack-apprise: re-tag ["activity"] -> ["ops"]; onHealthIssue off, onHealthRestored off' "$T/o" \
    || fail_ "--verify names the stale tag and the health events the news entry still sends: $(cat "$T/o")"; pass
(( WIRE_CHANGES == 1 )) && [[ ! -s "$T/calls" ]] || fail_ "--verify counts the drift and writes nothing"; pass
: > "$T/calls"; WIRE_DRY=0; WIRE_CHANGES=0
sync_ "$notes" > "$T/o"
[[ "$(cat "$T/calls")" == "PUT http://h/api/v3/notification/7?forceSave=true" ]] \
    || fail_ "one PUT, to mediastack's entry, without the app's own test (forceSave): $(cat "$T/calls")"; pass
[[ "$(jq -c '.fields | map({(.name): .value}) | add' "$T/put")" == '{"serverUrl":"http://gluetun:8000","configurationKey":"mediastack","authPassword":"********","notificationType":0,"tags":["ops"]}' ]] \
    && [[ "$(jq -c '[.onGrab, .onDownload, .onApplicationUpdate, .onHealthIssue, .onHealthRestored]' "$T/put")" == '[true,true,true,false,false]' ]] \
    || fail_ "only the tag and the health events change; a masked secret goes back as-is: $(cat "$T/put")"; pass
grep -q 'radarr: its hub entry mediastack-apprise: re-tag' "$T/o" || fail_ "the change is reported"; pass
: > "$T/calls"; WIRE_CHANGES=0
sync_ "[$(cat "$T/put")]" > "$T/o"
[[ ! -s "$T/calls" ]] && (( WIRE_CHANGES == 0 )) && grep -q 'its hub entry mediastack-apprise is current (info)' "$T/o" || fail_ "a current entry is left alone"; pass
WIRE_FAILS=0; API_RC=1
sync_ "$notes" > "$T/o" 2>&1
(( WIRE_FAILS == 1 )) || fail_ "a refused change is a wire failure"; pass
unset API_RC
# an app whose Apprise form has no type field: a failure, never "current" (nothing to set, nothing to differ)
WIRE_FAILS=0; : > "$T/calls"
sync_ "$(jq -c 'map(if .name == "mediastack-apprise" then .fields |= map(select(.name != "notificationType")) else . end)' <<<"[$(cat "$T/put")]")" > "$T/o" 2>&1
(( WIRE_FAILS == 1 )) && grep -q 'has no notification type' "$T/o" && [[ ! -s "$T/calls" ]] || fail_ "no type field: said as a failure, nothing written: $(cat "$T/o")"; pass
# the two health entries are made when missing, each its own type and event
SCHEMA='[{"implementation":"Apprise","name":"","onGrab":false,"onDownload":false,"onUpgrade":false,"onApplicationUpdate":false,"onHealthIssue":false,"onHealthRestored":false,
  "includeHealthWarnings":false,"fields":[{"name":"serverUrl","value":""},{"name":"configurationKey","value":""},{"name":"notificationType","value":0},{"name":"tags","value":[]}]}]'
hub_() { ( arr_key() { echo k; }; arr_url() { echo http://h; }; arr_apiver() { echo v3; }; svc_addr() { echo apprise:8000; }
           addr_stale() { return 1; }
           api() { echo "$1 $2" >> "$T/calls"
                   case "$1 $2" in
                       "GET http://h/api/v3/notification") printf '%s' "$CUR" ;;
                       "GET http://h/api/v3/notification/schema") printf '%s' "$SCHEMA" ;;
                       POST*) printf '%s\n' "$4" >> "$T/post"; echo '{}' ;;
                   esac; }
           apprise_arr_hub radarr "$APPRISE_ARR_NEWS" ) > "$T/o" 2>&1; }
CUR="[$(cat "$T/put")]"; : > "$T/calls"; : > "$T/post"; WIRE_DRY=0
hub_
[[ "$(grep -c "^POST" "$T/calls")" == 2 ]] || fail_ "the two health entries are made: $(cat "$T/calls") $(cat "$T/o")"; pass
[[ "$(jq -c 'select(.name=="mediastack-apprise-health") | [(.fields[]|select(.name=="notificationType").value), .onHealthIssue, .onHealthRestored, .onGrab, .includeHealthWarnings, (.fields[]|select(.name=="tags").value[0]), (.fields[]|select(.name=="serverUrl").value), (.fields[]|select(.name=="configurationKey").value)]' "$T/post")" \
    == '[3,true,false,false,false,"ops","http://apprise:8000","mediastack"]' ]] \
    || fail_ "a failing check: its own entry, type failure (red), errors only: $(cat "$T/post")"; pass
[[ "$(jq -c 'select(.name=="mediastack-apprise-restored") | [(.fields[]|select(.name=="notificationType").value), .onHealthRestored, .onHealthIssue]' "$T/post")" == '[1,true,false]' ]] \
    || fail_ "a restored check: its own entry, type success (green): $(cat "$T/post")"; pass
[[ "$(grep -c 'notification/schema' "$T/calls")" == 1 ]] || fail_ "the schema read once for both"; pass
# both owners of hub entries (each arr, and Prowlarr) go through the one function, Prowlarr with its own news
body=$(declare -f wire_apprise)
[[ "$(grep -c 'apprise_arr_hub' <<<"$body")" == 2 ]] && grep -q 'apprise_arr_hub prowlarr "$APPRISE_PROWLARR_NEWS"' <<<"$body" \
    || fail_ "wire_apprise checks the arrs' and Prowlarr's entries"; pass
body=$(declare -f apprise_arr_hub)
grep -q 'its hub entries not checked' <<<"$body" || fail_ "a re-point must be re-read before the entry check (else the second PUT undoes it)"; pass
# the hub entry's address is re-pointed without the app's test too; arr_repoint
# adds forceSave only when asked (a download client keeps its connection test)
grep -q 'arr_repoint --force .* notification ' <<<"$body" || fail_ "the hub entries' re-point passes --force"; pass
: > "$T/calls"
arr_repoint --force http://h/api/v3 k notification "$notes" mediastack-apprise "serverUrl=http://apprise:8000" >/dev/null
[[ "$(cat "$T/calls")" == "PUT http://h/api/v3/notification/7?forceSave=true" ]] || fail_ "--force saves with forceSave: $(cat "$T/calls")"; pass
[[ "$(jq -r '.fields[] | select(.name=="serverUrl") | .value' "$T/put")" == http://apprise:8000 ]] || fail_ "--force still changes the field"; pass
: > "$T/calls"
arr_repoint http://h/api/v3 k notification "$notes" mediastack-apprise "serverUrl=http://apprise:8000" >/dev/null
[[ "$(cat "$T/calls")" == "PUT http://h/api/v3/notification/7" ]] || fail_ "without --force the app tests as before: $(cat "$T/calls")"; pass

# ---- Apprise runs outside the VPN by default (schema 32) ----
# The fragment's default moved; an install following the default moves at the
# next `up`, so the migration marks its callers for re-pointing — as `vpn
# apprise off` would. An explicit choice, or Apprise not enabled: no mark.
[[ "$(sed -n 's/^ *mediastack\.vpn: *"\(.*\)"$/\1/p' services/apprise/compose.yml)" == false ]] \
    || fail_ "Apprise's fragment must default outside the VPN"; pass
# shellcheck disable=SC1090  # the real helpers again: svc_enabled was stubbed above
source "$lib"; STATE_DIR=$T/state; LOCAL_DIR=$T
mig() { : > "$ENV_FILE"; printf '%s\n' "$@" > "$ENV_FILE"; rm -rf "$STATE_DIR"; migrate_env_31_to_32 >/dev/null; state_get WIRE_REPOINT; }
ENV_FILE=$T/env
[[ "$(mig COMPOSE_PROFILES=gluetun,apprise,radarr)" == apprise ]] || fail_ "following the default: its callers are marked"; pass
[[ -z "$(mig COMPOSE_PROFILES=gluetun,apprise APPRISE_VPN=true)" ]] || fail_ "an explicit 'inside' stays, nothing to re-point"; pass
[[ -z "$(mig COMPOSE_PROFILES=gluetun,apprise APPRISE_VPN=false)" ]] || fail_ "already outside: nothing to re-point"; pass
[[ -z "$(mig COMPOSE_PROFILES=gluetun,radarr)" ]] || fail_ "Apprise not enabled: nothing to re-point"; pass

# ---- unit-failed: a scheduled or boot run that dies tells ops, once per cooldown ----
(
    STATE_DIR=$(mktemp -d); SENT=$(mktemp -d)
    load_env() { :; }; hostname() { echo testbox; }
    LOCAL_DIR=$(mktemp -d); MAINPID=""
    systemctl() { case "$*" in
        *"-p Result"*) echo exit-code ;; *"-p ExecMainStatus"*) echo 1 ;; *"-p InvocationID"*) echo inv123 ;;
        *"-p ExecMainPID"*) echo "$MAINPID" ;; esac; }
    journalctl() { [[ "$1" == "_SYSTEMD_INVOCATION_ID=inv123" ]] || { echo "journal read without the run's invocation id: $*" >&2; return 1; }
                   printf '    root : PWD=/home/someone/mediastack ; USER=root ; COMMAND=/usr/bin/docker ps\n'
                   printf 'pam_unix(sudo:session): session opened for user root(uid=0) by (uid=0)\n'
                   printf 'ERROR unhandled failure (exit 1) at lib/backup.sh:812 in update_run\n'; }
    notify() { local n; n=$(( $(find "$SENT" -name '*.tag' | wc -l) + 1 ))   # one send = four files
               printf '%s' "$1" > "$SENT/$n.tag"; printf '%s' "$2" > "$SENT/$n.title"
               printf '%s' "$3" > "$SENT/$n.body"; printf '%s' "$4" > "$SENT/$n.type"; }
    sends() { find "$SENT" -name '*.tag' | wc -l; }
    as_run cmd_unit_failed sshd.service; (( RC != 0 )) || fail_ "unit-failed must refuse a unit that is not mediastack's"; pass
    cmd_unit_failed mediastack-update.service >/dev/null
    [[ "$(cat "$SENT/1.tag")" == ops && "$(cat "$SENT/1.type")" == failure ]] || fail_ "unit-failed sends to ops as a failure"; pass
    [[ "$(cat "$SENT/1.title")" == "mediastack-update.service failed" ]] || fail_ "the title names the unit: $(cat "$SENT/1.title")"; pass
    body=$(cat "$SENT/1.body")
    [[ "$body" == *"Result: exit-code, exit status 1, on testbox"* && "$body" == *"lib/backup.sh:812"* && "$body" == *"journalctl -u mediastack-update.service"* ]] \
        || fail_ "the body carries result, exit status, host, that run's lines and where to look: $body"; pass
    [[ "$body" == *"from the journal (no run record)"* && "$body" != *COMMAND=* && "$body" != *pam_unix* && "$body" != */home/* ]] \
        || fail_ "no record: the journal, without sudo's audit lines and their home paths: $body"; pass
    cmd_unit_failed mediastack-update.service >/dev/null
    [[ $(sends) == 1 ]] || fail_ "a second failure inside the cooldown must not send again"; pass
    cmd_unit_failed mediastack-backup.service >/dev/null
    [[ $(sends) == 2 ]] || fail_ "the cooldown is per unit — another unit still sends"; pass
    state_set unit-failed-mediastack-update $(( $(date +%s) - FAILURE_COOLDOWN - 1 ))
    cmd_unit_failed mediastack-update.service >/dev/null
    [[ $(sends) == 3 ]] || fail_ "after the cooldown a failure sends again"; pass
    # with the run's record (lib/runs.sh): its own last lines, and the record to read
    mkdir -p "$LOCAL_DIR/runs"; MAINPID=4242; rec=$LOCAL_DIR/runs/20261113-040000-update--auto-4242.log
    { printf '# mediastack run\nverb:     update --auto\ncommit:   x\nby:       systemd mediastack-update\nstarted:  t\n---\n'
      for i in $(seq 1 20); do printf '04:00:%02d line %d\n' "$i" "$i"; done
      printf '04:00:21 ERROR the pull failed\n---\nexit:     1 after 21s\n'; } > "$rec"
    state_set unit-failed-mediastack-update 0
    cmd_unit_failed mediastack-update.service >/dev/null
    body=$(cat "$SENT/4.body")
    [[ "$body" == *"from its record"* && "$body" == *"04:00:21 ERROR the pull failed"* && "$body" == *"04:00:10 line 10"* \
       && "$body" != *"line 9"$'\n'* && "$body" != *"exit:"* && "$body" == *"Inspect: local/runs/20261113-040000-update--auto-4242.log"* ]] \
        || fail_ "with a record: its last 12 lines (no header, no footer) and where it is: $body"; pass
    rm -rf "$STATE_DIR" "$SENT" "$LOCAL_DIR"
)
checks=$((checks + 9))

# ---- doctor: the hub's own record of failed sends (lines as apprise-api 2.1 writes them, live Nov 2026) ----
cat > "$T/hublog" <<'LOG'
2026-11-11T12:09:54.539442738Z 2026-11-11 04:09:54,539 [INFO] django: NOTIFY - 172.31.250.3 - Delivered Notification(s) - Tags: ops, KEY: mediastack
2026-11-11T12:10:44.393687247Z 2026-11-11 04:10:44,393 [WARNING] django: NOTIFY - 172.31.250.129 - One or more notifications not sent (Tags: doctor-probe) using KEY: mediastack
2026-11-11T12:10:44.395363703Z 2026-11-11 04:10:44,395 [WARNING] django.request: Failed Dependency: /notify/mediastack
2026-11-11T12:10:44.396672241Z [pid: 151|app: 0|req: 13/13] 172.31.250.129 () {28 vars in 344 bytes} [Wed Nov 11 04:10:44 2026] POST /notify/mediastack => generated 67 bytes in 10 msecs (HTTP/1.1 424) 7 headers in 452 bytes (6 switches on core 0)
2026-11-11T12:11:00.000000000Z 2026-11-11 04:11:00,000 [WARNING] django: NOTIFY - 172.31.250.3 - One or more notifications not sent (Tags: activity) using KEY: mediastack
2026-11-11T12:12:00.000000000Z 2026-11-11 04:12:00,000 [WARNING] django: NOTIFY - 172.31.250.3 - One or more notifications not sent (Tags: activity) using KEY: mediastack
2026-11-11T12:13:00.000000000Z 2026-11-11 04:13:00,000 [WARNING] django: NOTIFY - 172.31.250.128 - One or more notifications not sent (Tags: ops) using KEY: mediastack
2026-11-11T12:14:00.000000000Z 2026-11-11 04:14:00,000 [ERROR] django: NOTIFY - 172.31.250.140 - Notification delivery failed using KEY: mediastack: boom
2026-11-11T12:15:00.000000000Z 2026-11-11 04:15:00,000 [WARNING] django: NOTIFY - 172.31.250.141 - One or more notifications not sent (Tags: ops) using KEY: someone-else
LOG
jq -n '[{IPAM:{Config:[{Subnet:"172.31.250.0/24", Gateway:"172.31.250.128"}]},
         Containers:{a:{Name:"mediastack-jellyfin", IPv4Address:"172.31.250.129/24"},
                     b:{Name:"mediastack-gluetun", IPv4Address:"172.31.250.3/24"}}}]' > "$T/net"
hub_doctor() { # -> doctor's lines about the hub's failed sends
    ( sudo() { case "$*" in "docker logs --since 168h"*) cat "$T/hublog" ;; "docker network inspect mediastack") cat "$T/net" ;; *) return 1 ;; esac; }
      svc_cname() { echo "mediastack-$1"; }; vpn_group() { printf 'qbittorrent\nradarr\n'; }
      ok() { echo "OK $*"; }; warn() { echo "WARN $*"; }
      _doctor_hub_failures )
}
got=$(hub_doctor)
[[ "$(grep -c '^WARN' <<<"$got")" == 4 ]] || fail_ "one line per sender and tag, ours only (another key is not ours): $got"; pass
grep -qF "WARN hub: 1 send(s) from mediastack-jellyfin (tag: doctor-probe) not delivered in the last 7 days: no stream carries that tag" <<<"$got" \
    || fail_ "a container by name, an unknown tag said so: $got"; pass
grep -qF "WARN hub: 2 send(s) from the VPN group (qbittorrent radarr, all sending as gluetun) (tag: activity)" <<<"$got" \
    || fail_ "gluetun's address is the VPN group, counted: $got"; pass
grep -qF "from mediastack itself (this host) (tag: ops) not delivered in the last 7 days: its URL(s) refused it — ./mediastack.sh notify test ops" <<<"$got" \
    || fail_ "the gateway is this host; a stream's tag: its URLs refused it: $got"; pass
grep -qF "from 172.31.250.140 (nothing on the stack network holds it now) (tag: (an error))" <<<"$got" \
    || fail_ "a delivery error from an address nobody holds now: $got"; pass
: > "$T/hublog"
[[ "$(hub_doctor)" == "OK hub: every send in the last 7 days was delivered" ]] || fail_ "nothing failed: said so: $(hub_doctor)"; pass
got=$( ( sudo() { echo "permission denied"; return 1; }; svc_cname() { echo "mediastack-$1"; }; warn() { echo "WARN $*"; }; _doctor_hub_failures ) )
[[ "$got" == "WARN hub: its log is unreadable: permission denied" ]] || fail_ "an unreadable log is a warning with its reason, not silence: $got"; pass

# ---- the hub is reached only through its interface (services/apprise/hub.sh) ----
# Only the provider's folder speaks the hub's HTTP API; everything else calls
# hub_*. A second provider defines every name in the interface. Migrations
# are left out: they record what happened to Apprise itself (schema 32 moved
# its VPN default), whatever the hub is later.
leak=$(grep -rnE 'hub_local_url|/(notify|get|add|del)/\$HUB_KEY|svc_(enabled|cname|hostport) "?apprise' lib services mediastack.sh --include=*.sh \
        | grep -vE '^(services/apprise/|lib/migrations\.sh:)' || true)
[[ -z "$leak" ]] || fail_ "the hub's own API used outside services/apprise/: $leak"; pass
for f in hub_enabled hub_running hub_local_url hub_notify_url hub_configured hub_send hub_outcome hub_cfg_get hub_cfg_put hub_failed_sends; do
    grep -qE "^$f\(\)" services/apprise/hub.sh || fail_ "the hub interface lacks $f"; pass
done
[[ "$(sed -n 's/^HUB_SVC=//p' services/apprise/hub.sh)" == apprise ]] || fail_ "HUB_SVC names the hub's service"; pass

# ---- URLs typed blind: their shape checked, their outline shown ----
D=https://discord.com/api/webhooks/1539/QzABCDEFGHIJ
out=$(notify_urls_ok ops "$D" 2>&1) && [[ "$out" == *"ops: 1 URL(s) — https://discord.com/…GHIJ"* && "$out" != *QzABC* ]] \
    || fail_ "a good URL passes, shown as its outline only: $out"; pass
out=$(notify_urls_ok ops "${D}${D}" 2>&1) && fail_ "two pastes run together are refused"
[[ "$out" == *"one entry holds two URLs"* ]] || fail_ "and named: $out"; pass
out=$(notify_urls_ok ops "discord.com/api/webhooks/x" 2>&1) && fail_ "a URL without its scheme is refused"; pass
out=$(notify_urls_ok ops "$D,ntfy://ntfy.sh/mytopic" 2>&1) && [[ "$out" == *"2 URL(s)"* ]] || fail_ "two URLs, comma-separated: $out"; pass
notify_urls_ok users "" >/dev/null 2>&1 || fail_ "empty (no URLs for this stream) is allowed"; pass

# ---- configure's URLs reach the hub once, through wire apprise ----
ENV_FILE=$T/.env; : > "$ENV_FILE"
wa() { # wa HUB-GET-CODE — wire apprise's endpoint step, the hub stubbed; the hub's calls in $T/hub
    ( svc_enabled() { [[ "$1" == apprise ]]; }; wire_gate() { :; }; http_ready() { :; }; wire_arrs_ready() { :; }
      arr_instances() { :; }; notify() { echo "SENT $1" >> "$T/hub"; }; hub_cfg_get() { :; }; hub_local_url() { echo http://hub; }
      curl() { local a; for a in "$@"; do [[ "$a" == http://hub/* ]] && echo "$a ${*: -3:1}" >> "$T/hub"; done
               case "$*" in *"/get/mediastack"*) printf '%s' "$GETCODE" ;; *"/add/mediastack"*) printf 'ok\n200' ;; esac; }
      GETCODE=$1; wire_apprise ) > "$T/out" 2>&1
}
: > "$T/hub"; state_set "$NOTIFY_URLS_STATE" $'ops\tntfy://ntfy.sh/a,ntfy://ntfy.sh/b\nusers\tdiscord://1/x'
wa 204 || fail_ "wire apprise with configure's URLs runs: $(cat "$T/out")"
grep -q '/add/mediastack' "$T/hub" && [[ -z "$(state_get "$NOTIFY_URLS_STATE")" && -n "$(state_get "$NOTIFY_STORED_STATE")" ]] \
    || fail_ "the URLs are stored in the hub, then deleted here: $(cat "$T/hub")"; pass
state_set "$NOTIFY_URLS_STATE" $'ops\tntfy://ntfy.sh/c'; state_del "$NOTIFY_STORED_STATE"; : > "$T/hub"
wa 200 || fail_ "a hub that has endpoints already"
! grep -q '/add/mediastack' "$T/hub" && grep -q 'were not used: the hub already has endpoints' "$T/out" \
    && [[ -z "$(state_get "$NOTIFY_URLS_STATE")" && -n "$(state_get "$NOTIFY_STORED_STATE")" ]] \
    || fail_ "the hub's endpoints are never overwritten; configure's are dropped, said: $(cat "$T/out")"; pass
state_del "$NOTIFY_STORED_STATE"; : > "$T/hub"
wa 204 </dev/null || fail_ "nothing recorded, no terminal"
! grep -q '/add/mediastack' "$T/hub" && grep -q 'configure asks them' "$T/out" || fail_ "nothing to store: wire asks nothing, says where they come from"; pass
! grep -nE 'ask_hidden|ask_token|ask_secret|read -r -[sp]' services/apprise/apprise.sh || fail_ "wire apprise asks nothing"; pass

# ---- doctor tells ops when its problems change, weekly while they stand ----
(
    STATE_DIR=$(mktemp -d); SENT=$(mktemp)
    notify() { printf '%s|%s|%s\n%s\n--\n' "$1" "$2" "$4" "$3" >> "$SENT"; }
    info() { :; }
    told() { grep -c '^ops|' "$SENT" || true; }
    probs() { D_FAIL_LINES=("$@"); D_FAILS=$#; }
    probs "radarr: No indexers" "sonarr: No indexers" "disk /srv: 1.0GiB free of 94GiB (1%)"
    doctor_tell_ops
    [[ $(told) == 1 ]] && grep -q '^ops|Doctor: 3 problem(s)|failure$' "$SENT" && grep -q '^- disk /srv: 1.0GiB free' "$SENT" \
        || fail_ "the first time: ops hears the problems, listed: $(cat "$SENT")"; pass
    probs "radarr: No indexers" "sonarr: No indexers" "disk /srv: 0.9GiB free of 94GiB (0%)"
    doctor_tell_ops; [[ $(told) == 1 ]] || fail_ "the same problems, numbers moved: not again"; pass
    echo $(( EPOCHSECONDS - DOCTOR_REMIND_EVERY - 1 )) > "$STATE_DIR/doctor-told-at"
    doctor_tell_ops; [[ $(told) == 2 ]] || fail_ "a week later: told again"; pass
    probs "radarr: No indexers"
    doctor_tell_ops; [[ $(told) == 3 ]] || fail_ "a different set: told at once"; pass
    probs
    doctor_tell_ops; [[ $(told) == 4 ]] && grep -q '^ops|Doctor: all clear|info$' "$SENT" || fail_ "all fixed: ops hears all clear"; pass
    doctor_tell_ops; [[ $(told) == 4 ]] || fail_ "clear again: nothing more"; pass
    mapfile -t many < <(seq -f 'problem %g' 1 13); probs "${many[@]}"; : > "$SENT"
    doctor_tell_ops; grep -q '^- problem 10$' "$SENT" && ! grep -q '^- problem 11$' "$SENT" && grep -q '^…and 3 more$' "$SENT" \
        || fail_ "at most 10 listed, the rest counted: $(cat "$SENT")"; pass
    rm -rf "$STATE_DIR" "$SENT"
)
checks=$((checks + 7))
# the timer's run tells ops and succeeds (a non-zero exit would also set off unit-failed); a manual run still fails
grep -q 'apply_timer mediastack-doctor "Mediastack scheduled doctor" "doctor --scheduled" DOCTOR_SCHEDULE' lib/backup.sh \
    && grep -q '(( scheduled )) || exit 1' <(awk '/^cmd_doctor\(\)/,/^}/' lib/doctor.sh) \
    && grep -q 'doctor_tell_ops' <(awk '/^cmd_doctor\(\)/,/^}/' lib/doctor.sh) \
    || fail_ "doctor --scheduled from its timer exits 0 with problems; by hand, 1"; pass

# ---- notify test: every app that sends to the hub itself is asked for its own test, found by its name ----
( svc_enabled_managed() { printf '%s\n' sonarr seerr; }
  seerr_notify_test() { echo SEERR >> "$T/apptests"; }
  : > "$T/apptests"; notify_test_apps
  [[ "$(cat "$T/apptests")" == SEERR ]] ) || fail_ "notify test asks Seerr for its own test (seerr_notify_test, its folder)"; pass
( svc_enabled_managed() { printf '%s\n' ghost; }
  eval 'ghost_notify_test() { return 1; }'
  ! notify_test_apps ) || fail_ "an app's failed own test fails notify test"; pass
[[ "$(grep -cE 'seerr_[a-z_]+\(\)|SEERR_' lib/notify.sh || true)" == 0 ]] || fail_ "lib/notify.sh holds none of Seerr's parts (services/seerr/): $(grep -nE 'seerr_|SEERR_' lib/notify.sh)"; pass

echo "OK notify: $checks checks"
