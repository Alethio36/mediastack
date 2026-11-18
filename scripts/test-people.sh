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
#   * Jellyfin, Kavita and Audiobookshelf: who may sign in follows the rule —
#     off on loss (disabled and signed out / Login taken / inactive), on again
#     only when the stack
#     turned it off; a deleted person's account renamed, never looked at again
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
now_run navidrome; [[ "$(cat "$T/rc")" == 0 && "$(ran)" == "follow-navidrome|" ]] && grep -q "navidrome's own accounts follow the portal — any change to them is above" "$T/out" \
    || fail_ "a followed app: its accounts follow now, said even when nothing changed (people-sync may have got there first): $(cat "$T/out")"; pass
now_run sonarr; [[ "$(cat "$T/rc")" == 0 && -z "$(ran)" ]] || fail_ "an app with no accounts of its own: nothing"; pass
fresh; now_run navidrome; [[ "$(cat "$T/rc")" == 0 && -z "$(ran)" ]] || fail_ "not followed yet: nothing"; pass
fresh; state_set "$PEOPLE_FOLLOWED" navidrome; RUNNING="" now_run navidrome
[[ "$(cat "$T/rc")" == 0 && -z "$(ran)" ]] && grep -q "not running — its accounts follow once it is" "$T/out" || fail_ "not running: said, nothing called"; pass
FOLLOW_FAIL=1 now_run navidrome
[[ "$(cat "$T/rc")" != 0 ]] && grep -q "access: the portal changed, but navidrome's accounts did not follow (1 failure(s) above) — people-sync tries again" "$T/out" \
    || fail_ "it failed: the command fails, saying the timer tries again: $(cat "$T/out")"; pass
for f in access_tier access_grant access_revoke access_admin; do
    awk "/^$f\\(\\)/,/^}/" lib/access.sh | grep 'people_follow_now "$s"' >/dev/null || fail_ "$f: the app's accounts follow at once"; pass
done

# ---- each wire follows its app once it reaches the portal step, just before its sync ----
for w in "services/jellyfin/jellyfin.sh people_follow_on jellyfin jf_admin_sync" "services/kavita/kavita.sh people_follow_on kavita kav_admin_sync" \
         "services/audiobookshelf/audiobookshelf.sh people_follow_on audiobookshelf abs_admin_sync" "services/navidrome/navidrome.sh people_follow_on navidrome navidrome_people_sync"; do
    read -r f on app sy <<<"$w"
    [[ "$(grep -A1 "^    $on $app\$" "$f" | sed -n 2p)" == "    $sy \"\$"* ]] || fail_ "$f: $on $app, then $sy"; pass
done

# ---- Jellyfin: who may sign in (slice B, decision 12) ----
JFL=$JF_LDAP_PROVIDER
jfu() { jq -cn --arg i "$1" --arg n "$2" --argjson d "${3:-false}" --arg p "${4:-$JFL}" '{Id:$i, Name:$n, Policy:{IsDisabled:$d, IsAdministrator:false, AuthenticationProviderId:$p}}'; }
jf_api() { # a fake Jellyfin: users in $T/jf.json, devices in $T/dev.tsv (id owner name)
    echo "$1 $2" >> "$T/jcalls"
    case "$1 $2" in
        "GET /Users") cat "$T/jf.json" ;;
        "GET /Users/"*) jq -c --arg i "${2##*/}" '.[] | select(.Id == $i)' "$T/jf.json" ;;
        "POST /Users/"*/Policy) local i=${2#/Users/}; i=${i%/Policy}; echo "$4" >> "$T/jpol"
            [[ -n "${JF_IGNORE:-}" ]] && return 0
            jq -c --arg i "$i" --argjson p "$4" 'map(if .Id == $i then .Policy = $p else . end)' "$T/jf.json" > "$T/jf.n"; mv "$T/jf.n" "$T/jf.json"
            # Jellyfin 12.4 ends a disabled person's sign-ins itself (proven live, 18 Nov 2026)
            if [[ -n "${JF_REVOKES:-}" && "$(jq -r .IsDisabled <<<"$4")" == true ]]; then awk -v u="$i" '$2 != u' "$T/dev.tsv" > "$T/dev.n"; mv "$T/dev.n" "$T/dev.tsv"; fi ;;
        "POST /Users?userId="*) [[ -n "${JF_NO_RENAME:-}" ]] && { echo 'bad name'; return 1; }; echo "$4" >> "$T/jren"
            jq -c --arg i "${2#*=}" --argjson d "$4" 'map(if .Id == $i then .Name = $d.Name else . end)' "$T/jf.json" > "$T/jf.n"; mv "$T/jf.n" "$T/jf.json" ;;
        "GET /Devices") [[ -n "${DEV_FAIL:-}" ]] && return 1
            jq -Rsc 'split("\n") | map(select(length > 0) | split(" ") | {Id:.[0], LastUserId:.[1], LastUserName:.[2]}) | {Items:.}' "$T/dev.tsv" ;;
        "DELETE /Devices?id="*) [[ -n "${DEV_KEEP:-}" ]] && return 0; awk -v d="${2#*=}" '$1 != d' "$T/dev.tsv" > "$T/dev.n"; mv "$T/dev.n" "$T/dev.tsv" ;;
        *) echo "unexpected $1 $2" >&2; return 1 ;;
    esac
}
jf_code() { echo 200; }
notify() { echo "$1|$3" >> "$T/notified"; }
ak_group_pk() { [[ -n "${NO_GROUPS:-}" ]] || echo "g-$1"; return 0; }
pu() { jq -cn --arg n "$1" --argjson a "$2" --argjson g "${3:-[]}" '{username:$n, is_active:$a, groups_obj:($g | map({name:.}))}'; }
signin_people() { jq -cn --slurpfile p "$T/portal.ndjson" '{results:$p}'; }
jfresh() { rm -f "$T/jcalls" "$T/jpol" "$T/jren" "$T/notified"; WIRE_FAILS=0; WIRE_DRY=0; }
D=$(date +%Y%m%d)
disabled() { jq -r --arg n "$1" '.[] | select(.Name == $n) | .Policy.IsDisabled' "$T/jf.json"; }
fresh; jfresh
printf '%s\n' "$(jfu 1 akadmin)" "$(jfu 2 bob)" "$(jfu 3 carol)" "$(jfu 4 dave)" "$(jfu 5 erin true)" "$(jfu 6 mediastack false Local)" | jq -sc . > "$T/jf.json"
printf 'd1 2 bob\nd2 3 carol\nd3 3 carol\nd4 2 bob\n' > "$T/dev.tsv"
printf '%s\n' "$(pu akadmin true '["admin"]')" "$(pu bob true '["frontend"]')" "$(pu carol false '["frontend"]')" "$(pu erin true '["frontend"]')" > "$T/portal.ndjson"
TIER="frontend"; jf_people_access tok > "$T/out" 2>&1
[[ "$(disabled carol) $(people_get jellyfin carol)" == "true off" ]] && grep -qF "'carol' can no longer sign in (portal account deactivated) — signed out of 2 device(s)" "$T/out" \
    || fail_ "deactivated: disabled, signed out of her own devices, recorded off: $(cat "$T/out")"; pass
[[ "$(disabled "removed-dave-$D") $(people_get jellyfin "removed-dave-$D") $(people_get jellyfin dave)" == "true removed " ]] \
    && grep -qF "'dave' can no longer sign in (portal account deleted) — signed out of 0 device(s)" "$T/out" && grep -qF "'dave' (portal account deleted) kept as 'removed-dave-$D'" "$T/out" \
    || fail_ "deleted: disabled, signed out, renamed removed-<name>-<date> (the name free for someone new), the old name forgotten: $(cat "$T/out")"; pass
grep -qF "dave can no longer sign in to Jellyfin: their portal account was deleted. Their Jellyfin account is kept as removed-dave-$D." "$T/notified" || fail_ "ops hears the new name"; pass
[[ "$(cut -d' ' -f2 "$T/dev.tsv" | sort -u | paste -sd, -)" == 2 ]] || fail_ "only their devices signed out: $(cat "$T/dev.tsv")"; pass
[[ "$(disabled bob) $(disabled akadmin) $(disabled erin)" == "false false true" && -z "$(people_get jellyfin erin)" ]] \
    || fail_ "bob and an admin may: untouched; erin, disabled by hand: left so, never recorded (only the stack's own turned back on)"; pass
! grep -q '/Users/6/' "$T/jcalls" || fail_ "the stack's own local admin is never touched"; pass
[[ "$(grep -c '^ops|' "$T/notified")" == 2 ]] && grep -qF "carol can no longer sign in to Jellyfin: portal account deactivated" "$T/notified" || fail_ "ops hears each, with why"; pass
d=$(grep -n 'POST /Users/3/Policy' "$T/jcalls" | cut -d: -f1); o=$(grep -n 'DELETE /Devices' "$T/jcalls" | sed -n 1p | cut -d: -f1)
(( d < o )) || fail_ "disabled first, then signed out (decision 12)"; pass
jfresh; jf_people_access tok > "$T/out" 2>&1; [[ ! -e "$T/jpol" && ! -e "$T/jren" ]] && ! grep -q "removed-dave" "$T/out" || fail_ "the next run: nothing written again, the renamed account not looked at"; pass
jfresh; TIER="admin"; WIRE_DRY=1 jf_people_access tok > "$T/out" 2>&1
[[ ! -e "$T/jpol" && "$(disabled bob)" == false ]] && grep -qF "would: jellyfin: 'bob' (may no longer open Jellyfin) is disabled and signed out" "$T/out" \
    || fail_ "a dry run says it and writes nothing: $(cat "$T/out")"; pass
jfresh; jf_people_access tok > "$T/out" 2>&1
[[ "$(disabled bob) $(people_get jellyfin bob)" == "true off" && ! -s "$T/dev.tsv" ]] || fail_ "tier admin: bob (frontend only) disabled and signed out"; pass
printf '%s\n' "$(pu akadmin true '["admin"]')" "$(pu bob true '["frontend","app-jellyfin"]')" "$(pu carol false '["frontend"]')" "$(pu erin true '["frontend","app-jellyfin"]')" > "$T/portal.ndjson"
jfresh; jf_people_access tok > "$T/out" 2>&1
[[ "$(disabled bob) $(people_get jellyfin bob)" == "false " ]] && grep -qF "'bob' may sign in again — their portal password, as before" "$T/out" \
    || fail_ "granted: the stack's own turned back on, the record forgotten: $(cat "$T/out")"; pass
[[ "$(disabled erin)" == true ]] || fail_ "erin granted too, but an admin disabled her by hand: stays disabled"; pass
[[ "$(disabled carol)" == true ]] || fail_ "carol's account still off: stays disabled"; pass
# someone an admin turned back on by hand: the record goes, nothing written
jq -c 'map(if .Name == "carol" then .Policy.IsDisabled = false else . end)' "$T/jf.json" > "$T/jf.n"; mv "$T/jf.n" "$T/jf.json"
printf '%s\n' "$(pu akadmin true '["admin"]')" "$(pu bob true '["frontend","app-jellyfin"]')" "$(pu carol true '["frontend","app-jellyfin"]')" "$(pu erin true '["frontend","app-jellyfin"]')" > "$T/portal.ndjson"
jfresh; jf_people_access tok > "$T/out" 2>&1; ! grep -q 'POST /Users/3/' "$T/jcalls" && [[ -z "$(people_get jellyfin carol)" ]] || fail_ "turned on by hand, and may: forgotten, nothing written: $(cat "$T/jcalls")"; pass
# Jellyfin ends the sign-ins itself on the disable: still counted, from before it
jq -c 'map(if .Name == "carol" then .Policy.IsDisabled = false else . end)' "$T/jf.json" > "$T/jf.n"; mv "$T/jf.n" "$T/jf.json"; people_set jellyfin carol ""
printf 'd7 3 carol\nd8 3 carol\nd9 2 bob\n' > "$T/dev.tsv"
printf '%s\n' "$(pu akadmin true '["admin"]')" "$(pu bob true '["frontend","app-jellyfin"]')" "$(pu carol false '["frontend"]')" "$(pu erin true '["frontend","app-jellyfin"]')" > "$T/portal.ndjson"
jfresh; JF_REVOKES=1 jf_people_access tok > "$T/out" 2>&1
grep -qF "'carol' can no longer sign in (portal account deactivated) — signed out of 2 device(s)" "$T/out" && [[ "$WIRE_FAILS" == 0 ]] && ! grep -q 'DELETE /Devices' "$T/jcalls" \
    || fail_ "Jellyfin ended them itself: the count from before the disable, nothing left for the sign-out, no failure: $(cat "$T/out")"; pass
[[ "$(cat "$T/dev.tsv")" == "d9 2 bob" ]] || fail_ "only carol's devices gone"; pass
jq -c 'map(if .Name == "carol" then .Policy.IsDisabled = false else . end)' "$T/jf.json" > "$T/jf.n"; mv "$T/jf.n" "$T/jf.json"; people_set jellyfin carol ""   # as the next checks found her

# failures: a write that does not hold; devices that stay
printf '%s\n' "$(pu akadmin true '["admin"]')" > "$T/portal.ndjson"
jfresh; JF_IGNORE=1 jf_people_access tok > "$T/out" 2>&1
[[ "$WIRE_FAILS" -ge 1 && -z "$(people_get jellyfin carol)" ]] && grep -qF "'carol' (portal account deleted) still signs in — it answered, but the change did not hold" "$T/out" \
    || fail_ "a disable that did not hold: a failure, nothing recorded: $(cat "$T/out")"; pass
printf 'd9 3 carol\n' > "$T/dev.tsv"
jfresh; DEV_KEEP=1 jf_people_access tok > "$T/out" 2>&1
[[ "$WIRE_FAILS" == 1 && "$(people_get jellyfin "removed-carol-$D")" == removed ]] && grep -qF "'carol' is disabled (portal account deleted), but still signed in somewhere — still signed in on 1 of 1 device(s)" "$T/out" \
    || fail_ "signed out did not hold: disabled and renamed still, a failure says what is left: $(cat "$T/out")"; pass
# deleted, and an admin had disabled them by hand: renamed all the same (the name is the risk), no policy written
printf '%s\n' "$(jfu 11 frank true)" "$(jfu 12 gina)" | jq -sc . > "$T/jf.json"; : > "$T/dev.tsv"
printf '%s\n' "$(pu gina true '["frontend"]')" > "$T/portal.ndjson"; TIER="frontend"
jfresh; jf_people_access tok > "$T/out" 2>&1
[[ "$(people_get jellyfin "removed-frank-$D")" == removed && ! -e "$T/jpol" ]] && grep -qF "'frank' (portal account deleted) kept as 'removed-frank-$D'" "$T/out" \
    || fail_ "deleted, disabled by hand: renamed, nothing else written: $(cat "$T/out")"; pass
# the rename refused: disabled and recorded off, the name kept, a failure; the next run renames it
printf '%s\n' "$(jfu 13 hank)" | jq -sc . > "$T/jf.json"; : > "$T/portal.ndjson"
jfresh; JF_NO_RENAME=1 jf_people_access tok > "$T/out" 2>&1
[[ "$(disabled hank) $(people_get jellyfin hank) $WIRE_FAILS" == "true off 1" ]] && grep -qF "'hank' (portal account deleted) is disabled, but keeps its name — Jellyfin refused the new name" "$T/out" \
    || fail_ "rename refused: off and recorded, a failure says so: $(cat "$T/out")"; pass
jfresh; jf_people_access tok > "$T/out" 2>&1
[[ "$(people_get jellyfin "removed-hank-$D") $WIRE_FAILS" == "removed 0" && ! -e "$T/jpol" ]] || fail_ "the next run renames it, nothing disabled twice: $(cat "$T/out")"; pass
# a group the rule reads missing: nobody judged
jq -c 'map(.Policy.IsDisabled = false)' "$T/jf.json" > "$T/jf.n"; mv "$T/jf.n" "$T/jf.json"
jfresh; NO_GROUPS=1 jf_people_access tok > "$T/out" 2>&1
[[ ! -e "$T/jpol" && "$WIRE_FAILS" == 1 ]] && grep -qF "authentik has no 'admin' group" "$T/out" || fail_ "a group missing: nobody touched, a failure says why: $(cat "$T/out")"; pass
# the filter follows a tier moved since wire; silent when it matches
jf_ldap_configure() { echo configured; }
jfc() { ( jf_api() { echo "{\"LdapSearchFilter\":\"$CUR\"}"; }; jf_ldap_want() { echo '{"LdapSearchFilter":"WANT"}'; }; jf_ldap_filter_follow tok ); }
[[ "$(CUR=WANT jfc)" == "" && "$(CUR=OLD jfc)" == configured ]] || fail_ "the filter: rewritten only when the rule moved"; pass
unset -f jf_api jf_code jf_ldap_configure

# ---- Kavita: who may sign in (slice C, decision 12) ----
kvu() { jq -cn --argjson i "$1" --arg n "$2" --argjson r "$3" --argjson p "${4:-1}" '{id:$i, username:$n, email:($n + "@x.org"), identityProvider:$p, roles:$r, libraries:[{id:1}], ageRestriction:null}'; }
kav_api() { # a fake Kavita: people in $T/kv.json
    echo "$1 $2" >> "$T/kcalls"
    case "$1 $2" in
        "GET /api/users?includePending=true") cat "$T/kv.json" ;;
        "POST /api/account/update") echo "$4" >> "$T/kupd"; [[ -n "${KV_IGNORE:-}" ]] && return 0
            jq -c --argjson b "$4" 'map(if .id == $b.userId then .roles = $b.roles | .username = $b.username | .email = $b.email else . end)' "$T/kv.json" > "$T/kv.n"; mv "$T/kv.n" "$T/kv.json" ;;
        *) echo "unexpected $1 $2" >&2; return 1 ;;
    esac
}
roles() { jq -r --arg n "$1" '.[] | select(.username == $n) | .roles | join(",")' "$T/kv.json"; }
kfresh() { rm -f "$T/kcalls" "$T/kupd" "$T/notified"; WIRE_FAILS=0; WIRE_DRY=0; }
fresh; kfresh
printf '%s\n' "$(kvu 1 kalice '["Login","Admin"]')" "$(kvu 2 kbob '["Login","Download"]')" "$(kvu 3 kcarol '["Login"]')" "$(kvu 4 kdave '["Login","Admin"]')" \
    "$(kvu 5 kerin '["Download"]')" "$(kvu 6 admin '["Login","Admin"]' 0)" | jq -sc . > "$T/kv.json"
printf '%s\n' "$(pu kalice true '["admin"]')" "$(pu kbob true '["frontend"]')" "$(pu kcarol false '["frontend"]')" "$(pu kerin true '["frontend"]')" > "$T/portal.ndjson"
TIER="frontend"; kav_people_access tok > "$T/out" 2>&1
[[ "$(roles kcarol) $(people_get kavita kcarol)" == " off" ]] && grep -qF "'kcarol' can no longer sign in (portal account deactivated) — an open tab ends at its next reload" "$T/out" \
    || fail_ "deactivated: Login taken, recorded off: $(cat "$T/out")"; pass
[[ "$(roles "removed-kdave-$D") $(people_get kavita "removed-kdave-$D") $(people_get kavita kdave)" == " removed " ]] \
    && [[ "$(jq -r '.[] | select(.id == 4) | .email' "$T/kv.json")" == "removed-kdave-$D@removed.invalid" ]] \
    && grep -qF "'kdave' can no longer sign in (portal account deleted) — kept as 'removed-kdave-$D'" "$T/out" \
    || fail_ "deleted: Login and Admin gone, renamed, an email nobody can sign up with (Kavita links a sign-in by email): $(cat "$T/out")"; pass
[[ "$(roles kbob) $(roles kalice) $(roles kerin) $(roles admin)" == "Login,Download Login,Admin Download Login,Admin" && -z "$(people_get kavita kerin)" ]] \
    || fail_ "may: untouched; kerin, shut out by hand: left so, never recorded; the stack's own (local): untouched"; pass
[[ "$(jq -c '[.[] | select(.id == 3)][0].libraries' "$T/kv.json")" == '[{"id":1}]' ]] && jq -e 'select(.userId == 3) | .libraries == [1] and .ageRestriction.ageRating == -1' "$T/kupd" >/dev/null \
    || fail_ "the whole account sent back as it was, one field changed (Kavita resets what is left out)"; pass
[[ "$(grep -c '^ops|' "$T/notified")" == 2 ]] || fail_ "ops hears each"; pass
kfresh; kav_people_access tok > "$T/out" 2>&1; [[ ! -e "$T/kupd" ]] && ! grep -q removed-kdave "$T/out" || fail_ "the next run: nothing written, the renamed account not looked at"; pass
kfresh; TIER="admin"; WIRE_DRY=1 kav_people_access tok > "$T/out" 2>&1
[[ ! -e "$T/kupd" ]] && grep -qF "would: kavita: 'kbob' (may no longer open Kavita) cannot sign in from now on" "$T/out" || fail_ "a dry run says it, writes nothing: $(cat "$T/out")"; pass
kfresh; kav_people_access tok > "$T/out" 2>&1
[[ "$(roles kbob) $(people_get kavita kbob)" == "Download off" ]] || fail_ "tier admin: kbob (frontend only) loses Login, recorded off"; pass
printf '%s\n' "$(pu kalice true '["admin"]')" "$(pu kbob true '["frontend","app-kavita"]')" "$(pu kcarol false '["frontend"]')" "$(pu kerin true '["frontend","app-kavita"]')" > "$T/portal.ndjson"
kfresh; kav_people_access tok > "$T/out" 2>&1
[[ "$(roles kbob) $(people_get kavita kbob)" == "Download,Login " ]] && grep -qF "'kbob' may sign in again — through the portal, their reading as they left it" "$T/out" \
    || fail_ "granted: the stack's own taken Login comes back, the record forgotten: $(cat "$T/out")"; pass
[[ "$(roles kerin)" == Download ]] || fail_ "kerin granted too, but shut out by hand: stays out"; pass
# failures: a change that does not hold; a group missing
printf '%s\n' "$(pu kalice true '["admin"]')" "$(pu kerin true '["frontend","app-kavita"]')" > "$T/portal.ndjson"
kfresh; KV_IGNORE=1 kav_people_access tok > "$T/out" 2>&1
[[ "$WIRE_FAILS" -ge 1 && -z "$(people_get kavita kbob)" ]] && grep -qF "'kbob' (portal account deleted) still signs in — it answered, but the change did not hold" "$T/out" \
    || fail_ "a change that did not hold: a failure, nothing recorded: $(cat "$T/out")"; pass
kfresh; NO_GROUPS=1 kav_people_access tok > "$T/out" 2>&1
[[ ! -e "$T/kupd" && "$WIRE_FAILS" == 1 ]] && grep -qF "authentik has no 'admin' group" "$T/out" || fail_ "a group missing: nobody touched, a failure says why: $(cat "$T/out")"; pass
unset -f kav_api
m=$(grep -E 'DATA_ROOT\}/media/' services/kavita/compose.yml)
[[ -n "$m" ]] && ! grep -v ':ro$' <<<"$m" >/dev/null || fail_ "Kavita's libraries mounted read-only: no account, an open tab included, changes a book (decision 15): $m"; pass

# ---- Audiobookshelf: who may sign in (slice D, decision 12) ----
abu() { jq -cn --arg i "$1" --arg n "$2" --argjson a "${3:-true}" --arg t "${4:-user}" --argjson l "${5:-true}" '{id:$i, username:$n, type:$t, isActive:$a, hasOpenIDLink:$l}'; }
abs_api() { # a fake Audiobookshelf: people in $T/ab.json
    echo "$1 $2" >> "$T/acalls"
    case "$1 $2" in
        "GET /api/users") jq -c '{users:.}' "$T/ab.json" ;;
        "GET /api/users/"*) jq -c --arg i "${2##*/}" '.[] | select(.id == $i)' "$T/ab.json" ;;
        "PATCH /api/users/"*) echo "$4" >> "$T/aupd"; [[ -n "${AB_IGNORE:-}" ]] && return 0
            jq -c --arg i "${2##*/}" --argjson p "$4" 'map(if .id == $i then . + $p else . end)' "$T/ab.json" > "$T/ab.n"; mv "$T/ab.n" "$T/ab.json" ;;
        *) echo "unexpected $1 $2" >&2; return 1 ;;
    esac
}
active() { jq -r --arg n "$1" '.[] | select(.username == $n) | .isActive' "$T/ab.json"; }
afresh() { rm -f "$T/acalls" "$T/aupd" "$T/notified"; WIRE_FAILS=0; WIRE_DRY=0; }
fresh; afresh
printf '%s\n' "$(abu a1 aalice true admin)" "$(abu a2 abob)" "$(abu a3 acarol)" "$(abu a4 adave)" "$(abu a5 aerin false)" \
    "$(abu a6 admin true root)" "$(abu a7 alocal true user false)" | jq -sc . > "$T/ab.json"
printf '%s\n' "$(pu aalice true '["admin"]')" "$(pu abob true '["frontend"]')" "$(pu acarol false '["frontend"]')" "$(pu aerin true '["frontend"]')" > "$T/portal.ndjson"
TIER="frontend"; abs_people_access tok > "$T/out" 2>&1
[[ "$(active acarol) $(people_get audiobookshelf acarol)" == "false off" ]] && grep -qF "'acarol' can no longer sign in (portal account deactivated) — an open tab ends at its next click" "$T/out" \
    || fail_ "deactivated: turned off (inactive), recorded off: $(cat "$T/out")"; pass
[[ "$(active "removed-adave-$D") $(people_get audiobookshelf "removed-adave-$D") $(people_get audiobookshelf adave)" == "false removed " ]] \
    && grep -qF "'adave' can no longer sign in (portal account deleted) — kept as 'removed-adave-$D'" "$T/out" \
    || fail_ "deleted: turned off and renamed (its usernames are unique: a newcomer under that name could not register): $(cat "$T/out")"; pass
[[ "$(active abob) $(active aalice) $(active aerin) $(active admin) $(active alocal)" == "true true false true true" && -z "$(people_get audiobookshelf aerin)" ]] \
    || fail_ "may: untouched; aerin, turned off by hand: left so, never recorded; root and a local account: untouched"; pass
! grep -qE 'PATCH /api/users/a(6|7)' "$T/acalls" || fail_ "the root account and local accounts are never written"; pass
[[ "$(grep -c '^ops|' "$T/notified")" == 2 ]] || fail_ "ops hears each"; pass
afresh; abs_people_access tok > "$T/out" 2>&1; [[ ! -e "$T/aupd" ]] && ! grep -q removed-adave "$T/out" || fail_ "the next run: nothing written, the renamed account not looked at"; pass
afresh; TIER="admin"; WIRE_DRY=1 abs_people_access tok > "$T/out" 2>&1
[[ ! -e "$T/aupd" ]] && grep -qF "would: audiobookshelf: 'abob' (may no longer open Audiobookshelf) is turned off" "$T/out" || fail_ "a dry run says it, writes nothing: $(cat "$T/out")"; pass
afresh; abs_people_access tok > "$T/out" 2>&1
[[ "$(active abob) $(people_get audiobookshelf abob)" == "false off" ]] || fail_ "tier admin: abob (frontend only) turned off, recorded"; pass
printf '%s\n' "$(pu aalice true '["admin"]')" "$(pu abob true '["frontend","app-audiobookshelf"]')" "$(pu acarol false '["frontend"]')" "$(pu aerin true '["frontend","app-audiobookshelf"]')" > "$T/portal.ndjson"
afresh; abs_people_access tok > "$T/out" 2>&1
[[ "$(active abob) $(people_get audiobookshelf abob)" == "true " ]] && grep -qF "'abob' may sign in again — through the portal, their listening as they left it" "$T/out" \
    || fail_ "granted: the stack's own turned off comes back on, the record forgotten: $(cat "$T/out")"; pass
[[ "$(active aerin)" == false ]] || fail_ "aerin granted too, but turned off by hand: stays off"; pass
printf '%s\n' "$(pu aalice true '["admin"]')" "$(pu aerin true '["frontend","app-audiobookshelf"]')" > "$T/portal.ndjson"
afresh; AB_IGNORE=1 abs_people_access tok > "$T/out" 2>&1
[[ "$WIRE_FAILS" -ge 1 && -z "$(people_get audiobookshelf abob)" ]] && grep -qF "'abob' (portal account deleted) still signs in — it answered, but the change did not hold" "$T/out" \
    || fail_ "a change that did not hold: a failure, nothing recorded: $(cat "$T/out")"; pass
afresh; NO_GROUPS=1 abs_people_access tok > "$T/out" 2>&1
[[ ! -e "$T/aupd" && "$WIRE_FAILS" == 1 ]] && grep -qF "authentik has no 'admin' group" "$T/out" || fail_ "a group missing: nobody touched, a failure says why: $(cat "$T/out")"; pass
unset -f abs_api

# ---- each app's part: the stack's own signs in first ----
part() { # part APP -> its output; the login refused
    ( WIRE_FAILS=0
      kav_api() { echo '{"title":"Unauthorized"}'; return 1; }; abs_api() { echo 'Unauthorized'; return 1; }; nd_login() { echo 'Invalid username or password'; return 1; }
      kav_admin_sync() { echo synced; }; abs_admin_sync() { echo synced; }; navidrome_people_sync() { echo synced; }; jf_admin_sync() { echo synced; }
      jf_ldap_filter_follow() { echo filter; }; jf_people_access() { echo access; }
      "${1}_people_follow"; echo "fails=$WIRE_FAILS" ) 2>&1
}
[[ "$(part jellyfin)" == *"no API key in .env (JELLYFIN_API_KEY)"*"fails=1" ]] || fail_ "jellyfin with no key: a failure"; pass
printf 'JELLYFIN_API_KEY=k\n' > "$ENV_FILE"; [[ "$(part jellyfin | tr '\n' ' ')" == "filter access synced fails=0 " ]] || fail_ "jellyfin: its key, then the filter, who may sign in, admin rights: $(part jellyfin)"; pass
[[ "$(part kavita)" == *"kavita rejected the stored admin login"*"fails=1" && "$(part kavita)" != *synced* ]] || fail_ "kavita refused: a failure, nothing synced"; pass
[[ "$( ( WIRE_FAILS=0; kav_login() { echo KTOK; }; kav_people_access() { echo "access $1"; }; kav_admin_sync() { echo "synced $1"; }; kavita_people_follow ) | tr '\n' ' ')" == "access KTOK synced KTOK " ]] \
    || fail_ "kavita: the stack's admin signs in, then who may sign in, then admin rights"; pass
[[ "$(grep -rh 'kav_api POST /api/account/login' services lib | wc -l)" == 1 ]] || fail_ "Kavita's admin login lives in kav_login alone (wire, doctor, people-sync, link-account, rotation use it)"; pass
[[ "$( ( WIRE_FAILS=0; abs_login() { echo ATOK; }; abs_people_access() { echo "access $1"; }; abs_admin_sync() { echo "synced $1"; }; audiobookshelf_people_follow ) | tr '\n' ' ')" == "access ATOK synced ATOK " ]] \
    || fail_ "audiobookshelf: root signs in, then who may sign in, then admin rights"; pass
[[ "$(grep -rh 'abs_api POST /login' services lib | wc -l)" == 1 ]] || fail_ "Audiobookshelf's root login lives in abs_login alone (wire, people-sync, link-account, rotation use it)"; pass
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
