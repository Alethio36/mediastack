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
#
# The configuration is Apprise's text format (tags=URL per line); lib/notify.sh
# edits those lines. The apps' own hub entries (the arrs, Prowlarr, Seerr,
# Cleanuparr) stay with their wire code: a notification-hub role waits for a
# second provider (docs/roadmap.md).
# Sourced by the entrypoint; relies on lib/common.sh and the svc helpers at call time.

HUB_SVC=apprise
HUB_KEY=mediastack   # the configuration's key in Apprise (every URL mediastack stores is under it)

hub_enabled() { svc_enabled "$HUB_SVC"; }
hub_running() { [[ "$(c_state "$(svc_cname "$HUB_SVC")")" == running ]]; }
hub_local_url() { local p; p=$(svc_hostport "$HUB_SVC") || return 1; echo "http://127.0.0.1:$p"; }

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

hub_cfg_put() { # hub_cfg_put TEXT — store it (empty: remove the configuration)
    local out code
    if [[ -z "$(grep -v '^[[:space:]]*$' <<<"$1" || true)" ]]; then   # nothing left to store
        out=$(curl -sS -m 10 -X POST -w $'\n%{http_code}' "$(hub_local_url)/del/$HUB_KEY" 2>&1) || die "the hub is unreachable: $(oneline "$out")"
    else
        out=$(curl -sS -m 10 -X POST -H "Content-Type: application/json" \
              -d "$(jq -cn --arg c "$1" '{config:$c,format:"text"}')" \
              -w $'\n%{http_code}' "$(hub_local_url)/add/$HUB_KEY" 2>&1) || die "the hub is unreachable: $(oneline "$out")"
    fi
    code=${out##*$'\n'}
    [[ "$code" =~ ^2 ]] || die "the hub rejected the configuration [HTTP $code]: $(oneline "${out%$'\n'*}")
  Check the URL against https://github.com/caronc/apprise/wiki"
}
