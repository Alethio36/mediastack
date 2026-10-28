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
# membership, <SVC>_VPN overrides included), compare each running one's
# NetworkMode to the live gluetun's full ID (leak-test's proof), and
# force-recreate any that drifted. Loud on drift, self-heals, dies only if a
# re-pin fails to take. Stopped dependents are skipped — doctor/leak-test
# catch them when started. Called from cmd_up and cmd_update so neither path
# can leave a ghost behind.
vpn_reattach_guard() {
    render; c_inspect_all
    local gid vd nm vdeps=() stale=()
    mapfile -t vdeps < <(jq -r '.services | to_entries[]
        | select((.value.network_mode // "") == "service:gluetun") | .key' \
        <<<"$RENDERED_JSON" | sort)
    (( ${#vdeps[@]} )) || { warn "vpn guard: no service:gluetun dependents in the rendered config — nothing to verify"; return 0; }
    gid=$(c_id "$(svc_cname gluetun)")
    [[ -n "$gid" ]] || die "vpn guard: cannot resolve the live gluetun container — VPN attachment unverifiable. Inspect gluetun, then re-run."
    for vd in "${vdeps[@]}"; do
        [[ "$(c_state "$(svc_cname "$vd")")" == running ]] || continue
        nm=$(c_netmode "$(svc_cname "$vd")")
        [[ "$nm" == "container:$gid" ]] || stale+=("$vd")
    done
    if (( ${#stale[@]} )); then
        warn "gluetun was recreated — dependents still joined to the old gluetun (dead tunnel): ${stale[*]}"
        info "re-pinning them onto the live gluetun..."
        DC up -d --force-recreate --no-deps "${stale[@]}"
        for vd in "${stale[@]}"; do
            nm=$(c_netmode "$(svc_cname "$vd")")
            [[ "$nm" == "container:$gid" ]] && continue
            notify ops "Mediastack VPN re-pin FAILED" "VPN dependents detached from gluetun and re-pin FAILED: **${stale[*]}**"$'\n'"Fix now: \`./mediastack.sh up\` then \`./mediastack.sh leak-test\`" failure
            die "vpn guard: $vd is still not joined to the live gluetun after recreate — VPN egress is broken. Fix this before anything else."
        done
        ok "re-pinned ${#stale[@]} dependent(s) onto the live gluetun"
    fi
    ok "VPN attachment verified: ${#vdeps[@]} dependent(s) on the live gluetun"
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
# The checks and their verdicts (PASS / FAIL / UNPROVEN) are in leak.sh; this
# runs them in order. Exit 0 all proven, 1 a leak or a missing safeguard, 2
# nothing failed but something could not be proven.
cmd_leak_test() {
    load_env
    local killswitch=0; [[ "${1:-}" == --killswitch ]] && killswitch=1
    local gcn; gcn=$(svc_cname gluetun)
    c_inspect_all
    [[ "$(c_state "$gcn")" == running ]] || die "gluetun is not running — start the stack first."
    lt_reset

    hr "leak-test: attachment audit"
    # Netns-joined containers report an EMPTY SandboxKey, so key equality can
    # never verify the join. The truth is NetworkMode: docker enforces
    # container:<id> joins atomically — matching gluetun's full ID is proof.
    local gid s cn nm
    gid=$(c_id "$gcn")
    for s in $(svc_managed_where mediastack.vpn true); do
        svc_enabled "$s" || continue
        cn=$(svc_cname "$s"); [[ "$(c_state "$cn")" == running ]] || { info "$s not running — skipped"; continue; }
        nm=$(c_netmode "$cn")
        if [[ "$nm" == "container:$gid" ]]; then lt_pass "$s routed through the gluetun tunnel"
        else lt_fail "$s is NOT joined to gluetun (mode: ${nm:0:40}...) — this IS a leak path"; fi
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
    lt_ipv6 "$gcn"

    hr "leak-test: who the internet sees"
    local hok=0
    hostid_ensure && hok=1
    lt_tunnel_ip "$gcn" "$hok"
    lt_udp_identity "$gcn" "$hok"

    hr "leak-test: DNS"
    lt_dns_config "$gcn"
    lt_dns_lan_path "$gcn"
    lt_dns_resolvers "$gcn" "$hok"

    hr "leak-test: gluetun's control server"
    lt_control_server "$gcn"

    hr "leak-test: kill-switch"
    if sudo docker exec "$gcn" sh -c 'iptables -S OUTPUT 2>/dev/null | grep -qE -- "^-P OUTPUT DROP|-j DROP"'; then
        lt_pass "firewall DROP rules present in gluetun"
    else
        lt_unproven "could not read gluetun's firewall rules (gluetun still defaults fail-closed)"
    fi
    if (( killswitch )); then
        warn "Disruptive proof: dropping the tunnel interface for ~10s..."
        sudo docker exec "$gcn" sh -c 'ip link set dev tun0 down' || true
        if sudo docker run --rm --network "container:$gcn" curlimages/curl:latest \
             -fsS --max-time 6 https://github.com -o /dev/null >/dev/null 2>&1; then
            lt_fail "egress SUCCEEDED with the tunnel down — kill-switch NOT working"
        else lt_pass "egress blocked with tunnel down — kill-switch works"; fi
        sudo docker exec "$gcn" sh -c 'ip link set dev tun0 up' || true
        info "Restarting gluetun to restore a clean tunnel..."
        DC restart gluetun >/dev/null

        warn "Hard-stop proof: stopping gluetun ENTIRELY (~30s of downtime)..."
        sudo docker stop "$gcn" >/dev/null; INSPECT_JSON=""
        local pcn; pcn=$(svc_cname qbittorrent)
        if [[ $(c_state "$pcn") == running ]]; then
            if sudo docker exec "$pcn" curl -fsS --max-time 6 https://github.com -o /dev/null >/dev/null 2>&1; then
                lt_fail "egress SUCCEEDED from a dependent with gluetun STOPPED — containment broken"
            else lt_pass "zero egress from dependents with gluetun dead (namespace has no interfaces — fail-safe)"; fi
            if sudo docker exec "$pcn" sh -c 'ip route 2>/dev/null | grep -q default'; then
                lt_fail "a default route appeared inside the dead namespace"
            else lt_pass "no fallback route appeared — docker cannot re-home a joined container"; fi
        else info "qbittorrent not running — hard-stop probe skipped"; fi
        info "Restarting gluetun and re-joining dependents..."
        sudo docker start "$gcn" >/dev/null; INSPECT_JSON=""
        wait_verdict --recover gluetun \
            || warn "gluetun ${VERDICT_WHY[gluetun]} — rejoining its dependents anyway; if they stay dead: ./mediastack.sh up"
        local rs
        for rs in $(svc_managed_where mediastack.vpn true); do
            svc_enabled "$rs" || continue
            # shellcheck disable=SC2034  # the inspect cache lives in the entrypoint (CACHE RULE at c_inspect)
            INSPECT_JSON=""; sudo docker restart "$(svc_cname "$rs")" >/dev/null && info "  rejoined: $rs"
        done
    fi

    hr "leak-test: host port sweep"
    render
    for s in $(svc_managed_where mediastack.vpn true); do
        if jq -e --arg s "$s" '.services[$s].ports // [] | length == 0' <<<"$RENDERED_JSON" >/dev/null; then
            lt_pass "$s publishes no ports of its own"
        else lt_fail "$s publishes host ports directly — must go through gluetun"; fi
    done

    echo
    case $(lt_exit_code) in
        0) ok "leak-test passed: every check proven." ;;
        1) fail "leak-test FOUND PROBLEMS: $LT_FAIL check(s) failed — see above."; exit 1 ;;
        *) warn "leak-test: no leak found, but $LT_UNPROVEN check(s) UNPROVEN — see above. Not a pass."; exit 2 ;;
    esac
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
        local dgid dnm dbad="" dchecked=0
        dgid=$(c_id "$(svc_cname gluetun)")
        for s in $(svc_managed_where mediastack.vpn true); do
            svc_enabled "$s" || continue
            [[ $(c_state "$(svc_cname "$s")") == running ]] || continue
            dnm=$(c_netmode "$(svc_cname "$s")")
            dchecked=1
            [[ "$dnm" == "container:$dgid" ]] || dbad+="$s "
        done
        if (( dchecked == 0 )); then info "no running VPN'd services to audit"
        elif [[ -z "$dbad" ]]; then ok "all VPN'd services routed through the gluetun tunnel"
        else d_fail "VPN'd services NOT attached to gluetun: $dbad" "their traffic bypasses the VPN entirely" "./mediastack.sh up   (recreates with correct attachment), then ./mediastack.sh leak-test"; fi   # addr-ok: a message, no address
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
