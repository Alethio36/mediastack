#!/usr/bin/env bash
# services/seerr/hub.sh — what Seerr sends the notification hub: its webhook
# agent's payload, the events it turns on (their bits), and how wire seerr
# moves an agent mediastack wrote to the current one. Where each event goes
# is the hub's routing (NOTIFY_EVENTS, lib/notify.sh). Sourced by the entrypoint.

# Seerr's bit per event (server/lib/notifications/index.ts); the agent's
# "types" is their sum — every event but the test, which is always sent
declare -A SEERR_EVENT_BIT=(
    [MEDIA_PENDING]=2 [MEDIA_APPROVED]=4 [MEDIA_AVAILABLE]=8 [MEDIA_FAILED]=16
    [MEDIA_DECLINED]=64 [MEDIA_AUTO_APPROVED]=128 [ISSUE_CREATED]=256 [ISSUE_COMMENT]=512
    [ISSUE_RESOLVED]=1024 [ISSUE_REOPENED]=2048 [MEDIA_AUTO_REQUESTED]=4096
)
# the payload Seerr sends: the title (with its year) as the card's title, its
# overview as the text; the event name as the tag (the routing). The poster,
# the event and who asked (or reported) are per-message values of the hub's,
# placed by the card's template: a blank one takes the configuration's
# default — Seerr's own test has no event and nobody asking, and its card
# reads "Seerr · test" instead of empty markup. Seerr fills every {{...}} it
# knows, nested ones too, and an empty one with nothing. The text ends in a
# zero-width space: the hub refuses an empty text, and a title with no
# overview would be lost.
# shellcheck disable=SC2034  # read by wire_seerr (seerr.sh)
SEERR_HUB_PAYLOAD='{"title":"{{subject}}","body":"{{message}}​","tag":"{{notification_type}}","type":"info","format":"markdown","template":{"poster":"{{image}}","event":"{{event}}","who":"{{requestedBy_username}}{{reportedBy_username}}"}}'
# every template wire seerr wrote before (tag "activity", the stream before
# ops; then "ops"; then the plain one before the cards; then the first card,
# its event line in Seerr's text): a template mediastack
# wrote is mediastack's to update — the events turned on and the poster
# setting stay whoever set them
SEERR_HUB_PAYLOADS_BEFORE=(
    '{"title":"Seerr","body":"{{event}}\n{{subject}}\n{{message}}","tag":"activity","type":"info"}'
    '{"title":"Seerr","body":"{{event}}\n{{subject}}\n{{message}}","tag":"ops","type":"info"}'
    '{"title":"Seerr","body":"{{event}}\n{{subject}}\n{{message}}","tag":"{{notification_type}}","type":"info"}'
    '{"title":"{{subject}}","body":"**{{event}}** · {{requestedBy_username}}{{reportedBy_username}}\n{{message}}","tag":"{{notification_type}}","type":"info","format":"markdown","template":{"poster":"{{image}}"}}'
)
SEERR_HUB_TYPES_BEFORE=222   # the events every earlier version turned on

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

seerr_hub_types() { # the agent's types: every routed event's bit, summed
    local e n=0
    for e in "${!SEERR_EVENT_BIT[@]}"; do n=$(( n + SEERR_EVENT_BIT[$e] )); done
    echo "$n"
}
