#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-rotate.sh — rotate-secrets' rules (docs/design-rotate.md):
#   * a secret compose carries moves all-or-nothing: proven on its new value,
#     or put back on its old one and proven there, or the run is told it is
#     stuck — and the journal holds it while it is in flight, never after
#   * no value is ever printed
#   * a rotation that never finished is refused until the stack is put back,
#     and doctor names it; one that stopped between secrets is not in flight
#   * the closing warning: framed at one width, a line per cost that leaves
#     work outside the stack, the outside secrets this install holds
#   * Meilisearch's key is proven by the new one taken and the old refused
#   * every cost tag a service uses has its words; a key is proven by the new
#     one opening and the old refused
#   * the keys outside authentik: an owner that makes its own (the arrs,
#     Seerr, Cleanuparr) is unchanged when it refuses, held when it took the
#     change but is not proven; Jellyfin's old key goes only once the new one
#     opens; Bazarr's and LazyLibrarian's go back when not taken; the arrs
#     before Prowlarr
#   * the portal: several secrets held in flight together; its API token
#     unchanged when the new key is refused; its settings (the database
#     password first) all new when proven, all back when not, held when
#     neither; every session ended and checked gone
#
#   scripts/test-rotate.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
lib=$(mktemp .test-rotate.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"
set +e +E; trap - ERR   # each check reads its own status

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

LOCAL_DIR=$T/local; ROTATE_DIR=$LOCAL_DIR/rotate; ROTATE_JOURNAL=$ROTATE_DIR/journal
repo_owned() { :; }; load_env() { :; }
env_get() { sed -n "s/^$1=//p" "$T/env" 2>/dev/null; }
env_set() { sed -i "/^$1=/d" "$T/env"; echo "$1=$2" >> "$T/env"; }

# ---- one secret, all-or-nothing ----
re() { # re PROVES-NEW PROVES-OLD -> "rc=N env=VALUE inflight=NAME" (and the output in $T/out)
    ( echo "K=OLDVALUE" > "$T/env"; rotate_journal_start 20261113-120000
      rotate_up() { :; }
      prove() { if [[ "$1" == NEWVALUE ]]; then [[ "$PN" == yes ]]; else [[ "$PO" == yes ]]; fi; }
      PN=$1 PO=$2; rc=0; rotate_env K NEWVALUE prove > "$T/out" 2>&1 || rc=$?
      echo "rc=$rc env=$(env_get K) inflight=$(rotate_inflight)" )
}
[[ "$(re yes yes)" == "rc=0 env=NEWVALUE inflight=" ]] || fail_ "proven on the new value: kept, nothing in flight: $(re yes yes)"; pass
[[ "$(re no yes)" == "rc=1 env=OLDVALUE inflight=" ]] || fail_ "the new one not proven: back on the old, nothing in flight: $(re no yes)"; pass
[[ "$(re no no)" == "rc=2 env=OLDVALUE inflight=K" ]] || fail_ "neither proven: stuck, the journal still holds it: $(re no no)"; pass
re no no >/dev/null; ! grep -qE 'OLDVALUE|NEWVALUE' "$T/out" || fail_ "a value was printed: $(cat "$T/out")"; pass
[[ "$(stat -c %a "$ROTATE_JOURNAL")" == 600 && "$(stat -c %a "$ROTATE_DIR")" == 700 ]] \
    || fail_ "the journal holds values: 0600 in a 0700 folder"; pass
[[ "$(rotate_journal_point)" == 20261113-120000 ]] || fail_ "the journal keeps the run's restore point"; pass

# ---- a rotation that never finished ----
rotate_journal_start 20261113-120000; rotate_journal_hold K a b
r=$( (cmd_rotate_secrets) 2>&1 </dev/null; echo "rc=$?")
[[ "$r" == *"K was in flight"*"restore --all --from 20261113-120000"*"rc=1" ]] || fail_ "in flight: refused, the way back named: $r"; pass
D_FAILS=0; r=$(run_unfinished() { :; }; _doctor_runs 2>&1)
[[ "$r" == *"a rotation never finished: K"* ]] || fail_ "doctor names a rotation in flight: $r"; pass
rotate_journal_release
[[ -z "$(rotate_inflight)" ]] || fail_ "settled between secrets: nothing in flight"; pass
r=$( (cmd_rotate_secrets) 2>&1 </dev/null; echo "rc=$?")
[[ "$r" == *"interactive"*"rc=1" ]] || fail_ "stopped between secrets is no refusal; no terminal is: $r"; pass

# ---- the closing warning ----
echo "CF_DNS_API_TOKEN=x" > "$T/env"
r=$(rotate_box_lines search)
[[ "$r" == *"Nothing outside the stack held these"* ]] || fail_ "a cost with nothing to do outside: said so: $r"; pass
[[ "$r" == *"Cloudflare's DNS token"* && "$r" != *"tunnel"* && "$r" != *"VPN's key"* ]] \
    || fail_ "the outside secrets this install holds, and only those: $r"; pass
C_YLW=""; C_BLD=""; C_RST=""
w=$(rotate_box "• a line — with dashes" --- "$(printf 'word %.0s' $(seq 1 40))" | while IFS= read -r l; do LC_ALL=C.UTF-8; echo "${#l}"; done | sort -u)
[[ "$(wc -l <<<"$w")" == 1 ]] || fail_ "every line of the frame is one width (long lines fold): $w"; pass

# ---- Meilisearch's key ----
mk() { ( meili_key_code() { case "$1" in NEW) echo "$A" ;; OLD) echo "$B" ;; esac; }; sleep() { :; }
         A=$1 B=$2; meili_key_proven NEW OLD >/dev/null 2>&1; echo $? ) }
[[ "$(mk 200 403)" == 0 ]] || fail_ "meilisearch: new taken, old refused: proven"; pass
[[ "$(mk 200 200)" == 1 ]] || fail_ "meilisearch: the old still taken: not proven"; pass
[[ "$(mk 403 403)" == 1 ]] || fail_ "meilisearch: the new refused: not proven"; pass
[[ "$(svc_enabled() { return 1; }; meilisearch_secrets)" == "" ]] || fail_ "meilisearch off: nothing to rotate"; pass
[[ "$(svc_enabled() { :; }; meilisearch_secrets)" == $'MEILI_MASTER_KEY\tsearch' ]] || fail_ "meilisearch on: its key, tagged search"; pass

# ---- slice 2: the keys outside authentik ----
http_ready() { :; }   # each rotator's readiness wait: up, unless a check says otherwise
for t in $(grep -hoE "printf '[^']*\\\\t[a-z,-]*\\\\n'" services/*/*.sh | sed -n "s/.*\\\\t\([a-z,-]*\)\\\\n'/\1/p" | tr ',' '\n' | sort -u); do
    [[ -n "${ROTATE_COSTS[$t]+x}" && -n "${ROTATE_AFTER[$t]+x}" ]] || fail_ "the cost tag '$t' has no words in ROTATE_COSTS and ROTATE_AFTER"
done; pass
[[ "$(printf '%s\n' "${!ROTATE_COSTS[@]}" | sort | paste -sd' ' -)" == "$(printf '%s\n' "${!ROTATE_AFTER[@]}" | sort | paste -sd' ' -)" ]] \
    || fail_ "every cost tag has its words both before the run and after it"; pass
[[ "$(svc_enabled() { :; }; signin_is() { [[ "$1" == wizarr ]]; }; env_get() { echo k; }; jellyfin_secrets | cut -f2)" == wizarr-jellyfin ]] \
    || fail_ "jellyfin with Wizarr on: its key carries the Wizarr cost"; pass
sleep() { :; }
rp() { ( rotate_http_code() { case "$2" in *NEW) echo "$A" ;; *OLD) echo "$B" ;; esac; }; A=$1 B=$2; rotate_proven x u "H: NEW" "H: OLD" >/dev/null 2>&1; echo $? ); }
[[ "$(rp 200 401)" == 0 && "$(rp 200 403)" == 0 ]] || fail_ "the new one opens, the old one is refused: proven"; pass
[[ "$(rp 200 200)" == 1 && "$(rp 401 401)" == 1 && "$(rp 200 000)" == 1 ]] || fail_ "the old one still opens, the new one refused, or no answer: not proven"; pass

ar() { # ar RESET(ok|no) KEY-AFTER OLD-CODE NEW-CODE -> "rc=N inflight=X"
    ( echo "point	p" > "$ROTATE_JOURNAL"
      arr_key() { if [[ -f "$T/reset" ]]; then echo "$KA"; else echo OLDK; fi; }
      arr_url() { echo http://a; }; arr_apiver() { echo v3; }
      api() { [[ "$RS" == ok ]] && touch "$T/reset"; [[ "$RS" == ok ]]; }
      rotate_http_code() { case "$2" in *OLDK) echo "$OC" ;; *) echo "$NC" ;; esac; }
      rm -f "$T/reset"; RS=$1 KA=$2 OC=$3 NC=$4; rc=0; arr_secret_rotate "sonarr API key" >/dev/null 2>&1 || rc=$?
      echo "rc=$rc inflight=$(rotate_inflight)" )
}
[[ "$(ar no OLDK 200 200)" == "rc=1 inflight=" ]] || fail_ "arr: the reset refused: unchanged, nothing in flight: $(ar no OLDK 200 200)"; pass
[[ "$(ar ok NEWK 401 200)" == "rc=0 inflight=" ]] || fail_ "arr: a new key, proven: done: $(ar ok NEWK 401 200)"; pass
[[ "$(ar ok OLDK 200 200)" == "rc=1 inflight=" ]] || fail_ "arr: the reset took but the key stayed and still opens: kept: $(ar ok OLDK 200 200)"; pass
[[ "$(ar ok OLDK 401 401)" == "rc=2 inflight=sonarr API key" ]] || fail_ "arr: no new key, the old refused: stuck, held: $(ar ok OLDK 401 401)"; pass
[[ "$(ar ok NEWK 200 200)" == "rc=2 inflight=sonarr API key" ]] || fail_ "arr: the old key still opens after the reset: stuck, held: $(ar ok NEWK 200 200)"; pass
r=$(arr_instances() { echo radarr sonarr; }; svc_enabled() { :; }; arr_secrets | cut -f1 | paste -sd, -)
[[ "$r" == "radarr API key,sonarr API key,prowlarr API key" ]] || fail_ "the arrs first, Prowlarr last: $r"; pass

jf() { # jf NEW-OPENS(yes|no) -> "rc=N env=K calls"
    ( echo "JELLYFIN_API_KEY=JOLD" > "$T/env"; echo "point	p" > "$ROTATE_JOURNAL"; rm -f "$T/c"
      jf_url() { echo http://j; }; jf_code() { echo 200; }; svc_enabled() { return 1; }
      jf_api() { echo "$1 $2 $3" >> "$T/c"; [[ "$1 $2" == "GET /Auth/Keys" ]] && echo '{"Items":[{"AppName":"mediastack","AccessToken":"JOLD"},{"AppName":"mediastack","AccessToken":"JNEW"}]}'; return 0; }
      rotate_http_code() { case "$2" in *JNEW*) [[ "$NO" == yes ]] && echo 200 || echo 401 ;; *) echo 401 ;; esac; }
      NO=$1; rc=0; jellyfin_secret_rotate >/dev/null 2>&1 || rc=$?
      echo "rc=$rc env=$(env_get JELLYFIN_API_KEY) $(grep DELETE "$T/c" | paste -sd, -)" )
}
[[ "$(jf yes)" == "rc=0 env=JNEW DELETE /Auth/Keys/JOLD JNEW" ]] || fail_ "jellyfin: the new key opens: stored, the old one deleted with it: $(jf yes)"; pass
[[ "$(jf no)" == "rc=1 env=JOLD DELETE /Auth/Keys/JNEW JOLD" ]] || fail_ "jellyfin: the new key does not open: it is deleted, the old kept: $(jf no)"; pass

sr() { # sr CODE -> "rc=N env=K"
    ( echo "SEERR_API_KEY=SOLD" > "$T/env"; echo "point	p" > "$ROTATE_JOURNAL"
      seerr_url() { echo http://s; }; curl() { printf '{"apiKey":"SNEW"}\n%s' "$C"; }
      rotate_proven() { :; }; C=$1; rc=0; seerr_secret_rotate >/dev/null 2>&1 || rc=$?
      echo "rc=$rc env=$(env_get SEERR_API_KEY)" )
}
[[ "$(sr 200)" == "rc=0 env=SNEW" ]] || fail_ "seerr: regenerated: .env takes it: $(sr 200)"; pass
[[ "$(sr 403)" == "rc=1 env=SOLD" ]] || fail_ "seerr: the regenerate refused: unchanged: $(sr 403)"; pass

bz() { ( echo "point	p" > "$ROTATE_JOURNAL"; bazarr_key() { echo BOLD; }; arr_url() { echo http://b; }; curl() { echo "$C"; }
         rotate_proven() { :; }; C=$1; rc=0; bazarr_secret_rotate >/dev/null 2>&1 || rc=$?; echo "rc=$rc inflight=$(rotate_inflight)" ); }
[[ "$(bz 204)" == "rc=0 inflight=" && "$(bz 400)" == "rc=1 inflight=" ]] || fail_ "bazarr: taken -> done; refused -> unchanged: $(bz 204) / $(bz 400)"; pass

ll() { # ll NEW-TAKES -> "rc=N" and the keys written, in order
    ( echo "point	p" > "$ROTATE_JOURNAL"; rm -f "$T/c"; ll_key() { echo LOLD; }
      ll_api_enable() { echo "$1" >> "$T/c"; }
      ll_key_takes() { if [[ "$1" == LOLD ]]; then [[ "$NT" != yes ]]; else [[ "$NT" == yes ]]; fi; }
      NT=$1; rc=0; lazylibrarian_secret_rotate >/dev/null 2>&1 || rc=$?; echo "rc=$rc $(sed 's/^[0-9a-f]\{32\}$/NEW/' "$T/c" | paste -sd, -)" )
}
[[ "$(ll yes)" == "rc=0 NEW" ]] || fail_ "lazylibrarian: the new key taken, the old refused: done: $(ll yes)"; pass
[[ "$(ll no)" == "rc=1 NEW,LOLD" ]] || fail_ "lazylibrarian: the new key not taken: the old one written back: $(ll no)"; pass

r=$(svc_cname() { echo g; }; sudo() { printf 'Connecting to 127.0.0.1:8008\n  HTTP/1.1 401 Unauthorized\n'; }; gluetun_control_code K)
[[ "$r" == 401 ]] || fail_ "gluetun: the control server's code read from wget's headers: $r"; pass
r=$(svc_cname() { echo g; }; sudo() { return 1; }; gluetun_control_code K)
[[ "$r" == "" ]] || fail_ "gluetun: no answer reads as none, never a code: $r"; pass

# an app still starting (after the restore point's restart) is waited for; never answering, nothing changes
r=$( ( echo "point	p" > "$ROTATE_JOURNAL"; rm -f "$T/c"; http_ready() { return 1; }; bazarr_key() { echo BOLD; }; arr_url() { echo http://b; }
       curl() { echo POST >> "$T/c"; echo 204; }; rc=0; bazarr_secret_rotate >/dev/null 2>&1 || rc=$?; echo "rc=$rc posts=$( { cat "$T/c" 2>/dev/null || true; } | wc -l)" ) )
[[ "$r" == "rc=1 posts=0" ]] || fail_ "an app that never answers: kept, nothing sent: $r"; pass
for f in jellyfin_secret_rotate arr_secret_rotate seerr_secret_rotate cleanuparr_secret_rotate bazarr_secret_rotate lazylibrarian_secret_rotate; do
    declare -f "$f" | grep 'http_ready' >/dev/null || fail_ "$f asks its app without waiting for it to be up"
done; pass
# LazyLibrarian answers a wrong key with JSON too: only Success true is its own (found live)
lk() { ( ll_url() { echo http://l; }; curl() { echo "$A"; }; A=$1; ll_key_takes K && echo takes || echo refused ); }
[[ "$(lk '{"Success": true, "current_version": "x"}')" == takes ]] || fail_ "lazylibrarian: its own key: taken"; pass
[[ "$(lk '{"Success": false, "Data": "", "Error": {"Code": 401, "Message": "Incorrect API key"}}')" == refused ]] || fail_ "lazylibrarian: a wrong key's JSON: refused"; pass
[[ "$(lk '')" == refused ]] || fail_ "lazylibrarian: no answer: refused"; pass
declare -f ll_api_enable | grep 'll_key_takes "$key"' >/dev/null || fail_ "ll_api_enable proves the key it wrote, not any JSON answer"; pass

# ---- slice 3: the portal ----
rotate_journal_start p; rotate_journal_hold A a1 a2 B b1 b2
[[ "$(rotate_inflight)" == "A B" ]] || fail_ "several secrets held together are all named in flight: $(rotate_inflight)"; pass
r=$(svc_enabled() { :; }; env_get() { [[ "$1" == AUTHENTIK_LDAP_TOKEN ]] && echo t; return 0; }; authentik_secrets | cut -f1,2 | paste -sd'|' -)
[[ "$r" == $'AUTHENTIK_API_TOKEN\t|AUTHENTIK_ADMIN_PASSWORD\takadmin|AUTHENTIK_LDAP_TOKEN\t|authentik\'s settings\tportal' ]] || fail_ "the portal's secrets, in order: $r"; pass
r=$(svc_enabled() { :; }; env_get() { :; }; authentik_secrets | cut -f1 | paste -sd'|' -)
[[ "$r" != *LDAP_TOKEN* ]] || fail_ "no LDAP outpost token yet: not listed"; pass

at() { # at SET-KEY(ok|no) -> "rc=N env=K"
    ( echo "AUTHENTIK_API_TOKEN=TOLD" > "$T/env"; rotate_journal_start p
      ak_token_set_key() { [[ "$SK" == ok ]]; }; rotate_proven() { :; }; authentik_url() { echo http://a; }
      SK=$1; rc=0; authentik_rotate_api_token >/dev/null 2>&1 || rc=$?; echo "rc=$rc env=$(env_get AUTHENTIK_API_TOKEN | cut -c1-4)" )
}
[[ "$(at no)" == "rc=1 env=TOLD" ]] || fail_ "API token: the new key refused: unchanged: $(at no)"; pass
[[ "$(at ok)" != *TOLD* && "$(at ok)" == rc=0* ]] || fail_ "API token: a new key taken: .env follows: $(at ok)"; pass

as() { # as DB-SET(ok|no) NEW-PROVEN(yes|no) OLD-PROVEN(yes|no) -> "rc=N secretkey=old|new dbset=calls"
    ( : > "$T/env"; for k in AUTHENTIK_SECRET_KEY AUTHENTIK_DB_PASSWORD AUTHENTIK_LDAP_BIND_PASSWORD AUTHENTIK_ABS_CLIENT_SECRET AUTHENTIK_KAVITA_CLIENT_SECRET; do echo "$k=OLD$k" >> "$T/env"; done
      rotate_journal_start p; rm -f "$T/c"
      ak_db_password_set() { if [[ "$1" == OLD* ]]; then echo old >> "$T/c"; else echo new >> "$T/c"; fi; [[ "$DS" == ok ]]; }
      rotate_up() { :; }
      authentik_settings_proven() { if [[ "$1" == OLD* ]]; then [[ "$OP" == yes ]]; else [[ "$NP" == yes ]]; fi; }
      DS=$1 NP=$2 OP=$3; rc=0; authentik_rotate_settings >/dev/null 2>&1 || rc=$?
      sk=$(env_get AUTHENTIK_SECRET_KEY); [[ "$sk" == OLD* ]] && sk=old || sk=new
      echo "rc=$rc secretkey=$sk dbset=$(paste -sd, "$T/c") inflight=$(rotate_inflight | wc -w)" )
}
[[ "$(as no yes yes)" == "rc=1 secretkey=old dbset=new inflight=0" ]] || fail_ "settings: the database refuses the new password: nothing changed: $(as no yes yes)"; pass
[[ "$(as ok yes yes)" == "rc=0 secretkey=new dbset=new inflight=0" ]] || fail_ "settings: proven: all new: $(as ok yes yes)"; pass
[[ "$(as ok no yes)" == "rc=1 secretkey=old dbset=new,old inflight=0" ]] || fail_ "settings: not proven: the database and .env back on the old: $(as ok no yes)"; pass
[[ "$(as ok no no)" == "rc=2 secretkey=old dbset=new,old inflight=5" ]] || fail_ "settings: neither proven: stuck, all five held: $(as ok no no)"; pass

ss() { # ss LEFT(none|one) -> "rc=N deletes=N"
    ( rm -f "$T/c"; ak_api() { case "$1" in
          GET) if [[ -f "$T/c" && "$LEFT" == one ]]; then echo '{"results":[{"uuid":"s1"}]}'
               elif [[ -f "$T/c" ]]; then echo '{"results":[{"uuid":"s9"}]}'
               else echo '{"results":[{"uuid":"s1"},{"uuid":"s2"}]}'; fi ;;
          DELETE) echo "$2" >> "$T/c" ;;
      esac; }
      LEFT=$1; rc=0; portal_sessions_secret_rotate >/dev/null 2>&1 || rc=$?; echo "rc=$rc deletes=$(wc -l < "$T/c")" )
}
[[ "$(ss none)" == "rc=0 deletes=2" ]] || fail_ "sessions: every one ended (one opened since is not ours to fail on): $(ss none)"; pass
[[ "$(ss one)" == "rc=1 deletes=2" ]] || fail_ "sessions: one still there after its delete: a failure: $(ss one)"; pass

# the database's password check goes where a password is asked (found live: loopback is trusted, any password passes)
r=$(declare -f ak_db_password_opens)
[[ "$r" != *127.0.0.1* && "$r" != *localhost* && "$r" != *"::1"* && "$r" == *'svc_cname authentik-db'* ]] \
    || fail_ "the password is proven over the stack network, never loopback"; pass
r=$( ( svc_cname() { echo mediastack-authentik-db; }
       sudo() { cat >/dev/null; echo "$*" > "$T/c"; echo 1; }; ak_db_password_opens pw >/dev/null; cat "$T/c" ) )
[[ "$r" != *pw* && "$r" == *" mediastack-authentik-db" ]] || fail_ "the password goes on stdin, never the command line; the host is its container name: $r"; pass

# the stack's own logins are set-credentials' job: the end names them, with the command
r=$(logins_list() { printf 'x\tU\tP\n'; }; env_get() { :; }; rotate_box_lines search)
[[ "$r" == *"the stack's own logins"*"set-credentials <target|all>"* ]] || fail_ "logins on this install: named under Not rotated, with the command: $r"; pass
r=$(logins_list() { :; }; env_get() { :; }; rotate_box_lines search)
[[ "$r" != *"stack's own logins"* ]] || fail_ "no logins: no line about them: $r"; pass

echo "OK rotate: $checks checks"
