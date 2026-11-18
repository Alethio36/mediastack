#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-people.sh — the apps' accounts following the portal (lib/people.sh):
#   * the record: who the stack turned off, per app, any case, 600
#   * the rule (decision 10): account on, and admin, or the app's tier
#     frontend and in frontend, or granted (app-<svc>)
#   * followed only once its wire reached the portal step, just before its
#     sync (never a dry run);
#     the timer started with it, every 15 minutes, in the footprint
#   * people-sync: nothing without the portal or while maintenance holds the
#     stack; only followed apps that are enabled and running, in
#     PEOPLE_APPS order; waits for authentik and each app first (the boot,
#     found live 17 Nov 2026) — authentik not up: stops, nobody judged; an
#     app not up: a failure, the others still followed; any failure fails
#     the run (ops hears it)
#   * an access command on a followed app: its accounts follow at once; a
#     failure says people-sync tries again
#   * each app's part signs in as the stack's own first: refused, a failure
#   * the 47 -> 48 step keeps Navidrome followed where it was
#
#   scripts/test-people.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-people.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

ENV_FILE=$T/.env; LOCAL_DIR=$T/local; STATE_DIR=$T/local/state
: > "$ENV_FILE"
repo_owned() { :; }; ok() { echo "OK $*"; }; info() { echo ":: $*"; }; warn() { echo "WARN $*"; }; fail() { echo "FAIL $*"; }
fresh() { rm -rf "$T/local" "$T/ran"; mkdir -p "$T/local"; WIRE_FAILS=0; WIRE_DRY=0; }

# ---- the record ----
fresh
people_set navidrome Alice on; people_set navidrome bob off; people_set kavita bob off
[[ "$(people_get navidrome alice) $(people_get navidrome BOB) $(people_get kavita bob) $(people_get jellyfin bob)" == "on off off " ]] \
    || fail_ "per app, any case: $(cat "$T/local/navidrome-people")"; pass
people_set navidrome BOB ""; [[ -z "$(people_get navidrome bob)" && "$(people_get navidrome alice)" == on ]] || fail_ "forgotten, the rest kept"; pass
[[ "$(stat -c %a "$(people_file navidrome)")" == 600 && "$(people_file navidrome)" == "$T/local/navidrome-people" ]] || fail_ "600, at local/<app>-people (Navidrome's file as before)"; pass

# ---- the rule ----
TIER="frontend"; svc_tier() { echo "$TIER"; }
person() { jq -cn --argjson a "$1" --argjson g "${2:-[]}" '{username:"p", is_active:$a, groups_obj:($g | map({name:.}))}'; }
may() { if people_may "$(person "$@")" navidrome; then echo yes; else echo no; fi; }
[[ "$(may true '["admin"]')" == yes ]] || fail_ "an admin: yes"; pass
[[ "$(may true '["frontend"]')" == yes ]] || fail_ "the household, tier frontend: yes"; pass
TIER="admin"
[[ "$(may true '["frontend"]')" == no ]] || fail_ "the household, tier admin: no"; pass
[[ "$(may true '["frontend","app-navidrome"]')" == yes ]] || fail_ "granted (app-navidrome), tier admin: yes"; pass
[[ "$(may true '["app-kavita"]')" == no ]] || fail_ "another app's grant: no"; pass
[[ "$(may false '["admin"]')" == no ]] || fail_ "account off: no, even an admin"; pass
TIER="frontend"; [[ "$(may true)" == no ]] || fail_ "in no group: no"; pass

# ---- followed, and the timer ----
people_timer_ensure() { echo timer >> "$T/ran"; }
fresh; WIRE_DRY=1 people_follow_on kavita; [[ ! -e "$T/ran" ]] && ! people_followed kavita || fail_ "a dry run follows nothing"; pass
fresh; people_follow_on kavita; people_follow_on navidrome; people_follow_on kavita
[[ "$(state_get "$PEOPLE_FOLLOWED")" == "kavita navidrome" && "$(grep -c timer "$T/ran")" == 3 ]] || fail_ "recorded once each, the timer ensured each time: $(state_get "$PEOPLE_FOLLOWED")"; pass
people_followed navidrome && ! people_followed jellyfin || fail_ "followed: exactly those"; pass
unset -f people_timer_ensure; source lib/people.sh
grep -qF 'timer_timer_render "Mediastack: people follow the portal" "*:0/15"' lib/people.sh \
    && grep -qF 'timer_service_render "Mediastack: people follow the portal" people-sync' lib/people.sh || fail_ "every 15 minutes, people-sync"; pass
[[ "$(fp_timers)" == *mediastack-people.timer* && "$(fp_timers)" == *mediastack-people.service* ]] || fail_ "the timer is in the footprint (uninstall removes it)"; pass
! grep -q people_follow_on <(awk '/^cmd_up\(\)/,/^}/' mediastack.sh) || fail_ "up never follows an app: its run could beat the wire that makes the stack's admin"; pass
verb_entry people-sync >/dev/null || fail_ "people-sync is a verb"; pass

# ---- people-sync ----
ENABLED="jellyfin kavita audiobookshelf navidrome" RUNNING="authentik jellyfin kavita audiobookshelf navidrome" BAD="" HELD="" FOLLOW_FAIL=""
sync_run() { # sync_run — cmd_people_sync against stubs; -> rc in $T/rc, what ran in $T/ran
    rm -f "$T/ran"
    ( load_env() { :; }; render() { :; }
      signin_is() { [[ "${SIGNIN_X:-authentik}" == "$1" ]]; }
      maint_try_lock() { [[ -z "$HELD" ]]; }
      svc_enabled() { [[ " $ENABLED " == *" $1 "* ]]; }
      svc_cname() { echo "$1"; }
      c_state() { if [[ " $RUNNING " == *" $1 "* ]]; then echo running; else echo exited; fi; }
      wait_verdict() { echo "wait $*" >> "$T/ran"; VERDICT_BAD="$BAD"; VERDICT_WHY=(); local b; for b in $BAD; do VERDICT_WHY[$b]="is unhealthy"; done; [[ -z "$BAD" ]]; }
      for a in jellyfin kavita audiobookshelf navidrome; do
          eval "${a}_people_follow() { echo follow-$a >> \"\$T/ran\"; [[ \" \$FOLLOW_FAIL \" == *\" $a \"* ]] && { wfail \"$a broke\"; return 1; }; return 0; }"
      done
      cmd_people_sync ) > "$T/out" 2>&1 && echo 0 > "$T/rc" || echo $? > "$T/rc"
}
ran() { [[ -e "$T/ran" ]] && tr '\n' '|' < "$T/ran"; return 0; }
fresh; state_set "$PEOPLE_FOLLOWED" "navidrome kavita jellyfin audiobookshelf"
sync_run
[[ "$(cat "$T/rc")" == 0 && "$(ran)" == "wait authentik jellyfin kavita audiobookshelf navidrome|follow-jellyfin|follow-kavita|follow-audiobookshelf|follow-navidrome|" ]] \
    || fail_ "every followed app, after authentik and they are up, in PEOPLE_APPS order: $(ran) $(cat "$T/out")"; pass
SIGNIN_X=wizarr sync_run; [[ "$(cat "$T/rc")" == 0 && -z "$(ran)" ]] || fail_ "without the portal: nothing called"; pass
HELD=1 sync_run; [[ "$(cat "$T/rc")" == 0 && -z "$(ran)" ]] && grep -q "has the stack — checked again in 15 minutes" "$T/out" || fail_ "maintenance holds the stack: skipped, said: $(cat "$T/out")"; pass
fresh; sync_run; [[ "$(cat "$T/rc")" == 0 && -z "$(ran)" ]] && grep -q "no app follows the portal yet" "$T/out" || fail_ "nothing followed yet (no wire reached it): nothing called"; pass
fresh; state_set "$PEOPLE_FOLLOWED" "kavita navidrome jellyfin"
ENABLED="kavita navidrome jellyfin" RUNNING="authentik kavita jellyfin" sync_run
[[ "$(cat "$T/rc")" == 0 && "$(ran)" == "wait authentik jellyfin kavita|follow-jellyfin|follow-kavita|" ]] && grep -q "navidrome is not running — its people not checked" "$T/out" \
    || fail_ "only the running ones; a stopped one said: $(ran) $(cat "$T/out")"; pass
ENABLED="kavita jellyfin" sync_run; [[ "$(ran)" == "wait authentik jellyfin kavita|follow-jellyfin|follow-kavita|" ]] || fail_ "a disabled one: not followed: $(ran)"; pass
BAD="authentik" sync_run
[[ "$(cat "$T/rc")" != 0 && "$(ran)" == "wait authentik jellyfin kavita navidrome|" ]] && grep -q "authentik is unhealthy — nobody's access was checked" "$T/out" \
    || fail_ "authentik not up: stops, nobody judged, a failure (ops): $(ran) $(cat "$T/out")"; pass
BAD="kavita" sync_run
[[ "$(cat "$T/rc")" != 0 && "$(ran)" == "wait authentik jellyfin kavita navidrome|follow-jellyfin|follow-navidrome|" ]] && grep -q "people-sync: kavita is unhealthy — its people not checked" "$T/out" \
    && grep -q "people-sync: 1 change(s) failed" "$T/out" || fail_ "one app not up: a failure, the others still followed: $(ran) $(cat "$T/out")"; pass
FOLLOW_FAIL="jellyfin" sync_run
[[ "$(cat "$T/rc")" != 0 && "$(ran)" == "wait authentik jellyfin kavita navidrome|follow-jellyfin|follow-kavita|follow-navidrome|" ]] && grep -q "people-sync: 1 change(s) failed" "$T/out" \
    || fail_ "a follow that fails: the next still runs, then the run fails: $(ran) $(cat "$T/out")"; pass
! grep -q "on_err\|unhandled" "$T/out" || fail_ "a follow returning 1 is handled, never the ERR trap: $(cat "$T/out")"; pass

# ---- at once, after an access command ----
now_run() { # now_run SVC -> rc in $T/rc
    rm -f "$T/ran"
    ( svc_enabled() { [[ " $ENABLED " == *" $1 "* ]]; }; svc_cname() { echo "$1"; }
      c_state() { if [[ " $RUNNING " == *" $1 "* ]]; then echo running; else echo exited; fi; }
      navidrome_people_follow() { echo follow-navidrome >> "$T/ran"; [[ -z "$FOLLOW_FAIL" ]] || { wfail "navidrome broke"; return 1; }; }
      people_follow_now "$1" ) > "$T/out" 2>&1 && echo 0 > "$T/rc" || echo $? > "$T/rc"
}
fresh; state_set "$PEOPLE_FOLLOWED" navidrome; ENABLED=navidrome RUNNING=navidrome FOLLOW_FAIL=""
now_run navidrome; [[ "$(cat "$T/rc")" == 0 && "$(ran)" == "follow-navidrome|" ]] || fail_ "a followed app: its accounts follow now"; pass
now_run sonarr; [[ "$(cat "$T/rc")" == 0 && -z "$(ran)" ]] || fail_ "an app with no accounts of its own: nothing"; pass
fresh; now_run navidrome; [[ "$(cat "$T/rc")" == 0 && -z "$(ran)" ]] || fail_ "not followed yet: nothing"; pass
fresh; state_set "$PEOPLE_FOLLOWED" navidrome; RUNNING="" now_run navidrome
[[ "$(cat "$T/rc")" == 0 && -z "$(ran)" ]] && grep -q "not running — its accounts follow once it is" "$T/out" || fail_ "not running: said, nothing called"; pass
FOLLOW_FAIL=1 now_run navidrome
[[ "$(cat "$T/rc")" != 0 ]] && grep -q "access: the portal changed, but navidrome's accounts did not follow (1 failure(s) above) — people-sync tries again" "$T/out" \
    || fail_ "it failed: the command fails, saying the timer tries again: $(cat "$T/out")"; pass
for f in access_tier access_grant access_revoke; do
    awk "/^$f\\(\\)/,/^}/" lib/access.sh | grep 'people_follow_now "$s"' >/dev/null || fail_ "$f: the app's accounts follow at once"; pass
done

# ---- each wire follows its app once it reaches the portal step, just before its sync ----
for w in "services/jellyfin/jellyfin.sh people_follow_on jellyfin jf_admin_sync" "services/kavita/kavita.sh people_follow_on kavita kav_admin_sync" \
         "services/audiobookshelf/audiobookshelf.sh people_follow_on audiobookshelf abs_admin_sync" "services/navidrome/navidrome.sh people_follow_on navidrome navidrome_people_sync"; do
    read -r f on app sy <<<"$w"
    [[ "$(grep -A1 "^    $on $app\$" "$f" | sed -n 2p)" == "    $sy \"\$"* ]] || fail_ "$f: $on $app, then $sy"; pass
done

# ---- each app's part: the stack's own signs in first ----
part() { # part APP -> its output; the login refused
    ( WIRE_FAILS=0
      kav_api() { echo '{"title":"Unauthorized"}'; return 1; }; abs_api() { echo 'Unauthorized'; return 1; }; nd_login() { echo 'Invalid username or password'; return 1; }
      kav_admin_sync() { echo synced; }; abs_admin_sync() { echo synced; }; navidrome_people_sync() { echo synced; }; jf_admin_sync() { echo synced; }
      "${1}_people_follow"; echo "fails=$WIRE_FAILS" ) 2>&1
}
[[ "$(part jellyfin)" == *"no API key in .env (JELLYFIN_API_KEY)"*"fails=1" ]] || fail_ "jellyfin with no key: a failure"; pass
printf 'JELLYFIN_API_KEY=k\n' > "$ENV_FILE"; [[ "$(part jellyfin)" == *synced*"fails=0" ]] || fail_ "jellyfin: its key, then the sync"; pass
[[ "$(part kavita)" == *"kavita rejected the stored admin login"*"fails=1" && "$(part kavita)" != *synced* ]] || fail_ "kavita refused: a failure, nothing synced"; pass
[[ "$(part audiobookshelf)" == *"audiobookshelf rejected the root login"*"fails=1" && "$(part audiobookshelf)" != *synced* ]] || fail_ "audiobookshelf refused: a failure, nothing synced"; pass
[[ "$(part navidrome)" == *"the stack's admin does not sign in"*"fails=1" && "$(part navidrome)" != *synced* ]] || fail_ "navidrome refused: a failure, nothing synced"; pass

# ---- 47 -> 48: Navidrome followed where it was ----
fresh; printf 'COMPOSE_PROFILES=authentik,navidrome\n' > "$ENV_FILE"; people_set navidrome bob on
migrate_env_47_to_48 >/dev/null; people_followed navidrome || fail_ "its record there: Navidrome stays followed"; pass
migrate_env_47_to_48 >/dev/null; [[ "$(state_get "$PEOPLE_FOLLOWED")" == navidrome ]] || fail_ "run twice: recorded once"; pass
fresh; migrate_env_47_to_48 >/dev/null; ! people_followed navidrome || fail_ "no record: not followed until its wire"; pass
fresh; printf 'COMPOSE_PROFILES=wizarr,navidrome\n' > "$ENV_FILE"; people_set navidrome bob on
[[ -z "$(migrate_env_47_to_48)" ]] && ! people_followed navidrome || fail_ "without the portal: nothing, nothing said"; pass
echo "OK people: $checks checks"
