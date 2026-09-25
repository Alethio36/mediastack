#!/usr/bin/env bash
# check-start-wait.sh — doctor's startup wait (DOCTOR_START_WAIT) must exceed
# every fragment's Docker verdict window, start_period + interval x retries;
# otherwise doctor FAILs a service Docker hasn't judged yet. Durations are
# plain seconds ("60s") — anything else fails loud here rather than being
# silently skipped.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

wait=$(sed -nE 's/^DOCTOR_START_WAIT=([0-9]+).*/\1/p' lib/doctor.sh)
[[ -n "$wait" ]] || { echo "ERROR DOCTOR_START_WAIT not found in lib/doctor.sh" >&2; exit 1; }

max=0 worst="" rc=0
for f in compose.d/*.yml; do
    # one healthcheck per fragment: pull its three fields (comments stripped)
    read -r iv rt sp < <(awk '
        /^[[:space:]]+healthcheck:/ { hc = 1; next }
        hc && /^[[:space:]]+(interval|retries|start_period):/ {
            sub(/#.*/, ""); gsub(/[[:space:]]/, ""); split($0, kv, ":"); v[kv[1]] = kv[2] }
        END { printf "%s %s %s\n", (v["interval"] ? v["interval"] : "-"), (v["retries"] ? v["retries"] : "-"), (v["start_period"] ? v["start_period"] : "-") }' "$f")
    [[ "$iv$rt$sp" == "---" ]] && continue          # no healthcheck
    for d in "$iv" "$sp"; do
        [[ "$d" == - || "$d" =~ ^[0-9]+s$ ]] || { echo "ERROR $f: duration '$d' is not plain seconds (Ns)" >&2; rc=1; }
    done
    (( rc )) && continue
    # docker defaults: interval 30s, retries 3, start_period 0s
    iv=${iv/-/30s}; rt=${rt/-/3}; sp=${sp/-/0s}
    win=$(( ${sp%s} + ${iv%s} * rt ))
    (( win > max )) && { max=$win; worst=$(basename "$f" .yml); }
done
(( rc )) && exit 1
if (( wait <= max )); then
    echo "ERROR DOCTOR_START_WAIT=${wait}s does not exceed $worst's verdict window (${max}s) — raise it in lib/doctor.sh" >&2
    exit 1
fi
echo "OK start wait: DOCTOR_START_WAIT=${wait}s > longest verdict window ${max}s ($worst)"
