#!/usr/bin/env bash
# test-upgrade.sh — what `upgrade` tells you, and who tells it. It used to say
# "Compose definitions changed — apply them" for any file under compose.d/
# (a comment edit included), and ran migrations in the process that did the
# pull — the OLD code, which cannot know the new ones. Pins: compose_pending
# is Compose's own dry run of up (changed, new, removed, stopped; Running /
# Waiting / Healthy are no change; a failed dry run fails loud), the
# hand-over (a real pull re-runs the pulled script with the old commit; up to
# date does not; the second half never pulls), and the three verdicts.
#
#   scripts/test-upgrade.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-upgrade.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }
eq()    { [[ "$2" == "$3" ]] || fail_ "$1: got '$2' want '$3'"; }

# ---- compose_pending: stub compose's dry run with the output format seen live
DRY=""; DC_FAILS=0
DC()   { [[ "$*" == "--dry-run up -d --remove-orphans" ]] || fail_ "unexpected DC call: $*"; printf '%s' "$DRY"; (( ! DC_FAILS )); }
pending() { compose_pending | paste -sd'|'; }
unchanged=$' Container mediastack-radarr Running\n Container mediastack-gluetun Running\n Container mediastack-gluetun Waiting\n Container mediastack-gluetun Healthy\n'

DRY=$unchanged
eq "nothing changed (Running / Waiting / Healthy)" "$(pending)" ""; pass
DRY=$unchanged$' Container mediastack-sonarr Recreate\n Container mediastack-sonarr Recreated\n Container mediastack-sonarr Starting\n Container mediastack-sonarr Started\n'
eq "a changed definition (its restart is not a second verdict)" "$(pending)" "sonarr"; pass
DRY=$unchanged$' Container mediastack-kavita Creating\n Container mediastack-kavita Created\n Container mediastack-kavita Starting\n'
eq "a new service (Creating/Created)" "$(pending)" "kavita (new)"; pass
DRY=$unchanged$' Container mediastack-kavita Creating\n'
eq "Creating alone still counts (stems, not whole words)" "$(pending)" "kavita (new)"; pass
DRY=$unchanged$' Container mediastack-deluge Stopping\n Container mediastack-deluge Removing\n Container mediastack-deluge Removed\n'
eq "a removed service" "$(pending)" "deluge (removed)"; pass
DRY=$unchanged$' Container mediastack-bazarr Starting\n Container mediastack-bazarr Started\n'
eq "a stopped service" "$(pending)" "bazarr (stopped)"; pass
DRY=$' Container mediastack-radarr Recreate\n Container mediastack-apprise Created\n'
eq "several, sorted" "$(pending)" "apprise (new)|radarr"; pass
# seen live: Compose pads some lines — trailing spaces, a CR, a prefix
DRY=$' Container mediastack-radarr Recreate   \n Container mediastack-sonarr Recreated\r\nDRY-RUN MODE -  Container mediastack-lidarr  Recreate\n Container mediastack-traefik Running  \n'
eq "padded lines still read (and a padded Running is still no change)" "$(pending)" "lidarr|radarr|sonarr"; pass
DRY="error: something broke"; DC_FAILS=1
set +e; (compose_pending >/dev/null 2>&1); rc=$?; set -e
(( rc != 0 )) || fail_ "a failed dry run must fail loud, never read as 'nothing to apply'"; pass
DC_FAILS=0

# ---- the hand-over
unset -f DC
REV=(); LOG=$T/log
# rev-parse runs inside $(...) — a subshell — so its position lives in a file
git() {
    case "$1" in
        status)    return 0 ;;
        rev-parse) local p; p=$(cat "$T/pos"); echo "${REV[$p]}"; echo $((p+1)) > "$T/pos" ;;
        pull)      echo pull >> "$LOG" ;;
        log|diff)  return 0 ;;
    esac
}
exec() { echo "exec MS_UPGRADE_FROM=${MS_UPGRADE_FROM:-} $*" >> "$LOG"; }
: > "$LOG"; REV=(aaa111 bbb222); echo 0 > "$T/pos"
cmd_upgrade >/dev/null
grep -q "^exec MS_UPGRADE_FROM=aaa111 $SCRIPT_DIR/mediastack.sh upgrade$" "$LOG" \
    || fail_ "a real pull must hand over to the pulled script with the old commit: $(cat "$LOG")"; pass
: > "$LOG"; REV=(aaa111 aaa111); echo 0 > "$T/pos"
cmd_upgrade >/dev/null
! grep -q '^exec' "$LOG" || fail_ "already up to date must not hand over"; pass
: > "$LOG"
upgrade_finish() { echo "finish $1" >> "$LOG"; }
MS_UPGRADE_FROM=aaa111 cmd_upgrade
eq "the second half finishes, never pulls" "$(paste -sd'|' "$LOG")" "finish aaa111"; pass

# ---- the verdicts (re-source for the real upgrade_finish)
# shellcheck disable=SC1090
source "$lib"
load_env() { :; }; provision() { :; }; vpn_gen() { :; }
CHANGED=""; PENDING=""
git() { [[ "$1" == diff ]] && printf '%s\n' "$CHANGED"; }
compose_pending() { [[ -z "$PENDING" ]] || printf '%s\n' $PENDING; }
CHANGED="compose.d/apprise.yml"; PENDING=""
[[ "$(upgrade_finish x)" == *"nothing to apply"* ]] || fail_ "a comment-only fragment change must not ask for up"; pass
CHANGED="compose.d/radarr.yml"; PENDING="radarr"
[[ "$(upgrade_finish x)" == *"Apply with ./mediastack.sh up — it changes: radarr"* ]] || fail_ "a real change must name what up changes"; pass
CHANGED="docs/x.md"; PENDING=""
[[ "$(upgrade_finish x)" == *"Docs/templates only"* ]] || fail_ "docs-only"; pass

echo "OK upgrade: $checks checks"
