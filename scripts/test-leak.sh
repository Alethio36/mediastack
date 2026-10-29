#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-leak.sh — leak-test's checks (services/gluetun/leak.sh):
#   * the IPv4 math: a valid address, an address inside a block or not
#   * the record of the host's own address: every address it has had, newest
#     first; refreshed from RIPEstat when a day old; too old = UNPROVEN, never
#     a pass
#   * verdicts: 0 all PASS, 1 any FAIL, 2 nothing failed but something UNPROVEN
#   * each check's three outcomes: the tunnel address (Mullvad's checker), the
#     UDP client subnet (Google's resolver), the resolvers (bash.ws), the DNS
#     settings (gluetun's dns, encrypted upstream — the image's own "DoT" — no
#     plaintext one), the LAN resolvers routed into the tunnel, the control
#     server (refused from the network, 401 inside)
#   * migration 36 -> 37: VPN_DNS_ADDRESS retired (a value is named), the
#     resolvers' setting added
# Sources the real entrypoint (minus its last line, main "$@"); docker, curl
# and the clock are stubs — no network.
#
#   scripts/test-leak.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-leak.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"
set +e +E; trap - ERR   # each check reads its own status

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

# ---- IPv4 math ----
ip4_valid 203.0.113.9 || fail_ "a dotted address is valid"; pass
for bad in "" 203.0.113 203.0.113.256 2400:cb00::1 "a.b.c.d"; do
    ip4_valid "$bad" && fail_ "'$bad' is not an IPv4 address"; pass
done
m=$(printf '10.0.0.0/8\n198.51.100.0/22\n' | ip4_in_prefixes 198.51.103.200) || fail_ "inside a /22"; pass
[[ "$m" == 198.51.100.0/22 ]] || fail_ "names the block it is in ($m)"; pass
printf '198.51.100.0/22\n' | ip4_in_prefixes 198.51.104.1 >/dev/null && fail_ "just past the /22: outside"; pass
printf '0.0.0.0/0\n' | ip4_in_prefixes 255.255.255.255 >/dev/null || fail_ "a /0 holds everything"; pass
printf '203.0.113.9/32\n' | ip4_in_prefixes 203.0.113.9 >/dev/null || fail_ "a /32 holds its one address"; pass
printf '2001:db8::/32\nnot-a-prefix\n' | ip4_in_prefixes 203.0.113.9 >/dev/null && fail_ "IPv6 and junk lines never match"; pass

# ---- the host record ----
LOCAL_DIR="$T/local"; HOSTID_FILE="$LOCAL_DIR/host-identity"
NOW=1000000
date() { [[ "${1:-}" == +%s ]] && echo "$NOW" || command date "$@"; }
RIPE_IP=198.51.100.7 RIPE_ASN=64500 RIPE_FAIL=""
curl() { # curl -4 -sS -m 15 -w ... URL: RIPEstat's three answers, then the HTTP code
    local url=${*: -1}
    [[ -n "$RIPE_FAIL" ]] && { printf 'curl: (6) Could not resolve host: stat.ripe.net\n000'; return 6; }
    case "$url" in
        */whats-my-ip/*)         printf '{"data":{"ip":"%s"}}\n200' "$RIPE_IP" ;;
        */network-info/*)        printf '{"data":{"asns":["%s"],"prefix":"198.51.100.0/24"}}\n200' "$RIPE_ASN" ;;
        */announced-prefixes/*)  printf '{"data":{"prefixes":[{"prefix":"198.51.100.0/22"},{"prefix":"2001:db8::/32"}]}}\n200' ;;
    esac
}
hostid_get asn | grep -q . && fail_ "no record yet: nothing to read"; pass
[[ -z "$(hostid_age)" ]] || fail_ "no record: no age"; pass
hostid_ensure > "$T/out" 2>&1 || fail_ "first run: refreshed and usable — $(cat "$T/out")"; pass
[[ "$(hostid_get asn)" == 64500 ]] || fail_ "the network is recorded"; pass
[[ "$(hostid_get prefix | sort | paste -sd' ')" == "198.51.100.0/22 198.51.100.0/24" ]] || fail_ "IPv4 blocks only, the host's own included ($(hostid_get prefix | paste -sd' '))"; pass
[[ "$(stat -c %a "$HOSTID_FILE")" == 600 ]] || fail_ "the record is private (600)"; pass
NOW=$((NOW + 3600)); RIPE_IP=198.51.101.9
hostid_ensure > /dev/null 2>&1; [[ "$(hostid_get ip | paste -sd' ')" == "198.51.100.7" ]] || fail_ "an hour later: not refreshed"; pass
NOW=$((NOW + HOSTID_REFRESH_AGE))
hostid_ensure > /dev/null 2>&1 || fail_ "a day later: refreshed"; pass
[[ "$(hostid_get ip | paste -sd' ')" == "198.51.101.9 198.51.100.7" ]] || fail_ "a new address joins, newest first, the old one kept ($(hostid_get ip | paste -sd' '))"; pass
NOW=$((NOW + HOSTID_REFRESH_AGE)); RIPE_FAIL=1
hostid_ensure > "$T/out" 2>&1 || fail_ "a failed refresh within two days: the record still serves"; pass
grep -qE "not refreshed — RIPEstat whats-my-ip: curl: \(6\) Could not resolve host: stat.ripe.net ?$" "$T/out" || fail_ "and says why, with the evidence, nothing after it — $(cat "$T/out")"; pass
NOW=$((NOW + HOSTID_STALE_AGE))
hostid_ensure > /dev/null 2>&1 && fail_ "refreshes failing past two days: unusable"; pass
[[ "$HOSTID_WHY" == *"h old (RIPEstat whats-my-ip: curl: (6)"* ]] || fail_ "the reason names its age and the error ($HOSTID_WHY)"; pass
RIPE_FAIL=""; hostid_ensure > /dev/null 2>&1 || fail_ "refreshes working again: usable"; pass

# ---- verdicts ----
lt_reset; [[ $(lt_exit_code) == 0 ]] || fail_ "nothing found: 0"; pass
lt_unproven x > /dev/null; [[ $(lt_exit_code) == 2 ]] || fail_ "an unproven check: 2, never 0"; pass
lt_fail x > /dev/null; [[ $(lt_exit_code) == 1 ]] || fail_ "a failure outranks it: 1"; pass

# ---- the tunnel address ----
EXEC_OUT="" EXEC_RC=0
sudo() { [[ "$2" == exec ]] || return 1; echo "$EXEC_OUT"; return "$EXEC_RC"; }
tun() { EXEC_OUT=$1; EXEC_RC=${2:-0}; lt_reset; lt_tunnel_ip mediastack-gluetun "${HOK:-1}" > "$T/out" 2>&1; }
tun '{"ip":"203.0.113.9","organization":"Example VPN"}'
[[ $(lt_exit_code) == 0 ]] && grep -q "OK tunnel exits at 203.0.113.9 (Example VPN)" "$T/out" || fail_ "a VPN address: PASS — $(cat "$T/out")"; pass
tun '{"ip":"198.51.100.7"}'
[[ $(lt_exit_code) == 1 ]] && grep -q "THIS HOST'S OWN address" "$T/out" || fail_ "an old address of the host's: FAIL — $(cat "$T/out")"; pass
tun '{"ip":"198.51.103.1"}'
[[ $(lt_exit_code) == 1 ]] && grep -q "inside your own network's block 198.51.100.0/22" "$T/out" || fail_ "an address of the host's network: FAIL — $(cat "$T/out")"; pass
tun 'wget: server returned error: HTTP/1.1 429 Too Many Requests' 1
[[ $(lt_exit_code) == 2 ]] && grep -q "UNPROVEN: tunnel address: Mullvad's checker did not answer.*429" "$T/out" || fail_ "a rate limit: UNPROVEN with the evidence — $(cat "$T/out")"; pass
HOK=0 tun '{"ip":"203.0.113.9"}'
[[ $(lt_exit_code) == 2 ]] || fail_ "no usable host record: UNPROVEN, not a pass"; pass

# ---- UDP ----
udp() { EXEC_OUT=$1; lt_reset; lt_udp_identity mediastack-gluetun 1 > "$T/out" 2>&1; }
udp $'o-o.myaddr.l.google.com\ttext = "172.253.11.26"\no-o.myaddr.l.google.com\ttext = "edns0-client-subnet 203.0.113.0/24"'
[[ $(lt_exit_code) == 0 ]] || fail_ "the VPN's subnet: PASS — $(cat "$T/out")"; pass
udp 'o-o.myaddr.l.google.com text = "edns0-client-subnet 198.51.101.0/24"'
[[ $(lt_exit_code) == 1 ]] || fail_ "the host network's subnet: FAIL"; pass
udp 'o-o.myaddr.l.google.com text = "172.253.11.26"'
[[ $(lt_exit_code) == 2 ]] || fail_ "no client subnet in the answer: UNPROVEN"; pass

# ---- resolvers (bash.ws) ----
BWS_ID=c11558d8cf7d7d5f BWS_JSON=""
sudo() { # docker exec gluetun wget|nslookup ...
    case "$*" in
        *bash.ws/id*) echo "$BWS_ID" ;;
        *dnsleak/test*) echo "$BWS_JSON" ;;
        *nslookup*) : ;;
    esac
}
bws() { BWS_JSON=$1; lt_reset; lt_dns_resolvers mediastack-gluetun 1 > "$T/out" 2>&1; }
bws '[{"ip":"86.104.249.52","asn":"AS25369 Hydra","type":"ip"},{"ip":"172.68.178.76","asn":"AS13335 CloudFlare Inc","type":"dns"},{"ip":"DNS may be leaking.","asn":"","type":"conclusion"}]'
[[ $(lt_exit_code) == 0 ]] && grep -q "1 resolver(s) answered ten never-seen names, none in your network (CloudFlare Inc)" "$T/out" \
    || fail_ "a public resolver: PASS (bash.ws's own verdict line ignored) — $(cat "$T/out")"; pass
bws '[{"ip":"198.51.100.53","asn":"AS64500 Example ISP","type":"dns"},{"ip":"172.68.178.76","asn":"AS13335 CloudFlare Inc","type":"dns"}]'
[[ $(lt_exit_code) == 1 ]] && grep -q "198.51.100.53 (AS64500 Example ISP)" "$T/out" || fail_ "your ISP's resolver: FAIL, named — $(cat "$T/out")"; pass
bws '[]'; [[ $(lt_exit_code) == 2 ]] || fail_ "no resolver seen: UNPROVEN"; pass
BWS_ID="wget: bad address 'bash.ws'"; bws '[]'
[[ $(lt_exit_code) == 2 ]] && grep -q "bash.ws gave no test id (wget: bad address" "$T/out" || fail_ "bash.ws down: UNPROVEN with the evidence"; pass

# ---- DNS settings ----
INSPECT='[{"HostConfig":{"Dns":["127.0.0.1"]},"Config":{"Env":["VPN_TYPE=wireguard"]}}]' RESOLV_OK=0
sudo() {
    case "$2" in
        inspect) echo "$INSPECT" ;;
        exec) return "$RESOLV_OK" ;;
    esac
}
dnscfg() { lt_reset; lt_dns_config mediastack-gluetun > "$T/out" 2>&1; }
dnscfg; [[ $(lt_exit_code) == 0 ]] || fail_ "dns 127.0.0.1, encrypted by default, no plaintext: PASS — $(cat "$T/out")"; pass
INSPECT='[{"HostConfig":{"Dns":["127.0.0.1"]},"Config":{"Env":["DNS_UPSTREAM_RESOLVER_TYPE=DoT","DNS_UPSTREAM_PLAIN_ADDRESSES="]}}]'; dnscfg
[[ $(lt_exit_code) == 0 ]] || fail_ "the image's own DNS_UPSTREAM_RESOLVER_TYPE=DoT (capitals, empty plain list): PASS — $(cat "$T/out")"; pass
INSPECT='[{"HostConfig":{"Dns":null},"Config":{"Env":[]}}]'; dnscfg
[[ $(lt_exit_code) == 1 ]] && grep -q "dns setting is 'unset'" "$T/out" || fail_ "no dns setting: FAIL (Docker forwards to the host)"; pass
INSPECT='[{"HostConfig":{"Dns":["127.0.0.1"]},"Config":{"Env":["DNS_UPSTREAM_RESOLVER_TYPE=plain","DNS_UPSTREAM_PLAIN_ADDRESSES=192.168.1.1:53"]}}]'; dnscfg
[[ $LT_FAIL == 2 ]] || fail_ "plaintext type and a plaintext upstream: two FAILs ($LT_FAIL)"; pass
INSPECT='[{"HostConfig":{"Dns":["127.0.0.1"]},"Config":{"Env":[]}}]' RESOLV_OK=1; dnscfg
[[ $(lt_exit_code) == 1 ]] || fail_ "resolv.conf not gluetun's: FAIL"; pass

# ---- the LAN resolver path: decided by the route ----
host_lan_resolvers() { echo 192.168.69.1; }
ROUTE_OUT=""
sudo() { echo "$ROUTE_OUT"; }
lan() { ROUTE_OUT=$1; lt_reset; lt_dns_lan_path mediastack-gluetun > "$T/out" 2>&1; }
lan '192.168.69.1 dev tun0 table 51820 src 10.5.0.2 uid 0'
[[ $(lt_exit_code) == 0 ]] && grep -q "routed into the tunnel (tun0)" "$T/out" || fail_ "routed into the tunnel (anzac4's live output): PASS — $(cat "$T/out")"; pass
lan '192.168.69.1 via 172.31.250.1 dev eth0 src 172.31.250.131 uid 0'
[[ $(lt_exit_code) == 1 ]] || fail_ "routed over eth0: FAIL"; pass
lan 'OCI runtime exec failed: exec: "ip": executable file not found in $PATH'
[[ $(lt_exit_code) == 2 ]] || fail_ "no route read: UNPROVEN, never a pass"; pass

# ---- the firewall: every way out accounted for ----
ip4_cidr_inside 172.31.250.0/24 172.31.250.0/24 || fail_ "a subnet lies inside itself"; pass
ip4_cidr_inside 172.31.250.7 172.31.250.0/24 || fail_ "an address of the subnet lies inside it"; pass
ip4_cidr_inside 172.31.0.0/16 172.31.250.0/24 && fail_ "a wider block is not inside a narrower one"; pass
ip4_cidr_inside 192.168.69.0/24 172.31.250.0/24 && fail_ "the LAN is not the stack's subnet"; pass
GLUETUN_RULES="" ADDR_OUT='4: eth0    inet 172.31.250.131/24 brd 172.31.250.255 scope global eth0'
sudo() { # docker exec gluetun iptables -S OUTPUT | ip -o -4 addr show dev eth0
    case "$*" in
        *iptables*) printf '%s\n' "$GLUETUN_RULES" ;;
        *"ip -o -4 addr"*) echo "$ADDR_OUT" ;;
    esac
}
fw() { GLUETUN_RULES=$1; lt_reset; lt_firewall mediastack-gluetun > "$T/out" 2>&1; }
GOOD=$'-P OUTPUT DROP\n-A OUTPUT -o lo -j ACCEPT\n-A OUTPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT\n-A OUTPUT -s 172.31.250.131/32 -d 172.31.250.0/24 -o eth0 -j ACCEPT\n-A OUTPUT -d 86.104.249.45/32 -o eth0 -p udp -m udp --dport 51820 -j ACCEPT\n-A OUTPUT -o tun0 -j ACCEPT'
fw "$GOOD"
[[ $(lt_exit_code) == 0 && "$LT_ENDPOINTS" == "86.104.249.45 " ]] || fail_ "gluetun's own rules: PASS, its VPN server named — $(cat "$T/out")"; pass
fw "${GOOD/-P OUTPUT DROP/-P OUTPUT ACCEPT}"; [[ $(lt_exit_code) == 1 ]] || fail_ "policy ACCEPT: FAIL"; pass
fw "$GOOD"$'\n-A OUTPUT -d 192.168.69.0/24 -o eth0 -j ACCEPT'
[[ $(lt_exit_code) == 1 ]] && grep -q "past the tunnel: -A OUTPUT -d 192.168.69.0/24" "$T/out" || fail_ "the LAN let out the LAN side: FAIL, the rule shown — $(cat "$T/out")"; pass
fw "$GOOD"$'\n-A OUTPUT -o eth0 -j ACCEPT'; [[ $(lt_exit_code) == 1 ]] || fail_ "everything out the LAN side: FAIL"; pass
fw "$GOOD"$'\n-A OUTPUT -j ACCEPT'; [[ $(lt_exit_code) == 2 ]] && grep -q -- "cannot account for: -A OUTPUT -j ACCEPT" "$T/out" || fail_ "a rule it cannot read: UNPROVEN, shown"; pass
fw "${GOOD/-A OUTPUT -d 86.104.249.45\/32 -o eth0 -p udp -m udp --dport 51820 -j ACCEPT/}"
[[ $(lt_exit_code) == 2 ]] || fail_ "no VPN server among the rules: UNPROVEN — $(cat "$T/out")"; pass

# ---- the traffic: what the host tracks from gluetun ----
conntrack() { :; }   # present (the stub sudo answers for it)
CT_OUT=""
sudo() {
    case "$*" in
        conntrack*) printf '%s\n' "$CT_OUT" ;;
        *"ip -o -4 addr"*) echo "$ADDR_OUT" ;;
    esac
}
fl() { CT_OUT=$1; LT_ENDPOINTS=${2-86.104.249.45 }; lt_reset; lt_flows mediastack-gluetun > "$T/out" 2>&1; }
fl 'udp      17 179 src=172.31.250.131 dst=86.104.249.45 sport=51820 dport=51820 src=86.104.249.45 dst=192.168.70.36 sport=51820 dport=51820 [ASSURED] mark=0 use=1
tcp      6 86390 ESTABLISHED src=172.31.250.131 dst=172.31.250.134 sport=40122 dport=8096 src=172.31.250.134 dst=172.31.250.131 sport=8096 dport=40122 [ASSURED] mark=0 use=1'
[[ $(lt_exit_code) == 0 ]] || fail_ "the tunnel and the stack network (anzac4's live flow): PASS — $(cat "$T/out")"; pass
fl 'udp      17 29 src=172.31.250.131 dst=192.168.69.1 sport=40000 dport=53 src=192.168.69.1 dst=192.168.70.36 sport=53 dport=40000 mark=0 use=1'
[[ $(lt_exit_code) == 1 ]] && grep -q "udp 192.168.69.1:53" "$T/out" || fail_ "a flow to the LAN resolver: FAIL, named — $(cat "$T/out")"; pass
fl ''; [[ $(lt_exit_code) == 2 ]] || fail_ "no flow at all, not even the tunnel's: UNPROVEN"; pass
fl 'x' ''; [[ $(lt_exit_code) == 2 ]] || fail_ "no VPN server known: UNPROVEN"; pass
unset -f conntrack; PATH_SAVE=$PATH
# shellcheck disable=SC2123  # deliberately: no conntrack anywhere on the search path
PATH=/nonexistent
fl 'x'; PATH=$PATH_SAVE
[[ $(lt_exit_code) == 2 ]] && grep -q "conntrack is not installed on this host — ./mediastack.sh install adds it" "$T/out" || fail_ "conntrack missing: UNPROVEN, naming the fix — $(cat "$T/out")"; pass

# ---- DNS that leaves from the host itself ----
tcpdump() { :; }
CAPTURE="" LISTENING=1
sudo() {
    if [[ "$1" == timeout ]]; then
        (( LISTENING )) && echo "tcpdump: listening on any, link-type LINUX_SLL2" >&2
        local i; for i in $(seq 1 30); do [[ -s "$T/name" ]] && break; sleep 0.1; done   # the lookup runs after "listening"
        [[ -n "$CAPTURE" ]] && echo "06:12:01.1 ens18 Out IP 192.168.70.36.58105 > 192.168.69.1.53: 1+ A? $(cat "$T/name"). (32)"
        return 124
    fi
    [[ "$*" == *nslookup* ]] && echo "${*##* }" > "$T/name"
    return 0
}
dh() { CAPTURE=$1; LISTENING=${2:-1}; : > "$T/name"; lt_reset; lt_dns_host_path mediastack-gluetun > "$T/out" 2>&1; }
dh ""; [[ $(lt_exit_code) == 0 ]] || fail_ "no query left the host: PASS — $(cat "$T/out")"; pass
dh hit; [[ $(lt_exit_code) == 1 ]] && grep -q "left the host as a query" "$T/out" || fail_ "a query left the host: FAIL — $(cat "$T/out")"; pass
dh "" 0; [[ $(lt_exit_code) == 2 ]] && grep -q "the capture did not start" "$T/out" || fail_ "a capture that never started: UNPROVEN, never a pass — $(cat "$T/out")"; pass
unset -f tcpdump

# ---- control server ----
CURL_R="" WGET_OUT=""
sudo() { case "$2" in run) echo "$CURL_R" ;; exec) echo "$WGET_OUT" ;; esac; }
ctl() { CURL_R=$1 WGET_OUT=$2; lt_reset; lt_control_server mediastack-gluetun > "$T/out" 2>&1; }
ctl "000 7" "  HTTP/1.1 401 Unauthorized"; [[ $(lt_exit_code) == 0 ]] || fail_ "refused outside, 401 inside: PASS — $(cat "$T/out")"; pass
ctl "401 0" "  HTTP/1.1 401 Unauthorized"; [[ $(lt_exit_code) == 1 ]] || fail_ "answers the network: FAIL"; pass
ctl "000 6" "  HTTP/1.1 401 Unauthorized"; [[ $(lt_exit_code) == 2 ]] || fail_ "name unresolved: UNPROVEN, not a pass"; pass
ctl "000 7" "  HTTP/1.1 200 OK"; [[ $(lt_exit_code) == 1 ]] || fail_ "no password inside: FAIL"; pass
unset -f sudo curl date

# ---- migration 36 -> 37 ----
ENV_FILE="$T/env"
printf 'ENV_SCHEMA=36\nVPN_DNS_ADDRESS=10.64.0.1\n' > "$ENV_FILE"
migrate_env_36_to_37 > "$T/out" 2>&1
! grep -q VPN_DNS_ADDRESS "$ENV_FILE" && grep -qx 'VPN_DNS_RESOLVERS=cloudflare' "$ENV_FILE" || fail_ "retired, the new setting added — $(cat "$ENV_FILE")"; pass
grep -q "VPN_DNS_ADDRESS=10.64.0.1 removed" "$T/out" || fail_ "a value that was set is named"; pass
printf 'VPN_DNS_ADDRESS=\nVPN_DNS_RESOLVERS=quad9\n' > "$ENV_FILE"
migrate_env_36_to_37 > "$T/out" 2>&1
[[ ! -s "$T/out" ]] && grep -qx 'VPN_DNS_RESOLVERS=quad9' "$ENV_FILE" || fail_ "empty: removed quietly; a choice already made is kept"; pass

echo "test-leak: $checks checks passed"
