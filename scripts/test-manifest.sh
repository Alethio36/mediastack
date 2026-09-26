#!/usr/bin/env bash
# test-manifest.sh — the media manifest's loss-vs-churn contract, end to end,
# against a throwaway library in a temp dir. No docker, no root, no network:
# sudo, require_mounts and notify are replaced with local stand-ins, so the
# real scan/compare/guard/find code runs unmodified.
#
#   scripts/test-manifest.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# a copy of the entrypoint without its last line (main "$@") so it can be
# sourced for its definitions; it lives beside the real one because the
# script locates lib/ relative to itself
lib=$(mktemp .test-manifest.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"

sudo() { "$@"; }                        # everything here is ours already
require_mounts() { :; }
notify() { printf '%s|%s|%s\n' "$1" "$4" "$2" >> "$T/notes"; printf '%s\n' "$3" >> "$T/bodies"; }
ENV_FILE=$T/.env
printf 'DATA_ROOT=%s/data\nBACKUP_ROOT=%s/bk\nMANIFEST_ALERT_PCT=5\nMANIFEST_SCHEDULE=*-*-* 03:30\n' "$T" "$T" > "$ENV_FILE"
load_env() { :; }                       # no schema migration against the stub .env
M=$T/data/media

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }
mk()    { mkdir -p "$(dirname "$M/$1")"; head -c "$2" /dev/zero > "$M/$1"; }
# snap [--accept] — one manifest run with errexit live; sets RC, OUT, NOTES
snap() {
    sleep 1.1   # snapshot names have one-second resolution
    : > "$T/notes"
    # errexit must be live INSIDE the run: a function returning non-zero
    # mid-way is exactly the bug class this catches (set +e would mask it)
    set +e; OUT=$( ( set -e; manifest_take "$@" ) 2>&1 ); RC=$?; set -e
    NOTES=$(cat "$T/notes")
}
count() { manifest_list | wc -l; }

# ---- library: sizes are unique per file so inode+size identity is exercised
for i in $(seq 1 20); do mk "movies/Movie $i (2000)/Movie $i (2000) Bluray-1080p.mkv" $((1000+i)); mk "movies/Movie $i (2000)/poster.jpg" 10; done
for e in $(seq -w 1 10); do mk "tv/Show (2010)/Season 01/Show S01E$e WEBDL-1080p.mkv" $((500+10#$e)); done
mk $'tv/Weird\tShow/Season 01/ep\\one\nline.mkv' 777

snap
[[ $RC == 0 && $(count) == 1 && -z "$NOTES" ]] || fail_ "baseline: rc=$RC count=$(count) notes=$NOTES"; pass

a=$T/a.gz; b=$T/b.gz; manifest_scan "$a"; manifest_scan "$b"
cmp -s "$a" "$b" || fail_ "identical trees must give byte-identical snapshots"; pass

# ---- arr churn: file rename, folder renames, upgrade, sidecar delete -> quiet
mv "$M/movies/Movie 1 (2000)/Movie 1 (2000) Bluray-1080p.mkv" "$M/movies/Movie 1 (2000)/Movie 1 (2000) {tmdb-1}.mkv"
for i in $(seq 2 12); do mv "$M/movies/Movie $i (2000)" "$M/movies/Movie $i (2000) {tmdb-$i}"; done
rm "$M/movies/Movie 13 (2000)/Movie 13 (2000) Bluray-1080p.mkv"; mk "movies/Movie 13 (2000)/Movie 13 (2000) Remux-2160p.mkv" 5555
rm "$M/movies/Movie 14 (2000)/poster.jpg"
snap
[[ $RC == 0 && -z "$NOTES" ]] || fail_ "churn must not alert: rc=$RC notes=$NOTES"; pass
grep -q 'renamed/moved 12' <<<"$OUT" || fail_ "churn: expected 12 moves: $OUT"; pass

# ---- real losses: one movie, two episodes -> one warning naming both titles
rm -r "$M/movies/Movie 20 (2000)"; rm "$M/tv/Show (2010)/Season 01/"*E0[12]*
snap
[[ $RC == 0 ]] || fail_ "loss run failed: $OUT"; pass
[[ $(grep -c '^ops|warning|' <<<"$NOTES") == 1 ]] || fail_ "loss: expected one ops warning: $NOTES"; pass
grep -q -- '-1  movies/Movie 20 (2000)' <<<"$OUT" && grep -q -- '-2  tv/Show (2010)/Season 01' <<<"$OUT" \
    || fail_ "loss report: $OUT"; pass

# ---- a tab in a folder name keeps the report's columns intact
rm "$M/tv/Weird"$'\t'"Show/Season 01/"*
snap
grep -qF -- '-1  tv/Weird\tShow/Season 01' <<<"$OUT" || fail_ "tab-named folder: $OUT"; pass

# ---- who removed it: the deletion log (lib/audit.sh) names who, per folder
# and per title in the alert; a folder the log never saw says so
mkdir -p "$T/bk/audit"
printf '%s\tradarr\tdelete\t%s\t\n' "$(date +%s)" "$(realpath "$M")/movies/Movie 19 (2000)/Movie 19 (2000) Bluray-1080p.mkv" \
    > "$T/bk/audit/$(date +%F).tsv"
rm -r "$M/movies/Movie 19 (2000)" "$M/movies/Movie 18 (2000)"; : > "$T/bodies"
snap
grep -A2 -- '-1  movies/Movie 19 (2000)' <<<"$OUT" | grep -q 'removed by: radarr ×1' || fail_ "report must name who removed Movie 19: $OUT"; pass
grep -A2 -- '-1  movies/Movie 18 (2000)' <<<"$OUT" | grep -q 'no deletion recorded here' || fail_ "report must say nothing was recorded for Movie 18: $OUT"; pass
grep -q '• movies/Movie 19 (2000) — removed by: radarr ×1' "$T/bodies" || fail_ "alert must name who: $(cat "$T/bodies")"; pass
rm -r "$T/bk/audit"

# ---- unmounted share: empty media root -> refused, nothing recorded
n=$(count); mv "$M" "$T/offline"; mkdir -p "$M"
snap
[[ $RC != 0 && $(count) == "$n" ]] || fail_ "empty root must be refused: rc=$RC count $n->$(count)"; pass
grep -q '^ops|failure|' <<<"$NOTES" || fail_ "empty root: expected ops failure: $NOTES"; pass
rm -r "$M"; mv "$T/offline" "$M"

# ---- find: gone vs present
f=$(manifest_find "movie 20"); grep -q 'GONE' <<<"$f" || fail_ "find gone: $f"; pass
f=$(manifest_find "S01E03");   grep -q 'present' <<<"$f" || fail_ "find present: $f"; pass

# ---- guard floor on a larger library: 24 gone passes, 30 more (8%) refuses, --accept records
rm -rf "$M"; for i in $(seq 1 400); do mk "movies/M$i/M$i.mkv" $((2000+i)); done; snap
for i in $(seq 1 24); do rm -r "$M/movies/M$i"; done; snap
[[ $RC == 0 ]] || fail_ "24 of 400 is under the floor and must record: $OUT"; pass
for i in $(seq 25 54); do rm -r "$M/movies/M$i"; done; n=$(count); snap
[[ $RC != 0 && $(count) == "$n" ]] || fail_ "30 of 376 must be refused: rc=$RC"; pass
snap --accept
[[ $RC == 0 && $(count) == $((n+1)) ]] || fail_ "--accept must record: rc=$RC"; pass

# ---- timestamps: an unreadable name fails loud, never reads as "fresh"
ts_age_hours 20261399-020000 >/dev/null && fail_ "impossible date must not parse"; pass
[[ $(ts_age_hours "$(date -d '-5 hours' +%Y%m%d-%H%M%S)") == 5 ]] || fail_ "ts_age_hours arithmetic"; pass
touch "$T/bk/manifest/29991399-000000.tsv.gz"
D_FAILS=0; out=$(_doctor_manifest 2>&1; echo "end D_FAILS=$D_FAILS")
grep -q 'is not a real date' <<<"$out" && grep -q 'end D_FAILS=1' <<<"$out" \
    || fail_ "doctor must d_fail an unreadable manifest name and finish: $out"; pass

echo "OK manifest: $checks checks"
