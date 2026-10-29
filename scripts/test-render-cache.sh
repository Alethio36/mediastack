#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced entrypoint
# test-render-cache.sh — `docker compose config` runs once per command, not
# once per helper call (render's CACHING SEMANTICS, mediastack.sh):
#   * arr_instances renders in its own scope, so its $(svc_label) per service
#     reuses that render — called inside a $( ) itself, it still renders once
#   * trash_instances (both arr types) renders once
#   * a caller that rendered first passes its render down: no render at all
# Found live (Oct 2026): trash-sync rendered ~150 times, two silent minutes
# before its first line. Sources the real entrypoint (minus main "$@"); DC is
# a stub that counts renders.
#
#   scripts/test-render-cache.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-render-cache.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"
set +e +E; trap - ERR

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

user_compose_files() { USER_FILES=(); }
env_get() { [[ "$1" == COMPOSE_PROFILES ]] && echo "sonarr,sonarr-anime,radarr,jellyfin"; }
DC() { # the one render: counted
    [[ " $* " == *" config "* ]] || return 0
    echo x >> "$T/renders"
    cat <<'JSON'
{"services":{
 "sonarr":{"labels":{"mediastack.managed":"true","mediastack.arrtype":"sonarr"}},
 "sonarr-anime":{"labels":{"mediastack.managed":"true","mediastack.arrtype":"sonarr"}},
 "radarr":{"labels":{"mediastack.managed":"true","mediastack.arrtype":"radarr"}},
 "radarr-4k":{"labels":{"mediastack.managed":"true","mediastack.arrtype":"radarr"}},
 "jellyfin":{"labels":{"mediastack.managed":"true"}}}}
JSON
}
renders() { [[ -e "$T/renders" ]] && wc -l < "$T/renders" || echo 0; }
fresh() { RENDERED_JSON=""; rm -f "$T/renders"; }

fresh; out=$(arr_instances sonarr)
[[ "$out" == $'sonarr\nsonarr-anime' ]] || fail_ "arr_instances sonarr: wrong instances ($out)"; pass
(( $(renders) == 1 )) || fail_ "arr_instances inside a \$( ): $(renders) renders, expected 1"; pass

fresh; out=$(trash_instances)
[[ "$out" == $'sonarr\nsonarr-anime\nradarr' ]] || fail_ "trash_instances: only enabled arrs, sonarr first ($out)"; pass
(( $(renders) == 1 )) || fail_ "trash_instances: $(renders) renders, expected 1"; pass

fresh; render; out=$(trash_instances); out=$(trash_instances)
(( $(renders) == 1 )) || fail_ "a caller that rendered first: $(renders) renders, expected its own 1"; pass

echo "test-render-cache: $checks checks passed"
