#!/usr/bin/env bash
# lib/newservice.sh — `new-service`: the interactive scaffold that writes a
# user's own service into custom/compose.d/<name>.yml on the toggle model,
# then enables and starts it. Sourced by the entrypoint; relies on
# lib/common.sh, lib/configure.sh (_configure_selfheal) and the entrypoint's
# helpers at call time.

cmd_new_service() {
    # User services live in custom/compose.d/, one file each: untracked,
    # passed to compose on every run, and upgrades never conflict with them.
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
    local image cport host desc vpn cfg data ident
    explain "New service: $name" \
"A few questions produce a complete, working service definition in
custom/compose.d/$name.yml — image, port, HTTPS hostname, VPN membership,
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
"Every mediastack service runs as its own system user (a UID such as
13029) in the shared 'mediacenter' group, so each app can only write its
own config folder plus the media it is allowed to touch, and files it
creates stay readable by the other apps. HOW that user is applied depends
on the image — and a wrong answer is silent: the app just runs as root.
Check the image's docs (or its Dockerfile) for 'PUID' and 'USER'.

  1) PUID/PGID   the image switches user itself when PUID/PGID are set
                 (linuxserver.io, hotio, most *arr images)
  2) user:       the image runs as whoever starts it (most official images:
                 Jellyfin, Seerr, Navidrome, Kavita, Audiobookshelf); every
                 file it writes must land in its folders, and it must not
                 listen on a port below 1024
  3) neither     it must run as root or as its own fixed user (nginx-style
                 images): no private owner, doctor won't expect its UID

doctor checks the running processes: if they aren't running as the
service's UID, it fails and tells you to switch to 2)."
    _ns_ask "Choice" "1"; ident="$REPLY_VAL"
    [[ "$ident" =~ ^[123]$ ]] || die "Choice must be 1, 2 or 3."
    if [[ "$ident" == 2 ]] && (( cport < 1024 )); then
        warn "port $cport is below 1024: running as its own user, the app may be refused that port (depends on the host). If it won't start, move it with the app's own port setting and re-run new-service with that port."
    fi

    # ---- scaffold ----
    local f="$DROPIN_DIR/$name.yml"
    [[ -e "$f" ]] && die "$f already exists — pick another name, or remove that file first."
    mkdir -p "$DROPIN_DIR"; repo_owned "$CUSTOM_DIR" "$DROPIN_DIR"
    { printf '# Your service — untracked, passed to compose on every run, upgrade-safe.\n'
      printf '# Remove it: ./mediastack.sh disable %s, then delete this file.\nservices:\n' "$name"
      _new_service_fragment "$name" "$stem" "$image" "$cport" "$host" "$desc" "$vpn" "$cfg" "$data" "$ident"
    } > "$f"
    repo_owned "$f"
    # anything failing from here until the stack is touched removes the file
    # AND regenerates the overlay: a stanza for a service that no longer
    # exists would make every later render fail ("neither an image nor a
    # build context")
    _new_service_rollback() {
        rm -f "$f"
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
        # shellcheck disable=SC2034  # the render cache lives in the entrypoint
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
    info "Waiting for Docker's verdict on $name (up to ${START_WAIT}s; without a healthcheck it passes once running)..."
    wait_verdict "$name" || die "$name ${VERDICT_WHY[$name]} — inspect: ./mediastack.sh logs $name"
    hr "$name"
    echo "  URL: $(svc_url "$name")"
    [[ -n "$(env_get TRAEFIK_DOMAIN)" ]] || echo "  (an HTTPS hostname appears once Traefik is set up: ./mediastack.sh traefik-setup)"
    echo "  VPN: $(vpn_onoff "$vpn")   change: ./mediastack.sh vpn $name on|off"
    echo "  Row: ./mediastack.sh status"
    _new_service_footer "$name"
}

_new_service_footer() { # where to go for anything the questions did not cover
    cat <<EOT

Its definition is custom/compose.d/$1.yml — plain compose YAML, yours to
edit: extra environment variables (API keys, a base URL), devices (/dev/dri
for hardware transcoding), more volumes, a healthcheck, or more containers it
needs (a database). Edit, then: ./mediastack.sh up
Host port:  $(uvar "$1")_PORT=<port> in .env   HTTPS name: $(uvar "$1")_HOST=<sub> in .env
Removing it later: docs/adding-a-service.md, "Removing your service".
EOT
}

_new_service_fragment() { # <name> <stem> <image> <cport> <host> <desc> <vpn> <cfg> <data> <ident 1|2|3> -> YAML on stdout
    local name="$1" stem="$2" image="$3" cport="$4" host="$5" desc="$6" vpn="$7" cfg="$8" data="$9" ident="${10}"
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
EOF
    # identity: 1 = PUID/PGID (image switches), 2 = user: (image runs as its starter), 3 = neither
    [[ "$ident" == 2 ]] && echo "    user: \"\${${stem}_UID}:\${MEDIA_GROUP_GID}\""
    cat <<EOF
    environment:
      - TZ=\${TZ}
EOF
    if [[ "$ident" == 1 ]]; then cat <<EOF
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
      mediastack.auth: "native"   # its own login; "gate" puts it behind the portal (authentik)
      mediastack.port: "$cport"
    logging:
      driver: json-file
      options:
        max-size: \${LOG_MAX_SIZE:-10m}
        max-file: \${LOG_MAX_FILE:-3}
    restart: unless-stopped
EOF
}
