#!/usr/bin/env bash
# lib/vpn.sh — everything about the gluetun tunnel: the reattach guard (script
# paths) and its boot unit (daemon/boot paths), the leak-test, and per-service
# VPN membership (vpn_gen renders local/vpn-overlay.yml; the vpn/vpn-apply
# verbs). Sourced by the entrypoint; relies on lib/common.sh and the
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
# every cmd_up so a removed unit reappears.
VPNGUARD_UNIT=/etc/systemd/system/mediastack-vpnguard.service

vpnguard_ensure() {
    # Write/refresh the boot-guard unit. Cheap and idempotent; only reloads
    # systemd when the file actually changed, to avoid needless daemon-reloads
    # on every up.
    local tmp; tmp=$(mktemp)
    cat >"$tmp" <<EOF
[Unit]
Description=Mediastack VPN attachment guard (boot/daemon)
After=docker.service
Requires=docker.service
[Service]
Type=oneshot
WorkingDirectory=$SCRIPT_DIR
ExecStart=$SCRIPT_DIR/mediastack.sh vpn-guard --boot
[Install]
WantedBy=multi-user.target
EOF
    if ! sudo cmp -s "$tmp" "$VPNGUARD_UNIT" 2>/dev/null; then
        sudo cp "$tmp" "$VPNGUARD_UNIT"
        sudo systemctl daemon-reload
        sudo systemctl enable mediastack-vpnguard.service >/dev/null 2>&1 || true
        info "VPN boot-guard unit installed/updated"
    fi
    rm -f "$tmp"
}

cmd_vpn_guard() {
    load_env
    local boot=0; [[ "${1:-}" == --boot ]] && boot=1
    # On boot, docker starts containers asynchronously — gluetun may not be
    # healthy yet. Wait (bounded) before judging attachment, or we would race
    # the very startup we are guarding and falsely repair/​fail. Mirrors cmd_up's
    # gluetun health-race handling.
    local gcn t=0; gcn=$(svc_cname gluetun)
    if [[ $(c_state "$gcn") == absent ]]; then
        (( boot )) && { info "vpn-guard: gluetun not present — stack not up, nothing to guard"; return 0; }
        die "vpn-guard: gluetun container not found — is the stack up?"
    fi
    while [[ $(c_health "$gcn") != healthy && $t -lt 120 ]]; do sleep 5; t=$((t+5)); done
    [[ $(c_health "$gcn") == healthy ]] \
        || { warn "vpn-guard: gluetun not healthy after ${t}s — deferring (next boot/up will retry)"; return 0; }
    vpn_reattach_guard
}

# --------------------------------------------------------------- leak-test --
cmd_leak_test() {
    load_env
    local killswitch=0; [[ "${1:-}" == --killswitch ]] && killswitch=1
    local gcn; gcn=$(svc_cname gluetun)
    c_inspect_all
    [[ "$(c_state "$gcn")" == running ]] || die "gluetun is not running — start the stack first."

    hr "leak-test: attachment audit"
    # Netns-joined containers report an EMPTY SandboxKey, so key equality can
    # never verify the join. The truth is NetworkMode: docker enforces
    # container:<id> joins atomically — matching gluetun's full ID is proof.
    local gid rc=0 s cn nm
    gid=$(c_id "$gcn")
    for s in $(svc_managed_where mediastack.vpn true); do
        svc_enabled "$s" || continue
        cn=$(svc_cname "$s"); [[ "$(c_state "$cn")" == running ]] || { info "$s not running — skipped"; continue; }
        nm=$(c_netmode "$cn")
        if [[ "$nm" == "container:$gid" ]]; then ok "$s routed through the gluetun tunnel"
        else fail "$s is NOT joined to gluetun (mode: ${nm:0:40}...) — this IS a leak path"; rc=1; fi
    done

    hr "leak-test: tunnel identity (one test — all VPN'd services share this namespace)"
    local hostip vinfo vip vcc
    hostip=$(curl -fsS --max-time 8 https://ipinfo.io/ip 2>/dev/null || echo unknown)
    vinfo=$(sudo docker run --rm --network "container:$gcn" curlimages/curl:latest \
            -fsS --max-time 10 https://ipinfo.io/json 2>/dev/null || true)
    vip=$(jq -r '.ip // empty' <<<"$vinfo"); vcc=$(jq -r '.country // "?"' <<<"$vinfo")
    if [[ -z "$vip" ]]; then fail "no egress through the tunnel — VPN down?"; rc=1
    elif [[ "$vip" == "$hostip" ]]; then fail "tunnel IP equals host WAN IP ($vip) — traffic is NOT going through the VPN"; rc=1
    else ok "tunnel IP $vip ($vcc) != host IP $hostip"; fi
    # IPv6 egress must fail
    if sudo docker run --rm --network "container:$gcn" curlimages/curl:latest \
         -6 -fsS --max-time 8 https://ipv6.google.com >/dev/null 2>&1; then
        fail "IPv6 egress SUCCEEDED inside the tunnel namespace — IPv6 leak"; rc=1
    else ok "no IPv6 egress"; fi
    # resolver identity: queries must go to gluetun's local resolver (which
    # forwards over the tunnel), not a LAN/ISP resolver
    if sudo docker exec "$gcn" sh -c 'grep -q "nameserver 127.0.0.1" /etc/resolv.conf' 2>/dev/null; then
        ok "DNS goes to gluetun's own resolver — queries ride the tunnel"
    else
        warn "resolv.conf inside the namespace is not gluetun's resolver — DNS may leak to the LAN (check DNS settings in gluetun)"
    fi
    # interface audit: the namespace must hold exactly lo + one LAN-side
    # interface + the tunnel. A second ethN means another docker network is
    # attached — the "accidentally on another network" case.
    local links eth_n
    links=$(sudo docker exec "$gcn" ip -o link 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1 | grep -v '^lo$' || true)
    eth_n=$(grep -c '^eth' <<<"$links" || true)
    if [[ "$eth_n" == 1 ]]; then ok "exactly one LAN-side interface in the namespace"
    else fail "unexpected interface set in namespace: $(tr '\n' ' ' <<<"$links") — a second network is attached"; rc=1; fi
    grep -qE '^(tun|wg)' <<<"$links" && ok "tunnel interface present" \
        || { fail "no tunnel interface in the namespace"; rc=1; }

    hr "leak-test: kill-switch"
    sudo docker exec "$gcn" sh -c 'iptables -S OUTPUT 2>/dev/null | grep -qE -- "^-P OUTPUT DROP|-j DROP"' \
        && ok "firewall DROP rules present in gluetun" \
        || warn "could not confirm firewall rules (gluetun still defaults fail-closed)"
    if (( killswitch )); then
        warn "Disruptive proof: dropping the tunnel interface for ~10s..."
        sudo docker exec "$gcn" sh -c 'ip link set dev tun0 down' || true
        if sudo docker run --rm --network "container:$gcn" curlimages/curl:latest \
             -fsS --max-time 6 https://ipinfo.io/ip >/dev/null 2>&1; then
            fail "egress SUCCEEDED with the tunnel down — kill-switch NOT working"; rc=1
        else ok "egress blocked with tunnel down — kill-switch works"; fi
        sudo docker exec "$gcn" sh -c 'ip link set dev tun0 up' || true
        info "Restarting gluetun to restore a clean tunnel..."
        DC restart gluetun >/dev/null

        warn "Hard-stop proof: stopping gluetun ENTIRELY (~30s of downtime)..."
        sudo docker stop "$gcn" >/dev/null; INSPECT_JSON=""
        local pcn; pcn=$(svc_cname qbittorrent)
        if [[ $(c_state "$pcn") == running ]]; then
            if sudo docker exec "$pcn" curl -fsS --max-time 6 https://ipinfo.io/ip >/dev/null 2>&1; then
                fail "egress SUCCEEDED from a dependent with gluetun STOPPED — containment broken"; rc=1
            else ok "zero egress from dependents with gluetun dead (namespace has no interfaces — fail-safe)"; fi
            if sudo docker exec "$pcn" sh -c 'ip route 2>/dev/null | grep -q default'; then
                fail "a default route appeared inside the dead namespace"; rc=1
            else ok "no fallback route appeared — docker cannot re-home a joined container"; fi
        else info "qbittorrent not running — hard-stop probe skipped"; fi
        info "Restarting gluetun and re-joining dependents..."
        sudo docker start "$gcn" >/dev/null; INSPECT_JSON=""
        local t=0; while [[ $(c_health "$gcn") != healthy && $t -lt 90 ]]; do sleep 3; t=$((t+3)); done
        local rs
        for rs in $(svc_managed_where mediastack.vpn true); do
            svc_enabled "$rs" || continue
            # shellcheck disable=SC2034  # the inspect cache lives in the entrypoint (CACHE RULE at c_inspect)
            INSPECT_JSON=""; sudo docker restart "$(svc_cname "$rs")" >/dev/null && info "  rejoined: $rs"
        done
    fi

    hr "leak-test: host port sweep"
    for s in $(svc_managed_where mediastack.vpn true); do
        render
        jq -e --arg s "$s" '.services[$s].ports // [] | length == 0' <<<"$RENDERED_JSON" >/dev/null \
            && ok "$s publishes no ports of its own" \
            || { fail "$s publishes host ports directly — must go through gluetun"; rc=1; }
    done
    echo
    (( rc == 0 )) && ok "leak-test passed." || { fail "leak-test FOUND PROBLEMS — see above."; exit 1; }
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
VPN_TORRENT_CLIENTS="qbittorrent deluge transmission"

vpn_rname() { echo "$1" | tr -cd 'a-z0-9'; }   # compose svc name -> traefik router name
vpn_onoff() { [[ "$1" == true ]] && echo "on" || echo "off"; }   # membership -> on/off

vpn_base_json() {   # base compose ONLY — never include the overlay (no self-reference)
    # The user's override IS base: a toggle-enabled service scaffolded there
    # must be seen, or vpn_gen never generates its network/port/route. An
    # explicit -f disables compose's automatic override merge, so pass it.
    local files=(-f docker-compose.yml)
    [[ -e docker-compose.override.yml ]] && files+=(-f docker-compose.override.yml)
    sudo docker compose --project-directory "$SCRIPT_DIR" "${files[@]}" \
        --profile "*" config --format json 2>/dev/null
}

vpn_effective() {   # vpn_effective <svc> <default> -> true|false
    local v; v=$(env_get "$(uvar "$1")_VPN")
    [[ -n "$v" ]] && { echo "$v"; return; }
    echo "$2"
}

vpn_traefik_labels() {   # <indent> <rname> <sub> <cport> <stem>  (router/service only)
    local i="$1" r="$2" sub="$3" cp="$4" stem="$5"
    echo "${i}traefik.http.routers.${r}.rule: \"Host(\`\${${stem}_HOST:-${sub}}.\${TRAEFIK_DOMAIN:-unset.invalid}\`)\""
    echo "${i}traefik.http.routers.${r}.entrypoints: \"websecure\""
    echo "${i}traefik.http.routers.${r}.tls: \"true\""
    echo "${i}traefik.http.routers.${r}.service: \"${r}\""
    echo "${i}traefik.http.services.${r}.loadbalancer.server.port: \"${cp}\""
}

vpn_gen() {
    install -d -m 755 local
    local bj; bj=$(vpn_base_json) || die "vpn: could not read base compose config"
    local svcs
    svcs=$(jq -r '.services | to_entries[]
        | select(.value.labels["mediastack.vpntoggle"]=="true") | .key' <<<"$bj" | sort)
    # Build the three sections up front so empty ones can be omitted (an empty
    # `ports:`/`labels:` mapping is invalid YAML) and traefik.enable is emitted
    # exactly once per container (never duplicated as a mapping key).
    local gports="" glabels="" stanzas="" s stem cport sub rname defv eff hp
    for s in $svcs; do
        stem=$(uvar "$s"); rname=$(vpn_rname "$s")
        cport=$(jq -r --arg s "$s" '.services[$s].labels["mediastack.port"] // ""' <<<"$bj")
        sub=$(jq -r --arg s "$s" '.services[$s].labels["mediastack.subdomain"] // ""' <<<"$bj")
        defv=$(jq -r --arg s "$s" '.services[$s].labels["mediastack.vpn"] // "false"' <<<"$bj")
        # hostport=false => traefik-only, no host port published (serving apps
        # whose container port would collide on the host, e.g. :80 vs Traefik).
        # Default true preserves direct host access for the acquisition apps.
        hp=$(jq -r --arg s "$s" '.services[$s].labels["mediastack.hostport"] // "true"' <<<"$bj")
        [[ -n "$cport" ]] || die "vpn: $s carries no mediastack.port label"
        [[ -n "$sub"   ]] || die "vpn: $s carries no mediastack.subdomain label"
        eff=$(vpn_effective "$s" "$defv")
        if [[ "$eff" == true ]]; then
            [[ "$hp" != false ]] && gports+="      - \"\${${stem}_PORT:-${cport}}:${cport}\""$'\n'
            glabels+="$(vpn_traefik_labels "      " "$rname" "$sub" "$cport" "$stem")"$'\n'
            stanzas+="  ${s}:"$'\n'"    network_mode: \"service:gluetun\""$'\n'
            stanzas+="    depends_on:"$'\n'"      gluetun:"$'\n'"        condition: service_healthy"$'\n'
            stanzas+="    labels:"$'\n'"      mediastack.vpn: \"true\""$'\n'
        else
            [[ " $VPN_TORRENT_CLIENTS " == *" $s "* ]] \
                && warn "vpn: $s (torrent client) is OUTSIDE the VPN — its traffic exits on the host IP"
            stanzas+="  ${s}:"$'\n'"    networks: [mediastack]"$'\n'
            [[ "$hp" != false ]] && stanzas+="    ports:"$'\n'"      - \"\${${stem}_PORT:-${cport}}:${cport}\""$'\n'
            stanzas+="    labels:"$'\n'"      mediastack.vpn: \"false\""$'\n'"      traefik.enable: \"true\""$'\n'
            stanzas+="$(vpn_traefik_labels "      " "$rname" "$sub" "$cport" "$stem")"$'\n'
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
            echo "  gluetun:"
            [[ -n "$gports"  ]] && { echo "    ports:";  printf '%s' "$gports"; }
            [[ -n "$glabels" ]] && { echo "    labels:"; printf '%s' "$glabels"; }
        fi
        printf '%s' "$stanzas"
    } > "$tmp"
    if ! cmp -s "$tmp" local/vpn-overlay.yml 2>/dev/null; then
        mv "$tmp" local/vpn-overlay.yml
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
        || die "vpn: '$svc' is not toggle-enabled (no mediastack.vpntoggle label — not yet migrated to the generated model)."
    local stem target; stem=$(uvar "$svc")
    case "$act" in
        on|true)   target=true ;;
        off|false)
            if [[ " $VPN_TORRENT_CLIENTS " == *" $svc "* && $iknow -ne 1 ]]; then
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
    if [[ "$target" == "$default" ]]; then
        env_del "${stem}_VPN"; how="matches default"
    else
        env_set "${stem}_VPN" "$target"; how="override"
    fi
    vpn_gen
    ok "vpn: $svc $act ($how) — regenerated local/vpn-overlay.yml. Apply with: ./mediastack.sh up"
}
