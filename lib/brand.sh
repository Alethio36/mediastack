#!/usr/bin/env bash
# lib/brand.sh — the household's kit, read by whatever shows it (the `brand`
# verb: show, change, apply). Files in custom/branding/ (yours, never
# overwritten), words in .env:
#   name        PORTAL_TITLE — configure asks it with the portal; the portal's
#               name, its sign-in title, the Discord sender's
#   icon        icon.png — the Discord sender's avatar and the portal's
#               "Start here" card (mediastack's when absent), and the portal's
#               tab icon (authentik's when absent)
#   logo        logo.png — the portal's logo (authentik's when absent)
#   background  background.png or .jpg — the portal's sign-in background
#   app icons   icons/<service>.png — that app's card on the portal's
#               dashboard; absent: services/<service>/icon.png, the shipped one
#               (services/NOTICE-icons.md says where they come from)
#   colours     BRAND_COLOUR_<TYPE> — a message card's colour per type
#               (Apprise's map for mediastack's, the hub entries for Seerr's)
#   accent      BRAND_ACCENT — the portal's buttons and links, the button in
#               its emails, Jellyfin's web client (each app's own when unset)
# Where each shows: the portal (services/authentik/kit.sh), Jellyfin — its
# accent, the background behind its sign-in, a sign-in line naming the
# household (services/jellyfin/kit.sh), Seerr's and the web panel's title
# (the name). Kavita, Audiobookshelf and Navidrome take none of it: people
# reach them signed in through the portal, which carries it.
# Each place takes it where mediastack set it last, never over a value set
# in that app's own screens. Nothing is required: an empty kit is the
# shipped look. Sourced by the entrypoint.

BRAND_DIR="$CUSTOM_DIR/branding"
BRAND_ICON_SHIPPED=services/apprise/assets/icon.png   # relative to SCRIPT_DIR
BRAND_ICON_MIN=128 BRAND_ICON_MAX=1024 BRAND_ICON_BYTES=1048576
BRAND_LOGO_BYTES=1048576 BRAND_BACKGROUND_BYTES=5242880
BRAND_TYPES=(info success warning failure)

brand_icon() { # -> the sender's icon, a path (yours when it is there)
    if [[ -e "$BRAND_DIR/icon.png" ]]; then echo "$BRAND_DIR/icon.png"; else echo "$SCRIPT_DIR/$BRAND_ICON_SHIPPED"; fi
}
brand_yours() { # brand_yours icon|logo|background -> your file of that kind, if there is one
    local f
    case "$1" in
        background) for f in "$BRAND_DIR/background.png" "$BRAND_DIR/background.jpg"; do [[ -e "$f" ]] && { echo "$f"; return 0; }; done ;;
        *) [[ -e "$BRAND_DIR/$1.png" ]] && echo "$BRAND_DIR/$1.png" ;;
    esac
    return 0
}
brand_app_icon() { # brand_app_icon SVC -> that app's card icon, a path (yours, else the shipped one; none: nothing)
    if [[ -e "$BRAND_DIR/icons/$1.png" ]]; then echo "$BRAND_DIR/icons/$1.png"
    elif [[ -e "$SCRIPT_DIR/services/$1/icon.png" ]]; then echo "$SCRIPT_DIR/services/$1/icon.png"; fi
    return 0
}

brand_file_kind() { # brand_file_kind FILE -> png, jpg or nothing (by its first bytes, not its name)
    case "$(head -c 8 "$1" | od -An -tx1 | tr -d ' \n')" in
        89504e470d0a1a0a) echo png ;;
        ffd8ff*) echo jpg ;;
    esac
}
brand_png_size() { # brand_png_size FILE -> "W H" (a PNG names its size in its header: the signature, then IHDR's width and height)
    echo "$((16#$(head -c 20 "$1" | tail -c 4 | od -An -tx1 | tr -d ' \n'))) $((16#$(head -c 24 "$1" | tail -c 4 | od -An -tx1 | tr -d ' \n')))"
}
brand_file_problem() { # brand_file_problem icon|logo|background FILE -> why it cannot be that ("" when fine)
    local k=$1 f=$2 size max w h kind
    [[ -f "$f" && -r "$f" ]] || { echo "$f is not a readable file"; return 0; }
    size=$(stat -c %s "$f"); kind=$(brand_file_kind "$f")
    case "$k" in icon) max=$BRAND_ICON_BYTES ;; logo) max=$BRAND_LOGO_BYTES ;; background) max=$BRAND_BACKGROUND_BYTES ;; esac
    (( size <= max )) || { echo "$f is $((size / 1024)) KiB — the most for the $k is $((max / 1024)) KiB"; return 0; }
    if [[ "$k" == background ]]; then
        [[ -n "$kind" ]] || echo "$f is neither a PNG nor a JPEG — save it as one (any image editor can)"
        return 0
    fi
    [[ "$kind" == png ]] || { echo "$f is not a PNG — save it as one (any image editor can)"; return 0; }
    [[ "$k" == icon ]] || return 0
    read -r w h <<<"$(brand_png_size "$f")"
    (( w == h )) || { echo "$f is ${w}x${h} — an icon must be square"; return 0; }
    (( w >= BRAND_ICON_MIN && w <= BRAND_ICON_MAX )) \
        || { echo "$f is ${w}x${h} — an icon must be ${BRAND_ICON_MIN} to ${BRAND_ICON_MAX} pixels a side"; return 0; }
}
brand_icon_problem() { brand_file_problem icon "$1"; }   # brand_icon_problem FILE (the sender's, an app's: one rule)

brand_decide() { # brand_decide CUR WANT DEFAULT MINE -> same | set | yours: an app's value is set while it is the app's own or the one mediastack set last
    if [[ "$1" == "$2" ]]; then echo same
    elif [[ -z "$1" || "$1" == "$3" || ( -n "$4" && "$1" == "$4" ) ]]; then echo set
    else echo yours; fi
}

brand_colour() { echo "#$(env_get "BRAND_COLOUR_${1^^}")"; }   # brand_colour TYPE -> #RRGGBB

brand_swatch() { # brand_swatch RRGGBB -> a small block in that colour and a space, on a terminal (24-bit colour); nothing otherwise
    [[ -n "$C_RST" ]] || return 0
    printf '\e[48;2;%d;%d;%dm  %s ' "$((16#${1:0:2}))" "$((16#${1:2:2}))" "$((16#${1:4:2}))" "$C_RST"
}

brand_colour_value() { # brand_colour_value TEXT -> the .env form (6 hex digits, upper case); rc 1 when it is not a colour
    local v=${1#\#}
    [[ "$v" =~ ^[0-9A-Fa-f]{6}$ ]] || return 1
    echo "${v^^}"
}

brand_name_discord_problem() { # brand_name_discord_problem NAME -> why Discord refuses it as a sender's name ("" when fine)
    local n=$1 l=${1,,}
    (( ${#n} >= 1 && ${#n} <= 80 )) || { echo "a sender's name is 1 to 80 characters on Discord (it is ${#n})"; return 0; }
    [[ "$l" != *discord* && "$l" != *clyde* ]] || echo "Discord refuses a sender's name with \"discord\" or \"clyde\" in it"
}

cmd_brand() { # brand [status | colour TYPE C|default | accent C|default | icon|logo|background FILE|default | app-icon SVC FILE|default]
    local what=${1:-status}
    (( $# )) && shift
    case "$what" in
        status) (( $# == 0 )) || die "'brand status' takes no arguments"; brand_status ;;
        colour|color)
            (( $# == 2 )) || die "usage: brand colour ${BRAND_TYPES[*]// /|} <colour, e.g. #3AA337>|default"
            brand_colour_set "$1" "$2" ;;
        accent) (( $# == 1 )) || die "usage: brand accent <colour, e.g. #E6701E>|default"; brand_accent_set "$1" ;;
        icon|logo|background) (( $# == 1 )) || die "usage: brand $what <file>|default"; brand_file_set "$what" "$1" ;;
        app-icon) (( $# == 2 )) || die "usage: brand app-icon <service> <file.png>|default"; brand_app_icon_set "$1" "$2" ;;
        *) die "unknown 'brand' action '$what' (accepts: status, colour, accent, icon, logo, background, app-icon)" ;;
    esac
}

brand_status() {
    load_env
    local t p f v k n=0 bad=""
    hr "Brand"
    info "name: $(env_get PORTAL_TITLE)  (PORTAL_TITLE — configure asks it with the portal)"
    p=$(brand_name_discord_problem "$(env_get PORTAL_TITLE)"); [[ -z "$p" ]] || warn "     not a Discord sender's name: $p"
    for k in icon logo background; do
        f=$(brand_yours "$k")
        if [[ -z "$f" ]]; then
            case "$k" in
                icon) info "icon: mediastack's for messages, authentik's on the portal (yours: ./mediastack.sh brand icon <file.png>)" ;;
                *) info "$k: authentik's (yours: ./mediastack.sh brand $k <file>)" ;;
            esac
            continue
        fi
        p=$(brand_file_problem "$k" "$f")
        if [[ -z "$p" ]]; then info "$k: yours (custom/branding/${f##*/})"; else warn "$k: yours, unusable — $p"; fi
    done
    for f in "$BRAND_DIR"/icons/*.png; do
        [[ -e "$f" ]] || continue
        n=$((n + 1)); p=$(brand_icon_problem "$f"); [[ -z "$p" ]] || bad+="${bad:+, }${f##*/}"
    done
    if (( n )); then info "app icons: $n of yours (custom/branding/icons/)$([[ -n "$bad" ]] && echo " — unusable: $bad")"
    else info "app icons: mediastack's (yours: ./mediastack.sh brand app-icon <service> <file.png>)"; fi
    v=$(env_get BRAND_ACCENT)
    if [[ -n "$v" ]]; then info "accent: $(brand_swatch "$v")#$v"; else info "accent: authentik's (yours: ./mediastack.sh brand accent <colour>)"; fi
    for t in "${BRAND_TYPES[@]}"; do
        v=$(env_get "BRAND_COLOUR_${t^^}")
        info "colour, $t: $(brand_swatch "$v")#$v$([[ "$v" == "${ENV_DEFAULT[BRAND_COLOUR_${t^^}]}" ]] && echo "  (mediastack's)")"
    done
}

brand_colour_set() { # brand_colour_set TYPE COLOUR|default
    local t=${1,,} v k
    [[ " ${BRAND_TYPES[*]} " == *" $t "* ]] || die "unknown message type '$1' (types: ${BRAND_TYPES[*]})"
    load_env
    k="BRAND_COLOUR_${t^^}"
    if [[ "$2" == default ]]; then
        env_del "$k"; ok "$t messages: mediastack's colour, $(brand_swatch "${ENV_DEFAULT[$k]}")#${ENV_DEFAULT[$k]}"
    else
        v=$(brand_colour_value "$2") || die "'$2' is not a colour — six hex digits, e.g. #3AA337 (the # is optional)"
        env_set "$k" "$v"; ok "$t messages: $(brand_swatch "$v")#$v"
    fi
    brand_apply_messages
}

brand_accent_set() { # brand_accent_set COLOUR|default
    local v
    load_env
    if [[ "$1" == default ]]; then
        env_del BRAND_ACCENT; ok "the portal's accent: authentik's own"
    else
        v=$(brand_colour_value "$1") || die "'$1' is not a colour — six hex digits, e.g. #E6701E (the # is optional)"
        env_set BRAND_ACCENT "$v"; ok "the portal's accent: $(brand_swatch "$v")#$v"
    fi
    brand_apply_apps
}

brand_file_put() { # brand_file_put SRC DEST — into custom/branding/, yours (the folder made, handed to the repo's owner)
    mkdir -p "${2%/*}"; repo_owned "$CUSTOM_DIR" "$BRAND_DIR" "${2%/*}"
    [[ "$(realpath "$1")" == "$(realpath -m "$2")" ]] || install -m 644 "$1" "$2"
    repo_owned "$2"
}

brand_file_set() { # brand_file_set icon|logo|background FILE|default
    local k=$1 p old dest
    load_env
    old=$(brand_yours "$k")
    if [[ "$2" == default ]]; then
        [[ -n "$old" ]] || { ok "the $k is already the shipped one"; return 0; }
        rm -f "$old"
        if [[ "$k" == icon ]]; then ok "the icon: mediastack's for messages, authentik's on the portal (yours removed from custom/branding/)"
        else ok "the $k: authentik's own again (yours removed from custom/branding/)"; fi
    else
        p=$(brand_file_problem "$k" "$2"); [[ -z "$p" ]] || die "$p"
        dest="$BRAND_DIR/$k.$( [[ "$k" == background ]] && brand_file_kind "$2" || echo png )"
        brand_file_put "$2" "$dest"
        [[ -z "$old" || "$old" == "$dest" ]] || rm -f "$old"   # a background that was the other kind
        ok "the $k is yours: custom/branding/${dest##*/}"
    fi
    [[ "$k" == icon ]] && brand_apply_messages
    brand_apply_apps
}

brand_app_icon_set() { # brand_app_icon_set SVC FILE|default
    local s=$1 p f="$BRAND_DIR/icons/$1.png"
    [[ "$s" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "'$s' is not a service name"
    load_env
    if [[ "$2" == default ]]; then
        [[ -e "$f" ]] || { ok "$s's card already has the shipped icon"; return 0; }
        rm -f "$f"; ok "$s's card: the shipped icon again$([[ -e "$SCRIPT_DIR/services/$s/icon.png" ]] || echo " (none ships: authentik's letter)")"
    else
        p=$(brand_icon_problem "$2"); [[ -z "$p" ]] || die "$p"
        brand_file_put "$2" "$f"
        ok "$s's card: your icon (custom/branding/icons/$s.png)"
    fi
    brand_apply_apps
}

brand_apply_messages() { # the kit as it is now reaches the hub (colours) and the Discord senders (name, icon)
    render   # here, in the verb's own shell: the hub's address is read from it
    if ! hub_enabled || ! hub_running; then
        info "the notification hub is not running — the kit reaches it at its next start: ./mediastack.sh up, then ./mediastack.sh wire apprise"
        return 0
    fi
    apprise_brand_apply
    info "see it: ./mediastack.sh notify test"
}

brand_apply_apps() { # the kit as it is now reaches the apps that show it: the portal (authentik) and Jellyfin
    render
    if signin_is authentik; then
        if [[ "$(c_state "$(svc_cname authentik)")" == running ]]; then
            # ready first: the change before may have restarted it (the accent rewrites its email templates)
            http_ready authentik "$(authentik_url)/-/health/ready/" '^2' && authentik_brand_apply
        else info "the portal is not running — it takes the kit at its next start: ./mediastack.sh up, then ./mediastack.sh wire authentik"; fi
    fi
    if svc_enabled jellyfin; then
        if [[ "$(c_state "$(svc_cname jellyfin)")" == running ]]; then jellyfin_brand_apply
        else info "jellyfin is not running — it takes the kit at: ./mediastack.sh up, then ./mediastack.sh wire jellyfin"; fi
    fi
    info "see it: the portal's and Jellyfin's sign-in pages, in a private window"
}

_doctor_brand() {
    hr "doctor: brand"
    local p f k
    for k in icon logo background; do
        f=$(brand_yours "$k"); [[ -n "$f" ]] || continue
        p=$(brand_file_problem "$k" "$f")
        if [[ -n "$p" ]]; then
            d_fail "the $k in custom/branding/ is unusable: $p" "what shows it keeps the $k it has" \
                "./mediastack.sh brand $k <file> (or brand $k default)"
        else
            ok "$k: yours (custom/branding/${f##*/})"
        fi
    done
    for f in "$BRAND_DIR"/icons/*.png; do
        [[ -e "$f" ]] || continue
        p=$(brand_icon_problem "$f"); k=${f##*/}; k=${k%.png}
        [[ -z "$p" ]] || d_fail "the app icon custom/branding/icons/$k.png is unusable: $p" "$k's card keeps the icon it has" \
            "./mediastack.sh brand app-icon $k <file.png> (or brand app-icon $k default)"
    done
    p=$(brand_name_discord_problem "$(env_get PORTAL_TITLE)")
    if [[ -n "$p" ]] && hub_enabled && hub_running && grep -q 'discord://' <<<"$( (hub_cfg_get) 2>/dev/null )"; then
        warn "the name '$(env_get PORTAL_TITLE)' (PORTAL_TITLE) is not a Discord sender's name — $p; the webhook keeps the name it has (change it: ./mediastack.sh configure)"
    fi
    ok "the kit is checked (custom/branding/)"
    return 0
}
