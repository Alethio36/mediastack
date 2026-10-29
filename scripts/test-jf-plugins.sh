#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-jf-plugins.sh — the plugins the stack depends on, and why one is missing
# (services/jellyfin/jellyfin.sh), plus Prowlarr's FlareSolverr registration:
#   * an install refused while Jellyfin's catalog is empty says why: its
#     repository unreachable from Jellyfin (found live, Oct 2026: a network
#     block), naming the address and curl's own words; a catalog that has
#     packages adds nothing
#   * doctor: with the portal on, LDAP Authentication must be loaded (Active);
#     with WatchState on, Webhook — missing or not Active is a problem
#   * doctor: a repository Jellyfin cannot reach is named, with the reason
#   * Prowlarr's FlareSolverr registration waits as long as the re-test does
#     (FlareSolverr starts its browser on the first request) and keeps
#     Prowlarr's answer when it fails
# Sources the real entrypoint (minus its last line, main "$@"); Jellyfin's API
# and docker are stubs.
#
#   scripts/test-jf-plugins.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-jf-plugins.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"
set +e +E; trap - ERR

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

REPO=https://repo.jellyfin.org/files/plugin/manifest.json
PACKAGES='[]' PLUGINS='[]' REACH="curl: (7) Failed to connect to repo.jellyfin.org port 443 after 6 ms: Could not connect to server"
ENABLED="authentik watchstate"
svc_enabled() { [[ " $ENABLED " == *" $1 "* ]]; }
signin_is()   { [[ $1 == authentik ]] && svc_enabled authentik; }   # the portal is the account model
svc_cname()   { echo "mediastack-$1"; }
jf_code()     { echo 404; }
jf_api() { # GET answers the fixtures; the install POST is refused
    case "$1 $2" in
        "GET /Packages")     echo "$PACKAGES" ;;
        "GET /Repositories") echo "[{\"Name\":\"Jellyfin Stable\",\"Url\":\"$REPO\",\"Enabled\":true}]" ;;
        "GET /Plugins")      echo "$PLUGINS" ;;
        POST*)               return 1 ;;
    esac
}
sudo() { # docker exec mediastack-jellyfin curl ...: the reach, or 200
    [[ "$*" == *"docker exec mediastack-jellyfin curl"* ]] || return 0
    # as curl -w '\n%{http_code}' answers: its error (stderr), then the code
    if [[ -n "$REACH" ]]; then printf '%s\n000' "$REACH"; return 7; fi
    printf '\n301'   # the repository redirects to its mirror
}

# ---- why an install was refused ----
r=$(jf_catalog_reason tok)
[[ "$r" == *"catalog is empty — Jellyfin cannot reach its repository ($REPO: curl: (7) Failed to connect"* ]] \
    || fail_ "an empty catalog and a blocked repository: named, with curl's words ($r)"; pass
PACKAGES='[{"name":"LDAP Authentication"}]'; r=$(jf_catalog_reason tok)
[[ -z "$r" ]] || fail_ "a catalog with packages: nothing added ($r)"; pass
PACKAGES='[]' REACH=""; r=$(jf_catalog_reason tok)
[[ "$r" == *"its repository answers now — retry"* ]] || fail_ "empty catalog, repository reachable again: say retry ($r)"; pass

wfail() { echo "WFAIL $*" >> "$T/wf"; }; w_would() { return 0; }; ok() { echo "OK $*" >> "$T/out"; }
REACH="curl: (7) refused"; : > "$T/wf"
jf_plugins_ensure tok "LDAP Authentication|$JF_LDAP_GUID|portal accounts sign in to Jellyfin" || true
grep -q "LDAP Authentication plugin install rejected \[HTTP 404\], Jellyfin's plugin catalog is empty — Jellyfin cannot reach its repository" "$T/wf" \
    || fail_ "wire's failure carries the reason: $(cat "$T/wf")"; pass

# ---- doctor ----
D_FAILS=0
d_fail() { echo "DFAIL $1 | $2" >> "$T/d"; D_FAILS=$((D_FAILS+1)); }
warn()   { echo "WARN $*" >> "$T/d"; }
ok()     { echo "OK $*" >> "$T/d"; }
doc() { PLUGINS=$1; REACH=${2-}; : > "$T/d"; D_FAILS=0; jellyfin_doctor_plugins tok; }
LDAP_ID=958aad66-3784-4d2a-b89a-a7b6fab6e25c WH_ID=71552a5a-5c5c-4350-a2ae-ebe451a30173
doc "[{\"Id\":\"${LDAP_ID//-/}\",\"Status\":\"Active\"},{\"Id\":\"$WH_ID\",\"Status\":\"Active\"}]"
(( D_FAILS == 0 )) && grep -q "OK jellyfin: LDAP Authentication plugin loaded" "$T/d" && grep -q "OK jellyfin reaches its plugin repository" "$T/d" \
    || fail_ "both loaded (ids in either form), repository reachable: clean — $(cat "$T/d")"; pass
doc "[{\"Id\":\"$WH_ID\",\"Status\":\"Active\"}]"
(( D_FAILS == 1 )) && grep -q "DFAIL jellyfin: LDAP Authentication plugin is not installed | portal accounts cannot sign in" "$T/d" \
    || fail_ "LDAP missing with the portal on: a problem — $(cat "$T/d")"; pass
doc "[{\"Id\":\"$LDAP_ID\",\"Status\":\"Restart\"},{\"Id\":\"$WH_ID\",\"Status\":\"Active\"}]"
(( D_FAILS == 1 )) && grep -q "plugin is Restart, not loaded" "$T/d" || fail_ "installed, not Active: a problem — $(cat "$T/d")"; pass
ENABLED=""; doc '[]'
(( D_FAILS == 0 )) || fail_ "no portal, no WatchState: no plugin required — $(cat "$T/d")"; pass
ENABLED="authentik watchstate"; doc "[{\"Id\":\"$LDAP_ID\",\"Status\":\"Active\"},{\"Id\":\"$WH_ID\",\"Status\":\"Active\"}]" "curl: (7) refused"
grep -q "WARN jellyfin cannot reach its plugin repository ($REPO: curl: (7) refused)" "$T/d" \
    || fail_ "a blocked repository is named — $(cat "$T/d")"; pass

# ---- Prowlarr's FlareSolverr registration ----
grep -q 'fout=$(API_TIMEOUT=$PROWLARR_TEST_WAIT api POST "$purl/api/v1/indexerproxy"' services/prowlarr/prowlarr.sh \
    || fail_ "the FlareSolverr registration lost the re-test's wait (FlareSolverr's first request starts its browser)"; pass
grep -q 'wfail "flaresolverr proxy registration failed — $(oneline' services/prowlarr/prowlarr.sh \
    || fail_ "the FlareSolverr registration's failure lost Prowlarr's answer"; pass

echo "test-jf-plugins: $checks checks passed"
