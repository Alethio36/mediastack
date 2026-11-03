#!/usr/bin/env bash
# services/gluetun/vpn.sh — everything about the gluetun tunnel: the reattach
# guard (script paths) and its boot unit (daemon/boot paths), the leak-test,
# doctor's tunnel checks (gluetun_doctor), and per-service VPN membership
# (vpn_gen renders local/vpn-overlay.yml, with each route's labels from the
# edge; the vpn/vpn-apply verbs). Sourced by the entrypoint; relies on lib/common.sh and the
# entrypoint's service/render/inspect helpers at call time.

# ---------------------------------------------------------- vpn guard --
# Fail-CLOSED enforcement for gluetun's netns model. Any path that recreates
# gluetun gives it a new container ID; compose does NOT recreate the
# network_mode:service:gluetun dependents whose own config is unchanged, so
# they stay joined to the dead namespace and lose egress silently (health
# stays green — the app runs fine offline). This guard is the single source
# of truth: enumerate dependents from the rendered config (effective
# membership, <SVC>_VPN overrides included), check each running one sits in
# the live gluetun's network namespace (vpn_join: the ID it joined, then the
# namespace itself — a gluetun restarted in place keeps its ID but builds a
# new namespace), and force-recreate any that drifted. Loud on drift, self-heals, dies only if a
# re-pin fails to take. Stopped dependents are skipped — doctor/leak-test
# catch them when started. Called from cmd_up and cmd_update so neither path
# can leave a ghost behind.
vpn_join() { # vpn_join CNAME GLUETUN_ID GLUETUN_NETNS -> ok | other | stale | unknown
    # other: joined to some other container (a leak path); stale: joined to
    # gluetun but in a namespace it no longer has (restarted under it: no
    # egress at all); unknown: its namespace could not be read
    local ns
    [[ "$(c_netmode "$1")" == "container:$2" ]] || { echo other; return; }
    ns=$(c_netns "$1")
    if [[ -z "$ns" || -z "$3" ]]; then echo unknown
    elif [[ "$ns" == "$3" ]]; then echo ok
    else echo stale; fi
}

vpn_reattach_guard() {
    render; c_inspect_all
    local gid gns vd nm vdeps=() stale=()
    mapfile -t vdeps < <(jq -r '.services | to_entries[]
        | select((.value.network_mode // "") == "service:gluetun") | .key' \
        <<<"$RENDERED_JSON" | sort)
    (( ${#vdeps[@]} )) || { warn "vpn guard: no service:gluetun dependents in the rendered config — nothing to verify"; return 0; }
    gid=$(c_id "$(svc_cname gluetun)")
    [[ -n "$gid" ]] || die "vpn guard: cannot resolve the live gluetun container — VPN attachment unverifiable. Inspect gluetun, then re-run."
    gns=$(c_netns "$(svc_cname gluetun)")
    [[ -n "$gns" ]] || die "vpn guard: cannot read the live gluetun's network namespace — VPN attachment unverifiable. Inspect gluetun, then re-run."
    local running=0
    for vd in "${vdeps[@]}"; do
        [[ "$(c_state "$(svc_cname "$vd")")" == running ]] || continue
        running=$((running + 1))
        nm=$(vpn_join "$(svc_cname "$vd")" "$gid" "$gns")
        [[ "$nm" == unknown ]] && die "vpn guard: cannot read $vd's network namespace — its VPN attachment is unverifiable. Inspect it, then re-run."
        [[ "$nm" == ok ]] || stale+=("$vd")
    done
    if (( ${#stale[@]} )); then
        warn "dependents not in the live gluetun's namespace (gluetun recreated or restarted under them — no egress): ${stale[*]}"
        info "re-pinning them onto the live gluetun..."
        DC up -d --force-recreate --no-deps "${stale[@]}"
        for vd in "${stale[@]}"; do
            nm=$(vpn_join "$(svc_cname "$vd")" "$gid" "$gns")
            [[ "$nm" == ok ]] && continue
            notify ops "Mediastack VPN re-pin FAILED" "VPN dependents detached from gluetun and re-pin FAILED: **${stale[*]}**"$'\n'"Fix now: \`./mediastack.sh up\` then \`./mediastack.sh leak-test\`" failure
            die "vpn guard: $vd is still not joined to the live gluetun after recreate — VPN egress is broken. Fix this before anything else."
        done
        ok "re-pinned ${#stale[@]} dependent(s) onto the live gluetun"
    fi
    # what was checked, not what the config lists: a stopped dependent is not verified
    if (( running == ${#vdeps[@]} )); then ok "VPN attachment verified: all $running dependent(s) on the live gluetun"
    else ok "VPN attachment verified: $running running dependent(s) on the live gluetun ($(( ${#vdeps[@]} - running )) not running — checked when they start)"; fi
}

# --------------------------------------------------------- vpn boot guard --
# The reattach guard (vpn_reattach_guard) only runs when the script runs. A
# reboot or `systemctl restart docker` brings containers back by restart-policy
# WITHOUT the script, so a gluetun recreated on boot could leave borrowers on a
# dead namespace with nothing to catch it until the next manual up/update. This
# oneshot unit runs the guard on every boot and docker restart, closing that
# out-of-band window. It does NOT cover a raw `docker compose up` while the
# system is already running — only script paths and daemon/boot events. Install
# is unconditional (pure safety, no reason to gate) and idempotent, refreshed on
# every cmd_up so a removed unit reappears. At boot it first starts what a
# cut-off backup left stopped (stopped_recover: a power cut, kill -9).
VPNGUARD_UNIT=$SYSTEMD_DIR/mediastack-vpnguard.service

vpnguard_ensure() {
    # Write/refresh the boot-guard unit. Cheap and idempotent; only reloads
    # systemd when the file actually changed, to avoid needless daemon-reloads
    # on every up.
    local tmp; tmp=$(mktemp)
    cat >"$tmp" <<EOF
[Unit]
Description=Mediastack boot guard (services a cut-off backup stopped; VPN attachment)
After=docker.service
Requires=docker.service
$FAILURE_HOOK
[Service]
Type=oneshot
WorkingDirectory=$SCRIPT_DIR
ExecStart=$SCRIPT_DIR/mediastack.sh vpn-guard --boot
[Install]
WantedBy=multi-user.target
EOF
    # 644 like every unit: mktemp makes 600, and a 600 unit refuses `systemctl
    # cat` to users (found live) — an existing 600 one is repaired too
    if ! sudo cmp -s "$tmp" "$VPNGUARD_UNIT" 2>/dev/null || [[ "$(stat -c %a "$VPNGUARD_UNIT" 2>/dev/null)" != 644 ]]; then
        sudo install -m 644 "$tmp" "$VPNGUARD_UNIT"
        failure_unit_ensure
        sudo systemctl daemon-reload
        sudo systemctl enable mediastack-vpnguard.service >/dev/null 2>&1 || true
        info "VPN boot-guard unit installed/updated"
    fi
    rm -f "$tmp"
}

cmd_vpn_guard() {
    load_env
    local boot=0; [[ "${1:-}" == --boot ]] && boot=1
    (( boot )) && stopped_recover
    # On boot, docker starts containers asynchronously — gluetun may not be
    # healthy yet. Wait (bounded) before judging attachment, or we would race
    # the very startup we are guarding and falsely repair/​fail. Mirrors cmd_up's
    # gluetun health-race handling.
    local gcn; gcn=$(svc_cname gluetun)
    if [[ $(c_state "$gcn") == absent ]]; then
        (( boot )) && { info "vpn-guard: gluetun not present — stack not up, nothing to guard"; return 0; }
        die "vpn-guard: gluetun container not found — is the stack up?"
    fi
    wait_verdict --recover gluetun \
        || { warn "vpn-guard: gluetun ${VERDICT_WHY[gluetun]} — deferring (next boot/up will retry)"; return 0; }
    vpn_reattach_guard
}

# --------------------------------------------------------------- leak-test --
# The checks and their verdicts (PASS / FAIL / UNPROVEN) are in leak.sh;
# leak_test_run runs them in order and returns the verdict, and the verb acts
# on it (leak_verdict, gate.sh: a FAIL stops the VPN group). Exit 0 all
# proven, 1 a leak or a missing safeguard, 2 nothing failed but something
# could not be proven. --local: only what this host can see for itself — no
# outside party is asked anything (the 5-minute check).
cmd_leak_test() {
    load_env
    local a killswitch=0 lonly=0 rc=0
    for a in "$@"; do case $a in
        --killswitch) killswitch=1 ;;
        --local) lonly=1 ;;
        *) die "usage: leak-test [--killswitch|--local]" ;;
    esac; done
    leak_test_run "$killswitch" "$lonly" || rc=$?
    leak_verdict "$rc"
    echo
    case $rc in
        0) ok "leak-test passed: every check proven." ;;
        1) fail "leak-test FOUND PROBLEMS: $LT_FAIL check(s) failed — see above."; exit 1 ;;
        *) warn "leak-test: no leak found, but $LT_UNPROVEN check(s) UNPROVEN — see above. Not a pass."; exit 2 ;;
    esac
}

leak_test_run() { # leak_test_run KILLSWITCH LOCAL -> returns the verdict (0/1/2); dies when it cannot run at all
    local killswitch=$1 lonly=$2
    local gcn; gcn=$(svc_cname gluetun)
    c_inspect_all
    [[ "$(c_state "$gcn")" == running ]] || die "gluetun is not running — start the stack first."
    lt_reset

    hr "leak-test: attachment audit"
    # drift first (a restarted gluetun leaves its dependents behind): repaired
    # loudly here, so what follows judges the tunnel, not a stale join
    vpn_reattach_guard
    c_inspect_all
    # Netns-joined containers report an EMPTY SandboxKey, so key equality can
    # never verify the join. NetworkMode names the container joined; the
    # namespace itself (vpn_join) proves it is gluetun's current one.
    local gid gns s cn nm
    gid=$(c_id "$gcn"); gns=$(c_netns "$gcn")
    for s in $(svc_managed_where mediastack.vpn true); do
        svc_enabled "$s" || continue
        cn=$(svc_cname "$s"); [[ "$(c_state "$cn")" == running ]] || { info "$s not running — skipped"; continue; }
        case $(vpn_join "$cn" "$gid" "$gns") in
            ok)    lt_pass "$s routed through the gluetun tunnel" ;;
            stale) lt_fail "$s sits in gluetun's old namespace (gluetun restarted under it): no egress at all, not a leak — ./mediastack.sh up re-joins it" ;;
            other) nm=$(c_netmode "$cn"); lt_fail "$s is NOT joined to gluetun (mode: ${nm:0:40}...) — this IS a leak path" ;;
            *)     lt_unproven "$s: its network namespace could not be read — attachment unverifiable" ;;
        esac
    done

    hr "leak-test: the tunnel's namespace"
    # the namespace must hold exactly lo + one LAN-side interface + the tunnel:
    # a second ethN means another docker network is attached
    local links eth_n
    links=$(sudo docker exec "$gcn" ip -o link 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1 | grep -v '^lo$' || true)
    eth_n=$(grep -c '^eth' <<<"$links" || true)
    if [[ "$eth_n" == 1 ]]; then lt_pass "exactly one LAN-side interface in the namespace"
    else lt_fail "unexpected interface set in the namespace: $(tr '\n' ' ' <<<"$links") — a second network is attached"; fi
    if grep -qE '^(tun|wg)' <<<"$links"; then lt_pass "tunnel interface present"
    else lt_fail "no tunnel interface in the namespace"; fi
    if (( lonly )); then
        info "--local: who the internet sees, IPv6, and the DNS a stranger answers are asked of outside parties — the hourly run does them"
    else
        lt_ipv6 "$gcn"
        hr "leak-test: who the internet sees"
        local hok=0
        hostid_ensure && hok=1
        lt_tunnel_ip "$gcn" "$hok"
        lt_udp_identity "$gcn" "$hok"
    fi

    hr "leak-test: DNS"
    lt_dns_config "$gcn"
    lt_dns_lan_path "$gcn"
    if (( ! lonly )); then
        lt_dns_host_path "$gcn"
        lt_dns_resolvers "$gcn" "$hok"
    fi

    hr "leak-test: gluetun's control server"
    lt_control_server "$gcn"

    hr "leak-test: the firewall and the traffic"
    lt_firewall "$gcn"
    lt_flows "$gcn"

    hr "leak-test: kill-switch"
    if (( lonly )); then
        info "--local runs no disruptive proof"
    elif (( ! killswitch )); then
        info "the disruptive proofs (tunnel dropped, gluetun stopped) run with --killswitch"
    else
        warn "Disruptive proof: dropping the tunnel interface for ~10s..."
        sudo docker exec "$gcn" sh -c 'ip link set dev tun0 down' || true
        if sudo docker run --rm --network "container:$gcn" curlimages/curl:latest \
             -fsS --max-time 6 https://github.com -o /dev/null >/dev/null 2>&1; then
            lt_fail "egress SUCCEEDED with the tunnel down — kill-switch NOT working"
        else lt_pass "egress blocked with tunnel down — kill-switch works"; fi
        sudo docker exec "$gcn" sh -c 'ip link set dev tun0 up' || true
        info "Restarting gluetun to restore a clean tunnel..."
        DC restart gluetun >/dev/null
        # the restart left every dependent in the old namespace: re-join them,
        # or the hard stop below probes from a namespace that is already dead
        wait_verdict --recover gluetun || die "gluetun ${VERDICT_WHY[gluetun]} after the tunnel-drop proof — inspect: ./mediastack.sh logs gluetun"
        vpn_reattach_guard
        gid=$(c_id "$gcn")

        # any running torrent client in gluetun's live namespace probes it — not
        # just qBittorrent; one moved out of the VPN (vpn ... --i-know) is no
        # probe. It must reach out BEFORE the stop: a probe with no egress to
        # begin with proves nothing by having none after (found live, Nov 2026).
        local pcn="" ts tcn
        INSPECT_JSON=""; gns=$(c_netns "$gcn")
        for ts in $(svc_managed_where mediastack.torrent true); do
            tcn=$(svc_cname "$ts")
            [[ "$(c_state "$tcn")" == running && "$(vpn_join "$tcn" "$gid" "$gns")" == ok ]] && { pcn=$tcn; break; }
        done
        if [[ -z "$pcn" ]]; then lt_unproven "hard stop: no torrent client is running in the tunnel to probe from"
        elif ! sudo docker exec "$pcn" curl -fsS --max-time 10 https://github.com -o /dev/null >/dev/null 2>&1; then
            lt_unproven "hard stop: the probe $pcn cannot reach out even with gluetun up — skipped (it would prove nothing)"
        else
            warn "Hard-stop proof: stopping gluetun ENTIRELY (~30s of downtime)..."
            sudo docker stop "$gcn" >/dev/null; INSPECT_JSON=""
            if sudo docker exec "$pcn" curl -fsS --max-time 6 https://github.com -o /dev/null >/dev/null 2>&1; then
                lt_fail "egress SUCCEEDED from a dependent with gluetun STOPPED — containment broken"
            else lt_pass "zero egress from dependents with gluetun dead (they reached out a moment before — fail-safe)"; fi
            if sudo docker exec "$pcn" sh -c 'ip route 2>/dev/null | grep -q default'; then
                lt_fail "a default route appeared inside the dead namespace"
            else lt_pass "no fallback route appeared — docker cannot re-home a joined container"; fi
            info "Restarting gluetun and re-joining dependents..."
            sudo docker start "$gcn" >/dev/null
            # shellcheck disable=SC2034  # the inspect cache lives in the entrypoint (CACHE RULE at c_inspect)
            INSPECT_JSON=""
            wait_verdict --recover gluetun \
                || die "gluetun ${VERDICT_WHY[gluetun]} after the hard-stop proof — its dependents are offline. Inspect: ./mediastack.sh logs gluetun, then ./mediastack.sh up"
            vpn_reattach_guard   # every running dependent is in the stopped gluetun's namespace: re-joined and verified
        fi
    fi

    hr "leak-test: host port sweep"
    render
    for s in $(svc_managed_where mediastack.vpn true); do
        if jq -e --arg s "$s" '.services[$s].ports // [] | length == 0' <<<"$RENDERED_JSON" >/dev/null; then
            lt_pass "$s publishes no ports of its own"
        else lt_fail "$s publishes host ports directly — must go through gluetun"; fi
    done
    return "$(lt_exit_code)"
}

# --------------------------------------------------------- vpn membership --
# VPN membership is operator-selectable per service. A service opts in by
# carrying the label mediastack.vpntoggle="true"; only those are handled here,
# so services still using static wiring are left untouched. Effective
# membership = ${<STEM>_VPN} from .env if set, else the fragment's
# mediastack.vpn default. vpn_gen materialises the wiring into
# local/vpn-overlay.yml (loaded by DC) additively — no compose !reset needed —
# and deterministically (sorted services), so identical inputs yield an
# identical file and never trigger a spurious recreate. .env stays the single
# source of truth for ports/hosts: the overlay emits ${VAR} placeholders, not
# resolved values.
# a torrent client outside the VPN leaks its traffic on the host IP: the
# mediastack.torrent label marks one (vpn_gen warns, `vpn ... off` refuses)
is_torrent_client() { [[ "$(svc_label "$1" mediastack.torrent)" == true ]]; }

vpn_onoff() { [[ "$1" == true ]] && echo "on" || echo "off"; }   # membership -> on/off

vpn_base_json() {   # base compose ONLY — never include the overlay (no self-reference)
    # Your files ARE base: a toggle-enabled service of yours (custom/) must be
    # seen, or vpn_gen never generates its network/port/route. (Run inside
    # $( ): a misplaced file prints its reason here and the caller dies.)
    user_compose_files
    local files=(-f docker-compose.yml "${USER_FILES[@]}")
    sudo docker compose --project-directory "$SCRIPT_DIR" "${files[@]}" \
        --profile "*" config --format json 2>/dev/null
}

vpn_effective() {   # vpn_effective <svc> <default> -> true|false
    local v; v=$(env_get "$(uvar "$1")_VPN")
    [[ -n "$v" ]] && { echo "$v"; return; }
    echo "$2"
}

vpn_port_line() {   # <stem> <cport> <auth> [local] -> one published port (a gated tool binds where MEDIASTACK_GATE_BIND says)
    local bind=""; [[ "$3" == gate ]] && bind='${MEDIASTACK_GATE_BIND:-}'
    [[ "${4:-}" == local ]] && bind='127.0.0.1:'   # mediastack.hostport: local — the script only (addr-ok: host bind)
    echo "      - \"${bind}\${${1}_PORT:-${2}}:${2}\""
}

vpn_gen() {
    install -d -m 755 "$LOCAL_DIR"; repo_owned "$LOCAL_DIR"
    local bj; bj=$(vpn_base_json) || die "vpn: could not read base compose config"
    local svcs
    svcs=$(jq -r '.services | to_entries[]
        | select(.value.labels["mediastack.vpntoggle"]=="true") | .key' <<<"$bj" | sort)
    # Build the three sections up front so empty ones can be omitted (an empty
    # `ports:`/`labels:` mapping is invalid YAML) and traefik.enable is emitted
    # exactly once per container (never duplicated as a mapping key).
    local gports="" glabels="" stanzas="" s stem cport sub rname defv eff hp auth bypass
    for s in $svcs; do
        stem=$(uvar "$s"); rname=$(edge_router_name "$s")
        cport=$(jq -r --arg s "$s" '.services[$s].labels["mediastack.port"] // ""' <<<"$bj")
        sub=$(jq -r --arg s "$s" '.services[$s].labels["mediastack.subdomain"] // ""' <<<"$bj")
        defv=$(jq -r --arg s "$s" '.services[$s].labels["mediastack.vpn"] // "false"' <<<"$bj")
        # hostport=false => traefik-only, no host port published (serving apps
        # whose container port would collide on the host, e.g. :80 vs Traefik).
        # Default true preserves direct host access for the acquisition apps.
        hp=$(jq -r --arg s "$s" '.services[$s].labels["mediastack.hostport"] // "true"' <<<"$bj")
        auth=$(jq -r --arg s "$s" '.services[$s].labels["mediastack.auth"] // ""' <<<"$bj")
        bypass=$(jq -r --arg s "$s" '.services[$s].labels["mediastack.auth.bypass"] // ""' <<<"$bj")
        [[ -n "$cport" ]] || die "vpn: $s carries no mediastack.port label"
        [[ -n "$sub"   ]] || die "vpn: $s carries no mediastack.subdomain label"
        eff=$(vpn_effective "$s" "$defv")
        if [[ "$eff" == true ]]; then
            [[ "$hp" != false ]] && gports+="$(vpn_port_line "$stem" "$cport" "$auth" "$hp")"$'\n'
            glabels+="$(edge_route_labels "      " "$rname" "$sub" "$cport" "$stem" "$auth" "$bypass")"$'\n'
            stanzas+="  ${s}:"$'\n'"    network_mode: \"service:gluetun\""$'\n'
            stanzas+="    depends_on:"$'\n'"      gluetun:"$'\n'"        condition: service_healthy"$'\n'   # addr-ok: a YAML key, no address
            stanzas+="    labels:"$'\n'"      mediastack.vpn: \"true\""$'\n'
        else
            [[ "$(jq -r --arg s "$s" '.services[$s].labels["mediastack.torrent"] // ""' <<<"$bj")" == true ]] \
                && warn "vpn: $s (torrent client) is OUTSIDE the VPN — its traffic exits on the host IP"
            # off the VPN it has its own resolv.conf: no host search domain
            # (docs/adding-a-service.md); on it, gluetun's is shared instead
            stanzas+="  ${s}:"$'\n'"    networks: [mediastack]"$'\n'"    dns_search: [\".\"]"$'\n'
            [[ "$hp" != false ]] && stanzas+="    ports:"$'\n'"$(vpn_port_line "$stem" "$cport" "$auth" "$hp")"$'\n'
            stanzas+="    labels:"$'\n'"      mediastack.vpn: \"false\""$'\n'"$(edge_enable_label "      ")"$'\n'
            stanzas+="$(edge_route_labels "      " "$rname" "$sub" "$cport" "$stem" "$auth" "$bypass")"$'\n'
        fi
    done
    local tmp; tmp=$(mktemp)
    {
        echo "# GENERATED by mediastack vpn_gen — DO NOT EDIT."
        echo "# Per-service VPN membership. Flip with: ./mediastack.sh vpn <svc> on|off"
        echo "# Source of truth: <SVC>_VPN in .env (default = fragment mediastack.vpn)."
        echo "services:"
        # gluetun only appears when at least one service is VPN'd; traefik.enable
        # is already set on the base gluetun service, so it is not repeated here.
        if [[ -n "$gports" || -n "$glabels" ]]; then
            echo "  gluetun:"   # addr-ok: the overlay's YAML key for the gluetun service, no address
            [[ -n "$gports"  ]] && { echo "    ports:";  printf '%s' "$gports"; }
            [[ -n "$glabels" ]] && { echo "    labels:"; printf '%s' "$glabels"; }
        fi
        printf '%s' "$stanzas"
    } > "$tmp"
    if ! cmp -s "$tmp" "$OVERLAY_FILE" 2>/dev/null; then
        # -f: the panel runs this as root, the CLI as the operator — a file the
        # other one wrote must be replaced, never questioned (mv prompts on an
        # unwritable target when stdin is a terminal). 0644: no secrets in it,
        # only labels and ${VAR} references, so no mktemp 0600 carried over.
        chmod 644 "$tmp"; mv -f "$tmp" "$OVERLAY_FILE"; repo_owned "$OVERLAY_FILE"
    else
        rm -f "$tmp"
    fi
}

vpn_list() {
    local bj; bj=$(vpn_base_json) || die "vpn: could not read base compose config"
    local any; any=$(jq -r '.services|to_entries[]
        | select(.value.labels["mediastack.vpntoggle"]=="true")|.key' <<<"$bj" | sort)
    [[ -n "$any" ]] || { info "No toggle-enabled services yet."; return; }
    cat <<'EOP'
VPN membership
"on" routes a service's internet traffic through the VPN tunnel (hiding your
real IP); "off" connects directly. It matters for downloaders and indexers
(torrent trackers, Prowlarr) — so those run on by default. Apps that only
serve your own media (Jellyfin, music, books) gain nothing and are fixed
outside the VPN, so they aren't shown here.

  VPN          what each service is set to now
  RECOMMENDED  the maintainer's suggested setting

Change one:  ./mediastack.sh vpn <service> on|off   then   ./mediastack.sh up
Turning a torrent client off needs --i-know (it exposes your IP).

EOP
    printf '%-16s %-5s %-13s %s\n' SERVICE VPN RECOMMENDED ""
    local s defv eff note
    for s in $any; do
        defv=$(jq -r --arg s "$s" '.services[$s].labels["mediastack.vpn"] // "false"' <<<"$bj")
        eff=$(vpn_effective "$s" "$defv")
        [[ "$eff" != "$defv" ]] && note="changed from recommended" || note=""
        printf '%-16s %-5s %-13s %s\n' "$s" "$(vpn_onoff "$eff")" "$(vpn_onoff "$defv")" "$note"
    done
}

# vpn-apply <svc> on|off — set a service's VPN membership AND apply it, so the
# panel button actually takes effect (bare `vpn` only stages the overlay).
# Delegates validation to cmd_vpn, which also refuses to move a torrent client
# OUT of the tunnel without the CLI's explicit --i-know (that would leak).
cmd_vpn_apply() {
    load_env
    local svc="${1:?usage: vpn-apply <svc> on|off}" act="${2:?usage: vpn-apply <svc> on|off}"
    case "$act" in on|off) ;; *) die "vpn-apply: action must be on or off" ;; esac
    cmd_vpn "$svc" "$act"
    cmd_up
}

cmd_vpn() {
    load_env
    local svc="${1:-}" act="${2:-}" iknow=0 a
    for a in "$@"; do case "$a" in --i-know) iknow=1 ;; -*) die "unknown option '$a' (usage: vpn [<svc> on|off] [--i-know])" ;; esac; done
    [[ "$svc" == --i-know ]] && die "usage: vpn [<svc> on|off] [--i-know]"
    [[ -z "$svc" ]] && { vpn_list; return; }
    svc_exists "$svc" || die "vpn: no such service '$svc'"
    [[ $(svc_label "$svc" mediastack.vpntoggle) == "true" ]] \
        || die "vpn: '$svc' is not toggle-enabled (no mediastack.vpntoggle label — its fragment fixes where it runs)."
    local stem target; stem=$(uvar "$svc")
    case "$act" in
        on|true)   target=true ;;
        off|false)
            if is_torrent_client "$svc" && (( iknow != 1 )); then
                die "vpn: refusing to move torrent client '$svc' OUT of the VPN — that leaks its traffic on the host IP.
  If you really mean it: ./mediastack.sh vpn $svc off --i-know"
            fi
            target=false ;;
        *) die "usage: ./mediastack.sh vpn [<svc> on|off]" ;;
    esac
    # Store an override only when it differs from the shipped default; when it
    # matches, clear any stale override so `vpn` shows OVERRIDE=— (no redundant
    # .env line). Read the default from the base fragment, not the rendered
    # config — the overlay reports the effective value, not the default.
    local default how
    default=$(vpn_base_json | jq -r --arg s "$svc" '.services[$s].labels["mediastack.vpn"] // "false"')
    # its address moves with its side (svc_addr): callers get re-pointed at `up`
    [[ "$(vpn_effective "$svc" "$default")" == "$target" ]] || repoint_mark "$svc"
    if [[ "$target" == "$default" ]]; then
        env_del "${stem}_VPN"; how="matches default"
    else
        env_set "${stem}_VPN" "$target"; how="override"
    fi
    vpn_gen
    ok "vpn: $svc $act ($how) — regenerated local/vpn-overlay.yml. Apply with: ./mediastack.sh up"
}

gluetun_doctor() { # doctor: every VPN'd service joined to the live tunnel, and the tunnel's public IP
    if [[ "$(c_state "$(svc_cname gluetun)")" == running ]]; then
        local dgid dgns dbad="" dstale="" dunk="" dchecked=0
        dgid=$(c_id "$(svc_cname gluetun)"); dgns=$(c_netns "$(svc_cname gluetun)")
        for s in $(svc_managed_where mediastack.vpn true); do
            svc_enabled "$s" || continue
            [[ $(c_state "$(svc_cname "$s")") == running ]] || continue
            dchecked=1
            case $(vpn_join "$(svc_cname "$s")" "$dgid" "$dgns") in
                ok) ;;
                stale) dstale+="$s " ;;
                other) dbad+="$s " ;;
                *) dunk+="$s " ;;
            esac
        done
        if (( dchecked == 0 )); then info "no running VPN'd services to audit"
        elif [[ -z "$dbad$dstale$dunk" ]]; then ok "all VPN'd services routed through the gluetun tunnel"; fi
        [[ -z "$dbad" ]] || d_fail "VPN'd services NOT attached to gluetun: $dbad" "their traffic bypasses the VPN entirely" "./mediastack.sh up   (recreates with correct attachment), then ./mediastack.sh leak-test"   # addr-ok: a message, no address
        [[ -z "$dstale" ]] || d_fail "VPN'd services in gluetun's old namespace: $dstale" "gluetun restarted under them: they have no network at all (not a leak)" "./mediastack.sh up   (re-joins them), then ./mediastack.sh leak-test"
        [[ -z "$dunk" ]] || warn "cannot read the network namespace of: $dunk— their attachment is unverified"
    fi
    if [[ "$(c_state "$(svc_cname gluetun)")" == running ]]; then
        # egress first (what the apps need), then who the internet sees: an
        # address-lookup service failing is not the tunnel failing
        local gcn out ip; gcn=$(svc_cname gluetun)
        if ! out=$(sudo docker exec "$gcn" wget -q --spider --timeout=8 "$VPN_EGRESS_URL" 2>&1); then
            d_fail "no egress through the tunnel ($VPN_EGRESS_URL: $(oneline "${out:-no answer}"))" "VPN may be down; downloads are dead (not leaking — kill-switch)" "./mediastack.sh logs gluetun"
        else
            out=$(sudo docker exec "$gcn" wget -qO- --timeout=8 https://am.i.mullvad.net/json 2>&1 || true)
            ip=$(jq -r '.ip // empty' <<<"$out" 2>/dev/null || true)
            if [[ -n "$ip" ]]; then ok "tunnel egress works; public IP $ip ($(jq -r '.organization // "?"' <<<"$out"))"
            else warn "tunnel egress works; its public IP is unknown — Mullvad's checker: $(oneline "${out:-no answer}")"; fi
        fi
    fi
}

# A service on gluetun's network reaches the internet only once the tunnel's
# DNS serves and its route holds: gluetun reports healthy before that (found
# by the soak, Oct 2026: right after the VPN group restarted, recyclarr got
# "Could not resolve host", then "Connection reset", wiped its guide copy and
# failed). Ready = a name resolves and HTTPS answers through the tunnel twice
# in a row; a service not on gluetun's network needs no wait. The probe asks
# for what recyclarr (the caller) fetches, not an address-lookup service: one
# rate-limited a shared VPN exit (HTTP 429, found live Oct 2026) and would
# have held recyclarr back on a healthy tunnel.
VPN_EGRESS_WAIT=120   # seconds
VPN_EGRESS_URL=https://github.com
vpn_egress_ready() { # vpn_egress_ready SVC -> 0 when SVC may go out; else a FAIL with the last error
    local who=$1 gcn t0 good=0 out=""
    render
    [[ "$(jq -r --arg s "$who" '.services[$s].network_mode // ""' <<<"$RENDERED_JSON")" == service:gluetun ]] || return 0
    gcn=$(svc_cname gluetun); t0=$(date +%s)
    while (( $(date +%s) - t0 < VPN_EGRESS_WAIT )); do
        if out=$(sudo docker exec "$gcn" wget -q --spider --timeout=8 "$VPN_EGRESS_URL" 2>&1); then
            good=$((good + 1)); (( good >= 2 )) && return 0
        else
            good=0
        fi
        sleep 5
    done
    out=$(oneline "${out:-no answer}")
    fail "$who: the tunnel still cannot reach the internet after ${VPN_EGRESS_WAIT}s (last: ${out% }) — not started. Check: ./mediastack.sh logs gluetun"
    return 1
}
