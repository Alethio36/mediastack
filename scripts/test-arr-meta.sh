#!/usr/bin/env bash
# test-arr-meta.sh — ARR_META, the one table of per-arr-type facts wire uses.
# A type added to a fragment (mediastack.arrtype) but not to the table, or a
# row missing a field, used to mean a silently wrong API call; arr_meta now
# dies on the gap, and this makes the gap a CI failure instead of a wire FAIL.
#
#   scripts/test-arr-meta.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-arr-meta.XXXXXX)
trap 'rm -f "$lib"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

FIELDS=(api impl catfield major jftype jfname)
mapfile -t types < <(for k in "${!ARR_META[@]}"; do echo "${k%%.*}"; done | sort -u)
(( ${#types[@]} > 0 )) || fail_ "ARR_META is empty"
for t in "${types[@]}"; do
    for f in "${FIELDS[@]}"; do
        [[ -n "${ARR_META[$t.$f]:-}" ]] || fail_ "ARR_META: type '$t' has no '$f'"
    done
    arr_known "$t" || fail_ "arr_known must accept '$t'"
done; pass

# every arrtype a shipped fragment declares is a row in the table
while read -r t; do
    arr_known "$t" || fail_ "compose.d declares mediastack.arrtype '$t' but ARR_META has no row for it"
done < <(grep -hoE 'mediastack\.arrtype: *"[^"]+"' compose.d/*.yml | sed -E 's/.*"([^"]+)"/\1/' | sort -u); pass

# unknown types: arr_known says no, arr_meta dies naming the gap
arr_known readarr && fail_ "arr_known must reject an unknown type"; pass
set +e; out=$( ( arr_meta readarr api ) 2>&1 ); rc=$?; set -e
[[ $rc != 0 && "$out" == *"arr type 'readarr' has no 'api' in ARR_META"* ]] || fail_ "arr_meta on an unknown type must die loud: $out"; pass

echo "OK arr-meta: $checks checks (${#types[@]} types x ${#FIELDS[@]} fields)"
