#!/usr/bin/env bash
# test-arr-health.sh — arr_doctor (services/_arr/arr.sh), doctor's view of each
# arr's and Prowlarr's own health list:
#   * an error entry is a doctor problem (counted), naming the app and its words
#   * a warning is a WARN, a notice is information; neither is counted
#   * an empty list is OK; an unreadable or non-list reply is a WARN, never "clear"
#   * an app not running, or without its API key yet, is skipped or warned
# Sources the real entrypoint (minus its last line, main "$@"); the service
# lookups and the API are stubs answering from $T.
#
#   scripts/test-arr-health.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-arr-health.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

arr_instances() { echo radarr sonarr; }
svc_enabled()   { [[ "$1" == prowlarr ]]; }
svc_cname()     { echo "mediastack-$1"; }
c_state()       { cat "$T/state.${1#mediastack-}" 2>/dev/null || echo running; }
arr_key()       { [[ -e "$T/nokey.$1" ]] || echo "key-$1"; }
arr_url()       { echo "http://stub/$1"; }
arr_apiver()    { echo v3; }
api() { # api METHOD URL KEY — answers $T/<app>.json; $T/<app>.down fails the call
    local app; app=$(cut -d/ -f4 <<<"$2")
    [[ -e "$T/$app.down" ]] && { echo "connection refused"; return 1; }
    cat "$T/$app.json"
}
reset() { rm -f "$T"/*; D_FAILS=0; }
doc() { arr_doctor > "$T/out" 2>&1; }

reset
echo '[{"source":"IndexerRssCheck","type":"error","message":"No indexers available with RSS sync enabled","wikiUrl":"https://wiki.servarr.com/radarr/system#no-indexers"},
      {"source":"IndexerSearchCheck","type":"warning","message":"No indexers available with Automatic Search enabled","wikiUrl":"https://wiki.servarr.com/x"}]' > "$T/radarr.json"
echo '[{"source":"NotificationStatusCheck","type":"error","message":"Notifications unavailable due to failures: mediastack-hub","wikiUrl":""}]' > "$T/sonarr.json"
echo '[]' > "$T/prowlarr.json"
doc
(( D_FAILS == 2 )) || fail_ "each error entry is one doctor problem (got $D_FAILS): $(cat "$T/out")"; pass
grep -q 'FAIL.*radarr: No indexers available with RSS sync enabled' "$T/out" || fail_ "an error names the app and its words: $(cat "$T/out")"; pass
grep -q 'wiki.servarr.com/radarr/system#no-indexers' "$T/out" || fail_ "its fix points at the app's own help page"; pass
grep -q 'FAIL.*sonarr: Notifications unavailable due to failures' "$T/out" || fail_ "a dead connection to the hub is a problem"; pass
grep -q 'WARN.*radarr: No indexers available with Automatic Search' "$T/out" || fail_ "a warning is a WARN, not counted"; pass
grep -q 'OK.*prowlarr: its health list is clear' "$T/out" || fail_ "Prowlarr is checked too; an empty list is OK"; pass

reset; echo '[]' > "$T/sonarr.json"; echo '[]' > "$T/prowlarr.json"; : > "$T/radarr.down"
doc
(( D_FAILS == 0 )) && grep -q 'WARN.*radarr: its health list is unreadable: connection refused' "$T/out" \
    || fail_ "an unreachable app is a WARN with the evidence: $(cat "$T/out")"; pass
reset; echo '{"message":"Unauthorized"}' > "$T/radarr.json"; echo '[]' > "$T/sonarr.json"; echo '[]' > "$T/prowlarr.json"
doc
grep -q 'WARN.*radarr: its health list is not a list' "$T/out" && ! grep -q 'radarr: its health list is clear' "$T/out" \
    || fail_ "a reply that is not a list is never read as clear: $(cat "$T/out")"; pass

reset; echo exited > "$T/state.radarr"; : > "$T/nokey.sonarr"; echo '[]' > "$T/prowlarr.json"
doc
! grep -q 'radarr' "$T/out" || fail_ "an app not running is skipped: $(cat "$T/out")"; pass
grep -q 'WARN.*sonarr: no API key yet' "$T/out" || fail_ "an app without its key yet says so"; pass

echo "test-arr-health: $checks checks passed"
