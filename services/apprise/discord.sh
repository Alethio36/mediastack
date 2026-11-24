#!/usr/bin/env bash
# services/apprise/discord.sh — who a Discord message comes from. A webhook
# has its own name and avatar, and its URL (with its token) is enough to set
# them: Discord's "Modify Webhook with Token" takes the name and the avatar as
# image data, so the icon is uploaded from this host — it needs no public
# address. The hub sends with avatar=no (lib/notify.sh), so the webhook's own
# shows on every message of mediastack's, Seerr's and the arrs' alike.
#
# Set once per webhook, and again only when mediastack's name or icon changes.
# A name or avatar changed in Discord afterwards is yours: it is left as it is
# (what mediastack set is kept in local/state, per webhook, to tell).
# Reached from this host, outside the VPN — the path the hub's own messages
# take, with the same token. Sourced by the entrypoint.

DISCORD_SENDER_NAME=Mediastack                                    # the branding kit's name next
DISCORD_SENDER_ICON=services/apprise/assets/icon.png              # the branding kit's icon next
DISCORD_API=https://discord.com/api/webhooks

discord_webhook_parts() { [[ "$1" =~ ^discord://([0-9]+)/([^/?]+)$ ]] && echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"; }   # discord://ID/TOKEN -> "ID TOKEN"; rc 1 for anything else
discord_sender_want() { { echo "$DISCORD_SENDER_NAME"; sha256sum < "$SCRIPT_DIR/$DISCORD_SENDER_ICON"; } | sha256sum | cut -c1-16; }   # what mediastack sets, as one fingerprint

discord_sender_sync() { # discord_sender_sync URL — the webhook shows mediastack's name and icon (said); rc 1 with the reason on stdout
    local id tok cur name av rec want out img rname rav rwant
    read -r id tok <<<"$(discord_webhook_parts "$1")" || true
    [[ -n "${id:-}" ]] || { echo "not a Discord webhook URL"; return 1; }
    cur=$(curl -sS -m 20 -w $'\n%{http_code}' "$DISCORD_API/$id/$tok" 2>&1) || { echo "Discord unreachable: $(oneline "$cur")"; return 1; }
    [[ "${cur##*$'\n'}" == 200 ]] || { echo "Discord answered HTTP ${cur##*$'\n'} for the webhook (deleted, or its token changed?)"; return 1; }
    cur=${cur%$'\n'*}
    name=$(jq -r '.name // ""' <<<"$cur"); av=$(jq -r '.avatar // ""' <<<"$cur")
    rec=$(state_get "discord-sender-$id"); want=$(discord_sender_want)
    if [[ -n "$rec" ]]; then
        IFS=$'\t' read -r rname rav rwant <<<"$rec"
        if [[ "$name" != "$rname" || "$av" != "$rav" ]]; then echo "yours: its name or avatar was changed in Discord ($name) — left as it is"; return 0; fi
        if [[ "$rwant" == "$want" ]]; then echo "current: $name, with its icon (already set)"; return 0; fi
    fi
    img="data:image/png;base64,$(base64 -w0 < "$SCRIPT_DIR/$DISCORD_SENDER_ICON")"
    out=$(jq -cn --arg n "$DISCORD_SENDER_NAME" --arg a "$img" '{name: $n, avatar: $a}' \
          | curl -sS -m 20 -w $'\n%{http_code}' -X PATCH -H 'Content-Type: application/json' --data-binary @- "$DISCORD_API/$id/$tok" 2>&1) \
        || { echo "Discord unreachable: $(oneline "$out")"; return 1; }
    [[ "${out##*$'\n'}" == 200 ]] || { echo "Discord refused the name and icon [HTTP ${out##*$'\n'}]: $(oneline "${out%$'\n'*}")"; return 1; }
    out=${out%$'\n'*}
    state_set "discord-sender-$id" "$(jq -r '.name // ""' <<<"$out")"$'\t'"$(jq -r '.avatar // ""' <<<"$out")"$'\t'"$want"
    echo "set: $DISCORD_SENDER_NAME, with its icon"
}

discord_senders_sync() { # every Discord URL of mediastack's streams shows its name and icon — said per stream; never stops the caller
    local cfg s u out
    cfg=$(hub_cfg_get) || return 0
    for s in "${NOTIFY_STREAMS[@]}"; do
        while IFS= read -r u; do
            [[ "$u" == discord://* ]] || continue
            if out=$(discord_sender_sync "$u"); then
                case "$out" in yours:*) info "$s: its Discord webhook's ${out#yours: }" ;; *) ok "$s: its Discord webhook sends as ${out#*: }" ;; esac
            else warn "$s: its Discord webhook's name and icon not set — $out"; fi
        done < <(notify_cfg_urls "$s" <<<"$cfg")
    done
    return 0
}
