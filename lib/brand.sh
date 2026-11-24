#!/usr/bin/env bash
# lib/brand.sh — the household's kit: the name, the icon and the message
# colours, read by whatever shows them (the `brand` verb: show, change, apply).
#   name     PORTAL_TITLE (.env) — configure asks it with the portal; it is
#            the portal's name and the Discord sender's
#   icon     custom/branding/icon.png (yours; absent: the shipped one) — the
#            Discord sender's avatar, uploaded from this host
#   colours  BRAND_COLOUR_<TYPE> (.env; 6 hex digits, no #) — a card's colour
#            per message type: Apprise's own map for mediastack's messages
#            (services/apprise/compose.yml, read at the hub's start) and
#            mediastack's entries for Seerr's (lib/notify.sh)
# Nothing is required: an empty kit is the shipped look. Sourced by the
# entrypoint.

BRAND_DIR="$CUSTOM_DIR/branding"
BRAND_ICON_SHIPPED=services/apprise/assets/icon.png   # relative to SCRIPT_DIR
BRAND_ICON_MIN=128 BRAND_ICON_MAX=1024 BRAND_ICON_BYTES=1048576
BRAND_TYPES=(info success warning failure)

brand_icon() { # -> the icon in use, a path (yours when it is there)
    if [[ -e "$BRAND_DIR/icon.png" ]]; then echo "$BRAND_DIR/icon.png"; else echo "$SCRIPT_DIR/$BRAND_ICON_SHIPPED"; fi
}

brand_icon_problem() { # brand_icon_problem FILE -> why it cannot be the icon ("" when fine)
    local f=$1 size w h
    [[ -f "$f" && -r "$f" ]] || { echo "$f is not a readable file"; return 0; }
    size=$(stat -c %s "$f")
    (( size <= BRAND_ICON_BYTES )) || { echo "$f is $((size / 1024)) KiB — the most is $((BRAND_ICON_BYTES / 1024)) KiB (Discord's limit is lower than most)"; return 0; }
    # a PNG names its size in its header: the signature, then IHDR's width and height
    [[ "$(head -c 8 "$f" | od -An -tx1 | tr -d ' \n')" == 89504e470d0a1a0a ]] \
        || { echo "$f is not a PNG — save it as one (any image editor can)"; return 0; }
    w=$((16#$(head -c 20 "$f" | tail -c 4 | od -An -tx1 | tr -d ' \n')))
    h=$((16#$(head -c 24 "$f" | tail -c 4 | od -An -tx1 | tr -d ' \n')))
    (( w == h )) || { echo "$f is ${w}x${h} — the icon must be square"; return 0; }
    (( w >= BRAND_ICON_MIN && w <= BRAND_ICON_MAX )) \
        || { echo "$f is ${w}x${h} — the icon must be ${BRAND_ICON_MIN} to ${BRAND_ICON_MAX} pixels a side"; return 0; }
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

cmd_brand() { # brand [colour TYPE COLOUR|default] [icon FILE|default]
    local what=${1:-status}
    (( $# )) && shift
    case "$what" in
        status) (( $# == 0 )) || die "'brand status' takes no arguments"; brand_status ;;
        colour|color)
            (( $# == 2 )) || die "usage: brand colour ${BRAND_TYPES[*]// /|} <colour, e.g. #3AA337>|default"
            brand_colour_set "$1" "$2" ;;
        icon) (( $# == 1 )) || die "usage: brand icon <file.png>|default"; brand_icon_set "$1" ;;
        *) die "unknown 'brand' action '$what' (accepts: status, colour, icon)" ;;
    esac
}

brand_status() {
    load_env
    local t p icon v
    hr "Brand"
    info "name: $(env_get PORTAL_TITLE)  (PORTAL_TITLE — configure asks it with the portal)"
    p=$(brand_name_discord_problem "$(env_get PORTAL_TITLE)"); [[ -z "$p" ]] || warn "     not a Discord sender's name: $p"
    icon=$(brand_icon)
    if [[ "$icon" == "$BRAND_DIR/icon.png" ]]; then
        p=$(brand_icon_problem "$icon")
        if [[ -z "$p" ]]; then info "icon: yours (custom/branding/icon.png)"; else warn "icon: yours, unusable — $p"; fi
    else
        info "icon: mediastack's (yours: ./mediastack.sh brand icon <file.png>)"
    fi
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
    brand_apply
}

brand_icon_set() { # brand_icon_set FILE|default
    local p
    load_env
    if [[ "$1" == default ]]; then
        [[ -e "$BRAND_DIR/icon.png" ]] || { ok "the icon is already mediastack's"; return 0; }
        rm -f "$BRAND_DIR/icon.png"; ok "the icon is mediastack's again (yours removed from custom/branding/)"
    else
        p=$(brand_icon_problem "$1"); [[ -z "$p" ]] || die "$p"
        mkdir -p "$BRAND_DIR"; repo_owned "$CUSTOM_DIR" "$BRAND_DIR"
        [[ "$(realpath "$1")" == "$(realpath -m "$BRAND_DIR/icon.png")" ]] || install -m 644 "$1" "$BRAND_DIR/icon.png"
        repo_owned "$BRAND_DIR/icon.png"
        ok "the icon is yours: custom/branding/icon.png"
    fi
    brand_apply
}

brand_apply() { # the kit as it is now reaches the hub (colours) and the Discord senders (name, icon)
    render   # here, in the verb's own shell: the hub's address is read from it
    if ! hub_enabled || ! hub_running; then
        info "the notification hub is not running — the kit reaches it at its next start: ./mediastack.sh up, then ./mediastack.sh wire apprise"
        return 0
    fi
    apprise_brand_apply
    info "see it: ./mediastack.sh notify test"
}

_doctor_brand() {
    hr "doctor: brand"
    local p icon
    icon=$(brand_icon)
    if [[ "$icon" == "$BRAND_DIR/icon.png" ]]; then
        p=$(brand_icon_problem "$icon")
        if [[ -n "$p" ]]; then
            d_fail "the icon in custom/branding/ is unusable: $p" "the Discord sender keeps the icon it has" \
                "./mediastack.sh brand icon <file.png> (or brand icon default)"
        else
            ok "icon: yours (custom/branding/icon.png)"
        fi
    else
        ok "icon: mediastack's"
    fi
    p=$(brand_name_discord_problem "$(env_get PORTAL_TITLE)")
    if [[ -n "$p" ]] && hub_enabled && hub_running && grep -q 'discord://' <<<"$( (hub_cfg_get) 2>/dev/null )"; then
        warn "the name '$(env_get PORTAL_TITLE)' (PORTAL_TITLE) is not a Discord sender's name — $p; the webhook keeps the name it has (change it: ./mediastack.sh configure)"
    fi
    return 0
}
