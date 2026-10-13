#!/usr/bin/env bash
# test-safety.sh — the stack's safety rules, held against every reviewed
# snapshot (scripts/fixtures/snapshot/*/expected/). test-snapshot.sh proves
# today's code generates exactly those files, so together they hold the code;
# and a --bless that would break a rule fails here, whatever its diff said.
#
#   vpn        a service on gluetun's network publishes no port of its own and
#              is labelled as VPN'd
#   torrent    a download client is in the VPN unless the fixture takes it out
#   edge       only the edge (Traefik or NPM) publishes 80 or 443
#   gated      with the portal on, no gated tool's port is open to the LAN
#   strip      with the portal on, a route into a gated tool that skips the
#              gate strips the portal's identity headers
#   trust      an app trusting a name header trusts Traefik's fixed address
#              only, and only while the portal runs
#   dashboard  Traefik's dashboard always has a login (the gate or its own)
#   ldap       the LDAP route answers the stack network only
#   socket     only Traefik mounts the Docker socket, and read-only
#   acme       the certificate server is staging exactly when ACME_ENV says so
#   secrets    a secret's value appears in an app's environment only — never in
#              a label, a command, Traefik's files or the panel's
# and once on what the host gets (_host/expected/):
#   panel      sudoers lets the panel user run exactly mediastack.sh as root and
#              nothing else; its key is pinned to the forced-command wrapper
#              with no pty and no forwarding; the host key is labelled only for
#              the name the container uses
#
# Each rule is also run against a copy broken on purpose (--self-test, also
# run by default), so a rule that can no longer fail is caught too.
# Needs jq only: no Docker, no render.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
fixtures=scripts/fixtures/snapshot
RULES=(vpn torrent edge gated strip trust dashboard ldap socket acme secrets)
HOST_RULES=(panel)

# ---- helpers: D is a case folder (env.set + expected/) ----
cj()       { echo "$1/expected/compose.json"; }
setting()  { sed -n "s/^$2=//p" "$1/env.set" | tail -1; }        # a key the fixture sets ("" otherwise)
portal_on(){ jq -e '.services.authentik' "$(cj "$1")" >/dev/null; }
schema_type() { awk -F'\t' -v k="$1" '$1==k {print $2; exit}' lib/env.schema.tsv services/*/env.tsv; }

# ---- the rules: each prints one line per violation ----
rule_vpn() {
    jq -r '.services | to_entries[] | select(.value.network_mode == "service:gluetun")
        | select(((.value.ports // []) | length) > 0 or .value.labels["mediastack.vpn"] != "true")
        | "\(.key): on gluetun network but publishes ports or is not labelled mediastack.vpn=true"' "$(cj "$1")"
}
rule_torrent() {
    local s
    for s in $(jq -r '.services | to_entries[] | select(.value.labels["mediastack.torrent"] == "true")
                 | select(.value.network_mode != "service:gluetun") | .key' "$(cj "$1")"); do
        [[ "$(setting "$1" "$(tr 'a-z-' 'A-Z_' <<<"$s")_VPN")" == false ]] || echo "$s: a download client outside the VPN"
    done
    return 0
}
rule_edge() {
    jq -r '.services | to_entries[] | select(.key != "traefik" and .key != "npm")
        | .key as $s | (.value.ports // [])[] | select(.published == "80" or .published == "443")
        | "\($s): publishes \(.published) (only the edge may)"' "$(cj "$1")"
}
rule_gated() {
    portal_on "$1" || return 0
    jq -r '.services as $all | $all | to_entries[] | select(.value.labels["mediastack.auth"] == "gate")
        | .key as $s | (.value.labels["mediastack.port"] | tonumber) as $p
        | (if .value.network_mode == "service:gluetun" then "gluetun" else $s end) as $pub
        | ($all[$pub].ports // [])[] | select(.target == $p and ((.host_ip // "0.0.0.0") != "127.0.0.1"))
        | "\($s): port \(.published) is open to the LAN while the portal guards it (published by \($pub))"' "$(cj "$1")"
}
rule_strip() {
    portal_on "$1" || return 0
    jq -r '[.services[] | .labels // {} | to_entries[]] as $L
        | ($L | map(select(.key | test("^traefik\\.http\\.routers\\.[^.]+\\.service$"))) | map({r: (.key | split(".")[3]), svc: .value})) as $routes
        | ($L | map(select(.key | test("^traefik\\.http\\.routers\\.[^.]+\\.middlewares$"))) | map({key: (.key | split(".")[3]), value: .value}) | from_entries) as $mw
        | [.services | to_entries[] | select(.value.labels["mediastack.auth"] == "gate") | .key | gsub("[^a-z0-9]"; "")] as $gated
        | $routes[] | select(.svc as $v | $gated | index($v)) | ($mw[.r] // "") as $m
        | select(($m | contains("mediastack-gate")) | not) | select(($m | contains("mediastack-strip")) | not)
        | "router \(.r) reaches gated \(.svc) without the gate and without stripping identity headers"' "$(cj "$1")"
}
rule_trust() {
    local want=""
    portal_on "$1" && want="$(jq -r '.services.traefik.networks.mediastack.ipv4_address' "$(cj "$1")")/32"
    jq -r --arg w "$want" '.services | to_entries[] | .key as $s | (.value.environment // {}) | to_entries[]
        | select(.key | test("TRUSTEDSOURCES|REVERSEPROXYWHITELIST")) | select(.value != $w)
        | "\($s): \(.key)=\(.value) (want \"\($w)\")"' "$(cj "$1")"
}
rule_dashboard() {
    local f=$1/expected/traefik/dynamic/00-mediastack.yml mw want=dash-auth
    [[ -f "$f" ]] || return 0
    portal_on "$1" && want=mediastack-gate
    mw=$(awk '/^    dashboard:/{d=1} d && /middlewares:/{sub(/^ +/, ""); print; exit}' "$f")
    [[ "$mw" == *"[$want]"* ]] || echo "dashboard: '$mw' (want [$want])"
}
rule_ldap() {
    portal_on "$1" || return 0
    local f=$1/expected/traefik/dynamic/00-mediastack.yml subnet range
    [[ "$(jq -r '[.services[].labels // {} | to_entries[] | select(.key == "traefik.tcp.routers.authentik-ldap.middlewares") | .value][0] // ""' "$(cj "$1")")" \
        == mediastack-ldap-allow@file ]] || echo "authentik-ldap: the tcp router lacks mediastack-ldap-allow"
    subnet=$(jq -r '.networks.mediastack.ipam.config[0].subnet' "$(cj "$1")")
    range=$(awk '/mediastack-ldap-allow:/{m=1} m && /sourceRange:/{sub(/^ +/, ""); print; exit}' "$f")
    [[ "$range" == *"[\"$subnet\"]"* ]] || echo "mediastack-ldap-allow: '$range' (want only the stack network $subnet)"
}
rule_socket() {
    jq -r '.services | to_entries[] | .key as $s | (.value.volumes // [])[] | select(.source == "/var/run/docker.sock")
        | select($s != "traefik" or .read_only != true) | "\($s): mounts the Docker socket (read_only: \(.read_only // false))"' "$(cj "$1")"
}
rule_acme() {
    local f=$1/expected/traefik/traefik.yml staging=0
    [[ -f "$f" ]] || return 0
    grep -q 'acme-staging' "$f" && staging=1
    if [[ "$(setting "$1" ACME_ENV)" == staging ]]; then (( staging )) || echo "ACME_ENV=staging but traefik.yml uses the production server"
    else (( ! staging )) || echo "traefik.yml uses the staging server but ACME_ENV is not staging"; fi
    return 0
}
rule_secrets() {
    local line k v
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        k=${line%%=*}; v=${line#*=}
        [[ -n "$v" && "$(schema_type "$k")" == secret ]] || continue
        jq -c 'del(.services[].environment)' "$(cj "$1")" | grep -qF -- "$v" && echo "$k: its value is in a label, command or name"
        { grep -rlF --exclude=compose.json -- "$v" "$1/expected" "$fixtures/_host/expected" || true; } | sed "s|^|$k: its value is in |"
    done < "$1/env.set"
    return 0
}

rule_panel() { # D is the _host folder here
    local e=$1/expected sud keys
    sud=$(grep -v '^#' "$e/frontdoor-sudoers" | grep -v '^[[:space:]]*$' || true)
    [[ "$sud" == 'olivetin ALL=(root) NOPASSWD: @REPO@/mediastack.sh' ]] \
        || echo "sudoers grants more than mediastack.sh to olivetin: $(tr '\n' '|' <<<"$sud")"
    keys=$(grep -c . "$e/olivetin-authorized_keys" || true)
    [[ "$keys" == 1 ]] || echo "authorized_keys holds $keys lines (want exactly the one pinned key)"
    grep -qE '^command="/usr/local/bin/olivetin-frontdoor",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding ssh-' "$e/olivetin-authorized_keys" \
        || echo "the panel's key is not pinned to the wrapper with no pty and no forwarding"
    awk '$1 != "host.docker.internal" { bad = 1 } END { exit !bad }' "$e/olivetin-known_hosts" \
        && echo "known_hosts trusts a name other than host.docker.internal"
    return 0
}

# ---- every rule on every case ----
fails=0 checks=0
for d in "$fixtures"/*/env.set; do
    d=${d%/env.set}
    [[ -f "$(cj "$d")" ]] || { echo "FAIL ${d##*/}: no expected/compose.json — run scripts/test-snapshot.sh --bless ${d##*/}" >&2; fails=$((fails + 1)); continue; }
    for r in "${RULES[@]}"; do
        out=$("rule_$r" "$d" 2>&1) || { echo "FAIL ${d##*/} [$r] the rule itself failed: $out" >&2; fails=$((fails + 1)); continue; }
        checks=$((checks + 1))
        [[ -z "$out" ]] || { sed "s|^|FAIL ${d##*/} [$r] |" <<<"$out" >&2; fails=$((fails + 1)); }
    done
done

for r in "${HOST_RULES[@]}"; do
    out=$("rule_$r" "$fixtures/_host" 2>&1) || { echo "FAIL _host [$r] the rule itself failed: $out" >&2; fails=$((fails + 1)); continue; }
    checks=$((checks + 1))
    [[ -z "$out" ]] || { sed "s|^|FAIL _host [$r] |" <<<"$out" >&2; fails=$((fails + 1)); }
done

# ---- self-test: each rule must fail on a copy broken for it ----
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
broken() { # broken RULE -> a portal copy (plus the host files) with exactly that rule broken
    local b=$tmp/$1/portal c
    mkdir -p "$tmp/$1"; cp -r "$fixtures/portal" "$b"; mkdir -p "$tmp/$1/_host"; cp -r "$fixtures/_host/expected" "$tmp/$1/_host/"
    c=$(cj "$b")
    case "$1" in
        vpn)       jq '.services.radarr.ports = [{"published":"7878","target":7878}]' "$c" ;;
        torrent)   jq '.services.qbittorrent.network_mode = null' "$c" ;;
        edge)      jq '.services.jellyfin.ports += [{"published":"443","target":8096}]' "$c" ;;
        gated)     jq '(.services.gluetun.ports[] | select(.target == 7878)) |= del(.host_ip)' "$c" ;;
        strip)     jq '(.services.gluetun.labels["traefik.http.routers.radarr-api.middlewares"]) = "something-else@file"' "$c" ;;
        trust)     jq '.services.navidrome.environment.ND_EXTAUTH_TRUSTEDSOURCES = "0.0.0.0/0"' "$c" ;;
        dashboard) sed -i 's/middlewares: \[mediastack-gate\]/middlewares: []/' "$b/expected/traefik/dynamic/00-mediastack.yml"; cat "$c" ;;
        ldap)      sed -i 's|sourceRange: \["172.31.250.0/24"\]|sourceRange: ["0.0.0.0/0"]|' "$b/expected/traefik/dynamic/00-mediastack.yml"; cat "$c" ;;
        socket)    jq '.services.jellyfin.volumes += [{"type":"bind","source":"/var/run/docker.sock","target":"/var/run/docker.sock"}]' "$c" ;;
        acme)      echo 'ACME_ENV=staging' >> "$b/env.set"; cat "$c" ;;
        secrets)   jq '.services.jellyfin.labels.leak = "fixture-secret-wireguard"' "$c" ;;
    esac > "$c.new"
    mv "$c.new" "$c"; echo "$b"
}
for r in "${RULES[@]}"; do
    b=$(broken "$r")
    out=$(fixtures=$tmp/$r; "rule_$r" "$b" 2>&1) || { echo "FAIL self-test [$r] the rule itself failed: $out" >&2; fails=$((fails + 1)); continue; }   # rule_secrets reads the host files under $fixtures
    checks=$((checks + 1))
    [[ -n "$out" ]] || { echo "FAIL self-test [$r]: the rule passed a copy broken for it — it can no longer fail" >&2; fails=$((fails + 1)); }
done

for broken_host in 's|NOPASSWD: @REPO@/mediastack.sh|NOPASSWD: ALL|:frontdoor-sudoers' \
                   's|,no-pty||:olivetin-authorized_keys' \
                   's|^host.docker.internal|anzac3|:olivetin-known_hosts'; do
    h=$tmp/host-${broken_host##*:}; mkdir -p "$h"; cp -r "$fixtures/_host/expected" "$h/"
    sed -i "${broken_host%:*}" "$h/expected/${broken_host##*:}"
    out=$(rule_panel "$h" 2>&1); checks=$((checks + 1))
    [[ -n "$out" ]] || { echo "FAIL self-test [panel] passed a copy with ${broken_host##*:} broken — it can no longer fail" >&2; fails=$((fails + 1)); }
done

(( ! fails )) || { echo "test-safety: $fails failure(s)" >&2; exit 1; }
echo "OK safety: $checks checks (${#RULES[@]} rules x $(find "$fixtures" -mindepth 1 -maxdepth 1 -type d ! -name _host | wc -l) cases + ${#HOST_RULES[@]} on the host's files, each rule proven able to fail)"
