#!/usr/bin/env bash
# lib/questionnaire.sh — configure's questions (docs/design-install.md, "The
# questionnaire"). It asks and records — and does nothing else: it writes
# .env and local/state, never runs sudo or Docker (rendering the catalogue
# aside), never makes users or folders. configure runs it as its own
# process (the internal `questionnaire` verb) and applies the answers after:
# folders, users, timers, the panel. test-questions holds it to that.
#   exit 0    every question answered
#   exit 130  cancelled (Ctrl-C): nothing applied; the answers recorded so far
#             are next time's defaults (folder changes are not — see below)
#   exit 3    no terminal to ask on
# Quick or full: every question either has a recommended answer (quick takes
# it and says so) or has none (quick asks it too). Sourced by the entrypoint;
# relies on lib/common.sh (prompts, env access) and the entrypoint's service
# helpers at call time.

Q_MODE=full                      # quick | full — the first question
Q_FOR=""                         # enable: only these services' questions (space-separated), quick
declare -gA Q_ROOT=()            # VAR -> the folder chosen for it
declare -gA Q_ROOT_MOVE=()       # VAR -> what happens to the old folder's contents: "" (nothing there) | move | leave | new
ROOTS_STATE=roots                # state key: the folders chosen, applied by configure (roots_apply)
PANEL_STATE=panel-install        # state key: install the web panel after provisioning
# shellcheck disable=SC2034  # set by services/authentik/email.sh, read by lib/configure.sh
EMAIL_STATE=email-changed        # state key: email settings changed — the portal's reset link follows them

q_quick() { [[ "$Q_MODE" == quick ]]; }
q_took() { info "$1: $2 (recommended)"; }   # q_took TITLE ANSWER — quick took the recommended answer, and says so

cmd_questionnaire() { # questionnaire [--fresh | --for SVC...] — configure's questions, or (--for) those of services enable brings
    [[ -t 0 ]] || { echo "${C_RED}ERROR${C_RST} configure asks questions — run it in a terminal" >&2; exit 3; }
    questionnaire_run "$@"
}

questionnaire_run() { # the questions, in order; each section records its own answers
    # shellcheck disable=SC2034  # read by _configure_services and _configure_schedule
    CONFIGURE_FRESH=0
    case "${1:-}" in
        "")      ;;
        --fresh) CONFIGURE_FRESH=1 ;;
        --for)   shift; [[ $# -gt 0 ]] || die "questionnaire --for: name the services"; Q_FOR=" $* "; questionnaire_for; return 0 ;;
        *)       die "unknown argument '$1' for 'questionnaire' (accepts: --fresh, --for SVC...)" ;;
    esac
    _configure_mode
    _configure_timezone
    _configure_roots
    _configure_selfheal
    _configure_services
    _configure_download_client
    _configure_vpn
    svc_hooks questions
    _configure_logins
    _configure_schedule
    _configure_panel_offer
}

questionnaire_for() { # enable's questions: what the services it brings need, quick — the rest of the stack is answered
    # shellcheck disable=SC2034  # read by every section's q_quick
    Q_MODE=quick
    if [[ "$Q_FOR" == *" gluetun "* ]]; then _configure_vpn; fi
    _configure_download_client
    svc_hooks questions
    _configure_logins
}

_configure_mode() {
    explain "How much should configure ask?" \
"  1) quick   only what has no sensible default — the services, how people
             sign in, your VPN details; everything else takes the
             recommended answer, and the summary at the end shows them all
  2) full    every question, each with its recommended answer as the default"
    while true; do
        ask Q_MODE "Choice" 1
        case "$REPLY_VAL" in 1) Q_MODE=quick; break ;; 2) Q_MODE=full; break ;; *) fail "Pick 1 or 2." ;; esac
    done
}

# ---------------------------------------------------------------- folders --
# A folder answer is held in local/state until configure applies it — made,
# its old contents moved as answered, its mount recorded (roots_apply). A
# cancelled questionnaire leaves .env pointing where it did: half a move
# would point the stack at an empty folder.
root_problem() { # root_problem PATH allow_network(yes/no) -> why PATH cannot be this folder ("" when it can)
    local val="$1" allow_net="$2" p="$1" fs
    # a backslash is the key beside Enter: kept, it named a folder "\"
    # (found live: CACHE_ROOT=.../mediastack/\, and every later use broke)
    if [[ "$val" == *\\* ]]; then
        echo "'$val' has a backslash in it — a slip of the key beside Enter? Paths use '/'. Enter it again."; return 0
    fi
    # Network shares must be mounted BEFORE this runs — the mount identity is
    # recorded and guarded forever after. Matched as text, never as a pattern:
    # a path went into a regex once, and a backslash broke grep.
    if awk -v p="$val" '$1 !~ /^#/ && $2 == p { f = 1 } END { exit !f }' "$FSTAB" 2>/dev/null && ! findmnt -rn "$val" >/dev/null 2>&1; then
        echo "'$val' is listed in /etc/fstab but NOT currently mounted.
  Continuing would record the wrong disk as this path's home. Fix first:
  sudo mount '$val'   (then re-enter the path here)"; return 0
    fi
    # a folder not made yet lives on the filesystem of its nearest existing parent
    while [[ ! -e "$p" ]]; do p=$(dirname "$p"); done
    fs=$(fstype_of "$p")
    if [[ "$allow_net" == no && "$fs" =~ ^(nfs|nfs4|cifs|smb3)$ ]]; then
        echo "'$val' is on a network share ($fs). App databases (SQLite)
  corrupt on network storage — this path must be a local disk. Your media
  can still live on the NAS via DATA_ROOT."
    fi
}

root_entries() { # root_entries DIR -> how many entries it holds; ? when it cannot be read without sudo
    [[ -d "$1" ]] || { echo 0; return 0; }
    [[ -r "$1" && -x "$1" ]] || { echo "?"; return 0; }
    find "$1" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l
}

configure_root() { # configure_root VAR title "explanation..." allow_network(yes/no) -> Q_ROOT[VAR], Q_ROOT_MOVE[VAR]
    local var="$1" title="$2" text="$3" allow_net="$4" cur val p rc fs e
    cur=$(env_get "$var")   # not set yet: the folder .env.example suggests
    [[ -n "$cur" ]] || cur=$(grep -E "^$var=" .env.example | sed -n 1p | cut -d= -f2-)
    cur=$(abspath "$cur")
    if q_quick && [[ -z "$(root_problem "$cur" "$allow_net")" ]]; then
        Q_ROOT[$var]=$cur; Q_ROOT_MOVE[$var]=""; q_took "$title" "$cur"; return 0
    fi
    explain "$title" "$text"
    while true; do
        ask "$var" "$title path" "$cur"; val=$(abspath "$REPLY_VAL")
        p=$(root_problem "$val" "$allow_net")
        [[ -z "$p" ]] || { fail "$p"; continue; }
        if [[ "$allow_net" == yes ]]; then
            e=$val; while [[ ! -e "$e" ]]; do e=$(dirname "$e"); done   # where it would live
            fs=$(fstype_of "$e")
            [[ "$fs" =~ ^(nfs|nfs4|cifs|smb3)$ ]] && info "Network share detected ($fs) — fine for this root."
        fi
        Q_ROOT_MOVE[$var]=""
        # a folder that moves takes its contents with it (or says why not)
        if [[ "$cur" != "$val" ]]; then
            rc=0; root_move_ask "$var" "$cur" "$val" || rc=$?
            case "$rc" in
                1) val=$cur; Q_ROOT_MOVE[$var]="" ;;   # keep: the folder stays where it was
                2) continue ;;                           # refused: asked again
            esac
        fi
        Q_ROOT[$var]=$val
        ok "$var = $val"
        break
    done
}

root_move_ask() { # root_move_ask VAR old new -> 0 proceed with new (Q_ROOT_MOVE[VAR] set), 1 keep old, 2 ask the path again
    # Anything at the old path is the user's state: it moves with the root,
    # stays behind on purpose (noted in .env as <VAR>_PREVIOUS so doctor keeps
    # pointing at it), or the change is abandoned. DATA_ROOT is never moved by
    # this script — a media library is a human-sized decision — but it gets
    # the same warning. The move itself is configure's (root_move_apply).
    local var="$1" old="$2" new="$3" n size choice
    n=$(root_entries "$old")
    [[ "$n" != 0 ]] || return 0
    size=$( { du -sh "$old" 2>/dev/null || true; } | cut -f1)
    warn "$var is moving: $old -> $new, and the old path is not empty ($n $( [[ "$n" == 1 ]] && echo entry || echo entries), ${size:-size unknown})."
    if [[ "$var" == DATA_ROOT ]]; then
        explain "Media stays where it is" \
"This script never moves a media library: it is usually huge, often on a
NAS, and the arrs know it by path. Move or re-mount it yourself first,
then enter the path here.
  keep   keep $var = $old (recommended unless the media is already at the new path)
  new    use $new; the old path is noted in .env and doctor keeps reminding you"
        ask MV "Choice (keep/new)" "keep"; choice="$REPLY_VAL"
        case "$choice" in
            new)  Q_ROOT_MOVE[$var]=new; return 0 ;;
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
    ask MV "Choice (move/leave/keep)" "keep"; choice="$REPLY_VAL"
    case "$choice" in
        keep)  return 1 ;;
        leave) Q_ROOT_MOVE[$var]=leave; return 0 ;;
        move)  ;;
        *)     die "Unknown choice '$choice' — expected move, leave or keep." ;;
    esac
    # no merge semantics: the new path must be empty (one configure cannot read
    # without sudo is checked again when the move runs)
    n=$(root_entries "$new")
    if [[ "$n" != 0 && "$n" != "?" ]]; then
        fail "$new is not empty — a move needs an empty destination. Empty it (or pick another path) and re-enter; $var stays at $old for now."
        return 2
    fi
    Q_ROOT_MOVE[$var]=move
}

_configure_roots() {
    # -- roots
    configure_root CONFIG_ROOT "Config directory" \
"Where every service keeps its settings and databases. A few GB.
  * MUST be on a local disk (databases corrupt on network shares).
  * Default keeps it inside this folder — simple, but note: deleting
    this repo folder then deletes your configs, and with the default
    backup folder (also inside it) your backups too." no
    configure_root DATA_ROOT "Data directory" \
"Your media library and downloads — usually the largest folder,
often on a NAS or a big second drive, NOT the system disk.
  * Network shares are fine here — but this wizard does NOT create mounts.
    Set one up first with './mediastack.sh add-mount', then enter its path;
    the wizard records the mount and refuses to start if it ever drops.
  * Default keeps it inside this folder like everything else — fine to
    start with; point it at the big disk later and the wizard tells you
    how the move works.
  * Keep downloads and media on the SAME drive, or imports become slow
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
  * Nothing here is kept or backed up." yes
    configure_root BACKUP_ROOT "Backup directory" \
"Where restore points are written — by the daily backup and before every
update. A NAS path is ENCOURAGED — backups on the same disk as the configs
aren't backups.
(As above: mount the share first; the wizard doesn't create mounts.)" yes

    # hardlink check: a download folder provisioning has yet to make is made
    # inside DATA_ROOT, on its filesystem — only an existing one can differ
    local dr=${Q_ROOT[DATA_ROOT]-} r rows=""
    if [[ -d "$dr/torrent" && "$(fsdev_of "$dr")" != "$(fsdev_of "$dr/torrent")" ]]; then
        warn "DATA_ROOT and its download folder (DATA_ROOT/torrent) are on different filesystems — hardlinks will not work: imports fall back to slow, space-doubling copies. Union the drives (e.g. mergerfs) and use the pool as DATA_ROOT (see README)."
    fi
    for r in "${ROOTS[@]}"; do rows+="$r"$'\t'"${Q_ROOT[$r]-}"$'\t'"${Q_ROOT_MOVE[$r]-}"$'\n'; done
    state_set "$ROOTS_STATE" "${rows%$'\n'}"
}

# --------------------------------------------------------------- services --
svc_own_installer() { # svc_own_installer SVC ",ENABLED," — true (and says so) for a service its own command sets up, not yet enabled
    local inst; inst=$(svc_label "$1" mediastack.installer)
    [[ -n "$inst" && "$2" != *",$1,"* ]] || return 1
    info "$1 — $(svc_label "$1" mediastack.desc): set up by its own command, not here: ./mediastack.sh $inst"
}

_configure_pick_download_clients() { # "everything": keep one download client, or all of them (edits sel)
    local -a dls menu; local c i=0 keep
    # in priority order, as the active-client question lists them: the first is the default
    mapfile -t dls < <(for c in $(role_all_providers download-client arr); do
        printf '%s\t%s\n' "$(jq -r '.priority // 50' "services/$c/provides/download-client.arr.json")" "$c"
    done | sort -n -k1,1 -k2,2 | cut -f2 | while read -r c; do [[ " $sel " == *" $c "* ]] && echo "$c"; done)
    (( ${#dls[@]} > 1 )) || return 0
    if q_quick; then
        REPLY_VAL=1; q_took "Download clients" "${dls[0]} only"
    else
        menu=("\"everything\" includes ${#dls[@]} download clients that do the same job. Most setups run one.")
        for c in "${dls[@]}"; do i=$((i + 1)); menu+=("  $i) $c only"); done
        menu+=("  $((i + 1))) all of them — one is the active client (asked next), the others stay ready")
        explain "Download clients" "${menu[@]}"
        while true; do
            ask DL_KEEP "Choice" 1
            [[ "$REPLY_VAL" =~ ^[0-9]+$ ]] && (( REPLY_VAL >= 1 && REPLY_VAL <= i + 1 )) && break
            fail "Pick 1-$((i + 1))."
        done
        (( REPLY_VAL <= i )) || return 0
    fi
    keep=${dls[REPLY_VAL - 1]}
    for c in "${dls[@]}"; do
        [[ "$c" == "$keep" ]] || sel=$(tr ' ' '\n' <<<"$sel" | grep -vx "$c" | paste -sd' ' -)
    done
    sel+=" "
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
    # a .env this run created holds the example's preset, not a choice: nothing to keep
    if (( ${CONFIGURE_FRESH:-0} )); then cur_list=""; fi
    [[ -n "$cur_list" ]] && { cur_n=$(tr ',' '\n' <<<"$cur_list" | grep -c .); def=0; }
    # quick on a configured stack: what runs, and how people sign in, stay as they are
    if q_quick && (( cur_n )); then q_took "Services" "keep the current $cur_n"; return 0; fi
    local -a menu=("Pick exactly what runs — anything, à la carte. Dependencies are handled
for you (picking qBittorrent brings the VPN; JellySearch brings its
search engine). Change any of this later with enable/disable. How people
sign in (none, Wizarr or authentik) is asked next."
"  1) standard    the recommended setup: VPN, qBittorrent, Sonarr, Radarr,"
"                 Prowlarr, Jellyfin + instant search, request site."
"                 No proxy: services answer on http://<host>:<port>; add"
"                 HTTPS names later with: enable traefik + traefik-setup"
"  2) everything  every service (sign-in is picked next)"
"  3) custom      yes/no through each service")
    (( cur_n )) && menu+=("  0) keep current: $cur_n enabled ($(tr ',' ' ' <<<"$cur_list"))")
    explain "Services" "${menu[@]}"
    local mode sel="" cur_en s d dp
    while true; do
        ask SVC_MODE "Choice" "$def"; mode="$REPLY_VAL"
        case "$mode" in
            0) (( cur_n )) && break; fail "Nothing is enabled yet — pick 1, 2 or 3." ;;
            1|2|3) break ;;
            *) fail "Pick $( (( cur_n )) && echo 0-3 || echo 1-3 )." ;;
        esac
    done
    cur_en=",$cur_list,"
    case "$mode" in
        0) sel=$(tr ',' ' ' <<<"$cur_list") ;;
        1) sel="$STD" ;;
        2) for s in $(svc_managed); do
               svc_own_installer "$s" "$cur_en" || sel+="$s "
           done
           _configure_pick_download_clients ;;
        3) for s in $(svc_managed); do
               case "$s" in wizarr|authentik) continue ;; esac   # the Accounts question decides these
               svc_own_installer "$s" "$cur_en" && continue
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
    esac
    [[ -n "$sel" ]] || die "No services selected — nothing to run."
    # shellcheck disable=SC2086  # a word list of services
    accounts_choose "$cur_list" $sel; sel=$ACCOUNTS_SEL
    if [[ "$mode" == 0 ]] && (( ! ACCOUNTS_CHANGED )); then
        ok "Keeping the current $cur_n service(s): $cur_list"; return 0   # nothing changed: .env untouched
    fi
    info "Resolving dependencies..."
    # the portal is reached through Traefik: choosing it brings Traefik
    if [[ " $sel " == *" authentik "* && " $sel " != *" traefik "* ]]; then
        sel+=" traefik"; info "  + traefik (required by authentik: the portal is reached through it)"
    fi
    # shellcheck disable=SC2086  # a word list of services
    sel=$(resolve_deps $sel)
    # services that do the same job two ways (mediastack.conflicts): keep one
    # the pairs are read first: a loop fed by the list would hand it to the
    # question's read too, answering every "Keep" with the next pair
    local pair a b keep pairs
    mapfile -t pairs < <(conflicts_in $sel)
    for pair in "${pairs[@]}"; do
        [[ -n "$pair" ]] || continue
        a=${pair% *}; b=${pair#* }
        if [[ " $a $b " == *" traefik "* && " $(tr '\n' ' ' <<<"$sel") " == *" authentik "* ]]; then
            keep=traefik; info "$([[ "$a" == traefik ]] && echo "$b" || echo "$a") left out: the portal (authentik) is reached through Traefik"
        else
            local kdef=1; [[ "$b" == traefik ]] && kdef=2   # Traefik: the recommended front door
            if q_quick; then
                keep=$a; [[ "$kdef" == 2 ]] && keep=$b
                q_took "Choose one: $a or $b" "$keep"
            else
                explain "Choose one: $a or $b" \
"These two do the same job in different ways and cannot both run:" \
"  1) $a — $(svc_label "$a" mediastack.desc)" \
"  2) $b — $(svc_label "$b" mediastack.desc)" \
"Switching later is possible (disable one, enable the other)."
                while true; do
                    ask "PICK_$a" "Keep" "$kdef"
                    case "$REPLY_VAL" in 1) keep=$a; break ;; 2) keep=$b; break ;; *) fail "Pick 1 or 2." ;; esac
                done
            fi
        fi
        sel=$(printf '%s\n' $sel | grep -vx "$([[ "$keep" == "$a" ]] && echo "$b" || echo "$a")")
        ok "Keeping $keep"
    done
    env_set COMPOSE_PROFILES "$(echo "$sel" | paste -sd, -)"
    ok "Enabled: $(env_get COMPOSE_PROFILES)"
}

# How people get into the apps: one account model at most (they conflict —
# two populations, duplicate names). Asked every time, whatever the preset;
# a re-run defaults to the current one.
accounts_choose() { # accounts_choose CURRENT-PROFILES SVC... -> ACCOUNTS_SEL: the selection with the chosen model in it (the other out)
    local cur=",$1," model="" c s; shift
    [[ "$cur" == *",authentik,"* ]] && model=authentik
    [[ "$cur" == *",wizarr,"* ]] && model=wizarr
    [[ -z "$model" && "$cur" != ",," ]] && model=none
    local -a menu=("How do people get into your media apps?"
"  1) none       you make each person's accounts yourself, in each app"
"                (Jellyfin's dashboard and so on). Simplest; nothing extra runs."
"  2) Wizarr     invite links: a person opens one and gets their Jellyfin"
"                account. Every app keeps its own login."
"  3) authentik  one portal: people join by invitation and sign in once for"
"                every app; admin tools sit behind it. Adds 4 containers.")
    [[ -z "$model" ]] || menu+=("  0) keep current: $model")
    explain "Accounts" "${menu[@]}"
    while true; do
        ask ACCOUNTS "Choice" "$( [[ -n "$model" ]] && echo 0 || echo 1 )"
        case "$REPLY_VAL" in
            0) [[ -n "$model" ]] || { fail "Nothing to keep."; continue; }; c=$model ;;
            1) c=none ;; 2) c=wizarr ;; 3) c=authentik ;;
            *) fail "Pick $( [[ -n "$model" ]] && echo 0-3 || echo 1-3 )."; continue ;;
        esac
        break
    done
    if [[ "$model" == authentik && "$c" != authentik ]]; then
        warn "Leaving the portal: people's portal accounts stay in authentik's database, but nobody can sign in"
        warn "  with them — every app goes back to its own login."
    elif [[ -n "$model" && "$model" != authentik && "$c" == authentik ]]; then
        info "Existing app accounts stay; tie each person's to their portal account with: ./mediastack.sh link-account <user>"
    fi
    ACCOUNTS_CHANGED=0; [[ "$c" == "${model:-none}" ]] || ACCOUNTS_CHANGED=1
    ACCOUNTS_SEL=""
    for s in "$@"; do [[ "$s" == wizarr || "$s" == authentik ]] || ACCOUNTS_SEL+="$s "; done
    [[ "$c" == none ]] || ACCOUNTS_SEL+="$c"
    ok "Accounts: $c"
}

_configure_download_client() { # several download clients enabled: the one the arrs, Prowlarr and Cleanuparr use
    local enabled cur n i c def=1
    enabled=$(role_providers download-client "${ROLE_CONSUMERS[0]}")
    n=$(grep -c . <<<"$enabled" || true)
    cur=$(env_get DOWNLOAD_CLIENT)
    if (( n < 2 )); then
        # nothing to choose; a choice naming a client no longer enabled would stop wire
        if [[ -n "$cur" ]] && ! grep -qx "$cur" <<<"$enabled"; then
            env_set DOWNLOAD_CLIENT ""; info "DOWNLOAD_CLIENT cleared: $cur is no longer enabled"
        fi
        return 0
    fi
    if q_quick; then
        grep -qx "$cur" <<<"$enabled" || cur=$(head -1 <<<"$enabled")
        env_set DOWNLOAD_CLIENT "$cur"; q_took "Download client" "$cur"; return 0
    fi
    explain "Download client" \
"More than one download client is enabled. The arrs, Prowlarr and Cleanuparr
send to one of them; the others keep running, their entries switched off
(kept, not deleted). Change it here any time, then: ./mediastack.sh wire"
    i=0
    while read -r c; do
        i=$((i + 1)); echo "  $i) $c"
        [[ "$c" == "${cur:-$(head -1 <<<"$enabled")}" ]] && def=$i
    done <<<"$enabled"
    while true; do
        ask DL_N "Which one" "$def"
        [[ "$REPLY_VAL" =~ ^[0-9]+$ ]] && (( REPLY_VAL >= 1 && REPLY_VAL <= n )) && break
        fail "Pick 1-$n."
    done
    c=$(sed -n "${REPLY_VAL}p" <<<"$enabled")
    env_set DOWNLOAD_CLIENT "$c"
    ok "download client: $c"
}

# -------------------------------------------------------------------- VPN --
ask_countries() { # ask_countries "prompt" -> REPLY_VAL: country names, comma-separated, or empty
    if q_quick; then REPLY_VAL=$(env_get VPN_SERVER_COUNTRIES); q_took "Server country" "${REPLY_VAL:-auto}"; return 0; fi
    while true; do
        ask VPN_SERVER_COUNTRIES "$1" "$(env_get VPN_SERVER_COUNTRIES)"
        [[ -z "$REPLY_VAL" || "$REPLY_VAL" =~ ^[A-Za-z][A-Za-z\ ,.\'-]*$ ]] && return 0
        fail "'$REPLY_VAL' is not a country name (e.g. Switzerland, or Netherlands,Sweden)."
    done
}

_configure_vpn() {
    # -- VPN: only when something runs in it
    svc_enabled gluetun || return 0
    local wg_cur; wg_cur=$(env_get WIREGUARD_PRIVATE_KEY)
    if q_quick && [[ -n "$wg_cur" ]]; then q_took "VPN" "keep $(env_get VPN_PROVIDER) and its key"; return 0; fi
    explain "VPN (gluetun)" \
"All download traffic runs inside a VPN container. Supported: any gluetun
provider (nordvpn, mullvad, protonvpn, surfshark, ...) or 'custom' to paste
your own WireGuard details (for fussy/unlisted providers)."
    while true; do
        ask VPN_PROVIDER "VPN provider" "$(env_get VPN_PROVIDER)"
        REPLY_VAL=${REPLY_VAL,,}
        [[ "$REPLY_VAL" =~ ^[a-z0-9][a-z0-9\ ._-]*$ ]] && break
        fail "'$REPLY_VAL' is not a provider name (gluetun's names: nordvpn, mullvad, protonvpn, ... or custom)."
    done
    env_set VPN_PROVIDER "$REPLY_VAL"
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
                ask_token "NordVPN access token (input hidden)"; tok=$REPLY_VAL
                # the login goes in on stdin (-K -), never on the command line where ps shows it
                key=$(curl -fsS -K - "https://api.nordvpn.com/v1/users/services/credentials" \
                          <<<"user = \"token:${tok}\"" \
                      | jq -r '.nordlynx_private_key // empty') \
                    || die "Could not reach Nord's API. Check connectivity and retry."
                [[ -n "$key" ]] || die "Token rejected by NordVPN — regenerate it and re-run configure."
                env_set WIREGUARD_PRIVATE_KEY "$key"
                ok "WireGuard key fetched and verified."
                ask_countries "Server country (e.g. Switzerland; Enter = auto)"
                env_set VPN_SERVER_COUNTRIES "$REPLY_VAL"
            fi ;;
        custom)
            explain "Manual WireGuard" \
"Paste values from your provider's WireGuard config file ([Interface]
PrivateKey and Address). See gluetun's wiki page 'Custom provider' for
the remaining server-side settings to add to .env / an override file."
            ask_token "PrivateKey (input hidden)" "$wg_cur"; env_set WIREGUARD_PRIVATE_KEY "$REPLY_VAL"
            while true; do
                ask WIREGUARD_ADDRESSES "Address" "$(env_get WIREGUARD_ADDRESSES)"
                # one or more IP/prefix, comma-separated (the [Interface] Address line)
                [[ "$REPLY_VAL" =~ ^[0-9A-Fa-f:.]+/[0-9]{1,3}(,[[:space:]]*[0-9A-Fa-f:.]+/[0-9]{1,3})*$ ]] && break
                fail "'$REPLY_VAL' is not an address like 10.5.0.2/32 (copy the Address line of the config file)."
            done
            env_set WIREGUARD_ADDRESSES "$REPLY_VAL" ;;
        *)
            explain "Provider: $REPLY_VAL" \
"Follow gluetun's wiki for '$REPLY_VAL' to obtain your WireGuard private
key, then paste it below. Country selection works the same for all."
            ask_token "WireGuard private key (input hidden)" "$wg_cur"; env_set WIREGUARD_PRIVATE_KEY "$REPLY_VAL"
            ask_countries "Server country (Enter = auto)"; env_set VPN_SERVER_COUNTRIES "$REPLY_VAL" ;;
    esac
}

# --------------------------------------------------------------- the rest --
_configure_timezone() {
    # -- timezone
    local tz_host tz_cur
    tz_host=$(timedatectl show -p Timezone --value 2>/dev/null || echo Etc/UTC)
    tz_cur=$(env_get TZ); [[ "$tz_cur" == Etc/UTC ]] && tz_cur="$tz_host"   # the default is no choice: offer the host's
    if q_quick && [[ -f "/usr/share/zoneinfo/$tz_cur" ]]; then
        env_set TZ "$tz_cur"; q_took "Timezone" "$tz_cur"; return 0
    fi
    explain "Timezone" \
        "Used for logs, in-app times and the update/backup schedules (they run" \
        "at their times in this zone, whatever the host's own). IANA format, e.g." \
        "Europe/Berlin or America/Chicago. Your host reports: $tz_host" \
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
            | sed 's|/usr/share/zoneinfo/||' | grep -i "${REPLY_VAL##*/}" | sed -n 1,5p || true
    done
}

# A service's part in the questionnaire is a function in its folder
# (services/<name>/*.sh), found by name — the core never names an app for it
# (test-questions): <name>_questions asks and records, <name>_summary prints
# its lines of the summary (label TAB value). The platform's come first, so
# the domain is known before the portal's name and email; then the enabled
# services, then the companions the catalogue always carries (no
# mediastack.managed: Recyclarr, run by trash-sync), each in name order.
QUESTION_PLATFORM=(traefik authentik)
svc_companions() { # services that are not switched on and off: always there (their hooks decide what applies)
    jq -r '.services | to_entries[] | select(.value.labels["mediastack.managed"] != "true" and .value.labels["mediastack.shard"] == null) | .key' <<<"$RENDERED_JSON" | sort
}
svc_hooks() { # svc_hooks SUFFIX — each enabled service's <name>_SUFFIX, the platform's first, the companions' last
    local s f
    local -a order comp
    render
    mapfile -t order < <(printf '%s\n' "${QUESTION_PLATFORM[@]}"; svc_enabled_managed | grep -vxF -f <(printf '%s\n' "${QUESTION_PLATFORM[@]}") || true)
    mapfile -t comp < <(svc_companions)
    for s in "${order[@]}"; do
        svc_enabled "$s" || continue
        [[ -z "$Q_FOR" || "$Q_FOR" == *" $s "* ]] || continue   # enable: only what it brings
        f="${s//-/_}_$1"
        if declare -F "$f" >/dev/null; then "$f"; fi
    done
    for s in "${comp[@]}"; do   # always there: no enabled check
        [[ -n "$s" ]] || continue
        f="${s//-/_}_$1"
        if declare -F "$f" >/dev/null; then "$f"; fi
    done
}

_configure_logins() { # the stack's own logins (lib/logins.sh): one username, the passwords generated, unified or typed for each
    local -a miss; local l user mode pw
    mapfile -t miss < <(login_missing)
    (( ${#miss[@]} )) || return 0   # every login is made: set-credentials changes one
    user=$(env_get STACK_USER); mode=$(env_get STACK_LOGINS)
    if q_quick && [[ "$mode" != each && -z "$(login_user_problem "$user")" ]]; then
        q_took "Logins" "$user, passwords $mode"
    else
        local -a menu=("The stack's own logins — the ones the stack makes and uses itself:")
        for l in "${miss[@]}"; do menu+=("  * $(cut -f1 <<<"$l")"); done
        menu+=("People sign in with their own accounts; these are the operator's and the
stack's. A login made already keeps its name and password (change one:
./mediastack.sh set-credentials).")
        explain "Logins" "${menu[@]}"
        while true; do
            ask STACK_USER "Username for all of them" "$user"
            pw=$(login_user_problem "$REPLY_VAL")
            [[ -n "$pw" ]] || break
            fail "'$REPLY_VAL' won't do: $pw."
        done
        user=$REPLY_VAL
        explain "Their passwords" \
"  1) generated   a random password for each (recommended)
  2) unified     one password for all of them — one leaked password then
                 opens every one
  3) each        typed for each, one at a time"
        while true; do
            ask LOGINS_MODE "Choice" "$(case "$mode" in unified) echo 2 ;; each) echo 3 ;; *) echo 1 ;; esac)"
            case "$REPLY_VAL" in 1) mode=generated; break ;; 2) mode=unified; break ;; 3) mode=each; break ;; *) fail "Pick 1, 2 or 3." ;; esac
        done
    fi
    env_set STACK_USER "$user"; env_set STACK_LOGINS "$mode"
    case "$mode" in
        generated)
            for l in "${miss[@]}"; do login_record "$l" "$(login_generate)"; done ;;
        unified)
            local rc=0; pw=$(login_unified_password) || rc=$?
            if (( rc )); then
                warn "the logins made already have different passwords: the new ones share this one; make them all one with: ./mediastack.sh set-credentials all"
                pw=""
            fi
            if [[ -z "$pw" ]]; then login_pass_ask "The one password"; pw=$REPLY_VAL; fi
            for l in "${miss[@]}"; do
                local why; why=$(login_pass_problem "$pw" "$(cut -f3 <<<"$l")")
                # never a quietly different password: "unified" would no longer be true
                [[ -z "$why" ]] || die "the shared password does not suit $(cut -f1 <<<"$l") ($why) — make one that suits every login: ./mediastack.sh set-credentials all, then run this again"
                login_record "$l" "$pw"
            done ;;
        each)
            for l in "${miss[@]}"; do
                login_pass_ask "Password for $(cut -f1 <<<"$l")" "$(cut -f3 <<<"$l")"
                login_record "$l" "$REPLY_VAL"
            done ;;
    esac
    ok "Logins: ${#miss[@]} recorded for '$user' (see them: ./mediastack.sh credentials)"
}

_configure_panel_offer() { # with Traefik on and no panel yet: offer it; configure installs it after provisioning
    if ! svc_enabled traefik || svc_enabled olivetin; then return 0; fi
    if q_quick; then state_set "$PANEL_STATE" yes; q_took "Web panel" "installed"; return 0; fi
    explain "Web panel (optional)" \
"Buttons for the stack's everyday commands — status, restarts, updates,
backups — in your browser at https://$(svc_subdomain olivetin).<domain>, behind the
portal when it runs. Installing it adds a host user that may run only this
script: its own SSH key and a sudo rule for nothing else."
    if confirm_yes "Install the web panel now?"; then state_set "$PANEL_STATE" yes
    else state_del "$PANEL_STATE"; info "Later: ./mediastack.sh frontdoor-install"; fi
}

# -------------------------------------------------------------- schedules --
SCHED_UPDATE_RECOMMENDED="Tue 04:00"   # weekly, choice 2 at its suggested day and time

_configure_schedule() { # updates and backups: two timers, one section — suggested answers, your call
    if q_quick; then
        # a first run takes the recommended pair; a re-run keeps what was chosen (never included)
        if (( ${CONFIGURE_FRESH:-0} )); then
            env_set UPDATE_SCHEDULE "$SCHED_UPDATE_RECOMMENDED"
            env_set BACKUP_SCHEDULE "*-*-* $(sched_time_after "$SCHED_UPDATE_RECOMMENDED")"
        fi
        q_took "Updates" "$(sched_words "$(env_get UPDATE_SCHEDULE)")"
        q_took "Backups" "$(sched_words "$(env_get BACKUP_SCHEDULE)")"
        return 0
    fi
    explain "Schedules" \
"Two jobs run on their own, each on its own schedule:
  Updates  pull new versions of your services. A restore point of every
           service is taken first, so './mediastack.sh rollback <svc>'
           can undo one.
  Backups  take that same kind of restore point: every service's settings
           and data (never your media). If an update took one within the
           last 6 hours, the backup skips — its restore point already
           covers everything.
Both stop all services briefly (~20-40s for the restore point), and both
wait while someone is watching in Jellyfin (UPDATE_DEFER_IF_ACTIVE in .env,
on by default) — other apps aren't asked. Pick quiet times for YOUR household."
    while true; do
        sched_choose UPDATE_SCHEDULE Updates 2 04:00 "manual './mediastack.sh update' only"
        echo
        sched_choose BACKUP_SCHEDULE Backups 1 "$(sched_time_after "$(env_get UPDATE_SCHEDULE)")" \
            "only updates and './mediastack.sh backup' take restore points"
        sched_summary
        if confirm_yes "Keep these?"; then echo; break; fi
        echo
    done
}

sched_choose() { # sched_choose VAR TITLE DEFAULT-CHOICE DEFAULT-TIME NEVER-TEXT -> VAR set in .env ("" = never)
    local var=$1 title=$2 defc=$3 deft=$4 never=$5 cur expr day c
    cur=$(env_get "$var")
    local -a line=("" "daily       every day at a time you pick" "weekly      one day a week" \
                   "weekdays    Mon-Fri" "weekends    Sat+Sun" "custom      raw systemd OnCalendar expression" \
                   "never       $never")
    echo "$title:"
    for c in 1 2 3 4 5 6; do
        printf '  %s) %s%s\n' "$c" "${line[$c]}" "$( [[ "$c" == "$defc" ]] && echo " (recommended)" )"
    done
    [[ -n "$cur" ]] && echo "  0) keep current: $(sched_words "$cur")"
    while true; do
        ask SCHED_MODE "Choice" "$( [[ -n "$cur" ]] && echo 0 || echo "$defc" )"
        expr=""
        case "$REPLY_VAL" in
            0) [[ -n "$cur" ]] || { fail "Nothing to keep."; continue; }
               expr=$cur ;;
            1) ask_time "$deft"; expr="*-*-* $REPLY_VAL" ;;
            2) while true; do
                   ask SCHED_DAY "Day (Mon/Tue/Wed/Thu/Fri/Sat/Sun)" "Tue"
                   day="${REPLY_VAL:0:1}"; day="${day^^}${REPLY_VAL:1:2}"; day="${day:0:3}"
                   [[ "$day" =~ ^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)$ ]] && break
                   fail "'$REPLY_VAL' is not a weekday name."
               done
               ask_time "$deft"; expr="$day $REPLY_VAL" ;;
            3) ask_time "$deft"; expr="Mon..Fri $REPLY_VAL" ;;
            4) ask_time "$deft"; expr="Sat,Sun $REPLY_VAL" ;;
            5) explain "Custom schedule" \
"Any systemd OnCalendar expression, e.g.:" \
"  Tue,Fri 04:00      twice a week      *-*-01 03:00   1st of the month" \
"  Mon..Fri 03:30     weekday early     (validated before it is saved)"
               ask SCHED_EXPR "OnCalendar expression" "*-*-* $deft"; expr=$REPLY_VAL ;;
            6) env_set "$var" ""; return 0 ;;
            *) fail "Pick 0-6."; continue ;;
        esac
        systemd-analyze calendar "$expr" >/dev/null 2>&1 || { fail "'$expr' is not a valid schedule."; continue; }
        env_set "$var" "$expr"; return 0
    done
}

sched_summary() { # both schedules, when they next run, and how they meet
    local u b ut bt
    u=$(env_get UPDATE_SCHEDULE); b=$(env_get BACKUP_SCHEDULE)
    echo; hr "Your schedules"
    printf '  %-8s  %-16s  %s\n' Updates "$(sched_words "$u")" "$(sched_next "$u")"
    printf '  %-8s  %-16s  %s\n' Backups "$(sched_words "$b")" "$(sched_next "$b")"
    if [[ -z "$u" && -z "$b" ]]; then
        warn "No automatic restore points at all — only './mediastack.sh backup' makes them."
    elif [[ -z "$b" ]]; then
        info "Restore points come only from updates and './mediastack.sh backup'."
    elif [[ -n "$u" ]]; then
        [[ "$u" =~ ([0-9]{1,2}:[0-9]{2})(:[0-9]{2})?$ ]] && ut=${BASH_REMATCH[1]}
        [[ "$b" =~ ([0-9]{1,2}:[0-9]{2})(:[0-9]{2})?$ ]] && bt=${BASH_REMATCH[1]}
        if [[ -n "${ut:-}" && -n "${bt:-}" ]] && (( 10#${bt/:/} <= 10#${ut/:/} )); then
            info "Note: on update days the backup runs first, so that day gets two restore points."
            info "  Put the backup after the update ($(sched_time_after "$u") or later) to avoid it."
        else
            info "On update days the update's restore point counts; the backup skips."
        fi
    fi
}

sched_next() { # sched_next EXPR -> "next: <when>" ("" for never)
    [[ -n "$1" ]] || return 0
    local n; n=$(systemd-analyze calendar "$1" 2>/dev/null | sed -n 's/^ *Next elapse: //p' | sed -n 1p)
    echo "next: ${n:-?}"
}

# ---------------------------------------------------------------- summary --
q_row() { printf '  %-16s %s\n' "$1" "$2"; }   # q_row LABEL VALUE — one line of the summary

questionnaire_summary() { # configure's last screen: every answer, the defaulted ones too; secrets in outline
    local r model l v
    hr "Your answers"
    q_row timezone "$(env_get TZ)"
    for r in "${ROOTS[@]}"; do r=${r%_ROOT}; q_row "${r,,} folder" "$(env_get "${r}_ROOT")"; done
    q_row services "$(env_get COMPOSE_PROFILES | tr ',' ' ')"
    model=$(signin_model); signin_is authentik && model+=" (portal: $(env_get PORTAL_TITLE))"
    q_row sign-in "$model"
    [[ -n "$(env_get DOWNLOAD_CLIENT)" ]] && q_row "download client" "$(env_get DOWNLOAD_CLIENT)"
    if svc_enabled gluetun; then
        q_row VPN "$(env_get VPN_PROVIDER), key $( [[ -n "$(env_get WIREGUARD_PRIVATE_KEY)" ]] && echo set || echo MISSING), servers: $(env_or_note VPN_SERVER_COUNTRIES auto)"
    fi
    svc_enabled cloudflared && q_row tunnel "token set"
    [[ -z "$(logins_list)" ]] || q_row logins "$(env_get STACK_USER), passwords $(env_get STACK_LOGINS) (see: credentials)"
    svc_hooks summary | while IFS=$'\t' read -r l v; do q_row "$l" "$v"; done
    q_row updates "$(sched_words "$(env_get UPDATE_SCHEDULE)")"
    q_row backups "$(sched_words "$(env_get BACKUP_SCHEDULE)")"
    signin_is authentik && q_row email "$( [[ -n "$(env_get SMTP_HOST)" ]] && echo "$(env_get SMTP_HOST), from $(env_get SMTP_FROM)" || echo "not set")"
    if svc_enabled olivetin; then
        if frontdoor_installed; then q_row "web panel" installed; else q_row "web panel" "not installed yet — frontdoor-install runs first"; fi
    fi
    echo "Something to change? ./mediastack.sh configure again, in full: these answers are its defaults."
}
