#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-gate.sh — the leak gate (services/gluetun/gate.sh):
#   * the VPN group: enabled services in gluetun's namespace, nothing else
#   * the chokepoint: while closed, a start of the whole stack or of anything
#     in gluetun's namespace (recyclarr too, never enabled) is refused through
#     DC; stops, other services and reads pass
#   * a verdict acted on: a FAIL closes the gate and stops the running group;
#     ops hears each change once (a leak, an unproven check, the recovery)
#   * up's gate: a pass or an unproven opens it, a FAIL keeps it closed and ends up
#   * wire and trash-sync, refused for a group member the gate holds, name the gate
#   * up's two phases: everything but the group, the gate, then the group — and
#     no second phase when the gate fails
# Sources the real entrypoint (minus its last line, main "$@"); docker and
# the leak-test itself are stubs.
#
#   scripts/test-gate.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-gate.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"
set +e +E; trap - ERR   # each check reads its own status

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

LOCAL_DIR="$T/local"; STATE_DIR="$LOCAL_DIR/state"
repo_owned() { :; }
ENABLED="gluetun qbittorrent sonarr jellyfin"
svc_enabled() { [[ " $ENABLED " == *" $1 "* ]]; }
svc_cname()   { echo "mediastack-$1"; }
RENDERED_JSON='{"services":{
  "gluetun":{},"jellyfin":{},
  "qbittorrent":{"network_mode":"service:gluetun"},"sonarr":{"network_mode":"service:gluetun"},
  "radarr":{"network_mode":"service:gluetun"},"recyclarr":{"network_mode":"service:gluetun"}}}'

# ---- the group ----
[[ "$(vpn_group | paste -sd' ')" == "qbittorrent sonarr" ]] || fail_ "the group: enabled, in gluetun's namespace ($(vpn_group | paste -sd' '))"; pass

# ---- the chokepoint ----
leak_gate_guards up -d --remove-orphans || fail_ "gate open: anything starts"; pass
state_set "$LEAK_GATE" "2026-11-02 20:00:00: traffic past the tunnel"
leak_gate_guards up -d --remove-orphans && fail_ "closed: the whole stack is refused (the group is in it)"; pass
leak_gate_guards up -d --force-recreate --no-deps sonarr && fail_ "closed: a group member is refused"; pass
leak_gate_guards restart qbittorrent && fail_ "closed: a restart of one is refused"; pass
leak_gate_guards run --rm --no-deps recyclarr sync && fail_ "closed: recyclarr in gluetun's namespace is refused, though its profile is never enabled (trash-sync)"; pass
leak_gate_guards up -d radarr && fail_ "closed: a disabled service in gluetun's namespace is refused too"; pass
leak_gate_guards run --rm jellyfin sonarr || fail_ "run: only the service counts, not its command words"; pass
leak_gate_guards up -d --remove-orphans gluetun jellyfin || fail_ "closed: services outside the group still start (up's first phase)"; pass
leak_gate_guards stop qbittorrent sonarr || fail_ "closed: stopping the group passes"; pass
leak_gate_guards ps || fail_ "closed: reads pass"; pass
COMPOSE_LOG="$T/compose"
sudo() { [[ "$1 $2" == "docker compose" ]] && echo "${*:3}" >> "$COMPOSE_LOG"; return 0; }
user_compose_files() { USER_FILES=(); }
stack_down_since() { :; }
out=$( (DC up -d qbittorrent) 2>&1 ); rc=$?
(( rc != 0 )) && [[ "$out" == *"the leak gate stopped the VPN group (2026-11-02 20:00:00: traffic past the tunnel)"* && "$out" == *"./mediastack.sh up"* ]] \
    || fail_ "DC refuses a group member with the reason and the way out (rc $rc) — $out"; pass
[[ ! -s "$COMPOSE_LOG" ]] || fail_ "and compose was never called"; pass
(DC stop qbittorrent) >/dev/null 2>&1 && grep -q "stop qbittorrent" "$COMPOSE_LOG" || fail_ "DC passes a stop through"; pass
out=$( (leak_gate_refuse "restarting qBittorrent") 2>&1 ); rc=$?
(( rc != 0 )) && [[ "$out" == "ERROR restarting qBittorrent: the leak gate stopped"* ]] || fail_ "a raw docker start refuses itself — $out"; pass
state_del "$LEAK_GATE"
(leak_gate_refuse "restarting qBittorrent") || fail_ "gate open: a raw start goes ahead"; pass

# ---- a verdict acted on ----
NOTES="$T/notes"
notify() { echo "$1|$2|$4" >> "$NOTES"; printf '%s\n--\n' "$3" >> "$T/bodies"; }
RUNNING="qbittorrent"
c_state() { [[ " $RUNNING " == *" ${1#mediastack-} "* ]] && echo running || echo exited; }
: > "$COMPOSE_LOG"
LT_FIRST="traffic: gluetun's address is talking past the tunnel — udp 192.168.69.1:53"
leak_verdict 1 > "$T/out" 2>&1
leak_gate_closed || fail_ "a FAIL closes the gate"; pass
[[ "$(state_get "$LEAK_GATE")" == *": traffic: gluetun's address is talking past the tunnel — udp 192.168.69.1:53" ]] || fail_ "and remembers why ($(state_get "$LEAK_GATE"))"; pass
grep -q " stop qbittorrent$" "$COMPOSE_LOG" || fail_ "the running group member is stopped ($(cat "$COMPOSE_LOG"))"; pass
grep -q "gluetun" "$COMPOSE_LOG" && fail_ "gluetun is never stopped by the gate"; pass
[[ "$(grep -c . "$NOTES")" == 1 ]] && grep -q "^ops|Mediastack VPN LEAK — downloads stopped|failure$" "$NOTES" || fail_ "ops hears the leak ($(cat "$NOTES"))"; pass
leak_verdict 1 > /dev/null 2>&1
[[ "$(grep -c . "$NOTES")" == 1 ]] || fail_ "the same leak next run: not heard again"; pass
leak_verdict 0 > /dev/null 2>&1
grep -q "pass again|success" "$NOTES" || fail_ "the recovery is heard"; pass
leak_gate_closed || fail_ "a pass does not re-open the gate: only up does"; pass
leak_verdict 0 > /dev/null 2>&1
[[ "$(grep -c . "$NOTES")" == 2 ]] || fail_ "pass after pass: nothing more"; pass
state_del "$LEAK_GATE"
LT_FIRST="tunnel address: Mullvad's checker did not answer"
leak_verdict 2 > /dev/null 2>&1; leak_verdict 2 > /dev/null 2>&1
[[ "$(grep -c "not everything proven|warning" "$NOTES")" == 1 ]] || fail_ "unproven: heard once, as a warning"; pass
leak_gate_closed && fail_ "unproven stops nothing"; pass

# ---- up's gate ----
GATE_RC=0
leak_test_run() { return "$GATE_RC"; }
state_set "$LEAK_GATE" "closed earlier"
(leak_gate_up) > /dev/null 2>&1 || fail_ "a pass: up goes on"; pass
leak_gate_closed && fail_ "a pass opens the gate"; pass
state_set "$LEAK_GATE" "closed earlier"; GATE_RC=2
out=$( (leak_gate_up) 2>&1 ) || fail_ "unproven: up goes on"; pass
leak_gate_closed && fail_ "unproven opens it"; pass
[[ "$out" == *"not everything was proven"* ]] || fail_ "with a warning — $out"; pass
state_set "$LEAK_GATE" "closed earlier"; GATE_RC=1
(leak_gate_up) > /dev/null 2>&1 && fail_ "a FAIL ends up"; pass
leak_gate_closed || fail_ "and the gate stays closed"; pass
# the recovery up itself proves (found live, Nov 2026): told as open, not "stay stopped until up"
state_set "$LEAK_VERDICT" 1; : > "$T/bodies"; GATE_RC=0
(leak_gate_up) > /dev/null 2>&1
grep -q "Every check proven" "$T/bodies" && ! grep -q "stay stopped" "$T/bodies" || fail_ "up's own pass: the recovery, not 'stay stopped until up' ($(cat "$T/bodies"))"; pass

# ---- wire and trash-sync name the gate ----
RUNNING="jellyfin"; ENABLED="gluetun qbittorrent sonarr jellyfin"
state_set "$LEAK_GATE" "2026-11-03 10:00:00: firewall lets traffic out"
out=$( (wire_gate sonarr jellyfin) 2>&1 ) && fail_ "a group member held by the gate: refused"; pass
[[ "$out" == *"Cannot wire: sonarr is in the VPN group: the leak gate stopped the VPN group (2026-11-03 10:00:00: firewall lets traffic out)"* ]] \
    || fail_ "names the gate, not 'start the stack' (found live, Nov 2026) — $out"; pass
state_del "$LEAK_GATE"
out=$( (wire_gate sonarr jellyfin) 2>&1 ) && fail_ "gate open, sonarr down: refused"; pass
[[ "$out" == *"Cannot wire: not running: sonarr"* ]] || fail_ "the plain reason when the gate is open — $out"; pass

# ---- up: two phases ----
UP_LOG="$T/up"
for f in load_env vpn_gen require_mounts reconcile_disabled require_free_ports frontdoor_require provision \
         uid_handover traefik_ensure authentik_prepare network_ensure vpnguard_ensure authentik_release_record \
         wire_repoint_pending prowlarr_indexers_retest; do eval "$f() { :; }"; done
svc_enabled_managed() { printf '%s\n' gluetun jellyfin qbittorrent sonarr; }
wait_verdict() { echo "wait $*" >> "$UP_LOG"; }
vpn_reattach_guard() { echo "guard" >> "$UP_LOG"; }
DC() { echo "DC $*" >> "$UP_LOG"; }
sudo() { :; }
leak_gate_up() { echo "gate" >> "$UP_LOG"; (( GATE_RC != 1 )) || exit 1; }
GATE_RC=0; : > "$UP_LOG"
(cmd_up) > /dev/null 2>&1 || fail_ "up runs through — $(cat "$UP_LOG")"; pass
[[ "$(paste -sd'|' "$UP_LOG")" == "DC up -d --remove-orphans gluetun jellyfin|wait --recover gluetun|gate|DC up -d --remove-orphans|guard" ]] \
    || fail_ "everything but the group, gluetun proven, then the group ($(paste -sd'|' "$UP_LOG"))"; pass
GATE_RC=1; : > "$UP_LOG"
(cmd_up) > /dev/null 2>&1 && fail_ "a FAIL at the gate ends up"; pass
[[ "$(paste -sd'|' "$UP_LOG")" == "DC up -d --remove-orphans gluetun jellyfin|wait --recover gluetun|gate" ]] \
    || fail_ "and the group is never started ($(paste -sd'|' "$UP_LOG"))"; pass
ENABLED="qbittorrent sonarr jellyfin"; : > "$UP_LOG"
out=$( (cmd_up) 2>&1 ) && fail_ "VPN'd services without gluetun: refused"; pass
[[ "$out" == *"but gluetun is not"* && ! -s "$UP_LOG" ]] || fail_ "before anything starts — $out"; pass
ENABLED="jellyfin"; : > "$UP_LOG"
(cmd_up) > /dev/null 2>&1 || fail_ "no VPN at all: up as before"; pass
[[ "$(paste -sd'|' "$UP_LOG")" == "DC up -d --remove-orphans|guard" ]] || fail_ "one phase, no gate ($(paste -sd'|' "$UP_LOG"))"; pass

# ---- the verb's arguments ----
out=$( (cmd_leak_test --bogus) 2>&1 ) && fail_ "an unknown argument: refused"; pass
[[ "$out" == *"usage: leak-test [--killswitch|--local]"* ]] || fail_ "with the usage — $out"; pass

echo "test-gate: $checks checks passed"
