#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-shard.sh — a service and its private containers are one shard.
#   * members are found by `mediastack.shard: <primary>`; a primary expands
#     to itself then its members, in a stable order
#   * the shard rules hold: the primary exists and is managed, a member is not
#     managed itself, shares the primary's profiles and user, and the primary
#     depends_on it — each broken rule is named
#   * status shows a shard "degraded" when any member is not up, and the
#     container cache that status and doctor read includes the members
#
#   scripts/test-shard.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-shard.XXXXXX)
trap 'rm -f "$lib"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }
render() { :; }   # RENDERED_JSON is set by each case

good='{"services":{
  "idp":        {"profiles":["idp"],"user":"13050:13000","depends_on":{"idp-worker":{},"idp-db":{}},"labels":{"mediastack.managed":"true"}},
  "idp-worker": {"profiles":["idp"],"user":"13050:13000","labels":{"mediastack.shard":"idp"}},
  "idp-db":     {"profiles":["idp"],"user":"13050:13000","labels":{"mediastack.shard":"idp"}},
  "radarr":     {"profiles":["radarr"],"labels":{"mediastack.managed":"true"}}}}'
RENDERED_JSON=$good
[[ "$(svc_members idp | tr '\n' ' ')" == "idp-db idp-worker " ]] || fail_ "members: $(svc_members idp)"; pass
[[ "$(svc_shard radarr idp | tr '\n' ' ')" == "radarr idp idp-db idp-worker " ]] || fail_ "shard expansion: $(svc_shard radarr idp)"; pass
[[ -z "$(svc_members radarr)" ]] || fail_ "a service without members has none"; pass
[[ -z "$(shard_problems)" ]] || fail_ "a well-formed shard: $(shard_problems)"; pass

broken() { # broken JQ-EDIT WANT — the edit applied to the good shard must be named
    RENDERED_JSON=$(jq -c "$1" <<<"$good")
    local got; got=$(shard_problems)
    [[ "$got" == *"$2"* ]] || fail_ "'$1' should report '$2', got: ${got:-nothing}"; pass
}
broken '.services["idp-db"].labels["mediastack.shard"] = "nope"'   'its primary nope does not exist'
broken '.services.idp.labels = {}'                                  'its primary idp is not a managed service'
broken '.services["idp-db"].labels["mediastack.managed"] = "true"'  'must not carry mediastack.managed'
broken '.services["idp-db"].profiles = ["other"]'                   'profiles differ from its primary idp'
broken '.services["idp-db"].user = "999:999"'                       'runs as 999:999, not as its primary idp'
broken 'del(.services.idp.depends_on["idp-worker"])'                'its primary idp must depend_on it'

# ---- status: a member down makes the shard degraded ----
RENDERED_JSON=$good
svc_cname() { echo "c-$1"; }
STATE_DB=running; HEALTH_DB=healthy
c_state()  { case "$1" in c-idp-db) echo "$STATE_DB" ;; *) echo running ;; esac; }
c_health() { case "$1" in c-idp-db) echo "$HEALTH_DB" ;; *) echo healthy ;; esac; }
[[ "$(shard_health idp)" == healthy ]] || fail_ "all members up: the primary's health"; pass
HEALTH_DB=unhealthy; [[ "$(shard_health idp)" == degraded ]] || fail_ "an unhealthy member: degraded"; pass
STATE_DB=exited; HEALTH_DB=-; [[ "$(shard_health idp)" == degraded ]] || fail_ "a stopped member: degraded"; pass
[[ "$(shard_health radarr)" == healthy ]] || fail_ "no members: the service's own health"; pass

# ---- the container cache includes members ----
# (found live: members were never inspected, so a healthy shard read "degraded")
RENDERED_JSON=$good
c_inspect() { printf '%s\n' "$@" > "$T_NAMES"; echo '[]'; }
T_NAMES=$(mktemp); c_inspect_all
[[ "$(sort "$T_NAMES" | tr '\n' ' ')" == "idp idp-db idp-worker radarr " ]] || fail_ "inspected: $(tr '\n' ' ' < "$T_NAMES")"; pass
rm -f "$T_NAMES"

# ---- a shard is recorded, restored and unpinned whole (repro 8 Oct 2026: ----
# ---- full points held only the primary; unpin left the members pinned)  ----
RENDERED_JSON=$good
svc_managed() { echo idp radarr; }
[[ "$(point_services | tr '\n' ' ')" == "idp idp-db idp-worker radarr " ]] || fail_ "a full point records every member: $(point_services)"; pass
grep -qF 'point_record "$dest" "$1" "$2" $(point_services)' <(awk '/^backup_take\(\)/,/^}/' lib/backup.sh) \
    || fail_ "backup_take records point_services, not only the managed services"; pass

P=$(mktemp -d); trap 'rm -f "$lib"; rm -rf "$P"' EXIT
printf 'idp a\nidp-db b\nidp-worker c\nradarr d\n' > "$P/images.lock"
( point_shard_check "$P" idp ) || fail_ "a shard recorded whole restores"; pass
printf 'radarr d\n' > "$P/images.lock"
( point_shard_check "$P" idp ) || fail_ "a shard not recorded at all restores (nothing to pin)"; pass
printf 'idp a\nradarr d\n' > "$P/images.lock"
out=$( ( point_shard_check "$P" idp ) 2>&1 ) && fail_ "a point holding only the primary must refuse"; pass
[[ "$out" == *"records the image of idp but not of idp-db idp-worker"* && "$out" == *"backup list idp"* ]] || fail_ "the refusal names the gap and the way out: $out"; pass

( shard_member_refuse idp rollback ) || fail_ "a primary is handled"; pass
out=$( ( shard_member_refuse idp-db rollback ) 2>&1 ) && fail_ "a member alone must refuse"; pass
[[ "$out" == *"idp-db is part of idp"*"mediastack.sh rollback idp"* ]] || fail_ "the refusal names the primary: $out"; pass

load_env() { :; }; repo_owned() { :; }; ok() { echo "OK $*"; }
DC() { echo "DC $*" >> "$P/log"; }
PINS_FILE=$P/pins.yml
printf 'services:\n  idp:\n    image: x:1\n  idp-worker:\n    image: x:1\n  idp-db:\n    image: y:1\n  radarr:\n    image: r:1\n' > "$PINS_FILE"
out=$(cmd_unpin idp-worker)
[[ "$(cat "$PINS_FILE")" == $'services:\n  radarr:\n    image: r:1' ]] || fail_ "unpin by a member releases the whole shard, nothing else: $(cat "$PINS_FILE")"; pass
[[ "$(cat "$P/log")" == "DC up -d idp" && "$out" == *"Unpinned idp idp-db idp-worker"* ]] || fail_ "the shard starts by its primary, every pin named: $out / $(cat "$P/log")"; pass

# ---- the update summary sees an image change without a version label ----
[[ -z "$(update_change db "" r@sha256:aaaa "" r@sha256:aaaa)" ]] || fail_ "same digest: no change"; pass
[[ "$(update_change db "" r@sha256:aaaaaaaaaaaaaaaa "" r@sha256:bbbbbbbbbbbbbbbb)" == "db: sha256:aaaaaaaaaaaa -> sha256:bbbbbbbbbbbb" ]] \
    || fail_ "no version label: the digest stands in: $(update_change db "" r@sha256:aaaaaaaaaaaaaaaa "" r@sha256:bbbbbbbbbbbbbbbb)"; pass
[[ "$(update_change app 1.0 r@sha256:a 1.1 r@sha256:b)" == "app: 1.0 -> 1.1" ]] || fail_ "a version label is shown when it changed"; pass

echo "OK shard: $checks checks"
