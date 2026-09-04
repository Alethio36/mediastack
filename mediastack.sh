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
SCRIPT_SCHEMA=12

# Shared base: output primitives + .env access (see lib/common.sh).
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/frontdoor.sh
source "$SCRIPT_DIR/lib/frontdoor.sh"
# shellcheck source=lib/integrations.sh
source "$SCRIPT_DIR/lib/integrations.sh"

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
migrate_env_8_to_9() {
    # watchstate joins as an official service
    if ! grep -qE '^WATCHSTATE_UID=' "$ENV_FILE"; then
        local wmax
        wmax=$(grep -E '_UID=[0-9]+' "$ENV_FILE" | cut -d= -f2 | sort -n | tail -1)
        env_set WATCHSTATE_UID "$(( ${wmax:-$(env_get UID_BASE 13000)} + 1 ))"
        info "New service variable WATCHSTATE_UID -> $(env_get WATCHSTATE_UID)"
    fi
    grep -qE '^WATCHSTATE_UPDATE=' "$ENV_FILE" || env_set WATCHSTATE_UPDATE true
}
migrate_env_9_to_10() {
    if ! grep -qE '^NAVIDROME_UID=' "$ENV_FILE"; then
        local nmax
        nmax=$(grep -E '_UID=[0-9]+' "$ENV_FILE" | cut -d= -f2 | sort -n | tail -1)
        env_set NAVIDROME_UID "$(( ${nmax:-$(env_get UID_BASE 13000)} + 1 ))"
        info "New service variable NAVIDROME_UID -> $(env_get NAVIDROME_UID)"
    fi
    grep -qE '^NAVIDROME_UPDATE=' "$ENV_FILE" || env_set NAVIDROME_UPDATE true
}
migrate_env_10_to_11() {
    # two reading/listening servers join; adopt their UID/UPDATE vars
    local svc var last
    for svc in AUDIOBOOKSHELF KAVITA; do
        var="${svc}_UID"
        if ! grep -qE "^${var}=" "$ENV_FILE"; then
            last=$(grep -E '_UID=[0-9]+' "$ENV_FILE" | cut -d= -f2 | sort -n | tail -1)
            env_set "$var" "$(( ${last:-$(env_get UID_BASE 13000)} + 1 ))"
            info "New service variable $var -> $(env_get "$var")"
        fi
        grep -qE "^${svc}_UPDATE=" "$ENV_FILE" || env_set "${svc}_UPDATE" true
    done
}
migrate_env_11_to_12() {
    if ! grep -qE '^LAZYLIBRARIAN_UID=' "$ENV_FILE"; then
        local lmax
        lmax=$(grep -E '_UID=[0-9]+' "$ENV_FILE" | cut -d= -f2 | sort -n | tail -1)
        env_set LAZYLIBRARIAN_UID "$(( ${lmax:-$(env_get UID_BASE 13000)} + 1 ))"
        info "New service variable LAZYLIBRARIAN_UID -> $(env_get LAZYLIBRARIAN_UID)"
    fi
    grep -qE '^LAZYLIBRARIAN_UPDATE=' "$ENV_FILE" || env_set LAZYLIBRARIAN_UPDATE true
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
    sudo docker compose --project-directory "$SCRIPT_DIR" "${files[@]}" "$@"
}

compose_renders() { DC config >/dev/null; } # rc-only; compose errors pass through

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
svc_url() { # where a browser reaches the service, best effort
    local s="$1" sub port
    [[ "$s" == traefik ]] && { echo "-"; return; }   # it IS the https edge
    sub=$(env_get "$(uvar "$s")_HOST"); [[ -n "$sub" ]] || sub=$(svc_label "$s" mediastack.subdomain)
    if [[ -n "$sub" ]]; then echo "https://${sub}.$(env_get TRAEFIK_DOMAIN unset)"; return; fi
    port=$(svc_label "$s" mediastack.port)
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
  status [svc]   Overview table of every service (state, health, version,
                 URL) — or a deep view of one (mounts, uid, recent logs).
  logs SVC       Follow one service's logs.
Maintain
  update         CONTAINER IMAGES: backup, then pull + apply (respects
                 per-service toggles and pins). Options: SVC (one service),
                 SVC --to TAG (step to an exact version and pin there),
                 --dry-run (preview), --now (skip deferral).
                 For mediastack itself, see: upgrade.
  apply-timer    Install/refresh the systemd timer from UPDATE_SCHEDULE.
  backup         Take a restore point now (cold: brief stop/start).
                 'backup verify [TS]' checks checksums and archives.
  restore        Restore configs+image from a restore point:
                 --service SVC | --all  [--from TIMESTAMP]
  rollback SVC   Shortcut: restore SVC from the newest restore point.
  unpin SVC      Release a pinned service back to normal updates.
  upgrade        MEDIASTACK ITSELF: git pull + .env migration. Container
                 images stay put — that's: update.
Connect
  wire           Connect the apps to each other — credentials, folders,
                 download clients, notifications, first-run setup.
                 Idempotent: re-run any time; anything you configured in a
                 GUI is never overwritten.
                 One app only: wire <qbit|arr|prowlarr|bazarr|apprise|
                 cleanuparr|lazylibrarian|jellyfin|seerr|wizarr>. Preview: wire --dry-run.
  invite         Mint a Wizarr invitation and print the ready-to-share URL.
                 Options: --expires 1|7|30 (default: never expires).
  credentials    Show the app logins wire created/stored.
  set-credentials Rotate a stored login everywhere it lives, atomically:
                 set-credentials <arr|qbit|jellyfin|pihole|traefik|all>;
                 'all' sets ONE password across the stack (Wizarr's
                 admin excluded).
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
  vpn [svc on|off]  Show or change which services run behind the VPN. No args
                 lists membership; 'vpn <svc> on|off' flips it (torrent clients
                 need --i-know to leave the tunnel). Apply with: up.
  fix-perms [s]  Repair config-dir ownership from the UID map.
Other
  new-service N  Scaffold service N into docker-compose.override.yml
                 (untracked, merged automatically, upgrade-safe).
  uninstall      Remove the stack (tiered: containers / users / configs).
  frontdoor-install  Install the OliveTin web panel over the safe verbs.
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
    for s in $(svc_managed); do
        svc_enabled "$s" && continue
        cn=$(svc_cname "$s")
        if [[ $(c_state "$cn") != absent ]]; then
            sudo docker rm -f -v "$cn" >/dev/null
            info "removed container for disabled service: $s"
        fi
    done
}

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
    render
    local gid vd nm vdeps=() stale=()
    mapfile -t vdeps < <(jq -r '.services | to_entries[]
        | select((.value.network_mode // "") == "service:gluetun") | .key' \
        <<<"$RENDERED_JSON" | sort)
    (( ${#vdeps[@]} )) || { warn "vpn guard: no service:gluetun dependents in the rendered config — nothing to verify"; return 0; }
    gid=$(sudo docker inspect --format '{{.Id}}' "$(svc_cname gluetun)" 2>/dev/null | tr -d '\n')
    [[ -n "$gid" ]] || die "vpn guard: cannot resolve the live gluetun container — VPN attachment unverifiable. Inspect gluetun, then re-run."
    for vd in "${vdeps[@]}"; do
        [[ "$(c_state "$(svc_cname "$vd")")" == running ]] || continue
        nm=$(sudo docker inspect --format '{{.HostConfig.NetworkMode}}' "$(svc_cname "$vd")" | tr -d '\n')
        [[ "$nm" == "container:$gid" ]] || stale+=("$vd")
    done
    if (( ${#stale[@]} )); then
        warn "gluetun was recreated — dependents still joined to the old gluetun (dead tunnel): ${stale[*]}"
        info "re-pinning them onto the live gluetun..."
        DC up -d --force-recreate --no-deps "${stale[@]}"
        for vd in "${stale[@]}"; do
            nm=$(sudo docker inspect --format '{{.HostConfig.NetworkMode}}' "$(svc_cname "$vd")" 2>/dev/null | tr -d '\n')
            [[ "$nm" == "container:$gid" ]] && continue
            notify ops "Mediastack VPN re-pin FAILED" "VPN dependents detached from gluetun and re-pin FAILED: **${stale[*]}**\nFix now: \`./mediastack.sh up\` then \`./mediastack.sh leak-test\`" failure
            die "vpn guard: $vd is still not joined to the live gluetun after recreate — VPN egress is broken. Fix this before anything else."
        done
        ok "re-pinned ${#stale[@]} dependent(s) onto the live gluetun"
    fi
    ok "VPN attachment verified: ${#vdeps[@]} dependent(s) on the live gluetun"
}

cmd_up()   {
    load_env; require_mounts; reconcile_disabled
    vpn_gen   # materialise per-service VPN membership before compose renders
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
            *)           svc="$a" ;;
        esac
    done
    [[ -n "$svc" ]] || die "usage: logs <service> [--no-follow]"
    DC logs "${follow[@]}" --tail=100 "$svc"
}

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
        enabled)    names=$(local s; for s in $(svc_managed); do svc_enabled "$s" && echo "$s"; done | sort) ;;
        disabled)   names=$(local s; for s in $(svc_managed); do svc_enabled "$s" || echo "$s"; done | sort) ;;
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
    hr "Mediastack status"
    printf "%-14s %-5s %-5s %-9s %-10s %-12s %-8s %-9s %s\n" SERVICE PORT VPN STATE HEALTH VERSION PINNED UPTIME URL
    local s cn pin vpn port rec bvpn
    bvpn=$(vpn_base_json)   # base (pre-overlay) labels = recommended VPN settings
    for s in $(svc_managed); do
        svc_enabled "$s" || continue
        cn=$(svc_cname "$s")
        pin=no; [[ -s "$PINS_FILE" ]] && grep -q "^  $s:" "$PINS_FILE" && pin="${C_YLW}yes${C_RST}"
        vpn=off; [[ $(svc_label "$s" mediastack.vpn) == "true" ]] && vpn=on
        [[ "$s" == gluetun ]] && vpn=self   # gluetun IS the tunnel, not behind it
        # flag a toggle-enabled service that's been moved off its recommended setting
        if [[ $(jq -r --arg s "$s" '.services[$s].labels["mediastack.vpntoggle"]//""' <<<"$bvpn") == "true" ]]; then
            rec=$(vpn_onoff "$(jq -r --arg s "$s" '.services[$s].labels["mediastack.vpn"]//"false"' <<<"$bvpn")")
            [[ "$vpn" == "$rec" ]] || vpn+="*"
        fi
        port=$(svc_label "$s" mediastack.port); port=${port:--}
        printf "%-14s %-5s %-5s %-9s %-10s %-12s %-8s %-9s %s\n" \
            "$s" "$port" "$vpn" "$(c_state "$cn")" "$(c_health "$cn")" "$(c_version "$cn" | cut -c1-12)" "$pin" "$(c_uptime "$cn")" "$(svc_url "$s")"
    done
    echo
    info "VPN: on = via the tunnel, off = direct, self = the tunnel itself · * = changed from recommended · change: ./mediastack.sh vpn"
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

    info "Stopping stack for a consistent snapshot... (all services briefly stop; ~20-40s)"
    DC stop >/dev/null
    local rc=0
    for s in $(svc_managed); do
        [[ $(svc_label "$s" mediastack.config) == "true" && -d "$croot/$s" ]] || continue
        sudo tar -C "$croot" -czf "$dest/$s.tar.gz" "$s" || { fail "tar failed for $s"; rc=1; }
    done
    sudo cp "$ENV_FILE" "$dest/env"; sudo chmod 600 "$dest/env"
    [[ -s "$PINS_FILE" ]] && sudo cp "$PINS_FILE" "$dest/pins.yml"
    ( cd "$dest" && sudo sh -c 'sha256sum * > SHA256SUMS' )
    info "Restarting stack... (waiting on gluetun health; can take up to ~1min)"
    DC up -d >/dev/null
    if (( rc == 0 )); then ok "Restore point complete: $dest"
    else
        notify ops "Mediastack backup FAILED" "Restore point \`$dest\` finished with errors — **do not trust it**. Inspect on the host." failure
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
    local d
    all=()
    for d in "$broot"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]; do
        [[ -d "$d" ]] && all+=("$(basename "$d")")
    done
    mapfile -t all < <(printf '%s\n' "${all[@]}" | sort -r)
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
    local svc="" all_svcs=0 from=""
    while [[ $# -gt 0 ]]; do case "$1" in
        --service) svc="$2"; shift 2 ;;
        --all) all_svcs=1; shift ;;
        --from) from="$2"; shift 2 ;;
        *) die "Unknown restore arg '$1' (usage: restore --service SVC|--all [--from TS])" ;;
    esac; done
    (( all_svcs )) || [[ -n "$svc" ]] || die "usage: restore --service SVC | --all  [--from TIMESTAMP]"
    local broot; broot=$(env_get BACKUP_ROOT)
    [[ -n "$from" ]] || from=$(ls -1 "$broot" 2>/dev/null | tail -1)
    [[ -n "$from" && -d "$broot/$from" ]] || die "No restore point found. Available: $(ls -1 "$broot" 2>/dev/null | tr '\n' ' ')"
    info "Restoring from $from"
    local targets; if (( all_svcs )); then targets=$(svc_managed); else targets="$svc"; fi
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

# `DC up` during an update, with the health verdict delegated to the script's
# own health gate. Compose's depends_on: service_healthy gating fails `up`
# (non-zero, fatal under set -e) the moment a service is briefly unhealthy on
# recreate — e.g. a new image mid first-run migration — aborting the update
# before vpn_reattach_guard and the tolerant 300s health gate ever run. We
# therefore treat ONLY a health-gate abort as non-fatal and let the gate
# adjudicate; every other up failure (broken config, image pull, etc.) still
# dies loudly with compose's message. Never swallow a non-health failure.
apply_up() {
    local rerr rc
    rerr=$(mktemp)
    if DC up -d "$@" 2>"$rerr"; then
        cat "$rerr" >&2; rm -f "$rerr"; return 0
    fi
    rc=$?
    cat "$rerr" >&2   # always surface compose's output
    if grep -qE 'dependency failed to start|is unhealthy|health' "$rerr"; then
        warn "compose aborted the apply on a transient health check — deferring the verdict to the health gate below"
        rm -f "$rerr"; return 0
    fi
    rm -f "$rerr"
    die "update: 'up' failed for a non-health reason (rc=$rc) — see compose's message above. Nothing further was applied."
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
    info "pulling from registries — the slowest step on a full update; a minute or two is normal"
    local after changed=()
    local -A before=()
    for s in "${targets[@]}"; do before[$s]=$(c_version "$(svc_cname "$s")"); done
    DC pull "${targets[@]}"
    hr "Applying"
    # Cascade: recreating gluetun gives it a new container ID, and compose does
    # NOT recreate its network_mode:service:gluetun borrowers when only their
    # namespace-host changed — they would be left on the dead ID (the ghost).
    # So when gluetun is in this update's target set, expand the recreate to
    # its enabled borrowers and --force-recreate the group together, the way a
    # dependency-aware updater would. Prevention: the borrowers never come up
    # stale, so there is no repair window. vpn_reattach_guard still runs after
    # as the catch-all for drift arriving via any OTHER path (out-of-band
    # compose, reboots) — this only closes the update path's own recreate.
    if printf '%s\n' "${targets[@]}" | grep -qx gluetun; then
        # gluetun is in this run: recreate it AND its borrowers as one
        # force-recreated group so no borrower is left on the old ID. Other
        # targets apply normally in the same call — only the VPN group is
        # forced, to avoid needlessly recreating unrelated services.
        render
        local grp=(gluetun) b
        while IFS= read -r b; do
            [[ -z "$b" ]] && continue
            svc_enabled "$b" && grp+=("$b")
        done < <(jq -r '.services | to_entries[]
            | select((.value.network_mode // "") == "service:gluetun") | .key' \
            <<<"$RENDERED_JSON")
        info "gluetun is updating — recreating its ${#grp[@]}-member VPN group together so none is orphaned"
        apply_up --remove-orphans --force-recreate "${grp[@]}"
        apply_up --remove-orphans "${targets[@]}"
    else
        apply_up --remove-orphans "${targets[@]}"
    fi
    sudo docker image prune -f >/dev/null

    vpn_reattach_guard

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
        notify ops "Mediastack update FAILED" "Unhealthy after update: **${bad[*]}**\nRoll back: \`./mediastack.sh rollback <service>\`" failure
        exit 1
    fi
    ok "All updated services healthy."
    (( ${#changed[@]} )) && notify ops "Mediastack updated" "$(printf '`%s`\\n' "${changed[@]}")" success

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
            notify ops "recyclarr v$rc_latest available" "Stack pins major **v$rc_pin**. Review upstream breaking changes, then bump \`compose.d/recyclarr.yml\`." warning
        fi
        echo
        cmd_trash_sync || { fail "update pipeline: trash-sync step failed (updates themselves succeeded — see FAIL lines above)"
                            notify ops "Mediastack trash-sync FAILED" "Nightly TRaSH sync failed — updates themselves succeeded.\nInspect: \`./mediastack.sh trash-sync\`" failure
                            exit 1; }
    fi
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

# --- doctor section checks (one helper per `hr "doctor: …"` block; each self-contained,
#     reporting via ok/warn/info/d_fail into the file-scope D_FAILS accumulator). ---
_doctor_environment() {
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

}

_doctor_containers() {
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

}

_doctor_permissions() {
    hr "doctor: permissions"
    # Two independent questions, deliberately not conflated:
    #   1. Can the app write its own config? (the true invariant — probed live)
    #   2. Is anything mis-owned, and does it matter? (reported, tiered)
    # Ownership drift confined to regenerable paths (cache/logs/backups) is
    # expected for images that ignore PUID and run as root — their background
    # tasks (update checks, log rotation) write those files as root. That is a
    # WARN, not a FAIL. Drift in actual config files is a FAIL. The writable
    # probe decides real health regardless, and resolves the container's true
    # mount path (which is not always /config — e.g. kavita uses /kavita/config).
    local croot gid v uid s
    croot=$(env_get CONFIG_ROOT); gid=$(env_get MEDIA_GROUP_GID)
    # path segments whose ownership is cosmetic (regenerable, non-config)
    local ephemeral_re='/(cache|cache-long|logs?|te?mp|[Bb]ackups?)(/|$)'
    for s in $(svc_managed); do
        [[ $(svc_label "$s" mediastack.config) == "true" ]] || continue
        v="$(uvar "$s")_UID"; uid=$(env_get "$v"); [[ -n "$uid" && -d "$croot/$s" ]] || continue

        # Ownership audit, tiered: split drift into config vs ephemeral.
        local misowned cfgbad="" ephbad="" f
        misowned=$(sudo find "$croot/$s" \( -not -user "$uid" -o -not -group "$gid" \) 2>/dev/null || true)
        if [[ -n "$misowned" ]]; then
            while IFS= read -r f; do
                [[ -z "$f" ]] && continue
                if [[ "${f#"$croot/$s"}" =~ $ephemeral_re ]]; then ephbad+="$f"$'\n'; else cfgbad+="$f"$'\n'; fi
            done <<<"$misowned"
        fi
        if [[ -n "$cfgbad" ]]; then
            d_fail "$s: config files not owned $uid:$gid" "the app cannot write its own config" "./mediastack.sh fix-perms $s"
        elif [[ -n "$ephbad" ]]; then
            warn "$s: $(grep -c . <<<"$ephbad") root-owned file(s) in cache/logs/backups — expected for a root-by-image app, cosmetic (clear with: ./mediastack.sh fix-perms $s)"
        fi

        # True invariant: can the app write its config? Probe live, from inside
        # the container, at its REAL mount path. This decides pass/fail; runs
        # regardless of ownership tier above (a config FAIL already fired if
        # warranted, but writability is the definitive check).
        local cn dest out rc
        cn=$(svc_cname "$s")
        if [[ $(c_state "$cn") == running ]]; then
            dest=$(sudo docker inspect "$cn" 2>/dev/null \
                   | jq -r --arg src "$croot/$s" '.[0].Mounts[]? | select(.Source==$src) | .Destination' | head -1)
            if [[ -n "$dest" ]]; then
                out=$(sudo docker exec "$cn" test -w "$dest" 2>&1) && rc=0 || rc=$?
                if (( rc == 0 )); then ok "$s config writable from inside the container"
                elif grep -q "executable file not found" <<<"$out"; then
                    info "$s: image has no probe tooling — writability unverified"
                else
                    d_fail "$s cannot write $dest from inside its container" "the app cannot persist settings" "./mediastack.sh fix-perms $s && ./mediastack.sh logs $s"
                fi
            else info "$s: config not bind-mounted in running container — skipped"; fi
        elif [[ -z "$cfgbad" ]]; then ok "$s config ownership OK (write probe skipped: not running)"; fi
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

}

_doctor_resources() {
    hr "doctor: host resources"
    local croot; croot=$(env_get CONFIG_ROOT)
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

}

_doctor_storage() {
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

}

_doctor_neighbours() {
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

}

_doctor_vpn_backups() {
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
        elif [[ -z "$dbad" ]]; then ok "all VPN'd services routed through the gluetun tunnel"
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
        local acmef; acmef="$(env_get CONFIG_ROOT)/traefik/acme/acme.json"
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

}

_doctor_apps() {
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

}

_doctor_runtime_audit() {
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
        # docker's daemon locates the PID column via the ps TITLE row, so the
        # format must keep its headers; awk drops the title line
        uids=$(sudo docker top "$cn" -o uid,pid 2>/dev/null | awk 'NR>1{print $1}' | sort -u | tr '\n' ' ' || true)
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
            iface=$(qb_api /app/preferences | jq -r '.current_network_interface // .network_interface // empty' 2>/dev/null || true)
            [[ "$iface" == tun0 ]] && ok "qBittorrent transfers bound to tun0" \
                || warn "qBittorrent is NOT bound to tun0 (currently: '${iface:-unset}') — fix: ./mediastack.sh wire qbit"
        else
            warn "could not sign in to qBittorrent to verify the tun0 bind"
        fi
    fi

}

cmd_doctor() {
    load_env; need_cmd jq; render
    _doctor_environment
    _doctor_containers
    _doctor_permissions
    _doctor_resources
    _doctor_storage
    _doctor_neighbours
    _doctor_vpn_backups
    _doctor_apps
    _doctor_runtime_audit
    echo
    if (( D_FAILS )); then
        fail "doctor: $D_FAILS problem(s) — fixes listed above."
        notify ops "Mediastack doctor: $D_FAILS problem(s)" "Run \`./mediastack.sh doctor\` on the host for the findings and fixes." failure
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
    else base="http://$(hostname -I 2>/dev/null | awk '{print $1}'):$(svc_label wizarr mediastack.port)"; fi
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
    local name="${1:?usage: new-service <name>}"
    [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "Service names: lowercase letters, digits, dashes."
    load_env
    svc_exists "$name" && die "A service '$name' already exists in the rendered stack."
    local f="docker-compose.override.yml" had_file=0 snap=""
    if [[ -e "$f" ]]; then
        had_file=1; snap=$(cat "$f")
        grep -qE "^  ${name}:" "$f" && die "$f already defines '$name'."
        grep -qE '^services:' "$f" || die "$f exists but has no 'services:' key — add the service there yourself."
    else
        printf '# Your services live here — untracked, merged automatically, upgrade-safe.\nservices:\n' > "$f"
    fi
    sed -e "s/__NAME__/${name}/g" -e "s/__UPPER__/$(uvar "$name")/g" >> "$f" <<'EOF'

  # __NAME__ — fill in image/ports/volumes, then:
  #   ./mediastack.sh configure   (adopts the new UID/UPDATE vars)
  #   ./mediastack.sh enable __NAME__
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
      com.centurylinklabs.watchtower.enable: "false"
      mediastack.managed: "true"
      mediastack.vpn: "false"
      mediastack.config: "true"
    networks: [mediastack]
    logging:
      driver: json-file
      options:
        max-size: ${LOG_MAX_SIZE:-10m}
        max-file: ${LOG_MAX_FILE:-3}
    restart: unless-stopped
EOF
    # the scaffold must render before it is kept: CHANGEME image is fine at
    # config time, structural YAML mistakes are not
    if ! compose_renders; then
        if (( had_file )); then printf '%s' "$snap" > "$f"; else rm -f "$f"; fi
        die "The scaffold broke compose rendering — reverted. See compose's message above."
    fi
    ok "Scaffolded '$name' in $f — edit it, then run: ./mediastack.sh configure && ./mediastack.sh enable $name"
    info "Nothing else to edit: $f is untracked and merges automatically."
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
        list)         cmd_list "$@" ;;
        logs)         cmd_logs "$@" ;;
        update)       cmd_update "$@" ;;
        apply-timer)  cmd_apply_timer ;;
        vpn-guard)    cmd_vpn_guard "$@" ;;
        backup)       if [[ "${1:-}" == verify ]]; then shift; cmd_backup_verify "$@"; else cmd_backup "$@"; fi ;;
        restore)      cmd_restore "$@" ;;
        rollback)     cmd_rollback "$@" ;;
        unpin)        cmd_unpin "$@" ;;
        doctor)       cmd_doctor ;;
        leak-test)    cmd_leak_test "$@" ;;
        vpn)          cmd_vpn "$@" ;;
        vpn-apply)    cmd_vpn_apply "$@" ;;
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
        frontdoor-install) cmd_frontdoor_install "$@" ;;
        frontdoor-refresh) cmd_frontdoor_refresh ;;
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
    DC pull -q recyclarr 2>/dev/null \
        && info "recyclarr image: pinned tag up to date" \
        || warn "recyclarr image pull failed (registry unreachable?) — syncing with the local image"
    local slog rc summary
    slog=$(mktemp)
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
    sudo docker compose --project-directory "$SCRIPT_DIR" -f docker-compose.yml \
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
    for a in "$@"; do [[ "$a" == --i-know ]] && iknow=1; done
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
