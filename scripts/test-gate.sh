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
#   * which gluetun is proven: a restart (same container, new start) needs the full run again
#   * a gated start of members: closed -> held; proven -> local checks; else full; a FAIL starts nothing
#   * the supervisor (vpn-watch, every 5 min, and the boot): starts members not running through
#     the gate; skips while an update, backup or up holds the stack, or a backup is mid-copy
#   * a backup's restart: everything else, gluetun ready, then the group through the gate —
#     each as it was (--no-recreate): a pending change is update's to apply, with its proofs
#   * the gate's timers: local every 5 minutes; the full run hourly, at a random
#     minute; this host's own address daily, at a random time — and in the footprint
#   * update: gluetun unchanged -> the group's targets through the gate; changed ->
#     stopped, forgotten, recreated, ready, then the whole group; a held group fails it
#   * doctor during a gated stop: one finding; the held members are not each a problem
#   * enable starts its service through up (the gate), never with its own compose up
#   * restore --service (and so rollback) starts what it restored as update applies:
#     the VPN group through the gate, a restored gluetun as a changed one;
#     restore --all starts the whole stack as up does
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
# the group as long as the real one, written slowly: a `| grep -q` read dies of SIGPIPE under pipefail (found live, Nov 2026)
vpn_group() { local i; echo bazarr; echo sonarr; for i in $(seq 1 2000); do echo "member$i"; done; }
out=$( (wire_gate sonarr jellyfin) 2>&1 )
[[ "$out" == *"sonarr is in the VPN group"* ]] || fail_ "a member early in a long group is still found — $out"; pass
unset -f vpn_group; source services/gluetun/gate.sh
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

# ---- proven: which gluetun the last full run vouched for ----
ENABLED="gluetun qbittorrent sonarr jellyfin"
LEAK_LOG="$T/leak"
GSTART="2026-11-03T10:00:00Z"
c_id()  { echo gid1; }
c_get() { [[ "$2" == ".State.StartedAt" ]] && echo "$GSTART"; }
state_del "$LEAK_PROVEN"
gluetun_proven && fail_ "nothing proven yet"; pass
leak_proof_record; gluetun_proven || fail_ "the same gluetun: proven"; pass
GSTART="2026-11-03T11:00:00Z"
gluetun_proven && fail_ "gluetun restarted (same container, new start): no longer proven"; pass

# ---- a gated start of group members ----
leak_test_run() { echo "test local=$2" >> "$LEAK_LOG"; return "$GATE_RC"; }
DC() { echo "DC $*" >> "$UP_LOG"; }
vpn_reattach_guard() { echo "guard" >> "$UP_LOG"; }
NOTES="$T/notes2"; : > "$NOTES"
state_set "$LEAK_GATE" "closed earlier"; : > "$UP_LOG"; : > "$LEAK_LOG"
rc=0; vpn_start_group qbittorrent > /dev/null 2>&1 || rc=$?
(( rc == 3 )) && [[ ! -s "$LEAK_LOG" && ! -s "$UP_LOG" ]] || fail_ "gate closed: held (3), nothing tested, nothing started (rc $rc)"; pass
state_del "$LEAK_GATE"; GATE_RC=0; GSTART="2026-11-03T10:00:00Z"; state_set "$LEAK_PROVEN" "gid1 $GSTART"
rc=0; vpn_start_group qbittorrent sonarr > /dev/null 2>&1 || rc=$?
(( rc == 0 )) && grep -qx "test local=1" "$LEAK_LOG" || fail_ "gluetun proven since it started: the local checks ($(cat "$LEAK_LOG"))"; pass
[[ "$(paste -sd'|' "$UP_LOG")" == "DC up -d qbittorrent sonarr|guard" ]] || fail_ "then the members, then the attachment verified ($(paste -sd'|' "$UP_LOG"))"; pass
: > "$UP_LOG"; vpn_start_group --no-recreate qbittorrent > /dev/null 2>&1
[[ "$(paste -sd'|' "$UP_LOG")" == "DC up -d --no-recreate qbittorrent|guard" ]] || fail_ "--no-recreate: started as they were ($(paste -sd'|' "$UP_LOG"))"; pass
GSTART="2026-11-03T12:00:00Z"; : > "$LEAK_LOG"; : > "$UP_LOG"
vpn_start_group qbittorrent > /dev/null 2>&1
grep -qx "test local=0" "$LEAK_LOG" || fail_ "gluetun restarted since its proof: the full run first ($(cat "$LEAK_LOG"))"; pass
GATE_RC=1; RUNNING=""; : > "$LEAK_LOG"; : > "$UP_LOG"
rc=0; vpn_start_group qbittorrent > /dev/null 2>&1 || rc=$?
(( rc == 3 )) && ! grep -q "DC up" "$UP_LOG" && leak_gate_closed || fail_ "a FAIL: the gate closes, nothing starts (rc $rc; $(paste -sd'|' "$UP_LOG"))"; pass
state_del "$LEAK_GATE"; GATE_RC=0

# ---- the supervisor ----
RUNNING="gluetun jellyfin"; : > "$LEAK_LOG"; : > "$UP_LOG"
vpn_supervise > /dev/null 2>&1
grep -q "DC up -d --no-recreate qbittorrent sonarr" "$UP_LOG" || fail_ "members not running (a crash, a boot): started as they were, through the gate — a change waits for update ($(paste -sd'|' "$UP_LOG"))"; pass
RUNNING="gluetun jellyfin qbittorrent sonarr"; : > "$LEAK_LOG"; : > "$UP_LOG"; state_set "$LEAK_PROVEN" "gid1 $GSTART"
vpn_supervise > /dev/null 2>&1
! grep -q "DC up" "$UP_LOG" && grep -qx "test local=1" "$LEAK_LOG" || fail_ "all running, gluetun proven: the local checks only, nothing started ($(paste -sd'|' "$UP_LOG"))"; pass
RUNNING="jellyfin"; : > "$LEAK_LOG"; : > "$UP_LOG"
vpn_supervise > /dev/null 2>&1
[[ ! -s "$LEAK_LOG" ]] && ! grep -q "DC up" "$UP_LOG" || fail_ "gluetun not running: nothing tested, nothing started (Docker restarts it)"; pass
ENABLED="jellyfin"; RUNNING="gluetun jellyfin"; : > "$LEAK_LOG"
vpn_supervise > /dev/null 2>&1; [[ ! -s "$LEAK_LOG" ]] || fail_ "no VPN at all: nothing to do"; pass
ENABLED="gluetun qbittorrent sonarr jellyfin"
maint_try_lock() { return 1; }; : > "$LEAK_LOG"
(cmd_vpn_watch) > /dev/null 2>&1 || fail_ "an update or backup holds the stack: the check skips, cleanly"; pass
[[ ! -s "$LEAK_LOG" ]] || fail_ "and touches nothing"; pass
maint_try_lock() { return 0; }; STOP_MARKER="$T/stopped"; : > "$STOP_MARKER"
(cmd_vpn_watch) > /dev/null 2>&1; [[ ! -s "$LEAK_LOG" ]] || fail_ "a backup mid-copy: skipped"; pass

# ---- a backup starts what it stopped: the group last, through the gate ----
VSG_RC=0
sudo() { if [[ "$1" == rm ]]; then shift; rm "$@"; fi; return 0; }
# stubbed past the real one tested above (eval: shellcheck would read a redefinition as a use-before-define)
eval 'vpn_start_group() { echo "gate $*" >> "$UP_LOG"; return "$VSG_RC"; }'
printf 'backup\ngluetun jellyfin qbittorrent sonarr\n' > "$STOP_MARKER"; : > "$UP_LOG"
stopped_start > /dev/null 2>&1 || fail_ "started again — $(cat "$UP_LOG")"; pass
[[ "$(paste -sd'|' "$UP_LOG")" == "DC up -d --no-recreate gluetun jellyfin|wait --recover gluetun|gate --no-recreate qbittorrent sonarr" ]] \
    || fail_ "everything else, gluetun ready, then the group through the gate — all as they were: a released pin waits for update (found live Nov 2026: a backup's restart moved gluetun to a new image unproven) ($(paste -sd'|' "$UP_LOG"))"; pass
[[ ! -e "$STOP_MARKER" ]] || fail_ "the marker goes once they are up"; pass
printf 'backup\n\n' > "$STOP_MARKER"; : > "$UP_LOG"   # a marker a power cut left half-written
stopped_start > /dev/null 2>&1
[[ "$(paste -sd'|' "$UP_LOG")" == "DC up -d --no-recreate gluetun jellyfin|wait --recover gluetun|gate --no-recreate qbittorrent sonarr" ]] || fail_ "a cut-short marker: everything enabled, the group still through the gate ($(paste -sd'|' "$UP_LOG"))"; pass
VSG_RC=3; printf 'backup\ngluetun qbittorrent\n' > "$STOP_MARKER"
stopped_start > /dev/null 2>&1 || fail_ "held by the gate: not a failure (the gate told ops and owns them)"; pass
[[ ! -e "$STOP_MARKER" ]] || fail_ "and the marker goes (the gate's state holds them now)"; pass
VSG_RC=1; printf 'backup\ngluetun qbittorrent\n' > "$STOP_MARKER"
stopped_start > /dev/null 2>&1 && fail_ "a group that failed to start: a failure"; pass
[[ -e "$STOP_MARKER" ]] || fail_ "and the marker stays for the boot guard"; pass

# ---- leak_test_run: dependents re-joined only once gluetun's own checks passed ----
# shellcheck source=services/gluetun/vpn.sh
source services/gluetun/vpn.sh   # the real leak_test_run back (stubbed above)
for f in lt_dns_config lt_dns_lan_path lt_control_server lt_flows lt_ipv6 lt_tunnel_ip lt_udp_identity lt_dns_host_path lt_dns_resolvers; do eval "$f() { :; }"; done
hostid_ensure() { return 0; }
FW_FAIL=0
lt_firewall() { if (( FW_FAIL )); then lt_fail "firewall: a test leak"; else lt_pass "firewall ok"; fi; }
c_inspect_all() { :; }; c_netns() { echo "net:[1]"; }; svc_managed_where() { :; }
sudo() { if [[ "$*" == *"ip -o link"* ]]; then printf '1: lo: x\n2: eth0@if3: x\n3: tun0: x\n'; fi; return 0; }
eval 'leak_proof_record() { echo proof >> "$UP_LOG"; }'
eval 'vpn_reattach_guard() { echo guard >> "$UP_LOG"; }'
RUNNING="gluetun"; FW_FAIL=1; : > "$UP_LOG"
rc=0; leak_test_run 0 0 > /dev/null 2>&1 || rc=$?
(( rc == 1 )) && ! grep -q guard "$UP_LOG" || fail_ "gluetun's own check failed: FAIL, the dependents NOT re-joined to it (rc $rc; $(paste -sd'|' "$UP_LOG"))"; pass
! grep -q proof "$UP_LOG" || fail_ "and a FAIL proves nothing"; pass
FW_FAIL=0; : > "$UP_LOG"
rc=0; leak_test_run 0 1 > /dev/null 2>&1 || rc=$?
(( rc == 0 )) && grep -q guard "$UP_LOG" || fail_ "gluetun's checks passed: the dependents re-joined (rc $rc)"; pass
! grep -q proof "$UP_LOG" || fail_ "the local checks never record a proof"; pass
: > "$UP_LOG"; leak_test_run 0 0 > /dev/null 2>&1
grep -q proof "$UP_LOG" || fail_ "a full run without a FAIL records which gluetun it proved"; pass

# ---- the hourly run: the full checks, whatever gluetun's proof ----
eval 'leak_test_run() { echo "test local=$2" >> "$LEAK_LOG"; return 0; }'   # the stub again (the ordering test above used the real one)
c_inspect_all() { :; }
RUNNING="gluetun jellyfin qbittorrent sonarr"; ENABLED="gluetun qbittorrent sonarr jellyfin"
GSTART="2026-11-03T10:00:00Z"; state_set "$LEAK_PROVEN" "gid1 $GSTART"; : > "$LEAK_LOG"
vpn_supervise full > /dev/null 2>&1
grep -qx "test local=0" "$LEAK_LOG" || fail_ "--full: the full run though gluetun is proven ($(cat "$LEAK_LOG"))"; pass

# ---- the gate's timers ----
SYSTEMD_DIR="$T/systemd"; mkdir -p "$SYSTEMD_DIR"; SCRIPT_DIR=/opt/ms
sudo() { case "$1" in cmp) shift; cmp "$@" ;; install) shift; install "$@" ;; *) : ;; esac; }
gate_timers_ensure > /dev/null 2>&1
tim() { cat "$SYSTEMD_DIR/$1.timer"; }
grep -qx 'OnCalendar=\*:0/5' <(tim mediastack-leakcheck) && ! grep -q RandomizedDelaySec <(tim mediastack-leakcheck) \
    || fail_ "the local checks: every 5 minutes, on the dot ($(tim mediastack-leakcheck))"; pass
grep -qx 'ExecStart=/opt/ms/mediastack.sh vpn-watch' "$SYSTEMD_DIR/mediastack-leakcheck.service" || fail_ "runs vpn-watch"; pass
grep -qx 'OnCalendar=hourly' <(tim mediastack-leaktest) && grep -qx 'RandomizedDelaySec=3000' <(tim mediastack-leaktest) \
    || fail_ "the full run: hourly, at a random minute ($(tim mediastack-leaktest))"; pass
grep -qx 'ExecStart=/opt/ms/mediastack.sh vpn-watch --full' "$SYSTEMD_DIR/mediastack-leaktest.service" || fail_ "runs vpn-watch --full"; pass
grep -qx 'OnCalendar=daily' <(tim mediastack-hostid) && grep -qx 'RandomizedDelaySec=43200' <(tim mediastack-hostid) \
    || fail_ "the host's own address: daily, at a random time ($(tim mediastack-hostid))"; pass
grep -qx 'ExecStart=/opt/ms/mediastack.sh host-identity' "$SYSTEMD_DIR/mediastack-hostid.service" || fail_ "runs host-identity"; pass
(( 43200 + 86400 < HOSTID_STALE_AGE )) || fail_ "two daily runs can be 36h apart: the record must outlive that (stale at $HOSTID_STALE_AGE s)"; pass
for u in mediastack-leakcheck mediastack-leaktest mediastack-hostid; do
    grep -qx "$FAILURE_HOOK" "$SYSTEMD_DIR/$u.service" || fail_ "$u: a run that cannot run tells ops (OnFailure)"; pass
    grep -q "$u.timer" lib/footprint.sh && grep -q "$u.service" lib/footprint.sh || fail_ "$u: both units in the host-footprint registry (uninstall removes them)"; pass
done

# ---- update: the VPN group through the gate ----
APPLY_LOG="$T/apply"
apply_up() { echo "apply $*" >> "$APPLY_LOG"; }
DC() { echo "DC $*" >> "$APPLY_LOG"; }
wait_verdict() { echo "wait $*" >> "$APPLY_LOG"; }
gluetun_addr() { echo 172.31.250.9; }
lt_flows_forget() { echo "forget $1" >> "$APPLY_LOG"; }
VSG_RC=0
eval 'vpn_start_group() { echo "gate $*" >> "$APPLY_LOG"; return "$VSG_RC"; }'
ENABLED="gluetun qbittorrent sonarr jellyfin"
GREC=1; gluetun_recreates() { return "$GREC"; }
: > "$APPLY_LOG"; update_apply jellyfin sonarr > /dev/null 2>&1
[[ "$(paste -sd'|' "$APPLY_LOG")" == "apply --remove-orphans jellyfin|gate sonarr" && $UPDATE_GCHG == 0 ]] \
    || fail_ "gluetun unchanged: the rest applied, the group's targets through the gate ($(paste -sd'|' "$APPLY_LOG"))"; pass
GREC=0; : > "$APPLY_LOG"; update_apply gluetun jellyfin sonarr > /dev/null 2>&1
[[ "$(paste -sd'|' "$APPLY_LOG")" == "DC stop gluetun|forget 172.31.250.9|apply --remove-orphans gluetun jellyfin|wait --recover gluetun|gate qbittorrent sonarr" && $UPDATE_GCHG == 1 ]] \
    || fail_ "gluetun changed: stopped, its tracked connections forgotten, recreated, ready, then the WHOLE group through the gate ($(paste -sd'|' "$APPLY_LOG"))"; pass
VSG_RC=3; out=$( (update_apply gluetun sonarr) 2>&1 ) && fail_ "the gate held the group: the update fails"; pass
[[ "$out" == *"the leak gate stopped the VPN group"*"rollback gluetun"* ]] || fail_ "and says what to do — $out"; pass
VSG_RC=0
grep -q 'leak_gate_refuse "update"' <(awk '/^cmd_update\(\)/,/^}/' lib/backup.sh) || fail_ "update refuses while the gate is closed, before anything is touched"; pass
grep -q 'leak_test_run 1 0' <(awk '/^cmd_update\(\)/,/^}/' lib/backup.sh) || fail_ "a new gluetun image: the kill-switch proven the same night"; pass
# the attachment verified once per update: by the gated start, or (no VPN'd target) the catch-all (found live Nov 2026: said twice)
GREC=1; : > "$APPLY_LOG"; update_apply jellyfin sonarr > /dev/null 2>&1; (( UPDATE_GUARDED == 1 )) || fail_ "a gated start: guarded"; pass
: > "$APPLY_LOG"; update_apply jellyfin > /dev/null 2>&1; (( UPDATE_GUARDED == 0 )) || fail_ "no VPN'd target: not guarded, the catch-all runs"; pass
grep -q '(( UPDATE_GUARDED )) || vpn_reattach_guard' <(awk '/^cmd_update\(\)/,/^}/' lib/backup.sh) || fail_ "update runs the catch-all only when no gated start verified"; pass

# ---- doctor during a gated stop: one finding, the rest attributed ----
D_FAILS=0
d_fail() { echo "DFAIL $1" >> "$T/doc"; D_FAILS=$((D_FAILS + 1)); }
svc_managed() { printf '%s\n' gluetun jellyfin qbittorrent sonarr; }
svc_shard() { printf '%s\n' "$@"; }
c_health() { echo "-"; }
RUNNING="gluetun jellyfin"; : > "$T/doc"
state_set "$LEAK_GATE" "2026-11-03 10:00:00: firewall lets traffic out"
_doctor_containers > "$T/out" 2>&1
! grep -q "DFAIL" "$T/doc" || fail_ "the members the gate holds are not each a problem ($(cat "$T/doc"))"; pass
grep -q "qbittorrent held stopped by the leak gate" "$T/out" || fail_ "they are named as held — $(cat "$T/out")"; pass
state_del "$LEAK_GATE"; : > "$T/doc"
_doctor_containers > /dev/null 2>&1
grep -q "DFAIL qbittorrent is exited" "$T/doc" || fail_ "gate open: a stopped member is a problem again ($(cat "$T/doc"))"; pass
grep -q 'leak_gate_closed; then' <(awk '/^cmd_doctor\(\)/,/^}/' lib/doctor.sh) && grep -q 'd_fail "the leak gate stopped the VPN group' lib/doctor.sh \
    || fail_ "doctor counts a gated stop once, at the top, with the fix"; pass

# ---- enable starts through up (the gate), never a compose up of its own ----
for f in svc_exists svc_conflicts vpn_gen require_free_ports require_mounts provision \
         uid_handover traefik_ensure authentik_prepare network_ensure load_env notify; do eval "$f() { :; }"; done
env_set() { if [[ "$1" == COMPOSE_PROFILES ]]; then ENABLED=${2//,/ }; echo "$2" >> "$T/sets"; fi; }   # what svc_enabled reads here
svc_label() { :; }; resolve_deps() { printf '%s\n' "$@"; }; trash_instances() { :; }
ENABLED="gluetun jellyfin"; : > "$UP_LOG"
mkdir -p "$T/fake"; printf '#!/usr/bin/env bash\necho "$*" >> "%s"\n' "$UP_LOG" > "$T/fake/mediastack.sh"
DC() { echo "DC $*" >> "$UP_LOG"; }
( SCRIPT_DIR=$T/fake; cmd_enable lidarr ) > /dev/null 2>&1
[[ "$(paste -sd'|' "$UP_LOG")" == "questionnaire --for lidarr|up|wire" ]] \
    || fail_ "enable asks its questions, then starts through up — the leak gate — and wires; no compose up of its own ($(paste -sd'|' "$UP_LOG"))"; pass
# its questions cancelled: the set goes back as it was, nothing starts
ENABLED="gluetun jellyfin"; : > "$UP_LOG"; : > "$T/sets"; env_get() { [[ "$1" == COMPOSE_PROFILES ]] && echo gluetun,jellyfin; return 0; }
printf '#!/usr/bin/env bash\necho "$*" >> "%s"\n[[ "$1" != questionnaire ]] || exit 130\n' "$UP_LOG" > "$T/fake/mediastack.sh"
( SCRIPT_DIR=$T/fake; cmd_enable lidarr; echo "ENABLED=$ENABLED" ) > "$T/out" 2>&1 && fail_ "enable with its questions cancelled"
[[ "$(paste -sd'|' "$UP_LOG")" == "questionnaire --for lidarr" ]] && grep -q "'lidarr' not enabled: its questions did not finish" "$T/out" \
    || fail_ "cancelled: nothing starts, it says so: $(paste -sd'|' "$UP_LOG") / $(cat "$T/out")"; pass
[[ "$(tail -1 "$T/sets")" == gluetun,jellyfin ]] || fail_ "and the set goes back as it was: $(paste -sd'|' "$T/sets")"; pass

# ---- restore starts what it restored as update applies (repro Nov 2026: ----
# ---- a bare compose up per service — no gate, a restored gluetun unproven,  ----
# ---- and restore --all named every catalogued service to compose)            ----
R=$T/restore; mkdir -p "$R/b/20261101-030000" "$R/c"; : > "$R/log"
for s_ in gluetun qbittorrent jellyfin deluge; do
    mkdir -p "$R/src/$s_"; tar -C "$R/src" -czf "$R/b/20261101-030000/$s_.tar.gz" "$s_"
done
printf 'gluetun g:1\nqbittorrent q:1\njellyfin j:1\ndeluge d:1\n' > "$R/b/20261101-030000/images.lock"
for f in load_env require_mounts point_check point_shard_check shard_member_refuse maint_lock svc_exists; do eval "$f() { :; }"; done
env_get() { case $1 in BACKUP_ROOT) echo "$R/b" ;; CONFIG_ROOT) echo "$R/c" ;; esac; }
svc_shard() { printf '%s\n' "$@"; }
svc_managed() { printf '%s\n' deluge gluetun jellyfin qbittorrent; }
gluetun_addr() { echo 172.31.250.3; }
DC() { echo "DC $*" >> "$R/log"; }
pin_service() { :; }
lt_flows_forget() { echo "forget $1" >> "$R/log"; }
eval 'update_apply() { echo "apply $*" >> "$R/log"; }'
ENABLED="gluetun qbittorrent jellyfin"
: > "$R/log"; ( cmd_restore --service qbittorrent --from 20261101-030000 ) > /dev/null 2>&1
[[ "$(paste -sd'|' "$R/log")" == "DC stop qbittorrent|apply qbittorrent" ]] \
    || fail_ "restore a VPN'd service: stopped, restored, started as update applies (the gate) — no compose up of its own ($(paste -sd'|' "$R/log"))"; pass
: > "$R/log"; ( cmd_restore --service gluetun --from 20261101-030000 ) > /dev/null 2>&1
[[ "$(paste -sd'|' "$R/log")" == "DC stop gluetun|forget 172.31.250.3|apply --restore gluetun" ]] \
    || fail_ "restore gluetun: its tracked connections forgotten, then applied as a changed gluetun ($(paste -sd'|' "$R/log"))"; pass
eval 'cmd_up() { echo "UP" >> "$R/log"; }'
: > "$R/log"; out=$( ( cmd_restore --all --from 20261101-030000 ) 2>&1 )
[[ "$(paste -sd'|' "$R/log")" == "DC stop deluge|DC stop gluetun|forget 172.31.250.3|DC stop jellyfin|DC stop qbittorrent|UP" ]] \
    || fail_ "restore --all: every point restored, then the stack started as up starts it — its checks, the gate (found live Nov 2026) ($(paste -sd'|' "$R/log"))"; pass
[[ "$out" == *"deluge not enabled — restored, not started"* ]] || fail_ "a disabled service with an archive: restored, not started, and said — $out"; pass
printf 'gluetun g:1\n' > "$R/b/20261101-030000/images.lock"; svc_managed() { printf '%s\n' gluetun lidarr; }
out=$( ( cmd_restore --all --from 20261101-030000 ) 2>&1 )
[[ "$out" != *"lidarr"* ]] || fail_ "a disabled service with nothing in the point is not called restored — $out"; pass
svc_managed() { printf '%s\n' deluge gluetun jellyfin qbittorrent; }
: > "$R/log"; out=$( ( cmd_restore --service deluge --from 20261101-030000 ) 2>&1 )
[[ "$(paste -sd'|' "$R/log")" == "DC stop deluge" && "$out" == *"deluge not enabled — restored, not started"* ]] \
    || fail_ "a disabled service is restored, not started, and says so ($(paste -sd'|' "$R/log") / $out)"; pass
# update_apply --restore: a restored gluetun takes the changed path whatever compose would do; messages name restore
unset -f update_apply; eval "$(awk '/^update_apply\(\)/,/^}/' lib/backup.sh)"
apply_up() { echo "apply $*" >> "$APPLY_LOG"; }; DC() { echo "DC $*" >> "$APPLY_LOG"; }
lt_flows_forget() { echo "forget $1" >> "$APPLY_LOG"; }; ENABLED="gluetun qbittorrent sonarr jellyfin"
GREC=1; VSG_RC=0; : > "$APPLY_LOG"; update_apply --restore gluetun > /dev/null 2>&1
[[ "$(paste -sd'|' "$APPLY_LOG")" == "DC stop gluetun|forget 172.31.250.3|apply --remove-orphans gluetun|wait --recover gluetun|gate qbittorrent sonarr" ]] \
    || fail_ "restore: gluetun unchanged to compose, still the changed path — the full run, the whole group ($(paste -sd'|' "$APPLY_LOG"))"; pass
VSG_RC=3; out=$( (update_apply --restore gluetun) 2>&1 ) && fail_ "the gate held the group: the restore fails"; pass
[[ "$out" == *"restore: the leak gate stopped the VPN group"* && "$out" != *"rollback gluetun"* ]] || fail_ "named restore, no rollback advice — $out"; pass
VSG_RC=0

echo "test-gate: $checks checks passed"
