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
[[ "$(brand_icon_problem "$(png 256 200)")" == *"256x200 — the icon must be square"* ]] || fail_ "not square: said"; pass
[[ "$(brand_icon_problem "$(png 64 64)")" == *"128 to 1024 pixels"* ]] || fail_ "too small: said"; pass
[[ "$(brand_icon_problem "$(png 2048 2048)")" == *"128 to 1024 pixels"* ]] || fail_ "too large: said"; pass
[[ "$(brand_icon_problem "$(png 512 512 1100000)")" == *"the most is 1024 KiB"* ]] || fail_ "over 1 MiB: said"; pass
printf '\xff\xd8\xff\xe0 a jpeg' > "$T/j.jpg"
[[ "$(brand_icon_problem "$T/j.jpg")" == *"is not a PNG"* ]] || fail_ "a JPEG: not a PNG, said"; pass
[[ "$(brand_icon_problem "$T/none.png")" == *"not a readable file"* ]] || fail_ "missing: said"; pass
[[ "$(brand_icon)" == "$SCRIPT_DIR/$BRAND_ICON_SHIPPED" ]] || fail_ "no icon of yours: the shipped one"; pass

hub_enabled() { return 1; }
brand_icon_set "$(png 300 300)" > "$T/out"
cmp -s "$T/p300x300.png" "$BRAND_DIR/icon.png" && [[ "$(brand_icon)" == "$BRAND_DIR/icon.png" && "$(stat -c %a "$BRAND_DIR/icon.png")" == 644 ]] \
    || fail_ "brand icon FILE: copied into custom/branding/ and used"; pass
grep -q "the kit reaches it at its next start" "$T/out" || fail_ "the hub off: nothing applied, and said when: $(cat "$T/out")"; pass
( brand_icon_set "$(png 300 200)" ) >/dev/null 2>"$T/err" && fail_ "an unusable icon: refused"
cmp -s "$T/p300x300.png" "$BRAND_DIR/icon.png" || fail_ "an unusable icon refused: yours stays as it was"; pass
brand_icon_set default >/dev/null
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

echo "OK brand: $checks checks"
