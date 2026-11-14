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
#   * an arr's API key that Prowlarr or Seerr holds is kept current: Prowlarr's
#     (masked) is tested and replaced only when refused as the key; Seerr's is
#     compared; --verify only reports
#   * Seerr's own key in .env follows Seerr (one regenerated in its settings)
#   * an arr's key Cleanuparr holds (masked) follows the arr: replaced only
#     when the stored key fails and the arr's current key passes
#   * --verify checks Cleanuparr with its stored key and writes nothing
#   * Bazarr's first start: wire waits (bounded) for the key it writes
#   * reset-password with Wizarr: a temporary Jellyfin password set through
#     its API, proven by signing in (that session ended), shown once; a
#     disabled account said, never re-enabled; the stack's admin refused
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
curl()       { [[ "$*" == *"apikey=$(ll_key)&cmd=getVersion"* ]] && echo '{"Success": true, "current_version":"x"}' || echo '{"Success": false, "Error": {"Code": 401, "Message": "Incorrect API key"}}'; }
out=$(ll_api_enable 2>&1) || fail_ "switching the API on runs: $out"
[[ "$(grep -E '^DC (stop|start) ' "$T/dc")" == $'DC stop lazylibrarian\nDC start lazylibrarian' ]] || fail_ "written while stopped: $(cat "$T/dc")"; pass
[[ "$(sed -n 2p "$ini")" == "api_enabled = 1" && "$(sed -n 3p "$ini")" =~ ^api_key\ =\ [0-9a-f]{32}$ ]] \
    || fail_ "the two keys right under [GENERAL]: $(cat "$ini")"; pass
[[ "$(grep -c '^api_enabled' "$ini")" == 1 && "$(sed -n '/^\[LOGGING\]/,$p' "$ini" | grep -c '^api_')" == 0 ]] \
    || fail_ "the old api_enabled replaced, nothing in other sections: $(cat "$ini")"; pass
[[ "$(ll_key)" =~ ^[0-9a-f]{32}$ ]] || fail_ "ll_key reads the key back"; pass
curl() { echo 'API not enabled'; }; : > "$T/dc"
ll_api_enable >/dev/null 2>&1 && fail_ "an API that does not answer after the write is a failure"
(( WIRE_FAILS > 0 )) || fail_ "and it is counted"; pass
# a wrong key gets JSON too (found live Nov 2026): only Success true proves the key written
curl() { echo '{"Success": false, "Data": "", "Error": {"Code": 401, "Message": "Incorrect API key"}}'; }; : > "$T/dc"
ll_api_enable >/dev/null 2>&1 && fail_ "LazyLibrarian refusing the written key (JSON, Success false) is a failure"; pass
unset -f curl

# ---- the summary names every failure by its step ----
WIRE_FAILS=0; WIRE_FAIL_LIST=()
WIRE_STEP=seerr; wfail $'library sync failed [HTTP 400]\n     a second line' >/dev/null
WIRE_STEP=kavita; wfail "kavita refused" >/dev/null; WIRE_STEP=""
[[ "$(wire_fail_summary)" == $'  - seerr: library sync failed [HTTP 400]\n  - kavita: kavita refused' ]] \
    || fail_ "one line per failure, its step first: $(wire_fail_summary)"; pass

# ---- what wire wrote to .env reaches the containers that read it at start;
# a failed recreate says compose's reason ----
: > "$T/dc"
compose_pending() { printf 'traefik\nauthentik-worker\n'; }
wire_apply_settings "traefik" >/dev/null
[[ "$(grep -E '^DC up' "$T/dc")" == "DC up -d authentik-worker" ]] || fail_ "only what became pending during wire is recreated: $(cat "$T/dc")"; pass
: > "$T/dc"; compose_pending() { echo traefik; }
wire_apply_settings "traefik" >/dev/null
! grep -q '^DC up' "$T/dc" || fail_ "nothing new pending: nothing recreated"; pass
compose_pending() { printf 'authentik-worker\n'; }; WIRE_FAILS=0; WIRE_FAIL_LIST=()
( DC() { echo "Error response from daemon: container mediastack-authentik-ldap is restarting" >&2; return 1; }
  wire_apply_settings "" >/dev/null 2>&1; printf '%s\n' "${WIRE_FAIL_LIST[@]}" ) > "$T/out"
grep -q 'recreating authentik-worker failed — compose: Error response from daemon: container mediastack-authentik-ldap is restarting — apply with' "$T/out" \
    || fail_ "a failed recreate says compose's own reason: $(cat "$T/out")"; pass
# only a changed definition is wire's to apply: a stopped or new service is not (found live:
# "authentik-ldap (stopped)" went to compose as a name)
: > "$T/dc"; compose_pending() { printf 'authentik-ldap (stopped)\nauthentik-worker\nkavita (new)\n'; }
wire_apply_settings "" >/dev/null
[[ "$(grep -E '^DC up' "$T/dc")" == "DC up -d authentik-worker" ]] || fail_ "only the bare names are recreated: $(cat "$T/dc")"; pass

# ensure_resource prints its success text after it already existed AND after it wrote it:
# that text must be true both ways (found live Nov 2026: "enable forms login", then "already set")
bad=$(grep -rn -A2 'ensure_resource "' lib services | grep -iE '^[^:]+-[0-9]+-.*"[^"]*already[^"]*"' || true)
[[ -z "$bad" ]] || fail_ "an ensure_resource success text says 'already' — it is also printed after a write: $bad"; pass

# a call that times out is unanswered, not refused: a write may still have been made (found live Nov 2026)
tmo() { ( curl() { echo "curl: (28) Operation timed out after 20002 milliseconds"; return 28; }; api "$1" http://x k ) 2>&1; }
[[ "$(tmo PUT)" == "no answer within 20s — the change may still have been made: wire reads it back at the end" ]] \
    || fail_ "a write that timed out: unanswered, maybe made ($(tmo PUT))"; pass
[[ "$(tmo GET)" == "no answer within 20s" ]] || fail_ "a read that timed out: unanswered ($(tmo GET))"; pass
[[ "$( ( curl() { echo "curl: (7) Failed to connect"; return 7; }; api GET http://x k ) 2>&1)" == *"Failed to connect"* ]] \
    || fail_ "any other failure: curl's own words"; pass

# ---- an arr's key in Prowlarr and Seerr follows the arr (found live Nov 2026:
#      a key regenerated in Sonarr left both refused, wire --verify clean) ----
APPS='[{"id":7,"name":"sonarr (mediastack)","fields":[{"name":"baseUrl","value":"http://gluetun:8989"},{"name":"apiKey","value":"********"}]}]'
pk() { # pk DRY TEST-ANSWER -> the calls made, then "fails=N"
    ( WIRE_DRY=$1 WIRE_FAILS=0 WIRE_CHANGES=0 ANSWER=$2; rm -f "$T/c"
      api() { echo "$1 ${2##*/v1/} ${4:-}" >> "$T/c"
          case "$1 $2" in
              "GET "*/applications) echo "$APPS" ;;
              "POST "*/applications/test) [[ "$ANSWER" == ok ]] && return 0; echo "$ANSWER"; return 1 ;;
              "PUT "*) echo '{}' ;;
          esac; }
      prowlarr_app_key sonarr "sonarr (mediastack)" http://p/api/v1 pkey NEWKEY >/dev/null 2>&1
      grep -v '^GET' "$T/c" | cut -d' ' -f1,2 | paste -sd' ' -; grep '^PUT' "$T/c" | cut -d' ' -f3- ; echo "fails=$WIRE_FAILS" )
}
refused='[{"propertyName":"ApiKey","errorMessage":"API Key is invalid"}]'
r=$(pk 0 "$refused")
[[ "$(sed -n 1p <<<"$r")" == "POST applications/test PUT applications/7" ]] || fail_ "refused as the key: tested, then put back: $r"; pass
jq -e '.fields[] | select(.name=="apiKey") | .value == "NEWKEY"' <<<"$(sed -n 2p <<<"$r")" >/dev/null \
    && jq -e '.fields[] | select(.name=="baseUrl") | .value == "http://gluetun:8989"' <<<"$(sed -n 2p <<<"$r")" >/dev/null \
    || fail_ "the PUT carries the arr's current key, the rest of the entry as it was: $(sed -n 2p <<<"$r")"; pass
[[ "$(pk 1 "$refused")" == $'POST applications/test\nfails=0' ]] || fail_ "--verify: tested and reported, nothing written: $(pk 1 "$refused")"; pass
[[ "$(pk 0 ok)" == $'POST applications/test\nfails=0' ]] || fail_ "the key works: nothing written: $(pk 0 ok)"; pass
[[ "$(pk 0 '[{"propertyName":"BaseUrl","errorMessage":"cannot connect"}]')" == $'POST applications/test\nfails=1' ]] \
    || fail_ "refused for another reason: a failure, the key left alone"; pass
sk() { # sk DRY HELD -> the calls made, SEERR_ENTRY's key, fails=N
    ( WIRE_DRY=$1 WIRE_FAILS=0 WIRE_CHANGES=0; rm -f "$T/c"
      arr_key() { echo NEWKEY; }
      seerr_api() { echo "$1 $2 ${4:-}" >> "$T/c"; echo '{}'; }; seerr_code() { echo 200; }
      SEERR_ENTRY=$(jq -cn --arg k "$2" '{id:3,name:"sonarr",hostname:"gluetun",apiKey:$k}')
      seerr_entry_key sonarr sonarr jar >/dev/null 2>&1
      { cut -d' ' -f1,2 "$T/c" 2>/dev/null || true; } | paste -sd' ' -; jq -r '.apiKey' <<<"$SEERR_ENTRY"; echo "fails=$WIRE_FAILS"
      cp "$T/c" "$T/sk" 2>/dev/null || rm -f "$T/sk" )
}
[[ "$(sk 0 OLDKEY)" == $'POST /settings/sonarr/test PUT /settings/sonarr/3\nNEWKEY\nfails=0' ]] || fail_ "seerr holds an old key: tested, then updated: $(sk 0 OLDKEY)"; pass
# Seerr refuses the id in a body (read-only in its API spec; found live Nov 2026): it goes in the path only
sk 0 OLDKEY >/dev/null
! cut -d' ' -f3- "$T/sk" | jq -e 'has("id")' >/dev/null 2>&1 && [[ "$(sed -n 2p "$T/sk" | cut -d' ' -f2)" == /settings/sonarr/3 ]] \
    || fail_ "no id in the test's or the PUT's body, the PUT's path names it: $(cat "$T/sk")"; pass
grep -q "'.hostname = \$h | .port = \$p | del(.id)'" services/seerr/seerr.sh || fail_ "the address re-point's PUT leaves the id out of its body too"; pass
[[ "$(sk 1 OLDKEY)" == $'\nOLDKEY\nfails=0' ]] || fail_ "a dry run: reported, nothing written: $(sk 1 OLDKEY)"; pass
[[ "$(sk 0 NEWKEY)" == $'\nNEWKEY\nfails=0' ]] || fail_ "seerr holds the current key: nothing written: $(sk 0 NEWKEY)"; pass

# ---- Seerr's own key in .env follows Seerr (found live Nov 2026: regenerated in
#      Seerr, .env kept the dead key, wire and doctor both silent) ----
ks() { # ks DRY STORED -> SEERR_API_KEY after, fails=N
    ( WIRE_DRY=$1 WIRE_FAILS=0 WIRE_CHANGES=0; echo "$2" > "$T/ek"
      seerr_api() { [[ "$1 $2" == "GET /settings/main" ]] && echo '{"apiKey":"SEERRNEW"}'; }; seerr_code() { echo 200; }
      env_get() { cat "$T/ek"; }; env_set() { echo "$2" > "$T/ek"; }
      seerr_key_store jar >/dev/null 2>&1; echo "$(cat "$T/ek") fails=$WIRE_FAILS" )
}
[[ "$(ks 0 SEERROLD)" == "SEERRNEW fails=0" ]] || fail_ "a key regenerated in Seerr: stored: $(ks 0 SEERROLD)"; pass
[[ "$(ks 1 SEERROLD)" == "SEERROLD fails=0" ]] || fail_ "a dry run: reported, .env untouched: $(ks 1 SEERROLD)"; pass
[[ "$(ks 0 SEERRNEW)" == "SEERRNEW fails=0" ]] || fail_ "already Seerr's: nothing to do: $(ks 0 SEERRNEW)"; pass
grep -q 'seerr_initialized; then' services/seerr/seerr.sh && awk '/if \$seerr_initialized; then/,/return 0/' services/seerr/seerr.sh | grep seerr_key_store >/dev/null \
    || fail_ "an initialised Seerr has its key checked on every wire, not only at its first"; pass

# ---- an arr's key in Cleanuparr follows the arr (found live Nov 2026: a new
#      Sonarr key, Cleanuparr's test 400, wire and --verify silent) ----
ck() { # ck DRY STORED-TEST CURRENT-TEST -> the calls made (method + path), then the PUT body, then fails=N
    ( WIRE_DRY=$1 WIRE_FAILS=0 WIRE_CHANGES=0 ST=$2 CT=$3; rm -f "$T/c"
      cup_code() { echo 400; }
      cup_api() { echo "$1 $2 ${4:-}" >> "$T/c"
          case "$1 $2" in
              "GET /configuration/sonarr") echo '{"instances":[{"id":"g-1","name":"sonarr","url":"http://gluetun:8989","version":4,"enabled":true,"apiKey":"••••••••"}]}' ;;
              "POST /configuration/sonarr/instances/test")
                  if [[ "${4:-}" == *instanceId* ]]; then [[ "$ST" == ok ]]; else [[ "$CT" == ok ]]; fi ;;
              "PUT "*) echo '{}' ;;
          esac; }
      cup_instance_key sonarr sonarr NEWKEY "X-Api-Key: k" >/dev/null 2>&1
      grep -v '^GET' "$T/c" | cut -d' ' -f1,2 | paste -sd' ' -; grep '^PUT' "$T/c" | cut -d' ' -f3- ; echo "fails=$WIRE_FAILS" )
}
r=$(ck 0 bad ok)
[[ "$(sed -n 1p <<<"$r")" == "POST /configuration/sonarr/instances/test POST /configuration/sonarr/instances/test PUT /configuration/sonarr/instances/g-1" ]] \
    || fail_ "the stored key fails, the current passes: replaced: $r"; pass
jq -e '.apiKey == "NEWKEY" and .url == "http://gluetun:8989" and .name == "sonarr"' <<<"$(sed -n 2p <<<"$r")" >/dev/null \
    || fail_ "the PUT carries the current key, the rest of the instance as it was: $(sed -n 2p <<<"$r")"; pass
grep -q '"apiKey":"NEWKEY"' "$T/c" && ! grep '/instances/test' "$T/c" | sed -n 1p | grep NEWKEY >/dev/null \
    || fail_ "the first test sends the masked value (Cleanuparr's stored key), not the current one"; pass
[[ "$(ck 1 bad ok)" == $'POST /configuration/sonarr/instances/test POST /configuration/sonarr/instances/test\nfails=0' ]] || fail_ "--verify: both tests, nothing written: $(ck 1 bad ok)"; pass
[[ "$(ck 0 ok ok)" == $'POST /configuration/sonarr/instances/test\nfails=0' ]] || fail_ "the stored key passes: one test, nothing written: $(ck 0 ok ok)"; pass
[[ "$(ck 0 bad bad)" == $'POST /configuration/sonarr/instances/test POST /configuration/sonarr/instances/test\nfails=1' ]] \
    || fail_ "the current key fails too (the arr unreachable): a failure, the key left alone: $(ck 0 bad bad)"; pass

# ---- --verify checks Cleanuparr instead of stopping quietly (found live Nov
#      2026: its stale copy of Sonarr's key, and "no drift") ----
cv() { # cv STORED-KEY-STATE(ok|refused|none) -> the writes a dry run sent, then its would: lines
    ( WIRE_DRY=1 WIRE_FAILS=0 WIRE_CHANGES=0 KS=$1; rm -f "$T/c"
      svc_enabled() { [[ "$1" == cleanuparr || "$1" == sonarr ]]; }; wire_gate() { :; }; http_ready() { :; }; hr() { :; }
      wire_arrs_ready() { :; }; arr_instances() { echo sonarr; }; arr_known() { :; }; arr_key() { echo K; }; arr_meta() { echo 4; }
      svc_label() { echo sonarr; }; hub_configured() { :; }; cup_code() { echo 200; }
      role_pick() { echo qbittorrent; }; role_env_missing() { :; }
      role_entry() { echo '{"name":"qBittorrent","typeName":"qBittorrent","host":"http://gluetun:8080"}'; }
      env_get() { case "$1" in ARR_USER) echo admin ;; ARR_PASSWORD) echo pw ;; CLEANUPARR_API_KEY) [[ "$KS" == none ]] || echo CK ;; esac; }
      cup_api() { echo "$1 $2" >> "$T/c"
          case "$1 $2" in
              "GET /auth/status") echo '{"setupCompleted":true}' ;;
              "GET /account/api-key") [[ "$KS" == ok ]] ;;
              "GET /configuration/download_client") echo '{"clients":[]}' ;;
              "GET /configuration/sonarr") echo '{"instances":[]}' ;;
              "GET /configuration/queue_cleaner") echo '{"enabled":false}' ;;
              "GET /configuration/notification_providers") echo '{"providers":[]}' ;;
              *) echo '{}' ;;
          esac; }
      out=$(wire_cleanuparr 2>&1)
      { grep -vE '^GET' "$T/c" 2>/dev/null || true; } | paste -sd' ' -; grep -o 'would: cleanuparr: [A-Za-z ]*' <<<"$out" | paste -sd'|' - )
}
r=$(cv ok)
[[ "$(sed -n 1p <<<"$r")" == "" ]] || fail_ "a dry run writes nothing (no sign-in, no create, no switch): $(sed -n 1p <<<"$r")"; pass
[[ "$(sed -n 2p <<<"$r")" == "would: cleanuparr: connect qBittorrent |would: cleanuparr: connect sonarr|would: cleanuparr: switch its queue cleaner on |would: cleanuparr: notify the hub " ]] \
    || fail_ "--verify reads on with the stored key and reports each missing piece: $(sed -n 2p <<<"$r")"; pass
[[ "$(cv refused)" == $'\nwould: cleanuparr: sign in and store its API key ' ]] || fail_ "the stored key refused: drift, not a quiet stop: $(cv refused)"; pass
[[ "$(cv none)" == $'\nwould: cleanuparr: sign in and store its API key ' ]] || fail_ "no stored key: drift, not a quiet stop: $(cv none)"; pass

# ---- Bazarr's first start: wire waits (bounded) for its key (found live Nov
#      2026: `enable bazarr` failed — config.yaml had no key yet) ----
bw() { # bw DRY KEY-AFTER-N-LOOKS -> "fails=N looks=N"
    ( WIRE_DRY=$1 WIRE_FAILS=0 AFTER=$2; echo 0 > "$T/looks"
      svc_enabled() { [[ "$1" == bazarr ]]; }; wire_gate() { :; }; hr() { :; }; sleep() { :; }
      bazarr_key() { n=$(( $(cat "$T/looks") + 1 )); echo "$n" > "$T/looks"; (( n > AFTER )) && echo BK; return 0; }
      arr_url() { echo http://b; }; curl() { echo 200; }   # past the key: the rest is not this check's
      wire_bazarr >/dev/null 2>&1; echo "fails=$WIRE_FAILS looks=$(cat "$T/looks")" )
}
[[ "$(bw 0 3)" == "fails=0 looks=4" ]] || fail_ "no key yet: wire waits for it, then goes on: $(bw 0 3)"; pass
[[ "$(bw 0 9999)" == "fails=1 looks=$(( BAZARR_KEY_WAIT / 3 + 2 ))" ]] || fail_ "never written: bounded, then a failure: $(bw 0 9999)"; pass
[[ "$(bw 1 9999)" == "fails=1 looks=1" ]] || fail_ "a dry run never waits: $(bw 1 9999)"; pass

# ---- reset-password with Wizarr: a temporary Jellyfin password, proven, the proof's session ended ----
jr() { # jr DISABLED(true|false) SIGNS-IN(yes|no) NAME -> "rc=N calls" (output in $T/jr)
    ( rm -f "$T/c"; env_get() { case "$1" in JELLYFIN_API_KEY) echo KEY ;; JELLYFIN_ADMIN_USER) echo admin ;; esac; }; jf_code() { echo 200; }
      jf_api() { echo "$1 $2" >> "$T/c"
          case "$1 $2" in
              "GET /Users") jq -cn --arg d "$DIS" '[{Name:"admin",Id:"a1",Policy:{IsDisabled:false}},{Name:"Viewer",Id:"v1",Policy:{IsDisabled:($d=="true")}}]' ;;
              "POST /Users/Password?userId=v1") [[ "$3" == KEY && "$4" == *'"NewPw":"'* ]] ;;
              "POST /Users/AuthenticateByName") [[ "$SI" == yes ]] && echo '{"AccessToken":"T1"}' ;;
              "POST /Sessions/Logout") [[ "$3" == T1 ]] ;;
          esac; }
      DIS=$1 SI=$2; rc=0; (jellyfin_reset_password "$3") > "$T/jr" 2>&1 || rc=$?
      echo "rc=$rc $(cut -d' ' -f1,2 "$T/c" 2>/dev/null | paste -sd'|' -)" )
}
[[ "$(jr false yes viewer)" == "rc=0 GET /Users|POST /Users/Password?userId=v1|POST /Users/AuthenticateByName|POST /Sessions/Logout" ]] \
    || fail_ "reset-password (Wizarr): set, proven by signing in, the proof's session ended: $(jr false yes viewer)"; pass
grep -E '^  Temporary password for viewer:  [A-Za-z0-9]{16}$' "$T/jr" >/dev/null || fail_ "the temporary password is shown once, 16 characters: $(cat "$T/jr")"; pass
[[ "$(jr false no viewer)" == rc=1* ]] || fail_ "the new password does not sign in: a failure, not a password handed out"; pass
! grep 'Temporary password' "$T/jr" >/dev/null || fail_ "an unproven password is never shown"; pass
[[ "$(jr true no viewer)" == "rc=0 GET /Users|POST /Users/Password?userId=v1" ]] && grep 'disabled in Jellyfin' "$T/jr" >/dev/null \
    || fail_ "a disabled account: the password set, the state said, nothing re-enabled: $(jr true no viewer)"; pass
[[ "$(jr false yes admin)" == "rc=1 GET /Users" ]] || fail_ "the stack's own admin: refused (set-credentials jellyfin): $(jr false yes admin)"; pass
[[ "$(jr false yes nobody)" == "rc=1 GET /Users" ]] || fail_ "no such user: refused, nothing written"; pass

echo "OK wire: $checks checks"
