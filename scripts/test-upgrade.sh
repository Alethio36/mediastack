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

# ---- the hand-over (exec is stubbed below, and maint_lock uses exec: the lock
# counts as held here; the lock's own check runs in a subshell with the real exec)
MAINT_LOCKED=1
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

# ---- the maintenance lock: held by an update/backup/wire elsewhere -> upgrade
# refuses before pulling (a pull once landed mid-update)
(
    unset -f exec
    # shellcheck disable=SC2034  # read by maint_lock
    MAINT_LOCKED=0
    MAINT_LOCK=$T/maint.lock; : > "$LOG"
    ( flock 9; sleep 5 ) 9>"$MAINT_LOCK" & holder=$!
    sleep 0.3
    out=$( (cmd_upgrade) 2>&1 ) && { kill "$holder"; fail_ "upgrade must refuse while the maintenance lock is held"; }
    kill "$holder" 2>/dev/null || true
    [[ "$out" == *"upgrade refused"* ]] || fail_ "the refusal must say what was refused: $out"
    ! grep -q pull "$LOG" || fail_ "upgrade pulled while the lock was held"
); pass
grep -q 'MS_UPGRADE_FROM="$before" MAINT_LOCKED=1 exec' lib/lifecycle.sh \
    || fail_ "the hand-over must tell the pulled script it already holds the lock"; pass

# ---- the verdicts (re-source for the real upgrade_finish)
# shellcheck disable=SC1090
source "$lib"
load_env() { :; }; provision() { :; }; vpn_gen() { :; }
CHANGED=""; PENDING=""
git() { [[ "$1" == diff ]] && printf '%s\n' "$CHANGED"; }
compose_pending() { [[ -z "$PENDING" ]] || printf '%s\n' $PENDING; }
CHANGED="services/apprise/compose.yml"; PENDING=""
[[ "$(upgrade_finish x)" == *"nothing to apply"* ]] || fail_ "a comment-only fragment change must not ask for up"; pass
CHANGED="services/radarr/compose.yml"; PENDING="radarr"
[[ "$(upgrade_finish x)" == *"Apply with ./mediastack.sh up — it changes: radarr"* ]] || fail_ "a real change must name what up changes"; pass
CHANGED="services/kavita/kavita.sh"; PENDING=""
[[ "$(upgrade_finish x)" == *"New tooling is live"* ]] || fail_ "a service's code is tooling"; pass
CHANGED="docs/x.md"; PENDING=""
[[ "$(upgrade_finish x)" == *"Docs/templates only"* ]] || fail_ "docs-only"; pass
# the portal's setup files reach authentik only at up, its flows at wire (found building password reset by email)
svc_enabled() { [[ "$1" == authentik ]]; }
CHANGED=$'services/authentik/templates/mediastack-password-reset.html\nlib/x.sh'; PENDING=""
[[ "$(upgrade_finish x)" == *"The portal's setup changed — apply: ./mediastack.sh up && ./mediastack.sh wire authentik"* ]] \
    || fail_ "a portal setup change asks for up and wire authentik, not 'nothing to apply'"; pass
CHANGED="services/authentik/blueprints/mediastack-portal.yaml"; PENDING="radarr"
[[ "$(upgrade_finish x 2>&1)" == *"it changes: radarr"*"after up, ./mediastack.sh wire authentik"* ]] || fail_ "with pending changes too: both said"; pass
svc_enabled() { return 1; }
[[ "$(upgrade_finish x)" != *"wire authentik"* ]] || fail_ "no portal: nothing said about it"; pass

echo "OK upgrade: $checks checks"
