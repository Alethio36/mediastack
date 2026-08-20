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
SCRIPT_SCHEMA=8

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

env_del() { sed -i "/^$1=/d" "$ENV_FILE"; } # remove a variable entirely

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
migrate_env_2_to_3() {
    # ersatztv's upstream image is rootful (no user mapping) — a UID entry
    # for it made doctor audit root-owned files against a fictional owner.
    env_del ERSATZTV_UID
    info "Removed ERSATZTV_UID (ersatztv runs as root by upstream design)."
}
migrate_env_3_to_4() { :; } # .env.example default change only; existing values stand
migrate_env_4_to_5() { :; } # additive only (arr instances, wire credentials)
migrate_env_5_to_6() { :; } # additive only (stack-wide arr login)
migrate_env_6_to_7() {
    # wave 4 adds wizarr: adopt its vars so enable/up on an existing .env
    # never renders unset variables (configure's self-heal only runs there).
    if ! grep -qE '^WIZARR_UID=' "$ENV_FILE"; then
        local max
        max=$(grep -E '_UID=[0-9]+' "$ENV_FILE" | cut -d= -f2 | sort -n | tail -1)
        env_set WIZARR_UID "$(( ${max:-$(env_get UID_BASE 13000)} + 1 ))"
        info "New service variable WIZARR_UID -> $(env_get WIZARR_UID)"
    fi
    grep -qE '^WIZARR_UPDATE=' "$ENV_FILE" || env_set WIZARR_UPDATE true
}
migrate_env_7_to_8() {
    # wave 5 adds apprise (+ cleanuparr later in the wave)
    if ! grep -qE '^APPRISE_UID=' "$ENV_FILE"; then
        local max
        max=$(grep -E '_UID=[0-9]+' "$ENV_FILE" | cut -d= -f2 | sort -n | tail -1)
        env_set APPRISE_UID "$(( ${max:-$(env_get UID_BASE 13000)} + 1 ))"
        info "New service variable APPRISE_UID -> $(env_get APPRISE_UID)"
    fi
    grep -qE '^APPRISE_UPDATE=' "$ENV_FILE" || env_set APPRISE_UPDATE true
    if ! grep -qE '^CLEANUPARR_UID=' "$ENV_FILE"; then
        local cmax
        cmax=$(grep -E '_UID=[0-9]+' "$ENV_FILE" | cut -d= -f2 | sort -n | tail -1)
        env_set CLEANUPARR_UID "$(( ${cmax:-$(env_get UID_BASE 13000)} + 1 ))"
        info "New service variable CLEANUPARR_UID -> $(env_get CLEANUPARR_UID)"
    fi
    grep -qE '^CLEANUPARR_UPDATE=' "$ENV_FILE" || env_set CLEANUPARR_UPDATE true
}

# ------------------------------------------------------------ compose layer --
DC() { # compose wrapper: project dir pinned, pin-override applied when present
    local files=(-f docker-compose.yml)
    [[ -s "$PINS_FILE" ]] && files+=(-f "$PINS_FILE")
    sudo docker compose --project-directory "$SCRIPT_DIR" "${files[@]}" "$@"
}

RENDERED_JSON=""
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
  Needs compose >= 2.24 ('include:' + wildcard profiles); check .env syntax."
    fi
    rm -f "$rerr"
}

svc_all()      { render; jq -r '.services | keys[]' <<<"$RENDERED_JSON"; }
svc_label()    { render; jq -r --arg s "$1" --arg l "$2" '.services[$s].labels[$l] // ""' <<<"$RENDERED_JSON"; }
svc_managed()  { local s; for s in $(svc_all); do [[ $(svc_label "$s" mediastack.managed) == "true" ]] && echo "$s"; done; }
svc_exists()   { svc_all | grep -qx "$1"; }
svc_image()    { render; jq -r --arg s "$1" '.services[$s].image' <<<"$RENDERED_JSON"; }
svc_cname()    { render; jq -r --arg s "$1" '.services[$s].container_name // $s' <<<"$RENDERED_JSON"; }
uvar()         { echo "${1^^}" | tr '-' '_' | tr -cd 'A-Z0-9_'; } # service -> env var stem (radarr-4k -> RADARR_4K)
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
Connect
  wire           Configure the apps to talk to each other: qBittorrent
                 credentials+categories, arr root folders, arr->qbit,
                 Prowlarr->arrs, FlareSolverr, Bazarr, Jellyfin first-run
                 (+libraries), Seerr bootstrap, Wizarr key. Idempotent —
                 re-run any time; GUI-configured apps are never overwritten.
                 Scope: wire [qbit|arr|prowlarr|bazarr|apprise|cleanuparr|jellyfin|seerr|wizarr];
                 preview: wire --dry-run.
  invite         Mint a Wizarr invitation and print the ready-to-share URL.
                 Options: --expires 1|7|30 (default: never expires).
  credentials    Show the app logins wire created/stored.
  set-credentials Rotate a stored login everywhere it lives, atomically:
                 set-credentials <arr|qbit|jellyfin>.
  traefik-setup  Configure the HTTPS edge: domain, Cloudflare token, cert
                 environment (staging/production), dashboard login. Auto-runs
                 on 'up' when traefik is enabled and unconfigured.
                 --hosts: guided rename of every service's subdomain.
                 --certs: switch staging/production certificates (applied
                 immediately — store reset + traefik restart, no .env edit).
  trash-sync     Sync TRaSH Guides quality profiles (Recyclarr) to the arrs.
                 First run asks per-instance choices; overrides survive in
                 local/trash-overrides.yml. See docs/trash-sync.md.
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
        warn "DATA_ROOT and its torrent subdir are on different filesystems — hardlinks will not work: imports fall back to slow, space-doubling copies. Union the drives (e.g. mergerfs) and use the pool as DATA_ROOT (see README)."
    fi

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
    done < <(grep -rhoE '\$\{[A-Z0-9_]+_(UID|UPDATE)[^}]*\}' docker-compose.yml compose.d/ \
             | sed -E 's/\$\{([A-Z0-9_]+).*/\1/' | sort -u)

    # -- services (à la carte)
    render
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
    if svc_enabled cloudflared && [[ -z "$(env_get CLOUDFLARE_TUNNEL_TOKEN)" ]]; then
        explain "Cloudflare tunnel" \
"The tunnel is created on CLOUDFLARE'S side; this stack just runs the
connector. One-time setup in their dashboard:" \
"  1. dash.cloudflare.com -> Zero Trust -> Networks -> Tunnels" \
"  2. Create a tunnel (type: cloudflared), name it, save" \
"  3. From the install step, copy ONLY the long token string" \
"     (the part after '--token' in the command they show)" \
"AFTER the stack is up, routing also lives in that dashboard: add Public
Hostnames pointing at http://npm:80 (recommended — reuses your proxy
hosts and certificates) or directly at a service, e.g. http://jellyfin:8096.
Service names resolve — cloudflared shares the stack's network."
        read -r -p "Tunnel token: " REPLY_VAL
        [[ -n "$REPLY_VAL" ]] && env_set CLOUDFLARE_TUNNEL_TOKEN "$REPLY_VAL" \
            || warn "No token — cloudflared will crash-loop until one is set in .env."
    fi
    if svc_enabled pihole && [[ -z "$(env_get PIHOLE_PASSWORD)" ]]; then
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
    load_env; render
    local gid; gid=$(env_get MEDIA_GROUP_GID 13000)
    getent group mediacenter >/dev/null || { sudo groupadd -g "$gid" mediacenter; ok "group mediacenter ($gid)"; }
    local s v uid croot droot cache
    croot=$(env_get CONFIG_ROOT); droot=$(env_get DATA_ROOT); cache=$(env_get CACHE_ROOT)
    for s in $(svc_managed); do
        svc_enabled "$s" || continue
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
        local stub
        while read -r stub; do
            [[ -z "$stub" ]] && continue
            sudo mkdir -p "$stub"
            [[ -n "$uid" ]] && sudo chown "$uid:mediacenter" "$stub"
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
    for s in $(svc_managed); do
        svc_enabled "$s" || continue
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
    for d in torrent media; do
        for sub in tv movies music books other; do sudo mkdir -p "$droot/$d/$sub"; done
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
    for s in $(svc_managed); do
        svc_enabled "$s" && continue
        cn=$(svc_cname "$s")
        if [[ $(c_state "$cn") != absent ]]; then
            sudo docker rm -f -v "$cn" >/dev/null
            info "removed container for disabled service: $s"
        fi
    done
}

cmd_up()   {
    load_env; require_mounts; reconcile_disabled
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

cmd_logs() { load_env; DC logs -f --tail=100 "${1:?usage: logs <service>}"; }

# ------------------------------------------------------------------ status --
# NOTE: on a missing container, some docker versions emit a blank stdout line
# alongside the stderr error — strip newlines and treat empty as the sentinel.
c_state()  { local o; o=$(sudo docker inspect --format '{{.State.Status}}' "$1" 2>/dev/null | tr -d '\n'); echo "${o:-absent}"; }
c_health() { local o; o=$(sudo docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$1" 2>/dev/null | tr -d '\n'); echo "${o:--}"; }
c_uptime() { # human-readable duration since container start (e.g. 3d4h, 12m, 45s)
    local st sec
    st=$(sudo docker inspect --format '{{.State.StartedAt}}' "$1" 2>/dev/null | tr -d '\n')
    [[ -n "$st" ]] || { echo "-"; return; }
    sec=$(( $(date +%s) - $(date -d "$st" +%s 2>/dev/null || date +%s) ))
    (( sec < 0 )) && sec=0
    if   (( sec >= 86400 )); then echo "$((sec/86400))d$(( (sec%86400)/3600 ))h"
    elif (( sec >= 3600 ));  then echo "$((sec/3600))h$(( (sec%3600)/60 ))m"
    elif (( sec >= 60 ));    then echo "$((sec/60))m$((sec%60))s"
    else echo "${sec}s"; fi
}
c_version(){ sudo docker inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$1" 2>/dev/null | tr -d '\n' || true; }
c_restarts(){ local o; o=$(sudo docker inspect --format '{{.RestartCount}}' "$1" 2>/dev/null | tr -d '\n'); echo "${o:-0}"; }

cmd_status() {
    load_env; render
    if [[ -n "${1:-}" ]]; then status_one "$1"; return; fi
    hr "Mediastack status"
    printf "%-14s %-5s %-4s %-9s %-10s %-12s %-8s %s\n" SERVICE PORT VPN STATE HEALTH VERSION PINNED UPTIME
    local s cn pin vpn port
    for s in $(svc_managed); do
        svc_enabled "$s" || continue
        cn=$(svc_cname "$s")
        pin=no; [[ -s "$PINS_FILE" ]] && grep -q "^  $s:" "$PINS_FILE" && pin="${C_YLW}yes${C_RST}"
        vpn=-; [[ $(svc_label "$s" mediastack.vpn) == "true" ]] && vpn=yes
        port=$(svc_label "$s" mediastack.port); port=${port:--}
        printf "%-14s %-5s %-4s %-9s %-10s %-12s %-8s %s\n" \
            "$s" "$port" "$vpn" "$(c_state "$cn")" "$(c_health "$cn")" "$(c_version "$cn" | cut -c1-12)" "$pin" "$(c_uptime "$cn")"
    done
    echo
    local off="" p
    for p in $(svc_managed); do svc_enabled "$p" || off+="$p "; done
    [[ -n "$off" ]] && info "Available, not enabled: $off"
    local last; last=$(ls -1 "$(env_get BACKUP_ROOT)" 2>/dev/null | tail -1 || true)
    info "Latest restore point: ${last:-none yet (run: ./mediastack.sh backup)}"
    df -h "$(env_get CONFIG_ROOT)" "$(env_get DATA_ROOT)" 2>/dev/null | tail -n +2 | sort -u \
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
    local s cn img ref
    { for s in $(svc_managed); do
        cn=$(svc_cname "$s")
        # RepoDigests is an IMAGE field: resolve container -> image -> digest
        img=$(sudo docker inspect --format '{{.Image}}' "$cn" 2>/dev/null | tr -d '\n' || true)
        [[ -n "$img" ]] || continue
        ref=$(sudo docker image inspect --format '{{index .RepoDigests 0}}' "$img" 2>/dev/null | tr -d '\n' || true)
        [[ -n "$ref" ]] && echo "$s $ref"
      done; } | sudo tee "$dest/images.lock" >/dev/null
    [[ -s "$dest/images.lock" ]] || warn "images.lock is empty — image-exact rollback unavailable for this point"

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
    if (( rc == 0 )); then ok "Restore point complete: $dest"
    else
        notify ops "Mediastack backup FAILED" "Restore point $dest finished with errors — do not trust it. Inspect on the host." failure
        die "Backup finished WITH ERRORS — do not trust $dest."
    fi
    prune_backups
}

# Tiered (grandfather-father-son) retention, all knobs in .env:
#   BACKUP_KEEP_DAILY   (7)  newest N restore points, kept unconditionally
#   BACKUP_KEEP_WEEKLY  (4)  beyond those: newest point per ISO week, N weeks
#   BACKUP_KEEP_MONTHLY (6)  beyond those: newest point per month, N months
# 0 disables a tier; the newest point is never pruned; anything in
# BACKUP_ROOT not matching a restore-point name is never touched.
prune_backups() {
    local broot keepd keepw keepm
    broot=$(env_get BACKUP_ROOT)
    keepd=$(env_get BACKUP_KEEP_DAILY 7)
    keepw=$(env_get BACKUP_KEEP_WEEKLY 4)
    keepm=$(env_get BACKUP_KEEP_MONTHLY 6)
    local -a all
    mapfile -t all < <(ls -1 "$broot" 2>/dev/null | grep -E '^[0-9]{8}-[0-9]{6}$' | sort -r)
    (( ${#all[@]} )) || return 0
    local -A keepset seenw seenm
    local p d wk mo i=0 pruned=0 nw=0 nm=0
    for p in "${all[@]}"; do
        d=${p:0:8}
        if (( i < keepd )) || (( i == 0 )); then keepset[$p]=1; i=$((i+1)); continue; fi
        i=$((i+1))
        wk=$(date -d "$d" +%G-%V 2>/dev/null) || { keepset[$p]=1; continue; }
        mo=${d:0:6}
        if [[ -z "${seenw[$wk]:-}" ]] && (( nw < keepw )); then
            seenw[$wk]=1; nw=$((nw+1)); keepset[$p]=1; continue
        fi
        seenw[$wk]=1
        if [[ -z "${seenm[$mo]:-}" ]] && (( nm < keepm )); then
            seenm[$mo]=1; nm=$((nm+1)); keepset[$p]=1; continue
        fi
        seenm[$mo]=1
    done
    for p in "${all[@]}"; do
        [[ -n "${keepset[$p]:-}" ]] && continue
        info "Pruning restore point $p (older than the retention policy keeps)"
        sudo rm -rf "${broot:?}/$p"; pruned=$((pruned+1))
    done
    ok "restore points: kept $(( ${#all[@]} - pruned )), pruned $pruned — policy: the last $keepd backups, plus one per week for $keepw weeks, plus one per month for $keepm months (change via BACKUP_KEEP_* in .env)"
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
        notify ops "Mediastack update FAILED" "Unhealthy after update: ${bad[*]} — roll back with: ./mediastack.sh rollback <service>" failure
        exit 1
    fi
    ok "All updated services healthy."
    (( ${#changed[@]} )) && notify ops "Mediastack updated" "$(printf '%s; ' "${changed[@]}")" success

    # nightly TRaSH sync rides the update pipeline: same schedule the
    # operator already chose, guides drift-window stays at one cycle.
    if grep -q "^TRASH_PROFILE_" .env 2>/dev/null; then
        # pinned-major drift notice: the recyclarr pin (":8") is deliberate,
        # but a released v9 should be a visible decision, not silence
        local rc_pin rc_latest
        rc_pin=$(grep -oE 'recyclarr/recyclarr:[0-9]+' compose.d/recyclarr.yml 2>/dev/null | cut -d: -f2)
        rc_latest=$(curl -sf -m 10 https://github.com/recyclarr/recyclarr/releases.atom 2>/dev/null \
                    | grep -oE '<title>v[0-9]+' | head -1 | grep -oE '[0-9]+')
        if [[ -n "$rc_pin" && -n "$rc_latest" ]] && (( rc_latest > rc_pin )); then
            warn "recyclarr v$rc_latest is out; the stack pins major v$rc_pin — review the breaking changes, then bump the tag in compose.d/recyclarr.yml when ready"
            notify ops "recyclarr v$rc_latest available" "Stack pins major v$rc_pin. Review upstream breaking changes, then bump compose.d/recyclarr.yml." warning
        fi
        echo
        cmd_trash_sync || { fail "update pipeline: trash-sync step failed (updates themselves succeeded — see FAIL lines above)"
                            notify ops "Mediastack trash-sync FAILED" "Nightly TRaSH sync failed — updates themselves succeeded. Inspect: ./mediastack.sh trash-sync" failure
                            exit 1; }
    fi
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
    load_env; need_cmd jq; render
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
    local pending=()
    local -A rc0=()
    for s in $(svc_managed); do
        cn=$(svc_cname "$s"); st=$(c_state "$cn"); h=$(c_health "$cn")
        case "$st:$h" in
            running:healthy|running:-) ok "$s ($st${h:+, $h})" ;;
            running:starting) pending+=("$s"); rc0[$s]=$(c_restarts "$cn") ;;   # verdict deferred
            absent:*) if svc_enabled "$s"; then
                          d_fail "$s enabled but not running" "container was never created or was removed" "./mediastack.sh up"
                      else info "$s not enabled — skipped"; fi ;;
            *) d_fail "$s is $st/$h (restarts: $(c_restarts "$cn"))" "service is not serving" "./mediastack.sh logs $s   (then: rollback $s if a recent update broke it)" ;;
        esac
    done
    if (( ${#pending[@]} )); then
        info "${#pending[@]} service(s) in their startup window — waiting (up to 90s, shared)..."
        local deadline=$(( $(date +%s) + 90 )) rc_now still
        while (( ${#pending[@]} )) && (( $(date +%s) < deadline )); do
            sleep 5
            still=()
            for s in "${pending[@]}"; do
                cn=$(svc_cname "$s"); st=$(c_state "$cn"); h=$(c_health "$cn")
                rc_now=$(c_restarts "$cn")
                if (( rc_now > ${rc0[$s]} )) || [[ "$st" == restarting ]]; then
                    d_fail "$s is boot-looping (restarted $rc_now times)" "it starts, crashes, and restarts — it will never become healthy" "./mediastack.sh logs $s"
                elif [[ "$h" == healthy ]]; then ok "$s (running, healthy — came up during the wait)"
                elif [[ "$h" == starting ]]; then still+=("$s")
                elif [[ "$st" == running && "$h" == "-" ]]; then ok "$s (running)"
                else d_fail "$s is $st/$h" "service failed its startup" "./mediastack.sh logs $s"
                fi
            done
            pending=("${still[@]}")
        done
        for s in "${pending[@]}"; do
            d_fail "$s still not healthy after 90s (health: $(c_health "$(svc_cname "$s")"))" "startup is taking abnormally long or the healthcheck cannot pass" "./mediastack.sh logs $s"
        done
    fi

    hr "doctor: permissions"
    local croot uid v bad
    croot=$(env_get CONFIG_ROOT)
    for s in $(svc_managed); do
        [[ $(svc_label "$s" mediastack.config) == "true" ]] || continue
        v="$(uvar "$s")_UID"; uid=$(env_get "$v"); [[ -n "$uid" && -d "$croot/$s" ]] || continue
        bad=$(sudo find "$croot/$s" \( -not -user "$uid" -o -not -group "$(env_get MEDIA_GROUP_GID)" \) 2>/dev/null | head -3 || true)
        if [[ -n "$bad" ]]; then
            d_fail "$s: files not owned $uid:mediacenter" "the app cannot write its own config" "./mediastack.sh fix-perms $s"
        else
            # Probe from INSIDE the container: bind mounts don't traverse the
            # host path, so host-side probes false-alarm on 0700 parent dirs.
            local cn dest out rc
            cn=$(svc_cname "$s")
            if [[ $(c_state "$cn") == running ]]; then
                dest=$(sudo docker inspect "$cn" 2>/dev/null \
                       | jq -r --arg src "$croot/$s" '.[0].Mounts[]? | select(.Source==$src) | .Destination' | head -1)
                if [[ -n "$dest" ]]; then
                    out=$(sudo docker exec "$cn" test -w "$dest" 2>&1) && rc=0 || rc=$?
                    if (( rc == 0 )); then ok "$s config writable from inside the container"
                    elif grep -q "executable file not found" <<<"$out"; then
                        info "$s: image has no probe tooling — ownership check only"
                    else
                        d_fail "$s cannot write $dest from inside its container" "the app cannot persist settings" "./mediastack.sh fix-perms $s && ./mediastack.sh logs $s"
                    fi
                else info "$s: config not bind-mounted in running container — skipped"; fi
            else ok "$s config ownership (write probe skipped: not running)"; fi
        fi
    done
    # jellysearch must READ jellyfin's config
    if svc_enabled jellysearch; then
        local jcn jout jrc
        jcn=$(svc_cname jellysearch)
        if [[ $(c_state "$jcn") == running ]]; then
            jout=$(sudo docker exec "$jcn" test -r /config 2>&1) && jrc=0 || jrc=$?
            if (( jrc == 0 )); then ok "jellysearch can read jellyfin's config"
            elif grep -q "executable file not found" <<<"$jout"; then
                info "jellysearch: image has no probe tooling — skipped"
            else d_fail "jellysearch cannot read /config inside its container" "search cannot index" "./mediastack.sh fix-perms jellyfin"; fi
        else info "jellysearch not running — read probe skipped"; fi
    fi
    # artifact sweep
    [[ $(sudo find "$(env_get DATA_ROOT)" -maxdepth 2 -name '*{*}*' 2>/dev/null | wc -l) -gt 0 ]] \
        && warn "literal '{...}' directories under DATA_ROOT — junk from an old installer; safe to remove"
    [[ $(sudo find "$croot" -maxdepth 1 -name '*.pre-restore.*' 2>/dev/null | wc -l) -gt 0 ]] \
        && warn "old *.pre-restore.* trees under CONFIG_ROOT — remove once you trust the restore"

    hr "doctor: host resources"
    df -h "$croot" "$(env_get DATA_ROOT)" 2>/dev/null | tail -n +2 | sort -u | while read -r line; do
        local pct; pct=$(awk '{print $5}' <<<"$line" | tr -d %)
        (( pct >= 90 )) && warn "disk >90%: $line" || ok "disk: $line"
    done
    local memfree l1 l5 l15 cores
    memfree=$(awk '/MemAvailable/{printf "%.1f", $2/1048576}' /proc/meminfo)
    read -r l1 l5 l15 _ < /proc/loadavg; cores=$(nproc)
    awk -v m="$memfree" 'BEGIN{exit !(m<1)}' && warn "available RAM low: ${memfree}G" || ok "available RAM: ${memfree}G"
    # Judge on the 5-min average: the 1-min figure spikes on every cold start
    # (container init is IO-heavy and Linux load counts IO-wait) and would
    # cry wolf exactly when people run doctor. Sustained 5-min > cores is
    # the real "this host is too small" signal.
    if awk -v l="$l5" -v c="$cores" 'BEGIN{exit !(l>c)}'; then
        warn "sustained load high: $l1 / $l5 / $l15 (1/5/15min) on $cores cores"
    else
        ok "load $l1 / $l5 / $l15 (1/5/15min) on $cores cores"
    fi

    hr "doctor: docker storage"
    local dtype dtot dact dsize drecl dpct
    while IFS='|' read -r dtype dtot dact dsize drecl; do
        case "$dtype" in
            Images)
                ok "images: $dtot on disk ($dsize), $dact in use by this host's containers"
                dpct=$(grep -oP '\(\K[0-9]+(?=%\))' <<<"$drecl" || echo 0)
                if (( dpct >= 30 )); then
                    info "  $drecl of image data is unused — reclaim with: sudo docker image prune -a  (keeps anything in use)"
                fi ;;
            Containers)
                if (( dtot > dact )); then
                    warn "stopped containers lingering: $(( dtot - dact )) — list with: sudo docker ps -a --filter status=exited"
                else
                    ok "containers: $dact running, none stopped/exited"
                fi ;;
            "Build Cache")
                [[ "$dsize" != "0B" ]] && info "build cache: $dsize — this stack builds nothing; reclaim with: sudo docker builder prune" ;;
        esac
    done < <(sudo docker system df --format '{{.Type}}|{{.TotalCount}}|{{.Active}}|{{.Size}}|{{.Reclaimable}}' 2>/dev/null)
    local dang
    dang=$(sudo docker volume ls -qf dangling=true 2>/dev/null | wc -l)
    if (( dang > 0 )); then
        info "orphaned anonymous volumes: $dang — empty leftovers from container recreates (all real state is bind-mounted). Clean: sudo docker volume prune -f"
    else
        ok "no orphaned volumes"
    fi

    hr "doctor: host neighbours"
    sudo docker ps --format '{{.Names}} {{.Image}}' | grep -Ei 'watchtower|ouroboros|autoheal' | grep -v mediastack \
        && warn "foreign auto-updater found on this host — it may update mediastack containers behind the backup system's back (our labels tell watchtower no; verify it honours them)" \
        || ok "no foreign auto-updaters"
    # docker subnet vs host routes overlap
    local net
    while read -r net; do
        [[ -z "$net" ]] && continue
        ip route | grep -vE 'dev (docker0|br-)' | grep -v "^default" | grep -q "^${net%.*}" \
            && warn "docker subnet $net overlaps a host route — containers may fail to reach the LAN/NAS. Fix: 'default-address-pools' in /etc/docker/daemon.json (restarts ALL containers on this host — do it in a window)."
    done < <(sudo docker network ls -q | xargs -r sudo docker network inspect \
             --format '{{range .IPAM.Config}}{{.Subnet}}{{println}}{{end}}' 2>/dev/null \
             | grep -oE '^[0-9.]+' || true)

    hr "doctor: vpn + backups"
    if [[ "$(c_state "$(svc_cname gluetun)")" == running ]]; then
        local dgid dnm dbad="" dchecked=0
        dgid=$(sudo docker inspect --format '{{.Id}}' "$(svc_cname gluetun)" | tr -d '\n')
        for s in $(svc_managed); do
            [[ $(svc_label "$s" mediastack.vpn) == "true" ]] || continue
            svc_enabled "$s" || continue
            [[ $(c_state "$(svc_cname "$s")") == running ]] || continue
            dnm=$(sudo docker inspect --format '{{.HostConfig.NetworkMode}}' "$(svc_cname "$s")" | tr -d '\n')
            dchecked=1
            [[ "$dnm" == "container:$dgid" ]] || dbad+="$s "
        done
        if (( dchecked == 0 )); then info "no running VPN'd services to audit"
        elif [[ -z "$dbad" ]]; then ok "all VPN'd services attached to gluetun's namespace"
        else d_fail "VPN'd services NOT attached to gluetun: $dbad" "their traffic bypasses the VPN entirely" "./mediastack.sh up   (recreates with correct attachment), then ./mediastack.sh leak-test"; fi
    fi
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
    if grep -q "^TRASH_PROFILE_" .env 2>/dev/null; then
        if [[ -s cache/trash-last-sync ]]; then
            local tage=$(( ( $(date +%s) - $(cat cache/trash-last-sync) ) / 3600 ))
            local tsum=""
            [[ -s cache/trash-last-summary ]] && tsum=" — last run: $(cat cache/trash-last-summary)"
            (( tage > 26 )) && warn "TRaSH sync is ${tage}h old — run: ./mediastack.sh trash-sync" \
                            || ok "TRaSH sync ${tage}h old${tsum}"
        else
            warn "TRaSH configured but never synced — run: ./mediastack.sh trash-sync"
        fi
    fi
    if svc_enabled traefik && [[ -n "$(env_get TRAEFIK_DOMAIN)" ]]; then
        local acmef="$(env_get CONFIG_ROOT)/traefik/acme/acme.json"
        if sudo test -s "$acmef"; then
            [[ "$(sudo stat -c %a "$acmef")" == 600 ]] && ok "acme.json permissions 600" \
                || warn "acme.json is NOT mode 600 — traefik will refuse it; fix: sudo chmod 600 $acmef"
            if sudo grep -q "acme-staging" "$acmef"; then
                warn "STAGING certificates active — browsers will warn. For real use: set ACME_ENV=production in .env, then ./mediastack.sh up"
            else
                ok "production certificates in the store"
            fi
            sudo grep -q "\*.$(env_get TRAEFIK_DOMAIN)" "$acmef" \
                && ok "wildcard certificate present for *.$(env_get TRAEFIK_DOMAIN)" \
                || warn "no wildcard certificate for *.$(env_get TRAEFIK_DOMAIN) yet — check: logs traefik"
        else
            warn "traefik configured but no certificates issued yet — check: logs traefik"
        fi
    fi

    hr "doctor: apps"
    if svc_enabled jellyfin && [[ "$(c_state "$(svc_cname jellyfin)")" == running ]]; then
        local jpub
        jpub=$(curl -s -m 10 "http://127.0.0.1:$(svc_label jellyfin mediastack.port)/System/Info/Public" 2>/dev/null || true)
        case "$(jq -r '.StartupWizardCompleted' <<<"$jpub" 2>/dev/null)" in
            true)  ok "jellyfin first-run wizard completed" ;;
            false) d_fail "jellyfin first-run wizard NOT completed" "an unclaimed jellyfin lets any visitor create the admin account" "./mediastack.sh wire jellyfin" ;;
            *)     warn "jellyfin public info unreadable — API may still be warming up" ;;
        esac
    fi
    if svc_enabled seerr && [[ "$(c_state "$(svc_cname seerr)")" == running ]]; then
        local spub
        spub=$(curl -s -m 10 "http://127.0.0.1:$(svc_label seerr mediastack.port)/api/v1/settings/public" 2>/dev/null || true)
        case "$(jq -r '.initialized' <<<"$spub" 2>/dev/null)" in
            true)  ok "seerr initialised" ;;
            false) warn "seerr not initialised yet — run: ./mediastack.sh wire seerr" ;;
            *)     warn "seerr public settings unreadable — API may still be warming up" ;;
        esac
    fi
    if svc_enabled wizarr && [[ "$(c_state "$(svc_cname wizarr)")" == running ]]; then
        local wkey wcode
        wkey=$(env_get WIZARR_API_KEY)
        if [[ -z "$wkey" ]]; then
            warn "wizarr has no stored API key — invites need it: ./mediastack.sh wire wizarr"
        else
            wcode=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -H "X-API-Key: $wkey" \
                    "http://127.0.0.1:$(svc_label wizarr mediastack.port)/api/invitations" 2>/dev/null || echo 000)
            [[ "$wcode" =~ ^2 ]] && ok "wizarr API key works ('invite' is ready)" \
                || d_fail "wizarr rejected the stored API key [HTTP $wcode]" "'invite' cannot mint links" "recreate the key in wizarr's Settings -> API Keys, then: ./mediastack.sh wire wizarr"
        fi
    fi

    hr "doctor: runtime audit"
    # per-service error volume, last 24h — noisy logs surface real problems
    local noisy=0 cnt
    for s in $(svc_managed); do
        svc_enabled "$s" || continue
        cn=$(svc_cname "$s")
        [[ "$(c_state "$cn")" == running ]] || continue
        cnt=$(sudo docker logs --since 24h "$cn" 2>&1 | grep -ciE '\b(error|fatal)\b' || true)
        if (( cnt > 25 )); then
            warn "$s: $cnt error lines in 24h — inspect: ./mediastack.sh logs $s"
            noisy=$((noisy+1))
        fi
    done
    (( noisy == 0 )) && ok "log noise: every service under the error threshold (25/24h)"
    # effective UID: the process must actually run as the UID .env assigns —
    # PUID images silently ignore bad values, this catches that
    local expect uids drift=0
    for s in $(svc_managed); do
        svc_enabled "$s" || continue
        cn=$(svc_cname "$s")
        [[ "$(c_state "$cn")" == running ]] || continue
        expect=$(env_get "$(uvar "$s")_UID")
        [[ -n "$expect" ]] || continue
        uids=$(sudo docker top "$cn" -eo uid= 2>/dev/null | sort -u | tr -d ' ' | tr '\n' ' ')
        if [[ " $uids" == *" $expect "* ]]; then :; else
            warn "$s: no process runs as UID $expect (saw: ${uids:-none}) — PUID may be ignored; check: logs $s"
            drift=$((drift+1))
        fi
    done
    (( drift == 0 )) && ok "effective UIDs match the .env map"
    # qbit must be bound to the tunnel interface (wire sets it; verify here)
    if svc_enabled qbittorrent && [[ "$(c_state "$(svc_cname qbittorrent)")" == running ]]; then
        if qb_login "$(env_get QBITTORRENT_USER)" "$(env_get QBITTORRENT_PASSWORD)" 2>/dev/null; then
            local iface
            iface=$(qb_api /app/preferences | jq -r '.current_network_interface // .network_interface // empty' 2>/dev/null)
            [[ "$iface" == tun0 ]] && ok "qBittorrent transfers bound to tun0" \
                || warn "qBittorrent is NOT bound to tun0 (currently: '${iface:-unset}') — fix: ./mediastack.sh wire qbit"
        else
            warn "could not sign in to qBittorrent to verify the tun0 bind"
        fi
    fi

    echo
    if (( D_FAILS )); then
        fail "doctor: $D_FAILS problem(s) — fixes listed above."
        notify ops "Mediastack doctor: $D_FAILS problem(s)" "Run ./mediastack.sh doctor on the host for the findings and fixes." failure
        exit 1
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
    # Netns-joined containers report an EMPTY SandboxKey, so key equality can
    # never verify the join. The truth is NetworkMode: docker enforces
    # container:<id> joins atomically — matching gluetun's full ID is proof.
    local gid rc=0 s cn nm
    gid=$(sudo docker inspect --format '{{.Id}}' "$gcn" | tr -d '\n')
    for s in $(svc_managed); do
        [[ $(svc_label "$s" mediastack.vpn) == "true" ]] || continue
        svc_enabled "$s" || continue
        cn=$(svc_cname "$s"); [[ "$(c_state "$cn")" == running ]] || { info "$s not running — skipped"; continue; }
        nm=$(sudo docker inspect --format '{{.HostConfig.NetworkMode}}' "$cn" | tr -d '\n')
        if [[ "$nm" == "container:$gid" ]]; then ok "$s runs inside gluetun's namespace"
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
        sudo docker stop "$gcn" >/dev/null
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
        sudo docker start "$gcn" >/dev/null
        local t=0; while [[ $(c_health "$gcn") != healthy && $t -lt 90 ]]; do sleep 3; t=$((t+3)); done
        local rs
        for rs in $(svc_managed); do
            [[ $(svc_label "$rs" mediastack.vpn) == "true" ]] || continue
            svc_enabled "$rs" || continue
            sudo docker restart "$(svc_cname "$rs")" >/dev/null && info "  rejoined: $rs"
        done
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
    echo "         .env, this repo folder, and pulled docker images (shared"
    echo "         cache — 'docker image prune -a' reclaims them)."
    echo "Running containers are stopped and removed by this command — no"
    echo "need to stop anything first. (Just never skip this and rm -rf the"
    echo "folder instead: running containers resurrect their mount dirs.)"
    local really; read -r -p "Type 'nuke mediastack' to proceed: " really
    [[ "$really" == "nuke mediastack" ]] || { info "Aborted — nothing touched."; return 1; }

    sudo systemctl disable --now mediastack-update.timer 2>/dev/null || true
    sudo rm -f /etc/systemd/system/mediastack-update.service /etc/systemd/system/mediastack-update.timer
    sudo systemctl daemon-reload
    ok "systemd units removed"
    sudo docker ps -aq --filter "label=com.docker.compose.project=mediastack" \
        | xargs -r sudo docker rm -f -v >/dev/null
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


# ================================================================= wire ====
# Idempotent app-to-app configuration: read live state, compare intent
# (labels + .env), apply only the delta. Safe to re-run forever.
WIRE_DRY=0
WIRE_CHANGES=0
WIRE_FAILS=0
wfail() { fail "$@"; WIRE_FAILS=$((WIRE_FAILS+1)); }

w_would() { # w_would "description" -> 0 if execution should proceed
    WIRE_CHANGES=$((WIRE_CHANGES+1))
    if (( WIRE_DRY )); then echo "  would: $1"; return 1; fi
    info "$1"
}

api() { # api METHOD URL APIKEY [json-body] -> body on stdout, rc from http
    local m="$1" u="$2" k="$3" b="${4:-}" out code
    out=$(curl -sS -m 20 -X "$m" -H "X-Api-Key: $k" -H "Content-Type: application/json" \
          ${b:+-d "$b"} -w '\n%{http_code}' "$u" 2>&1) || { echo "$out"; return 1; }
    code=${out##*$'\n'}; echo "${out%$'\n'*}"
    [[ "$code" =~ ^2 ]]
}

arr_key() { # arr_key <svc> -> api key from its config.xml ("" while initialising)
    sudo grep -oP '<ApiKey>\K[^<]+' "$(env_get CONFIG_ROOT)/$1/config.xml" 2>/dev/null | head -1 || true
}

arr_url() { echo "http://127.0.0.1:$(svc_label "$1" mediastack.port)"; }
arr_apiver() { # prowlarr and lidarr speak v1; the content arrs are v3
    [[ "$1" == prowlarr ]] && { echo v1; return; }
    case "$(svc_label "$1" mediastack.arrtype)" in lidarr) echo v1 ;; *) echo v3 ;; esac
}

arr_forms_login() { # shared operator login on an arr-family UI; idempotent
    local s="$1" auser apass key url cur verb=enable
    [[ "${2:-}" == force ]] && verb=rotate
    auser=$(env_get ARR_USER); apass=$(env_get ARR_PASSWORD)
    [[ -n "$auser" && -n "$apass" ]] || { info "$s: shared arr login not set yet — 'wire arr' creates it"; return 0; }
    key=$(arr_key "$s"); [[ -n "$key" ]] || return 0
    url=$(arr_url "$s")
    cur=$(api GET "$url/api/$(arr_apiver "$s")/config/host" "$key" || true)
    if [[ "${2:-}" != force ]] && jq -e --arg u "$auser" '.authenticationMethod=="forms" and .username==$u' <<<"$cur" >/dev/null 2>&1; then
        ok "$s: forms login already set for '$auser'"
    elif w_would "$s: $verb forms login for '$auser'"; then
        api PUT "$url/api/$(arr_apiver "$s")/config/host" "$key" "$(jq -c --arg u "$auser" --arg p "$apass" \
            '.authenticationMethod="forms" | .authenticationRequired="enabled"
             | .username=$u | .password=$p | .passwordConfirmation=$p' <<<"$cur")" >/dev/null \
            && ok "$s: forms login enabled" \
            || wfail "$s: auth setup rejected by the API — set it once in its UI; check: logs $s"
    fi
}

wire_gate() { # refuse to wire what isn't up
    local s missing=""
    for s in "$@"; do
        svc_enabled "$s" || continue
        [[ "$(c_state "$(svc_cname "$s")")" == running ]] || missing+="$s "
    done
    [[ -z "$missing" ]] || die "Cannot wire: not running: $missing
  Start the stack first: ./mediastack.sh up   (then wait for healthy: status)"
}

# shellcheck disable=SC2120  # type argument is optional by design
arr_instances() { # arr_instances [type] -> enabled arr services (optionally by type)
    local s t
    for s in $(svc_managed); do
        svc_enabled "$s" || continue
        t=$(svc_label "$s" mediastack.arrtype)
        [[ -n "$t" ]] || continue
        [[ -z "${1:-}" || "$t" == "$1" ]] && echo "$s"
    done
}

# ---- qbit ----
QB_COOKIE=""
QB_LOGIN_BODY=""
qb_bind_tun0() { # requires QB_COOKIE
    [[ -n "$QB_COOKIE" ]] || { info "no qBittorrent session — interface bind skipped"; return 0; }
    local cur
    cur=$(qb_api /app/preferences | jq -r '.current_network_interface // .network_interface // empty' 2>/dev/null)
    if [[ "$cur" == tun0 ]]; then
        ok "transfers bound to tun0"
    elif w_would "bind qBittorrent's transfers to tun0 (VPN interface)"; then
        qb_api /app/setPreferences 'json={"network_interface":"tun0"}' >/dev/null
        cur=$(qb_api /app/preferences | jq -r '.current_network_interface // .network_interface // empty' 2>/dev/null)
        [[ "$cur" == tun0 ]] && ok "transfers bound to tun0" \
            || wfail "interface bind did not stick (reads back '$cur') — set it in the UI: Advanced -> Network interface"
    fi
}

qb_login() { # rc: 0 = logged in (QB_COOKIE set), 1 = credentials rejected, 2 = unreachable
             # QB_LOGIN_BODY always carries the server's reply / curl error
    local r
    local jar r code
    jar=$(mktemp)
    if ! r=$(curl -sS -m 10 -c "$jar" -w $'\n%{http_code}' \
        --data-urlencode "username=$1" --data-urlencode "password=$2" \
        "http://127.0.0.1:$(svc_label qbittorrent mediastack.port)/api/v2/auth/login" 2>&1); then
        QB_LOGIN_BODY="unreachable: ${r:-<no detail>}"
        rm -f "$jar"; return 2
    fi
    code=${r##*$'\n'}
    QB_LOGIN_BODY="[HTTP ${code}] ${r%%$'\n'*}"; [[ "$QB_LOGIN_BODY" == "[HTTP ${code}] ${code}" ]] && QB_LOGIN_BODY="[HTTP ${code}] <empty body>"
    # qBittorrent >= 5.2 returns 204 on success and names the cookie
    # QBT_SID_<port>; older versions use 200 + "SID". Take name AND value
    # from the jar so we send back exactly what was issued.
    QB_COOKIE=$(awk -F'\t' '$6 ~ /(^|_)SID(_|$)|^SID$/ {print $6"="$7}' "$jar" 2>/dev/null | tail -1 || true)
    rm -f "$jar"
    [[ -n "$QB_COOKIE" ]] || return 1
}
qb_api() { # qb_api PATH [data...] (form-encoded)
    local p="$1"; shift
    local args=(); local a; for a in "$@"; do args+=(--data-urlencode "$a"); done
    curl -sS -m 20 -b "$QB_COOKIE" "${args[@]}" \
        "http://127.0.0.1:$(svc_label qbittorrent mediastack.port)/api/v2$p"
}

wire_qbit() {
    hr "wire: qBittorrent"
    wire_gate qbittorrent
    # auth-free settle: any HTTP status proves the listener (000 = no socket);
    # avoids misreading a boot gap as bad credentials on re-runs
    local qt=0
    while [[ "$(curl -s -m 3 -o /dev/null -w '%{http_code}' \
             "http://127.0.0.1:$(svc_label qbittorrent mediastack.port)/api/v2/app/webapiVersion" 2>/dev/null || echo 000)" == 000 ]]; do
        (( qt >= 45 )) && die "qBittorrent's WebUI never started listening — inspect: ./mediastack.sh logs qbittorrent"
        sleep 3; qt=$((qt+3)); info "qBittorrent WebUI not accepting connections yet (${qt}s)..."
    done
    local user pass gen
    user=$(env_get QBITTORRENT_USER)
    pass=$(env_get QBITTORRENT_PASSWORD)
    if [[ -n "$user" && -n "$pass" ]] && qb_login "$user" "$pass"; then
        ok "credentials from .env work"
    elif (( WIRE_DRY )); then
        w_would "harvest qBittorrent's boot password and set permanent credentials (you pick or accept generated)" || true
        info "category preview needs credentials — computed on the real run"
        return 0
    else
        # No stored credentials: don't forensically read old boots' logs —
        # restart qBittorrent ourselves and watch for the password THIS
        # restart mints. Deterministic: our restart, our time window.
        local tmp="" t=0 qcn ts
        qcn=$(svc_cname qbittorrent)
        info "restarting qBittorrent to mint a fresh temporary password (~20s)..."
        ts=$(date +%s)
        sudo docker restart "$qcn" >/dev/null
        while [[ -z "$tmp" && $t -lt 90 ]]; do
            sleep 5; t=$((t+5))
            # relative window covering everything since our restart
            tmp=$(sudo docker logs --since "$(( $(date +%s) - ts + 2 ))s" "$qcn" 2>&1 \
                  | grep -oP 'temporary password .*: \K\S+' | tail -1 || true)
            [[ -n "$tmp" ]] || info "waiting for qBittorrent to boot (${t}s)..."
        done
        [[ -n "$tmp" ]] || die "qBittorrent printed no temporary password within 90s of a fresh
  restart. Either it already has a password set that isn't in .env
  (set QBITTORRENT_USER/QBITTORRENT_PASSWORD there and re-run), or it
  is failing to boot: ./mediastack.sh logs qbittorrent"
        # the password prints BEFORE the WebUI is fully ready: during warmup
        # it can be unreachable (rc2) OR answer with empty non-auth replies
        # (rc1, empty body). Retry BOTH through the window, evidence inline —
        # a real "Fails." repeated to window-end is still a clean diagnosis.
        local lrc=2 lt=0
        while (( lt < 45 )); do
            if qb_login admin "$tmp"; then lrc=0; break; else lrc=$?; fi
            info "login attempt at ${lt}s: rc=$lrc, server said: $QB_LOGIN_BODY"
            sleep 3; lt=$((lt+3))
        done
        case $lrc in
            0) ok "logged in with the freshly minted password" ;;
            2) die "qBittorrent's WebUI never became reachable on port $(svc_label qbittorrent mediastack.port) within 45s.
  Last state: $QB_LOGIN_BODY
  Inspect: ./mediastack.sh logs qbittorrent" ;;
            *) die "qBittorrent rejected the password it just printed — genuinely unexpected
  (restart clears auth bans, so that isn't it). Server said: $QB_LOGIN_BODY
  Inspect: ./mediastack.sh logs qbittorrent" ;;
        esac
        gen=$(head -c12 /dev/urandom | base64 | tr -d '=+/')
        explain "qBittorrent credentials" \
"Pick the permanent WebUI login. Enter accepts a generated password;
type your own to use it instead. Stored in .env (view: credentials)."
        ask QB_USER "Username" "${user:-admin}"; user="$REPLY_VAL"
        ask_secret "Password" "$gen"; pass="$REPLY_VAL"
        if w_would "set permanent qBittorrent credentials"; then
            qb_api /app/setPreferences \
                "json={\"web_ui_username\":\"$user\",\"web_ui_password\":\"$pass\"}" >/dev/null
            env_set QBITTORRENT_USER "$user"; env_set QBITTORRENT_PASSWORD "$pass"
            sleep 2   # let the preference write settle
            local vrc=0; qb_login "$user" "$pass" || vrc=$?
            (( vrc == 0 )) \
                || die "qBittorrent did not accept the new credentials (rc=$vrc). Server said: $QB_LOGIN_BODY — inspect: logs qbittorrent"
            ok "permanent credentials set and verified"
        fi
    fi
    # bind transfers to the tunnel interface: belt on top of the killswitch —
    # even a firewall wipe inside gluetun cannot make qbit talk past tun0
    qb_bind_tun0
    # categories: one per arr instance, distinct save paths = hardlink discipline
    [[ -n "$QB_COOKIE" ]] || { info "no qBittorrent session — categories skipped"; return 0; }
    local existing s cat
    existing=$(qb_api /torrents/categories || true)
    for s in $(arr_instances); do
        cat=$(svc_label "$s" mediastack.category)
        if grep -q "\"$cat\"" <<<"$existing"; then
            ok "category '$cat' exists"
        elif w_would "create category '$cat' -> /data/torrent/$cat"; then
            qb_api /torrents/createCategory "category=$cat" "savePath=/data/torrent/$cat" >/dev/null \
                && ok "category '$cat' created" \
                || { wfail "category '$cat' creation failed"; }
        fi
    done
}

# ---- arr root folders + download client ----
wire_arr() {
    hr "wire: arr instances (root folders + download client)"
    local insts; insts=$(arr_instances)
    [[ -n "$insts" ]] || { info "no arr instances enabled"; return 0; }
    wire_gate $insts
    # --- arr login (the first-run "authentication required" gate) ---
    local auser apass
    auser=$(env_get ARR_USER); apass=$(env_get ARR_PASSWORD)
    if [[ -z "$auser" || -z "$apass" ]]; then
        if (( WIRE_DRY )); then
            w_would "set one shared login on every arr instance (the first-run auth gate)" || true
        else
            explain "Arr login" \
"The arrs refuse to serve their UI until an authentication method and
login are set. One login is used for ALL instances (they share one
operator). Stored in .env (view: credentials)."
            ask ARR_U "Username" "${auser:-admin}"; auser="$REPLY_VAL"
            ask_secret "Password" "$(head -c12 /dev/urandom | base64 | tr -d '=+/')"; apass="$REPLY_VAL"
            env_set ARR_USER "$auser"; env_set ARR_PASSWORD "$apass"
        fi
    fi
    local user pass; user=$(env_get QBITTORRENT_USER); pass=$(env_get QBITTORRENT_PASSWORD)
    if [[ -z "$pass" ]]; then
        if (( WIRE_DRY )); then
            info "download-client previews pend on qBittorrent credentials — they're created earlier in the same real run"
        else
            warn "qBittorrent credentials not set (scoped run?) — download-client wiring skipped; 'wire qbit' or a full 'wire' sets them"
        fi
    fi
    local s key url root t catfield cat cur
    for s in $insts; do
        key=$(arr_key "$s")
        [[ -n "$key" ]] || { wfail "$s: no ApiKey in config.xml yet (still initialising?) — re-run wire in a minute"; continue; }
        url=$(arr_url "$s"); root=$(svc_label "$s" mediastack.rootfolder)
        # authentication (forms login) — idempotent on method+username match
        arr_forms_login "$s"
        # root folder
        t=$(svc_label "$s" mediastack.arrtype)
        cur=$(api GET "$url/api/$(arr_apiver "$s")/rootfolder" "$key" || true)
        if grep -q "\"path\":\"$root\"" <<<"${cur//[[:space:]]/}"; then
            ok "$s: root folder $root registered"
        elif w_would "$s: register root folder $root"; then
            local rbody rresp
            if [[ "$t" == lidarr ]]; then
                # lidarr root folders carry library defaults (unlike sonarr/radarr);
                # profile IDs 1 = the built-in Standard profiles on a fresh install
                rbody="{\"name\":\"Music\",\"path\":\"$root\",\"defaultMetadataProfileId\":1,\"defaultQualityProfileId\":1,\"defaultMonitorOption\":\"all\",\"defaultTags\":[]}"
            else
                rbody="{\"path\":\"$root\"}"
            fi
            if rresp=$(api POST "$url/api/$(arr_apiver "$s")/rootfolder" "$key" "$rbody"); then
                ok "$s: root folder registered"
            else
                wfail "$s: root folder rejected — API said: $(head -c180 <<<"$rresp")"
            fi
        fi
        # download client
        [[ -n "$pass" ]] || continue
        cat=$(svc_label "$s" mediastack.category)
        case "$t" in sonarr) catfield=tvCategory ;; radarr) catfield=movieCategory ;; lidarr) catfield=musicCategory ;; esac
        cur=$(api GET "$url/api/$(arr_apiver "$s")/downloadclient" "$key" || true)
        if grep -q '"qBittorrent (mediastack)"' <<<"$cur"; then
            ok "$s: download client registered"
        elif w_would "$s: register qBittorrent (category $cat)"; then
            api POST "$url/api/$(arr_apiver "$s")/downloadclient" "$key" "$(cat <<JSON
{"enable":true,"protocol":"torrent","priority":1,
 "removeCompletedDownloads":true,"removeFailedDownloads":true,
 "name":"qBittorrent (mediastack)","implementation":"QBittorrent",
 "implementationName":"qBittorrent","configContract":"QBittorrentSettings",
 "fields":[{"name":"host","value":"localhost"},
   {"name":"port","value":$(svc_label qbittorrent mediastack.port)},
   {"name":"useSsl","value":false},
   {"name":"username","value":"$user"},{"name":"password","value":"$pass"},
   {"name":"$catfield","value":"$cat"}]}
JSON
)" >/dev/null && ok "$s: download client registered" \
              || wfail "$s: download client registration failed — API said no; check: logs $s"
        fi
    done
}

# ---- prowlarr: applications + flaresolverr proxy ----
wire_prowlarr() {
    hr "wire: Prowlarr"
    svc_enabled prowlarr || { info "prowlarr not enabled — skipped"; return 0; }
    wire_gate prowlarr
    local pkey purl; pkey=$(arr_key prowlarr); purl=$(arr_url prowlarr)
    [[ -n "$pkey" ]] || { wfail "prowlarr: no ApiKey yet — re-run wire shortly"; return 0; }
    # prowlarr has no arrtype label so wire_arr's loop never sees it: gate here
    arr_forms_login prowlarr
    local s key t impl cur
    cur=$(api GET "$purl/api/v1/applications" "$pkey" || true)
    for s in $(arr_instances); do
        t=$(svc_label "$s" mediastack.arrtype)
        case "$t" in sonarr) impl=Sonarr ;; radarr) impl=Radarr ;; lidarr) impl=Lidarr ;; *) continue ;; esac
        key=$(arr_key "$s") || true
        [[ -n "$key" ]] || { wfail "prowlarr<-$s: $s has no ApiKey yet"; continue; }
        if grep -q "\"$s (mediastack)\"" <<<"$cur"; then
            ok "prowlarr -> $s registered"
        elif w_would "register $s in prowlarr (Full Sync)"; then
            api POST "$purl/api/v1/applications" "$pkey" "$(cat <<JSON
{"name":"$s (mediastack)","syncLevel":"fullSync",
 "implementation":"$impl","configContract":"${impl}Settings",
 "fields":[{"name":"prowlarrUrl","value":"$purl"},
   {"name":"baseUrl","value":"$(arr_url "$s")"},
   {"name":"apiKey","value":"$key"}]}
JSON
)" >/dev/null && ok "prowlarr -> $s registered (Full Sync)" \
              || wfail "prowlarr -> $s failed — check: logs prowlarr"
        fi
    done
    if svc_enabled flaresolverr; then
        # tag 'flared': put it on any indexer that needs FlareSolverr and
        # prowlarr routes that indexer through the proxy. Nothing carries it
        # by default — only Cloudflare-protected indexers should pay the tax.
        local fid
        fid=$(api GET "$purl/api/v1/tag" "$pkey" | jq -r '.[] | select(.label=="flared") | .id' 2>/dev/null | head -1)
        if [[ -n "$fid" ]]; then
            ok "tag 'flared' exists"
        elif w_would "create prowlarr tag 'flared' (attach to indexers needing FlareSolverr)"; then
            fid=$(api POST "$purl/api/v1/tag" "$pkey" '{"label":"flared"}' | jq -r '.id' 2>/dev/null)
            [[ -n "$fid" && "$fid" != null ]] && ok "tag 'flared' created" \
                || { wfail "prowlarr tag 'flared' creation failed — check: logs prowlarr"; fid=""; }
        fi
        cur=$(api GET "$purl/api/v1/indexerproxy" "$pkey" || true)
        if grep -q '"FlareSolverr (mediastack)"' <<<"$cur"; then
            if [[ -n "$fid" ]] && jq -e --argjson id "$fid" \
                    '.[] | select(.name=="FlareSolverr (mediastack)") | .tags | index($id) | not' \
                    <<<"$cur" >/dev/null 2>&1; then
                if w_would "attach tag 'flared' to the FlareSolverr proxy"; then
                    local fbody
                    fbody=$(jq -c --argjson id "$fid" \
                        '[.[] | select(.name=="FlareSolverr (mediastack)")][0] | .tags += [$id]' <<<"$cur")
                    api PUT "$purl/api/v1/indexerproxy/$(jq -r '.id' <<<"$fbody")" "$pkey" "$fbody" >/dev/null \
                        && ok "flaresolverr proxy tagged 'flared'" \
                        || wfail "could not tag the flaresolverr proxy — check: logs prowlarr"
                fi
            else
                ok "flaresolverr proxy registered"
            fi
        elif w_would "register FlareSolverr as indexer proxy"; then
            api POST "$purl/api/v1/indexerproxy" "$pkey" "$(cat <<JSON
{"name":"FlareSolverr (mediastack)","implementation":"FlareSolverr",
 "configContract":"FlareSolverrSettings","tags":[${fid:-}],
 "fields":[{"name":"host","value":"http://localhost:8191/"},
   {"name":"requestTimeout","value":60}]}
JSON
)" >/dev/null && ok "flaresolverr proxy registered (tag 'flared')" \
              || wfail "flaresolverr proxy registration failed"
        fi
    fi
}

# ---- bazarr ----
wire_bazarr() {
    hr "wire: Bazarr"
    svc_enabled bazarr || { info "bazarr not enabled — skipped"; return 0; }
    wire_gate bazarr
    local bkey burl
    bkey=$(sudo grep -oP 'apikey:\s*\K\S+' "$(env_get CONFIG_ROOT)/bazarr/config/config.yaml" 2>/dev/null | head -1 || true)
    [[ -n "$bkey" ]] || { wfail "bazarr: no api key found yet (config/config.yaml) — re-run wire shortly"; return 0; }
    burl="http://127.0.0.1:$(svc_label bazarr mediastack.port)"
    # readiness gate: on a virgin install bazarr is still migrating its DB when
    # wire reaches it and resets the connection (HTTP 000). Poll before posting.
    if (( ! WIRE_DRY )); then
        local waited=0 bprobe
        until bprobe=$(curl -sS -m 5 -o /dev/null -w '%{http_code}' \
                -H "X-API-KEY: $bkey" "$burl/api/system/status" 2>&1) \
                && [[ "$bprobe" == 200 ]]; do
            if (( waited >= 90 )); then
                wfail "bazarr not ready after ${waited}s (last probe: $(head -c120 <<<"$bprobe")) — re-run wire once it settles; check: logs bazarr"
                return 0
            fi
            (( waited == 0 )) && info "waiting for bazarr to come up (budget 90s)..."
            sleep 3; waited=$((waited+3))
        done
    fi
    local pairs=() t skey
    for t in sonarr radarr; do
        svc_enabled "$t" || continue
        skey=$(arr_key "$t"); [[ -n "$skey" ]] || continue
        pairs+=("$t" "$skey")
    done
    (( ${#pairs[@]} )) || { info "no base sonarr/radarr to pair — skipped"; return 0; }
    if w_would "point bazarr at base sonarr/radarr (extra instances are out of bazarr's scope)"; then
        # auth fields exactly ONCE — duplicate form keys become lists on
        # bazarr's side and fail its type validation
        local form=("settings-auth-type=form"
                    "settings-auth-username=$(env_get ARR_USER)"
                    "settings-auth-password=$(env_get ARR_PASSWORD)") i
        for ((i=0; i<${#pairs[@]}; i+=2)); do
            t=${pairs[i]}; skey=${pairs[i+1]}
            form+=("settings-general-use_${t}=true"
                   "settings-${t}-ip=localhost"
                   "settings-${t}-port=$(svc_label "$t" mediastack.port)"
                   "settings-${t}-base_url=/"
                   "settings-${t}-ssl=false"
                   "settings-${t}-apikey=${skey}")
        done
        local args=() a
        for a in "${form[@]}"; do args+=(--data-urlencode "$a"); done
        local bresp bcode
        bresp=$(curl -sS -m 20 -w $'\n%{http_code}' -X POST -H "X-API-KEY: $bkey" \
                "${args[@]}" "$burl/api/system/settings" 2>&1) || bresp="${bresp}"$'\n000'
        bcode=${bresp##*$'\n'}
        if [[ "$bcode" =~ ^2 ]]; then
            ok "bazarr paired with base sonarr/radarr (+ shared login)"
        else
            wfail "bazarr pairing rejected [HTTP $bcode]: $(head -c200 <<<"${bresp%$'\n'*}")
     pair manually meanwhile (Settings -> Sonarr/Radarr) and paste the above"
        fi
    fi
}

# ---- apprise (wave 5): one notification hub for the whole stack ----
# apprise-api in gluetun's namespace. Tags route messages: ops (pipeline,
# backups, doctor), activity (arr events), users (wizarr invites).
apprise_url() { echo "http://127.0.0.1:$(env_get APPRISE_PORT 8000)"; }

NOTIFY_WARNED=0
notify() { # notify TAG TITLE BODY [TYPE] — never blocks, never fails the caller
    local tag="$1" title="$2" body="$3" type="${4:-info}"
    svc_enabled apprise 2>/dev/null || return 0
    [[ "$(c_state "$(svc_cname apprise)" 2>/dev/null)" == running ]] || return 0
    curl -sS -m 5 -o /dev/null -X POST -H "Content-Type: application/json" \
        -d "$(jq -cn --arg t "$title" --arg b "$body" --arg g "$tag" --arg y "$type" \
             '{title:$t,body:$b,tag:$g,type:$y}')" \
        "$(apprise_url)/notify/mediastack" 2>/dev/null && return 0
    if (( ! NOTIFY_WARNED )); then
        warn "apprise unreachable — notification dropped (stack keeps going; check: ./mediastack.sh logs apprise)"
        NOTIFY_WARNED=1
    fi
    return 0
}

wire_apprise() {
    hr "wire: apprise"
    svc_enabled apprise || { info "apprise not enabled — skipped"; return 0; }
    wire_gate apprise
    local t=0 code
    while :; do
        code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$(apprise_url)/status" 2>/dev/null || echo 000)
        [[ "$code" =~ ^2 ]] && break
        (( t >= 90 )) && { wfail "apprise never became ready within 90s (last: HTTP $code) — inspect: ./mediastack.sh logs apprise"; return 1; }
        sleep 5; t=$((t+5)); info "waiting for apprise (${t}s)..."
    done

    # --- notification endpoints: stored once under key 'mediastack';
    # an existing config is never touched (edit in apprise's UI or re-add)
    code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$(apprise_url)/get/mediastack" 2>/dev/null || echo 000)
    if [[ "$code" == 200 ]]; then
        ok "notification endpoints configured — untouched (yours to manage; UI: http://<this-host>:$(env_get APPRISE_PORT 8000))"
    elif (( WIRE_DRY )); then
        w_would "store notification endpoints (URLs asked per tag on the real run)" || true
    elif [[ ! -t 0 ]]; then
        info "no notification endpoints stored yet — run './mediastack.sh wire apprise' interactively to add them"
    else
        explain "Notifications (Apprise)" \
"One hub, three streams — give each one or more Apprise URLs
(comma-separated), or leave blank to skip a stream:
  ops       update pipeline, backup failures, doctor problems
  activity  arr grabs, imports, health events
  users     invite activity (wizarr)
Getting a URL:
  Discord   channel -> gear -> Integrations -> Webhooks -> New Webhook
            -> Copy Webhook URL, and paste that https://... URL as-is
  ntfy      pick any unique topic name: ntfy://ntfy.sh/your-topic
            (subscribe to the topic in the ntfy app — zero signup)
  anything  else: https://github.com/caronc/apprise/wiki"
        local ops_u act_u usr_u cfg="" u
        ask AP_OPS "URLs for ops" ""; ops_u="$REPLY_VAL"
        ask AP_ACT "URLs for activity" ""; act_u="$REPLY_VAL"
        ask AP_USR "URLs for users" ""; usr_u="$REPLY_VAL"
        for u in ${ops_u//,/ }; do cfg+="ops=$u"$'\n'; done
        for u in ${act_u//,/ }; do cfg+="activity=$u"$'\n'; done
        for u in ${usr_u//,/ }; do cfg+="users=$u"$'\n'; done
        if [[ -z "$cfg" ]]; then
            info "no URLs given — notifications stay off until 'wire apprise' stores some"
        elif w_would "store the notification endpoints under key 'mediastack'"; then
            local resp acode
            resp=$(curl -sS -m 10 -X POST -H "Content-Type: application/json" \
                   -d "$(jq -cn --arg c "$cfg" '{config:$c,format:"text"}')" \
                   -w $'\n%{http_code}' "$(apprise_url)/add/mediastack" 2>&1) \
                || { wfail "apprise unreachable while storing config: $(head -c200 <<<"$resp")"; return 1; }
            acode=${resp##*$'\n'}
            [[ "$acode" =~ ^2 ]] \
                || { wfail "apprise rejected the config [HTTP $acode]: $(head -c200 <<<"${resp%$'\n'*}")
     check the URL syntax against https://github.com/caronc/apprise/wiki"; return 1; }
            ok "notification endpoints stored"
            notify ops "Mediastack" "Notifications are wired up — this is your ops stream." info
            info "a test notification went to the ops stream — check it arrived"
        fi
    fi

    # --- each arr notifies the hub (tag: activity); create-if-missing by
    # name, schema-driven so per-type event flags stay version-proof
    local s ty key url ver have schema tmpl body resp
    for s in $(arr_instances); do
        ty=$(svc_label "$s" mediastack.arrtype)
        [[ "$ty" == sonarr || "$ty" == radarr || "$ty" == lidarr ]] || continue
        key=$(arr_key "$s"); url=$(arr_url "$s"); ver=$(arr_apiver "$s")
        [[ -n "$key" ]] || { wfail "$s: no ApiKey readable — re-run wire in a minute"; continue; }
        have=$(api GET "$url/api/$ver/notification" "$key" | jq -r '[.[].name] | join(" ")' 2>/dev/null)
        if [[ " $have " == *" mediastack-apprise "* ]]; then
            ok "$s already notifies the hub — untouched"
            continue
        fi
        if ! w_would "$s: notify the hub on grab/import/health (tag: activity)"; then continue; fi
        schema=$(api GET "$url/api/$ver/notification/schema" "$key" || true)
        tmpl=$(jq -c '[.[] | select(.implementation=="Apprise")][0] // empty' <<<"$schema" 2>/dev/null)
        [[ -n "$tmpl" ]] || { wfail "$s: its API offers no Apprise notification type — is the image very old?"; continue; }
        body=$(jq -c --arg srv "http://localhost:8000" '
            .name = "mediastack-apprise"
            | .fields = [ .fields[]
                | if .name == "serverUrl"         then .value = $srv
                  elif .name == "configurationKey" then .value = "mediastack"
                  elif .name == "tags"             then .value = ["activity"]
                  else . end ]
            | reduce ("onGrab","onDownload","onUpgrade","onReleaseImport",
                      "onImportComplete","onHealthIssue","onHealthRestored",
                      "onApplicationUpdate") as $k
                (.; if has($k) then .[$k] = true else . end)' <<<"$tmpl")
        resp=$(api POST "$url/api/$ver/notification" "$key" "$body") \
            && ok "$s now notifies the hub" \
            || wfail "$s: notification connection rejected: $(head -c200 <<<"$resp")"
    done
}

# ---- cleanuparr (wave 5) ----
# Bootstrap the account (reusing the stack's arr login), store the API key,
# point it at qBittorrent and every arr, and switch the queue cleaner on
# with its conservative upstream defaults. Existing entries: untouched.
cup_url() { echo "http://127.0.0.1:$(env_get CLEANUPARR_PORT 11011)"; }
CUP_CODE_F="${TMPDIR:-/tmp}/.mediastack-cup-code.$$"
cup_code() { cat "$CUP_CODE_F" 2>/dev/null || echo 000; }
cup_api() { # cup_api METHOD PATH AUTHHDR [json-body] -> body; rc = http 2xx
    local m="$1" p="$2" hdr="$3" b="${4:-}" out code
    if ! out=$(curl -sS -m 20 -X "$m" ${hdr:+-H "$hdr"} -H "Content-Type: application/json" \
          ${b:+-d "$b"} -w $'\n%{http_code}' "$(cup_url)/api$p" 2>&1); then
        printf '000' > "$CUP_CODE_F"; echo "$out"; return 1
    fi
    code=${out##*$'\n'}; printf '%s' "$code" > "$CUP_CODE_F"
    echo "${out%$'\n'*}"
    [[ "$code" =~ ^2 ]]
}

wire_cleanuparr() {
    hr "wire: cleanuparr"
    svc_enabled cleanuparr || { info "cleanuparr not enabled — skipped"; return 0; }
    wire_gate cleanuparr
    local t=0 code
    while :; do
        code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$(cup_url)/health" 2>/dev/null || echo 000)
        [[ "$code" =~ ^2 ]] && break
        (( t >= 90 )) && { wfail "cleanuparr never became ready within 90s (last: HTTP $code) — inspect: ./mediastack.sh logs cleanuparr"; return 1; }
        sleep 5; t=$((t+5)); info "waiting for cleanuparr (${t}s)..."
    done

    local user pass st out
    user=$(env_get ARR_USER); pass=$(env_get ARR_PASSWORD)
    [[ -n "$user" && -n "$pass" ]] || { wfail "cleanuparr bootstrap reuses the arr login — run 'wire arr' first (a full 'wire' does both in order)"; return 1; }

    st=$(cup_api GET /auth/status "" || true)
    if [[ "$(jq -r '.setupCompleted' <<<"$st" 2>/dev/null)" != true ]]; then
        if w_would "create cleanuparr's account ('$user' — same login as the arrs) and complete setup"; then
            out=$(cup_api POST /auth/setup/account "" "$(jq -cn --arg u "$user" --arg p "$pass" '{username:$u,password:$p}')")
            [[ "$(cup_code)" =~ ^2 || "$(cup_code)" == 409 ]] \
                || { wfail "cleanuparr account creation rejected [HTTP $(cup_code)]: $(head -c200 <<<"$out")"; return 1; }
            out=$(cup_api POST /auth/setup/complete "")
            [[ "$(cup_code)" =~ ^2 || "$(cup_code)" == 409 ]] \
                || { wfail "cleanuparr setup completion rejected [HTTP $(cup_code)]: $(head -c200 <<<"$out")"; return 1; }
            ok "account created — sign in with the arr login (view: credentials)"
        fi
    else
        ok "account already set up"
    fi
    (( WIRE_DRY )) && { info "remaining cleanuparr previews pend on signing in — shown on the real run"; return 0; }

    # login -> bearer -> durable API key
    local tok akey
    out=$(cup_api POST /auth/login "" "$(jq -cn --arg u "$user" --arg p "$pass" '{username:$u,password:$p}')") \
        || { wfail "cleanuparr rejected the arr login [HTTP $(cup_code)]: $(head -c200 <<<"$out")
     if you changed its password in the UI, this is expected — its config stays yours"; return 1; }
    tok=$(jq -r '.tokens.accessToken // empty' <<<"$out")
    [[ -n "$tok" ]] || { wfail "cleanuparr login gave no access token: $(head -c200 <<<"$out")"; return 1; }
    akey=$(cup_api GET /account/api-key "Authorization: Bearer $tok" | jq -r '.apiKey // empty' 2>/dev/null)
    [[ -n "$akey" ]] || { wfail "could not read cleanuparr's API key [HTTP $(cup_code)]"; return 1; }
    [[ "$(env_get CLEANUPARR_API_KEY)" == "$akey" ]] || env_set CLEANUPARR_API_KEY "$akey"
    local KH="X-Api-Key: $akey"

    # download client: create-if-missing by name
    local qu qp have
    qu=$(env_get QBITTORRENT_USER); qp=$(env_get QBITTORRENT_PASSWORD)
    have=$(cup_api GET /configuration/download_client "$KH" | jq -r '[.[].name] | join(" ")' 2>/dev/null)
    if [[ " $have " == *" qbittorrent "* ]]; then
        ok "qbittorrent already connected — untouched"
    elif [[ -z "$qu" || -z "$qp" ]]; then
        wfail "no qBittorrent credentials in .env — run 'wire qbit' first"
    else
        local dc
        dc=$(jq -cn --arg u "$qu" --arg p "$qp" \
             '{enabled:true,name:"qbittorrent",typeName:"qBittorrent",type:"Torrent",
               host:"http://gluetun:8085",urlBase:"",username:$u,password:$p}')
        out=$(cup_api POST /configuration/download_client/test "$KH" "$dc") \
            || { wfail "cleanuparr could not reach qBittorrent [HTTP $(cup_code)]: $(head -c200 <<<"$out")"; return 1; }
        out=$(cup_api POST /configuration/download_client "$KH" "$dc") \
            && ok "qbittorrent connected" \
            || wfail "qbittorrent entry rejected [HTTP $(cup_code)]: $(head -c200 <<<"$out")"
    fi

    # arrs: create-if-missing by name, per type
    local s ty key port cfg names
    for s in $(arr_instances); do
        ty=$(svc_label "$s" mediastack.arrtype)
        [[ "$ty" == sonarr || "$ty" == radarr || "$ty" == lidarr ]] || continue
        key=$(arr_key "$s"); port=$(svc_label "$s" mediastack.port)
        [[ -n "$key" ]] || { wfail "$s: no ApiKey readable — re-run wire in a minute"; continue; }
        cfg=$(cup_api GET "/configuration/$ty" "$KH" || true)
        names=$(jq -r '[.instances[]?.name] | join(" ")' <<<"$cfg" 2>/dev/null)
        if [[ " $names " == *" $s "* ]]; then
            ok "$s already connected — untouched"
            continue
        fi
        out=$(cup_api POST "/configuration/$ty/instances" "$KH" \
              "$(jq -cn --arg n "$s" --arg u "http://gluetun:$port" --arg k "$key" \
                 '{enabled:true,name:$n,url:$u,apiKey:$k}')") \
            && ok "$s connected" \
            || wfail "$s: cleanuparr rejected it [HTTP $(cup_code)]: $(head -c200 <<<"$out")"
    done

    # queue cleaner: switch on, keep upstream's conservative defaults
    cfg=$(cup_api GET /configuration/queue_cleaner "$KH" || true)
    if [[ "$(jq -r '.enabled' <<<"$cfg" 2>/dev/null)" == true ]]; then
        ok "queue cleaner already on — its settings are yours to manage in the UI"
    elif [[ -n "$cfg" ]]; then
        out=$(cup_api PUT /configuration/queue_cleaner "$KH" "$(jq -c '.enabled = true' <<<"$cfg")") \
            && ok "queue cleaner enabled (conservative defaults — tune in its UI)" \
            || wfail "could not enable the queue cleaner [HTTP $(cup_code)]: $(head -c200 <<<"$out")"
    else
        wfail "could not read the queue-cleaner config [HTTP $(cup_code)]"
    fi

    # ops notifications via the hub, when the hub is wired
    if svc_enabled apprise && [[ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$(apprise_url)/get/mediastack" 2>/dev/null)" == 200 ]]; then
        have=$(cup_api GET /configuration/notification_providers "$KH" | jq -r '[.[].name] | join(" ")' 2>/dev/null)
        if [[ " $have " == *" mediastack-apprise "* ]]; then
            ok "already notifies the hub — untouched"
        else
            out=$(cup_api POST /configuration/notification_providers/apprise "$KH" \
                  "$(jq -cn '{name:"mediastack-apprise",isEnabled:true,mode:"Api",
                              url:"http://gluetun:8000",key:"mediastack",tags:"ops",
                              onQueueItemDeleted:true,onDownloadCleaned:true,
                              onStalledStrike:true,onFailedImportStrike:true}')") \
                && ok "now notifies the hub (tag: ops)" \
                || wfail "hub connection rejected [HTTP $(cup_code)]: $(head -c200 <<<"$out")"
        fi
    fi
}

# ---- jellyfin (wave 4) ----
# Wire's jellyfin surface is deliberately tiny: complete the first-run wizard
# (once, ever — the API gate closes itself), create libraries whose PATH is
# not yet covered, and mint the stack's API key. It never updates or deletes
# anything: rename/merge/tune libraries in the GUI freely — wire matches by
# path, not name, so it will not recreate or touch them.
JF_AUTH_HDR='Authorization: MediaBrowser Client="mediastack", Device="mediastack", DeviceId="mediastack-wire", Version="1.0"'
# jf_api runs inside $( ) at every call site, so a plain global would be lost
# to the subshell — the last HTTP code crosses back via a per-PID file.
JF_CODE_F="${TMPDIR:-/tmp}/.mediastack-jf-code.$$"
jf_code() { cat "$JF_CODE_F" 2>/dev/null || echo 000; }
jf_url() { echo "http://127.0.0.1:$(svc_label jellyfin mediastack.port)"; }
jf_api() { # jf_api METHOD PATH TOKEN [json-body] -> body on stdout; rc = http 2xx
    local m="$1" p="$2" tok="$3" b="${4:-}" out code
    if ! out=$(curl -sS -m 20 -X "$m" -H "$JF_AUTH_HDR" \
          ${tok:+-H "X-Emby-Token: $tok"} -H "Content-Type: application/json" \
          ${b:+-d "$b"} -w $'\n%{http_code}' "$(jf_url)$p" 2>&1); then
        printf '000' > "$JF_CODE_F"; echo "$out"; return 1
    fi
    code=${out##*$'\n'}; printf '%s' "$code" > "$JF_CODE_F"
    echo "${out%$'\n'*}"
    [[ "$code" =~ ^2 ]]
}
jf_ready() { # container "running" != API "ready"
    local t=0 code
    while :; do
        code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$(jf_url)/health" 2>/dev/null || echo 000)
        [[ "$code" == 200 ]] && return 0
        (( t >= 90 )) && { wfail "jellyfin's API never became ready within 90s (last: HTTP $code) — inspect: ./mediastack.sh logs jellyfin"; return 1; }
        sleep 5; t=$((t+5)); info "waiting for jellyfin's API (${t}s)..."
    done
}
jf_libname() { # default library name for a media subdir
    case "$1" in
        movies)    echo "Movies" ;;
        movies-4k) echo "Movies (4K)" ;;
        tv)        echo "TV Shows" ;;
        tv-anime)  echo "Anime" ;;
        music)     echo "Music" ;;
        *)         echo "${1^}" ;;
    esac
}

wire_jellyfin() {
    hr "wire: jellyfin"
    svc_enabled jellyfin || { info "jellyfin not enabled — skipped"; return 0; }
    wire_gate jellyfin
    jf_ready || return 1
    local pub completed juser jpass
    pub=$(jf_api GET /System/Info/Public "" || true)
    # NB: jq's // operator treats false as missing — read booleans plainly
    completed=$(jq -r '.StartupWizardCompleted' <<<"$pub" 2>/dev/null)
    [[ "$completed" == true || "$completed" == false ]] \
        || { wfail "jellyfin gave no readable public info [HTTP $(jf_code)]: $(head -c200 <<<"$pub")"; return 1; }
    juser=$(env_get JELLYFIN_ADMIN_USER); jpass=$(env_get JELLYFIN_ADMIN_PASSWORD)

    # --- first-run wizard: only ever runs while jellyfin says it is unclaimed.
    # This also closes a real hole: an unconfigured jellyfin lets ANY visitor
    # create the admin account.
    if [[ "$completed" == false ]]; then
        if [[ -z "$juser" || -z "$jpass" ]]; then
            if (( WIRE_DRY )); then
                w_would "complete jellyfin's first-run wizard (admin login asked on the real run)" || true
            elif [[ ! -t 0 ]]; then
                wfail "jellyfin's first-run wizard is incomplete and there is no terminal to ask for the admin login — run './mediastack.sh wire jellyfin' interactively"
                return 1
            else
                explain "Jellyfin admin" \
"Jellyfin needs one administrator account. This is the operator/recovery
login (it also signs in to Seerr as its owner) — your household gets
their own accounts later via invites. Everything else about Jellyfin
(look, libraries' settings, users) stays yours to manage in its GUI;
wire only performs this minimum first-run. Stored in .env (view:
credentials)."
                ask JF_U "Admin username" "${juser:-admin}"; juser="$REPLY_VAL"
                ask_secret "Admin password" "$(head -c12 /dev/urandom | base64 | tr -d '=+/')"; jpass="$REPLY_VAL"
                env_set JELLYFIN_ADMIN_USER "$juser"; env_set JELLYFIN_ADMIN_PASSWORD "$jpass"
            fi
        fi
        if [[ -n "$juser" && -n "$jpass" ]] && w_would "complete jellyfin's first-run wizard (admin '$juser', remote access on, UPnP off)"; then
            local step out
            for step in cfg getuser postuser remote complete; do
                case "$step" in
                    cfg)      out=$(jf_api POST /Startup/Configuration "" '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}') ;;
                    getuser)  out=$(jf_api GET /Startup/User "") ;;  # initialises the first-user record
                    postuser) out=$(jf_api POST /Startup/User "" "$(jq -cn --arg u "$juser" --arg p "$jpass" '{Name:$u,Password:$p}')") ;;
                    remote)   out=$(jf_api POST /Startup/RemoteAccess "" '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}') ;;
                    complete) out=$(jf_api POST /Startup/Complete "") ;;
                esac || { wfail "jellyfin wizard step '$step' rejected [HTTP $(jf_code)]: $(head -c200 <<<"$out")"; return 1; }
            done
            ok "first-run wizard completed — admin '$juser'"
        fi
    else
        ok "first-run wizard already completed"
    fi

    # --- everything below needs an admin session
    if [[ -z "$juser" || -z "$jpass" ]]; then
        if (( WIRE_DRY )); then
            info "library/API-key previews pend on the admin login — created earlier in the same real run"
        else
            info "jellyfin was configured outside wire and no JELLYFIN_ADMIN_USER/PASSWORD is in .env — libraries and the stack API key stay manual (set them in .env to let wire manage those)"
        fi
        return 0
    fi
    local auth tok
    auth=$(jf_api POST /Users/AuthenticateByName "" "$(jq -cn --arg u "$juser" --arg p "$jpass" '{Username:$u,Pw:$p}')") \
        || { (( WIRE_DRY )) && { info "cannot verify further without logging in — real run continues from here"; return 0; }
             wfail "jellyfin rejected the admin login from .env [HTTP $(jf_code)]: $(head -c200 <<<"$auth")"; return 1; }
    tok=$(jq -r '.AccessToken // empty' <<<"$auth")
    [[ -n "$tok" ]] || { wfail "jellyfin login succeeded but returned no token: $(head -c200 <<<"$auth")"; return 1; }

    # --- libraries: create-if-path-missing, derived from the arrs' own
    # rootfolder labels. Match by PATH so GUI renames/merges are respected.
    local vf droot; vf=$(jf_api GET /Library/VirtualFolders "$tok" || true)
    [[ "$(jf_code)" =~ ^2 ]] || { wfail "could not list jellyfin libraries [HTTP $(jf_code)]: $(head -c200 <<<"$vf")"; return 1; }
    droot=$(env_get DATA_ROOT)
    local -A seen=()
    local s rf base path ctype lname enc_n enc_p resp
    for s in $(arr_instances); do
        rf=$(svc_label "$s" mediastack.rootfolder); base=${rf##*/}
        [[ -n "$base" && -z "${seen[$base]:-}" ]] || continue; seen[$base]=1
        path="/media/$base"
        case "$(svc_label "$s" mediastack.arrtype)" in
            radarr) ctype=movies ;; sonarr) ctype=tvshows ;; lidarr) ctype=music ;; *) continue ;;
        esac
        if jq -e --arg p "$path" 'any(.[].Locations[]?; . == $p)' <<<"$vf" >/dev/null 2>&1; then
            ok "a library already covers $path — untouched (yours to manage in the GUI)"
            continue
        fi
        if (( WIRE_DRY )); then
            w_would "create jellyfin library for $path (${ctype}; name asked on the real run)" || true
            continue
        fi
        if [[ ! -t 0 ]]; then
            info "$path has no library yet — creation asks for a name, so it only happens interactively: ./mediastack.sh wire jellyfin"
            continue
        fi
        # jellyfin sees /media read-only; the host dir must exist or the
        # library is born broken. Same ownership pattern as configure's tree.
        sudo test -d "$droot/media/$base" \
            || { sudo install -d -m 2775 -g mediacenter "$droot/media/$base" && info "created $droot/media/$base (was missing)"; }
        ask JF_LN "Library name for $path" "$(jf_libname "$base")"; lname="$REPLY_VAL"
        if w_would "create jellyfin library '$lname' -> $path"; then
            enc_n=$(jq -rn --arg v "$lname" '$v|@uri'); enc_p=$(jq -rn --arg v "$path" '$v|@uri')
            resp=$(jf_api POST "/Library/VirtualFolders?name=${enc_n}&collectionType=${ctype}&paths=${enc_p}&refreshLibrary=true" "$tok" '{"LibraryOptions":{}}') \
                && ok "library '$lname' created" \
                || wfail "library '$lname' rejected [HTTP $(jf_code)]: $(head -c200 <<<"$resp")"
        fi
    done

    # --- one API key for the stack (update-defer streaming check + doctor)
    local keys have
    keys=$(jf_api GET /Auth/Keys "$tok" || true)
    have=$(jq -r '.Items[]? | select(.AppName=="mediastack") | .AccessToken' <<<"$keys" 2>/dev/null | head -1)
    if [[ -n "$have" ]]; then
        [[ "$(env_get JELLYFIN_API_KEY)" == "$have" ]] || env_set JELLYFIN_API_KEY "$have"
        ok "stack API key present"
    elif w_would "mint a jellyfin API key for the stack (app 'mediastack')"; then
        jf_api POST "/Auth/Keys?app=mediastack" "$tok" >/dev/null \
            || { wfail "API key creation rejected [HTTP $(jf_code)]"; return 1; }
        keys=$(jf_api GET /Auth/Keys "$tok" || true)
        have=$(jq -r '.Items[]? | select(.AppName=="mediastack") | .AccessToken' <<<"$keys" 2>/dev/null | head -1)
        [[ -n "$have" ]] || { wfail "API key created but not readable back — check Dashboard -> API Keys"; return 1; }
        env_set JELLYFIN_API_KEY "$have"
        ok "stack API key minted and stored (JELLYFIN_API_KEY)"
    fi
}

# ---- seerr (wave 4) ----
# Seerr federates auth to jellyfin (users sign in with their jellyfin logins;
# no seerr-local passwords exist here). Wire bootstraps an UNINITIALISED
# seerr only: first sign-in as the jellyfin admin (which creates seerr's
# owner), library sync + enable, one server entry per arr, initialise. An
# initialised seerr is never touched — its settings are GUI territory.
seerr_url() { echo "http://127.0.0.1:$(svc_label seerr mediastack.port)"; }
SEERR_CODE_F="${TMPDIR:-/tmp}/.mediastack-seerr-code.$$"
seerr_code() { cat "$SEERR_CODE_F" 2>/dev/null || echo 000; }
seerr_api() { # seerr_api METHOD PATH JAR [json-body] -> body; rc = http 2xx
    local m="$1" p="$2" jar="$3" b="${4:-}" out code
    if ! out=$(curl -sS -m 30 -X "$m" -b "$jar" -c "$jar" -H "Content-Type: application/json" \
          ${b:+-d "$b"} -w $'\n%{http_code}' "$(seerr_url)/api/v1$p" 2>&1); then
        printf '000' > "$SEERR_CODE_F"; echo "$out"; return 1
    fi
    code=${out##*$'\n'}; printf '%s' "$code" > "$SEERR_CODE_F"
    echo "${out%$'\n'*}"
    [[ "$code" =~ ^2 ]]
}

wire_seerr() {
    hr "wire: seerr"
    svc_enabled seerr || { info "seerr not enabled — skipped"; return 0; }
    svc_enabled jellyfin || { wfail "seerr is enabled but jellyfin is not — seerr cannot function without it"; return 1; }
    wire_gate seerr jellyfin
    local t=0 code
    while :; do
        code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$(seerr_url)/api/v1/status" 2>/dev/null || echo 000)
        [[ "$code" == 200 ]] && break
        (( t >= 90 )) && { wfail "seerr's API never became ready within 90s (last: HTTP $code) — inspect: ./mediastack.sh logs seerr"; return 1; }
        sleep 5; t=$((t+5)); info "waiting for seerr's API (${t}s)..."
    done
    local jar pub
    jar=$(mktemp)
    pub=$(seerr_api GET /settings/public "$jar" || true)
    local seerr_initialized=false
    [[ "$(jq -r '.initialized' <<<"$pub" 2>/dev/null)" == true ]] && seerr_initialized=true
    local juser jpass
    juser=$(env_get JELLYFIN_ADMIN_USER); jpass=$(env_get JELLYFIN_ADMIN_PASSWORD)
    if [[ -z "$juser" || -z "$jpass" ]]; then
        if (( WIRE_DRY )); then
            w_would "bootstrap seerr (sign in as the jellyfin admin, sync + enable libraries, add the arrs, initialise)" || true
        else
            wfail "seerr bootstrap needs the jellyfin admin login — run 'wire jellyfin' first (a full 'wire' does both in order)"
        fi
        rm -f "$jar"; return 0
    fi
    if $seerr_initialized; then
        # initialised = its settings are yours; wire only CREATES missing arr
        # entries (matched by name), mirroring the jellyfin library contract
        if ! w_would "verify seerr's arr entries (create missing only — nothing existing is touched)"; then rm -f "$jar"; return 0; fi
    else
        if ! w_would "bootstrap seerr: jellyfin sign-in ('$juser'), libraries, arr servers, initialise"; then rm -f "$jar"; return 0; fi
    fi

    # the API demands the hostname iff seerr does not have one yet: a prior
    # partial bootstrap leaves it stored, and re-sending it is a hard 500
    local jfport out
    jfport=$(svc_label jellyfin mediastack.port)
    out=$(seerr_api POST /auth/jellyfin "$jar" "$(jq -cn --arg u "$juser" --arg p "$jpass" --argjson port "$jfport" \
          '{username:$u,password:$p,hostname:"jellyfin",port:$port,useSsl:false,urlBase:"",serverType:2}')") || {
        if grep -q "already configured" <<<"$out"; then
            $seerr_initialized || info "seerr already holds the jellyfin hostname (earlier attempt) — signing in without it"
            out=$(seerr_api POST /auth/jellyfin "$jar" "$(jq -cn --arg u "$juser" --arg p "$jpass" \
                  '{username:$u,password:$p,serverType:2}')") \
                || { wfail "seerr rejected the jellyfin sign-in [HTTP $(seerr_code)]: $(head -c200 <<<"$out")"; rm -f "$jar"; return 1; }
        else
            wfail "seerr rejected the jellyfin sign-in [HTTP $(seerr_code)]: $(head -c200 <<<"$out")"; rm -f "$jar"; return 1
        fi
    }
    ok "signed in — seerr owner is jellyfin admin '$juser'"

    if ! $seerr_initialized; then
    # v3.4.1 API: ?sync=true fetches from jellyfin and returns the list;
    # ?enable=<csv-ids> declares the complete enabled set in one call
    local libs ids n
    libs=$(seerr_api GET "/settings/jellyfin/library?sync=true" "$jar") \
        || { wfail "library sync failed [HTTP $(seerr_code)]: $(head -c200 <<<"$libs")"; rm -f "$jar"; return 1; }
    ids=$(jq -r '[.[].id] | join(",")' <<<"$libs" 2>/dev/null)
    [[ -n "$ids" ]] || { wfail "seerr returned no libraries from jellyfin — are the libraries created? re-run 'wire jellyfin' first: $(head -c200 <<<"$libs")"; rm -f "$jar"; return 1; }
    libs=$(seerr_api GET "/settings/jellyfin/library?enable=$ids" "$jar") \
        || { wfail "enabling libraries failed [HTTP $(seerr_code)]: $(head -c200 <<<"$libs")"; rm -f "$jar"; return 1; }
    n=$(jq '[.[] | select(.enabled)] | length' <<<"$libs" 2>/dev/null)
    ok "libraries synced — ${n:-0} enabled"
    fi

    # one server entry per arr instance, connection details straight from the
    # stack's own labels/keys. The arrs live in gluetun's network namespace,
    # so 'gluetun' is their in-network hostname. Existing entries (matched by
    # name) are never touched — create-if-missing only.
    local have_radarr have_sonarr
    have_radarr=$(seerr_api GET /settings/radarr "$jar" | jq -r '[.[].name] | join(" ")' 2>/dev/null)
    have_sonarr=$(seerr_api GET /settings/sonarr "$jar" | jq -r '[.[].name] | join(" ")' 2>/dev/null)
    local s ty key port root profs pid pname body ep is4k
    for s in $(arr_instances); do
        ty=$(svc_label "$s" mediastack.arrtype)
        [[ "$ty" == radarr || "$ty" == sonarr ]] || { info "$s: seerr does not manage $ty — skipped"; continue; }
        if [[ "$ty" == radarr && " $have_radarr " == *" $s "* ]] || [[ "$ty" == sonarr && " $have_sonarr " == *" $s "* ]]; then
            ok "$s already in seerr — untouched (yours to manage in the GUI)"
            continue
        fi
        key=$(arr_key "$s"); port=$(svc_label "$s" mediastack.port); root=$(svc_label "$s" mediastack.rootfolder)
        [[ -n "$key" ]] || { wfail "$s: no ApiKey readable — is it initialised? re-run wire in a minute"; continue; }
        profs=$(api GET "$(arr_url "$s")/api/$(arr_apiver "$s")/qualityprofile" "$key" || true)
        pid=$(jq -r --arg n "$(env_get "TRASH_PROFILE_$(uvar "$s")")" \
              '(map(select(.name==$n)) + .)[0].id // empty' <<<"$profs" 2>/dev/null)
        pname=$(jq -r --arg n "$(env_get "TRASH_PROFILE_$(uvar "$s")")" \
              '(map(select(.name==$n)) + .)[0].name // empty' <<<"$profs" 2>/dev/null)
        [[ -n "$pid" ]] || { wfail "$s: could not read a quality profile from its API — seerr entry skipped"; continue; }
        is4k=false; [[ "$s" == *-4k ]] && is4k=true
        body=$(jq -cn --arg name "$s" --argjson port "$port" --arg key "$key" \
                     --argjson pid "$pid" --arg pname "$pname" --arg root "$root" --argjson is4k "$is4k" \
              '{name:$name,hostname:"gluetun",port:$port,apiKey:$key,useSsl:false,baseUrl:"",
                activeProfileId:$pid,activeProfileName:$pname,activeDirectory:$root,
                tags:[],is4k:$is4k,isDefault:true,syncEnabled:true,preventSearch:false,
                tagRequests:false,overrideRule:[]}')
        ep="/settings/$ty"
        [[ "$ty" == radarr ]] && body=$(jq -c '. + {minimumAvailability:"released"}' <<<"$body")
        [[ "$ty" == sonarr ]] && body=$(jq -c '. + {enableSeasonFolders:true}' <<<"$body")
        [[ "$s" == sonarr-anime ]] && body=$(jq -c '. + {isDefault:false}' <<<"$body")
        out=$(seerr_api POST "$ep/test" "$jar" "$body") \
            || { wfail "$s: seerr could not reach it [HTTP $(seerr_code)]: $(head -c200 <<<"$out")"; continue; }
        out=$(seerr_api POST "$ep" "$jar" "$body") \
            && ok "$s added to seerr (profile '$pname'${is4k:+, 4k=$is4k})" \
            || wfail "$s: seerr rejected the server entry [HTTP $(seerr_code)]: $(head -c200 <<<"$out")"
    done

    if $seerr_initialized; then
        rm -f "$jar"
        ok "seerr arr entries verified"
        return 0
    fi
    out=$(seerr_api POST /settings/initialize "$jar") \
        || { wfail "seerr initialise call failed [HTTP $(seerr_code)]: $(head -c200 <<<"$out")"; rm -f "$jar"; return 1; }
    local skey
    skey=$(seerr_api GET /settings/main "$jar" | jq -r '.apiKey // empty' 2>/dev/null)
    [[ -n "$skey" ]] && env_set SEERR_API_KEY "$skey"
    rm -f "$jar"
    ok "seerr initialised — users sign in with their jellyfin logins"
}

# ---- wizarr (wave 4) ----
# Wizarr's admin account, jellyfin connection, and API keys are web-UI-only
# by upstream design — no bootstrap API exists. One documented first-run in
# the UI, then wire holds the API key and './mediastack.sh invite' does the
# rest forever.
wizarr_url() { echo "http://127.0.0.1:$(svc_label wizarr mediastack.port)"; }

wire_wizarr() {
    hr "wire: wizarr"
    svc_enabled wizarr || { info "wizarr not enabled — skipped"; return 0; }
    wire_gate wizarr
    local t=0 code
    while :; do
        code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$(wizarr_url)/health" 2>/dev/null || echo 000)
        # a virgin wizarr 302s /health to /setup (onboarding middleware) —
        # any 2xx/3xx means the app is up and serving
        [[ "$code" =~ ^[23] ]] && break
        (( t >= 90 )) && { wfail "wizarr never became ready within 90s (last: HTTP $code) — inspect: ./mediastack.sh logs wizarr"; return 1; }
        sleep 5; t=$((t+5)); info "waiting for wizarr (${t}s)..."
    done
    local key host domain
    key=$(env_get WIZARR_API_KEY)
    if [[ -z "$key" ]]; then
        if (( WIRE_DRY )); then
            w_would "store + verify a wizarr API key (pasted by you after wizarr's one-time UI first-run)" || true
            return 0
        fi
        if [[ ! -t 0 ]]; then
            info "no WIZARR_API_KEY yet — wizarr's first-run is a one-time UI step; run './mediastack.sh wire wizarr' interactively after it"
            return 0
        fi
        host=$(env_get WIZARR_HOST invites); domain=$(env_get TRAEFIK_DOMAIN)
        local jfkey; jfkey=$(env_get JELLYFIN_API_KEY "(empty — run 'wire jellyfin' first to mint it)")
        explain "Wizarr first-run (one-time, in its UI)" \
"Wizarr's admin account and API keys can only be created in its web UI —
there is no automation API for this by upstream design. Once, ever:
  1. open ${domain:+https://$host.$domain (or }http://<this-host>:$(svc_label wizarr mediastack.port)${domain:+)}
  2. create the admin account
  3. Settings -> Servers -> Add Server:
       Name            jellyfin
       Server Type     Jellyfin
       URL (Internal)  http://jellyfin:8096
       API Key         $jfkey
     then Test & Add
  4. Settings -> API Keys -> create one, and paste it below
Paste nothing to skip for now — re-run 'wire wizarr' any time."
        ask_token "Wizarr API key (input is hidden; empty = skip)" ""
        key="$REPLY_VAL"
        [[ -n "$key" ]] || { info "skipped — invites stay in wizarr's UI until a key is stored"; return 0; }
        env_set WIZARR_API_KEY "$key"
    fi
    local out
    if ! out=$(curl -sS -m 15 -H "X-API-Key: $key" -w $'\n%{http_code}' "$(wizarr_url)/api/invitations" 2>&1); then
        wfail "wizarr unreachable while verifying the API key: $(head -c200 <<<"$out")"; return 1
    fi
    code=${out##*$'\n'}
    if [[ "$code" =~ ^2 ]]; then
        ok "API key verified — mint invites with: ./mediastack.sh invite"
    else
        wfail "wizarr rejected the stored API key [HTTP $code] — recreate it in Settings -> API Keys, then re-run 'wire wizarr' (the old value stays in .env until replaced)"
        return 1
    fi
}

cmd_wire() {
    load_env; render
    local section="all"
    while [[ $# -gt 0 ]]; do case "$1" in
        --dry-run) WIRE_DRY=1; shift ;;
        qbit|arr|prowlarr|bazarr|apprise|cleanuparr|jellyfin|seerr|wizarr|all) section="$1"; shift ;;
        *) die "usage: wire [qbit|arr|prowlarr|bazarr|apprise|cleanuparr|jellyfin|seerr|wizarr] [--dry-run]" ;;
    esac; done
    (( WIRE_DRY )) && hr "wire --dry-run: showing changes, touching nothing"
    if (( ! WIRE_DRY )) && [[ ! -f "$SCRIPT_DIR/.wired" ]]; then
        if confirm "First wire on this deployment — take a restore point first? (recommended)"; then
            cmd_backup
            # the backup bounced every container — let the apps come back
            # before wiring their APIs
            info "waiting for services to settle after the restore point (up to 120s)..."
            local wt=0 pending_s
            while (( wt < 120 )); do
                pending_s=""
                for s in qbittorrent prowlarr bazarr apprise cleanuparr jellyfin seerr wizarr $(arr_instances); do
                    svc_enabled "$s" || continue
                    case "$(c_health "$(svc_cname "$s")")" in
                        healthy|-) : ;;
                        *) pending_s+="$s " ;;
                    esac
                done
                [[ -z "$pending_s" ]] && break
                sleep 5; wt=$((wt+5))
            done
            [[ -z "$pending_s" ]] && ok "services settled" \
                || warn "still settling: $pending_s— wiring anyway; anything that refuses gets a per-item FAIL and a re-run picks it up"
        fi
    fi
    case "$section" in
        qbit)     wire_qbit ;;
        arr)      wire_arr ;;
        prowlarr) wire_prowlarr ;;
        bazarr)   wire_bazarr ;;
        apprise)  wire_apprise ;;
        cleanuparr) wire_cleanuparr ;;
        jellyfin) wire_jellyfin ;;
        seerr)    wire_seerr ;;
        wizarr)   wire_wizarr ;;
        # order matters: seerr signs in via jellyfin's admin; wizarr's UI
        # first-run wants jellyfin claimed first
        all)      wire_qbit; wire_arr; wire_prowlarr; wire_bazarr; wire_apprise; wire_cleanuparr; wire_jellyfin; wire_seerr; wire_wizarr ;;
    esac
    echo
    if (( WIRE_DRY )); then
        info "dry-run complete: $WIRE_CHANGES change(s) would be applied. Run without --dry-run to apply."
        info "note: items marked as pending on credentials resolve mid-run — the real run creates them in order."
    else
        touch "$SCRIPT_DIR/.wired"
        if (( WIRE_FAILS )); then
            fail "wire finished with $WIRE_FAILS failure(s) — see the FAIL lines above. Re-run after fixing; completed items just skip."
            exit 1
        fi
        ok "wire complete. Verify: ./mediastack.sh doctor   Credentials: ./mediastack.sh credentials"
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
    info "Meilisearch master key is machine-to-machine — apps use it, you never need it."
}

cmd_set_credentials() { # rotate a stored credential in the app(s) AND .env, atomically
    load_env; render
    local target="${1:-}"
    [[ "$target" == arr || "$target" == qbit || "$target" == jellyfin ]] \
        || die "usage: set-credentials <arr|qbit|jellyfin>
  arr       the shared login of every arr app (+ cleanuparr's account password)
  qbit      qBittorrent's WebUI login (+ every place that stores it)
  jellyfin  the Jellyfin admin password (Seerr/Wizarr need no change)"
    [[ -t 0 ]] || die "set-credentials is interactive — run it at a terminal."

    case "$target" in
    arr)
        local olduser oldpass user pass s
        olduser=$(env_get ARR_USER); oldpass=$(env_get ARR_PASSWORD)
        explain "Rotate the arr login" \
"One login for Sonarr/Radarr/Lidarr/Prowlarr/Bazarr — and cleanuparr's
account password follows it. Cleanuparr's USERNAME cannot be changed via
its API: if you change the username here, sign-in to cleanuparr keeps the
old one."
        ask SC_U "Username" "${olduser:-admin}"; user="$REPLY_VAL"
        ask_secret "New password" "$(head -c12 /dev/urandom | base64 | tr -d '=+/')"; pass="$REPLY_VAL"
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
        ;;
    qbit)
        local user pass s
        explain "Rotate the qBittorrent login" \
"Changes the WebUI login and updates everything that stores it: each
arr's download-client entry and cleanuparr's connection."
        ask SC_QU "Username" "$(env_get QBITTORRENT_USER admin)"; user="$REPLY_VAL"
        ask_secret "New password" "$(head -c12 /dev/urandom | base64 | tr -d '=+/')"; pass="$REPLY_VAL"
        qb_login "$(env_get QBITTORRENT_USER)" "$(env_get QBITTORRENT_PASSWORD)" \
            || die "cannot sign in to qBittorrent with the stored credentials — fix that first (wire qbit)"
        qb_api /app/setPreferences "json=$(jq -cn --arg u "$user" --arg p "$pass" '{web_ui_username:$u,web_ui_password:$p}')" >/dev/null
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
            dcid=$(jq -r '.[] | select(.name=="qbittorrent") | .id' <<<"$dcs" 2>/dev/null | head -1)
            if [[ -n "$dcid" ]]; then
                dcent=$(jq -c --arg i "$dcid" --arg u "$user" --arg p "$pass" \
                        '.[] | select(.id==$i) | .username=$u | .password=$p' <<<"$dcs")
                cup_api PUT "/configuration/download_client/$dcid" "$KH" "$dcent" >/dev/null \
                    && ok "cleanuparr connection updated" \
                    || wfail "cleanuparr connection not updated [HTTP $(cup_code)] — fix in its UI"
            fi
        fi
        ;;
    jellyfin)
        local juser jpass npass auth tok
        juser=$(env_get JELLYFIN_ADMIN_USER); jpass=$(env_get JELLYFIN_ADMIN_PASSWORD)
        [[ -n "$juser" && -n "$jpass" ]] || die "no Jellyfin admin stored — run 'wire jellyfin' first"
        explain "Rotate the Jellyfin admin password" \
"Seerr federates to Jellyfin (nothing to change there) and Wizarr connects
by API key (unchanged). Only this password and .env move."
        ask_secret "New password" "$(head -c12 /dev/urandom | base64 | tr -d '=+/')"; npass="$REPLY_VAL"
        auth=$(jf_api POST /Users/AuthenticateByName "" "$(jq -cn --arg u "$juser" --arg p "$jpass" '{Username:$u,Pw:$p}')") \
            || die "Jellyfin rejected the stored admin login [HTTP $(jf_code)] — is .env stale?"
        tok=$(jq -r '.AccessToken // empty' <<<"$auth")
        jf_api POST /Users/Password "$tok" "$(jq -cn --arg c "$jpass" --arg n "$npass" '{CurrentPw:$c,NewPw:$n}')" >/dev/null \
            || die "Jellyfin refused the password change [HTTP $(jf_code)]"
        jf_api POST /Users/AuthenticateByName "" "$(jq -cn --arg u "$juser" --arg p "$npass" '{Username:$u,Pw:$p}')" >/dev/null \
            || die "verification sign-in with the NEW password failed — check Jellyfin's users in its dashboard"
        env_set JELLYFIN_ADMIN_PASSWORD "$npass"
        ok "Jellyfin admin password rotated and verified"
        ;;
    esac
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
    else base="http://$(hostname -I 2>/dev/null | awk '{print $1}'):$(svc_label wizarr mediastack.port)"; fi
    exp_line="never expires"
    [[ -n "$expires" ]] && exp_line="expires in $expires day(s)"
    hr "Invitation ready"
    echo "  ${base}${url}"
    echo "  ($exp_line — manage or revoke in wizarr's UI)"
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
        wire)         cmd_wire "$@" ;;
        invite)       cmd_invite "$@" ;;
        set-credentials) cmd_set_credentials "$@" ;;
        credentials)  cmd_credentials ;;
        trash-sync)   cmd_trash_sync "$@" ;;
        traefik-setup) cmd_traefik_setup "$@" ;;
        new-service)  cmd_new_service "$@" ;;
        upgrade)      cmd_upgrade ;;
        uninstall)    cmd_uninstall "$@" ;;
        *) fail "Unknown command '$cmd'"; echo; cmd_help; exit 1 ;;
    esac
}
# =================================================================== trash --
# Wave 2: TRaSH Guides sync via Recyclarr (guide-backed profiles, v8 schema).
# Managed instances: sonarr, sonarr-anime, radarr, radarr-4k. Lidarr is out
# of scope (recyclarr supports sonarr/radarr only).

trash_instances() {
    local s; for s in sonarr sonarr-anime radarr radarr-4k; do
        svc_enabled "$s" && echo "$s"
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

trash_gen_config() {
    local uid out tmp
    uid=$(env_get RECYCLARR_UID 13020)
    out="$(env_get CONFIG_ROOT)/recyclarr/recyclarr.yml"
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

cmd_trash_sync() {
    WIRE_FAILS=0
    hr "trash-sync: TRaSH Guides via Recyclarr"
    local insts; insts=$(trash_instances)
    [[ -n "$insts" ]] || { info "no managed arr instances enabled — nothing to sync"; return 0; }
    wire_gate $insts
    trash_menu
    hr "trash-sync: provision"
    trash_provision || { fail "trash-sync aborted: provisioning failed."; return 1; }
    hr "trash-sync: generate config"
    trash_gen_config
    local s
    hr "trash-sync: ownership banners"
    local deadline=$(( $(date +%s) + 90 ))
    for s in $insts; do
        [[ "$(env_get "$(trash_envkey "$s")")" == skip ]] && continue
        arr_api_ready "$s" "$deadline" || continue
        trash_sentinel "$s"
    done
    hr "trash-sync: recyclarr"
    # keep the pinned :8 tag current (patch releases only — a major bump is
    # a schema migration and stays a deliberate, manual tag change)
    sudo docker compose pull -q recyclarr 2>/dev/null \
        && info "recyclarr image: pinned tag up to date" \
        || warn "recyclarr image pull failed (registry unreachable?) — syncing with the local image"
    local slog rc summary
    slog=$(mktemp)
    sudo docker compose run --rm recyclarr sync 2>&1 | tee "$slog"
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

# ================================================================= traefik --
# Wave 3: the edge. All config is generated (desired state from .env); the
# only imperative act is issuing certs, which Traefik does itself.

traefik_ensure() { # traefik_ensure [--reconfigure]; runs on up/enable; idempotent
    svc_enabled traefik || return 0
    local force=0; [[ "${1:-}" == --reconfigure ]] && force=1
    local domain email token acmeenv duser
    domain=$(env_get TRAEFIK_DOMAIN); email=$(env_get ACME_EMAIL)
    token=$(env_get CF_DNS_API_TOKEN)
    if [[ -z "$domain" || -z "$email" || -z "$token" ]] || (( force )); then
        if [[ ! -t 0 ]]; then
            (( force )) && die "traefik-setup needs a terminal."
            die "traefik is enabled but not configured (TRAEFIK_DOMAIN/ACME_EMAIL/CF_DNS_API_TOKEN) and there is no terminal to ask — run './mediastack.sh traefik-setup' interactively first."
        fi
        hr "Traefik setup"
        (( force )) && info "Enter keeps the value shown in [brackets]."
        explain "Your domain" \
"Every service gets its own address under one domain you own:
https://jellyfin.<domain>, https://requests.<domain>, and so on.
Before continuing, two things must exist at dash.cloudflare.com:
  1. the domain's DNS, hosted on Cloudflare
  2. a wildcard A record  *.<domain> -> this machine's LAN IP,
     with the proxy toggle OFF (grey cloud, 'DNS only')
This exposes nothing to the internet — the addresses only resolve
usefully on your own network."
        ask TD "Base domain (e.g. media.example.com)" "${domain}"; domain="$REPLY_VAL"
        [[ -n "$domain" ]] || die "A domain is required."
        ask AE "Email for certificate-expiry notices" "${email}"; email="$REPLY_VAL"
        explain "Cloudflare API token" \
"Lets the stack prove to Let's Encrypt that you control the domain.
Create one at dash.cloudflare.com -> My Profile -> API Tokens ->
Create Token: give it the single permission  Zone / DNS / Edit,
scoped to just this domain's zone. (Not the Global API Key.)"
        ask_token "Paste the Cloudflare token (input is hidden)" "$token"; token="$REPLY_VAL"
        explain "Certificates: real or testing?" \
"  production  real certificates, trusted by every browser. Let's
              Encrypt allows only 5 identical ones per week, so
              repeated install testing can lock you out for days.
  staging     unlimited test certificates. Browsers show a warning
              you can click through — everything else works the
              same. Pick this while you are still testing; one
              setting change switches to production later and the
              stack handles the swap itself."
        ask AV "Certificate environment [production/staging]" "$(env_get ACME_ENV production)"
        case "$REPLY_VAL" in production|staging) acmeenv="$REPLY_VAL" ;; *) die "Expected 'production' or 'staging'." ;; esac
        env_set TRAEFIK_DOMAIN "$domain"; env_set ACME_EMAIL "$email"
        env_set CF_DNS_API_TOKEN "$token"; env_set ACME_ENV "$acmeenv"
    fi
    duser=$(env_get TRAEFIK_DASH_USER)
    if [[ -z "$duser" ]] || (( force )); then
        [[ -t 0 ]] || die "traefik dashboard credentials unset and no terminal — run './mediastack.sh traefik-setup'."
        explain "Dashboard login" \
"Traefik's dashboard (https://dash.<domain>) shows every route and
certificate. It cannot change anything, but it still gets a login.
Enter accepts a generated password; see it later with: credentials"
        ask DU "Dashboard username" "$(env_get TRAEFIK_DASH_USER admin)"; duser="$REPLY_VAL"
        ask_secret "Dashboard password" "$(env_get TRAEFIK_DASH_PASSWORD "$(head -c12 /dev/urandom | base64 | tr -d '=+/')")"
        env_set TRAEFIK_DASH_USER "$duser"; env_set TRAEFIK_DASH_PASSWORD "$REPLY_VAL"
    fi
    traefik_gen
}

traefik_gen() {
    local croot domain acmeenv caline hash duser dpass prehash posthash
    croot=$(env_get CONFIG_ROOT); domain=$(env_get TRAEFIK_DOMAIN)
    acmeenv=$(env_get ACME_ENV production)
    # docker creates missing bind sources as root-owned DIRECTORIES; if the
    # container ever started before setup, our file paths are junk dirs now
    local f
    for f in "$croot/traefik/traefik.yml" "$croot/traefik/dynamic.yml" "$croot/traefik/dynamic/00-mediastack.yml"; do
        sudo test -d "$f" && { warn "removing docker-created junk directory at $f"; sudo rm -rf "$f"; }
    done
    sudo test -d /run-traefik-setup-first && sudo rm -rf /run-traefik-setup-first
    sudo install -d -m 700 "$croot/traefik" "$croot/traefik/acme"
    install -d -m 755 local/proxy.d
    env_set TRAEFIK_LOCAL_PROXY "$PWD/local/proxy.d"
    # env switch detection: staging certs must not survive into production
    # (and vice versa) — traefik would keep serving the cached ones forever
    local acme="$croot/traefik/acme/acme.json" stored=""
    if sudo test -s "$acme"; then
        sudo grep -q "acme-staging" "$acme" && stored=staging || stored=production
        if [[ "$stored" != "$acmeenv" ]]; then
            warn "ACME_ENV is '$acmeenv' but stored certificates are '$stored' — resetting the certificate store so the switch takes effect (reissue happens automatically)."
            sudo mv "$acme" "$acme.old-$stored.$(date +%s)"
        fi
    fi
    prehash=$(sudo cat "$croot/traefik/traefik.yml" "$croot/traefik/dynamic/00-mediastack.yml" 2>/dev/null | sha256sum)
    caline=""
    [[ "$acmeenv" == staging ]] && caline='      caServer: "https://acme-staging-v02.api.letsencrypt.org/directory"'
    local tmp; tmp=$(mktemp)
    cat > "$tmp" <<STATIC
# GENERATED by mediastack traefik-setup — DO NOT EDIT. Knobs live in .env.
ping: {}
api:
  dashboard: true
entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"
providers:
  docker:
    exposedByDefault: false
    network: mediastack
  file:
    directory: /dynamic
    watch: true
certificatesResolvers:
  le:
    acme:
      email: $(env_get ACME_EMAIL)
      storage: /letsencrypt/acme.json
$caline
      dnsChallenge:
        provider: cloudflare
        resolvers:
          - "1.1.1.1:53"
          - "8.8.8.8:53"
STATIC
    sudo install -m 600 "$tmp" "$croot/traefik/traefik.yml"
    duser=$(env_get TRAEFIK_DASH_USER); dpass=$(env_get TRAEFIK_DASH_PASSWORD)
    # deterministic salt: identical inputs must yield an identical file, or
    # the change-detection restart fires on every regeneration
    hash=$(openssl passwd -apr1 -salt "$(printf '%s' "$duser:$dpass" | sha256sum | cut -c1-8)" "$dpass")
    cat > "$tmp" <<DYNAMIC
# GENERATED by mediastack traefik-setup — DO NOT EDIT.
# The dashboard router is also the single wildcard-cert requester: every
# other router says tls=true and reuses the cert issued here.
http:
  routers:
    dashboard:
      rule: "Host(\`$(env_get TRAEFIK_DASH_HOST dash).$domain\`)"
      entryPoints: [websecure]
      service: api@internal
      middlewares: [dash-auth]
      tls:
        certResolver: le
        domains:
          - main: "$domain"
            sans: ["*.$domain"]
  middlewares:
    dash-auth:
      basicAuth:
        users:
          - "$duser:$hash"
DYNAMIC
    sudo install -d -m 700 "$croot/traefik/dynamic"
    sudo rm -f "$croot/traefik/dynamic.yml"   # pre-dir layout leftover
    sudo install -m 600 "$tmp" "$croot/traefik/dynamic/00-mediastack.yml"; rm -f "$tmp"
    # user proxy hosts: copied in (applied on every up / traefik-setup)
    sudo rm -f "$croot/traefik/dynamic/"user-*.yml
    local uf n=0
    for uf in local/proxy.d/*.yml; do
        [[ -e "$uf" ]] || break
        sudo install -m 600 "$uf" "$croot/traefik/dynamic/user-$(basename "$uf")"; n=$((n+1))
    done
    (( n )) && info "$n user proxy file(s) from local/proxy.d applied"
    ok "traefik config generated ($acmeenv certificates, domain $domain)"
    # static config only loads at container start; a content change on a
    # running traefik needs an explicit restart or it silently stays stale
    posthash=$(sudo cat "$croot/traefik/traefik.yml" "$croot/traefik/dynamic/00-mediastack.yml" 2>/dev/null | sha256sum)
    if [[ "$prehash" != "$posthash" ]] \
        && sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$(svc_cname traefik)"; then
        info "config changed — restarting traefik to load it"
        sudo docker restart "$(svc_cname traefik)" >/dev/null \
            && ok "traefik restarted" \
            || wfail "traefik restart failed — restart it manually: sudo docker restart $(svc_cname traefik)"
    fi
}

# hostname map is discovered from the fragments' own router labels
# (${X_HOST:-default}), so it self-maintains as services are added
traefik_host_vars() {
    grep -rhoE '\$\{[A-Z0-9_]+_HOST:-[a-z0-9-]+\}' compose.d/ \
        | sed -E 's/^\$\{([A-Z0-9_]+_HOST):-([a-z0-9-]+)\}$/\1 \2/' | sort -u
    echo "TRAEFIK_DASH_HOST dash"
}

cmd_traefik_hosts() {
    [[ -t 0 ]] || die "traefik-setup --hosts needs a terminal."
    local domain; domain=$(env_get TRAEFIK_DOMAIN)
    [[ -n "$domain" ]] || die "Run './mediastack.sh traefik-setup' first — no domain configured yet."
    hr "Service hostnames"
    explain "Pick each service's address" \
"Enter keeps the name shown in [brackets]. Names must be a single DNS
label: letters, numbers, hyphens (not first or last). The wildcard
certificate covers any choice — renames are free."
    local var def cur val
    local -A chosen
    # map on fd 3: ask() must keep stdin for the person's answers
    while read -r var def <&3; do
        cur=$(env_get "$var"); cur=${cur:-$def}
        while :; do
            ask HV "  ${var%_HOST} -> https://?.$domain" "$cur"; val="$REPLY_VAL"
            [[ "$val" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] \
                || { warn "'$val' is not a valid DNS label — lowercase letters, numbers, hyphens only"; continue; }
            if [[ -n "${chosen[$val]:-}" ]]; then
                warn "'$val' is already taken by ${chosen[$val]} — pick another"
                continue
            fi
            break
        done
        chosen[$val]="${var%_HOST}"
        env_set "$var" "$val"
    done 3< <(traefik_host_vars)
    traefik_gen   # the dashboard hostname lives in the generated config
    info "Apply with: ./mediastack.sh up"
    info "(services whose name changed are recreated; renaming a VPN'd service recreates gluetun — a brief tunnel bounce)"
}

cmd_traefik_certs() {
    [[ -t 0 ]] || die "traefik-setup --certs needs a terminal."
    local cur acmef stored="(none issued yet)"
    cur=$(env_get ACME_ENV production)
    acmef="$(env_get CONFIG_ROOT)/traefik/acme/acme.json"
    if sudo test -s "$acmef" 2>/dev/null; then
        sudo grep -q "acme-staging" "$acmef" && stored=staging || stored=production
    fi
    hr "Certificate environment"
    info "Setting: $cur — certificates in the store: $stored"
    explain "Real or testing certificates?" \
"  production  real certificates, trusted by every browser. Let's
              Encrypt allows only 5 identical ones per week, so
              repeated install testing can lock you out for days.
  staging     unlimited test certificates. Browsers show a warning
              you can click through — everything else works the same.
Switching either way is safe: the stack resets the certificate store,
restarts traefik, and the new environment reissues automatically."
    ask AV "Certificate environment [production/staging]" "$cur"
    case "$REPLY_VAL" in production|staging) env_set ACME_ENV "$REPLY_VAL" ;; *) die "Expected 'production' or 'staging'." ;; esac
    traefik_gen
}

cmd_traefik_setup() {
    svc_enabled traefik || die "traefik is not enabled. Enable it first: ./mediastack.sh enable traefik"
    if [[ "${1:-}" == --hosts ]]; then cmd_traefik_hosts; return; fi
    if [[ "${1:-}" == --certs ]]; then cmd_traefik_certs; return; fi
    traefik_ensure --reconfigure
    info "Apply with: ./mediastack.sh up   (recreates traefik if config changed)"
    info "Rename service addresses any time: ./mediastack.sh traefik-setup --hosts"
}

main "$@"
