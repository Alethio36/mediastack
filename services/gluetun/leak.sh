#!/usr/bin/env bash
# services/gluetun/leak.sh — leak-test's checks (cmd_leak_test in vpn.sh runs
# them in order) and the record of this host's own address they compare the
# tunnel against. Sourced by the entrypoint; relies on lib/common.sh and
# oneline (lib/wire.sh) at call time.
#
# Verdicts — every check ends in exactly one of:
#   PASS      proven, with what was seen
#   FAIL      a leak, or a safeguard that is not in place — proven
#   UNPROVEN  the check could not run (a third party down or rate-limited, no
#             record of the host's address): never counted as a pass, always
#             says why, with the evidence
# leak-test exits 0 (all PASS), 1 (any FAIL) or 2 (no FAIL, something
# UNPROVEN): the caller decides what an unproven check means.
#
# Privacy — no party is asked about both of your addresses:
#   host side    RIPEstat: your address, its network (ASN) and that network's
#                IPv4 blocks, kept in local/host-identity, refreshed once a day
#   tunnel side  Mullvad's checker (the exit address), Google's resolver (the
#                UDP client subnet), bash.ws (which resolvers answer) — asked
#                from inside gluetun, so they only ever see the VPN's address
# The comparison is local: a tunnel address that is one of yours, or inside
# your network's blocks, is a leak. docs/privacy.md lists every flow.

LT_FAIL=0
LT_UNPROVEN=0
lt_reset()     { LT_FAIL=0; LT_UNPROVEN=0; }
lt_pass()      { ok "$*"; }
lt_fail()      { fail "$*"; LT_FAIL=$((LT_FAIL + 1)); }
lt_unproven()  { warn "UNPROVEN: $*"; LT_UNPROVEN=$((LT_UNPROVEN + 1)); }
lt_exit_code() { # 1 any FAIL, 2 no FAIL but something UNPROVEN, 0 all PASS
    if (( LT_FAIL )); then echo 1; elif (( LT_UNPROVEN )); then echo 2; else echo 0; fi
}

# the host tools the traffic checks read with — `install` adds them, uninstall
# removes them only if it added them (lib/footprint.sh: fp_leakcheck)
# shellcheck disable=SC2034  # read by lib/footprint.sh and lib/lifecycle.sh
LEAK_TOOLS="conntrack tcpdump"
leak_tool() { # leak_tool NAME -> 0 when present; otherwise UNPROVEN, naming the fix
    command -v "$1" >/dev/null 2>&1 && return 0
    lt_unproven "$2: $1 is not installed on this host — ./mediastack.sh install adds it (and uninstall removes it again)"
    return 1
}

# ------------------------------------------------------------- IPv4 math --
ip4_valid() { # ip4_valid A.B.C.D -> 0 when it is a dotted IPv4 address
    awk -F. 'NF == 4 { for (i = 1; i <= 4; i++) if ($i !~ /^[0-9]+$/ || $i > 255) exit 1; exit 0 } { exit 1 }' <<<"$1"
}
ip4_cidr_inside() { # ip4_cidr_inside A.B.C.D[/n] NET/m -> 0 when the address (or the whole block) lies inside NET/m
    local addr=${1%/*} n=${1#*/} m=${2#*/}
    [[ "$1" == */* ]] || n=32
    (( n >= m )) && printf '%s\n' "$2" | ip4_in_prefixes "$addr" >/dev/null
}
ip4_in_prefixes() { # ip4_in_prefixes IP < a.b.c.d/n lines -> 0 and the first prefix holding IP; 1 when none does
    awk -v ip="$1" '
        function toint(a,  p) { split(a, p, "."); return ((p[1] * 256 + p[2]) * 256 + p[3]) * 256 + p[4] }
        BEGIN { x = toint(ip) }
        /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/ {
            split($0, c, "/"); size = 2 ^ (32 - c[2])
            if (int(x / size) == int(toint(c[1]) / size)) { print; found = 1; exit }
        }
        END { exit !found }'
}

# ------------------------------------------------- this host's own address --
HOSTID_FILE="$LOCAL_DIR/host-identity"
HOSTID_REFRESH_AGE=86400    # refreshed when a day old
HOSTID_STALE_AGE=172800     # older than two days (refreshes failing): comparisons are UNPROVEN
HOSTID_KEEP_IPS=50          # every address the host has had, newest first: a leak on an old one still matches
RIPESTAT=https://stat.ripe.net/data
RIPESTAT_ERR=""
HOSTID_WHY=""

hostid_get() { # hostid_get KIND -> the record's values of that kind, one per line
    [[ -r "$HOSTID_FILE" ]] || return 0
    awk -v k="$1" '$1 == k { print $2 }' "$HOSTID_FILE"
}
hostid_age() { # seconds since the record was refreshed; "" when there is none
    local u; u=$(hostid_get updated)
    [[ "$u" =~ ^[0-9]+$ ]] && echo $(( $(date +%s) - u )) || true
}

RIPESTAT_BODY=""
ripestat() { # ripestat PATH — asked from the host (IPv4): the JSON answer in RIPESTAT_BODY; non-zero with the evidence in RIPESTAT_ERR
    local out code   # (globals, not stdout: a $( ) subshell would lose the error)
    RIPESTAT_BODY=""
    out=$(curl -4 -sS -m 15 -w '\n%{http_code}' "$RIPESTAT/$1" 2>&1) || { RIPESTAT_ERR="RIPEstat ${1%%/*}: $(oneline "${out%$'\n'*}")"; return 1; }
    code=${out##*$'\n'}; out=${out%$'\n'*}
    if [[ "$code" != 200 ]] || ! jq -e '.data' >/dev/null 2>&1 <<<"$out"; then
        RIPESTAT_ERR="RIPEstat ${1%%/*}: HTTP $code $(oneline "$out")"; return 1
    fi
    RIPESTAT_BODY=$out
}

hostid_ips_merged() { # hostid_ips_merged IP NOW -> the record's ip lines with IP seen NOW, newest first
    { awk '$1 == "ip"' "$HOSTID_FILE" 2>/dev/null || true; echo "ip $1 $2 $2"; } \
        | awk '{ if (!($2 in first) || $3 < first[$2]) first[$2] = $3; if ($4 > last[$2]) last[$2] = $4 }
               END { for (a in last) print "ip", a, first[a], last[a] }' \
        | sort -k4,4nr -k2,2 | head -n "$HOSTID_KEEP_IPS"
}

hostid_refresh() { # ask RIPEstat for this host's address, network and IPv4 blocks; rewrite the record. Non-zero with RIPESTAT_ERR
    local j ip asn own blocks now tmp
    ripestat "whats-my-ip/data.json" || return 1; j=$RIPESTAT_BODY
    ip=$(jq -r '.data.ip // empty' <<<"$j")
    ip4_valid "$ip" || { RIPESTAT_ERR="RIPEstat whats-my-ip: no IPv4 address in its answer ($(oneline "$j"))"; return 1; }
    ripestat "network-info/data.json?resource=$ip" || return 1; j=$RIPESTAT_BODY
    asn=$(jq -r '.data.asns[0] // empty' <<<"$j"); own=$(jq -r '.data.prefix // empty' <<<"$j")
    [[ "$asn" =~ ^[0-9]+$ ]] || { RIPESTAT_ERR="RIPEstat network-info: no network for this host's address ($(oneline "$j"))"; return 1; }
    ripestat "announced-prefixes/data.json?resource=AS$asn" || return 1; j=$RIPESTAT_BODY
    blocks=$( { jq -r '.data.prefixes[].prefix' <<<"$j"; echo "$own"; } \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' | sort -u || true)
    [[ -n "$blocks" ]] || { RIPESTAT_ERR="RIPEstat announced-prefixes: no IPv4 block for AS$asn"; return 1; }
    now=$(date +%s); tmp=$(mktemp)
    {
        echo "# mediastack: this host's own internet address, its network and that network's"
        echo "# IPv4 blocks — leak-test compares the tunnel against them (services/gluetun/leak.sh)."
        echo "# Private: never commit it, never paste it. Delete it and leak-test rebuilds it."
        echo "updated $now"
        echo "asn $asn"
        hostid_ips_merged "$ip" "$now"
        sed 's/^/prefix /' <<<"$blocks"
    } >"$tmp"
    mkdir -p "$LOCAL_DIR"; repo_owned "$LOCAL_DIR"
    install -m 600 "$tmp" "$HOSTID_FILE"; rm -f "$tmp"; repo_owned "$HOSTID_FILE"
}

hostid_ensure() { # refresh the record when a day old -> 0 usable; 1 with the reason in HOSTID_WHY
    local age; age=$(hostid_age)
    if [[ -z "$age" ]] || (( age >= HOSTID_REFRESH_AGE )); then
        if hostid_refresh; then info "record of this host's address refreshed (RIPEstat): your network has $(hostid_get prefix | wc -l) IPv4 blocks"
        else warn "record of this host's address not refreshed — $RIPESTAT_ERR"; fi
        age=$(hostid_age)
    fi
    if [[ -z "$age" ]]; then HOSTID_WHY="no record of this host's own address (${RIPESTAT_ERR:-never refreshed})"; return 1; fi
    if (( age >= HOSTID_STALE_AGE )); then HOSTID_WHY="the record of this host's own address is $(( age / 3600 ))h old ($RIPESTAT_ERR)"; return 1; fi
    return 0
}

# ------------------------------------------------- who the internet sees --
lt_tunnel_ip() { # lt_tunnel_ip GLUETUN HOSTID_OK — the exit address (Mullvad's checker, inside the tunnel) against the record
    local gcn=$1 hok=$2 out ip org m
    out=$(sudo docker exec "$gcn" wget -qO- --timeout=10 https://am.i.mullvad.net/json 2>&1) \
        || { lt_unproven "tunnel address: Mullvad's checker did not answer through the tunnel ($(oneline "$out"))"; return 0; }
    ip=$(jq -r '.ip // empty' <<<"$out" 2>/dev/null || true); org=$(jq -r '.organization // "?"' <<<"$out" 2>/dev/null || true)
    ip4_valid "$ip" || { lt_unproven "tunnel address: unreadable answer from Mullvad's checker ($(oneline "$out"))"; return 0; }
    (( hok )) || { lt_unproven "tunnel address $ip ($org) not compared: $HOSTID_WHY"; return 0; }
    if hostid_get ip | grep -qxF "$ip"; then
        lt_fail "tunnel address $ip is THIS HOST'S OWN address — traffic is leaving outside the VPN"
    elif m=$(hostid_get prefix | ip4_in_prefixes "$ip"); then
        lt_fail "tunnel address $ip is inside your own network's block $m — traffic is leaving outside the VPN"
    else
        lt_pass "tunnel exits at $ip ($org): not yours, outside your network's $(hostid_get prefix | wc -l) blocks"
    fi
}

lt_udp_identity() { # lt_udp_identity GLUETUN HOSTID_OK — Google's resolver, asked over plain UDP, names the subnet the query came from
    local gcn=$1 hok=$2 out net m
    out=$(sudo docker exec "$gcn" nslookup -type=txt o-o.myaddr.l.google.com 8.8.8.8 2>&1 || true)
    net=$(grep -oE 'edns0-client-subnet [0-9.]+/[0-9]+' <<<"$out" | awk '{ print $2; exit }' || true)
    [[ -n "$net" ]] || { lt_unproven "UDP exit: Google's resolver reported no client subnet ($(oneline "$out"))"; return 0; }
    (( hok )) || { lt_unproven "UDP exit $net not compared: $HOSTID_WHY"; return 0; }
    if m=$(hostid_get prefix | ip4_in_prefixes "${net%/*}"); then
        lt_fail "UDP leaves from $net, inside your own network's block $m — UDP (torrents' main protocol) bypasses the VPN"
    else
        lt_pass "UDP exits from $net: the VPN's side, not yours"
    fi
}

# --------------------------------------------------------------------- DNS --
lt_dns_config() { # lt_dns_config GLUETUN — gluetun's DNS as configured
    local gcn=$1 j env dns kind plain
    j=$(sudo docker inspect "$gcn" 2>&1) || { lt_unproven "DNS settings: cannot inspect $gcn ($(oneline "$j"))"; return 0; }
    dns=$(jq -r '.[0].HostConfig.Dns // [] | join(",")' <<<"$j")
    env=$(jq -r '.[0].Config.Env[]' <<<"$j")
    kind=$(sed -n 's/^DNS_UPSTREAM_RESOLVER_TYPE=//p' <<<"$env"); kind=${kind:-dot}   # gluetun's default
    kind=${kind,,}   # the image itself sets it as "DoT" (found live, Oct 2026)
    plain=$(sed -n 's/^DNS_UPSTREAM_PLAIN_ADDRESSES=//p' <<<"$env")
    # Docker's own resolver answers the namespace's container names; a name it
    # does not know it forwards to its upstream — the host's DNS, from the host
    # itself, unless gluetun's dns setting points that upstream back inside
    # (found live, Oct 2026: a short name left the host to the LAN router)
    if [[ "$dns" == 127.0.0.1 ]]; then lt_pass "DNS: names Docker does not know go back to gluetun, never to the host's DNS"   # addr-ok: a message, no address
    else lt_fail "DNS: gluetun's dns setting is '${dns:-unset}', not 127.0.0.1 — Docker forwards names it does not know to the host's DNS, outside the tunnel (services/gluetun/compose.yml sets it: check custom/override.yml)"; fi   # addr-ok: a message, no address
    case "$kind" in
        dot|doh) lt_pass "DNS: gluetun asks its upstream resolvers encrypted ($kind)" ;;
        *) lt_fail "DNS: gluetun's upstream is '$kind' — plaintext DNS can be read and changed on the VPN's path (remove DNS_UPSTREAM_RESOLVER_TYPE from your override)" ;;
    esac
    [[ -z "$plain" ]] || lt_fail "DNS: plaintext upstreams set (DNS_UPSTREAM_PLAIN_ADDRESSES=$plain) — a private address there sends every query outside the tunnel (gluetun's wiki)"
    if sudo docker exec "$gcn" sh -c 'grep -q "^nameserver 127.0.0.1" /etc/resolv.conf' 2>/dev/null; then   # addr-ok: gluetun's own resolver, read for the leak-test
        lt_pass "DNS: the namespace asks gluetun's own resolver"
    else
        lt_fail "DNS: the namespace's resolv.conf does not point at gluetun's resolver — queries may go to the LAN"
    fi
}

host_lan_resolvers() { # this host's DNS servers on a private network — where a stray query would go
    local f=/etc/resolv.conf
    [[ -r /run/systemd/resolve/resolv.conf ]] && f=/run/systemd/resolve/resolv.conf   # systemd-resolved: its real upstreams
    awk '$1 == "nameserver" { print $2 }' "$f" 2>/dev/null \
        | grep -E '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' || true
}

lt_dns_lan_path() { # lt_dns_lan_path GLUETUN — the namespace must route the host's LAN resolvers into the tunnel, never onto the LAN
    # Decided by the route, not by asking the resolver: something on the
    # tunnel's side answers port 53 for any private address, even one where
    # no resolver exists (found live, Oct 2026) — an answer proves nothing
    local gcn=$1 r out dev rs
    rs=$(host_lan_resolvers)
    [[ -n "$rs" ]] || { info "DNS: this host's resolvers are not on a private network — no LAN resolver to check"; return 0; }
    for r in $rs; do
        out=$(sudo docker exec "$gcn" ip route get "$r" 2>&1 || true)
        dev=$(grep -oE ' dev [^ ]+' <<<"$out" | awk '{ print $2; exit }' || true)
        case "$dev" in
            tun*|wg*) lt_pass "DNS: your LAN resolver $r is routed into the tunnel ($dev) from the namespace — never onto your LAN" ;;
            "") lt_unproven "DNS: no route read for your LAN resolver $r inside the namespace ($(oneline "$out"))" ;;
            *) lt_fail "DNS: the namespace routes your LAN resolver $r over $dev — a path for queries outside the tunnel (a FIREWALL_OUTBOUND_SUBNETS in your override?)" ;;
        esac
    done
}

lt_dns_resolvers() { # lt_dns_resolvers GLUETUN HOSTID_OK — bash.ws's extended test: ten never-seen names, every resolver that asked
    local gcn=$1 hok=$2 id i out json n bad who
    id=$(sudo docker exec "$gcn" wget -qO- --timeout=10 https://bash.ws/id 2>&1 || true)
    [[ "$id" =~ ^[0-9a-f]+$ ]] || { lt_unproven "DNS resolvers: bash.ws gave no test id ($(oneline "$id"))"; return 0; }
    # never-seen names: no cache can answer, so every resolver in the path shows
    for i in 1 2 3 4 5 6 7 8 9 10; do sudo docker exec "$gcn" nslookup "$i.$id.bash.ws" >/dev/null 2>&1 || true; done
    out=$(sudo docker exec "$gcn" wget -qO- --timeout=10 "https://bash.ws/dnsleak/test/$id?json" 2>&1 || true)
    json=$(jq -c '[.[] | select(.type == "dns")]' <<<"$out" 2>/dev/null || echo '[]')
    n=$(jq 'length' <<<"$json")
    (( n > 0 )) || { lt_unproven "DNS resolvers: bash.ws saw no resolver ($(oneline "$out"))"; return 0; }
    who=$(jq -r '[.[].asn | sub("^AS[0-9]+ *"; "")] | unique | join(", ")' <<<"$json")
    (( hok )) || { lt_unproven "DNS resolvers ($n: $who) not compared: $HOSTID_WHY"; return 0; }
    # bash.ws's own verdict line is not used: it flags any resolver outside the
    # exit's network, which encrypted DNS to a public resolver always is
    bad=$(jq -r --arg a "AS$(hostid_get asn)" '.[] | select((.asn | split(" ")[0]) == $a) | "\(.ip) (\(.asn))"' <<<"$json" | paste -sd, - || true)
    if [[ -n "$bad" ]]; then lt_fail "DNS: resolvers in your own network answered — $bad: queries leave outside the VPN"
    else lt_pass "DNS: $n resolver(s) answered ten never-seen names, none in your network ($who)"; fi
}

# ------------------------------------------------- the firewall, the traffic --
lt_ns_subnet() { # lt_ns_subnet GLUETUN -> the namespace's LAN-side subnet (eth0's), e.g. 172.31.250.0/24
    sudo docker exec "$1" ip -o -4 addr show dev eth0 2>/dev/null \
        | awk '{ split($4, a, "/"); split(a[1], o, "."); m = a[2]; ip = ((o[1]*256+o[2])*256+o[3])*256+o[4]
                 size = 2 ^ (32 - m); net = int(ip / size) * size
                 printf "%d.%d.%d.%d/%d\n", int(net/16777216)%256, int(net/65536)%256, int(net/256)%256, net%256, m; exit }'
}

LT_ENDPOINTS=""   # the VPN servers gluetun's firewall lets out on the LAN side (lt_firewall fills it)
lt_firewall() { # lt_firewall GLUETUN — every way out of the namespace: the policy DROP, and each ACCEPT accounted for
    # Through the tunnel, to loopback, replies to a connection already made,
    # into the namespace's own docker subnet, or to one VPN server (a single
    # address on one port): anything else out the LAN side is a path that
    # skips the tunnel. A rule this cannot read is UNPROVEN, shown as written.
    local gcn=$1 rules sub r d unknown=() bad=()
    LT_ENDPOINTS=""
    rules=$(sudo docker exec "$gcn" iptables -S OUTPUT 2>&1) || { lt_unproven "firewall: cannot read gluetun's rules ($(oneline "$rules"))"; return 0; }
    sub=$(lt_ns_subnet "$gcn")
    [[ -n "$sub" ]] || { lt_unproven "firewall: cannot read the namespace's own subnet (eth0)"; return 0; }
    if grep -qx -- '-P OUTPUT DROP' <<<"$rules"; then lt_pass "firewall: everything leaving the namespace is dropped unless a rule lets it out"
    else lt_fail "firewall: gluetun's outbound policy is not DROP ($(grep -- '^-P OUTPUT' <<<"$rules" | head -1)) — traffic no rule names leaves anyway"; fi
    while IFS= read -r r; do
        [[ "$r" == "-A OUTPUT "* && "$r" == *" -j ACCEPT"* ]] || continue
        d=$(grep -oE -- '-d [0-9./]+' <<<"$r" | awk '{print $2}' || true)
        if [[ "$r" == *" -o lo "* || "$r" =~ \ -o\ (tun|wg)[^\ ]*\  ]]; then continue
        elif [[ "$r" == *"--ctstate RELATED,ESTABLISHED"* && "$r" != *" -o "* ]]; then continue
        elif [[ "$r" == *" -o eth"* && -n "$d" ]] && ip4_cidr_inside "$d" "$sub"; then continue
        elif [[ "$r" == *" -o eth"* && "$d" == */32 && "$r" == *"--dport "* ]]; then LT_ENDPOINTS+="${d%/32} "
        elif [[ "$r" == *" -o eth"* ]]; then bad+=("$r")
        else unknown+=("$r"); fi
    done <<<"$rules"
    if (( ${#bad[@]} )); then lt_fail "firewall: lets traffic out the LAN side, past the tunnel: $(printf '%s; ' "${bad[@]}")(a FIREWALL_OUTBOUND_SUBNETS in your override?)"
    elif (( ${#unknown[@]} )); then lt_unproven "firewall: rules this check cannot account for: $(printf '%s; ' "${unknown[@]}")"
    elif [[ -z "$LT_ENDPOINTS" ]]; then lt_unproven "firewall: no VPN server among the rules — cannot tell the tunnel's own traffic from a leak"
    else lt_pass "firewall: out the LAN side only to the VPN server (${LT_ENDPOINTS% }) and the stack's own network ($sub)"; fi
}

lt_flows() { # lt_flows GLUETUN — the connections the host tracks from gluetun go only to the VPN server and the stack network
    local gcn=$1 gip sub out flows bad=() proto dst dport e ok
    leak_tool conntrack "traffic" || return 0
    [[ -n "$LT_ENDPOINTS" ]] || { lt_unproven "traffic: no VPN server known (the firewall check could not name one)"; return 0; }
    sub=$(lt_ns_subnet "$gcn"); gip=$(sudo docker exec "$gcn" ip -o -4 addr show dev eth0 2>/dev/null | awk '{ split($4, a, "/"); print a[1]; exit }')
    [[ -n "$gip" && -n "$sub" ]] || { lt_unproven "traffic: cannot read gluetun's own address"; return 0; }
    out=$(sudo conntrack -L -s "$gip" 2>/dev/null) || true
    flows=$(awk '{ d = ""; dp = "-"; for (i = 1; i <= NF; i++) { if ($i ~ /^dst=/ && d == "") d = substr($i, 5); if ($i ~ /^dport=/ && dp == "-") dp = substr($i, 7) }
                   if (d != "") print $1, d, dp }' <<<"$out" | sort -u)
    [[ -n "$flows" ]] || { lt_unproven "traffic: the host tracks no connection from gluetun ($gip) — not even the tunnel's"; return 0; }
    while read -r proto dst dport; do
        ok=0
        for e in $LT_ENDPOINTS; do [[ "$dst" == "$e" ]] && ok=1; done
        (( ok )) || ip4_cidr_inside "$dst" "$sub" || bad+=("$proto $dst:$dport")
    done <<<"$flows"
    if (( ${#bad[@]} )); then lt_fail "traffic: gluetun's address is talking past the tunnel — ${bad[*]}"
    else lt_pass "traffic: every connection the host tracks from gluetun goes to the VPN server or the stack's own network ($(wc -l <<<"$flows") seen)"; fi
}

lt_dns_host_path() { # lt_dns_host_path GLUETUN — a name nobody knows, looked up inside the namespace, must never leave the host as a query
    # The path found live (Oct 2026): gluetun hands a short name to Docker's
    # resolver, which asks the host's own DNS, from the host — outside the
    # tunnel, where no firewall in the namespace can see it. Watched from the
    # host, which is the only place it shows.
    local gcn=$1 name cap err pid n
    leak_tool tcpdump "DNS outside the tunnel" || return 0
    name="leaktest$RANDOM$RANDOM"; cap=$(mktemp); err=$(mktemp)
    # shellcheck disable=SC2024  # the capture lands in our own temp files, read below
    sudo timeout 10 tcpdump -lni any 'port 53' >"$cap" 2>"$err" & pid=$!
    for n in 1 2 3 4 5 6 7 8 9 10; do grep -q 'listening on' "$err" && break; sleep 0.5; done
    if ! grep -q 'listening on' "$err"; then
        lt_unproven "DNS outside the tunnel: the capture did not start ($(oneline "$(cat "$err")"))"
        wait "$pid" 2>/dev/null || true; rm -f "$cap" "$err"; return 0
    fi
    sudo docker exec "$gcn" nslookup "$name" >/dev/null 2>&1 || true
    sudo docker exec "$gcn" nslookup "$name.example.com" >/dev/null 2>&1 || true
    wait "$pid" 2>/dev/null || true
    n=$(grep -c -- "$name" "$cap" || true)
    if (( n > 0 )); then lt_fail "DNS outside the tunnel: a lookup inside the namespace left the host as a query ($(oneline "$(grep -- "$name" "$cap" | head -1)"))"
    else lt_pass "DNS outside the tunnel: names nobody knows, looked up inside the namespace, never left the host"; fi
    rm -f "$cap" "$err"
}

# ------------------------------------------------------------------ the rest --
lt_control_server() { # lt_control_server GLUETUN — gluetun's control API: refused from the stack network, a password inside
    local gcn=$1 r code rc out
    r=$(sudo docker run --rm --network mediastack curlimages/curl:latest \
        -s -o /dev/null -m 5 -w '%{http_code} %{exitcode}' http://gluetun:8008/v1/vpn/status 2>/dev/null || true)   # addr-ok: gluetun's control server, probed from the stack network
    code=${r% *}; rc=${r#* }
    case "$code:$rc" in
        000:7) lt_pass "control server: refused from the stack network (bound to gluetun's own localhost)" ;;   # addr-ok: a message, no address
        000:*) lt_unproven "control server: the probe from the stack network ended unclear (curl exit ${rc:-none}: 6 = gluetun's name unresolved, 28 = timeout)" ;;
        *) lt_fail "control server: answers the whole stack network (HTTP $code) — any container can reach the VPN's controls (HTTP_CONTROL_SERVER_ADDRESS must be 127.0.0.1:8008)" ;;   # addr-ok: a message, no address
    esac
    out=$(sudo docker exec "$gcn" wget -qS -O /dev/null --timeout=5 http://127.0.0.1:8008/v1/vpn/status 2>&1 || true)   # addr-ok: gluetun's control server, probed from inside its namespace
    if grep -q ' 401' <<<"$out"; then lt_pass "control server: asks for credentials from inside the namespace (401)"
    elif grep -q ' 200' <<<"$out"; then lt_fail "control server: answers WITHOUT credentials from inside the namespace (HTTP 200) — gluetun's auth default changed"
    else lt_unproven "control server: no readable answer from inside the namespace ($(oneline "$out"))"; fi
}

lt_ipv6() { # lt_ipv6 GLUETUN — only meaningful where the host has IPv6 to leak
    local gcn=$1
    if ! ip -6 route show default 2>/dev/null | grep -q .; then
        info "IPv6: this host has no IPv6 route — nothing to leak (not tested)"; return 0
    fi
    if sudo docker run --rm --network "container:$gcn" curlimages/curl:latest -6 -fsS -m 8 -o /dev/null https://ipv6.google.com >/dev/null 2>&1; then
        lt_fail "IPv6 egress SUCCEEDED inside the tunnel's namespace — IPv6 leaks past the VPN"
    else
        lt_pass "IPv6: the host has it, the tunnel's namespace has none"
    fi
}
