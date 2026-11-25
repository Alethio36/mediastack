#!/usr/bin/env bash
# check-schema-bump.sh — a change to .env.example's settings comes with a
# bump of ENV_SCHEMA (and a migration, lib/migrations.sh), because installs
# migrate their .env by it. One kind of change needs none: lines added for a
# service added in the same range — its <SVC>_UID and <SVC>_UPDATE, and the
# keys of its own env.tsv. Existing installs need nothing written for them:
# its UID is allocated when it is first started (_configure_selfheal), its
# logins recorded when it is enabled (logins_fill), its update flag reads
# true when absent, and every other key has its default in the schema.
#
#   scripts/check-schema-bump.sh BASE [HEAD]    (HEAD defaults to HEAD)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
base=${1:?usage: check-schema-bump.sh BASE [HEAD]}; head=${2:-HEAD}

changed=$(git diff -U0 "$base" "$head" -- .env.example | sed -nE 's/^([+-])([A-Z][A-Z0-9_]*)=.*/\1\2/p')
[[ -n "$changed" ]] || { echo "OK schema bump: no setting line of .env.example changed"; exit 0; }
if grep -qxE '[+-]ENV_SCHEMA' <<<"$changed"; then echo "OK schema bump: ENV_SCHEMA moved with the settings"; exit 0; fi

# the services added in the range, and the keys that are theirs alone
mapfile -t added < <(git diff --name-only --diff-filter=A "$base" "$head" -- 'services/*/compose.yml' | sed -E 's|^services/([^/]+)/compose.yml$|\1|')
own=" "
for s in "${added[@]}"; do
    stem=$(tr 'a-z-' 'A-Z_' <<<"$s")
    own+="${stem}_UID ${stem}_UPDATE "
    own+="$(git show "$head:services/$s/env.tsv" 2>/dev/null | awk -F'\t' '!/^#/ && NF > 1 { printf "%s ", $1 }' || true) "   # soft read: a service with no settings of its own
done
bad=""
while IFS= read -r c; do
    sign=${c:0:1}; key=${c:1}
    if [[ "$sign" == + && "$own" == *" $key "* ]]; then continue; fi
    bad+="$c "
done <<<"$changed"
if [[ -z "$bad" ]]; then
    echo "OK schema bump: only new services' own settings added (${added[*]}) — nothing for an install to migrate"; exit 0
fi
echo "::error::.env.example changed without bumping ENV_SCHEMA (and adding a migration): $bad"
echo "  (a new service's own lines need neither: its <SVC>_UID, <SVC>_UPDATE and its env.tsv keys, added with its folder)"
exit 1
