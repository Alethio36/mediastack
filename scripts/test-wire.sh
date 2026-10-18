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
# nor does a helper one calls bare: set -e ends the whole run on it (found live, Oct 2026)
returners=$(awk '/^[a-z_]+\(\) *\{/ { fn=$1; sub(/\(\).*/, "", fn) }
    fn != "" && /return 1/ { print fn }
    /^}/ { fn="" }' mediastack.sh lib/*.sh services/*/*.sh | sort -u | tr '\n' ' ')
bad=$(for f in services/*/*.sh; do awk -v F="$f" -v R="^wire_($roles)\$" -v L="$returners" '
    BEGIN { n = split(L, a, " "); for (i = 1; i <= n; i++) ret[a[i]] = 1 }
    /^[a-z_]+\(\) *\{/ { fn=$1; sub(/\(\).*/, "", fn) }
    /^}/ { fn=""; st=""; next }
    { st = st $0 }                       # one statement: continued lines joined
    /\\$/ { sub(/\\$/, "", st); next }
    st ~ /<</ { st=""; next }           # a here-document: its guard follows the terminator, out of sight here
    { split(st, w, " ") }
    fn ~ R && (w[1] in ret) && st !~ /\|\||&&/ { print F ":" NR ": " st }
    { st="" }' "$f"; done)
[[ -z "$bad" ]] || fail_ "a wire step calls a helper that can return 1, unguarded — the helper reports with wfail and returns 0:"$'\n'"$bad"; pass

# ---- every wire step and every credential rotation skips a service that is
# off: on a stack without it, the step otherwise waits out its API and dies
# (wire_qbit on a Deluge-only stack, found Oct 2026) ----
unguarded=$(for f in services/*/*.sh; do awk -v F="$f" -v R="^(wire_($roles)|sc_rotate_[a-z_]+)\$" '
    /^[a-z_]+\(\) *\{/ { fn=$1; sub(/\(\).*/, "", fn); n=0; g=0; next }
    fn ~ R { n++; if ($0 ~ /svc_enabled|arr_instances|signin_is/) g=1
             if (n == 4) { if (!g) print F ": " fn; fn="" } }' "$f"; done)
[[ -z "$unguarded" ]] || fail_ "a wire step or credential rotation does not first check its service is enabled:"$'\n'"$unguarded"; pass

# ---- Jellyfin's plugins, read softly ----
[[ "$(jf_plugin_ids '<html>Jellyfin is starting</html>')" == "||" ]] || fail_ "a startup page is no plugin seen"; pass
[[ "$(jf_plugin_ids '[{"Id":"A-B"},{"Id":"c"}]')" == "|ab|c|" ]] || fail_ "ids, dashes gone, lower case"; pass
# the Webhook plugin (and its Jellyfin restart) only for WatchState, its one consumer
wanted=$( svc_enabled() { [[ $1 == watchstate ]]; }; jf_plugins_ensure() { echo "ENSURE $2"; }; jf_plugin_webhook tok )
[[ "$wanted" == "ENSURE Webhook|"* ]] || fail_ "WatchState on: the Webhook plugin is ensured ($wanted)"; pass
wanted=$( svc_enabled() { return 1; }; jf_plugins_ensure() { echo "ENSURE $2"; }; jf_plugin_webhook tok )
[[ -z "$wanted" ]] || fail_ "WatchState off: no Webhook plugin, no restart ($wanted)"; pass

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
