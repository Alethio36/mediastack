#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-ll-client.sh — wire_lazylibrarian's download client
# (services/lazylibrarian/lazylibrarian.sh) follows the stack's choice:
#   * qBittorrent chosen: its settings are written, then the book folders
#   * another client chosen: a WARN naming it and where to add it, nothing
#     of qBittorrent's written — the book folders still are
#   * a dry run writes nothing
# Sources the real entrypoint (minus its last line, main "$@"); the API and
# the service lookups are stubs.
#
#   scripts/test-ll-client.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-ll-client.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

DL=qbittorrent
svc_enabled() { [[ $1 == lazylibrarian ]]; }
wire_gate()   { :; }
http_ready()  { :; }
ll_url()      { echo http://ll; }
ll_key()      { echo k; }
ll_login()    { :; }
role_pick()   { echo "$DL"; }
svc_host()    { echo "$1"; }
svc_cport()   { echo 8080; }
env_get()     { case $1 in QBITTORRENT_USER) echo admin ;; QBITTORRENT_PASSWORD) echo pw ;; esac; }
ll_api()      { echo "$1 ${2:-}" >> "$T/api"; echo '{}'; }
run() { rm -f "$T/api"; WIRE_FAILS=0; wire_lazylibrarian > "$T/out" 2>&1 || true; }

DL=qbittorrent WIRE_DRY=0; run
grep -q 'group=QBITTORRENT' "$T/api" && grep -q 'TOR_DOWNLOADER&group=General&value=qbittorrent' "$T/api" || fail_ "qBittorrent chosen: its settings are written"; pass
grep -q 'EBOOK_DEST_FOLDER' "$T/api" && (( WIRE_FAILS == 0 )) || fail_ "and the book folders"; pass

DL=deluge; run
! grep -q 'QBITTORRENT\|TOR_DOWNLOADER' "$T/api" || fail_ "deluge chosen: nothing of qBittorrent's is written — $(cat "$T/api")"; pass
grep -q "WARN.*download client is deluge.*add deluge in its UI" "$T/out" || fail_ "a WARN names the client and where to add it — $(cat "$T/out")"; pass
grep -q 'EBOOK_DEST_FOLDER' "$T/api" && (( WIRE_FAILS == 0 )) || fail_ "the book folders are still set, and that is no failure"; pass

DL=qbittorrent WIRE_DRY=1; run
[[ ! -e "$T/api" ]] && grep -q 'would: point lazylibrarian at qBittorrent' "$T/out" || fail_ "a dry run writes nothing — $(cat "$T/out")"; pass

echo "test-ll-client: $checks checks passed"
