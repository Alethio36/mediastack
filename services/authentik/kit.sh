#!/usr/bin/env bash
# services/authentik/kit.sh — the household's kit (lib/brand.sh) on the
# portal: authentik's brand (logo, tab icon, sign-in background, the accent as
# its custom CSS), its sign-in title, each app card's icon, and the accent in
# mediastack's emails (authentik_template_render).
#
# authentik takes an image as a file name in its media folder
# (CONFIG_ROOT/authentik/data/media/public/, which it serves itself — checked
# in its source, 2026.8) or as an address. The kit's files are copied into
# mediastack/ there, named by their content (a changed file is a new name,
# so no browser keeps the old one), and files no longer wanted are removed.
#
# Each value is set while it is authentik's own or the one mediastack set
# last (local/state, per value); one set in authentik's screens is yours and
# stays. A kit file taken away puts authentik's own back. Sourced by the
# entrypoint.

AUTHENTIK_KIT_DIR=mediastack                                       # mediastack's folder in authentik's media
AUTHENTIK_SIGNIN_FLOW=default-authentication-flow                  # authentik's own sign-in, which the portal uses
# authentik's own values (2026.8): what an empty kit leaves, or puts back
declare -A AUTHENTIK_KIT_DEFAULT=(
    [branding_logo]=/static/dist/assets/icons/icon_left_brand.svg
    [branding_favicon]=/static/dist/assets/icons/icon.png
    [branding_default_flow_background]=/static/dist/assets/images/flow_background.jpg
    [branding_custom_css]=""
    [title]="Welcome to authentik!"
    [meta_icon]=""
)

authentik_media_dir() { echo "$(authentik_dir)/data/media/public/$AUTHENTIK_KIT_DIR"; }

authentik_kit_name() { # authentik_kit_name SRC KIND -> its name in authentik's media: mediastack/KIND-<content hash>.<ext>
    echo "$AUTHENTIK_KIT_DIR/$2-$(sha256sum < "$1" | cut -c1-12).$(brand_file_kind "$1")"
}

authentik_accent_css() { # authentik_accent_css RRGGBB -> authentik's buttons and links in that colour ("" for none)
    [[ -n "$1" ]] || return 0
    # authentik's brand layer comes last: these custom properties win over its
    # theme in every component (checked live: the sign-in button, hover darker)
    printf ':root { --pf-global--primary-color--100: #%s; --pf-global--primary-color--dark-100: #%s; --pf-global--primary-color--200: color-mix(in oklab, #%s 70%%, black); --pf-global--primary-color--light-100: color-mix(in oklab, #%s 60%%, white); --pf-global--link--Color: #%s; --pf-global--link--Color--dark: #%s; --pf-global--link--Color--light: color-mix(in oklab, #%s 60%%, white); --pf-global--link--Color--hover: color-mix(in oklab, #%s 70%%, black); --pf-global--link--Color--dark--hover: color-mix(in oklab, #%s 70%%, black); --pf-global--link--Color--light--hover: color-mix(in oklab, #%s 40%%, white); }' \
        "$1" "$1" "$1" "$1" "$1" "$1" "$1" "$1" "$1" "$1"
}

authentik_kit_decide() { # authentik_kit_decide CUR WANT DEFAULT MINE -> same | set | yours
    if [[ "$1" == "$2" ]]; then echo same
    elif [[ -z "$1" || "$1" == "$3" || ( -n "$4" && "$1" == "$4" ) ]]; then echo set
    else echo yours; fi
}

AK_KIT_FILES=()   # SRC<TAB>NAME of every file the portal is given now (authentik_kit_collect)
AK_ICON_APPS=()   # every mediastack card by its key: an app's service, or getting-started (authentik_kit_collect)
# the "Start here" card (the portal setup's own) shows the kit's icon: yours, else mediastack's
authentik_card_slug() { if [[ "$1" == getting-started ]]; then echo mediastack-getting-started; else echo "mediastack-app-$1"; fi; }
authentik_card_src()  { if [[ "$1" == getting-started ]]; then brand_icon; else brand_app_icon "$1"; fi; }
authentik_kit_collect() { # the files the kit gives the portal now — yours that pass their check, and each card's icon; rc 1 when the cards are unreadable
    local k f all slug s src
    AK_KIT_FILES=(); AK_ICON_APPS=()
    for k in logo icon background; do
        f=$(brand_yours "$k"); [[ -n "$f" && -z "$(brand_file_problem "$k" "$f")" ]] || continue
        AK_KIT_FILES+=("$f"$'\t'"$(authentik_kit_name "$f" "$k")")
    done
    all=$(ak_api GET "/core/applications/?superuser_full_list=true&page_size=500") || { wfail "authentik: applications unreadable — the cards' icons unchecked"; return 1; }
    for slug in $(jq -r '.results[].slug | select(startswith("mediastack-app-") or . == "mediastack-getting-started")' <<<"$all"); do
        s=${slug#mediastack-app-}; [[ "$slug" != mediastack-getting-started ]] || s=getting-started
        AK_ICON_APPS+=("$s")
        src=$(authentik_card_src "$s"); [[ -n "$src" && -z "$(brand_icon_problem "$src")" ]] || continue
        AK_KIT_FILES+=("$src"$'\t'"$(authentik_kit_name "$src" "icons/$s")")
    done
}

authentik_kit_files() { # the files AK_KIT_FILES names where authentik reads them, its own; every other file of mediastack's there removed
    local pub dir uid gid line src name keep=() f d
    dir=$(authentik_media_dir); pub=${dir%/*}; uid=$(env_get AUTHENTIK_UID); gid=$(env_get MEDIA_GROUP_GID)
    # authentik makes media/public at its first upload: made here first, it is authentik's all the same
    for d in "${pub%/*}" "$pub" "$dir" "$dir/icons"; do sudo test -d "$d" || sudo install -d -m 755 -o "$uid" -g "$gid" "$d"; done
    for line in "${AK_KIT_FILES[@]}"; do
        src=${line%%$'\t'*}; name=${line#*$'\t'}; keep+=("$name")
        sudo test -e "$pub/$name" || sudo install -m 644 -o "$uid" -g "$gid" "$src" "$pub/$name"
    done
    while IFS= read -r f; do
        [[ " ${keep[*]} " == *" ${f#"$pub"/} "* ]] || sudo rm -f "$f"
    done < <(sudo find "$dir" -type f)
    return 0
}

authentik_kit_field() { # authentik_kit_field LABEL STATE-KEY CUR WANT DEFAULT -> rc 0 when it is to be set (said); the rest said here
    local d mine
    mine=$(state_get "authentik-kit-$2")
    d=$(authentik_kit_decide "$3" "$4" "$5" "$mine")
    case "$d" in
        same)  return 1 ;;
        yours) ok "authentik: $1 was set in its own screens — yours, untouched"; return 1 ;;
        set)   w_would "authentik: $1 — $([[ "$4" == "$5" ]] && echo "authentik's own" || echo "the kit's")" ;;
    esac
}

authentik_brand_apply() { # the kit onto the portal: its brand, the sign-in title, the cards' icons, the emails' accent
    local brand uuid cur body="{}" k want label dirty=() title flow f p kind
    declare -A wants=()
    # your file's name in authentik's media, or authentik's own; an unusable
    # file of yours: nothing (the portal keeps what it shows, said)
    for k in branding_logo branding_favicon branding_default_flow_background; do
        case "$k" in branding_logo) kind=logo ;; branding_favicon) kind=icon ;; *) kind=background ;; esac
        f=$(brand_yours "$kind")
        if [[ -z "$f" ]]; then wants[$k]=${AUTHENTIK_KIT_DEFAULT[$k]}; continue; fi
        p=$(brand_file_problem "$kind" "$f")
        if [[ -n "$p" ]]; then wants[$k]=""; wfail "authentik: your $kind is unusable, the portal keeps what it shows — $p (./mediastack.sh brand)"
        else wants[$k]=$(authentik_kit_name "$f" "$kind"); fi
    done
    wants[branding_custom_css]=$(authentik_accent_css "$(env_get BRAND_ACCENT)")
    brand=$(ak_api GET "/core/brands/?domain=authentik-default") || { wfail "authentik: its brand is unreadable: $(oneline "$brand")"; return 0; }
    uuid=$(jq -r '.results[0].brand_uuid // empty' <<<"$brand")
    [[ -n "$uuid" ]] || { wfail "authentik: its default brand is missing — has the portal's setup applied? ./mediastack.sh doctor"; return 0; }
    for k in branding_logo branding_favicon branding_default_flow_background branding_custom_css; do
        want=${wants[$k]}
        # an unusable file of yours: nothing wanted, nothing changed (said above)
        [[ -n "$want" || "$k" == branding_custom_css ]] || continue
        case "$k" in
            branding_logo) label="the logo" ;; branding_favicon) label="the tab icon" ;;
            branding_default_flow_background) label="the sign-in background" ;; branding_custom_css) label="the accent colour" ;;
        esac
        cur=$(jq -r --arg k "$k" '.results[0][$k] // ""' <<<"$brand")
        if authentik_kit_field "$label" "$k" "$cur" "$want" "${AUTHENTIK_KIT_DEFAULT[$k]}"; then
            body=$(jq -c --arg k "$k" --arg v "$want" '.[$k] = $v' <<<"$body"); dirty+=("$k")
        fi
    done
    title="Welcome to $(env_get PORTAL_TITLE)"
    flow=$(ak_api GET "/flows/instances/$AUTHENTIK_SIGNIN_FLOW/") || { wfail "authentik: its sign-in flow ($AUTHENTIK_SIGNIN_FLOW) is unreadable: $(oneline "$flow")"; flow=""; }
    (( WIRE_DRY )) && return 0
    authentik_kit_collect || return 0
    # the files first: a value naming one authentik cannot read yet would show nothing
    authentik_kit_files
    if (( ${#dirty[@]} )); then
        if ak_api PATCH "/core/brands/$uuid/" "$body" >/dev/null; then
            for k in "${dirty[@]}"; do state_set "authentik-kit-$k" "${wants[$k]}"; done
            ok "authentik: the portal's look follows the kit"
        else
            wfail "authentik refused the kit for its brand (./mediastack.sh brand)"
        fi
    fi
    if [[ -n "$flow" ]] && authentik_kit_field "the sign-in title" title "$(jq -r '.title // ""' <<<"$flow")" "$title" "${AUTHENTIK_KIT_DEFAULT[title]}"; then
        ak_api PATCH "/flows/instances/$AUTHENTIK_SIGNIN_FLOW/" "$(jq -cn --arg t "$title" '{title:$t}')" >/dev/null \
            && { state_set authentik-kit-title "$title"; ok "authentik: sign-in says \"$title\""; } \
            || wfail "authentik refused the sign-in title"
    fi
    authentik_app_icons
    # the emails' button takes the accent (a changed template restarts authentik to read it)
    authentik_templates_sync
}

authentik_app_icons() { # every mediastack card shows its app's icon (yours, else the shipped one; none: authentik's letter) — after authentik_kit_collect and _files
    local all s app want src p n=0
    all=$(ak_api GET "/core/applications/?superuser_full_list=true&page_size=500") || { wfail "authentik: applications unreadable — the cards' icons unchecked"; return 0; }
    for s in "${AK_ICON_APPS[@]}"; do
        app=$(jq -c --arg sl "$(authentik_card_slug "$s")" '[.results[] | select(.slug == $sl)][0] // empty' <<<"$all"); [[ -n "$app" ]] || continue
        src=$(authentik_card_src "$s"); want=""
        if [[ -n "$src" ]]; then
            p=$(brand_icon_problem "$src")
            if [[ -n "$p" ]]; then wfail "authentik: $s's icon is unusable, its card keeps what it shows — $p"; continue; fi
            want=$(authentik_kit_name "$src" "icons/$s")
        fi
        authentik_kit_field "$s's card icon" "icon-$s" "$(jq -r '.meta_icon // ""' <<<"$app")" "$want" "" || continue
        ak_api PATCH "/core/applications/$(authentik_card_slug "$s")/" "$(jq -cn --arg i "$want" '{meta_icon:$i}')" >/dev/null \
            && { state_set "authentik-kit-icon-$s" "$want"; n=$((n + 1)); } \
            || wfail "authentik refused $s's card icon"
    done
    (( n == 0 )) || ok "authentik: $n card icon(s) set"
}

authentik_kit_icons() { # the cards' icons alone (after the cards change: access, wire's cards)
    (( WIRE_DRY )) && return 0
    authentik_kit_collect || return 0
    authentik_kit_files
    authentik_app_icons
}
