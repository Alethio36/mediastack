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
SCRIPT_SCHEMA=2

# ------------------------------------------------------------------ output --
if [[ -t 1 ]]; then
    C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YLW=$'\e[33m'; C_BLU=$'\e[34m'
    C_BLD=$'\e[1m'; C_RST=$'\e[0m'
else
    C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_BLD=""; C_RST=""
fi
info()  { echo "${C_BLU}::${C_RST} $*"; }
ok()    { echo "${C_GRN}OK${C_RST} $*"; }
warn()  { echo "${C_YLW}WARN${C_RST} $*"; }
fail()  { echo "${C_RED}FAIL${C_RST} $*"; }
die()   { echo "${C_RED}ERROR${C_RST} $*" >&2; exit 1; }
hr()    { echo "── $* ────────────────────────────────────────────"; }

confirm() { # confirm "question" -> 0 yes / 1 no
    local ans
    read -r -p "$1 [y/N]: " ans
    [[ "${ans,,}" == y || "${ans,,}" == yes ]]
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed. Run: ./mediastack.sh install"; }

# --------------------------------------------------------------- env layer --
env_get() { # env_get VAR [default]
    local line
    line=$(grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -n1 || true)
    if [[ -n "$line" ]]; then echo "${line#*=}"; else echo "${2-}"; fi
}

env_set() { # env_set VAR value  (idempotent upsert, preserves file order)
    local var="$1" val="$2"
    touch "$ENV_FILE"
    if grep -qE "^${var}=" "$ENV_FILE"; then
        # sed with | delimiter; escape | and & in value
        local esc=${val//\\/\\\\}; esc=${esc//|/\\|}; esc=${esc//&/\\&}
        sed -i "s|^${var}=.*|${var}=${esc}|" "$ENV_FILE"
    else
        echo "${var}=${val}" >> "$ENV_FILE"
    fi
}

load_env() {
    # NOTE: .env is deliberately NOT sourced — compose reads it natively, and
    # bash `source` would execute space-containing values ("Tue 04:00") as
    # commands. All script reads go through env_get.
    [[ -f "$ENV_FILE" ]] || die ".env not found. Run: ./mediastack.sh configure"
    migrate_env
}

migrate_env() {
    local have; have=$(env_get ENV_SCHEMA 0)
    if (( have > SCRIPT_SCHEMA )); then
        die ".env schema ($have) is NEWER than this script ($SCRIPT_SCHEMA).
  You likely downgraded the repo. Run 'git pull' to return to the newer
  version, or restore .env from a backup matching this script."
    fi
    while (( have < SCRIPT_SCHEMA )); do
        cp "$ENV_FILE" "$ENV_FILE.bak.$(date +%Y%m%d%H%M%S)"
        local next=$((have + 1))
        info "Migrating .env schema $have -> $next (backup written)"
        "migrate_env_${have}_to_${next}"
        env_set ENV_SCHEMA "$next"
        have=$next
    done
    :
}
migrate_env_0_to_1() { :; } # base schema: nothing to do
migrate_env_1_to_2() {
    # profiles were groups; now profile == service name. Translate.
    local cur out="" tok
    cur=$(env_get COMPOSE_PROFILES)
    for tok in ${cur//,/ }; do case "$tok" in
        core) out+="gluetun qbittorrent sonarr radarr prowlarr jellyfin npm " ;;
        search) out+="meilisearch jellysearch " ;;
        requests) out+="seerr " ;;
        music) out+="lidarr " ;;
        subs) out+="bazarr " ;;
        dns) out+="pihole " ;;
        tunnel) out+="cloudflared " ;;
        torrents-extra) out+="deluge transmission " ;;
        tv) out+="ersatztv " ;;
        *) out+="$tok " ;;   # already a service name
    esac; done
    env_set COMPOSE_PROFILES "$(echo "$out" | tr ' ' '\n' | awk 'NF && !seen[$0]++' | paste -sd, -)"
    info "Profiles translated to per-service form: $(env_get COMPOSE_PROFILES)"
}

# ------------------------------------------------------------ compose layer --
DC() { # compose wrapper: project dir pinned, pin-override applied when present
    local files=(-f docker-compose.yml)
    [[ -s "$PINS_FILE" ]] && files+=(-f "$PINS_FILE")
    sudo docker compose --project-directory "$SCRIPT_DIR" "${files[@]}" "$@"
}

RENDERED_JSON=""
render() { # cache rendered config as json for discovery
    [[ -n "$RENDERED_JSON" ]] && return 0
    # --profile "*": discovery sees the whole catalogue, not just enabled
    # services — otherwise disabled services vanish from backups and audits.
    RENDERED_JSON=$(DC --profile "*" config --format json 2>/dev/null) \
        || die "docker compose could not render the config.
  Check: docker compose version >= 2.24 (needed for 'include:' and wildcard profiles), and that
  .env has no syntax errors. Try: docker compose config"
}

svc_all()      { render; jq -r '.services | keys[]' <<<"$RENDERED_JSON"; }
svc_label()    { render; jq -r --arg s "$1" --arg l "$2" '.services[$s].labels[$l] // ""' <<<"$RENDERED_JSON"; }
svc_managed()  { local s; for s in $(svc_all); do [[ $(svc_label "$s" mediastack.managed) == "true" ]] && echo "$s"; done; }
svc_exists()   { svc_all | grep -qx "$1"; }
svc_image()    { render; jq -r --arg s "$1" '.services[$s].image' <<<"$RENDERED_JSON"; }
svc_cname()    { render; jq -r --arg s "$1" '.services[$s].container_name // $s' <<<"$RENDERED_JSON"; }
uvar()         { echo "${1^^}" | tr -cd 'A-Z0-9_'; } # service -> env var stem
svc_enabled()  { [[ ",$(env_get COMPOSE_PROFILES)," == *",$1,"* ]]; }
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
cmd_help() {
    cat <<EOF
${C_BLD}Mediastack${C_RST} — usage: ./mediastack.sh <command>

Setup
  install        Install host dependencies (docker, jq, ...). Run once.
  configure      Interactive setup wizard. Writes .env, creates users and
                 folders. Safe to re-run any time — existing answers become
                 the defaults, and it auto-adopts newly added services.
  add-mount      Guided NFS/SMB mount on this host (fstab automount +
                 poison layer). NAS-side share setup is out of scope.
Run
  up             Start the stack (everything enabled in COMPOSE_PROFILES).
  down           Stop the stack. Configs and data are untouched.
  enable SVC     Turn one service on (dependencies come along) and start it.
  disable SVC    Turn one service off (refused while others depend on it).
  status [svc]   Overview table of every service — or a deep view of one
                 service (health, mounts, uid, recent log lines).
  logs SVC       Follow one service's logs.
Maintain
  update         Backup, then pull + apply new images (respects per-service
                 toggles and pins). Options: SVC (one service only),
                 SVC --to TAG (step to an exact version and pin there),
                 --dry-run (show what would change), --now (skip deferral).
  apply-timer    Install/refresh the systemd timer from UPDATE_SCHEDULE.
  backup         Take a restore point now (cold: brief stop/start).
  restore        Restore configs+image from a restore point:
                 --service SVC | --all  [--from TIMESTAMP]
  rollback SVC   Shortcut: restore SVC from the newest restore point.
  unpin SVC      Release a pinned service back to normal updates.
  upgrade        Pull the latest mediastack (git), migrate .env, summarize.
Check
  doctor         Full health/permission/resource audit with fix instructions.
  leak-test      Verify no VPN'd service can leak (--killswitch for the
                 disruptive drop-the-tunnel proof).
  fix-perms [s]  Repair config-dir ownership from the UID map.
Other
  new-service N  Scaffold a new compose.d fragment.
  uninstall      Remove the stack (tiered: containers / users / configs).
                 --nuke: everything in one confirmed shot; works even on a
                 broken tree. Media and backups are never touched.
  menu           Interactive menu wrapping all of the above.
EOF
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
    info "Installing base packages (curl, git, jq, ca-certificates)..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq curl git jq ca-certificates >/dev/null
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
    local cv
    cv=$(sudo docker compose version --short 2>/dev/null || echo "0")
    ok "docker compose $cv"
    printf '%s\n2.24.0\n' "$cv" | sort -V | head -n1 | grep -qx "2.20.0" \
        || warn "compose < 2.24 lacks 'include:'/wildcard profiles — upgrade the compose plugin."
    echo; ok "Dependencies ready. Next: ./mediastack.sh configure"
}

# --------------------------------------------------------------- configure --
explain() { echo; hr "$1"; shift; printf '%s\n' "$@"; echo; }

ask() { # ask VAR "prompt" "default" -> sets REPLY_VAL
    local def="$3" ans
    read -r -p "$2 [${def}]: " ans
    REPLY_VAL="${ans:-$def}"
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

cmd_configure() {
    need_cmd jq; need_cmd docker
    [[ -f "$ENV_FILE" ]] || { cp .env.example "$ENV_FILE"; chmod 600 "$ENV_FILE"; info "Created .env from .env.example"; }
    chmod 600 "$ENV_FILE" || true

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
        warn "DATA_ROOT and its torrent subdir are on different filesystems — hardlinks will not work."
    fi

    # -- services (à la carte)
    local STD="gluetun qbittorrent sonarr radarr prowlarr jellyfin npm meilisearch jellysearch seerr"
    explain "Services" \
"Pick exactly what runs — anything, à la carte. Dependencies are handled
for you (picking qBittorrent brings the VPN; JellySearch brings its
search engine). Change any of this later with enable/disable." \
"  1) standard    the recommended setup: VPN, qBittorrent, Sonarr, Radarr," \
"                 Prowlarr, Jellyfin + instant search, proxy, request site" \
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
               if [[ "$cur_en" == *",$s,"* || ( "$cur_en" == ",," && " $STD " == *" $s "* ) ]]; then dp="Y/n"; else dp="y/N"; fi
               read -r -p "  $s — ${d:-no description} [$dp]: " REPLY_VAL
               REPLY_VAL="${REPLY_VAL:-${dp:0:1}}"
               [[ "${REPLY_VAL,,}" == y* ]] && sel+="$s "
           done ;;
        *) sel="$STD" ;;
    esac
    [[ -n "$sel" ]] || die "No services selected — nothing to run."
    info "Resolving dependencies..."
    sel=$(resolve_deps $sel)
    env_set COMPOSE_PROFILES "$(echo "$sel" | paste -sd, -)"
    ok "Enabled: $(env_get COMPOSE_PROFILES)"

    # -- self-heal: adopt any *_UID / *_UPDATE vars referenced by compose
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
    done < <(grep -rhoE '\$\{[A-Z0-9_]+_(UID|UPDATE)[^}]*\}' docker-compose.yml compose.d/ \
             | sed -E 's/\$\{([A-Z0-9_]+).*/\1/' | sort -u)

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

    # -- secrets
    if [[ -z "$(env_get MEILI_MASTER_KEY)" ]]; then
        env_set MEILI_MASTER_KEY "$(openssl rand -base64 32 2>/dev/null || head -c32 /dev/urandom | base64)"
        ok "Generated Meilisearch master key (machine secret — you never need it)."
    fi
    if [[ "$(env_get COMPOSE_PROFILES)" == *tunnel* && -z "$(env_get CLOUDFLARE_TUNNEL_TOKEN)" ]]; then
        explain "Cloudflare tunnel token" \
"Cloudflare dashboard -> Zero Trust -> Networks -> Tunnels -> create a
'cloudflared' tunnel -> copy ONLY the long token from the docker command."
        read -r -p "Tunnel token: " REPLY_VAL; env_set CLOUDFLARE_TUNNEL_TOKEN "$REPLY_VAL"
    fi
    if [[ "$(env_get COMPOSE_PROFILES)" == *dns* && -z "$(env_get PIHOLE_PASSWORD)" ]]; then
        env_set PIHOLE_PASSWORD "$(head -c12 /dev/urandom | base64 | tr -d '=+/')"
        ok "Generated Pi-hole admin password (view it any time in .env)."
    fi

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

    provision
    [[ -n "$(env_get UPDATE_SCHEDULE)" ]] && cmd_apply_timer

    echo; hr "Configure complete"
    cat <<EOF
Next steps:
  1. ./mediastack.sh up          start everything
  2. ./mediastack.sh doctor      verify the deployment
  3. ./mediastack.sh leak-test   prove the VPN cannot leak
Then open the apps (ports in README) and connect them to each other.
EOF
}

provision() {
    hr "Provisioning users, group, folders"
    load_env
    local gid; gid=$(env_get MEDIA_GROUP_GID 13000)
    getent group mediacenter >/dev/null || { sudo groupadd -g "$gid" mediacenter; ok "group mediacenter ($gid)"; }
    local s v uid croot droot cache
    croot=$(env_get CONFIG_ROOT); droot=$(env_get DATA_ROOT); cache=$(env_get CACHE_ROOT)
    for s in $(svc_managed); do
        svc_enabled "$s" || continue
        v="$(uvar "$s")_UID"; uid=$(env_get "$v")
        if [[ -n "$uid" ]] && ! getent passwd "$s" >/dev/null; then
            sudo useradd -r -M -s /usr/sbin/nologin -u "$uid" -g mediacenter "$s" \
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
    done
    # data tree: shared group, setgid so new files inherit it
    local d
    for d in torrent media; do
        for sub in tv movies music books other; do sudo mkdir -p "$droot/$d/$sub"; done
    done
    sudo chown -R ":mediacenter" "$droot" 2>/dev/null || true
    sudo chmod -R g+rwX "$droot"
    sudo find "$droot" -type d -exec chmod g+s {} +
    ok "data tree ready (group mediacenter, setgid)"
    sudo mkdir -p "$(env_get BACKUP_ROOT)"
}

# ------------------------------------------------------------- up/down/... --
cmd_up()   { load_env; require_mounts; DC up -d --remove-orphans; ok "Stack up. Try: ./mediastack.sh status"; }
cmd_down() { load_env; DC down; ok "Stack stopped (configs and data untouched)."; }

cmd_enable() {
    local svc="${1:?usage: enable <service>}"; load_env
    svc_exists "$svc" || die "No service '$svc'. Known: $(svc_managed | tr '\n' ' ')"
    svc_enabled "$svc" && { ok "'$svc' already enabled."; return; }
    local sel cur; cur=$(env_get COMPOSE_PROFILES | tr ',' ' ')
    # shellcheck disable=SC2086  # word splitting intended: service list
    sel=$(resolve_deps "$svc" $cur)
    env_set COMPOSE_PROFILES "$(echo "$sel" | paste -sd, -)"
    require_mounts; provision >/dev/null   # users/dirs for the new services
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
    DC up -d --remove-orphans
    ok "'$svc' disabled; its container was removed (config kept, still backed up)."
}

cmd_logs() { load_env; DC logs -f --tail=100 "${1:?usage: logs <service>}"; }

# ------------------------------------------------------------------ status --
c_state()  { sudo docker inspect --format '{{.State.Status}}' "$1" 2>/dev/null || echo absent; }
c_health() { sudo docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$1" 2>/dev/null || echo -; }
c_uptime() { sudo docker inspect --format '{{.State.StartedAt}}' "$1" 2>/dev/null | cut -dT -f1 || true; }
c_version(){ sudo docker inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$1" 2>/dev/null || true; }

cmd_status() {
    load_env
    if [[ -n "${1:-}" ]]; then status_one "$1"; return; fi
    hr "Mediastack status"
    printf "%-14s %-4s %-9s %-10s %-12s %-8s %s\n" SERVICE VPN STATE HEALTH VERSION PINNED UPTIME
    local s cn pin vpn
    for s in $(svc_managed); do
        svc_enabled "$s" || continue
        cn=$(svc_cname "$s")
        pin=no; [[ -s "$PINS_FILE" ]] && grep -q "^  $s:" "$PINS_FILE" && pin="${C_YLW}yes${C_RST}"
        vpn=-; [[ $(svc_label "$s" mediastack.vpn) == "true" ]] && vpn=yes
        printf "%-14s %-4s %-9s %-10s %-12s %-8s %s\n" \
            "$s" "$vpn" "$(c_state "$cn")" "$(c_health "$cn")" "$(c_version "$cn" | cut -c1-12)" "$pin" "$(c_uptime "$cn")"
    done
    echo
    local off="" p
    for p in $(svc_managed); do svc_enabled "$p" || off+="$p "; done
    [[ -n "$off" ]] && info "Available, not enabled: $off"
    local last; last=$(ls -1 "$(env_get BACKUP_ROOT)" 2>/dev/null | tail -1 || true)
    info "Latest restore point: ${last:-none yet (run: ./mediastack.sh backup)}"
    df -h "$(env_get CONFIG_ROOT)" "$(env_get DATA_ROOT)" 2>/dev/null | tail -n +2 \
        | awk '{printf ":: disk %-24s %s used of %s (%s)\n", $6, $3, $2, $5}'
}

status_one() {
    local s="$1"; svc_exists "$s" || die "No service '$s'. Known: $(svc_managed | tr '\n' ' ')"
    local cn; cn=$(svc_cname "$s")
    hr "$s"
    echo "container : $cn"
    echo "state     : $(c_state "$cn")   health: $(c_health "$cn")"
    echo "image     : $(svc_image "$s")  version: $(c_version "$cn")"
    echo "user      : $(sudo docker inspect --format '{{.Config.User}}' "$cn" 2>/dev/null || echo -)"
    echo "restarts  : $(sudo docker inspect --format '{{.RestartCount}}' "$cn" 2>/dev/null || echo -)"
    echo "mounts    :"
    sudo docker inspect --format '{{range .Mounts}}  {{.Source}} -> {{.Destination}}{{println}}{{end}}' "$cn" 2>/dev/null || true
    hr "last 15 log lines"
    sudo docker logs --tail 15 "$cn" 2>&1 || true
}

# ------------------------------------------------------------------ backup --
ts_now() { date +%Y%m%d-%H%M%S; }

cmd_backup() {
    load_env; require_mounts
    local broot croot dest need have
    broot=$(env_get BACKUP_ROOT); croot=$(env_get CONFIG_ROOT)
    need=$(sudo du -sk "$croot" | awk '{print $1}')
    have=$(df -k --output=avail "$broot" | tail -1 | tr -d ' ')
    (( have > need + 524288 )) || die "Not enough space at $broot: need ~$((need/1024))MB (+512MB headroom), have $((have/1024))MB.
  Free space or point BACKUP_ROOT somewhere larger, then retry."
    dest="$broot/$(ts_now)"; sudo mkdir -p "$dest"
    info "Restore point: $dest"

    # images.lock BEFORE stopping (inspect needs the containers)
    local s cn ref
    { for s in $(svc_managed); do
        cn=$(svc_cname "$s")
        ref=$(sudo docker inspect --format '{{index .RepoDigests 0}}' "$cn" 2>/dev/null || true)
        [[ -n "$ref" ]] && echo "$s $ref"
      done; } | sudo tee "$dest/images.lock" >/dev/null

    info "Stopping stack for a consistent snapshot..."
    DC stop >/dev/null
    local rc=0
    for s in $(svc_managed); do
        [[ $(svc_label "$s" mediastack.config) == "true" && -d "$croot/$s" ]] || continue
        sudo tar -C "$croot" -czf "$dest/$s.tar.gz" "$s" || { fail "tar failed for $s"; rc=1; }
    done
    sudo cp "$ENV_FILE" "$dest/env"; sudo chmod 600 "$dest/env"
    [[ -s "$PINS_FILE" ]] && sudo cp "$PINS_FILE" "$dest/pins.yml"
    ( cd "$dest" && sudo sh -c 'sha256sum * > SHA256SUMS' )
    info "Restarting stack..."
    DC up -d >/dev/null
    (( rc == 0 )) && ok "Restore point complete: $dest" || die "Backup finished WITH ERRORS — do not trust $dest."
    prune_backups
}

prune_backups() {
    local broot keepd keepw
    broot=$(env_get BACKUP_ROOT); keepd=$(env_get BACKUP_KEEP_DAILY 7); keepw=$(env_get BACKUP_KEEP_WEEKLY 4)
    local total=$(( keepd + keepw * 7 ))
    local n; n=$(ls -1 "$broot" 2>/dev/null | wc -l)
    (( n > total )) || return 0
    ls -1 "$broot" | head -n $(( n - total )) | while read -r old; do
        info "Pruning old restore point $old"
        sudo rm -rf "${broot:?}/$old"
    done
}

cmd_backup_verify() {
    load_env
    local broot t="${1:-}"
    broot=$(env_get BACKUP_ROOT)
    [[ -n "$t" ]] || t=$(ls -1 "$broot" | tail -1)
    [[ -d "$broot/$t" ]] || die "No restore point '$t' under $broot"
    ( cd "$broot/$t" && sudo sha256sum -c SHA256SUMS ) && ok "Checksums OK for $t"
    local f; for f in "$broot/$t"/*.tar.gz; do
        sudo tar -tzf "$f" >/dev/null || die "Corrupt archive: $f"
    done
    ok "Archives readable. (True proof is a restore drill: restore --service <svc>.)"
}

# ------------------------------------------------- restore / rollback / pin --
pin_service() { # pin_service svc image_ref
    touch "$PINS_FILE"
    grep -q '^services:' "$PINS_FILE" || echo "services:" > "$PINS_FILE"
    if grep -q "^  $1:" "$PINS_FILE"; then
        # replace the image line following the service key
        sudo sed -i "/^  $1:/,/image:/ s|image:.*|image: $2|" "$PINS_FILE"
    else
        printf '  %s:\n    image: %s\n' "$1" "$2" >> "$PINS_FILE"
    fi
    ok "$1 pinned to $2 (updates hold; release with: ./mediastack.sh unpin $1)"
}

cmd_unpin() {
    local s="${1:?usage: unpin <service>}"; load_env
    [[ -s "$PINS_FILE" ]] || { ok "Nothing pinned."; return; }
    sed -i "/^  $s:/,+1d" "$PINS_FILE"
    [[ $(grep -c ':' "$PINS_FILE") -le 1 ]] && rm -f "$PINS_FILE"
    RENDERED_JSON=""; DC up -d "$s"
    ok "$s unpinned and returned to the floating tag. Next 'update' includes it."
}

cmd_restore() {
    load_env; require_mounts
    local svc="" all=0 from=""
    while [[ $# -gt 0 ]]; do case "$1" in
        --service) svc="$2"; shift 2 ;;
        --all) all=1; shift ;;
        --from) from="$2"; shift 2 ;;
        *) die "Unknown restore arg '$1' (usage: restore --service SVC|--all [--from TS])" ;;
    esac; done
    (( all )) || [[ -n "$svc" ]] || die "usage: restore --service SVC | --all  [--from TIMESTAMP]"
    local broot; broot=$(env_get BACKUP_ROOT)
    [[ -n "$from" ]] || from=$(ls -1 "$broot" 2>/dev/null | tail -1)
    [[ -n "$from" && -d "$broot/$from" ]] || die "No restore point found. Available: $(ls -1 "$broot" 2>/dev/null | tr '\n' ' ')"
    info "Restoring from $from"
    local targets; if (( all )); then targets=$(svc_managed); else targets="$svc"; fi
    local croot ts s ref
    croot=$(env_get CONFIG_ROOT); ts=$(ts_now)
    for s in $targets; do
        svc_exists "$s" || die "No service '$s'."
        DC stop "$s" >/dev/null
        if [[ -f "$broot/$from/$s.tar.gz" ]]; then
            [[ -d "$croot/$s" ]] && sudo mv "$croot/$s" "$croot/$s.pre-restore.$ts"
            sudo tar -C "$croot" -xzf "$broot/$from/$s.tar.gz"
            ok "$s config restored (previous kept at $s.pre-restore.$ts)"
        fi
        ref=$(awk -v s="$s" '$1==s{print $2}' "$broot/$from/images.lock" 2>/dev/null || true)
        [[ -n "$ref" ]] && pin_service "$s" "$ref"
        RENDERED_JSON=""
        DC up -d "$s"
    done
    ok "Restore done. Verify with: ./mediastack.sh status"
}

cmd_rollback() { cmd_restore --service "${1:?usage: rollback <service>}"; }

# ------------------------------------------------------------------ update --
jellyfin_sessions_active() {
    local key host; key=$(env_get JELLYFIN_API_KEY); host="http://127.0.0.1:$(env_get JELLYFIN_PORT 8096)"
    [[ -n "$key" ]] || return 1
    local n
    n=$(curl -fsS --max-time 5 "$host/Sessions?api_key=$key" 2>/dev/null \
        | jq '[.[] | select(.NowPlayingItem != null)] | length' 2>/dev/null || echo 0)
    (( n > 0 ))
}

cmd_update() {
    load_env; require_mounts
    local one="" to_tag="" dry=0 now=0 auto=0
    while [[ $# -gt 0 ]]; do case "$1" in
        --dry-run) dry=1; shift ;;
        --now) now=1; shift ;;
        --auto) auto=1; shift ;;
        --to) to_tag="$2"; shift 2 ;;
        *) one="$1"; shift ;;
    esac; done
    [[ -n "$to_tag" && -z "$one" ]] && die "--to requires a service: update <svc> --to <tag>"
    [[ -n "$one" ]] && { svc_exists "$one" || die "No service '$one'."; }

    # session deferral (auto runs only)
    if (( auto )) && [[ "$(env_get UPDATE_DEFER_IF_ACTIVE false)" == true ]] && (( ! now )); then
        local waited=0 retry max
        retry=$(( $(env_get UPDATE_DEFER_RETRY_MIN 30) * 60 )); max=$(( $(env_get UPDATE_DEFER_MAX_MIN 180) * 60 ))
        while jellyfin_sessions_active; do
            (( waited >= max )) && { [[ "$(env_get UPDATE_DEFER_ACTION proceed)" == skip ]] \
                && { warn "Streams still active after max deferral — SKIPPING this update run."; return 0; } \
                || { warn "Streams still active after max deferral — proceeding anyway."; break; }; }
            info "Active stream detected — deferring update $((retry/60))min..."
            sleep "$retry"; waited=$(( waited + retry ))
        done
    fi

    # build target list honouring toggles + pins
    [[ -n "$one" ]] && ! svc_enabled "$one" && die "'$one' is not enabled — enable it first or skip it."
    local targets=() s
    for s in $(svc_managed); do
        svc_enabled "$s" || continue
        [[ -n "$one" && "$s" != "$one" ]] && continue
        [[ -z "$one" ]] && { [[ "$(env_get "$(uvar "$s")_UPDATE" true)" == true ]] || continue; }
        [[ -s "$PINS_FILE" ]] && grep -q "^  $s:" "$PINS_FILE" && [[ -z "$to_tag" ]] \
            && { info "$s is pinned — skipping (unpin to resume updates)."; continue; }
        targets+=("$s")
    done
    (( ${#targets[@]} )) || { ok "Nothing to update."; return 0; }

    if (( dry )); then
        hr "update --dry-run"
        for s in "${targets[@]}"; do
            local cn cur; cn=$(svc_cname "$s"); cur=$(c_version "$cn")
            echo "$s: would pull $( [[ -n "$to_tag" ]] && echo "$(svc_image "$s" | cut -d: -f1):$to_tag" || svc_image "$s" ) (currently ${cur:-unknown})"
        done
        return 0
    fi

    hr "Update: restore point first"
    cmd_backup

    if [[ -n "$to_tag" ]]; then
        local base; base=$(svc_image "$one" | cut -d: -f1)
        pin_service "$one" "$base:$to_tag"
        RENDERED_JSON=""
    fi

    hr "Pulling images"
    local after changed=()
    local -A before=()
    for s in "${targets[@]}"; do before[$s]=$(c_version "$(svc_cname "$s")"); done
    DC pull "${targets[@]}"
    hr "Applying"
    DC up -d --remove-orphans "${targets[@]}"
    sudo docker image prune -f >/dev/null

    hr "Health gate"
    local deadline=$(( $(date +%s) + 300 )) bad=()
    for s in "${targets[@]}"; do
        local cn h; cn=$(svc_cname "$s")
        while :; do
            h=$(c_health "$cn")
            [[ "$h" == healthy || "$h" == "-" ]] && break
            (( $(date +%s) > deadline )) && { bad+=("$s"); break; }
            sleep 5
        done
        after=$(c_version "$cn")
        [[ "${before[$s]}" != "$after" ]] && changed+=("$s: ${before[$s]:-?} -> ${after:-?}")
    done
    # search functional probe: index must exist and be non-empty
    if svc_enabled jellysearch; then
        local docs
        docs=$(sudo docker exec "$(svc_cname meilisearch)" sh -c \
               "curl -fsS -H 'Authorization: Bearer $(env_get MEILI_MASTER_KEY)' http://127.0.0.1:7700/stats \
                || wget -qO- --header='Authorization: Bearer $(env_get MEILI_MASTER_KEY)' http://127.0.0.1:7700/stats" \
               2>/dev/null | jq '[.indexes[].numberOfDocuments] | add // 0' || echo 0)
        (( docs > 0 )) && ok "search index: $docs documents" \
            || { warn "search index EMPTY after update — try 'docker restart $(svc_cname jellysearch)';"; warn "if it stays empty: ./mediastack.sh rollback jellyfin"; bad+=("jellysearch(index)"); }
    fi

    echo; hr "Update summary"
    (( ${#changed[@]} )) && printf '  %s\n' "${changed[@]}" || echo "  no version changes"
    if (( ${#bad[@]} )); then
        fail "Unhealthy after update: ${bad[*]}"
        echo "  Roll back any of them with: ./mediastack.sh rollback <service>"
        exit 1
    fi
    ok "All updated services healthy."
}

cmd_apply_timer() {
    load_env
    local sched; sched=$(env_get UPDATE_SCHEDULE)
    if [[ -z "$sched" ]]; then
        sudo systemctl disable --now mediastack-update.timer 2>/dev/null || true
        ok "Automatic updates disabled (UPDATE_SCHEDULE is empty)."
        return
    fi
    systemd-analyze calendar "$sched" >/dev/null 2>&1 || die "UPDATE_SCHEDULE '$sched' is invalid."
    sudo tee /etc/systemd/system/mediastack-update.service >/dev/null <<EOF
[Unit]
Description=Mediastack update pipeline
[Service]
Type=oneshot
WorkingDirectory=$SCRIPT_DIR
ExecStart=$SCRIPT_DIR/mediastack.sh update --auto
EOF
    sudo tee /etc/systemd/system/mediastack-update.timer >/dev/null <<EOF
[Unit]
Description=Mediastack scheduled update
[Timer]
OnCalendar=$sched
Persistent=true
[Install]
WantedBy=timers.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now mediastack-update.timer
    ok "Timer installed: $sched (next: $(systemctl show mediastack-update.timer -p NextElapseUSecRealtime --value 2>/dev/null || echo '?'))"
}

# ------------------------------------------------------------------ doctor --
D_FAILS=0
d_fail() { fail "$1"; printf '     why : %s\n     fix : %s\n' "$2" "$3"; D_FAILS=$((D_FAILS+1)); }

cmd_doctor() {
    load_env; need_cmd jq
    hr "doctor: environment"
    local root
    for root in CONFIG_ROOT DATA_ROOT CACHE_ROOT BACKUP_ROOT; do
        [[ -n "$(env_get "$root")" ]] && ok "$root=$(env_get "$root")" \
            || d_fail "$root unset" "the stack cannot locate its files" "run: ./mediastack.sh configure"
    done
    local fs; fs=$(fstype_of "$(env_get CONFIG_ROOT)")
    [[ "$fs" =~ ^(nfs|nfs4|cifs|smb3)$ ]] \
        && d_fail "CONFIG_ROOT on $fs" "SQLite databases corrupt on network shares" "move configs to local disk (see docs/migration-existing.md)" \
        || ok "CONFIG_ROOT filesystem: $fs"
    require_mounts && ok "mount identity checks pass"

    hr "doctor: containers"
    local s cn st h
    for s in $(svc_managed); do
        cn=$(svc_cname "$s"); st=$(c_state "$cn"); h=$(c_health "$cn")
        case "$st:$h" in
            running:healthy|running:-) ok "$s ($st${h:+, $h})" ;;
            absent:*) if svc_enabled "$s"; then
                          d_fail "$s enabled but not running" "container was never created or was removed" "./mediastack.sh up"
                      else info "$s not enabled — skipped"; fi ;;
            *) d_fail "$s is $st/$h" "service is not serving" "./mediastack.sh logs $s   (then: rollback $s if a recent update broke it)" ;;
        esac
    done

    hr "doctor: permissions"
    local croot uid v bad
    croot=$(env_get CONFIG_ROOT)
    for s in $(svc_managed); do
        [[ $(svc_label "$s" mediastack.config) == "true" ]] || continue
        v="$(uvar "$s")_UID"; uid=$(env_get "$v"); [[ -n "$uid" && -d "$croot/$s" ]] || continue
        bad=$(sudo find "$croot/$s" \( -not -user "$uid" -o -not -group "$(env_get MEDIA_GROUP_GID)" \) 2>/dev/null | head -3)
        if [[ -n "$bad" ]]; then
            d_fail "$s: files not owned $uid:mediacenter" "the app cannot write its own config" "./mediastack.sh fix-perms $s"
        else
            sudo runuser -u "#$uid" -- test -w "$croot/$s" 2>/dev/null \
                && ok "$s config ownership + write access" \
                || d_fail "$s: uid $uid cannot write $croot/$s" "mode/ACL problem despite ownership" "./mediastack.sh fix-perms $s"
        fi
    done
    # jellysearch must READ jellyfin's config
    if svc_enabled jellysearch; then
        sudo runuser -u "#$(env_get JELLYFIN_UID)" -- test -r "$croot/jellyfin" 2>/dev/null \
            && ok "jellysearch can read jellyfin's config" \
            || d_fail "jellysearch cannot read $croot/jellyfin" "search cannot index" "./mediastack.sh fix-perms jellyfin"
    fi
    # artifact sweep
    sudo find "$(env_get DATA_ROOT)" -maxdepth 2 -name '*{*}*' 2>/dev/null | grep -q . \
        && warn "literal '{...}' directories under DATA_ROOT — junk from an old installer; safe to remove"
    sudo find "$croot" -maxdepth 1 -name '*.pre-restore.*' 2>/dev/null | grep -q . \
        && warn "old *.pre-restore.* trees under CONFIG_ROOT — remove once you trust the restore"

    hr "doctor: host resources"
    df -h "$croot" "$(env_get DATA_ROOT)" 2>/dev/null | tail -n +2 | while read -r line; do
        local pct; pct=$(awk '{print $5}' <<<"$line" | tr -d %)
        (( pct >= 90 )) && warn "disk >90%: $line" || ok "disk: $line"
    done
    local memfree loadavg cores
    memfree=$(awk '/MemAvailable/{printf "%.1f", $2/1048576}' /proc/meminfo)
    loadavg=$(awk '{print $1}' /proc/loadavg); cores=$(nproc)
    awk -v m="$memfree" 'BEGIN{exit !(m<1)}' && warn "available RAM low: ${memfree}G" || ok "available RAM: ${memfree}G"
    awk -v l="$loadavg" -v c="$cores" 'BEGIN{exit !(l>c)}' && warn "load $loadavg exceeds $cores cores" || ok "load $loadavg / $cores cores"
    sudo docker system df | tail -n +2 | sed 's/^/:: docker /'

    hr "doctor: host neighbours"
    sudo docker ps --format '{{.Names}} {{.Image}}' | grep -Ei 'watchtower|ouroboros|autoheal' | grep -v mediastack \
        && warn "foreign auto-updater found on this host — it may update mediastack containers behind the backup system's back (our labels tell watchtower no; verify it honours them)" \
        || ok "no foreign auto-updaters"
    # docker subnet vs host routes overlap
    local net
    while read -r net; do
        [[ -z "$net" ]] && continue
        ip route | grep -v docker | grep -v "^default" | grep -q "^${net%.*}" \
            && warn "docker subnet $net overlaps a host route — containers may fail to reach the LAN/NAS. Fix: 'default-address-pools' in /etc/docker/daemon.json (restarts ALL containers on this host — do it in a window)."
    done < <(sudo docker network ls -q | xargs -r sudo docker network inspect \
             --format '{{range .IPAM.Config}}{{.Subnet}}{{println}}{{end}}' 2>/dev/null \
             | grep -oE '^[0-9.]+' || true)

    hr "doctor: vpn + backups"
    if [[ "$(c_state "$(svc_cname gluetun)")" == running ]]; then
        local vip; vip=$(sudo docker exec "$(svc_cname gluetun)" wget -qO- --timeout=8 https://ipinfo.io/ip 2>/dev/null || true)
        [[ -n "$vip" ]] && ok "tunnel public IP: $vip" \
            || d_fail "cannot fetch IP through tunnel" "VPN may be down; downloads are dead (not leaking — kill-switch)" "./mediastack.sh logs gluetun"
    fi
    local last age broot; broot=$(env_get BACKUP_ROOT)
    last=$(ls -1 "$broot" 2>/dev/null | tail -1 || true)
    if [[ -n "$last" ]]; then
        age=$(( ( $(date +%s) - $(date -d "$(sed -E 's/([0-9]{8})-([0-9]{2})([0-9]{2}).*/\1 \2:\3/' <<<"$last")" +%s 2>/dev/null || date +%s) ) / 3600 ))
        (( age > 48 )) && warn "latest restore point is ${age}h old — run: ./mediastack.sh backup" || ok "latest restore point ${age}h old"
    else
        warn "no restore points yet — run: ./mediastack.sh backup"
    fi

    echo
    if (( D_FAILS )); then fail "doctor: $D_FAILS problem(s) — fixes listed above."; exit 1
    else ok "doctor: all checks passed."; fi
}

cmd_fix_perms() {
    load_env
    local croot targets s v uid
    croot=$(env_get CONFIG_ROOT)
    targets="${1:-$(svc_managed)}"
    for s in $targets; do
        [[ $(svc_label "$s" mediastack.config) == "true" ]] || continue
        v="$(uvar "$s")_UID"; uid=$(env_get "$v"); [[ -n "$uid" && -d "$croot/$s" ]] || continue
        sudo chown -R "$uid:mediacenter" "$croot/$s"
        ok "$s -> $uid:mediacenter"
    done
}

# --------------------------------------------------------------- leak-test --
cmd_leak_test() {
    load_env
    local killswitch=0; [[ "${1:-}" == --killswitch ]] && killswitch=1
    local gcn; gcn=$(svc_cname gluetun)
    [[ "$(c_state "$gcn")" == running ]] || die "gluetun is not running — start the stack first."

    hr "leak-test: attachment audit"
    local gsandbox rc=0 s cn nm sb
    gsandbox=$(sudo docker inspect --format '{{.NetworkSettings.SandboxKey}}' "$gcn")
    for s in $(svc_managed); do
        [[ $(svc_label "$s" mediastack.vpn) == "true" ]] || continue
        cn=$(svc_cname "$s"); [[ "$(c_state "$cn")" == running ]] || { info "$s not running — skipped"; continue; }
        nm=$(sudo docker inspect --format '{{.HostConfig.NetworkMode}}' "$cn")
        sb=$(sudo docker inspect --format '{{.NetworkSettings.SandboxKey}}' "$cn")
        if [[ "$nm" == container:* && "$sb" == "$gsandbox" ]]; then ok "$s runs inside gluetun's namespace"
        else fail "$s is NOT inside gluetun's namespace (mode: $nm) — this IS a leak path"; rc=1; fi
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
    # resolver identity
    sudo docker run --rm --network "container:$gcn" curlimages/curl:latest \
        -fsS --max-time 8 https://ipinfo.io/ip >/dev/null 2>&1 \
        && ok "DNS resolves inside the namespace (gluetun's resolver)"

    hr "leak-test: kill-switch"
    sudo docker exec "$gcn" sh -c 'iptables -S OUTPUT 2>/dev/null | grep -q -- "-j DROP"' \
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
    fi

    hr "leak-test: host port sweep"
    for s in $(svc_managed); do
        [[ $(svc_label "$s" mediastack.vpn) == "true" ]] || continue
        render
        jq -e --arg s "$s" '.services[$s].ports // [] | length == 0' <<<"$RENDERED_JSON" >/dev/null \
            && ok "$s publishes no ports of its own" \
            || { fail "$s publishes host ports directly — must go through gluetun"; rc=1; }
    done
    echo
    (( rc == 0 )) && ok "leak-test passed." || { fail "leak-test FOUND PROBLEMS — see above."; exit 1; }
}

# ------------------------------------------------------- upgrade/uninstall --
cmd_upgrade() {
    need_cmd git
    [[ -z "$(git status --porcelain 2>/dev/null)" ]] || die "Working tree has local changes to tracked files.
  Mediastack keeps user state in .env / override files, so tracked files
  should be clean. Review 'git status', stash or move changes into
  docker-compose.override.yml, then retry."
    local before; before=$(git rev-parse HEAD)
    git pull --ff-only || die "git pull failed (diverged history?). Resolve manually."
    [[ "$before" == "$(git rev-parse HEAD)" ]] && { ok "Already up to date."; return; }
    hr "Changes pulled"; git log --oneline "$before..HEAD" | sed 's/^/  /'
    load_env   # runs schema migrations
    provision >/dev/null || true
    ok "Upgrade complete. Apply new images when ready: ./mediastack.sh update"
}

cmd_nuke() {
    # Deliberately does NOT need a working compose render or .env — it must
    # succeed on a half-deleted deployment. Containers are found by compose
    # project label; users by the mediacenter group in /etc/passwd.
    hr "NUKE: remove everything the installer created"
    echo "Removes: containers, docker network, systemd units,"
    echo "         service users + group, CONFIG_ROOT, CACHE_ROOT."
    echo "Keeps  : DATA_ROOT (your media), BACKUP_ROOT (restore points),"
    echo "         .env and this repo folder (delete those yourself)."
    echo "Note   : stop the stack BEFORE deleting this folder — running"
    echo "         containers recreate their bind-mount dirs forever."
    local really; read -r -p "Type 'nuke mediastack' to proceed: " really
    [[ "$really" == "nuke mediastack" ]] || { info "Aborted — nothing touched."; return 1; }

    sudo systemctl disable --now mediastack-update.timer 2>/dev/null || true
    sudo rm -f /etc/systemd/system/mediastack-update.service /etc/systemd/system/mediastack-update.timer
    sudo systemctl daemon-reload
    ok "systemd units removed"
    sudo docker ps -aq --filter "label=com.docker.compose.project=mediastack" \
        | xargs -r sudo docker rm -f >/dev/null
    ok "containers removed"
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
    DC down --remove-orphans; ok "containers removed"
    sudo systemctl disable --now mediastack-update.timer 2>/dev/null || true
    sudo rm -f /etc/systemd/system/mediastack-update.service /etc/systemd/system/mediastack-update.timer
    sudo systemctl daemon-reload
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

cmd_new_service() {
    local name="${1:?usage: new-service <name>}"
    local f="compose.d/${name}.yml"
    [[ -e "$f" ]] && die "$f already exists."
    sed -e "s/__NAME__/${name}/g" -e "s/__UPPER__/$(uvar "$name")/g" > "$f" <<'EOF'
# __NAME__ profile — fill in image/ports/volumes, then:
#   ./mediastack.sh configure   (adopts the new UID/UPDATE vars)
#   ./mediastack.sh enable __NAME__
x-logging: &logging
  driver: json-file
  options:
    max-size: ${LOG_MAX_SIZE:-10m}
    max-file: ${LOG_MAX_FILE:-3}
x-armour: &no-foreign-watchtower
  com.centurylinklabs.watchtower.enable: "false"
services:
  __NAME__:
    image: CHANGEME:latest
    container_name: ${__UPPER___NAME:-mediastack-__NAME__}
    profiles: ["__NAME__"]
    environment:
      - TZ=${TZ}
      - PUID=${__UPPER___UID}
      - PGID=${MEDIA_GROUP_GID}
      - UMASK=002
    volumes:
      - ${CONFIG_ROOT}/__NAME__:/config
    labels:
      <<: *no-foreign-watchtower
      mediastack.managed: "true"
      mediastack.vpn: "false"
      mediastack.config: "true"
    networks: [mediastack]
    logging: *logging
    restart: unless-stopped
EOF
    ok "Scaffolded $f — edit it, then run: ./mediastack.sh configure && ./mediastack.sh enable $name"
    warn "Remember: add '- compose.d/${name}.yml' to the include list in docker-compose.yml"
}

# -------------------------------------------------------------- dispatcher --
main() {
    local cmd="${1:-help}"; shift || true
    case "$cmd" in
        help|-h|--help) cmd_help ;;
        menu)         cmd_menu ;;
        install)      cmd_install ;;
        configure)    cmd_configure ;;
        up)           cmd_up ;;
        down)         cmd_down ;;
        enable)       cmd_enable "$@" ;;
        disable)      cmd_disable "$@" ;;
        status)       cmd_status "$@" ;;
        logs)         cmd_logs "$@" ;;
        update)       cmd_update "$@" ;;
        apply-timer)  cmd_apply_timer ;;
        backup)       if [[ "${1:-}" == verify ]]; then shift; cmd_backup_verify "$@"; else cmd_backup "$@"; fi ;;
        restore)      cmd_restore "$@" ;;
        rollback)     cmd_rollback "$@" ;;
        unpin)        cmd_unpin "$@" ;;
        doctor)       cmd_doctor ;;
        leak-test)    cmd_leak_test "$@" ;;
        fix-perms)    cmd_fix_perms "$@" ;;
        add-mount)    cmd_add_mount ;;
        new-service)  cmd_new_service "$@" ;;
        upgrade)      cmd_upgrade ;;
        uninstall)    cmd_uninstall "$@" ;;
        *) fail "Unknown command '$cmd'"; echo; cmd_help; exit 1 ;;
    esac
}
main "$@"
