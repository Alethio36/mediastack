#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-navidrome.sh — Navidrome's stack admin and its people following the
# portal (services/navidrome/navidrome.sh, people.sh), against a fake Navidrome:
#   * the stack's admin: signs in when it exists; made with createAdmin on a
#     fresh install; when Navidrome already has accounts, wire fails saying
#     how to add it; a dry run never creates it
#   * a portal person seen in Navidrome is recorded; admin rights follow the
#     portal's admins group (either way)
#   * deactivated on the portal: the password is replaced with Navidrome's
#     "nobody chose it" kind and admin rights go — once; ops hears it;
#     reactivated, recorded again and nothing written
#   * deleted from the portal: also renamed removed-<name>-<date>, the old
#     name forgotten, the new one never looked at again
#   * never touched: the stack's admin, an account the portal was never seen
#     behind; names match in any case
#   * a dry run writes nothing, records nothing; a write that does not hold
#     is a failure and records nothing
#   * the timer: every 15 minutes, runs people-sync, in the footprint; wire
#     navidrome installs it only with the portal and once the stack's admin
#     signs in (never up, never a dry run); people-sync does nothing without
#     them; Navidrome is published on 127.0.0.1 only
#
#   scripts/test-navidrome.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-navidrome.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

ENV_FILE=$T/.env; LOCAL_DIR=$T/local; STATE_DIR=$T/local/state; NAVIDROME_PEOPLE=$T/local/navidrome-people
printf 'NAVIDROME_ADMIN_USER=admin\nNAVIDROME_ADMIN_PASSWORD=pw-of-the-stack\n' > "$ENV_FILE"
repo_owned() { :; }; ok() { echo "OK $*"; }; info() { echo ":: $*"; }; warn() { echo "WARN $*"; }; fail() { echo "FAIL $*"; }
notify() { echo "$1|$3" >> "$T/notified"; }

# ---- a fake Navidrome: its users in $T/nd.json, its admin login, its createAdmin ----
nd_api() { # METHOD PATH TOKEN [json]
    echo "$1 $2" >> "$T/calls"
    case "$1 $2" in
        "POST /auth/login")
            [[ "$(jq -r .password <<<"$4")" == "${ND_PW:-pw-of-the-stack}" && -n "${ND_HAS_ADMIN-1}" ]] && { echo '{"token":"tok-1"}'; return 0; }
            echo '{"error":"Invalid username or password"}'; return 1 ;;
        "POST /auth/createAdmin")
            [[ -n "${ND_EMPTY:-}" ]] && { echo '{"token":"tok-new"}'; return 0; }
            echo '{"error":"Cannot create another first admin"}'; return 1 ;;
        "GET /api/user") cat "$T/nd.json" ;;
        "GET /api/user/"*) jq -c --arg i "${2##*/}" '.[] | select(.id == $i)' "$T/nd.json" ;;
        "PUT /api/user/"*)
            echo "$4" >> "$T/puts"
            [[ -n "${ND_IGNORE:-}" ]] && return 0   # answers, changes nothing
            jq -c --arg i "${2##*/}" --argjson b "$4" --arg t "$(date +%s%N)" 'map(if .id == $i then ($b | del(.password)) + {updatedAt: $t} else . end)' "$T/nd.json" > "$T/nd.new"
            mv "$T/nd.new" "$T/nd.json" ;;
        *) echo "unexpected $1 $2" >&2; return 1 ;;
    esac
}
nd_user() { jq -cn --arg i "$1" --arg n "$2" --argjson a "${3:-false}" '{id:$i, userName:$n, name:$n, email:"", isAdmin:$a, updatedAt:"before"}'; }
portal_user() { jq -cn --arg n "$1" --argjson a "$2" --argjson g "${3:-[]}" '{username:$n, is_active:$a, groups_obj:($g | map({name:.}))}'; }
signin_people() { jq -cn --slurpfile p "$T/portal.ndjson" '{results:$p}'; }
fresh() { # fresh — an empty record, nothing called yet
    rm -rf "$T/local" "$T/calls" "$T/puts" "$T/notified"; mkdir -p "$T/local"
    WIRE_FAILS=0; WIRE_DRY=0; WIRE_CHANGES=0
}
nd_set()     { printf '%s\n' "$@" | jq -sc . > "$T/nd.json"; }
portal_set() { printf '%s\n' "$@" > "$T/portal.ndjson"; }
user_field() { jq -r --arg n "$1" --arg f "$2" '.[] | select(.userName == $n) | .[$f]' "$T/nd.json"; }

# ---- the stack's admin ----
fresh; nd_admin_ensure >/dev/null && [[ "$ND_TOKEN" == tok-1 ]] && ! grep -q createAdmin "$T/calls" || fail_ "it exists: signs in, nothing made"; pass
fresh; out=$(ND_HAS_ADMIN='' ND_EMPTY=1 nd_admin_ensure; echo "rc=$? tok=$ND_TOKEN")
[[ "$out" == *"admin 'admin' created"* && "$out" == *"rc=0 tok=tok-new"* ]] || fail_ "a fresh install: made with createAdmin, its token used: $out"; pass
fresh; out=$(ND_HAS_ADMIN='' nd_admin_ensure; echo "rc=$? fails=$WIRE_FAILS")
[[ "$out" == *"its first visitor became its admin"*"add the user 'admin'"*"rc=1 fails=1" ]] || fail_ "accounts there already: a failure that says how to add it: $out"; pass
fresh; out=$(WIRE_DRY=1 ND_HAS_ADMIN='' ND_EMPTY=1 nd_admin_ensure; echo "rc=$?")
[[ "$out" == *"rc=1" ]] && ! grep -q createAdmin "$T/calls" || fail_ "a dry run never makes it: $out"; pass

# ---- the people ----
D=$(date +%Y%m%d)
fresh
nd_set "$(nd_user 1 admin true)" "$(nd_user 2 Alice)" "$(nd_user 3 bob true)" "$(nd_user 4 carol)" "$(nd_user 5 dave)"
portal_set "$(portal_user alice true '["media-users","admins"]')" "$(portal_user bob true '["media-users"]')" "$(portal_user carol true)"
navidrome_people_sync tok-1 > "$T/out"
[[ "$(sort "$NAVIDROME_PEOPLE" | cut -f1,2 | tr '\t\n' ': ')" == "Alice:on bob:on carol:on " ]] || fail_ "the portal's people recorded, any case: $(cat "$NAVIDROME_PEOPLE")"; pass
[[ "$(user_field Alice isAdmin) $(user_field bob isAdmin)" == "true false" ]] || fail_ "admin rights follow the admins group, both ways"; pass
grep -qF "'dave' is not tied to a portal account" "$T/out" && [[ "$(user_field admin isAdmin)" == true ]] || fail_ "dave (never on the portal) and the stack's admin: left alone"; pass
! grep -qF "'admin'" "$T/out" || fail_ "the stack's admin is not even looked at: $(grep -F "'admin'" "$T/out")"; pass
[[ "$(wc -l < "$T/puts")" == 2 && "$WIRE_FAILS" == 0 ]] || fail_ "two writes, no failure: $(cat "$T/puts")"; pass

# bob deactivated, carol deleted
fresh_keep() { rm -f "$T/calls" "$T/puts" "$T/notified"; WIRE_FAILS=0; WIRE_DRY=0; }
fresh_keep
portal_set "$(portal_user alice true '["admins"]')" "$(portal_user bob false '["media-users"]')"
WIRE_DRY=1 navidrome_people_sync tok-1 > "$T/out"
[[ ! -e "$T/puts" && "$(nd_people_get bob)" == on ]] && grep -qF "would: navidrome: 'bob' (portal account deactivated)" "$T/out" \
    || fail_ "a dry run says what it would do and writes nothing"; pass
fresh_keep; navidrome_people_sync tok-1 > "$T/out"
bp=$(grep -F '"userName":"bob"' "$T/puts")
[[ "$(jq -r .password <<<"$bp")" == __NAVIDROME_AUTOGEN__* && "$(jq -r .isAdmin <<<"$bp")" == false && "$(nd_people_get bob)" == off ]] \
    || fail_ "deactivated: an unchosen password, no admin, recorded off: $bp"; pass
cp=$(grep -F '"userName":"removed-carol-' "$T/puts")
[[ "$(jq -r .password <<<"$cp")" == __NAVIDROME_AUTOGEN__* && "$(user_field "removed-carol-$D" id)" == 4 ]] \
    || fail_ "deleted: an unchosen password, renamed removed-carol-<date>: $cp"; pass
[[ -z "$(nd_people_get carol)" && "$(nd_people_get "removed-carol-$D")" == removed ]] || fail_ "the old name forgotten, the new one marked"; pass
[[ "$(grep -c '^ops|' "$T/notified")" == 2 ]] && grep -qF "bob's music apps are stopped" "$T/notified" || fail_ "ops hears each one"; pass
[[ "$(jq -r '.[] | select(.password? != null)' "$T/nd.json")" == "" && "$(grep -c . "$T/puts")" == 2 ]] || fail_ "two writes"; pass
fresh_keep; navidrome_people_sync tok-1 > "$T/out"
[[ ! -e "$T/puts" ]] && ! grep -q "removed-carol" "$T/out" || fail_ "the next run: nothing written again, the renamed account not looked at"; pass

# bob comes back
fresh_keep; portal_set "$(portal_user alice true '["admins"]')" "$(portal_user bob true '["media-users"]')"
navidrome_people_sync tok-1 > "$T/out"
[[ "$(nd_people_get bob)" == on && ! -e "$T/puts" ]] && grep -qF "'bob' is back on the portal" "$T/out" || fail_ "reactivated: recorded again, nothing written"; pass

# a write that does not hold
fresh_keep; portal_set "$(portal_user alice true '["admins"]')" "$(portal_user bob false)"
ND_IGNORE=1 navidrome_people_sync tok-1 > "$T/out"
[[ "$WIRE_FAILS" == 1 && "$(nd_people_get bob)" == on ]] && grep -qF "'bob' (portal account deactivated) still plays music — it answered, but the change did not hold" "$T/out" \
    || fail_ "a change that did not hold: a failure, nothing recorded: $(cat "$T/out")"; pass

# the portal unreadable: nothing touched
fresh_keep; signin_people() { echo "HTTP 500"; return 1; }
navidrome_people_sync tok-1 > "$T/out"
[[ "$WIRE_FAILS" == 1 && ! -e "$T/puts" ]] || fail_ "the portal unreadable: a failure, nothing written"; pass

# ---- the timer, the verb, the port ----
[[ "$(timer_timer_render x '*:0/15')" == *"OnCalendar=*:0/15"* ]] && grep -qF 'timer_timer_render "Mediastack: Navidrome follows the portal" "*:0/15"' services/navidrome/people.sh \
    && grep -qF 'timer_service_render "Mediastack: Navidrome follows the portal" people-sync' services/navidrome/people.sh || fail_ "every 15 minutes, people-sync"; pass
[[ "$(fp_timers)" == *mediastack-people.timer* && "$(fp_timers)" == *mediastack-people.service* ]] || fail_ "the timer is in the footprint (uninstall removes it)"; pass
! grep -q people_timer_ensure <(awk '/^cmd_up\(\)/,/^}/' mediastack.sh) || fail_ "up never installs it: its first run could beat wire's createAdmin (found live)"; pass
wired() { # wired [VAR=value...] — wire_navidrome against the fake; -> what ran, in order
    rm -f "$T/order"
    ( for a in "$@"; do export "${a?}"; done
      svc_enabled() { return 0; }; wire_gate() { :; }; nd_ready() { return 0; }
      signin_is() { [[ "${SIGNIN_X:-authentik}" == "$1" ]]; }
      people_timer_ensure() { echo timer >> "$T/order"; }
      navidrome_people_sync() { echo sync >> "$T/order"; }
      wire_navidrome >/dev/null 2>&1 )
    [[ ! -e "$T/order" ]] || tr '\n' ' ' < "$T/order"
}
fresh; nd_set; portal_set
[[ "$(wired)" == "timer sync " ]] || fail_ "the admin signs in: the timer, then the sync: $(wired)"; pass
fresh; [[ "$(wired ND_HAS_ADMIN= ND_EMPTY=1)" == "timer sync " ]] || fail_ "a fresh install: the admin made first, then the timer"; pass
fresh; [[ -z "$(wired ND_HAS_ADMIN=)" ]] || fail_ "the admin does not sign in: no timer, no sync"; pass
fresh; [[ "$(wired WIRE_DRY=1)" == "sync " ]] || fail_ "a dry run installs no timer"; pass
fresh; [[ -z "$(wired SIGNIN_X=wizarr)" ]] || fail_ "without the portal: no timer"; pass
verb_entry people-sync >/dev/null || fail_ "people-sync is a verb"; pass
( load_env() { :; }; render() { :; }; signin_is() { return 1; }; nd_login() { echo called > "$T/login"; }; rm -f "$T/login"; cmd_people_sync ) && [[ ! -e "$T/login" ]] \
    || fail_ "people-sync without the portal: nothing to do, nothing called"; pass
grep -q '"127.0.0.1:${NAVIDROME_PORT:-4533}:4533"' services/navidrome/compose.yml || fail_ "Navidrome is published on 127.0.0.1 only (the script's way in)"; pass
r=" ${WIRE_ROLES[*]} "; [[ "$r" == *" authentik "*" navidrome "* ]] || fail_ "navidrome is wired after authentik"; pass

echo "OK navidrome: $checks checks"
