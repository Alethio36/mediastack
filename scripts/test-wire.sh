#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-wire.sh — wire goes on past a failed app, and the pieces of this that
# run without the apps:
#   * no wire step (wire_<role>) returns 1: it reports with wfail and returns
#     0, so one refusing app never ends the run at the error trap (the
#     summary counts the failure and exits 1)
#   * Jellyfin's plugin list read softly: a startup page is no plugin seen
#   * LazyLibrarian's API switched on in config.ini while it is stopped: the
#     two keys under [GENERAL], an old api_enabled replaced, the owner kept
#   * the closing summary lists every failure again, named by its step
#   * settings wire wrote to .env reach the containers that read them at
#     start: what became pending during the run is recreated, nothing else
#
#   scripts/test-wire.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
lib=$(mktemp .test-wire.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"
set +e +E; trap - ERR   # each check reads its own status

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

# ---- no wire step returns 1 ----
roles=$(IFS='|'; echo "${WIRE_ROLES[*]}")
bad=$(for f in services/*/*.sh; do awk -v F="$f" -v R="^wire_($roles)\$" '
    /^[a-z_]+\(\) *\{/ { fn=$1; sub(/\(\).*/, "", fn) }
    fn ~ R && /return 1/ { print F ":" NR ": " $0 }
    /^}/ { fn="" }' "$f"; done)
[[ -z "$bad" ]] || fail_ "a wire step returns 1 — report with wfail and return 0 (lib/wire.sh):"$'\n'"$bad"; pass

# ---- Jellyfin's plugins, read softly ----
[[ "$(jf_plugin_ids '<html>Jellyfin is starting</html>')" == "||" ]] || fail_ "a startup page is no plugin seen"; pass
[[ "$(jf_plugin_ids '[{"Id":"A-B"},{"Id":"c"}]')" == "|ab|c|" ]] || fail_ "ids, dashes gone, lower case"; pass

# ---- LazyLibrarian's API switched on ----
ENV_FILE=$T/.env; printf 'CONFIG_ROOT=%s\n' "$T/cfg" > "$ENV_FILE"
mkdir -p "$T/cfg/lazylibrarian"; ini=$T/cfg/lazylibrarian/config.ini
printf '[GENERAL]\nimp_preflang = en\napi_enabled = 0\n\n[LOGGING]\nlog_dir = /config/log\n' > "$ini"
sudo()       { "$@"; }
DC()         { echo "DC $*" >> "$T/dc"; }
http_ready() { :; }; render() { :; }; ll_url() { echo http://127.0.0.1:5299; }
ll_api()     { [[ "$1" == getVersion ]] && echo '{"current_version":"x"}'; }
out=$(ll_api_enable 2>&1) || fail_ "switching the API on runs: $out"
[[ "$(grep -E '^DC (stop|start) ' "$T/dc")" == $'DC stop lazylibrarian\nDC start lazylibrarian' ]] || fail_ "written while stopped: $(cat "$T/dc")"; pass
[[ "$(sed -n 2p "$ini")" == "api_enabled = 1" && "$(sed -n 3p "$ini")" =~ ^api_key\ =\ [0-9a-f]{32}$ ]] \
    || fail_ "the two keys right under [GENERAL]: $(cat "$ini")"; pass
[[ "$(grep -c '^api_enabled' "$ini")" == 1 && "$(sed -n '/^\[LOGGING\]/,$p' "$ini" | grep -c '^api_')" == 0 ]] \
    || fail_ "the old api_enabled replaced, nothing in other sections: $(cat "$ini")"; pass
[[ "$(ll_key)" =~ ^[0-9a-f]{32}$ ]] || fail_ "ll_key reads the key back"; pass
ll_api() { echo 'API not enabled'; }; : > "$T/dc"
ll_api_enable >/dev/null 2>&1 && fail_ "an API that does not answer after the write is a failure"
(( WIRE_FAILS > 0 )) || fail_ "and it is counted"; pass

# ---- the summary names every failure by its step ----
WIRE_FAILS=0; WIRE_FAIL_LIST=()
WIRE_STEP=seerr; wfail $'library sync failed [HTTP 400]\n     a second line' >/dev/null
WIRE_STEP=kavita; wfail "kavita refused" >/dev/null; WIRE_STEP=""
[[ "$(wire_fail_summary)" == $'  - seerr: library sync failed [HTTP 400]\n  - kavita: kavita refused' ]] \
    || fail_ "one line per failure, its step first: $(wire_fail_summary)"; pass

# ---- what wire wrote to .env reaches the containers that read it at start ----
: > "$T/dc"
compose_pending() { printf 'traefik\nauthentik-worker\n'; }
wire_apply_settings "traefik" >/dev/null
[[ "$(grep -E '^DC up' "$T/dc")" == "DC up -d authentik-worker" ]] || fail_ "only what became pending during wire is recreated: $(cat "$T/dc")"; pass
: > "$T/dc"; compose_pending() { echo traefik; }
wire_apply_settings "traefik" >/dev/null
! grep -q '^DC up' "$T/dc" || fail_ "nothing new pending: nothing recreated"; pass

echo "OK wire: $checks checks"
