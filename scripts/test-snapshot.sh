#!/usr/bin/env bash
# shellcheck disable=SC2034  # RENDERED_JSON/INSPECT_JSON/VPNGUARD_UNIT are read by the sourced code
# test-snapshot.sh — what mediastack generates, byte-compared against a
# reviewed copy, for one fixture per generator branch. It guards the re-org's
# platform slices (hub, panel, sign-in, edge, VPN): moving code must leave
# every generated file identical.
#
#   scripts/test-snapshot.sh              compare every case (CI)
#   scripts/test-snapshot.sh CASE...      compare these cases
#   scripts/test-snapshot.sh --bless      rewrite expected/ from today's code —
#                                         only after reading the diff; CI never blesses
#
# A case is scripts/fixtures/snapshot/<case>/: env.set (KEY=VALUE lines laid
# over .env.example — every key must be one the schema knows, every value is
# validated like .env), an optional custom/ (copied in as the repo's custom/),
# and expected/ (the reviewed outputs). Per case, the `up` order runs on a
# throwaway copy: gate_bind_sync, vpn_gen, traefik_gen (when Traefik is on),
# then the compose render. Captured:
#   vpn-overlay.yml          local/vpn-overlay.yml
#   traefik/                 the static and dynamic config, your proxy.d routes
#   authentik-templates/     the email templates with the portal's name in them
#   compose.json             the render, cut to what mediastack owns (below)
# and once for the host (_host/expected/): what frontdoor-install writes — the
# panel's OliveTin config (its password hash replaced), theme, wrapper,
# sudoers file, forced-command key line, known_hosts, container passwd and
# refresh units (keys and ids are fixture values) — and the VPN boot-guard unit.
#
# compose.json keeps the fields mediastack writes — image, names, profiles,
# networks, ports, volumes, depends_on, dns_search, labels, environment, user,
# capabilities, devices, command — so a newer Compose adding defaults of its
# own cannot fail the build. Repo paths read @REPO@.
#
# Runs on a copy of the tracked files; the working tree is never touched
# (--bless writes only scripts/fixtures/snapshot/*/expected/). Needs
# `docker compose` (renders without a daemon), jq, openssl.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
repo=$PWD
fixtures=$repo/scripts/fixtures/snapshot

bless=0; cases=()
for a in "$@"; do
    case "$a" in
        --bless) bless=1 ;;
        -*)      echo "usage: test-snapshot.sh [--bless] [CASE...]" >&2; exit 2 ;;
        *)       [[ -f "$fixtures/$a/env.set" ]] || { echo "no such case: $a (scripts/fixtures/snapshot/$a/env.set)" >&2; exit 2; }
                 cases+=("$a") ;;
    esac
done
full=0
if (( ! ${#cases[@]} )); then
    full=1   # a full run also checks what the host gets (_host)
    for d in "$fixtures"/*/env.set; do d=${d%/env.set}; cases+=("${d##*/}"); done
fi

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
git -C "$repo" ls-files -z | (cd "$repo" && xargs -0 cp --parents -t "$work")
cd "$work"

# the entrypoint minus its last line (main "$@"), sourced for its generators
lib=$(mktemp .test-snapshot.XXXXXX)
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"; rm -f "$lib"
t_fail() { echo "ERROR $*" >&2; exit 1; }
# the generators ask root for files under the throwaway copy only; units are
# written to out/ and never reach systemd
sudo() { "$@"; }
systemctl() { :; }

normalize() { sed "s#$work#@REPO@#g"; }

# the render, cut to what mediastack owns; keys sorted, nulls dropped
PROJECT='
def clean: with_entries(select(.value != null and .value != [] and .value != {}));
{
  services: (.services | map_values({
      image, container_name, profiles, network_mode, dns_search, labels, environment,
      user, cap_add, cap_drop, devices, privileged, security_opt, sysctls, command, entrypoint,
      networks: (if .networks then (.networks | map_values(if . == null then {} else ({ipv4_address, aliases} | clean) end)) else null end),
      ports: (if .ports then [.ports[] | {host_ip, published, target, protocol} | clean] else null end),
      volumes: (if .volumes then [.volumes[] | {type, source, target, read_only} | clean] else null end),
      depends_on: (if .depends_on then (.depends_on | map_values(.condition)) else null end)
  } | clean)),
  networks: ((.networks // {}) | map_values({name, driver, ipam} | clean))
}'

snap_case() { # snap_case CASE OUT — one fixture through the up order, outputs into OUT
    local c=$1 out=$2 fx=$fixtures/$1 line k v croot f
    rm -rf "$work/.env" "$work/local" "$work/custom" "$work/config"
    cp "$work/.env.example" "$work/.env"
    [[ -d "$fx/custom" ]] && cp -r "$fx/custom" "$work/custom"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        k=${line%%=*}; v=${line#*=}
        env_schema_lookup "$k" >/dev/null || t_fail "$c: '$k' is no setting mediastack knows (lib/env.schema.tsv, services/*/env.tsv)"
        env_set "$k" "$v"
    done < "$fx/env.set"
    RENDERED_JSON=""; INSPECT_JSON=""
    load_env                       # migrations (none on the example) + every value validated
    gate_bind_sync
    vpn_gen
    RENDERED_JSON=""
    mkdir -p "$out"
    normalize < "$OVERLAY_FILE" > "$out/vpn-overlay.yml"
    if svc_enabled traefik; then
        traefik_gen
        croot=$(env_get CONFIG_ROOT)
        mkdir -p "$out/traefik/dynamic"
        normalize < "$croot/traefik/traefik.yml" > "$out/traefik/traefik.yml"
        for f in "$croot"/traefik/dynamic/*.yml; do normalize < "$f" > "$out/traefik/dynamic/${f##*/}"; done
    fi
    if svc_enabled authentik; then
        mkdir -p "$out/authentik-templates"
        for f in services/authentik/templates/*; do
            authentik_template_render "$f" "$(env_get PORTAL_TITLE Mediastack)" > "$out/authentik-templates/${f##*/}"
        done
    fi
    DC config --format json | jq -S "$PROJECT" | normalize > "$out/compose.json"
}

snap_host() { # snap_host OUT — what the panel and the VPN guard install, from the code alone
    local out=$1
    mkdir -p "$out"
    panel_config_render '@ARGON2ID-HASH@' | normalize > "$out/olivetin-config.yaml"
    panel_theme_render | normalize > "$out/olivetin-theme.css"
    _fd_wrapper_render "$SCRIPT_DIR/mediastack.sh" | normalize > "$out/olivetin-frontdoor"
    _fd_sudoers_render "$SCRIPT_DIR/mediastack.sh" | normalize > "$out/frontdoor-sudoers"
    _fd_authkeys_render "$FRONTDOOR_WRAPPER" 'ssh-ed25519 @PANEL-PUBKEY@ olivetin-frontdoor' > "$out/olivetin-authorized_keys"
    echo 'ssh-ed25519 @HOST-PUBKEY@ root@host' | _fd_known_hosts_render > "$out/olivetin-known_hosts"
    panel_passwd_render 990 991 > "$out/olivetin-passwd"
    _fd_refresh_service_render | normalize > "$out/mediastack-frontdoor-refresh.service"
    _fd_refresh_timer_render > "$out/mediastack-frontdoor-refresh.timer"
    VPNGUARD_UNIT=$work/vpnguard.service
    rm -f "$VPNGUARD_UNIT"; vpnguard_ensure
    normalize < "$VPNGUARD_UNIT" > "$out/mediastack-vpnguard.service"
}

run() { # run NAME FUNCTION ARGS... — quiet unless it fails; then its own output
    local log rc; log=$(mktemp)
    set +e; ( set -e; "${@:2}" ) >"$log" 2>&1; rc=$?; set -e
    if (( rc )); then sed 's/^/    /' "$log" >&2; rm -f "$log"; t_fail "$1: generating failed (output above)"; fi
    rm -f "$log"
}

compare() { # compare NAME GOT EXPECTED -> 0 identical; prints the diff
    if [[ ! -d "$3" ]]; then echo "FAIL $1: no reviewed snapshot yet — check the output, then: scripts/test-snapshot.sh --bless $1" >&2; return 1; fi
    diff -ru "$3" "$2" >"$work/diff" && return 0
    echo "FAIL $1: generated files changed (- reviewed, + now):" >&2
    sed -e "s#$3#expected#g" -e "s#$2#now#g" -e 's/^/    /' "$work/diff" >&2
    return 1
}

failed=0 n=0
names=("${cases[@]}")
(( full )) && names+=(_host)
for c in "${names[@]}"; do
    got=$work/out/$c
    if [[ "$c" == _host ]]; then run "$c" snap_host "$got"; else run "$c" snap_case "$c" "$got"; fi
    exp=$fixtures/$c/expected
    if (( bless )); then
        rm -rf "$exp"; mkdir -p "$fixtures/$c"; cp -r "$got" "$exp"
        echo "blessed $c ($(find "$exp" -type f | wc -l) files)"
    elif compare "$c" "$got" "$exp"; then
        n=$((n + $(find "$got" -type f | wc -l)))
    else
        failed=1
    fi
done
(( bless )) && { echo "OK snapshot: expected/ rewritten — review it with git diff before committing"; exit 0; }
(( failed )) && { echo "If the change is intended: scripts/test-snapshot.sh --bless, and commit the reviewed diff with the code." >&2; exit 1; }
echo "OK snapshot: ${#names[@]} cases, $n files identical"
