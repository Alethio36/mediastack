#!/usr/bin/env bash
# services/jellyfin/kit.sh — the household's kit (lib/brand.sh) on Jellyfin,
# whose own sign-in page everyone sees (the web, and the TV and phone apps:
# they sign in with the portal's password through Jellyfin's LDAP plugin).
# Jellyfin's branding settings (12.4, checked in its source and live):
#   accent      its web client's main colour, through its own colour variables
#               (--jf-palette-*), in its custom CSS between two marker lines —
#               CSS of your own there stays. Some parts it draws in a fixed
#               blue (sliders, toggles, the loading ring) stay blue.
#   background  uploaded as the picture behind its sign-in page (its
#               "splashscreen"), which it then shows (SplashscreenEnabled)
#   sign-in     with the portal: a line under the form, the household's name
#               and that the password is the portal's (its login disclaimer)
# The logo is not taken: only a picture inside its CSS could replace its
# banner, sent with every page. Each value is set while it is Jellyfin's own
# or the one mediastack set last (local/state); the picture Jellyfin keeps
# cannot be read back, so mediastack replaces only the one it uploaded.
# Sourced by the entrypoint.

JF_KIT_BEGIN="/* >>> mediastack: the kit's accent (./mediastack.sh brand) — your own CSS goes outside these two lines */"
JF_KIT_END="/* <<< mediastack */"

jellyfin_kit_css() { # jellyfin_kit_css RRGGBB -> mediastack's block of Jellyfin's CSS (nothing without an accent)
    [[ -n "$1" ]] || return 0
    local rgb="$((16#${1:0:2})) $((16#${1:2:2})) $((16#${1:4:2}))"
    printf '%s\n%s\n%s\n' "$JF_KIT_BEGIN" \
        ":root[data-theme] { --jf-palette-primary-main: #$1; --jf-palette-primary-mainChannel: $rgb; --jf-palette-primary-dark: color-mix(in oklab, #$1 70%, black); --jf-palette-secondary-main: #$1; --jf-palette-secondary-mainChannel: $rgb; }" \
        "$JF_KIT_END"
}

jellyfin_css_merge() { # jellyfin_css_merge CURRENT BLOCK -> Jellyfin's CSS with mediastack's block replaced (or added at the end; empty BLOCK: taken out)
    local cur=$1 block=$2 out
    out=$(awk -v b="$JF_KIT_BEGIN" -v e="$JF_KIT_END" '$0 == b { skip = 1; next } skip && $0 == e { skip = 0; next } !skip' <<<"$cur")
    if [[ -n "$block" ]]; then printf '%s%s' "${out:+$out$'\n'}" "$block"; else printf '%s' "$out"; fi
}

jellyfin_kit_disclaimer() { # -> the sign-in line: with the portal, the household's name and that its password is the portal's
    signin_is authentik || return 0
    local n; n=$(env_get PORTAL_TITLE)
    n=${n//\\/\\\\}; n=${n//\*/\\*}; n=${n//_/\\_}; n=${n//\[/\\[}; n=${n//</&lt;}   # the name is text, never markdown or markup
    echo "Sign in with your **$n** account — the same username and password as the portal."
}

jellyfin_splash_upload() { # jellyfin_splash_upload TOKEN FILE — the picture behind its sign-in page (rc from HTTP)
    local ty
    case "$(brand_file_kind "$2")" in png) ty=image/png ;; jpg) ty=image/jpeg ;; *) return 1 ;; esac
    base64 -w0 < "$2" | scurl -fsS -m 60 -X POST -H "$(jf_auth_hdr "$1")" -H "Content-Type: $ty" --data-binary @- "$(jf_url)/Branding/Splashscreen" >/dev/null
}

jellyfin_brand_apply() { # the kit onto Jellyfin: its accent, the picture behind its sign-in, the sign-in line
    local tok cur css want disc mine bg hash have_hash on body changed=() p
    tok=$(env_get JELLYFIN_API_KEY)
    [[ -n "$tok" ]] || { info "jellyfin: no API key yet — it takes the kit at: ./mediastack.sh wire jellyfin"; return 0; }
    cur=$(jf_api GET /Branding/Configuration "$tok") || { wfail "jellyfin: its branding is unreadable [HTTP $(jf_code)]"; return 0; }
    body=$cur
    # the accent: mediastack's block of its CSS, whatever else is there
    css=$(jq -r '.CustomCss // ""' <<<"$cur")
    want=$(jellyfin_css_merge "$css" "$(jellyfin_kit_css "$(env_get BRAND_ACCENT)")")
    if [[ "$css" != "$want" ]] && w_would "jellyfin: its accent — $([[ -n "$(env_get BRAND_ACCENT)" ]] && echo "the kit's" || echo "its own")"; then
        body=$(jq -c --arg c "$want" '.CustomCss = $c' <<<"$body"); changed+=(accent)
    fi
    # the sign-in line: set while it is empty or the one mediastack set
    disc=$(jq -r '.LoginDisclaimer // ""' <<<"$cur"); want=$(jellyfin_kit_disclaimer); mine=$(state_get jellyfin-kit-disclaimer)
    case "$(brand_decide "$disc" "$want" "" "$mine")" in
        set)   if w_would "jellyfin: the line under its sign-in — $([[ -n "$want" ]] && echo "the portal's password" || echo "none")"; then
                   body=$(jq -c --arg d "$want" '.LoginDisclaimer = $d' <<<"$body"); changed+=(disclaimer); fi ;;
        yours) ok "jellyfin: the line under its sign-in was written in its dashboard — yours, untouched" ;;
    esac
    # the picture behind its sign-in: the kit's background, uploaded when it changed
    bg=$(brand_yours background); hash=""; have_hash=$(state_get jellyfin-kit-splash)
    if [[ -n "$bg" ]]; then
        p=$(brand_file_problem background "$bg")
        if [[ -n "$p" ]]; then wfail "jellyfin: your background is unusable, its sign-in keeps what it shows — $p"; bg=""; have_hash=""
        else hash=$(sha256sum < "$bg" | cut -c1-16); fi
    fi
    on=$(jq -r '.SplashscreenEnabled' <<<"$cur")
    if [[ -n "$hash" && "$hash" != "$have_hash" ]] && w_would "jellyfin: the kit's background behind its sign-in"; then
        if (( ! WIRE_DRY )); then
            if jellyfin_splash_upload "$tok" "$bg"; then state_set jellyfin-kit-splash "$hash"; changed+=(picture)
            else wfail "jellyfin refused the background as its sign-in picture"; hash=""; fi
        fi
    elif [[ -z "$hash" && -z "$bg" && -n "$have_hash" ]] && w_would "jellyfin: its own picture behind its sign-in again"; then
        if (( ! WIRE_DRY )); then
            if scurl -fsS -m 20 -X DELETE -H "$(jf_auth_hdr "$tok")" "$(jf_url)/Branding/Splashscreen" >/dev/null; then state_del jellyfin-kit-splash; changed+=(picture)
            else wfail "jellyfin refused to remove the kit's sign-in picture"; fi
        fi
    fi
    if [[ -n "$hash" && "$on" != true ]]; then
        body=$(jq -c '.SplashscreenEnabled = true' <<<"$body"); changed+=(picture); state_set jellyfin-kit-splash-on 1
    elif [[ -z "$hash" && -z "$bg" && "$on" == true && -n "$(state_get jellyfin-kit-splash-on)" ]]; then
        body=$(jq -c '.SplashscreenEnabled = false' <<<"$body"); changed+=(picture); state_del jellyfin-kit-splash-on
    fi
    (( WIRE_DRY )) && return 0
    if (( ${#changed[@]} )); then
        jf_api POST /System/Configuration/Branding "$tok" "$(jq -c '{LoginDisclaimer, CustomCss, SplashscreenEnabled}' <<<"$body")" >/dev/null \
            || { wfail "jellyfin refused the kit for its branding [HTTP $(jf_code)]"; return 0; }
        [[ " ${changed[*]} " != *" disclaimer "* ]] || state_set jellyfin-kit-disclaimer "$(jq -r '.LoginDisclaimer // ""' <<<"$body")"
        ok "jellyfin: its look follows the kit"
    else
        ok "jellyfin: its look is the kit's"
    fi
}
