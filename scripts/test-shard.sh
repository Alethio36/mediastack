#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-shard.sh — a service and its private containers are one shard.
#   * members are found by `mediastack.shard: <primary>`; a primary expands
#     to itself then its members, in a stable order
#   * the shard rules hold: the primary exists and is managed, a member is not
#     managed itself, shares the primary's profiles and user, and the primary
#     depends_on it — each broken rule is named
#   * status shows a shard "degraded" when any member is not up
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

echo "OK shard: $checks checks"
