#!/usr/bin/env bash
# services/apprise/hub.sh — the notification hub's interface, as Apprise
# provides it. lib/notify.sh (streams, routing, the `notify` verb, doctor) and
# the apps that check for the hub call only these; everything that speaks
# Apprise's HTTP API is here. A second provider defines the same names.
#
#   HUB_SVC                         the service that is the hub
#   hub_enabled / hub_running       enabled in .env / its container is running
#   hub_local_url                   the script's own address for it (127.0.0.1, its host port)
#   hub_configured                  rc 0 when a configuration is stored (quiet: never dies)
#   hub_send TAG TITLE BODY TYPE    -> "code<TAB>body" of its answer; rc 1 when unreachable
#   hub_outcome CODE BODY           -> "" when delivered, else why not (for people)
#   hub_cfg_get                     the stored configuration text (empty when none)
#   hub_cfg_put TEXT                store it (empty: remove the configuration)
#   hub_notify_url                  where an app on the stack network posts a message (its address follows the VPN)
#   hub_failed_sends HOURS          the sends it could not deliver in that time, by anyone: "addr<TAB>tags" per send
#
#   hub_templates_sync              mediastack's Discord templates where the hub reads them (before storing a configuration that names them)
#
# The configuration is Apprise's YAML (lib/notify.sh writes it; a text-format
# one is read and converted). A Discord URL in it names a template of
# mediastack's (services/apprise/discord/), copied into the hub's own folder:
# the hub reads it there, at /config/$HUB_TEMPLATES_DIR. The apps' own hub entries (the arrs, Prowlarr, Seerr,
# Cleanuparr) stay with their wire code: a notification-hub role waits for a
# second provider (docs/roadmap.md).
# Sourced by the entrypoint; relies on lib/common.sh and the svc helpers at call time.

HUB_SVC=apprise
HUB_KEY=mediastack   # the configuration's key in Apprise (every URL mediastack stores is under it)
HUB_TEMPLATES_DIR=mediastack-templates   # under its /config: mediastack's Discord templates

hub_enabled() { svc_enabled "$HUB_SVC"; }
hub_running() { [[ "$(c_state "$(svc_cname "$HUB_SVC")")" == running ]]; }
hub_local_url() { local p; p=$(svc_hostport "$HUB_SVC") || return 1; echo "http://127.0.0.1:$p"; }

hub_notify_url() { echo "http://$(svc_addr "$HUB_SVC")/notify/$HUB_KEY"; }

hub_configured() {
    hub_enabled && [[ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST "$(hub_local_url)/get/$HUB_KEY" 2>/dev/null || echo 000)" == 200 ]]
}

hub_send() { # hub_send TAG TITLE BODY TYPE -> "code<TAB>body" of the hub's answer; rc 1 when unreachable
    local out
    out=$(curl -sS -m 10 -X POST -H "Content-Type: application/json" \
          -d "$(jq -cn --arg t "$2" --arg b "$3" --arg g "$1" --arg y "$4" \
                '{title:$t,body:$b,tag:$g,type:$y,format:"markdown"}')" \
          -w $'\n%{http_code}' "$(hub_local_url)/notify/$HUB_KEY" 2>&1) || { printf '000\t%s\n' "$(oneline "$out")"; return 1; }
    printf '%s\t%s\n' "${out##*$'\n'}" "$(oneline "${out%$'\n'*}")"
}

hub_outcome() { # hub_outcome CODE BODY -> "" when delivered, else why not (for people)
    case "$1" in
        200) ;;
        204) echo "nothing is set up for this stream (no URL carries its tag): ./mediastack.sh notify set <stream>" ;;
        000) echo "the hub is unreachable: $2" ;;
        *)   echo "the hub answered HTTP $1${2:+: $2}" ;;
    esac
}

hub_cfg_get() { # the hub's stored configuration text (empty when none)
    local out code
    out=$(curl -sS -m 10 -X POST -w $'\n%{http_code}' "$(hub_local_url)/get/$HUB_KEY" 2>&1) \
        || die "the notification hub is unreachable: $(oneline "$out")"
    code=${out##*$'\n'}
    case "$code" in
        200) printf '%s\n' "${out%$'\n'*}" ;;
        204|404) ;;   # nothing stored yet
        *) die "the notification hub refused to show its configuration [HTTP $code]: $(oneline "${out%$'\n'*}")" ;;
    esac
}

hub_templates_sync() { # the templates in the repo, copied into the hub's config folder when they differ (owned by its user, read-only to it)
    local src="$SCRIPT_DIR/services/apprise/discord" dst f
    dst="$(env_get CONFIG_ROOT)/$HUB_SVC/$HUB_TEMPLATES_DIR"
    sudo install -d -m 755 -o "$(env_get APPRISE_UID)" -g "$(env_get MEDIA_GROUP_GID)" "$dst"
    for f in "$src"/*.json; do
        sudo cmp -s "$f" "$dst/$(basename "$f")" 2>/dev/null && continue
        sudo install -m 644 -o "$(env_get APPRISE_UID)" -g "$(env_get MEDIA_GROUP_GID)" "$f" "$dst/$(basename "$f")"
    done
}
hub_cfg_put() { # hub_cfg_put TEXT — store it, YAML or Apprise's text format (empty: remove the configuration)
    local out code fmt=text
    if grep -qE '^(version|urls):' <<<"$1"; then fmt=yaml; hub_templates_sync; fi   # what it names must be there first
    if [[ -z "$(grep -v '^[[:space:]]*$' <<<"$1" || true)" ]]; then   # nothing left to store
        out=$(curl -sS -m 10 -X POST -w $'\n%{http_code}' "$(hub_local_url)/del/$HUB_KEY" 2>&1) || die "the hub is unreachable: $(oneline "$out")"
    else
        out=$(curl -sS -m 10 -X POST -H "Content-Type: application/json" \
              -d "$(jq -cn --arg c "$1" --arg f "$fmt" '{config:$c,format:$f}')" \
              -w $'\n%{http_code}' "$(hub_local_url)/add/$HUB_KEY" 2>&1) || die "the hub is unreachable: $(oneline "$out")"
    fi
    code=${out##*$'\n'}
    [[ "$code" =~ ^2 ]] || die "the hub rejected the configuration [HTTP $code]: $(oneline "${out%$'\n'*}")
  Check the URL against https://github.com/caronc/apprise/wiki"
}

hub_failed_sends() { # hub_failed_sends HOURS -> "addr<TAB>tags" per send the hub could not deliver (its log: the apps' sends and the script's); rc 1 + why when unreadable
    # Apprise logs the sender's address and the tags (apprise-api 2.1, checked
    # live Nov 2026): "NOTIFY - <addr> - One or more notifications not sent
    # (Tags: <t>) using KEY: <k>" (424: no URL carries the tag, or every URL
    # failed), "NOTIFY - <addr> - Notification delivery failed…" (an error).
    # The log is only as long as Docker keeps it (LOG_MAX_SIZE x LOG_MAX_FILE).
    local out
    out=$(sudo docker logs --since "${1}h" "$(svc_cname "$HUB_SVC")" 2>&1) || { echo "its log is unreadable: $(oneline "$out")"; return 1; }
    sed -nE "s/.*NOTIFY - ([0-9a-fA-F.:]+) - One or more notifications not sent( \(Tags: ([^)]*)\))? using KEY: $HUB_KEY.*/\1\t\3/p
             s/.*NOTIFY - ([0-9a-fA-F.:]+) - Notification delivery failed using KEY: $HUB_KEY.*/\1\t(an error)/p" <<<"$out"
}
