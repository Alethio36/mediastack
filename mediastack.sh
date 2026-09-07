#!/usr/bin/env bash
# ============================================================================
# mediastack.sh — install, configure, run, update, back up and diagnose the
# mediastack. Run without arguments for an explained command list.
#
# Design rules this script follows:
#   * .env is the single source of truth; tracked files are NEVER written at
#     runtime. Generated state goes to gitignored files (.pins.yml, backups/).
#   * Fail loud: no silent fallbacks. Every failure states what and how to fix.
#   * Service discovery is label-driven (mediastack.* labels in compose.d/*):
#     this script contains no hardcoded service lists.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE="$SCRIPT_DIR/.env"
PINS_FILE="$SCRIPT_DIR/.pins.yml"
SCRIPT_SCHEMA=14

# Libraries — sourced, never executed (mode 644); every source line lives
# here so the load order is visible in one place. Each lib says at its top
# what it holds; the entrypoint keeps the header, the compose/service/
# inspect helpers, configure, up/down/enable/disable, status, the verb
# registry and main(). Libs call entrypoint helpers at call time only.
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/frontdoor.sh
source "$SCRIPT_DIR/lib/frontdoor.sh"
# shellcheck source=lib/integrations.sh
source "$SCRIPT_DIR/lib/integrations.sh"
# shellcheck source=lib/migrations.sh
source "$SCRIPT_DIR/lib/migrations.sh"
# shellcheck source=lib/vpn.sh
source "$SCRIPT_DIR/lib/vpn.sh"
# shellcheck source=lib/edge.sh
source "$SCRIPT_DIR/lib/edge.sh"
# shellcheck source=lib/backup.sh
source "$SCRIPT_DIR/lib/backup.sh"
# shellcheck source=lib/doctor.sh
source "$SCRIPT_DIR/lib/doctor.sh"

load_env() {
    # NOTE: .env is deliberately NOT sourced — compose reads it natively, and
    # bash `source` would execute space-containing values ("Tue 04:00") as
    # commands. All script reads go through env_get.
    [[ -f "$ENV_FILE" ]] || die ".env not found. Run: ./mediastack.sh configure"
    migrate_env
}

# ------------------------------------------------------------ compose layer --
DC() { # compose wrapper: project dir pinned, pin-override applied when present
    # explicit -f disables compose's automatic override merge, so the user's
    # override file is passed explicitly (before pins — pins win)
    local files=(-f docker-compose.yml)
    [[ -e docker-compose.override.yml ]] && files+=(-f docker-compose.override.yml)
    # generated VPN membership overlay (see vpn_gen); after the user override
    # so materialised membership is authoritative, before pins so pins win
    [[ -e local/vpn-overlay.yml ]] && files+=(-f local/vpn-overlay.yml)
    [[ -s "$PINS_FILE" ]] && files+=(-f "$PINS_FILE")
    [[ " $* " == *" config "* ]] || INSPECT_JSON=""   # see CACHE RULE at c_inspect
    sudo docker compose --project-directory "$SCRIPT_DIR" "${files[@]}" "$@"
}

compose_renders() { DC config >/dev/null; } # rc-only; compose errors pass through

RENDERED_JSON=""
INSPECT_JSON=""   # `docker inspect` cache — see CACHE RULE at c_inspect
render() { # cache rendered config as json for discovery
    # CACHING SEMANTICS: helpers run inside $( ) subshells, so a render
    # triggered there does NOT populate the parent shell. Any function that
    # reads $RENDERED_JSON directly, or loops service helpers, must call
    # `render` in its own (parent) scope first — both for correctness and to
    # avoid one `docker compose config` per helper call.
    [[ -n "$RENDERED_JSON" ]] && return 0
    # --profile "*": discovery sees the whole catalogue, not just enabled
    # services — otherwise disabled services vanish from backups and audits.
    local rerr
    rerr=$(mktemp)
    if ! RENDERED_JSON=$(DC --profile "*" config --format json 2>"$rerr"); then
        echo "${C_RED}compose said:${C_RST}" >&2
        sed 's/^/  /' "$rerr" >&2; rm -f "$rerr"
        die "docker compose could not render the config (see compose's message above).
  Needs compose >= 2.24 ('include:' + wildcard profiles); check .env syntax.
  Just removed a service from docker-compose.override.yml? Its generated
  stanza is stale: ./mediastack.sh up regenerates local/vpn-overlay.yml."
    fi
    rm -f "$rerr"
}

svc_all()      { render; jq -r '.services | keys[]' <<<"$RENDERED_JSON"; }
svc_label()    { render; jq -r --arg s "$1" --arg l "$2" '.services[$s].labels[$l] // ""' <<<"$RENDERED_JSON"; }
svc_managed()  { svc_managed_where mediastack.managed true; }
svc_managed_where() { # svc_managed_where LABEL VALUE — managed services whose LABEL == VALUE, one jq
    render
    jq -r --arg l "$1" --arg v "$2" '
        [ .services | to_entries[]
          | select(.value.labels["mediastack.managed"] == "true" and .value.labels[$l] == $v)
          | .key ] | sort[]' <<<"$RENDERED_JSON"
}
svc_enabled_managed()  { _svc_managed_by_profile true; }
svc_disabled_managed() { _svc_managed_by_profile false; }
_svc_managed_by_profile() { # one env read + one jq, same test as svc_enabled per service
    render
    local profiles; profiles=",$(env_get COMPOSE_PROFILES),"
    jq -r --arg p "$profiles" --argjson want "$1" '
        [ .services | to_entries[]
          | select(.value.labels["mediastack.managed"] == "true")
          | .key as $k | select(($p | contains("," + $k + ",")) == $want) | $k ] | sort[]' <<<"$RENDERED_JSON"
}
svc_exists()   { svc_all | grep -qx "$1"; }
svc_image()    { render; jq -r --arg s "$1" '.services[$s].image' <<<"$RENDERED_JSON"; }
svc_cname()    { render; jq -r --arg s "$1" '.services[$s].container_name // $s' <<<"$RENDERED_JSON"; }
svc_port() { # host port a service is published on for its mediastack.port
    # (the CONTAINER port). Read from the rendered config, so it honours every
    # `${<SVC>_PORT:-…}` override — on the service itself, or on gluetun when
    # the service shares gluetun's namespace. Empty when nothing publishes it
    # (Traefik-only services); use svc_hostport where a host port is required.
    render
    local cport; cport=$(svc_label "$1" mediastack.port)
    [[ -n "$cport" ]] || return 0
    jq -r --arg s "$1" --argjson t "$cport" '
        ((.services[$s].network_mode // "")
         | if startswith("service:") then ltrimstr("service:") else $s end) as $pub
        | [ .services[$pub].ports[]? | select(.target == $t and .protocol == "tcp") | .published ]
        | first // ""' <<<"$RENDERED_JSON"
}
svc_hostport() { # svc_port, but a missing host port is an error (API callers)
    local p; p=$(svc_port "$1")
    [[ -n "$p" ]] || die "$1 publishes no host port for its mediastack.port label — unreachable from this host"
    echo "$p"
}
uvar()         { echo "${1^^}" | tr '-' '_' | tr -cd 'A-Z0-9_'; } # service -> env var stem (radarr-4k -> RADARR_4K)
svc_enabled()  { [[ ",$(env_get COMPOSE_PROFILES)," == *",$1,"* ]]; }
svc_url() { # where a browser reaches the service, best effort
    local s="$1" sub port domain
    [[ "$s" == traefik ]] && { echo "-"; return; }   # it IS the https edge
    domain=$(env_get TRAEFIK_DOMAIN)
    sub=$(env_get "$(uvar "$s")_HOST"); [[ -n "$sub" ]] || sub=$(svc_label "$s" mediastack.subdomain)
    # a subdomain only yields an https URL when a domain is actually configured;
    # without one, fall through to the host:port (or internal) form below rather
    # than printing a dead https://<sub>.unset
    if [[ -n "$sub" && -n "$domain" ]]; then echo "https://${sub}.${domain}"; return; fi
    port=$(svc_port "$s")
    [[ -z "$port" ]] && { echo "-"; return; }
    [[ "$(svc_label "$s" mediastack.internal)" == "true" ]] \
        && echo "internal :${port}" \
        || echo "http://$(hostname):${port}"
}
svc_deps()     { # direct dependencies: depends_on + shared network namespace
    render
    jq -r --arg s "$1" '.services[$s]
        | ((.depends_on // {}) | keys[]?),
          (if ((.network_mode // "") | startswith("service:"))
           then (.network_mode | ltrimstr("service:")) else empty end)' \
        <<<"$RENDERED_JSON" | sort -u
}
resolve_deps() { # expand a service set to include all transitive dependencies
    local set=" $* " grew=1 s d
    while (( grew )); do
        grew=0
        for s in $set; do
            for d in $(svc_deps "$s"); do
                [[ "$set" == *" $d "* ]] || { set+="$d "; grew=1; info "  + $d (required by $s)"; }
            done
        done
    done
    echo "$set" | xargs -n1 | awk 'NF' | sort -u
}

# ------------------------------------------------------------------ mounts --
require_mounts() {
    local root path expect actual
    for root in CONFIG_ROOT DATA_ROOT CACHE_ROOT BACKUP_ROOT; do
        path=$(env_get "$root"); expect=$(env_get "${root}_SOURCE")
        [[ -z "$path" || -z "$expect" ]] && continue
        actual=$(timeout 5 findmnt -rn -o SOURCE --target "$path" 2>/dev/null) || {
            die "$root ($path): mount check timed out — stale or hung network mount.
  Fix the share (e.g. 'sudo umount -l $path' then remount) and retry."
        }
        [[ "$actual" == "$expect" ]] || die "$root ($path) expected on '$expect' but found '$actual'.
  The share is not mounted — starting now would write to the wrong disk.
  Fix: 'sudo mount $path' (or check the NAS), then retry."
    done
}

# =============================================================== subcommands
cmd_help() { # rendered from VERBS: one line per verb, grouped; depth lives in README
    echo "${C_BLD}Mediastack${C_RST} — usage: ./mediastack.sh <command> [args]"
    local g e usage desc w=0
    for e in "${VERBS[@]}"; do usage=$(cut -d'~' -f2 <<<"$e"); (( ${#usage} > w )) && w=${#usage}; done
    for g in Setup Run Maintain Connect Check Other Internal; do
        echo
        [[ "$g" == Internal ]] && echo "Internal (used by the panel, timers and units — not meant for hand use)" || echo "$g"
        for e in "${VERBS[@]}"; do
            [[ "$(cut -d'~' -f4 <<<"$e")" == "$g" ]] || continue
            usage=$(cut -d'~' -f2 <<<"$e"); desc=$(cut -d'~' -f5 <<<"$e")
            printf '  %-*s  %s\n' "$w" "$usage" "$desc"
        done
    done
    echo
    echo "Every verb rejects arguments it does not accept. Details, options and"
    echo "worked examples: README.md and docs/."
}

cmd_menu() {
    local opts=(up down status doctor update backup leak-test configure help exit)
    while true; do
        echo; hr "Mediastack menu"
        local i=1; for o in "${opts[@]}"; do echo "  $i) $o"; ((i++)); done
        local pick; read -r -p "Choice: " pick
        [[ "$pick" =~ ^[0-9]+$ ]] && (( pick>=1 && pick<=${#opts[@]} )) || { warn "Pick 1-${#opts[@]}"; continue; }
        local cmd="${opts[$((pick-1))]}"
        [[ "$cmd" == exit ]] && return 0
        "cmd_${cmd//-/_}" || warn "'$cmd' exited with an error (see above)"
    done
}

# ----------------------------------------------------------------- install --
cmd_install() {
    hr "Host dependencies"
    [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release — unsupported OS."
    # shellcheck disable=SC1091
    source /etc/os-release
    case "${ID:-}" in
        debian|ubuntu) ok "Detected ${PRETTY_NAME}" ;;
        *) die "This installer supports Debian/Ubuntu (apt). Detected: ${PRETTY_NAME:-unknown}.
  Docker + compose v2.20+, jq, curl and git installed manually will also work." ;;
    esac
    info "Installing base packages (curl, git, jq, ca-certificates, argon2)..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq curl git jq ca-certificates argon2 >/dev/null
    if ! command -v docker >/dev/null 2>&1; then
        info "Installing Docker from Docker's official repository..."
        sudo install -m 0755 -d /etc/apt/keyrings
        sudo curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
        sudo chmod a+r /etc/apt/keyrings/docker.asc
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
            | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
        sudo apt-get update -qq
        sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null
        ok "Docker installed"
    else
        ok "Docker already present: $(docker --version)"
    fi
    local cv min=2.24.0
    cv=$(sudo docker compose version --short 2>/dev/null || echo "0"); cv=${cv#v}
    ok "docker compose $cv"
    [[ "$(printf '%s\n%s\n' "$cv" "$min" | sort -V | head -n1)" == "$min" ]] \
        || warn "compose $cv < $min — 'include:'/wildcard profiles need $min+. Upgrade the compose plugin."
    echo; hr "Dependencies ready"
    cat <<'EOT'
Next step:   ./mediastack.sh configure

That's the guided setup. Every question explains itself and offers a
sensible default — pressing Enter through it gives a working stack.
It will ask about:
  * where configs, media, cache and backups live (defaults are fine)
  * which services to run (a recommended set is offered)
  * your VPN — HAVE THIS READY: a NordVPN access token
    (nordvpn.com -> Services -> NordVPN -> "Set up NordVPN manually"),
    or your provider's WireGuard private key if not using Nord
  * when automatic updates should run

Takes about 5 minutes. Safe to re-run any time — your answers become
the new defaults.
EOT
}

# --------------------------------------------------------------- configure --
explain() { echo; hr "$1"; shift; printf '%s\n' "$@"; echo; }

ask() { # ask VAR "prompt" "default" -> sets REPLY_VAL
    local def="$3" ans
    read -r -p "$2 [${def}]: " ans
    REPLY_VAL="${ans:-$def}"
}

ask_token() { # ask_token "prompt" "current" -> REPLY_VAL; pasted secrets:
    # hidden input, single entry (no typo-confirm — it's pasted), Enter
    # keeps the current value when one exists, empty is refused otherwise.
    local a hint=""
    [[ -n "${2:-}" ]] && hint=" [Enter keeps the current one]"
    while true; do
        read -r -s -p "$1${hint}: " a; echo
        if [[ -z "$a" ]]; then
            [[ -n "${2:-}" ]] && { REPLY_VAL="$2"; info "keeping the current value"; return 0; }
            warn "this value is required — paste it (input is hidden)"
            continue
        fi
        REPLY_VAL="$a"; return 0
    done
}

ask_secret() { # ask_secret "prompt" "generated-default" -> REPLY_VAL
    # Never echoes. Enter accepts the generated default (view: credentials);
    # a typed password must be entered twice to guard against blind typos.
    local a b
    while true; do
        read -r -s -p "$1 [Enter = accept a generated one]: " a; echo
        if [[ -z "$a" ]]; then
            REPLY_VAL="$2"
            info "using a generated password — view any time: ./mediastack.sh credentials"
            return 0
        fi
        read -r -s -p "Confirm password: " b; echo
        [[ "$a" == "$b" ]] && { REPLY_VAL="$a"; return 0; }
        fail "Passwords do not match — try again."
    done
}

ask_time() { # 24h HH:MM prompt with validation -> REPLY_VAL
    while true; do
        ask UPD_TIME "Time (24h, HH:MM)" "04:00"
        [[ "$REPLY_VAL" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] && return 0
        fail "'$REPLY_VAL' is not a valid HH:MM time (e.g. 04:00, 23:30)."
    done
}

abspath() { case "$1" in /*) echo "$1" ;; *) echo "$SCRIPT_DIR/${1#./}" ;; esac; }

fstype_of() { findmnt -rn -o FSTYPE --target "$1" 2>/dev/null || echo unknown; }
fsdev_of()  { stat -c %d "$1" 2>/dev/null || echo 0; }

configure_root() { # configure_root VAR title "explanation..." allow_network(yes/no)
    local var="$1" title="$2" text="$3" allow_net="$4" cur val fs
    cur=$(env_get "$var" "$(grep -E "^$var=" .env.example | head -1 | cut -d= -f2-)")
    explain "$title" "$text"
    while true; do
        ask "$var" "$title path" "$cur"; val=$(abspath "$REPLY_VAL")
        # Network shares must be mounted BEFORE this wizard runs — we record
        # the mount identity now and guard it forever after. Catch the trap:
        if grep -qsE "[[:space:]]${val}[[:space:]]" /etc/fstab && ! findmnt -rn "$val" >/dev/null 2>&1; then
            fail "'$val' is listed in /etc/fstab but NOT currently mounted.
  Continuing would record the wrong disk as this path's home. Fix first:
  sudo mount '$val'   (then re-enter the path here)"
            continue
        fi
        sudo mkdir -p "$val"
        fs=$(fstype_of "$val")
        if [[ "$allow_net" == no && "$fs" =~ ^(nfs|nfs4|cifs|smb3)$ ]]; then
            fail "'$val' is on a network share ($fs). App databases (SQLite)
  corrupt on network storage — this path must be a local disk. Your media
  can still live on the NAS via DATA_ROOT."
            continue
        fi
        [[ "$allow_net" == yes && "$fs" =~ ^(nfs|nfs4|cifs|smb3)$ ]] \
            && info "Network share detected ($fs) — fine for this root."
        env_set "$var" "$val"
        env_set "${var}_SOURCE" "$(findmnt -rn -o SOURCE --target "$val")"
        ok "$var = $val"
        break
    done
}

# --- configure wizard steps (one helper per `# -- …` block; each persists to
#     .env via env_set, so the driver's call order is the only sequencing). ---
_configure_timezone() {
    # -- timezone
    local tz_host tz_cur
    tz_host=$(timedatectl show -p Timezone --value 2>/dev/null || echo Etc/UTC)
    tz_cur=$(env_get TZ "$tz_host"); [[ "$tz_cur" == Etc/UTC ]] && tz_cur="$tz_host"
    explain "Timezone" \
        "Used for logs, schedules and in-app times. IANA format, e.g." \
        "Australia/Adelaide or America/Chicago. Your host reports: $tz_host" \
        "If unsure, accept the default."
    while true; do
        ask TZ "Timezone" "$tz_cur"
        if [[ -f "/usr/share/zoneinfo/$REPLY_VAL" ]]; then
            env_set TZ "$REPLY_VAL"
            ok "TZ=$REPLY_VAL — current time there: $(TZ=$REPLY_VAL date '+%H:%M %Z')"
            break
        fi
        fail "'$REPLY_VAL' is not a valid timezone."
        info "Close matches:"; find /usr/share/zoneinfo -type f 2>/dev/null \
            | sed 's|/usr/share/zoneinfo/||' | grep -i "${REPLY_VAL##*/}" | head -5 || true
    done

}

_configure_roots() {
    # -- roots
    configure_root CONFIG_ROOT "Config directory" \
"Where every service keeps its settings and databases. A few GB.
  * MUST be on a local disk (databases corrupt on network shares).
  * Default keeps it inside this folder — simple, but note: deleting
    this repo folder then deletes your configs. Backups cover you." no
    configure_root DATA_ROOT "Data directory" \
"Your media library and torrent downloads — usually the largest folder,
often on a NAS or a big second drive, NOT the system disk.
  * Network shares are fine here — but this wizard does NOT create mounts.
    Set one up first with './mediastack.sh add-mount', then enter its path;
    the wizard records the mount and refuses to start if it ever drops.
  * Just testing? Accept the default local path.
  * Keep torrents and media on the SAME drive or imports become slow
    full copies instead of instant hardlinks (checked below)." yes
    configure_root CACHE_ROOT "Cache directory" \
"Disposable data: transcodes, image caches, the search index. Losing it
costs a regeneration, nothing more. Network storage is fine; note that
transcode segments on NFS can stutter playback on transcoding hosts." yes
    configure_root BACKUP_ROOT "Backup directory" \
"Where restore points are written before every update. A NAS path is
ENCOURAGED — backups on the same disk as the configs aren't backups.
(As above: mount the share first; the wizard doesn't create mounts.)" yes

    # hardlink check
    if [[ $(fsdev_of "$(env_get DATA_ROOT)") != "$(fsdev_of "$(env_get DATA_ROOT)/torrent" 2>/dev/null || fsdev_of "$(env_get DATA_ROOT)")" ]]; then
        warn "DATA_ROOT and its torrent subdir are on different filesystems — hardlinks will not work: imports fall back to slow, space-doubling copies. Union the drives (e.g. mergerfs) and use the pool as DATA_ROOT (see README)."
    fi

}

_configure_selfheal() {
    # -- self-heal FIRST: adopt any *_UID / *_UPDATE vars new fragments
    # reference, so the render below never sees unset variables
    info "Checking for newly added services..."
    local ref base
    base=$(env_get UID_BASE 13000)
    while read -r ref; do
        if ! grep -qE "^${ref}=" "$ENV_FILE"; then
            if [[ "$ref" == *_UID ]]; then
                local max
                max=$(grep -E '_UID=[0-9]+' "$ENV_FILE" | cut -d= -f2 | sort -n | tail -1)
                env_set "$ref" "$(( ${max:-$base} + 1 ))"
                info "New service variable $ref -> $(env_get "$ref")"
            elif [[ "$ref" == *_UPDATE ]]; then
                env_set "$ref" true
            fi
        fi
    done < <(grep -rhoE '\$\{[A-Z0-9_]+_(UID|UPDATE)[^}]*\}' docker-compose.yml compose.d/ docker-compose.override.yml 2>/dev/null \
             | sed -E 's/\$\{([A-Z0-9_]+).*/\1/' | sort -u)

}

_configure_services() {
    # -- services (à la carte)
    render
    local STD="gluetun qbittorrent sonarr radarr prowlarr jellyfin meilisearch jellysearch seerr"
    explain "Services" \
"Pick exactly what runs — anything, à la carte. Dependencies are handled
for you (picking qBittorrent brings the VPN; JellySearch brings its
search engine). Change any of this later with enable/disable." \
"  1) standard    the recommended setup: VPN, qBittorrent, Sonarr, Radarr," \
"                 Prowlarr, Jellyfin + instant search, request site." \
"                 No proxy: services answer on http://<host>:<port>; add" \
"                 HTTPS names later with: enable traefik + traefik-setup" \
"  2) everything  all $(svc_managed | wc -l) services" \
"  3) custom      yes/no through each service"
    local mode sel="" cur_en s d dp
    ask SVC_MODE "Choice" "1"; mode="$REPLY_VAL"
    cur_en=",$(env_get COMPOSE_PROFILES),"
    case "$mode" in
        2) sel=$(svc_managed | tr '\n' ' ') ;;
        3) for s in $(svc_managed); do
               d=$(svc_label "$s" mediastack.desc)
               # default: current state if configured before, else standard membership
               local dp def
               if [[ "$cur_en" == *",$s,"* || ( "$cur_en" == ",," && " $STD " == *" $s "* ) ]]; then
                   dp="Y/n"; def=y
               else
                   dp="y/N"; def=n
               fi
               read -r -p "  $s — ${d:-no description} [$dp]: " REPLY_VAL
               REPLY_VAL="${REPLY_VAL:-$def}"
               [[ "${REPLY_VAL,,}" == y* ]] && sel+="$s "
           done ;;
        *) sel="$STD" ;;
    esac
    [[ -n "$sel" ]] || die "No services selected — nothing to run."
    info "Resolving dependencies..."
    sel=$(resolve_deps $sel)
    env_set COMPOSE_PROFILES "$(echo "$sel" | paste -sd, -)"
    ok "Enabled: $(env_get COMPOSE_PROFILES)"

}

_configure_vpn() {
    # -- VPN
    explain "VPN (gluetun)" \
"All download traffic runs inside a VPN container. Supported: any gluetun
provider (nordvpn, mullvad, protonvpn, surfshark, ...) or 'custom' to paste
your own WireGuard details (for fussy/unlisted providers)."
    ask VPN_PROVIDER "VPN provider" "$(env_get VPN_PROVIDER nordvpn)"
    env_set VPN_PROVIDER "$REPLY_VAL"
    local wg_cur; wg_cur=$(env_get WIREGUARD_PRIVATE_KEY)
    case "$REPLY_VAL" in
        nordvpn)
            if [[ -n "$wg_cur" ]] && ! confirm "A WireGuard key is already set. Replace it?"; then
                ok "Keeping existing key."
            else
                explain "NordVPN token" \
"1. Log in at nordvpn.com -> Services -> NordVPN" \
"2. 'Set up NordVPN manually' -> generate an access token" \
"3. Copy it (it is shown only once) and paste it below." \
"The key is fetched from Nord's API — nothing is installed on this host."
                local tok key
                read -r -p "NordVPN access token: " tok
                key=$(curl -fsS -u "token:${tok}" \
                      "https://api.nordvpn.com/v1/users/services/credentials" \
                      | jq -r '.nordlynx_private_key // empty') \
                    || die "Could not reach Nord's API. Check connectivity and retry."
                [[ -n "$key" ]] || die "Token rejected by NordVPN — regenerate it and re-run configure."
                env_set WIREGUARD_PRIVATE_KEY "$key"
                ok "WireGuard key fetched and verified."
                local cc
                ask VPN_SERVER_COUNTRIES "Server country (e.g. Switzerland; empty = auto)" "$(env_get VPN_SERVER_COUNTRIES)"
                cc="$REPLY_VAL"; env_set VPN_SERVER_COUNTRIES "$cc"
            fi ;;
        custom)
            explain "Manual WireGuard" \
"Paste values from your provider's WireGuard config file ([Interface]
PrivateKey and Address). See gluetun's wiki page 'Custom provider' for
the remaining server-side settings to add to .env / an override file."
            ask WIREGUARD_PRIVATE_KEY "PrivateKey" "$wg_cur"; env_set WIREGUARD_PRIVATE_KEY "$REPLY_VAL"
            ask WIREGUARD_ADDRESSES "Address" "$(env_get WIREGUARD_ADDRESSES 10.5.0.2/32)"; env_set WIREGUARD_ADDRESSES "$REPLY_VAL" ;;
        *)
            explain "Provider: $REPLY_VAL" \
"Follow gluetun's wiki for '$REPLY_VAL' to obtain your WireGuard private
key, then paste it below. Country selection works the same for all."
            ask WIREGUARD_PRIVATE_KEY "WireGuard private key" "$wg_cur"; env_set WIREGUARD_PRIVATE_KEY "$REPLY_VAL"
            ask VPN_SERVER_COUNTRIES "Server country (empty = auto)" "$(env_get VPN_SERVER_COUNTRIES)"; env_set VPN_SERVER_COUNTRIES "$REPLY_VAL" ;;
    esac

}

_configure_secrets() {
    # -- secrets
    if [[ -z "$(env_get MEILI_MASTER_KEY)" ]]; then
        env_set MEILI_MASTER_KEY "$(openssl rand -base64 32 2>/dev/null || head -c32 /dev/urandom | base64)"
        ok "Generated Meilisearch master key (machine secret — you never need it)."
    fi
    if svc_enabled cloudflared && [[ -z "$(env_get CLOUDFLARE_TUNNEL_TOKEN)" ]]; then
        explain "Cloudflare tunnel" \
"The tunnel is created on CLOUDFLARE'S side; this stack just runs the
connector. One-time setup in their dashboard:" \
"  1. dash.cloudflare.com -> Zero Trust -> Networks -> Tunnels" \
"  2. Create a tunnel (type: cloudflared), name it, save" \
"  3. From the install step, copy ONLY the long token string" \
"     (the part after '--token' in the command they show)" \
"AFTER the stack is up, routing also lives in that dashboard: add Public
Hostnames pointing at http://traefik:80 if Traefik is enabled (one
hostname per service, same names as your HTTPS routes) or directly at a
service, e.g. http://jellyfin:8096. Service names resolve — cloudflared
shares the stack's network."
        read -r -p "Tunnel token: " REPLY_VAL
        [[ -n "$REPLY_VAL" ]] && env_set CLOUDFLARE_TUNNEL_TOKEN "$REPLY_VAL" \
            || warn "No token — cloudflared will crash-loop until one is set in .env."
    fi
    if svc_enabled pihole && [[ -z "$(env_get PIHOLE_PASSWORD)" ]]; then
        env_set PIHOLE_PASSWORD "$(head -c12 /dev/urandom | base64 | tr -d '=+/')"
        ok "Generated Pi-hole admin password (view it any time in .env)."
    fi

}

_configure_schedule() {
    # -- update schedule
    local sched_cur; sched_cur=$(env_get UPDATE_SCHEDULE)
    explain "Automatic updates" \
"Nightly-style pipeline: restore point first, then pull + apply, then a
health check — one command rolls anything back. Updates briefly stop
services, so pick a quiet time for YOUR users." \
"  1) daily       every day at a time you pick" \
"  2) weekly      one day a week (a good default for a stable stack)" \
"  3) weekdays    Mon–Fri at a time you pick" \
"  4) weekends    Sat+Sun at a time you pick" \
"  5) custom      raw systemd OnCalendar expression" \
"  6) never       manual './mediastack.sh update' only" \
"$( [[ -n "$sched_cur" ]] && echo "  0) keep current: $sched_cur" )"
    local expr="" t day
    while true; do
        ask SCHED_MODE "Choice" "$( [[ -n "$sched_cur" ]] && echo 0 || echo 1 )"
        case "$REPLY_VAL" in
            0) [[ -n "$sched_cur" ]] || { fail "Nothing to keep."; continue; }
               expr="$sched_cur" ;;
            1) ask_time; expr="*-*-* $REPLY_VAL" ;;
            2) while true; do
                   ask UPD_DAY "Day (Mon/Tue/Wed/Thu/Fri/Sat/Sun)" "Tue"
                   day="${REPLY_VAL:0:1}"; day="${day^^}${REPLY_VAL:1:2}"; day="${day:0:3}"
                   [[ "$day" =~ ^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)$ ]] && break
                   fail "'$REPLY_VAL' is not a weekday name."
               done
               ask_time; expr="$day $REPLY_VAL" ;;
            3) ask_time; expr="Mon..Fri $REPLY_VAL" ;;
            4) ask_time; expr="Sat,Sun $REPLY_VAL" ;;
            5) explain "Custom schedule" \
"Any systemd OnCalendar expression, e.g.:" \
"  Tue,Fri 04:00      twice a week      *-*-01 03:00   1st of the month" \
"  Mon..Fri 03:30     weekday early     (validated before it is saved)"
               ask UPDATE_SCHEDULE "OnCalendar expression" "*-*-* 04:00"; expr="$REPLY_VAL" ;;
            6) env_set UPDATE_SCHEDULE ""
               ok "Automatic updates disabled (manual 'update' only)."; expr=""; break ;;
            *) fail "Pick 0-6."; continue ;;
        esac
        if [[ -n "$expr" ]]; then
            systemd-analyze calendar "$expr" >/dev/null 2>&1 \
                || { fail "'$expr' is not a valid schedule."; continue; }
            env_set UPDATE_SCHEDULE "$expr"
            ok "Schedule: $expr — next runs:"
            systemd-analyze calendar --iterations=3 "$expr" | grep -E 'Next elapse|Iter' | head -3 || true
            break
        fi
        break
    done

}

cmd_configure() {
    need_cmd jq; need_cmd docker
    [[ -f "$ENV_FILE" ]] || { cp .env.example "$ENV_FILE"; chmod 600 "$ENV_FILE"; info "Created .env from .env.example"; }
    chmod 600 "$ENV_FILE" || true

    _configure_timezone
    _configure_roots
    _configure_selfheal
    _configure_services
    _configure_vpn
    _configure_secrets
    _configure_schedule

    provision
    [[ -n "$(env_get UPDATE_SCHEDULE)" ]] && cmd_apply_timer

    echo; hr "Configure complete"
    cat <<EOF
Next steps:
  1. ./mediastack.sh up          start everything
  2. ./mediastack.sh doctor      verify the deployment
  3. ./mediastack.sh leak-test   prove the VPN cannot leak
Then open the apps (URLs and ports: ./mediastack.sh status) and connect them to each other.
EOF
}

provision() {
    hr "Provisioning users, group, folders"
    load_env; render
    local gid; gid=$(env_get MEDIA_GROUP_GID 13000)
    getent group mediacenter >/dev/null || { sudo groupadd -g "$gid" mediacenter; ok "group mediacenter ($gid)"; }
    local s v uid croot droot cache
    croot=$(env_get CONFIG_ROOT); droot=$(env_get DATA_ROOT); cache=$(env_get CACHE_ROOT)
    for s in $(svc_enabled_managed); do
        v="$(uvar "$s")_UID"; uid=$(env_get "$v")
        if [[ -n "$uid" ]] && ! getent passwd "$s" >/dev/null; then
            # no -r: it only warns about our (deliberate) high UIDs; with an
            # explicit -u it contributes nothing that -M and nologin don't.
            sudo useradd -M -s /usr/sbin/nologin -u "$uid" -g mediacenter "$s" \
                && ok "user $s ($uid)" \
                || warn "could not create user $s (uid $uid taken? doctor will flag it)"
        fi
        if [[ $(svc_label "$s" mediastack.config) == "true" ]]; then
            sudo mkdir -p "$croot/$s"
            [[ -n "$uid" ]] && sudo chown "$uid:mediacenter" "$croot/$s"
        fi
        if [[ $(svc_label "$s" mediastack.cache) == "true" ]]; then
            sudo mkdir -p "$cache/$s"
            [[ -n "$uid" ]] && sudo chown "$uid:mediacenter" "$cache/$s"
        fi
        # Nested bind mounts (e.g. cache inside config): docker creates the
        # inner mountpoint stub as root if missing — pre-create it owned right.
        # Only when MISSING: some services (olivetin) nest *file* mounts under a
        # dir mount, already written by their own installer; mkdir -p there would
        # error ("File exists") or, if the file were absent, create a directory
        # over it and break the mount.
        local stub
        while read -r stub; do
            [[ -z "$stub" ]] && continue
            # One atomic elevated call: test -> create -> own, in a single sudo
            # invocation with detached stdin. Collapsing the previous
            # test/&&/mkdir/chown sequence sidesteps whatever interaction it had
            # with this loop's input stream inside the live provision run (the
            # two-call form skipped existing paths correctly in isolation, but
            # not in situ). Path and uid pass as argv; the body is single-quoted
            # (no interpolation), so the front-door audit stays green.
            sudo sh -c 'test -e "$1" && exit 0; mkdir -p "$1" && { [ -z "$2" ] || chown "$2:mediacenter" "$1"; }' \
                _ "$stub" "$uid" </dev/null
        done < <(jq -r --arg s "$s" '
            (.services[$s].volumes // []) | map(select(.type=="bind")) as $v
            | [ $v[] as $o | $v[] as $i
                | select($i.target != $o.target)
                | select($i.target | startswith($o.target + "/"))
                | $o.source + ($i.target | ltrimstr($o.target)) ]
            | unique | .[]' <<<"$RENDERED_JSON")
    done
    # per-instance data dirs from the label contract
    local dd
    for s in $(svc_enabled_managed); do
        for dd in $(svc_label "$s" mediastack.datadirs); do
            sudo mkdir -p "$droot/$dd"
            sudo chown ":mediacenter" "$droot/$dd"
            sudo chmod 2775 "$droot/$dd"
        done
        # seed the in-app port BEFORE first boot: extra instances share
        # gluetun's namespace, so the image default port would collide
        local ap
        ap=$(svc_label "$s" mediastack.appport)
        if [[ -n "$ap" && ! -f "$croot/$s/config.xml" ]]; then
            printf '<Config>\n  <Port>%s</Port>\n</Config>\n' "$ap" | sudo tee "$croot/$s/config.xml" >/dev/null
            v="$(uvar "$s")_UID"; uid=$(env_get "$v")
            [[ -n "$uid" ]] && sudo chown "$uid:mediacenter" "$croot/$s/config.xml"
            info "$s: seeded in-app port $ap (namespace-shared instance)"
        fi
    done
    # data tree: shared group, setgid so new files inherit it.
    # The recursive pass runs ONLY when the tree root isn't group-correct yet:
    # on a real library this is TBs — never re-walk it on every configure.
    local d
    for sub in tv movies music books other; do sudo mkdir -p "$droot/torrent/$sub"; done
    # media carries the reading/listening trees too (audiobookshelf, kavita)
    for sub in tv movies music books audiobooks podcasts comics manga other; do
        sudo mkdir -p "$droot/media/$sub"
    done
    if [[ "$(stat -c %G "$droot" 2>/dev/null)" != mediacenter ]]; then
        info "first-time data tree ownership pass (may take a while on large trees)..."
        sudo chown -R ":mediacenter" "$droot" 2>/dev/null || true
        sudo chmod -R g+rwX "$droot"
        sudo find "$droot" -type d -exec chmod g+s {} +
    fi
    ok "data tree ready (group mediacenter, setgid)"
    sudo mkdir -p "$(env_get BACKUP_ROOT)"
}

# ------------------------------------------------------------- up/down/... --
reconcile_disabled() {
    # compose does NOT treat profile-disabled services as orphans (verified
    # on compose 5.x): their containers survive `up --remove-orphans`.
    # Remove them explicitly. -v drops their anonymous volumes too.
    render
    local s cn
    for s in $(svc_disabled_managed); do
        cn=$(svc_cname "$s")
        if [[ $(c_state "$cn") != absent ]]; then
            sudo docker rm -f -v "$cn" >/dev/null; INSPECT_JSON=""
            info "removed container for disabled service: $s"
        fi
    done
}

# ------------------------------------------------------- host port audit --
port_collisions() { # port_collisions [profiles] -> one line per host port published twice
    # Reads the rendered config (the VPN overlay decides who publishes what,
    # so call it after vpn_gen with the render cache cleared). A service is in
    # scope when its name is in COMPOSE_PROFILES — the same test svc_enabled
    # uses; pass a prospective list to check before enabling. gluetun's
    # mappings bind whenever gluetun runs (the overlay publishes every
    # toggle-enabled service through it, enabled or not), so gluetun counts as
    # a whole; each of its mappings is attributed to the namespace-sharing
    # service listening on that target port, so the finding names the app.
    render
    jq -r --arg prof ",${1:-$(env_get COMPOSE_PROFILES)}," '
        .services as $all
        | ($all | to_entries
            | map(select((.value.network_mode // "") == "service:gluetun")
                  | {key: (.value.labels["mediastack.port"] // ""), value: .key})
            | from_entries) as $owner
        | [ $all | to_entries[]
            | .key as $s
            | select($prof | contains("," + $s + ","))
            | .value.ports[]?
            | select((.published // "") != "")
            | { port: "\(.host_ip // "")\(.published)/\(.protocol // "tcp")",
                who:  (if $s == "gluetun" and ($owner[.target|tostring] // "") != ""
                       then "\($owner[.target|tostring]) (via gluetun)" else $s end) } ]
        | group_by(.port) | map(select(length > 1))[]
        | "\(.[0].port): \(map(.who) | join(" and "))"' <<<"$RENDERED_JSON"
}
require_free_ports() { # require_free_ports [profiles]; dies before docker can fail mid-apply
    local found
    found=$(port_collisions "$@") || die "port audit could not evaluate the rendered config — nothing verified (see jq's message above)"
    [[ -z "$found" ]] || die "host port collision — the same port would be published twice:
$(sed 's/^/  /' <<<"$found")
  Docker would refuse the second bind halfway through starting the stack.
  Fix: give one of them a free host port in .env (<SVC>_PORT=…; see docs/adding-a-service.md), then re-run."
}

cmd_up()   {
    load_env
    # vpn_gen FIRST: it reads base + override only, never the overlay, so it
    # always succeeds — and it must run before anything renders, because a
    # stale overlay (a stanza for a service since removed from the override)
    # makes every render fail. Regenerating it here is what makes
    # "disable, delete its block, up" the whole removal procedure.
    vpn_gen
    require_mounts; reconcile_disabled
    require_free_ports
    traefik_ensure
    if ! DC up -d --remove-orphans; then
        warn "First start attempt failed — usually gluetun's health race after a recreate."
        local gcn t=0; gcn=$(svc_cname gluetun)
        info "Waiting for the tunnel (up to 120s)..."
        while [[ $(c_health "$gcn") != healthy && $t -lt 120 ]]; do sleep 5; t=$((t+5)); done
        [[ $(c_health "$gcn") == healthy ]] \
            || die "gluetun never became healthy — nothing VPN'd was started.
  Inspect: ./mediastack.sh logs gluetun (bad credentials? provider outage?)"
        info "Tunnel up — starting the remaining services..."
        DC up -d --remove-orphans
    fi
    vpn_reattach_guard   # fail-closed: no service may run pinned to a dead gluetun
    vpnguard_ensure      # (re)install the boot/daemon guard unit
    ok "Stack started."
    cat <<'EOT'
Check on it:   ./mediastack.sh status    (what's running, health, versions)
Verify it:     ./mediastack.sh doctor    (full audit with fixes)
First time? Services need connecting to each other once — the README's
"After install" section walks through it app by app.
EOT
}
cmd_down() {
    load_env
    # --volumes: only anonymous volumes exist in this stack (VOLUME directives
    # in upstream images); all real state is in bind mounts, so this is safe
    # and stops orphaned-volume creep on every stop/start cycle.
    DC down --volumes
    ok "Stack stopped (configs and data untouched)."
}

cmd_enable() {
    local svc="${1:?usage: enable <service>}"; load_env
    svc_exists "$svc" || die "No service '$svc'. Known: $(svc_managed | tr '\n' ' ')"
    svc_enabled "$svc" && { ok "'$svc' already enabled."; return; }
    local sel cur; cur=$(env_get COMPOSE_PROFILES | tr ',' ' ')
    # shellcheck disable=SC2086  # word splitting intended: service list
    sel=$(resolve_deps "$svc" $cur)
    vpn_gen   # a toggle service enabled for the first time needs its overlay stanza before compose sees it
    RENDERED_JSON=""; require_free_ports "$(echo "$sel" | paste -sd, -)"   # refuse before .env changes
    env_set COMPOSE_PROFILES "$(echo "$sel" | paste -sd, -)"
    require_mounts; provision >/dev/null   # users/dirs for the new services
    traefik_ensure   # wizard + config gen if traefik just came into the set
    DC up -d --remove-orphans; ok "'$svc' enabled and started."
}
cmd_disable() {
    local svc="${1:?usage: disable <service>}"; load_env
    svc_enabled "$svc" || { ok "'$svc' is not enabled."; return; }
    local e deps blockers=""
    for e in $(env_get COMPOSE_PROFILES | tr ',' ' '); do
        [[ "$e" == "$svc" ]] && continue
        deps=$(svc_deps "$e")
        [[ " $deps " == *" $svc "* ]] && blockers+="$e "
    done
    [[ -n "$blockers" ]] && die "'$svc' is required by enabled service(s): $blockers
  Disable those first, or leave '$svc' running."
    env_set COMPOSE_PROFILES "$(env_get COMPOSE_PROFILES | tr ',' '\n' | grep -vx "$svc" | paste -sd, -)"
    reconcile_disabled
    ok "'$svc' disabled; its container was removed (config kept, still backed up)."
}

cmd_logs() {
    load_env
    # Interactive default follows; --no-follow returns a bounded snapshot, which
    # is what the web front door calls (a following stream would hang the action).
    local svc="" follow=(-f) a
    for a in "$@"; do
        case "$a" in
            --no-follow) follow=() ;;
            -*)          die "unknown option '$a' (usage: logs <service> [--no-follow])" ;;
            *)           [[ -z "$svc" ]] || die "logs takes one service (got '$svc' and '$a')"; svc="$a" ;;
        esac
    done
    [[ -n "$svc" ]] || die "usage: logs <service> [--no-follow]"
    DC logs "${follow[@]}" --tail=100 "$svc"
}

# ------------------------------------------------------------------ status --
# Container facts come from `docker inspect` JSON. A reporting command calls
# c_inspect_all once (one privileged call for every managed container) and
# every c_* reads the cache; without it, c_* inspects that one container —
# the same JSON, one call per fact. CACHE RULE: anything that creates,
# recreates, starts, stops or removes a container clears INSPECT_JSON (DC does
# it for every compose verb but config; raw `sudo docker` mutations do it
# explicitly), so a health poll after `up` never reads a stale snapshot.
c_inspect() { # c_inspect <cname>... -> JSON array of the containers that exist
    # a missing container is a normal state (before the first `up`); anything
    # else on stderr — daemon down, permission denied — is zero evidence: die
    local err out; err=$(mktemp)
    out=$(sudo docker inspect --type container "$@" 2>"$err") || true
    if grep -vE 'No such (object|container)' "$err" | grep -q .; then
        cat "$err" >&2; rm -f "$err"
        die "docker inspect failed — container state is unverifiable (evidence above)"
    fi
    rm -f "$err"; echo "${out:-[]}"
}
c_inspect_all() { # fill the cache for every managed container (see CACHE RULE)
    render
    local names
    names=$(jq -r '.services | to_entries[]
        | select(.value.labels["mediastack.managed"] == "true")
        | .value.container_name // .key' <<<"$RENDERED_JSON")
    [[ -n "$names" ]] || { INSPECT_JSON="[]"; return 0; }
    # projected to the fields c_get reads: a full inspect of 30 containers is
    # hundreds of KB that every c_* would re-parse — this keeps it to a few
    # shellcheck disable=SC2086  # one name per word
    INSPECT_JSON=$(c_inspect $names | jq -c '[ .[] | {Name, Id, Image, RestartCount,
        State: {Status: .State.Status, StartedAt: .State.StartedAt, Health: .State.Health},
        HostConfig: {NetworkMode: .HostConfig.NetworkMode},
        Config: {User: .Config.User, Labels: {"org.opencontainers.image.version": .Config.Labels["org.opencontainers.image.version"]}},
        Mounts: [ .Mounts[] | {Source, Destination} ] } ]')
}
# ADDING A FIELD TO c_get's READS = ADDING IT TO THE PROJECTION ABOVE, or the
# cached path silently returns "" where the uncached one returns the value.
c_get() { # c_get <cname> <jq path> -> the value, "" when the container is absent
    local j
    if [[ -n "$INSPECT_JSON" ]]; then j=$INSPECT_JSON; else j=$(c_inspect "$1"); fi
    jq -r --arg n "/$1" ".[] | select(.Name == \$n) | $2 // \"\"" <<<"$j"
}
c_state()  { local o; o=$(c_get "$1" '.State.Status'); echo "${o:-absent}"; }
c_health() { local o; o=$(c_get "$1" '.State.Health.Status'); echo "${o:--}"; }
c_uptime() { # human-readable duration since container start (e.g. 3d4h, 12m, 45s)
    local st sec
    st=$(c_get "$1" '.State.StartedAt')
    [[ -n "$st" ]] || { echo "-"; return; }
    sec=$(( $(date +%s) - $(date -d "$st" +%s 2>/dev/null || date +%s) ))
    (( sec < 0 )) && sec=0
    if   (( sec >= 86400 )); then echo "$((sec/86400))d$(( (sec%86400)/3600 ))h"
    elif (( sec >= 3600 ));  then echo "$((sec/3600))h$(( (sec%3600)/60 ))m"
    elif (( sec >= 60 ));    then echo "$((sec/60))m$((sec%60))s"
    else echo "${sec}s"; fi
}
c_version(){ c_get "$1" '.Config.Labels["org.opencontainers.image.version"]'; }
c_restarts(){ local o; o=$(c_get "$1" '.RestartCount'); echo "${o:-0}"; }
c_netmode(){ c_get "$1" '.HostConfig.NetworkMode'; }   # "container:<id>" when joined to another namespace
c_id()     { c_get "$1" '.Id'; }

# Machine-readable service lister — one service name per line, nothing else.
# Built for consumers that need a clean list to parse (e.g. a web UI populating
# a dropdown), and useful on the CLI too. Subsets mirror the sets the other
# verbs accept, so a caller can list exactly the services a given action will
# take. Read-only: renders the config and prints names, changes nothing.
cmd_list() {
    load_env
    # optional --json emits one Olivetin-style entity record per line
    # ({"name":"<svc>"}), for feeding an entity file that backs a UI dropdown.
    # Default is plain names, one per line.
    local json=0 subset="managed" a
    for a in "$@"; do
        case "$a" in
            --json) json=1 ;;
            all|managed|enabled|disabled|vpntoggle|wire|pinned) subset="$a" ;;
            *) die "usage: list [all|managed|enabled|disabled|vpntoggle|wire|pinned] [--json]" ;;
        esac
    done
    local names
    case "$subset" in
        all)        names=$(svc_all | sort) ;;
        managed)    names=$(svc_managed | sort) ;;
        enabled)    names=$(svc_enabled_managed) ;;
        disabled)   names=$(svc_disabled_managed) ;;
        vpntoggle)  render; names=$(jq -r '.services | to_entries[]
                        | select(.value.labels["mediastack.vpntoggle"]=="true") | .key' \
                        <<<"$RENDERED_JSON" | sort) ;;
        wire)       names=$(printf '%s\n' qbit arr prowlarr bazarr apprise cleanuparr lazylibrarian jellyfin seerr wizarr all) ;;
        pinned)     if [[ -s "$PINS_FILE" ]]; then
                        # service keys are 2-space-indented `  <svc>:`; the image
                        # line is 4-space-indented and won't match.
                        names=$(grep -oE '^  [a-z0-9][a-z0-9-]*:' "$PINS_FILE" | tr -d ' :' | sort || true)
                    else names=""; fi ;;
    esac
    [[ -z "$names" ]] && return 0
    if (( json )); then
        # jq -R reads each raw line; build a safe object (handles any chars).
        printf '%s\n' "$names" | jq -R '{name: .}' -c
    else
        printf '%s\n' "$names"
    fi
}

cmd_status() {
    load_env; render
    if [[ -n "${1:-}" ]]; then status_one "$1"; return; fi
    c_inspect_all
    hr "Mediastack status"
    printf "%-14s %-5s %-5s %-9s %-10s %-12s %-8s %-9s %s\n" SERVICE PORT VPN STATE HEALTH VERSION PINNED UPTIME URL
    local s cn pin vpn port rec bvpn
    bvpn=$(vpn_base_json)   # base (pre-overlay) labels = recommended VPN settings
    for s in $(svc_enabled_managed); do
        cn=$(svc_cname "$s")
        pin=no; [[ -s "$PINS_FILE" ]] && grep -q "^  $s:" "$PINS_FILE" && pin="${C_YLW}yes${C_RST}"
        vpn=off; [[ $(svc_label "$s" mediastack.vpn) == "true" ]] && vpn=on
        [[ "$s" == gluetun ]] && vpn=self   # gluetun IS the tunnel, not behind it
        # flag a toggle-enabled service that's been moved off its recommended setting
        if [[ $(jq -r --arg s "$s" '.services[$s].labels["mediastack.vpntoggle"]//""' <<<"$bvpn") == "true" ]]; then
            rec=$(vpn_onoff "$(jq -r --arg s "$s" '.services[$s].labels["mediastack.vpn"]//"false"' <<<"$bvpn")")
            [[ "$vpn" == "$rec" ]] || vpn+="*"
        fi
        port=$(svc_port "$s"); port=${port:--}
        printf "%-14s %-5s %-5s %-9s %-10s %-12s %-8s %-9s %s\n" \
            "$s" "$port" "$vpn" "$(c_state "$cn")" "$(c_health "$cn")" "$(c_version "$cn" | cut -c1-12)" "$pin" "$(c_uptime "$cn")" "$(svc_url "$s")"
    done
    echo
    info "VPN: on = via the tunnel, off = direct, self = the tunnel itself · * = changed from recommended · change: ./mediastack.sh vpn"
    local off="" p
    for p in $(svc_disabled_managed); do off+="$p "; done
    [[ -n "$off" ]] && info "Available, not enabled: $off"
    local last; last=$(ls -1 "$(env_get BACKUP_ROOT)" 2>/dev/null | tail -1 || true)
    info "Latest restore point: ${last:-none yet (run: ./mediastack.sh backup)}"
    df -h "$(env_get CONFIG_ROOT)" "$(env_get DATA_ROOT)" 2>/dev/null | tail -n +2 | sort -u \
        | awk '{printf ":: disk %-24s %s used of %s (%s)\n", $6, $3, $2, $5}'
}

status_one() {
    local s="$1"; svc_exists "$s" || die "No service '$s'. Known: $(svc_managed | tr '\n' ' ')"
    local cn st; cn=$(svc_cname "$s")
    INSPECT_JSON=$(c_inspect "$cn")   # one call; every fact below reads it
    st=$(c_state "$cn")
    hr "$s"
    echo "container : $cn"
    echo "state     : $st   health: $(c_health "$cn")"
    echo "image     : $(svc_image "$s")  version: $(c_version "$cn")"
    if [[ "$st" == absent ]]; then
        echo "user      : -"
        echo "restarts  : -"
        echo "mounts    :"
    else
        echo "user      : $(c_get "$cn" '.Config.User')"
        echo "restarts  : $(c_get "$cn" '.RestartCount')"
        echo "mounts    :"
        c_get "$cn" '(.Mounts[] | "  \(.Source) -> \(.Destination)")'
        echo
    fi
    hr "last 15 log lines"
    sudo docker logs --tail 15 "$cn" 2>&1 || true
}

# ------------------------------------------------------- upgrade/uninstall --
cmd_upgrade() {
    need_cmd git
    # -uno: untracked files (like the .wired marker) are deployment state,
    # not a pull hazard — only tracked modifications block an upgrade.
    [[ -z "$(git status --porcelain -uno 2>/dev/null)" ]] || die "Working tree has local changes to tracked files.
  Mediastack keeps user state in .env / override files, so tracked files
  should be clean. Review 'git status', stash or move changes into
  docker-compose.override.yml, then retry."
    local before; before=$(git rev-parse HEAD)
    git pull --ff-only || die "git pull failed (diverged history?). Resolve manually."
    [[ "$before" == "$(git rev-parse HEAD)" ]] && { ok "Already up to date."; return; }
    hr "Changes pulled"; git log --oneline "$before..HEAD" | sed 's/^/  /'
    load_env   # runs schema migrations
    provision >/dev/null || true
    # say what (if anything) the pull requires — images are never part of
    # an upgrade, so they are never mentioned here (that's: update, nightly)
    local changed
    changed=$(git diff --name-only "$before..HEAD" 2>/dev/null || true)
    if grep -qE '^(compose\.d/|docker-compose\.yml)' <<<"$changed"; then
        ok "Upgrade complete. Compose definitions changed — apply them: ./mediastack.sh up"
    elif grep -qE '^mediastack\.sh' <<<"$changed"; then
        ok "Upgrade complete. New tooling is live from the next command — nothing to apply."
    else
        ok "Upgrade complete. Docs/templates only — nothing to apply."
    fi
}

cmd_nuke() {
    # Deliberately does NOT need a working compose render or .env — it must
    # succeed on a half-deleted deployment. Containers are found by compose
    # project label; users by the mediacenter group in /etc/passwd.
    hr "NUKE: remove everything the installer created"
    echo "Removes: containers, docker network, systemd units,"
    echo "         service users + group, CONFIG_ROOT, CACHE_ROOT."
    echo "Keeps  : DATA_ROOT (your media), BACKUP_ROOT (restore points),"
    echo "         .env, this repo folder, and pulled docker images (shared"
    echo "         cache — 'docker image prune -a' reclaims them)."
    echo "Running containers are stopped and removed by this command — no"
    echo "need to stop anything first. (Just never skip this and rm -rf the"
    echo "folder instead: running containers resurrect their mount dirs.)"
    local really; read -r -p "Type 'nuke mediastack' to proceed: " really
    [[ "$really" == "nuke mediastack" ]] || { info "Aborted — nothing touched."; return 1; }

    sudo systemctl disable --now mediastack-update.timer 2>/dev/null || true
    sudo systemctl disable --now mediastack-vpnguard.service 2>/dev/null || true
    sudo rm -f /etc/systemd/system/mediastack-update.service /etc/systemd/system/mediastack-update.timer /etc/systemd/system/mediastack-vpnguard.service
    sudo systemctl daemon-reload
    frontdoor_teardown
    ok "systemd units removed"
    sudo docker ps -aq --filter "label=com.docker.compose.project=mediastack" \
        | xargs -r sudo docker rm -f -v >/dev/null; INSPECT_JSON=""
    ok "containers removed (with their anonymous volumes)"
    rm -f "$PINS_FILE"
    sudo docker network rm mediastack >/dev/null 2>&1 && ok "network removed" || true

    local gid u
    gid=$(getent group mediacenter | cut -d: -f3 || true)
    if [[ -n "$gid" ]]; then
        for u in $(awk -F: -v g="$gid" '$4==g{print $1}' /etc/passwd); do
            sudo userdel "$u" 2>/dev/null && ok "user $u removed"
        done
        sudo groupdel mediacenter 2>/dev/null && ok "group mediacenter removed"
    fi

    local croot cache
    croot=$(env_get CONFIG_ROOT "$SCRIPT_DIR/config")
    cache=$(env_get CACHE_ROOT "$SCRIPT_DIR/cache")
    sudo rm -rf "$croot" "$cache"
    ok "removed $croot and $cache"
    ok "Nuked. Media and backups untouched. Safe to delete this folder now."
}

cmd_uninstall() {
    if [[ "${1:-}" == --nuke ]]; then cmd_nuke; return; fi
    load_env
    hr "Uninstall (tiered)"
    echo "Tier 1: remove containers + docker network (configs, data, users kept)"
    confirm "Proceed with tier 1?" || return 0
    DC down --remove-orphans --volumes; ok "containers removed (anonymous volumes included)"
    sudo systemctl disable --now mediastack-update.timer 2>/dev/null || true
    sudo systemctl disable --now mediastack-vpnguard.service 2>/dev/null || true
    sudo rm -f /etc/systemd/system/mediastack-update.service /etc/systemd/system/mediastack-update.timer /etc/systemd/system/mediastack-vpnguard.service
    sudo systemctl daemon-reload
    frontdoor_teardown
    echo; echo "Tier 2: remove the service system users + group"
    if confirm "Also remove users/group?"; then
        local s; for s in $(svc_managed); do sudo userdel "$s" 2>/dev/null || true; done
        sudo groupdel mediacenter 2>/dev/null || true; ok "users removed"
    fi
    echo; echo "Tier 3: DELETE ALL SERVICE CONFIGS at $(env_get CONFIG_ROOT) — irreversible."
    local really; read -r -p "Type 'delete my configs' to proceed (anything else skips): " really
    if [[ "$really" == "delete my configs" ]]; then
        sudo rm -rf "$(env_get CONFIG_ROOT)"; ok "configs deleted"
    else info "Configs kept."; fi
    ok "Uninstall finished. Media in DATA_ROOT and backups in BACKUP_ROOT were never touched."
}

cmd_add_mount() {
    explain "Add a host mount (NFS / SMB)" \
"Sets up a network share on THIS host the safe way:
  * /etc/fstab entry with systemd automount — boot never hangs on the NAS,
    the share attaches on first access and survives NAS reboots.
  * 'hard' mount — apps wait out a NAS blip instead of corrupting writes.
  * poison layer — the empty mountpoint is made immutable, so if the share
    is ever down, writes FAIL LOUDLY instead of silently filling your
    system disk behind the mount.
The share itself (NFS export / SMB share on the NAS) must already exist —
server-side setup is out of scope here."
    local mtype remote mpoint
    while true; do
        ask MOUNT_TYPE "Share type (nfs/cifs)" "nfs"
        mtype="$REPLY_VAL"; [[ "$mtype" == nfs || "$mtype" == cifs ]] && break
        fail "Answer 'nfs' or 'cifs' (cifs = SMB/Samba/Windows share)."
    done
    if [[ "$mtype" == nfs ]]; then
        explain "Remote path" "NFS form:  server:/export/path   e.g. 192.168.1.50:/volume1/media"
    else
        explain "Remote path" "SMB form:  //server/share        e.g. //192.168.1.50/media"
    fi
    ask MOUNT_REMOTE "Remote" ""
    remote="$REPLY_VAL"; [[ -n "$remote" ]] || die "Remote path is required."
    ask MOUNT_POINT "Local mountpoint (e.g. /mnt/media)" ""
    mpoint=$(abspath "${REPLY_VAL:?mountpoint required}")
    grep -qsE "[[:space:]]${mpoint}[[:space:]]" /etc/fstab \
        && die "$mpoint already has an fstab entry. Edit /etc/fstab manually or pick another path."
    findmnt -rn "$mpoint" >/dev/null 2>&1 && die "$mpoint is already a mountpoint."

    if [[ "$mtype" == nfs ]]; then
        info "Installing nfs-common..."
        sudo apt-get install -y -qq nfs-common >/dev/null
    else
        info "Installing cifs-utils..."
        sudo apt-get install -y -qq cifs-utils >/dev/null
    fi

    sudo mkdir -p "$mpoint"
    [[ -z "$(sudo ls -A "$mpoint")" ]] || die "$mpoint is not empty — mounting would hide its contents. Move them first."
    sudo chattr +i "$mpoint" 2>/dev/null \
        && ok "poison layer set (mountpoint immutable while unmounted)" \
        || warn "filesystem does not support chattr +i — poison layer skipped"

    local opts fsline
    if [[ "$mtype" == nfs ]]; then
        opts="_netdev,x-systemd.automount,hard,nfsvers=4.2,nofail"
        fsline="$remote $mpoint nfs4 $opts 0 0"
    else
        local smbuser smbpass credfile gid
        ask SMB_USER "SMB username" ""
        smbuser="$REPLY_VAL"
        read -r -s -p "SMB password: " smbpass; echo
        credfile="/etc/mediastack-cifs-$(basename "$mpoint")"
        printf 'username=%s\npassword=%s\n' "$smbuser" "$smbpass" | sudo tee "$credfile" >/dev/null
        sudo chmod 600 "$credfile"
        ok "credentials stored at $credfile (root-only)"
        gid=$( [[ -f "$ENV_FILE" ]] && env_get MEDIA_GROUP_GID 13000 || echo 13000 )
        # SMB has no POSIX ownership: map files to the shared media group.
        opts="_netdev,x-systemd.automount,hard,nofail,credentials=$credfile,uid=0,gid=$gid,file_mode=0664,dir_mode=2775,iocharset=utf8"
        fsline="$remote $mpoint cifs $opts 0 0"
    fi
    echo "$fsline" | sudo tee -a /etc/fstab >/dev/null
    ok "fstab entry written"
    sudo systemctl daemon-reload
    if sudo mount "$mpoint" 2>/dev/null && findmnt -rn "$mpoint" >/dev/null; then
        ok "$mpoint mounted from $remote"
        info "Use this path in './mediastack.sh configure' — the wizard will record and guard it."
    else
        fail "Mount FAILED. The fstab entry is kept (it is boot-safe: nofail+automount).
  Check: server reachable? export/share name right? credentials right?
  Retry with: sudo mount '$mpoint'
  Or remove the line from /etc/fstab to abandon it."
        exit 1
    fi
}

cmd_credentials() {
    load_env
    hr "Credentials (stored in .env)"
    printf '%-22s %s\n' "Arr apps user"        "$(env_get ARR_USER '(not set — run wire)')"
    printf '%-22s %s\n' "Arr apps password"    "$(env_get ARR_PASSWORD '(not set — run wire)')"
    printf '%-22s %s\n' "qBittorrent user"     "$(env_get QBITTORRENT_USER '(not set — run wire)')"
    printf '%-22s %s\n' "qBittorrent password" "$(env_get QBITTORRENT_PASSWORD '(not set — run wire)')"
    printf '%-22s %s\n' "Pi-hole password"     "$(env_get PIHOLE_PASSWORD '(dns profile not configured)')"
    printf '%-22s %s\n' "Traefik dash user"    "$(env_get TRAEFIK_DASH_USER '(traefik not configured)')"
    printf '%-22s %s\n' "Traefik dash password" "$(env_get TRAEFIK_DASH_PASSWORD '(traefik not configured)')"
    printf '%-22s %s\n' "Jellyfin admin user"   "$(env_get JELLYFIN_ADMIN_USER '(not set — run wire)')"
    printf '%-22s %s\n' "Jellyfin admin password" "$(env_get JELLYFIN_ADMIN_PASSWORD '(not set — run wire)')"
    printf '%-22s %s\n' "Jellyfin API key"      "$(env_get JELLYFIN_API_KEY '(not set — run wire jellyfin)')"
    printf '%-22s %s\n' "Wizarr API key"        "$(env_get WIZARR_API_KEY '(not set — run wire wizarr)')"
    info "Seerr owner = the Jellyfin admin above; all Seerr sign-ins use Jellyfin accounts (no separate Seerr passwords exist)."
    info "The Jellyfin API key is what Wizarr's Add Server form asks for."
    info "Wizarr's ADMIN login is its own account — set-credentials does not cover it; rotate in Wizarr's UI."
    info "Meilisearch master key is machine-to-machine — apps use it, you never need it."
}

cmd_set_credentials() { # rotate a stored credential in the app(s) AND .env, atomically
    load_env; render
    local target="${1:-}"
    case "$target" in arr|qbit|jellyfin|pihole|traefik|all) ;; *)
        die "usage: set-credentials <arr|qbit|jellyfin|pihole|traefik|all>
  arr       the shared login of every arr app (+ cleanuparr's account password)
  qbit      qBittorrent's WebUI login (+ every place that stores it)
  jellyfin  the Jellyfin admin password (Seerr/Wizarr need no change)
  pihole    the Pi-hole admin password
  traefik   the Traefik dashboard password
  all       ONE password across all of the above (usernames stay put)" ;; esac
    [[ -t 0 ]] || die "set-credentials is interactive — run it at a terminal."

    case "$target" in
    arr)
        local user pass
        explain "Rotate the arr login" \
"One login for Sonarr/Radarr/Lidarr/Prowlarr/Bazarr — and cleanuparr's
account password follows it. Cleanuparr's USERNAME cannot be changed via
its API: if you change the username here, sign-in to cleanuparr keeps the
old one."
        ask SC_U "Username" "$(env_get ARR_USER admin)"; user="$REPLY_VAL"
        ask_secret "New password" "$(head -c12 /dev/urandom | base64 | tr -d '=+/')"; pass="$REPLY_VAL"
        sc_rotate_arr "$user" "$pass"
        ;;
    qbit)
        local user pass
        explain "Rotate the qBittorrent login" \
"Changes the WebUI login and updates everything that stores it: each
arr's download-client entry and cleanuparr's connection."
        ask SC_QU "Username" "$(env_get QBITTORRENT_USER admin)"; user="$REPLY_VAL"
        ask_secret "New password" "$(head -c12 /dev/urandom | base64 | tr -d '=+/')"; pass="$REPLY_VAL"
        sc_rotate_qbit "$user" "$pass"
        ;;
    pihole)
        local pass
        ask_secret "New Pi-hole password" "$(head -c12 /dev/urandom | base64 | tr -d '=+/')"; pass="$REPLY_VAL"
        sc_rotate_pihole "$pass"
        ;;
    traefik)
        local pass
        ask_secret "New dashboard password" "$(head -c12 /dev/urandom | base64 | tr -d '=+/')"; pass="$REPLY_VAL"
        sc_rotate_traefik "$pass"
        ;;
    jellyfin)
        local npass
        explain "Rotate the Jellyfin admin password" \
"Seerr federates to Jellyfin (nothing to change there) and Wizarr connects
by API key (unchanged). Only this password and .env move."
        ask_secret "New password" "$(head -c12 /dev/urandom | base64 | tr -d '=+/')"; npass="$REPLY_VAL"
        sc_rotate_jellyfin "$npass"
        ;;
    all)
        local pass
        explain "One password across the stack" \
"Sets a single password on the arr login (6 apps + cleanuparr follows),
qBittorrent (and everything storing its login), the Jellyfin admin,
Pi-hole, and the Traefik dashboard.
Usernames stay as they are. Deliberate trade-off: one reused password
means one leak opens everything — use a strong, stack-unique one.
NOT covered: Wizarr's admin account is its own — rotate it in Wizarr's
UI (Settings -> Account) yourself."
        ask_secret "New stack password" "$(head -c12 /dev/urandom | base64 | tr -d '=+/')"; pass="$REPLY_VAL"
        sc_rotate_arr "$(env_get ARR_USER admin)" "$pass"
        sc_rotate_qbit "$(env_get QBITTORRENT_USER admin)" "$pass"
        sc_rotate_jellyfin "$pass"
        sc_rotate_pihole "$pass"
        sc_rotate_traefik "$pass"
        warn "Wizarr's admin password is NOT rotated by this — change it in Wizarr's UI."
        ok "one password now covers arr + qbit + jellyfin + pihole + traefik — view: ./mediastack.sh credentials"
        ;;
    esac
}

sc_rotate_arr() { # USER PASS — every arr-family app + cleanuparr follows
        local user="$1" pass="$2" olduser oldpass s
        olduser=$(env_get ARR_USER); oldpass=$(env_get ARR_PASSWORD)
        env_set ARR_USER "$user"; env_set ARR_PASSWORD "$pass"
        for s in $(arr_instances) prowlarr; do
            svc_enabled "$s" || continue
            arr_forms_login "$s" force
        done
        if svc_enabled cleanuparr && [[ "$(c_state "$(svc_cname cleanuparr)")" == running ]]; then
            local lout ltok
            lout=$(cup_api POST /auth/login "" "$(jq -cn --arg u "$olduser" --arg p "$oldpass" '{username:$u,password:$p}')" || true)
            ltok=$(jq -r '.tokens.accessToken // empty' <<<"$lout" 2>/dev/null)
            if [[ -n "$ltok" ]]; then
                cup_api PUT /account/password "Authorization: Bearer $ltok" \
                    "$(jq -cn --arg c "$oldpass" --arg n "$pass" '{currentPassword:$c,newPassword:$n}')" >/dev/null \
                    && ok "cleanuparr account password rotated in step" \
                    || warn "cleanuparr refused the password change [HTTP $(cup_code)] — change it in its UI (login: '$olduser' + the OLD password)"
            else
                warn "could not sign in to cleanuparr with the previous login — rotate its password in its UI"
            fi
            [[ "$user" != "$olduser" ]] && warn "cleanuparr's username stays '$olduser' (no API to change it)"
        fi
        ok "arr login rotated — view: ./mediastack.sh credentials"
}

sc_rotate_qbit() { # USER PASS — qbit + every place that stores its login
        local user="$1" pass="$2" s
        qb_login "$(env_get QBITTORRENT_USER)" "$(env_get QBITTORRENT_PASSWORD)" \
            || die "cannot sign in to qBittorrent with the stored credentials — fix that first (wire qbit)"
        qb_api /app/setPreferences "json=$(jq -cn --arg u "$user" --arg p "$pass" '{web_ui_username:$u,web_ui_password:$p}')" >/dev/null || true  # re-login below is the verdict
        sleep 2
        qb_login "$user" "$pass" || die "qBittorrent did not accept the new credentials — inspect: logs qbittorrent"
        env_set QBITTORRENT_USER "$user"; env_set QBITTORRENT_PASSWORD "$pass"
        ok "qBittorrent login rotated and verified"
        local key url cur id ent
        for s in $(arr_instances); do
            svc_enabled "$s" || continue
            key=$(arr_key "$s"); url=$(arr_url "$s")
            cur=$(api GET "$url/api/$(arr_apiver "$s")/downloadclient" "$key" || true)
            id=$(jq -r '.[] | select(.implementation=="QBittorrent") | .id' <<<"$cur" 2>/dev/null | head -1)
            [[ -n "$id" ]] || { info "$s: no qBittorrent download client entry — skipped"; continue; }
            ent=$(jq -c --argjson i "$id" --arg u "$user" --arg p "$pass" '
                .[] | select(.id==$i)
                | .fields = [ .fields[]
                    | if .name=="username" then .value=$u
                      elif .name=="password" then .value=$p
                      else . end ]' <<<"$cur")
            api PUT "$url/api/$(arr_apiver "$s")/downloadclient/$id" "$key" "$ent" >/dev/null \
                && ok "$s: download-client entry updated" \
                || wfail "$s: could not update its download-client entry — fix in its UI (Settings -> Download Clients)"
        done
        if svc_enabled cleanuparr && [[ -n "$(env_get CLEANUPARR_API_KEY)" ]]; then
            local KH dcs dcid dcent
            KH="X-Api-Key: $(env_get CLEANUPARR_API_KEY)"
            dcs=$(cup_api GET /configuration/download_client "$KH" || true)
            dcid=$(jq -r '.clients[]? | select(.name=="qbittorrent") | .id' <<<"$dcs" 2>/dev/null | head -1)
            if [[ -n "$dcid" ]]; then
                dcent=$(jq -c --arg i "$dcid" --arg u "$user" --arg p "$pass" \
                        '.clients[] | select(.id==$i) | .username=$u | .password=$p' <<<"$dcs")
                cup_api PUT "/configuration/download_client/$dcid" "$KH" "$dcent" >/dev/null \
                    && ok "cleanuparr connection updated" \
                    || wfail "cleanuparr connection not updated [HTTP $(cup_code)] — fix in its UI"
            fi
        fi
}

sc_rotate_pihole() { # PASS — env-driven; recreate applies it
        local pass="$1"
        svc_enabled pihole || { info "pihole not enabled — skipped"; return 0; }
        env_set PIHOLE_PASSWORD "$pass"
        DC up -d pihole >/dev/null 2>&1 \
            && ok "Pi-hole password rotated (container recreated)" \
            || wfail "Pi-hole recreate failed — apply with: ./mediastack.sh up"
}

sc_rotate_traefik() { # PASS — regenerated into the watched dynamic config
        local pass="$1"
        svc_enabled traefik || { info "traefik not enabled — skipped"; return 0; }
        [[ -n "$(env_get TRAEFIK_DASH_USER)" ]] || { info "traefik dashboard never configured — skipped (run traefik-setup first)"; return 0; }
        env_set TRAEFIK_DASH_PASSWORD "$pass"
        traefik_gen \
            && ok "Traefik dashboard password rotated (config regenerated; traefik watches it live)" \
            || wfail "traefik config regeneration failed — inspect: ./mediastack.sh traefik-setup"
}

sc_rotate_jellyfin() { # PASS — the Jellyfin admin (Seerr/Wizarr unaffected)
        local npass="$1" juser jpass auth tok
        juser=$(env_get JELLYFIN_ADMIN_USER); jpass=$(env_get JELLYFIN_ADMIN_PASSWORD)
        [[ -n "$juser" && -n "$jpass" ]] || die "no Jellyfin admin stored — run 'wire jellyfin' first"
        auth=$(jf_api POST /Users/AuthenticateByName "" "$(jq -cn --arg u "$juser" --arg p "$jpass" '{Username:$u,Pw:$p}')") \
            || die "Jellyfin rejected the stored admin login [HTTP $(jf_code)] — is .env stale?"
        tok=$(jq -r '.AccessToken // empty' <<<"$auth")
        jf_api POST /Users/Password "$tok" "$(jq -cn --arg c "$jpass" --arg n "$npass" '{CurrentPw:$c,NewPw:$n}')" >/dev/null \
            || die "Jellyfin refused the password change [HTTP $(jf_code)]"
        jf_api POST /Users/AuthenticateByName "" "$(jq -cn --arg u "$juser" --arg p "$npass" '{Username:$u,Pw:$p}')" >/dev/null \
            || die "verification sign-in with the NEW password failed — check Jellyfin's users in its dashboard"
        env_set JELLYFIN_ADMIN_PASSWORD "$npass"
        ok "Jellyfin admin password rotated and verified"
}

cmd_invite() { # mint a wizarr invitation and print the ready-to-share URL
    load_env; render
    local expires="" host domain base key
    while [[ $# -gt 0 ]]; do case "$1" in
        --expires) case "${2:-}" in 1|7|30) expires="$2"; shift 2 ;;
                   *) die "usage: invite [--expires 1|7|30]   (no flag = never expires)" ;; esac ;;
        *) die "usage: invite [--expires 1|7|30]   (no flag = never expires)" ;;
    esac; done
    svc_enabled wizarr || die "wizarr is not enabled. Enable it first: ./mediastack.sh enable wizarr"
    [[ "$(c_state "$(svc_cname wizarr)")" == running ]] || die "wizarr is not running: ./mediastack.sh up"
    key=$(env_get WIZARR_API_KEY)
    [[ -n "$key" ]] || die "No wizarr API key stored yet — run: ./mediastack.sh wire wizarr"
    # server discovery: a create without server_ids deliberately answers 400
    # WITH the available_servers list (upstream-documented behaviour)
    local disc dcode ids out code url exp_line
    disc=$(curl -sS -m 15 -X POST -H "X-API-Key: $key" -H "Content-Type: application/json" \
           -d '{}' -w $'\n%{http_code}' "$(wizarr_url)/api/invitations" 2>&1) \
        || die "wizarr unreachable: $(head -c200 <<<"$disc")"
    dcode=${disc##*$'\n'}; disc=${disc%$'\n'*}
    [[ "$dcode" == 400 || "$dcode" =~ ^2 ]] || die "wizarr refused the request [HTTP $dcode]: $(head -c200 <<<"$disc")
  (401 = stale API key: re-run 'wire wizarr')"
    ids=$(jq -c '[.available_servers[]?.id]' <<<"$disc" 2>/dev/null)
    [[ "$ids" != "[]" && -n "$ids" ]] || die "wizarr has no verified media server yet — finish its one-time
  first-run in the UI (see: wire wizarr), then retry."
    out=$(curl -sS -m 15 -X POST -H "X-API-Key: $key" -H "Content-Type: application/json" \
          -d "$(jq -cn --argjson ids "$ids" --argjson e "${expires:-null}" \
               '{server_ids:$ids} + (if $e then {expires_in_days:$e} else {} end)')" \
          -w $'\n%{http_code}' "$(wizarr_url)/api/invitations" 2>&1) \
        || die "wizarr unreachable during creation: $(head -c200 <<<"$out")"
    code=${out##*$'\n'}; out=${out%$'\n'*}
    [[ "$code" =~ ^2 ]] || die "invitation rejected [HTTP $code]: $(head -c200 <<<"$out")"
    url=$(jq -r '.invitation.url // empty' <<<"$out")
    [[ -n "$url" ]] || die "invitation created but no URL in the reply: $(head -c300 <<<"$out")"
    host=$(env_get WIZARR_HOST invites); domain=$(env_get TRAEFIK_DOMAIN)
    if [[ -n "$domain" ]]; then base="https://$host.$domain"
    else base="http://$(hostname -I 2>/dev/null | awk '{print $1}'):$(svc_hostport wizarr)"; fi
    exp_line="never expires"
    [[ -n "$expires" ]] && exp_line="expires in $expires day(s)"
    hr "Invitation ready"
    echo "  ${base}${url}"
    echo "  ($exp_line — manage or revoke in wizarr's UI)"
}

cmd_new_service() {
    # User services live in docker-compose.override.yml: compose merges it
    # automatically, it is untracked, and upgrades never conflict with it.
    # compose.d/ and docker-compose.yml are the repo's territory — a scaffold
    # there would trip the clean-tree gate on the next upgrade.
    #
    # The scaffold is emitted on the TOGGLE MODEL: the fragment carries only
    # metadata (mediastack.* labels); vpn_gen generates its network, host
    # port and Traefik route, so `vpn <name> on|off` works from day one and no
    # routing YAML is ever hand-written.
    local name="${1:?usage: new-service <n>}"
    [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "Service names: lowercase letters, digits, dashes."
    [[ -t 0 ]] || die "new-service is interactive — run it at a terminal."
    load_env; need_cmd jq; need_cmd docker
    svc_exists "$name" && die "A service '$name' already exists in the rendered stack."
    local stem; stem=$(uvar "$name")

    # ---- questions (configure-style: explain, then ask; Enter = default) ----
    _ns_ask() { local hint=""; [[ -n "$2" ]] && hint=" [$2]"; read -r -p "$1$hint: " REPLY_VAL; REPLY_VAL="${REPLY_VAL:-$2}"; }
    local image cport host desc vpn cfg data puid
    explain "New service: $name" \
"A few questions produce a complete, working service definition in
docker-compose.override.yml — image, port, HTTPS hostname, VPN membership,
folders and permissions — then it is enabled and started. Nothing to edit."
    while true; do
        _ns_ask "Docker image (repository:tag)" ""; image="$REPLY_VAL"
        [[ -n "$image" ]] || { warn "an image is required"; continue; }
        [[ "$image" == *CHANGEME* ]] && { warn "that is a placeholder, not an image"; continue; }
        if sudo docker manifest inspect "$image" >/dev/null 2>&1; then
            ok "image found in its registry"; break
        fi
        warn "could not verify '$image' in its registry (typo? private image? offline?)"
        _ns_ask "Use it anyway? [y/N]" ""
        [[ "${REPLY_VAL,,}" == y* ]] && break
    done
    while true; do
        _ns_ask "Port the app listens on INSIDE the container (see its docs)" ""; cport="$REPLY_VAL"
        [[ "$cport" =~ ^[0-9]+$ ]] && (( cport > 0 && cport < 65536 )) && break
        warn "a port is a number 1-65535"
    done
    _ns_ask "HTTPS hostname (<name>.$(env_get TRAEFIK_DOMAIN '<your domain>'))" "$name"; host="$REPLY_VAL"
    [[ "$host" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "Hostnames: lowercase letters, digits, dashes."
    _ns_ask "One-line description (shown in configure and status)" "$name"; desc="$REPLY_VAL"
    explain "VPN" \
"Rule of thumb: apps that ACQUIRE content (torrent clients, indexers) run
inside the VPN; apps that SERVE your own media to you run outside it (the
tunnel adds latency and gains them nothing). Flip it any time:
./mediastack.sh vpn $name on|off"
    _ns_ask "Route $name through the VPN? [y/N]" ""
    [[ "${REPLY_VAL,,}" == y* ]] && vpn=true || vpn=false
    _ns_ask "Does it keep settings/state in a config folder? [Y/n]" ""
    [[ "${REPLY_VAL,,}" == n* ]] && cfg=false || cfg=true
    explain "Data access" \
"  1) none         it needs no media at all
  2) serving      read-only view of the media library (players, readers)
  3) acquisition  read-write torrent + media trees as ONE mount, so imports
                  hardlink instead of copy (downloaders, *arr-style importers)"
    _ns_ask "Choice" "1"; data="$REPLY_VAL"
    [[ "$data" =~ ^[123]$ ]] || die "Choice must be 1, 2 or 3."
    explain "Permissions" \
"Every mediastack service runs as its own system user (a PUID such as
13029) in the shared 'mediacenter' group (PGID), so each app can only
write its own config folder plus the media it is allowed to touch, and
files it creates stay readable by the other apps. An image that honours
PUID/PGID (linuxserver.io, hotio and most *arr images) switches to that
user at start-up when the two variables are set.

Some images ignore them and run as root, or as a fixed user of their own
(nginx, many official Docker Hub images, Jellyfin's official image). Check
the image's docs for 'PUID' or 'user:'. For those answer no: the variables
are omitted, the config folder is created without a private owner, and
doctor will not warn that no process runs as the expected UID. Nothing
else changes — it is still backed up, updated and audited like the rest."
    _ns_ask "Does the image honour PUID/PGID? [Y/n]" ""
    [[ "${REPLY_VAL,,}" == n* ]] && puid=false || puid=true

    # ---- scaffold ----
    local f="docker-compose.override.yml" had_file=0 snap=""
    if [[ -e "$f" ]]; then
        had_file=1; snap=$(cat "$f")
        grep -qE "^  ${name}:" "$f" && die "$f already defines '$name'."
        grep -qE '^services:' "$f" || die "$f exists but has no 'services:' key — add the service there yourself."
    else
        printf '# Your services live here — untracked, merged automatically, upgrade-safe.\nservices:\n' > "$f"
    fi
    _new_service_fragment "$name" "$stem" "$image" "$cport" "$host" "$desc" "$vpn" "$cfg" "$data" "$puid" >> "$f"
    # anything failing from here until the stack is touched reverts the file
    # AND the overlay: a stanza for a service that no longer exists would make
    # every later render fail ("neither an image nor a build context")
    _new_service_rollback() {
        if (( had_file )); then printf '%s' "$snap" > "$f"; else rm -f "$f"; fi
        (( overlay_made )) && vpn_gen
        return 0
    }
    local overlay_made=0
    if ! compose_renders; then
        _new_service_rollback
        die "The scaffold broke compose rendering — reverted. See compose's message above."
    fi
    RENDERED_JSON=""
    vpn_gen; overlay_made=1   # its network/port/route now exist in the overlay
    ok "scaffolded '$name' in $f"

    # host port: the container port by default (${stem}_PORT overrides). A
    # collision with something already published is refused here, not by
    # docker halfway through `up`.
    local prof found; prof="$(env_get COMPOSE_PROFILES),$name"
    found=$(port_collisions "$prof") || { _new_service_rollback; die "port audit could not evaluate the rendered config — reverted"; }
    if [[ -n "$found" ]]; then
        warn "host port $cport is already published: $found"
        _ns_ask "Host port to publish $name on instead" ""
        [[ "$REPLY_VAL" =~ ^[0-9]+$ ]] || { _new_service_rollback; die "not a port — reverted"; }
        env_set "${stem}_PORT" "$REPLY_VAL"
        RENDERED_JSON=""; vpn_gen
        found=$(port_collisions "$prof") || { env_del "${stem}_PORT"; _new_service_rollback; die "port audit could not evaluate the rendered config — reverted"; }
        [[ -z "$found" ]] || { env_del "${stem}_PORT"; _new_service_rollback; die "still colliding: $found — reverted"; }
        ok "host port ${REPLY_VAL} (${stem}_PORT in .env)"
    fi
    _configure_selfheal   # allocate ${stem}_UID / _UPDATE like any new fragment

    # ---- enable + start ----
    _ns_ask "Start it now? [Y/n]" ""
    if [[ "${REPLY_VAL,,}" == n* ]]; then
        hr "Next steps"
        echo "  ./mediastack.sh enable $name      create its user/folders and start it"
        echo "  ./mediastack.sh vpn $name on|off  change VPN membership (now: $(vpn_onoff "$vpn"))"
        echo "  ./mediastack.sh status            its URL and health"
        _new_service_footer "$name"
        return
    fi
    cmd_enable "$name"
    local cn t=0; cn=$(svc_cname "$name")
    info "Waiting for $name to report healthy (up to 120s; images without a healthcheck report '-')..."
    while [[ "$(c_health "$cn")" == starting && $t -lt 120 ]]; do sleep 5; t=$((t+5)); done
    case "$(c_health "$cn")" in
        healthy) ok "$name is healthy" ;;
        -)       [[ "$(c_state "$cn")" == running ]] && ok "$name is running (no healthcheck in the image)" \
                     || die "$name is not running — inspect: ./mediastack.sh logs $name" ;;
        *)       die "$name is $(c_health "$cn") after ${t}s — inspect: ./mediastack.sh logs $name" ;;
    esac
    hr "$name"
    echo "  URL: $(svc_url "$name")"
    [[ -n "$(env_get TRAEFIK_DOMAIN)" ]] || echo "  (an HTTPS hostname appears once Traefik is set up: ./mediastack.sh traefik-setup)"
    echo "  VPN: $(vpn_onoff "$vpn")   change: ./mediastack.sh vpn $name on|off"
    echo "  Row: ./mediastack.sh status"
    _new_service_footer "$name"
}

_new_service_footer() { # where to go for anything the questions did not cover
    cat <<EOT

Its definition is the '$1:' block in docker-compose.override.yml — plain
compose YAML, yours to edit: extra environment variables (API keys, a base
URL), devices (/dev/dri for hardware transcoding), more volumes, a
healthcheck. Edit, then: ./mediastack.sh up
Host port:  $(uvar "$1")_PORT=<port> in .env   HTTPS name: $(uvar "$1")_HOST=<sub> in .env
Removing it later: docs/adding-a-service.md, "Removing your service".
EOT
}

_new_service_fragment() { # <name> <stem> <image> <cport> <host> <desc> <vpn> <cfg> <data> <puid> -> YAML on stdout
    local name="$1" stem="$2" image="$3" cport="$4" host="$5" desc="$6" vpn="$7" cfg="$8" data="$9" puid="${10}"
    # values land inside double-quoted YAML scalars: escape what would break out
    desc=${desc//\\/\\\\}; desc=${desc//\"/\\\"}
    cat <<EOF

  # $name — scaffolded by: ./mediastack.sh new-service $name
  # Network, host port and HTTPS route are generated from the labels below
  # (local/vpn-overlay.yml). VPN membership: ./mediastack.sh vpn $name on|off
  $name:
    image: $image
    container_name: \${${stem}_NAME:-mediastack-$name}
    profiles: ["$name"]
    environment:
      - TZ=\${TZ}
EOF
    if [[ "$puid" == true ]]; then cat <<EOF
      - PUID=\${${stem}_UID}
      - PGID=\${MEDIA_GROUP_GID}
      - UMASK=002
EOF
    fi
    if [[ "$cfg" == true || "$data" != 1 ]]; then echo "    volumes:"; fi
    [[ "$cfg" == true ]] && echo "      - \${CONFIG_ROOT}/$name:/config"
    case "$data" in
        2) echo "      - \${DATA_ROOT}/media:/data/media:ro" ;;
        3) echo "      - \${DATA_ROOT}:/data" ;;
    esac
    cat <<EOF
    labels:
      com.centurylinklabs.watchtower.enable: "false"
      mediastack.managed: "true"
      mediastack.desc: "$desc"
      mediastack.vpn: "$vpn"
      mediastack.vpntoggle: "true"
      mediastack.config: "$cfg"
      mediastack.subdomain: "$host"
      mediastack.port: "$cport"
    logging:
      driver: json-file
      options:
        max-size: \${LOG_MAX_SIZE:-10m}
        max-file: \${LOG_MAX_FILE:-3}
    restart: unless-stopped
EOF
}

# -------------------------------------------------------------- dispatcher --

# ---- verb registry ----
# ONE line per verb: verb~usage~args~group~description (~ separates fields; main() dispatches
# usage text may contain |). main() dispatches from it (cmd_<verb>, dashes as
# underscores), the args column is the
# verb's argument contract, and help renders the table — so a verb cannot
# exist without a contract or a help line, and CI checks every verb is
# documented in README (depth lives there; help is one line each).
#   args:  none            no arguments
#          max=N           up to N positional arguments
#          allow=A,B       only these arguments, any order
#          allow=A max=N   both
#          free            the verb parses its own (its `*)` arm dies on unknown input)
#   group: Setup Run Maintain Connect Check Other Internal — Internal verbs
#          exist for the panel, timers and units and are listed last.
VERBS=(
    "help~help~~Other~This list."
    "install~install~none~Setup~Install host dependencies (docker, jq, ...). Run once."
    "configure~configure~none~Setup~Interactive setup wizard: .env, users, folders. Safe to re-run."
    "add-mount~add-mount~none~Setup~Guided NFS/SMB mount on this host (fstab automount + poison layer)."
    "up~up~none~Run~Start the stack (everything enabled in COMPOSE_PROFILES)."
    "down~down~none~Run~Stop the stack. Configs and data are untouched."
    "enable~enable <svc>~max=1~Run~Turn one service on (dependencies come along) and start it."
    "disable~disable <svc>~max=1~Run~Turn one service off (refused while others depend on it)."
    "status~status [svc]~max=1~Run~Overview table of every service, or a deep view of one."
    "logs~logs <svc> [--no-follow]~free~Run~Follow one service's logs (--no-follow: bounded snapshot)."
    "update~update [svc] [--to TAG] [--dry-run|--now]~free~Maintain~Container images: backup, pull, apply (toggles + pins respected)."
    "apply-timer~apply-timer~none~Maintain~Install/refresh the systemd timer from UPDATE_SCHEDULE."
    "backup~backup [verify [TS]]~free~Maintain~Take a restore point now (cold); 'verify' checks checksums and archives."
    "restore~restore --service <svc>|--all [--from TS]~free~Maintain~Restore configs + image from a restore point."
    "rollback~rollback <svc>~max=1~Maintain~Restore one service from the newest restore point and pin it there."
    "unpin~unpin <svc>~max=1~Maintain~Release a pinned service back to normal updates."
    "upgrade~upgrade~none~Maintain~Mediastack itself: git pull + .env migration (images stay put: update)."
    "wire~wire [app] [--dry-run|--verify]~free~Connect~Connect the apps to each other; idempotent, GUI changes never overwritten."
    "invite~invite [--expires 1|7|30]~free~Connect~Mint a Wizarr invitation and print the ready-to-share URL."
    "credentials~credentials~none~Connect~Show the app logins wire created/stored."
    "set-credentials~set-credentials <target|all>~max=1~Connect~Rotate a stored login everywhere it lives, atomically."
    "traefik-setup~traefik-setup [--hosts|--certs]~allow=--hosts,--certs max=1~Connect~Configure the HTTPS edge (domain, token, staging/production, dashboard login)."
    "trash-sync~trash-sync [--dry-run]~allow=--dry-run~Connect~Sync TRaSH Guides quality profiles to the arrs (--dry-run previews drift)."
    "doctor~doctor~none~Check~Full health/permission/port/backup audit; every failure states its fix."
    "leak-test~leak-test [--killswitch]~allow=--killswitch~Check~Prove no VPN'd service can leak (--killswitch: disruptive tunnel-drop proof)."
    "vpn~vpn [svc on|off] [--i-know]~max=3~Check~Show or change which services run behind the VPN; apply with: up."
    "fix-perms~fix-perms [svc]~max=1~Check~Repair config-dir ownership from the UID map."
    "new-service~new-service <name>~max=1~Other~Add your own service: asks image/port/VPN/folders, then enables and starts it."
    "frontdoor-install~frontdoor-install [--set-password]~allow=--set-password~Other~Install the OliveTin web panel over the safe verbs."
    "uninstall~uninstall [--nuke]~allow=--nuke~Other~Remove the stack (tiered; --nuke: one confirmed shot). Media and backups are never touched."
    "menu~menu~none~Other~Interactive menu wrapping the common verbs."
    "list~list [--json]~free~Internal~Enabled services, one per line (--json: panel entity records)."
    "vpn-apply~vpn-apply <svc> on|off~max=2~Internal~Set a service's VPN membership AND apply it (panel button)."
    "vpn-guard~vpn-guard [--boot]~allow=--boot~Internal~Re-pin VPN dependents onto the live gluetun (boot/daemon unit)."
    "frontdoor-refresh~frontdoor-refresh~none~Internal~Regenerate the panel's config and entity files."
)

verb_entry() { # verb_entry <verb> -> its registry line, rc 1 if unknown
    local e; for e in "${VERBS[@]}"; do [[ "${e%%~*}" == "$1" ]] && { echo "$e"; return 0; }; done; return 1
}

# ---- argument discipline ----
# Every verb declares what it accepts; anything else is rejected before it
# runs, so a typo or an unsupported flag never silently falls through to the
# default behaviour (e.g. 'trash-sync --dry-run' once ran a real sync).
CMD=""
args_none()  { (( $# == 0 )) || die "'$CMD' takes no arguments (got: $*)"; }
args_max()   { local n="$1"; shift; (( $# <= n )) || die "'$CMD' takes at most $n argument(s) (got: $*)"; }
args_allow() { # args_allow "<space-separated allowed args>" "$@" — anything else is rejected
    local allowed="$1" a; shift
    for a in "$@"; do [[ " $allowed " == *" $a "* ]] || die "unknown argument '$a' for '$CMD' (accepts: ${allowed:-nothing})"; done
    return 0
}
args_check() { # args_check "<args column>" "$@" — apply a registry contract
    local spec="$1" tok; shift
    for tok in $spec; do
        case "$tok" in
            none)    args_none "$@" ;;
            free)    ;;
            max=*)   args_max "${tok#max=}" "$@" ;;
            allow=*) tok=${tok#allow=}; args_allow "${tok//,/ }" "$@" ;;
            *)       die "registry: unknown args token '$tok' for '$CMD'" ;;
        esac
    done
}

main() {
    local cmd="${1:-help}"; shift || true
    case "$cmd" in -h|--help) cmd=help ;; esac
    CMD="$cmd"
    local entry
    entry=$(verb_entry "$cmd") || { fail "Unknown command '$cmd'"; echo; cmd_help; exit 1; }
    local spec; spec=$(cut -d'~' -f3 <<<"$entry")
    args_check "$spec" "$@"
    "cmd_${cmd//-/_}" "$@"
}
# =================================================================== trash --
# Wave 2: TRaSH Guides sync via Recyclarr (guide-backed profiles, v8 schema).
# Managed instances: sonarr, sonarr-anime, radarr, radarr-4k. Lidarr is out
# of scope (recyclarr supports sonarr/radarr only).

trash_instances() {
    local s; for s in sonarr sonarr-anime radarr radarr-4k; do
        svc_enabled "$s" || continue
        echo "$s"
    done
}

trash_envkey() { echo "TRASH_PROFILE_$(tr 'a-z-' 'A-Z_' <<<"$1")"; }

# profile menu: stored once in .env; radarr-4k and sonarr-anime pre-answered
trash_menu() {
    local s key cur
    for s in $(trash_instances); do
        key=$(trash_envkey "$s"); cur=$(env_get "$key")
        [[ -n "$cur" ]] && continue
        case "$s" in
            radarr-4k)    env_set "$key" uhd;   info "radarr-4k: pre-answered 'uhd' (that is its whole job)"; continue ;;
            sonarr-anime) env_set "$key" anime; info "sonarr-anime: pre-answered 'anime'"; continue ;;
        esac
        if [[ ! -t 0 ]]; then
            env_set "$key" skip
            warn "$s: no TRaSH profile chosen and no terminal to ask — set to 'skip'; run './mediastack.sh trash-sync' interactively to choose"
            continue
        fi
        explain "TRaSH profile: $s" \
"Pick the quality profile recyclarr will manage on this instance.
  1) 1080p   TRaSH guide default (recommended)
  2) 720p    space saver (ours: smaller grabs, WEB-preferred)
  3) 4k      TRaSH UHD guide profile
  4) skip    leave this instance unmanaged"
        ask TP "Choice for $s [1080p/720p/4k/skip]" "1080p"
        case "$REPLY_VAL" in
            1080p|720p|4k|skip) env_set "$key" "$REPLY_VAL" ;;
            *) die "Unknown choice '$REPLY_VAL' — expected 1080p, 720p, 4k or skip." ;;
        esac
    done
}

# our 720p space-saver profile (full custom profile; recyclarr replaces
# qualities wholesale, so the list must be complete)
trash_720p_profile() { # $1 = sonarr|radarr
    cat <<'Y720'
      - name: "[synced] 720p Space Saver"
        reset_unmatched_scores:
          enabled: true
        upgrade:
          allowed: true
          until_quality: WEB 720p
          until_score: 10000
        min_format_score: 0
        quality_sort: top
        qualities:
          - name: WEB 720p
            qualities: [WEBDL-720p, WEBRip-720p]
          - name: Bluray-720p
          - name: HDTV-720p
Y720
}

# verbatim splice of the user's score overrides for one instance.
# local/trash-overrides.yml sections are native recyclarr custom_formats
# lists under a top-level "<service>:" key — see docs/trash-sync.md.
trash_overrides_for() { # $1 = svc; emits indented custom_formats block
    local f=local/trash-overrides.yml
    [[ -s "$f" ]] || return 0
    awk -v svc="$1" '
        /^[a-z0-9-]+:[[:space:]]*$/ { insec = ($0 == svc":") ; next }
        insec && /^[[:space:]]/ { print }
        insec && /^[^[:space:]#]/ { insec = 0 }
    ' "$f"
}

# dedicated system user for the recyclarr container: same pattern as every
# service (uid from .env, primary group mediacenter — which is also how nuke
# finds and removes it). trash-sync self-provisions so configure isn't needed.
trash_provision() {
    local uid gid
    uid=$(env_get RECYCLARR_UID 13020); gid=$(env_get MEDIA_GROUP_GID 13000)
    env_set RECYCLARR_UID "$uid"
    if ! getent group mediacenter >/dev/null; then
        sudo groupadd -g "$gid" mediacenter && ok "group mediacenter ($gid)" \
            || { wfail "could not create group mediacenter"; return 1; }
    fi
    if ! getent passwd recyclarr >/dev/null; then
        sudo useradd -M -s /usr/sbin/nologin -u "$uid" -g mediacenter recyclarr \
            && ok "user recyclarr ($uid)" \
            || { wfail "could not create user recyclarr (uid $uid taken?)"; return 1; }
    fi
    # one-time cleanup: an earlier fragment used an include-relative mount
    # path, which docker auto-created root-owned under compose.d/
    [[ -d compose.d/local ]] && sudo rm -rf compose.d/local
    sudo install -d -o "$uid" -g mediacenter -m 750 "$(env_get CONFIG_ROOT)/recyclarr"
    ok "recyclarr user ($uid) + config dir ready"
}

trash_gen_config() { # trash_gen_config [out-path] — default: the live recyclarr.yml
    local uid out tmp
    uid=$(env_get RECYCLARR_UID 13020)
    out="${1:-$(env_get CONFIG_ROOT)/recyclarr/recyclarr.yml}"
    tmp=$(mktemp)
    {
        echo "# GENERATED by mediastack trash-sync — DO NOT EDIT."
        echo "# Choices live in .env (TRASH_PROFILE_*); score overrides in"
        echo "# local/trash-overrides.yml. Regenerated on every trash-sync run."
        echo "# yaml-language-server: \$schema=https://schemas.recyclarr.dev/v8/config-schema.json"
    } > "$tmp"
    local s key choice app port apikey ov n
    local wrote_sonarr=0 wrote_radarr=0
    for s in $(trash_instances); do
        key=$(trash_envkey "$s"); choice=$(env_get "$key")
        [[ -z "$choice" || "$choice" == skip ]] && continue
        app=$(svc_label "$s" mediastack.arrtype)   # sonarr | radarr
        port=$(svc_label "$s" mediastack.port)
        apikey=$(arr_key "$s")
        [[ -n "$apikey" ]] || { wfail "$s: no ApiKey yet — start it, then re-run trash-sync"; continue; }
        if [[ "$app" == sonarr && $wrote_sonarr == 0 ]]; then echo "sonarr:" >> "$tmp"; wrote_sonarr=1; fi
        if [[ "$app" == radarr && $wrote_radarr == 0 ]]; then echo "radarr:" >> "$tmp"; wrote_radarr=1; fi
        {
            echo "  $s:"
            echo "    base_url: http://localhost:$port"
            echo "    api_key: $apikey"
            case "$app/$choice" in
                sonarr/anime) echo "    quality_definition: {type: anime}" ;;
                sonarr/*)     echo "    quality_definition: {type: series}" ;;
                radarr/*)     echo "    quality_definition: {type: movie}" ;;
            esac
            echo "    quality_profiles:"
            case "$app/$choice" in
                sonarr/1080p) echo '      - trash_id: 72dae194fc92bf828f32cde7744e51a1  # WEB-1080p'
                              printf '%s\n' '        name: "[synced] WEB-1080p"' '        reset_unmatched_scores:' '          enabled: true' ;;
                sonarr/4k)    echo '      - trash_id: d1498e7d189fbe6c7110ceaabb7473e6  # WEB-2160p'
                              printf '%s\n' '        name: "[synced] WEB-2160p"' '        reset_unmatched_scores:' '          enabled: true' ;;
                sonarr/anime) echo '      - trash_id: 20e0fc959f1f1704bed501f23bdae76f  # [Anime] Remux-1080p'
                              printf '%s\n' '        name: "[synced] Anime Remux-1080p"' '        reset_unmatched_scores:' '          enabled: true' ;;
                radarr/1080p) echo '      - trash_id: d1d67249d3890e49bc12e275d989a7e9  # HD Bluray + WEB'
                              printf '%s\n' '        name: "[synced] HD Bluray + WEB"' '        reset_unmatched_scores:' '          enabled: true' ;;
                radarr/uhd|radarr/4k)
                              echo '      - trash_id: 64fb5f9858489bdac2af690e27c8f42f  # UHD Bluray + WEB'
                              printf '%s\n' '        name: "[synced] UHD Bluray + WEB"' '        reset_unmatched_scores:' '          enabled: true' ;;
                */720p)       trash_720p_profile "$app" ;;
                *) die "unmapped profile choice '$choice' for $s (env $key)" ;;
            esac
        } >> "$tmp"
        ov=$(trash_overrides_for "$s")
        if [[ -n "$ov" ]]; then
            n=$(grep -c 'trash_ids:' <<<"$ov" || true)
            printf '%s\n' "$ov" >> "$tmp"
            ok "$s: profile '$choice' ($n overridden)"
        else
            ok "$s: profile '$choice'"
        fi
    done
    sudo install -o "$uid" -g mediacenter -m 600 "$tmp" "$out" && rm -f "$tmp" \
        || { rm -f "$tmp"; wfail "could not install $out"; return 1; }
}

# the ownership banner: a never-matching CF that sorts first in the GUI so
# nobody hand-tunes what nightly sync will revert. Recyclarr cannot create
# non-TRaSH CFs, so we push it ourselves (idempotent by name).
# container "running" is not API "ready" — after a cold restart the arrs
# answer errors for a few seconds. Poll each instance before touching it.
arr_api_ready() { # arr_api_ready <svc> <shared-deadline-epoch> -> 0 ready
    local s="$1" deadline="$2" key url probe
    key=$(arr_key "$s"); [[ -n "$key" ]] || return 1
    url=$(arr_url "$s")
    while :; do
        probe=$(curl -sS -m 5 -o /dev/null -w '%{http_code}' \
                -H "X-Api-Key: $key" "$url/api/$(arr_apiver "$s")/system/status" 2>&1)
        [[ "$probe" == 200 ]] && return 0
        if (( $(date +%s) >= deadline )); then
            wfail "$s: API not ready before the 90s budget ran out (last probe: $(head -c80 <<<"$probe"))"
            return 1
        fi
        sleep 3
    done
}

TRASH_SENTINEL='[!] Synced by mediastack — tune via local/trash-overrides.yml'
trash_sentinel() { # $1 = svc
    local s="$1" key url cur
    key=$(arr_key "$s") || true; [[ -n "$key" ]] || return 0
    url=$(arr_url "$s")
    cur=$(api GET "$url/api/$(arr_apiver "$s")/customformat" "$key" || true)
    if jq -e --arg n "$TRASH_SENTINEL" 'any(.[]; .name == $n)' <<<"$cur" >/dev/null 2>&1; then
        ok "$s: sentinel banner present"
    elif w_would "$s: create sentinel banner custom format"; then
        local sresp
        if sresp=$(api POST "$url/api/$(arr_apiver "$s")/customformat" "$key" "$(jq -nc --arg n "$TRASH_SENTINEL" \
            '{name:$n, includeCustomFormatWhenRenaming:false, specifications:[{name:"Never matches", implementation:"ReleaseTitleSpecification", negate:false, required:true, fields:[{name:"value", value:"\\b\\B"}]}]}')"); then
            ok "$s: sentinel banner created"
        else
            wfail "$s: sentinel creation rejected — API said: $(head -c160 <<<"$sresp")"
        fi
    fi
}

# condense recyclarr's sync log into one line for doctor + the verdict.
# recyclarr only renders its results table on a TTY; captured output is
# plain [INF] logging, so that is what we parse: "Created/Updated/Deleted
# N <thing>" lines per instance mean drift was repaired or guides moved.
# Best-effort: unrecognized output degrades to a note, never the verdict.
trash_summarize() { # $1 = captured sync log
    awk '
        /^\[INF\] [a-z0-9-]+: (Created|Updated|Deleted) [0-9]+ / {
            name=$2; sub(/:$/, "", name)
            detail=""; for (i=3; i<=NF; i++) detail = detail (detail?" ":"") $i
            sub(/:.*/, "", detail)
            per[name] = per[name] (per[name] ? ", " : "") detail
        }
        /^\[INF\] [a-z0-9-]+: Processing / { rows++ }
        END {
            if (rows == 0) { print "summary unavailable (unrecognized output)"; exit }
            out=""
            for (n in per) out = out (out ? " " : "") n "(" per[n] ")"
            if (out == "") print "all in sync, no drift"
            else           print "changes applied: " out
        }
    ' "$1"
}

trash_preview_summarize() { # $1 = captured `sync --preview` log -> "<count>|<summary>"
    # preview renders one "── <pipeline> (Preview) [<instance>] ──" block per
    # pipeline per instance, each followed by "No changes" or a change table.
    # Counts the pipelines that would change; the caller adds that to
    # WIRE_CHANGES (this runs inside $(...), so it cannot do so itself).
    # a pty emits ANSI colour and CRLF line endings: strip both before matching
    sed -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' -e 's/\r$//' "$1" | awk '
        /^── .* \(Preview\) \[[a-z0-9-]+\] ──/ { blocks++; open=1; name=$0; sub(/.*\[/, "", name); sub(/\].*/, "", name); next }
        open && /^No changes/ { open=0; next }
        open && NF { drift++; open=0; per[name]++ }
        END {
            out=""; for (i in per) out = out (out ? " " : "") i "(" per[i] ")"
            if (blocks == 0)     print "0|FAIL"   # nothing rendered: drift is UNKNOWN, not zero
            else if (drift == 0) print "0|all in sync, no drift (" blocks " pipeline blocks checked)"
            else                 print drift "|would change: " out " (pipelines per instance)"
        }'
}

# shellcheck disable=SC2120  # arguments arrive via main()'s registry dispatch
cmd_trash_sync() { # trash-sync [--dry-run]
    WIRE_FAILS=0; WIRE_CHANGES=0; WIRE_DRY=0
    [[ "${1:-}" == --dry-run ]] && WIRE_DRY=1
    local insts s rdir live preview
    if (( WIRE_DRY )); then
        hr "trash-sync --dry-run: previewing drift, touching nothing"
    else
        hr "trash-sync: TRaSH Guides via Recyclarr"
    fi
    insts=$(trash_instances)
    [[ -n "$insts" ]] || { info "no managed arr instances enabled — nothing to sync"; return 0; }
    wire_gate $insts
    rdir="$(env_get CONFIG_ROOT)/recyclarr"; live="$rdir/recyclarr.yml"; preview="$rdir/recyclarr.preview.yml"
    if (( WIRE_DRY )); then
        # a preview needs a provisioned recyclarr and answered profile choices:
        # both are decisions the real run makes, and a dry run makes none
        sudo test -d "$rdir" || die "recyclarr is not provisioned yet — run './mediastack.sh trash-sync' once, then preview"
        # recyclarr renders its preview with Spectre.Console and discards ALL of
        # that when its stdout is not a TTY (its "log mode"); the run below
        # forces a pty, which needs a terminal on our stdin to attach
        [[ -t 0 ]] || die "trash-sync --dry-run needs a terminal (recyclarr only renders a preview on a TTY)"
        for s in $insts; do
            [[ -n "$(env_get "$(trash_envkey "$s")")" ]] \
                || die "$s: no TRaSH profile chosen yet — run './mediastack.sh trash-sync' once to choose, then preview"
        done
        hr "trash-sync: generate config (preview copy)"
        # the generated config goes to a scratch file beside the live one; the
        # preview syncs from it so the diff being previewed is the real one
        trash_gen_config "$preview"
        if sudo cmp -s "$live" "$preview" 2>/dev/null; then
            ok "recyclarr.yml unchanged"
        else
            w_would "install the regenerated recyclarr.yml (differs from the live one)" || true
        fi
    else
        trash_menu
        hr "trash-sync: provision"
        trash_provision || { fail "trash-sync aborted: provisioning failed."; return 1; }
        hr "trash-sync: generate config"
        trash_gen_config
    fi
    hr "trash-sync: ownership banners"
    local deadline=$(( $(date +%s) + 90 ))
    for s in $insts; do
        [[ "$(env_get "$(trash_envkey "$s")")" == skip ]] && continue
        arr_api_ready "$s" "$deadline" || continue
        trash_sentinel "$s"
    done
    hr "trash-sync: recyclarr"
    local slog rc summary
    slog=$(mktemp)
    if (( WIRE_DRY )); then
        # -t: force a pseudo-TTY even though our stdout is a pipe — without it
        # recyclarr enters log mode and prints no preview at all
        DC run --rm -t --no-deps recyclarr sync --preview --config /config/recyclarr.preview.yml 2>&1 | tee "$slog"
        rc=${PIPESTATUS[0]}
        sudo rm -f "$preview"
        summary=$(trash_preview_summarize "$slog"); rm -f "$slog"
        WIRE_CHANGES=$((WIRE_CHANGES + ${summary%%|*})); summary=${summary#*|}
        if (( rc != 0 )); then
            wfail "recyclarr preview failed — output above is the evidence"
        elif [[ "$summary" == FAIL ]]; then
            wfail "recyclarr rendered no '(Preview)' blocks — drift UNCONFIRMED (a clean preview prints one block per pipeline per instance; check the output above and: docs/trash-sync.md)"
        else
            ok "preview complete — $summary"
        fi
        echo
        if (( WIRE_FAILS )); then fail "dry-run finished with $WIRE_FAILS failure(s)."; return 1; fi
        info "dry-run complete: $WIRE_CHANGES change(s) would be applied. Run without --dry-run to apply."
        return 0
    fi
    # keep the pinned :8 tag current (patch releases only — a major bump is
    # a schema migration and stays a deliberate, manual tag change)
    DC pull -q recyclarr 2>/dev/null \
        && info "recyclarr image: pinned tag up to date" \
        || warn "recyclarr image pull failed (registry unreachable?) — syncing with the local image"
    DC run --rm --no-deps recyclarr sync 2>&1 | tee "$slog"
    rc=${PIPESTATUS[0]}
    summary=$(trash_summarize "$slog")
    sudo install -m 644 "$slog" cache/trash-sync.log; rm -f "$slog"
    if (( rc == 0 )); then
        date +%s | sudo tee cache/trash-last-sync >/dev/null
        printf '%s' "$summary" | sudo tee cache/trash-last-summary >/dev/null
        ok "sync complete — $summary (full log: cache/trash-sync.log)"
    else
        wfail "recyclarr sync failed — output above is the evidence (also: cache/trash-sync.log)"
    fi
    if (( WIRE_FAILS )); then
        fail "trash-sync finished with $WIRE_FAILS failure(s)."; return 1
    fi
    ok "trash-sync complete."
}

main "$@"
