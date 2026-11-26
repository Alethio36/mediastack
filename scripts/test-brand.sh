#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-brand.sh — the household's kit (lib/brand.sh) and where it shows.
#   * the icon is checked before anything uses it: a PNG, square, 128-1024
#     pixels a side, at most 1 MiB; yours in custom/branding/ wins, else the
#     shipped one (which passes its own check)
#   * a colour is six hex digits, the # optional, stored upper case; default
#     removes it from .env so the schema's value applies
#   * a name Discord refuses as a sender's is named before anything is sent
#   * the colours reach both places a card takes them: Apprise's own map
#     (compose, the hub's start-up setting) and Seerr's entries (rendered);
#     the map's defaults are the schema's
#   * applying with the hub off changes nothing and says when it will apply
#
#   scripts/test-brand.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-brand.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }
STATE_DIR=$T/state; LOCAL_DIR=$T; ENV_FILE=$T/.env; : > "$ENV_FILE"
CUSTOM_DIR=$T/custom; BRAND_DIR=$CUSTOM_DIR/branding
load_env() { :; }; render() { :; }

be32() { printf "$(printf '\\x%02x' $(( $1 >> 24 & 255 )) $(( $1 >> 16 & 255 )) $(( $1 >> 8 & 255 )) $(( $1 & 255 )))"; }   # a 4-byte big-endian number
png() { # png W H [EXTRA-BYTES] -> a file with a PNG's header saying W x H
    local f=$T/p$1x$2.png
    { printf '\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR'; be32 "$1"; be32 "$2"; head -c "${3:-64}" /dev/zero; } > "$f"
    echo "$f"
}

# ---- the icon ----
[[ -z "$(brand_icon_problem "$SCRIPT_DIR/$BRAND_ICON_SHIPPED")" ]] || fail_ "the shipped icon passes its own check: $(brand_icon_problem "$SCRIPT_DIR/$BRAND_ICON_SHIPPED")"; pass
[[ -z "$(brand_icon_problem "$(png 256 256)")" ]] || fail_ "a square PNG of 256: fine"; pass
[[ "$(brand_icon_problem "$(png 256 200)")" == *"256x200 — an icon must be square"* ]] || fail_ "not square: said"; pass
[[ "$(brand_icon_problem "$(png 64 64)")" == *"128 to 1024 pixels"* ]] || fail_ "too small: said"; pass
[[ "$(brand_icon_problem "$(png 2048 2048)")" == *"128 to 1024 pixels"* ]] || fail_ "too large: said"; pass
[[ "$(brand_icon_problem "$(png 512 512 1100000)")" == *"the most for the icon is 1024 KiB"* ]] || fail_ "over 1 MiB: said"; pass
printf '\xff\xd8\xff\xe0 a jpeg' > "$T/j.jpg"
[[ "$(brand_icon_problem "$T/j.jpg")" == *"is not a PNG"* ]] || fail_ "a JPEG: not a PNG, said"; pass
[[ "$(brand_icon_problem "$T/none.png")" == *"not a readable file"* ]] || fail_ "missing: said"; pass
[[ "$(brand_icon)" == "$SCRIPT_DIR/$BRAND_ICON_SHIPPED" ]] || fail_ "no icon of yours: the shipped one"; pass

hub_enabled() { return 1; }
brand_file_set icon "$(png 300 300)" > "$T/out"
cmp -s "$T/p300x300.png" "$BRAND_DIR/icon.png" && [[ "$(brand_icon)" == "$BRAND_DIR/icon.png" && "$(stat -c %a "$BRAND_DIR/icon.png")" == 644 ]] \
    || fail_ "brand icon FILE: copied into custom/branding/ and used"; pass
grep -q "the kit reaches it at its next start" "$T/out" || fail_ "the hub off: nothing applied, and said when: $(cat "$T/out")"; pass
( brand_file_set icon "$(png 300 200)" ) >/dev/null 2>"$T/err" && fail_ "an unusable icon: refused"
cmp -s "$T/p300x300.png" "$BRAND_DIR/icon.png" || fail_ "an unusable icon refused: yours stays as it was"; pass
brand_file_set icon default >/dev/null
[[ ! -e "$BRAND_DIR/icon.png" && "$(brand_icon)" == "$SCRIPT_DIR/$BRAND_ICON_SHIPPED" ]] || fail_ "brand icon default: the shipped one again"; pass

# ---- the colours ----
[[ "$(brand_colour_value '#2e8b57')" == 2E8B57 && "$(brand_colour_value 2E8B57)" == 2E8B57 ]] || fail_ "a colour: # optional, stored upper case"; pass
for bad in '#2E8B5' 2E8B57A 'green' '#GG0000' ''; do brand_colour_value "$bad" >/dev/null && fail_ "'$bad' is not a colour"; done; pass
[[ "$(brand_colour success)" == "#${ENV_DEFAULT[BRAND_COLOUR_SUCCESS]}" ]] || fail_ "unset: the schema's colour"; pass
brand_colour_set success '#2e8b57' >/dev/null
grep -qx 'BRAND_COLOUR_SUCCESS=2E8B57' "$ENV_FILE" && [[ "$(brand_colour success)" == "#2E8B57" ]] || fail_ "brand colour: stored in .env: $(cat "$ENV_FILE")"; pass
( brand_colour_set success green ) >/dev/null 2>&1 && fail_ "a colour that is none: refused"
grep -qx 'BRAND_COLOUR_SUCCESS=2E8B57' "$ENV_FILE" || fail_ "refused: the colour stays"; pass
( brand_colour_set purple '#2e8b57' ) >/dev/null 2>&1 && fail_ "an unknown type: refused"; pass
# the colour shown as itself on a terminal (24-bit), nothing in a log
[[ -z "$(brand_swatch 2E8B57)" ]] || fail_ "no terminal: no swatch"; pass
[[ "$(C_RST=$'\e[0m'; brand_swatch 2E8B57)" == $'\e[48;2;46;139;87m  \e[0m ' ]] || fail_ "a terminal: a block in the colour itself"; pass
env_type_ok hex 2E8B57 && ! env_type_ok hex '#2E8B57' || fail_ ".env's hex type: six digits, no #"; pass

# Seerr's cards take the kit's colour; the defaults are Apprise's own
NOTIFY_MODEL=$'ops\tdiscord://111/tokA'; NOTIFY_YOURS=""
hostname() { echo testhost; }
got=$(notify_cfg_render)
grep -q ":color=$((16#2E8B57))&" <<<"$got" || fail_ "Seerr's success cards: the kit's colour: $got"; pass
grep -q ":color=$((16#${ENV_DEFAULT[BRAND_COLOUR_FAILURE]}))&" <<<"$got" || fail_ "the colours left alone: the schema's"; pass
brand_colour_set success default >/dev/null
! grep -q BRAND_COLOUR_SUCCESS "$ENV_FILE" && [[ "$(brand_colour success)" == "#${ENV_DEFAULT[BRAND_COLOUR_SUCCESS]}" ]] || fail_ "brand colour default: out of .env"; pass

# mediastack's own cards take Apprise's map: the hub's start-up setting, the schema's defaults
map=$(grep -o "APPRISE_ASSET_HTML_NOTIFY_MAP=.*'" services/apprise/compose.yml)
for t in "${BRAND_TYPES[@]}"; do
    grep -qF "\"$t\":\"#\${BRAND_COLOUR_${t^^}:-${ENV_DEFAULT[BRAND_COLOUR_${t^^}]}}\"" <<<"$map" || fail_ "the hub's map: $t from the kit, the schema's default: $map"; pass
done
sed -E "s/^APPRISE_ASSET_HTML_NOTIFY_MAP=//; s/'$//; s/\\$\\{[A-Z_]+:-([0-9A-F]{6})\\}/\\1/g" <<<"$map" | jq -e 'keys == ["failure","info","success","warning"]' >/dev/null \
    || fail_ "the map is JSON with Apprise's four types once compose fills it: $map"; pass

# ---- the name ----
[[ -z "$(brand_name_discord_problem 'Our House')" ]] || fail_ "an ordinary name: fine"; pass
[[ "$(brand_name_discord_problem 'Movie Discord')" == *'"discord" or "clyde"'* && -n "$(brand_name_discord_problem 'CLYDE')" ]] || fail_ "Discord's refused words: said"; pass
[[ "$(brand_name_discord_problem "$(printf 'x%.0s' {1..81})")" == *"1 to 80"* ]] || fail_ "too long: said"; pass

# ---- the portal's files ----
[[ -z "$(brand_file_problem logo "$(png 600 150)")" ]] || fail_ "a logo: any shape of PNG"; pass
[[ "$(brand_file_problem logo "$T/j.jpg")" == *"not a PNG"* ]] || fail_ "a logo that is a JPEG: said"; pass
[[ -z "$(brand_file_problem background "$T/j.jpg")" && -z "$(brand_file_problem background "$(png 1920 1080)")" ]] || fail_ "a background: a JPEG or a PNG"; pass
printf 'GIF89a......' > "$T/g.gif"
[[ "$(brand_file_problem background "$T/g.gif")" == *"neither a PNG nor a JPEG"* ]] || fail_ "a GIF background: said"; pass
head -c 6000000 /dev/zero > "$T/big.jpg"; printf '\xff\xd8\xff' | dd of="$T/big.jpg" conv=notrunc 2>/dev/null
[[ "$(brand_file_problem background "$T/big.jpg")" == *"the most for the background is 5120 KiB"* ]] || fail_ "a background over 5 MiB: said"; pass
brand_apply_apps() { echo "PORTAL" >> "$T/applied"; }; brand_apply_messages() { echo "MESSAGES" >> "$T/applied"; }
: > "$T/applied"; brand_file_set background "$(png 1920 1080)" >/dev/null
[[ -e "$BRAND_DIR/background.png" && "$(brand_yours background)" == "$BRAND_DIR/background.png" && "$(cat "$T/applied")" == PORTAL ]] || fail_ "brand background: stored, the portal told"; pass
cp "$T/j.jpg" "$T/bg.jpg"; brand_file_set background "$T/bg.jpg" >/dev/null
[[ ! -e "$BRAND_DIR/background.png" && -e "$BRAND_DIR/background.jpg" ]] || fail_ "a JPEG background replaces the PNG one: one background, by its kind"; pass
: > "$T/applied"; brand_file_set icon "$(png 256 256)" >/dev/null
[[ "$(paste -sd' ' "$T/applied")" == "MESSAGES PORTAL" ]] || fail_ "the icon: both the messages and the portal take it"; pass
brand_file_set icon default >/dev/null; brand_file_set background default >/dev/null
[[ -z "$(brand_yours icon)$(brand_yours background)" ]] || fail_ "default: yours removed"; pass

# ---- the apps' icons: shipped, every one usable; yours first ----
n=0; for f in services/*/icon.png; do
    p=$(brand_icon_problem "$f"); [[ -z "$p" ]] || fail_ "a shipped icon: $p"; n=$((n + 1))
done; (( n >= 20 )) || fail_ "an icon ships for each app with a card ($n)"; pass
# their licences honoured (Apache-2.0 §4, MIT): the licence texts shipped, each file naming its source,
# copyright, licence and the change made to it, and the notice naming them
for f in services/*/icon.png; do
    for k in Source Copyright License Modified Trademark; do grep -aq "$k" "$f" || fail_ "$f: no $k field (services/NOTICE-icons.md)"; done
    lic=$(grep -ao 'LICENSES/[A-Za-z0-9.-]*\.txt' "$f" | sed -n 1p)
    [[ -n "$lic" && -s "$lic" ]] || fail_ "$f names a licence file that is not shipped: '$lic'"
    pass
done
grep -q 'Copyright (c) 2024 Bjorn Lammers' LICENSES/dashboard-icons.Apache-2.0.txt && grep -q 'Copyright (c) 2024 ArabCoders' LICENSES/watchstate.MIT.txt \
    && grep -q 'LICENSES/dashboard-icons.Apache-2.0.txt' services/NOTICE-icons.md && grep -q 'LICENSES/watchstate.MIT.txt' services/NOTICE-icons.md \
    && grep -q 'services/NOTICE-icons.md' README.md || fail_ "the icons' licences: shipped, named in the notice, credited in the README"; pass
[[ "$(brand_app_icon jellyfin)" == "$SCRIPT_DIR/services/jellyfin/icon.png" && -z "$(brand_app_icon nosuchapp)" ]] || fail_ "an app's icon: the shipped one; none: nothing"; pass
brand_app_icon_set jellyfin "$(png 200 200)" >/dev/null
[[ "$(brand_app_icon jellyfin)" == "$BRAND_DIR/icons/jellyfin.png" ]] || fail_ "brand app-icon: yours first"; pass
( brand_app_icon_set '../x' "$(png 200 200)" ) >/dev/null 2>&1 && fail_ "a service name with a path in it: refused"; pass
( brand_app_icon_set kavita "$(png 200 100)" ) >/dev/null 2>&1 && fail_ "a card icon that is not square: refused"; pass
brand_app_icon_set jellyfin default >/dev/null
[[ "$(brand_app_icon jellyfin)" == "$SCRIPT_DIR/services/jellyfin/icon.png" ]] || fail_ "app-icon default: the shipped one again"; pass

# ---- the portal: what is set, and what is left ----
for c in "same:a:a:d:" "set:d:a:d:" "set::a:d:" "set:m:a:d:m" "yours:u:a:d:m" "yours:u:a:d:"; do
    IFS=: read -r want cur w d mine <<<"$c"
    [[ "$(brand_decide "$cur" "$w" "$d" "$mine")" == "$want" ]] || fail_ "decide cur=$cur want=$w default=$d mine=$mine: $want"; pass
done
css=$(authentik_accent_css E6701E)
[[ "$css" == ':root {'* && "$css" == *'--pf-global--primary-color--100: #E6701E'* && "$css" == *'--pf-global--link--Color: #E6701E'* ]] || fail_ "the accent: buttons and links: $css"; pass
[[ -z "$(authentik_accent_css "")" ]] || fail_ "no accent: no CSS (authentik's own)"; pass
[[ "$(authentik_kit_name "$T/p256x256.png" logo)" =~ ^mediastack/logo-[0-9a-f]{12}\.png$ && "$(authentik_kit_name "$T/j.jpg" background)" == mediastack/background-*.jpg ]] \
    || fail_ "a file's name in authentik's media: by kind and content"; pass
[[ "$(authentik_email_accent)" == 2563eb ]] || fail_ "the emails' button: their blue without an accent"; pass
echo BRAND_ACCENT=E6701E >> "$ENV_FILE"
h=$(authentik_template_render services/authentik/templates/mediastack-invitation.html X)
[[ "$h" == *'background:#E6701E'* && "$h" != *'@@'* ]] || fail_ "the emails' button takes the accent"; pass

# the brand, against a stub of authentik's API: PATCH bodies recorded
WIRE_DRY=0; AKB=$T/akb.json; AKF=$T/akf.json; AKA=$T/aka.json; AKP=$T/akpatch
echo '{"results":[{"brand_uuid":"u1","branding_logo":"/static/dist/assets/icons/icon_left_brand.svg","branding_favicon":"/static/dist/assets/icons/icon.png","branding_default_flow_background":"/static/dist/assets/images/flow_background.jpg","branding_custom_css":""}]}' > "$AKB"
echo '{"title":"Welcome to authentik!"}' > "$AKF"
echo '{"results":[{"slug":"mediastack-app-jellyfin","meta_icon":""},{"slug":"mediastack-app-kavita","meta_icon":"my/own.png"},{"slug":"mediastack-getting-started","meta_icon":""},{"slug":"other-card","meta_icon":""}]}' > "$AKA"
ak_api() {
    case "$1 $2" in
        "GET /core/brands/"*) cat "$AKB" ;;
        "GET /flows/instances/"*) cat "$AKF" ;;
        "GET /core/applications/"*) cat "$AKA" ;;
        PATCH*) echo "$2 $3" >> "$AKP"
            case "$2" in
                /core/brands/*) jq -c --argjson p "$3" '.results[0] += $p' "$AKB" > "$AKB.n" && mv "$AKB.n" "$AKB" ;;
                /flows/*) jq -c --argjson p "$3" '. += $p' "$AKF" > "$AKF.n" && mv "$AKF.n" "$AKF" ;;
                /core/applications/*) jq -c --arg sl "${2#/core/applications/}" --argjson p "$3" '.results |= map(if .slug == ($sl | rtrimstr("/")) then . + $p else . end)' "$AKA" > "$AKA.n" && mv "$AKA.n" "$AKA" ;;
            esac ;;
        *) return 1 ;;
    esac
}
authentik_dir() { echo "$T/ak"; }
sudo() { local a=() skip=0 x; for x in "$@"; do if (( skip )); then skip=0; continue; fi; case "$x" in -o|-g) skip=1 ;; *) a+=("$x") ;; esac; done; "${a[@]}"; }
authentik_templates_sync() { :; }
http_ready() { :; }   # the portal answers ready (its wait: the case further down)
echo 'PORTAL_TITLE="Our House"' >> "$ENV_FILE"
brand_file_set logo "$(png 600 150)" >/dev/null 2>&1 || true   # stored; brand_apply_apps is the stub here
: > "$AKP"; authentik_brand_apply > "$T/out" 2>&1
logo=$(jq -r '.results[0].branding_logo' "$AKB")
[[ "$logo" =~ ^mediastack/logo-[0-9a-f]{12}\.png$ && -e "$T/ak/data/media/public/$logo" ]] || fail_ "the logo: copied into authentik's media, the brand names it: $logo"; pass
[[ "$(jq -r '.results[0].branding_custom_css' "$AKB")" == *'#E6701E'* && "$(jq -r '.results[0].branding_favicon' "$AKB")" == /static/dist/assets/icons/icon.png ]] \
    || fail_ "the accent set; no icon of yours: authentik's tab icon stays"; pass
[[ "$(jq -r .title "$AKF")" == "Welcome to Our House" ]] || fail_ "the sign-in title: the household's name"; pass
[[ "$(jq -r '.results[] | select(.slug == "mediastack-app-jellyfin") | .meta_icon' "$AKA")" =~ ^mediastack/icons/jellyfin-[0-9a-f]{12}\.png$ ]] || fail_ "jellyfin's card: its shipped icon"; pass
[[ "$(jq -r '.results[] | select(.slug == "mediastack-app-kavita") | .meta_icon' "$AKA")" == my/own.png ]] && grep -q "kavita's card icon was set in its own screens" "$T/out" \
    || fail_ "an icon set in authentik's screens: yours, said, untouched"; pass
[[ "$(jq -r '.results[] | select(.slug == "mediastack-getting-started") | .meta_icon' "$AKA")" =~ ^mediastack/icons/getting-started-[0-9a-f]{12}\.png$ ]] \
    || fail_ "the Start here card: the kit's icon (found live: a bare letter)"; pass
! grep -q other-card "$AKP" || fail_ "a card that is not mediastack's: left alone"; pass
: > "$AKP"; authentik_brand_apply > "$T/out" 2>&1
[[ ! -s "$AKP" ]] || fail_ "the same kit again: nothing sent ($(cat "$AKP"))"; pass
jq -c '.results[0].branding_default_flow_background = "uploads/mine.jpg"' "$AKB" > "$AKB.n" && mv "$AKB.n" "$AKB"
brand_file_set background "$T/bg.jpg" >/dev/null 2>&1 || true
: > "$AKP"; authentik_brand_apply > "$T/out" 2>&1
[[ "$(jq -r '.results[0].branding_default_flow_background' "$AKB")" == uploads/mine.jpg ]] && grep -q "the sign-in background was set in its own screens" "$T/out" \
    || fail_ "a background set in authentik's screens: yours, even with one in the kit"; pass
old=$logo; rm -f "$BRAND_DIR/logo.png"; : > "$AKP"; authentik_brand_apply > "$T/out" 2>&1
[[ "$(jq -r '.results[0].branding_logo' "$AKB")" == /static/dist/assets/icons/icon_left_brand.svg && ! -e "$T/ak/data/media/public/$old" ]] \
    || fail_ "the kit's logo taken away: authentik's back, the file removed"; pass
printf 'not a png' > "$BRAND_DIR/logo.png"; : > "$AKP"; authentik_brand_apply > "$T/out" 2>&1
[[ "$(jq -r '.results[0].branding_logo' "$AKB")" == /static/dist/assets/icons/icon_left_brand.svg ]] && grep -q "your logo is unusable, the portal keeps what it shows" "$T/out" \
    || fail_ "an unusable logo of yours: said, nothing changed"; pass
rm -f "$BRAND_DIR/logo.png"

# ---- Jellyfin: the accent in its CSS (yours kept), its sign-in picture, the sign-in line ----
b=$(jellyfin_kit_css E6701E)
[[ "$(head -1 <<<"$b")" == "$JF_KIT_BEGIN" && "$(tail -1 <<<"$b")" == "$JF_KIT_END" && "$b" == *'--jf-palette-primary-mainChannel: 230 112 30;'* && "$b" == *'--jf-palette-secondary-main: #E6701E'* ]] \
    || fail_ "Jellyfin's accent: its own colour variables, between mediastack's markers: $b"; pass
[[ -z "$(jellyfin_kit_css "")" ]] || fail_ "no accent: no block"; pass
[[ "$(jellyfin_css_merge "" "$b")" == "$b" ]] || fail_ "no CSS before: the block alone"; pass
mine='.card { border-radius: 0; }'
[[ "$(jellyfin_css_merge "$mine" "$b")" == "$mine"$'\n'"$b" ]] || fail_ "your CSS first, mediastack's block after"; pass
[[ "$(jellyfin_css_merge "$(jellyfin_css_merge "$mine" "$b")" "$(jellyfin_kit_css 112233)")" == "$mine"$'\n'"$(jellyfin_kit_css 112233)" ]] || fail_ "a new accent: the block replaced, yours kept"; pass
[[ "$(jellyfin_css_merge "$mine"$'\n'"$b"$'\n''.x { y: z; }' "")" == "$mine"$'\n''.x { y: z; }' ]] || fail_ "no accent: the block taken out, all of yours kept"; pass
signin_model() { echo authentik; }
echo 'PORTAL_TITLE="A*B_C"' >> "$ENV_FILE"
[[ "$(jellyfin_kit_disclaimer)" == 'Sign in with your **A\*B\_C** account — the same username and password as the portal.' ]] || fail_ "the sign-in line: the name as text: $(jellyfin_kit_disclaimer)"; pass
signin_model() { echo jellyfin; }
[[ -z "$(jellyfin_kit_disclaimer)" ]] || fail_ "no portal: no sign-in line"; pass
signin_model() { echo authentik; }; echo 'PORTAL_TITLE="Our House"' >> "$ENV_FILE"

JFB=$T/jfb.json; echo '{"LoginDisclaimer":null,"CustomCss":"","SplashscreenEnabled":false}' > "$JFB"
jf_api() {
    case "$1 $2" in
        "GET /Branding/Configuration") cat "$JFB" ;;
        "POST /System/Configuration/Branding") echo "$4" > "$JFB"; echo POST >> "$T/jfcalls" ;;
        *) return 1 ;;
    esac
}
jf_code() { echo 200; }; jf_url() { echo http://jf; }
jellyfin_splash_upload() { echo "UPLOAD $2" >> "$T/jfcalls"; }
scurl() { [[ " $* " == *" DELETE "* ]] && echo DELETE >> "$T/jfcalls"; return 0; }
echo JELLYFIN_API_KEY=k >> "$ENV_FILE"; sed -i '/^BRAND_ACCENT=/d' "$ENV_FILE"; echo BRAND_ACCENT=E6701E >> "$ENV_FILE"
cp "$T/bg.jpg" "$BRAND_DIR/background.jpg"
: > "$T/jfcalls"; jellyfin_brand_apply > "$T/out" 2>&1
[[ "$(jq -r .CustomCss "$JFB")" == "$(jellyfin_kit_css E6701E)" && "$(jq -r .SplashscreenEnabled "$JFB")" == true ]] \
    && [[ "$(jq -r .LoginDisclaimer "$JFB")" == *'**Our House** account'* ]] && grep -q "^UPLOAD $BRAND_DIR/background.jpg$" "$T/jfcalls" \
    || fail_ "Jellyfin: the accent, the sign-in line, the background uploaded and shown: $(cat "$JFB") $(cat "$T/jfcalls")"; pass
: > "$T/jfcalls"; jellyfin_brand_apply > "$T/out" 2>&1
[[ ! -s "$T/jfcalls" ]] || fail_ "Jellyfin, the same kit again: nothing sent ($(cat "$T/jfcalls"))"; pass
jq -c '.LoginDisclaimer = "Ask Nick for an account." | .CustomCss = ".mine{}\n" + .CustomCss' "$JFB" > "$JFB.n" && mv "$JFB.n" "$JFB"
rm -f "$BRAND_DIR/background.jpg"; sed -i '/^BRAND_ACCENT=/d' "$ENV_FILE"
: > "$T/jfcalls"; jellyfin_brand_apply > "$T/out" 2>&1
[[ "$(jq -r .LoginDisclaimer "$JFB")" == "Ask Nick for an account." && "$(jq -r .CustomCss "$JFB")" == ".mine{}" && "$(jq -r .SplashscreenEnabled "$JFB")" == false ]] \
    && grep -qx DELETE "$T/jfcalls" && grep -q "written in its dashboard — yours, untouched" "$T/out" \
    || fail_ "the kit emptied: your line and CSS kept, mediastack's block and picture gone: $(cat "$JFB") $(cat "$T/jfcalls")"; pass
unset -f scurl jf_api

# ---- Seerr's title; the panel's ----
SEERR=$T/seerr.json; echo '{"applicationTitle":"Seerr"}' > "$SEERR"
scurl() { local a; for a in "$@"; do [[ "$a" == POST ]] && { jq -c --argjson p "$(sed -n 's/.*-d \({.*}\) .*/\1/p' <<<"$*")" '. + $p' "$SEERR" > "$SEERR.n" && mv "$SEERR.n" "$SEERR"; echo '{}'; return 0; }; done; cat "$SEERR"; }
seerr_url() { echo http://seerr; }; echo SEERR_API_KEY=s >> "$ENV_FILE"
seerr_brand_apply > "$T/out" 2>&1
[[ "$(jq -r .applicationTitle "$SEERR")" == "Our House" ]] || fail_ "Seerr's title: the household's name: $(cat "$SEERR")"; pass
echo '{"applicationTitle":"Film Club"}' > "$SEERR"; seerr_brand_apply > "$T/out" 2>&1
[[ "$(jq -r .applicationTitle "$SEERR")" == "Film Club" ]] && grep -q "yours, untouched" "$T/out" || fail_ "a title written in Seerr's settings: yours"; pass
unset -f scurl
echo 'PORTAL_TITLE="Tom \"&\" Co"' >> "$ENV_FILE"
grep -qxF 'pageTitle: "Tom \"&\" Co"' <<<"$(panel_config_render admin hash)" || fail_ "the panel's title: the household's name, a YAML string: $(panel_config_render admin hash | grep pageTitle)"; pass

# ---- found live: the accent restarts authentik (its email templates); the next change hit it starting ----
# the portal's kit waits for it ready itself (services/authentik/kit.sh), whoever calls it
authentik_url() { echo http://ak; }
http_ready() { echo "READY $2" >> "$T/order"; return "${READY_RC:-0}"; }
scurl() { echo "CURL $*" >> "$T/order"; return 1; }
: > "$T/order"; rc=0; READY_RC=1 authentik_brand_apply > /dev/null 2>&1 || rc=$?
[[ "$(cat "$T/order")" == "READY http://ak/-/health/ready/" && $rc == 0 ]] || fail_ "the portal never ready: its kit sends nothing (its wait says why, a wire step's helper returns 0): rc=$rc $(cat "$T/order")"; pass
unset -f scurl

# ---- every app that shows the kit is reached: <svc>_brand_apply, found by its name ----
eval "$(sed -n '/^brand_apply_apps() {/,/^}/p' lib/brand.sh | sed '1s/^brand_apply_apps/real_brand_apply_apps/')"   # the real one: stubbed above
svc_enabled_managed() { printf '%s\n' apprise authentik jellyfin seerr sonarr; }
c_state() { [[ "$1" == c-jellyfin ]] && echo exited || echo running; }; svc_cname() { echo "c-$1"; }
# the stubs by eval: defined here as functions, shellcheck 0.9 (CI's) would take the calls above for calls before a definition
eval 'authentik_brand_apply() { echo authentik >> "$T/order"; }; jellyfin_brand_apply() { echo jellyfin >> "$T/order"; }
      seerr_brand_apply() { echo seerr >> "$T/order"; }; apprise_brand_apply() { echo apprise >> "$T/order"; }'
: > "$T/order"; out=$(real_brand_apply_apps 2>&1)
[[ "$(paste -sd' ' "$T/order")" == "authentik seerr" ]] || fail_ "each running app with a kit hook, the hub aside (its colours: brand_apply_messages): $(paste -sd' ' "$T/order")"; pass
grep -F "jellyfin is not running" <<<"$out" >/dev/null || fail_ "an app with a kit that is stopped says when it takes it: $out"; pass

echo "OK brand: $checks checks"
