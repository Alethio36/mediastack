#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# scripts/test-dl-login.sh — a download client's login changes, and every copy follows:
#   * dl_login_follow: the arr family's entries, then each enabled service's
#     own <svc>_dl_login_resync, found by its name; qBittorrent, Deluge and
#     Transmission's set-credentials all go through it
#   * an arr's entry is found by mediastack's own entry name — found in the
#     whole-code audit: qBittorrent's rotation took the first QBittorrent
#     entry, so a second one of yours got the stack's login
#   * LazyLibrarian's values reach it URL-encoded (a password with & # + or a
#     space arrived cut or changed), and its qBittorrent login follows
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-dl-login.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "OK $*" >> "$T/out"; }; info() { echo "INFO $*" >> "$T/out"; }; warn() { echo "WARN $*" >> "$T/out"; }
wfail() { echo "WFAIL $*" >> "$T/out"; }

# ---- the fan-out ----
( arr_dl_login_resync() { echo "arr $1" >> "$T/calls"; }
  svc_enabled_managed() { printf '%s\n' sonarr cleanuparr lazylibrarian; }
  cleanuparr_dl_login_resync() { echo "cleanuparr $1" >> "$T/calls"; }
  lazylibrarian_dl_login_resync() { echo "lazylibrarian $1" >> "$T/calls"; }
  : > "$T/calls"; dl_login_follow deluge
  [[ "$(paste -sd, "$T/calls")" == "arr deluge,cleanuparr deluge,lazylibrarian deluge" ]] ) \
    || fail_ "dl_login_follow: the arrs, then each enabled service's own hook: $(paste -sd, "$T/calls")"; pass
for s in qbittorrent deluge transmission; do
    f=$(declare -f "sc_rotate_${s/qbittorrent/qbit}")
    grep -E "dl_login_follow $s\b" <<<"$f" >/dev/null || fail_ "set-credentials $s: its copies follow through dl_login_follow"
    ! grep -E 'implementation *== *"QBittorrent"|cleanuparr_dl_login_resync|arr_dl_login_resync|ll_api' <<<"$f" >/dev/null \
        || fail_ "set-credentials $s does none of the follow-up itself"
done; pass

# ---- an arr's entry: mediastack's own, by name, never the first of its kind ----
LIST='[{"id":1,"name":"qBittorrent","implementation":"QBittorrent","fields":[{"name":"username","value":"yours"},{"name":"password","value":"********"}]},
       {"id":2,"name":"qBittorrent (mediastack)","implementation":"QBittorrent","fields":[{"name":"username","value":"old"},{"name":"password","value":"********"}]}]'
( arr_instances() { echo sonarr; }; svc_enabled() { [[ "$1" == sonarr ]]; }
  arr_key() { echo K; }; arr_url() { echo http://s; }; arr_apiver() { echo v3; }
  role_entry() { echo '{"fields":{"username":"newuser","password":"newpass"}}'; }
  api() { if [[ "$1" == GET ]]; then echo "$LIST"; else echo "$1 $2 $4" >> "$T/put"; fi; }
  : > "$T/put"; : > "$T/out"; arr_dl_login_resync qbittorrent
  [[ "$(wc -l < "$T/put")" == 1 ]] && grep -F 'PUT http://s/api/v3/downloadclient/2 ' "$T/put" >/dev/null \
    && grep -F '"value":"newuser"' "$T/put" >/dev/null ) \
    || fail_ "only mediastack's entry (id 2) takes the new login, yours (id 1) is left alone: $(cat "$T/put")"; pass

# ---- LazyLibrarian: values encoded, its qBittorrent login follows ----
( ll_key() { echo LK; }; ll_url() { echo http://ll; }
  scurl() { printf '%s\n' "${*: -1}" >> "$T/ll"; echo OK; }
  : > "$T/ll"; ll_api writeCFG name=PASS group=QBITTORRENT 'value=p&w#d +x=y%'
  [[ "$(cat "$T/ll")" == 'http://ll/api?apikey=LK&cmd=writeCFG&name=PASS&group=QBITTORRENT&value=p%26w%23d%20%2Bx%3Dy%25' ]] ) \
    || fail_ "ll_api encodes each value: $(cat "$T/ll")"; pass
( ll_key() { echo LK; }; ll_url() { echo http://ll; }; svc_enabled() { [[ "$1" == lazylibrarian ]]; }
  env_get() { case "$1" in QBITTORRENT_USER) echo u1 ;; QBITTORRENT_PASSWORD) echo 'p&1' ;; esac; }
  scurl() { printf '%s\n' "${*: -1}" >> "$T/ll"; echo OK; }
  : > "$T/ll"; : > "$T/out"; lazylibrarian_dl_login_resync deluge
  [[ ! -s "$T/ll" ]] || exit 1
  lazylibrarian_dl_login_resync qbittorrent
  [[ "$(cat "$T/ll")" == "http://ll/api?apikey=LK&cmd=writeCFG&name=USER&group=QBITTORRENT&value=u1
http://ll/api?apikey=LK&cmd=writeCFG&name=PASS&group=QBITTORRENT&value=p%261
http://ll/api?apikey=LK&cmd=loadCFG" ]] \
    && grep -F "OK lazylibrarian: its qBittorrent login updated" "$T/out" >/dev/null ) \
    || fail_ "LazyLibrarian: only qBittorrent's login, both fields, then its config reloaded: $(cat "$T/ll")"; pass

echo "OK dl-login: $checks checks"
