#!/usr/bin/env bash
# lib/configure.sh — the interactive setup wizard (`configure`): timezone,
# roots (and moving a root's contents when its path changes), services, VPN,
# secrets and the update schedule. Sourced by the entrypoint; relies on
# lib/common.sh (prompts, env access) and the entrypoint's service helpers and
# provision() at call time.

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
        # a root that moves takes its contents with it (or says why not)
        [[ -n "$cur" && "$(abspath "$cur")" != "$val" ]] && { move_root_contents "$var" "$(abspath "$cur")" "$val" || continue; }
        env_set "$var" "$val"
        env_set "${var}_SOURCE" "$(findmnt -rn -o SOURCE --target "$val")"
        ok "$var = $val"
        break
    done
}

move_root_contents() { # move_root_contents VAR old new -> 0 proceed with new, 1 keep old
    # Called when a root's path changes. Anything at the old path is the
    # user's state: it moves with the root, stays behind on purpose (noted in
    # .env as <VAR>_PREVIOUS so doctor keeps pointing at it), or the change is
    # abandoned. DATA_ROOT is never moved by this script — a media library is
    # a human-sized decision — but it gets the same warning.
    local var="$1" old="$2" new="$3" size n choice
    sudo test -d "$old" || return 0
    n=$(sudo find "$old" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
    (( n > 0 )) || return 0
    size=$(sudo du -sh "$old" 2>/dev/null | cut -f1)
    warn "$var is moving: $old -> $new, and the old path is not empty ($n $( (( n == 1 )) && echo entry || echo entries), $size)."
    if [[ "$var" == DATA_ROOT ]]; then
        explain "Media stays where it is" \
"This script never moves a media library: it is usually huge, often on a
NAS, and the arrs know it by path. Move or re-mount it yourself first,
then enter the path here.
  keep   keep $var = $old (recommended unless the media is already at the new path)
  new    use $new; the old path is noted in .env and doctor keeps reminding you"
        ask MV "Choice [keep/new]" "keep"; choice="$REPLY_VAL"
        case "$choice" in
            new)  env_set "${var}_PREVIOUS" "$old"; return 0 ;;
            keep) return 1 ;;
            *)    die "Unknown choice '$choice' — expected keep or new." ;;
        esac
    fi
    explain "What happens to the existing contents?" \
"  move   copy everything to $new, verify, remove the old copy
         (the stack is stopped first if it is running; start it after: up)
  leave  start empty at the new path; the old path is noted in .env and
         doctor warns until it is gone
  keep   keep $var = $old and change nothing"
    ask MV "Choice [move/leave/keep]" "keep"; choice="$REPLY_VAL"
    case "$choice" in
        keep)  return 1 ;;
        leave) env_set "${var}_PREVIOUS" "$old"; info "$old left in place — see doctor"; return 0 ;;
        move)  ;;
        *)     die "Unknown choice '$choice' — expected move, leave or keep." ;;
    esac
    # no merge semantics: the new path must be empty, or the move is refused
    if (( $(sudo find "$new" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l) > 0 )); then
        fail "$new is not empty — a move needs an empty destination. Empty it (or pick another path) and re-enter; $var stays at $old for now."
        return 1
    fi
    if [[ -n "$(c_inspect_all; jq -r '.[] | select(.State.Status=="running") | .Name' <<<"$INSPECT_JSON")" ]]; then
        info "stopping the stack for a consistent move..."; DC stop >/dev/null
    fi
    if [[ "$(fsdev_of "$old")" == "$(fsdev_of "$new")" ]]; then
        sudo find "$old" -mindepth 1 -maxdepth 1 -exec mv -t "$new" {} + \
            || die "move failed — nothing was removed; $var still points at $old"
    else
        need_cmd rsync
        sudo rsync -a "$old"/ "$new"/ || die "copy failed — nothing was removed; $var still points at $old"
        # verify before deleting: a dry re-sync must have nothing to do
        if [[ -n "$(sudo rsync -a -n --itemize-changes "$old"/ "$new"/ | grep -v '^\.d\.\.t')" ]]; then
            die "copy verification failed — the old copy at $old is intact; $var still points at $old. Compare the two by hand before retrying."
        fi
        sudo find "$old" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    fi
    env_del "${var}_PREVIOUS"
    ok "$var contents moved to $new ($n $( (( n == 1 )) && echo entry || echo entries), $size)"
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
  * Default keeps it inside this folder like everything else — fine to
    start with; point it at the big disk later and the wizard tells you
    how the move works.
  * Keep torrents and media on the SAME drive or imports become slow
    full copies instead of instant hardlinks (checked below)." yes
    configure_root CACHE_ROOT "Cache directory" \
"Disposable data: image caches, metadata, the search index. Losing it
costs a regeneration, nothing more. Network storage is fine." yes
    configure_root TRANSCODE_ROOT "Transcode directory" \
"Where Jellyfin (and any other transcoding app) writes video segments while
someone is watching: a few GB per concurrent stream, written and read back
at the video's bitrate, deleted when the stream ends.
  * Local SSD is right. A network share here stutters playback — every
    segment crosses the wire twice.
  * Have RAM to spare? A tmpfs mount (e.g. 4G) is the fastest option and
    empties itself on reboot.
  * Nothing here is kept or backed up." yes
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
    done < <(grep -rhoE '\$\{[A-Z0-9_]+_(UID|UPDATE)[^}]*\}' docker-compose.yml compose.d/ "$CUSTOM_DIR" 2>/dev/null \
             | sed -E 's/\$\{([A-Z0-9_]+).*/\1/' | sort -u)

}

_configure_services() {
    # -- services (à la carte)
    render
    # a curated preset, kept beside its description below — not discovery
    # (status/backup/doctor/update never need a list edited), so not a label
    local STD="gluetun qbittorrent sonarr radarr prowlarr jellyfin meilisearch jellysearch seerr"
    # a re-run keeps what is enabled unless asked otherwise: option 0 exists
    # (and is the default) only when something is enabled already
    local cur_list cur_n=0 def=1
    cur_list=$(env_get COMPOSE_PROFILES)
    [[ -n "$cur_list" ]] && { cur_n=$(tr ',' '\n' <<<"$cur_list" | grep -c .); def=0; }
    explain "Services" \
"Pick exactly what runs — anything, à la carte. Dependencies are handled
for you (picking qBittorrent brings the VPN; JellySearch brings its
search engine). Change any of this later with enable/disable." \
"  1) standard    the recommended setup: VPN, qBittorrent, Sonarr, Radarr," \
"                 Prowlarr, Jellyfin + instant search, request site." \
"                 No proxy: services answer on http://<host>:<port>; add" \
"                 HTTPS names later with: enable traefik + traefik-setup" \
"  2) everything  all $(svc_managed | wc -l) services" \
"  3) custom      yes/no through each service" \
"$( (( cur_n )) && echo "  0) keep current: $cur_n enabled ($(tr ',' ' ' <<<"$cur_list"))" )"
    local mode sel="" cur_en s d dp
    ask SVC_MODE "Choice" "$def"; mode="$REPLY_VAL"
    cur_en=",$cur_list,"
    case "$mode" in
        0) (( cur_n )) || die "Nothing is enabled yet — pick 1, 2 or 3."
           ok "Keeping the current $cur_n service(s): $cur_list"; return 0 ;;
        1) sel="$STD" ;;
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
        *) die "Unknown choice '$mode' — expected 0, 1, 2 or 3." ;;
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
    local expr="" day
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
    cmd_apply_timer

    echo; hr "Configure complete"
    cat <<EOF
Next steps:
  1. ./mediastack.sh up          start everything
  2. ./mediastack.sh doctor      verify the deployment
  3. ./mediastack.sh leak-test   prove the VPN cannot leak
Then open the apps (URLs and ports: ./mediastack.sh status) and connect them to each other.
EOF
}
