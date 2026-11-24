#!/usr/bin/env bash
# services/seerr/kit.sh — the household's kit (lib/brand.sh) on Seerr: its
# title is the household's name (PORTAL_TITLE) — the browser tab, its sign-in
# page, the name an installed phone app shows. Seerr takes no logo (checked in
# its source). Set while it is Seerr's own ("Seerr") or the one mediastack set
# last; a title written in its settings stays. Sourced by the entrypoint.

SEERR_KIT_DEFAULT_TITLE=Seerr

seerr_brand_apply() { # Seerr's title: the household's name
    local key cur want out
    key=$(env_get SEERR_API_KEY)
    [[ -n "$key" ]] || { info "seerr: no API key stored yet — it takes the household's name at its next wire"; return 0; }
    out=$(curl -fsS -m 20 -H "X-Api-Key: $key" "$(seerr_url)/api/v1/settings/main" 2>&1) || { wfail "seerr: its main settings are unreadable — its title not checked: $(oneline "$out")"; return 0; }
    cur=$(jq -r '.applicationTitle // ""' <<<"$out"); want=$(env_get PORTAL_TITLE)
    case "$(brand_decide "$cur" "$want" "$SEERR_KIT_DEFAULT_TITLE" "$(state_get seerr-kit-title)")" in
        same)  return 0 ;;
        yours) ok "seerr: its title '$cur' was written in its settings — yours, untouched"; return 0 ;;
    esac
    w_would "seerr: its title — the household's name, $want" || return 0
    out=$(curl -fsS -m 20 -X POST -H "X-Api-Key: $key" -H 'Content-Type: application/json' \
          -d "$(jq -cn --arg t "$want" '{applicationTitle:$t}')" "$(seerr_url)/api/v1/settings/main" 2>&1) \
        || { wfail "seerr refused its title: $(oneline "$out")"; return 0; }
    state_set seerr-kit-title "$want"; ok "seerr: its title is $want"
}
