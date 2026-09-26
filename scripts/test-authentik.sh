#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-authentik.sh — the authentik shard's rules.
#   * upgrades walk authentik's releases one at a time and never go back; a
#     new database may start on any known release; the release is read from an
#     image tag or a version
#   * secrets: generated once, letters and digits only, never replaced — and
#     refused outright when the database already exists without them
#   * account models: authentik and Wizarr conflict (declared on either side),
#     and a conflict pair in a selection is found
#   * a shard member is never a dependency to enable (it comes with its
#     primary's profile)
#   * a service an upgrade adds gets its UID before it first starts
#
#   scripts/test-authentik.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-authentik.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }
ok() { :; }

# ---- the upgrade path ----
AUTHENTIK_RELEASES=(2026.2 2026.5 2026.8)
[[ "$(authentik_step "" 2026.8)" == ok ]] || fail_ "a new database may start on any known release"; pass
[[ "$(authentik_step 2026.8 2026.8)" == ok ]] || fail_ "the same release (a patch update) is fine"; pass
[[ "$(authentik_step 2026.5 2026.8)" == ok ]] || fail_ "the next release is fine"; pass
got=$(authentik_step 2026.2 2026.8)
[[ "$got" == *"must not skip"*"2026.2 -> 2026.5 first"*"update authentik --to 2026.5"* ]] || fail_ "skipping: $got"; pass
got=$(authentik_step 2026.8 2026.5)
[[ "$got" == *"cannot go back"*"rollback authentik"* ]] || fail_ "going back: $got"; pass
[[ "$(authentik_step 2026.5 2027.1)" == *"not an authentik release this version of mediastack knows"* ]] || fail_ "an unknown target"; pass
[[ "$(authentik_step 2025.10 2026.2)" == *"which this version of mediastack does not know"* ]] || fail_ "an unknown starting release"; pass
[[ "$(authentik_release_of ghcr.io/goauthentik/server:2026.8)" == 2026.8 ]] || fail_ "release from an image tag"; pass
[[ "$(authentik_release_of 2026.8.3)" == 2026.8 ]] || fail_ "release from a version"; pass
if authentik_release_of ghcr.io/goauthentik/server:latest >/dev/null; then fail_ "'latest' names no release"; fi; pass
# the fragment's tag is a release the list knows (so a fresh install can start)
tag=$(awk '/image: ghcr.io\/goauthentik\/server:/ { sub(/.*:/, ""); print; exit }' compose.d/authentik.yml)
[[ " ${AUTHENTIK_RELEASES[*]} " == *" $(authentik_release_of "$tag") "* ]] || fail_ "the fragment's tag $tag is not in AUTHENTIK_RELEASES"; pass
[[ "$(grep -c "image: ghcr.io/goauthentik/server:$tag$" compose.d/authentik.yml)" == 2 ]] || fail_ "server and worker must run the same tag"; pass

# ---- secrets ----
s=$(authentik_secret 60)
[[ ${#s} == 60 && "$s" =~ ^[A-Za-z0-9]+$ ]] || fail_ "a secret: 60 letters and digits, got '$s'"; pass
ENV_FILE=$T/env; printf 'AUTHENTIK_DB_PASSWORD=keepme\n' > "$ENV_FILE"
authentik_has_db() { return 1; }
authentik_secrets
[[ "$(env_get AUTHENTIK_DB_PASSWORD)" == keepme ]] || fail_ "an existing secret must never be replaced"; pass
[[ "$(env_get AUTHENTIK_SECRET_KEY | wc -c)" == 61 && "$(env_get AUTHENTIK_API_TOKEN | wc -c)" == 65 ]] \
    || fail_ "missing secrets must be generated at their lengths"; pass
printf 'AUTHENTIK_SECRET_KEY=x\n' > "$ENV_FILE"
authentik_has_db() { return 0; }
out=$( (authentik_secrets) 2>&1 ) && fail_ "a database without its password must stop, not get a new one"
[[ "$out" == *"AUTHENTIK_DB_PASSWORD is missing"* ]] || fail_ "the refusal must name the missing secret: $out"; pass
[[ "$(env_get AUTHENTIK_DB_PASSWORD)" == "" ]] || fail_ "nothing may be written when refusing"; pass

# ---- conflicts and dependencies ----
render() { :; }
RENDERED_JSON='{"services":{
  "authentik":        {"depends_on":{"authentik-db":{},"authentik-worker":{}},"labels":{"mediastack.managed":"true","mediastack.conflicts":"wizarr"}},
  "authentik-worker": {"labels":{"mediastack.shard":"authentik"}},
  "authentik-db":     {"labels":{"mediastack.shard":"authentik"}},
  "wizarr":           {"depends_on":{"jellyfin":{}},"labels":{"mediastack.managed":"true"}},
  "jellyfin":         {"labels":{"mediastack.managed":"true"}}}}'
[[ "$(svc_conflicts wizarr)" == authentik ]] || fail_ "a conflict declared on one side counts for both"; pass
[[ "$(conflicts_in jellyfin wizarr authentik)" == "authentik wizarr" ]] || fail_ "the conflicting pair: $(conflicts_in jellyfin wizarr authentik)"; pass
[[ -z "$(conflicts_in jellyfin authentik)" ]] || fail_ "no pair, no conflict"; pass
[[ -z "$(svc_deps authentik)" ]] || fail_ "a shard member is not a dependency to enable: $(svc_deps authentik)"; pass
[[ "$(svc_deps wizarr)" == jellyfin ]] || fail_ "ordinary dependencies are unchanged"; pass

# ---- a service an upgrade adds gets its UID before it first starts ----
# (found live: an install upgraded to authentik ran it as the images' default
# users — the UID was only allocated by `configure`)
info() { echo "INFO $*" >> "$T/info"; }
CUSTOM_DIR=$T/custom
printf 'UID_BASE=13000\nSONARR_UID=13001\nRADARR_UID=13028\n' > "$ENV_FILE"
_configure_selfheal
u=$(env_get AUTHENTIK_UID)
[[ "$u" =~ ^[0-9]+$ ]] && (( u > 13028 )) \
    || fail_ "a new service gets a UID above every existing one: '$u'"; pass
[[ -z "$(grep -E '_UID=[0-9]+$' "$ENV_FILE" | cut -d= -f2 | sort | uniq -d)" ]] || fail_ "allocated UIDs must be unique"; pass
before=$(cat "$ENV_FILE"); rm -f "$T/info"; _configure_selfheal
[[ "$(cat "$ENV_FILE")" == "$before" && ! -e "$T/info" ]] || fail_ "a second run changes nothing and says nothing"; pass
grep -q '^    _configure_selfheal' <(sed -n '/^provision() {/,/^}/p' mediastack.sh) \
    || fail_ "provision (up, enable) must allocate new services' UIDs"; pass

echo "OK authentik: $checks checks"
