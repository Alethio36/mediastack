#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-credentials.sh — `credentials` and `set-credentials` are made from the
# logins the services declare (lib/access.sh), not from a list of them:
#   * the targets are every <stem>_logins line's (target=, else the stem) —
#     exactly the ones the hand-kept list had — and the usage names each
#   * a target with ask_user asks the username and passes it first; others
#     the password alone; its own explanation, when it has one, first
#   * `all` rotates every enabled login that is set up, usernames kept, and
#     skips one not set up yet
#   * `credentials` prints each enabled service's logins once (a shared one
#     once) and its own note, and nothing of a service that is off
# Renders the real catalogue from .env.example in a scratch copy of the repo;
# every rotation and question is a stub.
#
#   scripts/test-credentials.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
repo=$PWD
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
git -C "$repo" ls-files -z | (cd "$repo" && xargs -0 cp --parents -t "$work")
cd "$work"
cp .env.example .env
sed '$d' mediastack.sh > .test-credentials-lib.sh
# shellcheck disable=SC1091
source ./.test-credentials-lib.sh
set +E; trap - ERR
vpn_gen >/dev/null

checks=0
# strict CMD... — run it as a real run does, under set -e (a test's $( ) drops -e, and an
# `if`/`||` around it too): SR its status, its output in $work/strict
strict() { set +e; ( set -e; "$@" ) > "$work/strict" 2>&1; SR=$?; set -e; }
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }
profiles() { env_set COMPOSE_PROFILES "$1"; RENDERED_JSON=""; render; }

# ---- the targets: every declared login, exactly what the hand-kept list had ----
profiles gluetun
got=$(sc_lines | cut -f1 | sort | paste -sd' ')
[[ "$got" == "arr audiobookshelf deluge dispatcharr jellyfin kavita navidrome panel pihole qbit traefik transmission" ]] \
    || fail_ "the catalogue's targets: $got"; pass
strict cmd_set_credentials; u=$(cat "$work/strict")
[[ $SR == 0 && "$u" != *ERROR* ]] || fail_ "set-credentials asked bare: the list, not an error (rc $SR): $u"; pass
strict cmd_set_credentials nosuch
[[ $SR != 0 ]] && grep -q "no login named 'nosuch'" "$work/strict" || fail_ "an unknown target: an error naming it: $(cat "$work/strict")"; pass
strict sc_usage; u=$(cat "$work/strict")
[[ $SR == 0 ]] || fail_ "usage, under set -e: rc $SR: $u"
for t in $got portal all; do grep -qE "^  $t +" <<<"$u" || fail_ "usage names $t: $u"; done; pass
[[ "$(sc_lines | awk -F'\t' '$1 == "arr"' | wc -l)" == 1 ]] || fail_ "the arrs' shared login is one target, once"; pass

# ---- one target: its explanation, its question(s), its own rotation ----
REC=$work/rec
for t in $got; do eval "sc_rotate_$t() { echo \"$t \$*\" >> \"$REC\"; }"; done
login_pass_ask() { REPLY_VAL=Newpass123456; }
ask() { REPLY_VAL=${ASKED:-$3}; }
explain() { echo "EXPLAIN $1" >> "$REC"; }
one() { : > "$REC"; local l; l=$(sc_lines | awk -F'\t' -v t="$1" '$1 == t { sub(/^[^\t]*\t/, ""); print }'); strict sc_one "$1" "$l"; [[ $SR == 0 ]] || echo "rc $SR: $(cat "$work/strict")"; paste -sd'|' "$REC"; }
env_set ARR_USER ops
[[ "$(one arr)" == "EXPLAIN Rotate the arrs (one login for every one of them)|arr ops Newpass123456" ]] || fail_ "arr: explained, its username asked (current offered), then both: $(one arr)"; pass
[[ "$(ASKED=newname one qbit)" == "EXPLAIN Rotate qBittorrent's WebUI|qbit newname Newpass123456" ]] || fail_ "qbit: target=qbit, its username asked: $(ASKED=newname one qbit)"; pass
[[ "$(one pihole)" == "pihole Newpass123456" ]] || fail_ "no explanation, no username: the password alone: $(one pihole)"; pass
[[ "$(one panel)" == "EXPLAIN Rotate the web panel's admin|panel Newpass123456" ]] || fail_ "panel: the panel's login, target=panel: $(one panel)"; pass

# ---- all: every enabled login that is set up, usernames kept ----
profiles gluetun,qbittorrent,sonarr,prowlarr,jellyfin,kavita,dispatcharr
env_set ARR_PASSWORD x; env_set QBITTORRENT_USER qb; env_set QBITTORRENT_PASSWORD x; env_set JELLYFIN_ADMIN_PASSWORD x
env_set KAVITA_ADMIN_PASSWORD ""; env_set DISPATCHARR_ADMIN_PASSWORD x
: > "$REC"; strict sc_all; out=$(cat "$work/strict")
[[ $SR == 0 ]] || fail_ "all, under set -e: rc $SR: $out"
got=$(grep -v EXPLAIN "$REC" | sort | paste -sd'|')
[[ "$got" == "arr ops Newpass123456|dispatcharr Newpass123456|jellyfin Newpass123456|qbit qb Newpass123456" ]] || fail_ "all: the enabled ones that are set up, usernames kept: $got"; pass
grep -q "Kavita's admin: not set up yet — skipped" <<<"$out" || fail_ "all: one not set up is said and skipped: $out"; pass
grep -q '^EXPLAIN One password across the stack' "$REC" || fail_ "all: explained first"; pass

# ---- credentials: one block per service — its logins once, then its own lines ----
env_set ARR_PASSWORD arrpw; env_set KAVITA_ADMIN_USER admin; env_set KAVITA_ADMIN_PASSWORD kpw
signin_is() { [[ "$1" == none ]]; }
# watchstate last: the last enabled service shares no login (live, 25 Nov 2026: the shared login's
# heading died there — a loop ending in a false test)
profiles gluetun,qbittorrent,sonarr,prowlarr,jellyfin,kavita,dispatcharr,seerr,watchstate
[[ "$(svc_enabled_managed | tail -n 1)" == watchstate ]] || fail_ "the profile's last service is one with no shared login"
strict cmd_credentials; out=$(cat "$work/strict")
[[ $SR == 0 ]] || fail_ "credentials, under set -e: rc $SR: $out"
[[ "$(grep -c 'the arrs (one login for every one of them)$' <<<"$out")" == 1 ]] && grep -qx 'arr (prowlarr, sonarr)' <<<"$out" \
    || fail_ "the arrs' login once, headed by its name and the services that share it: $out"; pass
grep -A3 "^kavita$" <<<"$out" | grep -E '^  password +kpw$' >/dev/null || fail_ "a login's password in its service's block: $out"; pass
grep -A3 "^dispatcharr$" <<<"$out" | grep -E "^  login +Dispatcharr's admin$" >/dev/null || fail_ "a block: its service's name, then what the login is: $out"; pass
awk '/^seerr$/ { f = 1; next } f && /^[^ ]/ { f = 0 } f' <<<"$out" | grep -E "^  · its owner is Jellyfin's admin" >/dev/null || fail_ "a service with no login: its name heads its block, its notes in it: $out"; pass
! grep -E '^::' <<<"$out" | grep -v 'Not shown\|Give an app' >/dev/null || fail_ "no note floats loose (each sits in its block): $out"; pass
! grep -q "Navidrome's admin\|Pi-hole" <<<"$out" || fail_ "nothing of a service that is off: $out"; pass
grep -q '^:: Not shown: the secrets only the stack uses, and your own' <<<"$out" && grep -q 'credentials <service>' <<<"$out" && grep -q 'credentials --all' <<<"$out" \
    || fail_ "credentials says what it leaves out, and how to see it: $out"; pass
! grep -q '── Keys for your apps' <<<"$out" || fail_ "no table of keys: each key sits in its service's block: $out"; pass
awk 'NR > 2 && /^[a-z(]/ && prev != "" { bad = 1 } { prev = $0 } END { exit bad }' <<<"$out" && [[ "$(sed -n 2p <<<"$out")" != "" ]] \
    || fail_ "a blank line between services, none before the first: $out"; pass
# keys for your apps: each service's <name>_api_key, an arr instance's through its type label — in its own block, with its address
arr_key() { echo "key-$1"; }; bazarr_key() { echo key-bazarr; }; env_set SEERR_API_KEY key-seerr; env_set JELLYFIN_API_KEY key-jf
profiles gluetun,sonarr,radarr-4k,prowlarr,bazarr,seerr,jellyfin,kavita
strict cmd_credentials; out=$(cat "$work/strict")
[[ $SR == 0 ]] || fail_ "credentials with keys, under set -e: rc $SR: $out"
k=$(awk '/^[a-z0-9-]+$/ { b = $1 } /^  API key / { print b "=" $3 }' <<<"$out" | sort | paste -sd' ')
[[ "$k" == "bazarr=key-bazarr jellyfin=key-jf prowlarr=key-prowlarr radarr-4k=key-radarr-4k seerr=key-seerr sonarr=key-sonarr" ]] || fail_ "each key in its own service's block, from the hooks and the arr type label: $k"; pass
grep -A1 -E '^  API key +key-sonarr$' <<<"$out" | grep -E '^  address +https?://' >/dev/null || fail_ "a key, then its address: $out"; pass
! awk '/^kavita$/,/^[a-z]/' <<<"$out" | grep 'API key' >/dev/null || fail_ "a service with neither a hook nor an arr type: no key row: $out"; pass
! awk 'prev ~ /^[a-z(]/ && $0 !~ /^  / { bad = 1 } { prev = $0 } END { if (prev ~ /^[a-z(]/) bad = 1; exit !bad }' <<<"$(grep -v '^::' <<<"$out" | grep -v '^──')" \
    || fail_ "no heading without a block under it (gluetun holds nothing here): $out"; pass
grep -A3 -x 'seerr' <<<"$out" | sed -n 2p | grep -E '^  API key' >/dev/null || fail_ "rows first, then notes: $out"; pass
grep -qx 'arr (bazarr, prowlarr, radarr-4k, sonarr)' <<<"$out" && grep -A2 -x 'sonarr' <<<"$out" | grep -E '^  API key' >/dev/null \
    || fail_ "the shared login its own block; each arr's key under its own name: $out"; pass
# notes wrap at word boundaries to the terminal's width — values never
CRED_WIDTH=40; w=$(credentials_lines $'url\thttps://a-very-long-address.example.com/with/a/path?and=query\none two three four five six seven eight nine ten eleven twelve')
[[ "$(sed -n 1p <<<"$w")" == "  url        https://a-very-long-address.example.com/with/a/path?and=query" ]] || fail_ "a value is never wrapped: $w"; pass
awk 'NR > 1 && length($0) > 40 { exit 1 }' <<<"$w" && [[ "$(sed -n 3p <<<"$w")" == "    "* ]] && ! grep -qE '[a-z]-$' <<<"$w" || fail_ "a note wraps at words, within the width, indented: $w"; pass
CRED_WIDTH=0; [[ "$(credentials_lines 'one two three' | wc -l)" == 1 ]] || fail_ "no width (a pipe, a file): never wrapped"; pass
unset CRED_WIDTH
profiles gluetun,qbittorrent,sonarr,prowlarr,jellyfin,kavita,dispatcharr
env_set DISPATCHARR_ADMIN_PASSWORD ""
grep -A3 "^dispatcharr$" <<<"$(cmd_credentials 2>&1)" | grep -E '^  password +\(not recorded yet' >/dev/null || fail_ "a login not recorded says what records it"; pass

# ---- credentials <service>: everything it holds, each secret once, whose it is ----
env_set AUTHENTIK_ADMIN_PASSWORD akpw; env_set AUTHENTIK_DB_PASSWORD dbpw; env_set SMTP_PASSWORD smtppw; env_set AUTHENTIK_LDAP_TOKEN ""
strict cmd_credentials authentik; out=$(cat "$work/strict")
[[ $SR == 0 ]] || fail_ "credentials authentik, under set -e: rc $SR: $out"
[[ "$(grep -c 'akpw' <<<"$out")" == 1 ]] || fail_ "the portal admin's password once (its row), not again as a setting: $out"; pass
owner() { awk -v k="$1" '/^  the stack.s own — rotate-secrets changes these/ { g = "own" } /^  yours, as you gave them:/ { g = "yours" } $1 == k { print g }' <<<"$2"; }
[[ "$(owner AUTHENTIK_DB_PASSWORD "$out")" == own && "$(owner SMTP_PASSWORD "$out")" == yours ]] || fail_ "each secret under whose it is — the stack's own, or yours: $out"; pass
[[ "$(grep -c "rotate-secrets changes these" <<<"$out")" == 1 ]] || fail_ "whose they are: said once for the group, not under each: $out"; pass
! grep -q 'AUTHENTIK_LDAP_TOKEN' <<<"$out" || fail_ "a secret not set: not listed: $out"; pass
env_set WIREGUARD_PRIVATE_KEY wgkey; env_set GLUETUN_CONTROL_APIKEY ctlkey
out=$(cmd_credentials gluetun 2>&1)
grep -A2 '^    GLUETUN_CONTROL_APIKEY$' <<<"$out" | grep 'closed' >/dev/null && [[ "$(owner WIREGUARD_PRIVATE_KEY "$out")" == yours && "$(owner GLUETUN_CONTROL_APIKEY "$out")" == own ]] \
    || fail_ "gluetun: its control key with why no app can use it, your VPN key as yours: $out"; pass
out=$(cmd_credentials jellyfin 2>&1)
[[ "$(grep -c 'key-jf' <<<"$out")" == 1 ]] && grep -qE '^  API key +key-jf$' <<<"$out" || fail_ "jellyfin: its key once, as its key for your apps: $out"; pass
grep -A1 -E '^  API key ' <<<"$out" | grep -E '^  address +https?://' >/dev/null || fail_ "its key, then its address as a row of its own (an app asks for both): $out"; pass
strict cmd_credentials nosuch
[[ $SR != 0 ]] && grep -q "no service named 'nosuch'" "$work/strict" || fail_ "an unknown service: an error naming it: $(cat "$work/strict")"; pass
profiles gluetun,qbittorrent,sonarr,radarr,prowlarr,jellyfin,kavita,dispatcharr,flaresolverr
env_set ARR_USER admin
strict cmd_credentials --all; out=$(cat "$work/strict")
[[ $SR == 0 ]] || fail_ "--all, under set -e: rc $SR: $out"
for s in gluetun jellyfin kavita dispatcharr; do grep -qE "── $s ─" <<<"$out" || fail_ "--all: $s's section: $out"; done; pass
! grep -A1 -E '^── [a-z0-9-]+ ─' <<<"$out" | grep -xE '[a-z0-9][a-z0-9-]*' >/dev/null || fail_ "--all: a section names its service once (its heading), not again under it: $out"; pass
! grep -q '── flaresolverr' <<<"$out" || fail_ "--all: a service holding nothing is left out: $out"; pass
awk 'NR > 1 && /^── / && prev != "" { bad = 1 } { prev = $0 } END { exit bad }' <<<"$out" && [[ "$(sed -n 1p <<<"$out")" == "── "* ]] \
    || fail_ "--all: a blank line between sections, none before the first: $out"; pass
[[ "$(grep -c '^  user ' <<<"$(awk '/── (prowlarr|radarr|sonarr) ─/,0' <<<"$out")")" -ge 1 && "$(grep -c 'the arrs (one login for every one of them) — shown under prowlarr' <<<"$out")" == 2 ]] \
    || fail_ "--all: the arrs' login in full once (prowlarr's), the others point at it: $out"; pass
out=$(cmd_credentials flaresolverr 2>&1)
grep -q 'the stack keeps no login, key or secret for it' <<<"$out" || fail_ "a service asked for by name that holds nothing: said so: $out"; pass

# ---- the core names no app for them, companion keys included (docs/design-install.md: each piece lands with this test) ----
cd "$repo"
apps=$(for d in services/*/; do d=${d%/}; d=${d#services/}; [[ "$d" =~ ^(_arr|gluetun|traefik|authentik|apprise)$ ]] || echo "$d"; done | paste -sd'|')   # the platform services may be named
code=$(awk '/^# ---- the stack.s own logins/,/^cmd_reset_password\(\)/' lib/access.sh | grep -v '^[[:space:]]*#')
hits=$(grep -nwE "$apps" <<<"$code" || true)   # none: the point
[[ -z "$hits" ]] || fail_ "credentials / set-credentials name an app: $hits"; pass
[[ "$(wc -l <<<"$code")" -gt 50 ]] || fail_ "the section was read"; pass

echo "OK credentials: $checks checks"
