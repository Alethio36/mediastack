#!/usr/bin/env bash
# test-upgrade.sh — what `upgrade` tells you, and who tells it. It used to say
# "Compose definitions changed — apply them" for any file under compose.d/
# (a comment edit included), and ran migrations in the process that did the
# pull — the OLD code, which cannot know the new ones. Pins: compose_pending
# is Docker's own verdict (config-hash vs each container's label: changed,
# new, removed; nothing -> nothing; a failed render fails loud), the
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

# ---- compose_pending: stub compose's config hashes and docker's labels
WANT=""; HAVE=""; DC_FAILS=0
DC()   { [[ "$*" == "config --hash *" ]] || fail_ "unexpected DC call: $*"; (( ! DC_FAILS )) || return 1; printf '%s' "$WANT"; }
sudo() { "$@"; }
docker() { printf '%s' "$HAVE"; }
pending() { compose_pending | paste -sd'|'; }

WANT=$'radarr aaa\nsonarr bbb\n'; HAVE=$'radarr aaa\nsonarr bbb\n'
eq "nothing changed" "$(pending)" ""; pass
WANT=$'radarr aaa\nsonarr NEW\n'
eq "a changed definition" "$(pending)" "sonarr"; pass
WANT=$'radarr aaa\nsonarr bbb\nkavita ccc\n'
eq "an enabled service with no container" "$(pending)" "kavita (new)"; pass
WANT=$'radarr aaa\n'
eq "a container whose service is gone" "$(pending)" "sonarr (removed)"; pass
DC_FAILS=1
set +e; (compose_pending >/dev/null 2>&1); rc=$?; set -e
(( rc != 0 )) || fail_ "a failed render must fail loud, never read as 'nothing to apply'"; pass
DC_FAILS=0

# ---- the hand-over
unset -f DC docker
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
