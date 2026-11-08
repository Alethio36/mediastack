#!/usr/bin/env bash
# services/apprise/questions.sh — the hub's question: the notification URLs
# per stream, the questionnaire's apprise_questions hook
# (docs/design-install.md, "One-shot answers"). They are held in local/state
# (0600) until `wire apprise` hands them to the hub, then deleted: a copy in
# .env would drift from the hub, which `notify set` edits. Once the hub holds
# endpoints configure asks no more. Sourced by the entrypoint; relies on
# lib/common.sh, lib/notify.sh and lib/questionnaire.sh at call time.

NOTIFY_URLS_STATE=notify-urls       # configure's URLs, "ops<TAB>urls" and "users<TAB>urls", until wire apprise stores them
NOTIFY_STORED_STATE=notify-stored   # the hub holds endpoints: they are changed with `notify`, not asked again

notify_pending() { # notify_pending STREAM -> the URLs configure recorded for it ("" when none)
    awk -F'\t' -v s="$1" '$1 == s { print $2; exit }' <<<"$(state_get "$NOTIFY_URLS_STATE")"
}

apprise_questions() {
    if [[ -n "$(state_get "$NOTIFY_STORED_STATE")" ]]; then
        if q_quick; then q_took "Notifications" "kept in the hub (change them: ./mediastack.sh notify)"; fi
        return 0
    fi
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
  anything  else: https://github.com/caronc/apprise/wiki
They are handed to the hub by wire, then kept there (change: notify)."
    local st prev keep answers=""
    for st in ops users; do
        prev=$(notify_pending "$st"); keep=""
        [[ -z "$prev" ]] || keep="; Enter = the ones given before"
        # a webhook URL is a password: whoever holds it can post — read hidden
        while true; do
            ask_hidden "URLs for $st (input hidden${keep:-; Enter = none})"
            [[ -n "$REPLY_VAL" || -z "$prev" ]] || REPLY_VAL=$prev
            notify_urls_ok "$st" "$REPLY_VAL" && break
        done
        [[ -z "$REPLY_VAL" ]] || answers+="$st"$'\t'"$REPLY_VAL"$'\n'
    done
    notify_urls_record "$answers"
}

notify_urls_record() { # notify_urls_record "ops<TAB>urls\nusers<TAB>urls\n" — held 0600 for wire apprise; nothing: notifications stay off
    if [[ -z "$1" ]]; then
        state_del "$NOTIFY_URLS_STATE"
        info "no URLs — notifications stay off until configure (or: ./mediastack.sh notify set) gives some"
        return 0
    fi
    state_set "$NOTIFY_URLS_STATE" "${1%$'\n'}"; chmod 600 "$STATE_DIR/$NOTIFY_URLS_STATE"
}
