#!/usr/bin/env bash
# test-questions.sh — the questionnaire (lib/questionnaire.sh) asks and
# records, and does nothing else (docs/design-install.md):
#   * whole runs, quick and full, with sudo, docker, useradd, groupadd,
#     systemctl, rsync and mount on PATH as shims that log and fail: none is
#     called, and nothing but .env and local/state is written
#   * quick asks only what has no recommended answer; Enter through a full
#     run gives what quick takes; quick on a configured stack asks nothing and
#     keeps a schedule set to never
#   * with the portal: email is left as it is, the panel is recorded for
#     configure to install
#   * its source names no sudo, Docker, users or folders
#   * exit codes: 3 without a terminal; configure stops on 130 (Ctrl-C reaches
#     both processes and configure survives to say so), passes 3 on, and stops
#     on anything else
#   * configure applies the folders: made, recorded with their mount, a move
#     done as answered, contents it never saw asked about again
# The entrypoint is sourced (minus main "$@"); the rendered catalogue is a
# small fixture, so no Docker is needed.
#
#   scripts/test-questions.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
lib=$(mktemp .test-questions.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"
set +e +E; trap - ERR   # each check reads its own status

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; [[ -f "$T/out" ]] && { echo "--- output:" >&2; cat "$T/out" >&2; }; exit 1; }

# what the questionnaire may not run: each logs its call and fails
mkdir -p "$T/bin"
for c in sudo docker useradd groupadd systemctl rsync mount; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\nexit 1\n' "$c" "$T" > "$T/bin/$c"; chmod +x "$T/bin/$c"
done
SHIMS=$T/bin:$PATH

render() { :; }
curl() { cat >/dev/null; echo '{"nordlynx_private_key":"KEY"}'; }   # NordVPN's API
# shellcheck disable=SC2034  # read by the sourced entrypoint's svc_* helpers
RENDERED_JSON='{"services":{
  "gluetun":     {"labels":{"mediastack.managed":"true","mediastack.desc":"VPN"}},
  "qbittorrent": {"labels":{"mediastack.managed":"true","mediastack.desc":"torrents"},"depends_on":{"gluetun":{}}},
  "deluge":      {"labels":{"mediastack.managed":"true","mediastack.desc":"torrents"},"depends_on":{"gluetun":{}}},
  "olivetin":    {"labels":{"mediastack.managed":"true","mediastack.desc":"web panel","mediastack.installer":"frontdoor-install"}},
  "sonarr":      {"labels":{"mediastack.managed":"true","mediastack.desc":"series"}},
  "radarr":      {"labels":{"mediastack.managed":"true","mediastack.desc":"films"}},
  "prowlarr":    {"labels":{"mediastack.managed":"true","mediastack.desc":"indexers"}},
  "jellyfin":    {"labels":{"mediastack.managed":"true","mediastack.desc":"media"}},
  "meilisearch": {"labels":{"mediastack.managed":"true","mediastack.desc":"index"}},
  "jellysearch": {"labels":{"mediastack.managed":"true","mediastack.desc":"search"},"depends_on":{"meilisearch":{}}},
  "seerr":       {"labels":{"mediastack.managed":"true","mediastack.desc":"requests"}},
  "traefik":     {"labels":{"mediastack.managed":"true","mediastack.desc":"https","mediastack.conflicts":"npm"}},
  "npm":         {"labels":{"mediastack.managed":"true","mediastack.desc":"gui proxy","mediastack.conflicts":"traefik"}},
  "authentik":   {"labels":{"mediastack.managed":"true","mediastack.desc":"portal","mediastack.conflicts":"wizarr"}},
  "wizarr":      {"labels":{"mediastack.managed":"true","mediastack.desc":"invites","mediastack.conflicts":"authentik"}}}}'
STD=gluetun,jellyfin,jellysearch,meilisearch,prowlarr,qbittorrent,radarr,seerr,sonarr

# run STDIN [--fresh] — a whole questionnaire in its own directory: .env (a
# fresh one from .env.example unless one is there), local/state, the shims
run() {
    [[ -f "$T/w/.env" ]] || { mkdir -p "$T/w"; cp .env.example "$T/w/.env"; }
    : > "$T/calls"
    # shellcheck disable=SC2034  # read by the questionnaire
    ( ENV_FILE=$T/w/.env STATE_DIR=$T/w/local/state LOCAL_DIR=$T/w/local FSTAB=$T/fstab PATH=$SHIMS
      printf '%b' "$1" | questionnaire_run "${@:2}" ) > "$T/out" 2>&1
}
envv() { ENV_FILE=$T/w/.env env_get "$1"; }
clean() { rm -rf "$T/w"; }
written() { (cd "$T/w" && find . -type f | sort | tr '\n' ' '); }
: > "$T/fstab"

# ---- quick, fresh: the services, sign-in and the VPN — nothing else ----
clean; run '1\n1\n1\n\nTOKEN\n' --fresh || fail_ "quick on a fresh .env runs"
[[ ! -s "$T/calls" ]] || fail_ "quick ran what it may not: $(cat "$T/calls")"; pass
[[ "$(written)" == "./.env ./local/state/roots " ]] || fail_ "only .env and local/state are written: $(written)"; pass
[[ "$(envv COMPOSE_PROFILES | tr ',' '\n' | sort | paste -sd, -)" == "$STD" ]] || fail_ "standard: $(envv COMPOSE_PROFILES)"; pass
[[ "$(envv WIREGUARD_PRIVATE_KEY)" == KEY && "$(envv VPN_PROVIDER)" == nordvpn ]] || fail_ "the VPN key fetched"; pass
[[ "$(envv UPDATE_SCHEDULE)" == "Tue 04:00" && "$(envv BACKUP_SCHEDULE)" == "*-*-* 05:00" ]] \
    || fail_ "the recommended schedules: $(envv UPDATE_SCHEDULE) / $(envv BACKUP_SCHEDULE)"; pass
grep -q 'Timezone: .* (recommended)' "$T/out" && grep -q 'Updates: .* (recommended)' "$T/out" \
    || fail_ "what quick took is said"; pass
[[ "$(grep -c "^[A-Z_]*_ROOT	$SCRIPT_DIR/[a-z]*	$" "$T/w/local/state/roots")" == 5 ]] \
    || fail_ "every folder recorded for configure, none in .env yet: $(cat "$T/w/local/state/roots")"; pass
grep -qx 'CONFIG_ROOT=./config' "$T/w/.env" || fail_ "a folder answer is not written to .env by the questions"; pass
quick_env=$(grep -vE '^(MEILI_MASTER_KEY)=' "$T/w/.env")

# ---- full, fresh: Enter through every question gives what quick takes ----
clean; run '2\n\n\n\n\n\n\n1\n1\n\nTOKEN\n\n\n\n\n\n\n\n' --fresh || fail_ "full on a fresh .env runs"
[[ ! -s "$T/calls" ]] || fail_ "full ran what it may not: $(cat "$T/calls")"; pass
[[ "$(grep -vE '^(MEILI_MASTER_KEY)=' "$T/w/.env")" == "$quick_env" ]] \
    || fail_ "Enter through full = quick: $(diff <(echo "$quick_env") <(grep -vE '^MEILI_MASTER_KEY=' "$T/w/.env"))"; pass

# ---- quick on a configured stack: nothing asked, a "never" kept ----
sed -i 's/^UPDATE_SCHEDULE=.*/UPDATE_SCHEDULE=/' "$T/w/.env"; before=$(cat "$T/w/.env")
run '1\n' || fail_ "quick re-run asks nothing beyond the mode"
[[ "$(cat "$T/w/.env")" == "$before" ]] || fail_ "quick re-run changes nothing: $(diff <(echo "$before") "$T/w/.env")"; pass
grep -q 'Services: keep the current' "$T/out" && grep -q 'VPN: keep nordvpn' "$T/out" || fail_ "and says what it kept"; pass

# ---- quick with the portal: email left alone, the panel recorded ----
clean; run '1\n2\n3\n\nTOKEN\n' --fresh || fail_ "quick, everything, the portal runs"
[[ ! -s "$T/calls" ]] || fail_ "ran what it may not: $(cat "$T/calls")"; pass
[[ ",$(envv COMPOSE_PROFILES)," == *,traefik,* && ",$(envv COMPOSE_PROFILES)," == *,authentik,* && ",$(envv COMPOSE_PROFILES)," != *,npm,* \
   && ",$(envv COMPOSE_PROFILES)," != *,deluge,* ]] || fail_ "one client, traefik for the portal: $(envv COMPOSE_PROFILES)"; pass
[[ "$(cat "$T/w/local/state/$PANEL_STATE")" == yes && -z "$(envv SMTP_HOST)" ]] && grep -q 'Email: not set' "$T/out" \
    || fail_ "the panel recorded, email left as it is"; pass
[[ "$(envv PORTAL_TITLE)" == Mediastack ]] || fail_ "the portal's name taken: $(envv PORTAL_TITLE)"; pass

# ---- its source names no sudo, Docker, users or folders ----
# a command where a command goes (a line's start, after ; & | ( or $( ); the one
# prose line that starts with one is root_problem's advice to mount a share
bad=$(grep -nE '(^|[;&|(]|\$\()[[:space:]]*(sudo|DC|docker|useradd|groupadd|chown|chmod|mkdir|rsync|provision|cmd_[a-z_]+_install)\b' lib/questionnaire.sh \
      | grep -vF "sudo mount '\$val'   (then re-enter the path here)" || true)
[[ -z "$bad" ]] || fail_ "the questionnaire acts instead of asking: $bad"; pass

# ---- exit codes ----
( cmd_questionnaire ) </dev/null > "$T/out" 2>&1; rc=$?
[[ "$rc" == 3 ]] && grep -q 'configure asks questions — run it in a terminal' "$T/out" || fail_ "no terminal: exit 3 ($rc)"; pass
mkdir -p "$T/fake"
child() { printf '#!/usr/bin/env bash\n%s\n' "$1" > "$T/fake/mediastack.sh"; chmod +x "$T/fake/mediastack.sh"; }
asked() { setsid -w bash -c 'source "$1"; set +e +E; trap - ERR; SCRIPT_DIR=$2; questionnaire_ask; echo CONTINUED' _ "$lib" "$T/fake" > "$T/out" 2>&1; }
child 'kill -INT 0; sleep 2'   # Ctrl-C: the whole process group, configure included
asked; rc=$?
[[ "$rc" == 130 ]] && grep -q 'Cancelled — nothing was applied' "$T/out" && ! grep -q CONTINUED "$T/out" \
    || fail_ "Ctrl-C: configure survives to say so, then stops with 130 ($rc)"; pass
child 'exit 3'; asked; rc=$?
[[ "$rc" == 3 ]] && ! grep -q CONTINUED "$T/out" || fail_ "no terminal: configure stops with 3 ($rc)"; pass
child 'exit 1'; asked; rc=$?
[[ "$rc" == 1 ]] && grep -q 'the questions stopped (exit 1, above) — nothing was applied' "$T/out" && ! grep -q CONTINUED "$T/out" \
    || fail_ "a failed question: configure stops ($rc)"; pass
child 'exit 0'; asked; rc=$?
[[ "$rc" == 0 ]] && grep -q CONTINUED "$T/out" || fail_ "every question answered: configure carries on ($rc)"; pass

# ---- configure applies the folders ----
sudo() { "$@"; }   # as this user, on the test's folders
# shellcheck disable=SC2034  # read by root_move_apply
c_inspect_all() { INSPECT_JSON='[]'; }
mkdir -p "$T/a/old" "$T/a/keep"; echo x > "$T/a/old/file"; echo y > "$T/a/keep/file"
# shellcheck disable=SC2034  # read by state_set and roots_apply
apply() { ( ENV_FILE=$T/a/.env STATE_DIR=$T/a/state LOCAL_DIR=$T/a; state_set "$ROOTS_STATE" "$1"; roots_apply ) > "$T/out" 2>&1; }
printf 'CONFIG_ROOT=%s\nCACHE_ROOT=%s\n' "$T/a/old" "$T/a/keep" > "$T/a/.env"
apply "CONFIG_ROOT	$T/a/new	move" || fail_ "a move applies"
[[ -f "$T/a/new/file" && ! -e "$T/a/old/file" ]] && grep -qx "CONFIG_ROOT=$T/a/new" "$T/a/.env" && grep -q '^CONFIG_ROOT_SOURCE=.' "$T/a/.env" \
    || fail_ "moved, recorded with its mount: $(cat "$T/a/.env")"; pass
[[ ! -e "$T/a/state/$ROOTS_STATE" ]] || fail_ "the answers are gone once applied"; pass
apply "CACHE_ROOT	$T/a/other	" && fail_ "contents the questions never saw stop configure"
grep -qx "CACHE_ROOT=$T/a/keep" "$T/a/.env" && grep -q 'configure did not see when it asked' "$T/out" \
    || fail_ "and leave that folder as it was: $(cat "$T/a/.env")"; pass
apply "CACHE_ROOT	$T/a/other	leave" || fail_ "leave applies"
grep -qx "CACHE_ROOT=$T/a/other" "$T/a/.env" && grep -qx "CACHE_ROOT_PREVIOUS=$T/a/keep" "$T/a/.env" && [[ -f "$T/a/keep/file" ]] \
    || fail_ "leave: the new folder, the old one noted for doctor: $(cat "$T/a/.env")"; pass

echo "OK questions: $checks checks"
