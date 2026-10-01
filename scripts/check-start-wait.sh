#!/usr/bin/env bash
# check-start-wait.sh — the health-verdict wait (START_WAIT) must exceed
# every healthcheck's Docker verdict window, start_period + interval x retries;
# otherwise a wait FAILs a service Docker hasn't judged yet. Every block
# counts: an inline `healthcheck:` and a top-level `x-*:` anchor one or more
# services point at (compose.d/authentik.yml has both). Durations are plain
# seconds ("60s") — anything else fails loud here rather than being silently
# skipped.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

wait=$(sed -nE 's/^START_WAIT=([0-9]+).*/\1/p' mediastack.sh)
[[ -n "$wait" ]] || { echo "ERROR START_WAIT not found in mediastack.sh" >&2; exit 1; }

max=0 worst="" rc=0
for f in compose.d/*.yml; do
    # one line per block: "<name> <interval> <retries> <start_period>" ("-" = unset)
    while read -r name iv rt sp; do
        for d in "$iv" "$sp"; do
            [[ "$d" == - || "$d" =~ ^[0-9]+s$ ]] || { echo "ERROR $f ($name): duration '$d' is not plain seconds (Ns)" >&2; rc=1; }
        done
        (( rc )) && continue
        # docker defaults: interval 30s, retries 3, start_period 0s
        iv=${iv/-/30s}; rt=${rt/-/3}; sp=${sp/-/0s}
        win=$(( ${sp%s} + ${iv%s} * rt ))
        (( win > max )) && { max=$win; worst="$(basename "$f" .yml) ($name)"; }
    done < <(awk '
        function flush() { if (name != "" && length(v) > 0) printf "%s %s %s %s\n", name, (v["interval"] ? v["interval"] : "-"), (v["retries"] ? v["retries"] : "-"), (v["start_period"] ? v["start_period"] : "-"); name = ""; delete v }
        # a block starts at a top-level anchor (x-foo: &foo) or an inline "healthcheck:" with its fields below;
        # "healthcheck: *ref" points at an anchor already counted; a block with none of the three fields is not one
        /^x-[A-Za-z0-9_-]+:[[:space:]]*&/ { flush(); name = $1; sub(/:$/, "", name); depth = 0; next }
        /^[[:space:]]+healthcheck:[[:space:]]*$/ { flush(); match($0, /^[[:space:]]+/); depth = RLENGTH; name = "healthcheck@" NR; next }
        name != "" {
            match($0, /^[[:space:]]*/); ind = RLENGTH
            if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) next
            if (ind <= depth) { flush(); next }
            if ($0 ~ /^[[:space:]]+(interval|retries|start_period):/) {
                sub(/#.*/, ""); gsub(/[[:space:]]/, ""); split($0, kv, ":"); v[kv[1]] = kv[2] }
        }
        END { flush() }' "$f")
done
(( rc )) && exit 1
if (( wait <= max )); then
    echo "ERROR START_WAIT=${wait}s does not exceed the longest verdict window (${max}s, $worst) — raise it in mediastack.sh" >&2
    exit 1
fi
echo "OK start wait: START_WAIT=${wait}s > longest verdict window ${max}s ($worst)"
