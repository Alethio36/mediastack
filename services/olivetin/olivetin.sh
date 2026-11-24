#!/usr/bin/env bash
# services/olivetin/olivetin.sh — the web panel's provider: how OliveTin shows
# the panel. lib/frontdoor.sh holds the security boundary, whatever app shows
# it (the PANEL table, the forced-command wrapper, sudoers, the pinned key and
# host key, install and teardown) and calls only this interface:
#
#   panel_config_render USER HASH   OliveTin's config.yaml: the PANEL table as
#                                   its actions, run over FD_SSH; USER and HASH
#                                   are its admin's name and argon2id hash
#   panel_hash PASS [OLD-HASH]      that hash (OLD-HASH itself while it is PASS's)
#   panel_theme_render              its theme (custom-webui/themes/mediastack)
#   panel_passwd_render UID GID     the container's minimal passwd
#   panel_portal_render             its sign-in through the portal (only while it runs)
#   panel_signin_check              wire authentik's word on whether the installed
#                                   config signs in through the portal yet
#
# A second panel app defines the same names. Its admin is one of the stack's
# own logins (olivetin_logins; set-credentials panel). Sourced by the
# entrypoint (under the front-door audit, like every services/*/*.sh); relies
# on lib/frontdoor.sh (PANEL, PANEL_GROUP_NOTE, _fd_panel_argv, FRONTDOOR_USER,
# fd_config_write, fd_panel_restart) at call time.

olivetin_logins() { printf "the web panel's admin\tPANEL_ADMIN_USER\tPANEL_ADMIN_PASSWORD\treserve\n"; }   # lib/logins.sh — with the portal, admins sign in through it and this is the fallback

# how OliveTin reaches the host: one narrow ssh call per button, landing on the
# forced-command wrapper (lib/frontdoor.sh)
FD_SSH='ssh -i /config/ssh/id_ed25519 -o UserKnownHostsFile=/config/ssh/known_hosts -o StrictHostKeyChecking=yes -o BatchMode=yes olivetin@host.docker.internal'

panel_config_render() { # panel_config_render USER HASH -> config.yaml; both concatenated, never shell-expanded
    # single-quoted YAML: a login's name is letters, digits and . _ - (lib/logins.sh), a hash has no quote
    # the panel's users and the portal's admin group share one name: the
    # portal sends a person's groups, and the list below lets that one in
    local head t
    head=$(_fd_otcfg_head | sed "s/@ADMIN_GROUP@/$PORTAL_ADMIN/g")
    t=$(env_get PORTAL_TITLE); t=${t//\\/\\\\}; t=${t//\"/\\\"}   # the household's name, a double-quoted YAML string
    printf '%s\n' "${head//@PAGE_TITLE@/"$t"}"
    printf "    - username: '%s'\n      usergroup: %s\n      password: '%s'\n" "$1" "$PORTAL_ADMIN" "$2"
    _fd_otcfg_tail; panel_portal_render
}

PANEL_ARGON2=(-id -t 4 -m 16 -p 6 -l 32)   # the admin hash's argon2id cost (64 MiB, 4 passes)
panel_hash() { # panel_hash PASS [OLD-HASH] -> argon2id: OLD-HASH when it is PASS's (the config unchanged, no restart), else a new salt's
    local h salt
    # the encoded hash keeps its salt (unpadded base64): recomputed with it, PASS gives OLD-HASH back only when it is PASS's
    if [[ "${2:-}" =~ ^\$argon2id\$v=19\$[^$]+\$([A-Za-z0-9+/]+)\$[A-Za-z0-9+/]+$ ]]; then
        salt=${BASH_REMATCH[1]}
        while (( ${#salt} % 4 )); do salt+="="; done
        if salt=$(base64 -d <<<"$salt" 2>/dev/null) && [[ -n "$salt" ]] \
            && h=$(printf '%s' "$1" | argon2 "$salt" "${PANEL_ARGON2[@]}" -e) && [[ "$h" == "$2" ]]; then
            echo "$2"; return 0
        fi
    fi
    # the password on stdin, never in argv
    h=$(printf '%s' "$1" | argon2 "$(openssl rand -hex 16)" "${PANEL_ARGON2[@]}" -e) || return 1
    [[ "$h" == '$argon2id$'* ]] || return 1
    echo "$h"
}

panel_installed_login() { # -> "USER<TAB>HASH" of the installed config's admin ("" when not installed)
    local cfg; cfg="$(env_get CONFIG_ROOT)/olivetin/config.yaml"
    sudo test -f "$cfg" || return 0
    sudo awk -F"'" '/^    - username: /{u=$2} /^      password: /{print u "\t" $2; exit}' "$cfg"
}

sc_rotate_panel() { # PASS — set-credentials panel: .env, then the installed config (its hash), then the panel restarted to read it
    local pass="$1" hash
    svc_enabled olivetin || { info "the web panel is not enabled — skipped"; return 0; }
    frontdoor_installed || { wfail "the web panel is enabled but not installed — nothing changed: ./mediastack.sh frontdoor-install"; return 0; }
    need_cmd argon2; need_cmd openssl
    hash=$(panel_hash "$pass") || { wfail "panel: argon2 made no argon2id hash — nothing changed"; return 0; }
    env_set PANEL_ADMIN_PASSWORD "$pass"
    fd_config_write "$hash"
    fd_panel_restart
    ok "the web panel's admin password changed (sign in as $(env_get PANEL_ADMIN_USER))"
}

olivetin_doctor() { # doctor: apps — the installed panel signs its admin in with the login in .env (credentials shows)
    local got user pass
    got=$(panel_installed_login)
    [[ -n "$got" ]] || return 0
    command -v argon2 >/dev/null && command -v openssl >/dev/null \
        || { d_fail "argon2 or openssl is missing on this host" "the web panel's admin cannot be checked or changed" "./mediastack.sh install"; return 0; }
    user=$(env_get PANEL_ADMIN_USER); pass=$(env_get PANEL_ADMIN_PASSWORD)
    if [[ -z "$user" || -z "$pass" ]]; then
        d_fail "the web panel's admin is not one of the stack's logins yet" "credentials cannot show it, set-credentials cannot change it" "./mediastack.sh frontdoor-install (records it as the others are)"
    elif [[ "$(cut -f1 <<<"$got")" != "$user" ]] || [[ "$(panel_hash "$pass" "$(cut -f2 <<<"$got")")" != "$(cut -f2 <<<"$got")" ]]; then
        d_fail "the web panel's admin is not the login in .env" "signing in with what credentials shows fails" "./mediastack.sh frontdoor-install (rewrites it from .env)"
    else
        ok "the web panel's admin is the login in .env ($user)"
    fi
}

panel_portal_render() { # while the portal runs: the gate's identity headers sign people in
    signin_is authentik || return 0
    cat <<'EOF'

# Signed in through the portal: on the panel's route the gate (Traefik asking
# authentik) replaces these headers on every request, and the panel's network
# (mediastack-panel) holds only the edge, so no other container can reach the
# panel to send them. authentik joins a person's groups with "|"; the
# portal's admin group (the list above) decides. The local admin above stays: without the portal it
# is the only way in. Takes effect at OliveTin's start.
authHttpHeaderUsername: X-authentik-username
authHttpHeaderUserGroup: X-authentik-groups
authHttpHeaderUserGroupSep: "|"
EOF
}

panel_config_follow() { # wire: the installed config is the one the stack writes today, for the login it holds — so who may use it follows the portal's groups
    svc_enabled olivetin || return 0
    local cfg got user hash ctmp
    cfg="$(env_get CONFIG_ROOT)/olivetin/config.yaml"
    sudo test -f "$cfg" || return 0   # the panel is not installed
    got=$(panel_installed_login)
    [[ -n "$got" ]] || { wfail "the panel's config holds no admin login — ./mediastack.sh frontdoor-install"; return 0; }
    user=${got%%$'\t'*}; hash=${got#*$'\t'}
    ctmp=$(mktemp); panel_config_render "$user" "$hash" > "$ctmp"
    if sudo cmp -s "$ctmp" "$cfg"; then rm -f "$ctmp"; return 0; fi
    rm -f "$ctmp"
    # after the groups' rename (Nov 2026) the installed list still named 'admins': every admin shut out
    w_would "the panel's config follows the stack's (who may use it: the portal's '$PORTAL_ADMIN' group) — one panel restart" || return 0
    fd_config_write "$hash" "$user"
    fd_panel_restart
    ok "the panel's config follows the stack's (its admin, $user, kept)"
}

panel_signin_check() { # the installed config signs in through the portal, or says how to make it
    svc_enabled olivetin || return 0
    local cfg; cfg="$(env_get CONFIG_ROOT)/olivetin/config.yaml"
    sudo test -f "$cfg" || return 0   # the panel is not installed
    if sudo grep -q '^authHttpHeaderUsername: X-authentik-username$' "$cfg"; then ok "authentik: the panel signs in through the portal"
    else warn "authentik: the panel still asks for its own login after the portal — to sign in through it: ./mediastack.sh frontdoor-install"; fi
}

_fd_otcfg_head() {
    cat <<'OTCFG_HEAD'
# Managed by mediastack.sh frontdoor-install. Regenerate via frontdoor-install.
logLevel: "INFO"
pageTitle: "@PAGE_TITLE@"
# custom-webui/themes/mediastack/theme.css (written by frontdoor-install) styles
# the status tiles into a coloured grid.
themeName: "mediastack"
# hide the small on-start indicator badges on each button, for a cleaner grid
showNavigateOnStartIcons: false

# Everyone must log in; the panel can change the stack, so no guest access.
authRequireGuestsToLogin: true
accessControlLists:
  - name: @ADMIN_GROUP@
    matchUsergroups: [@ADMIN_GROUP@]
    permissions:
      view: true
      exec: true
      logs: true
    addToEveryAction: true

authLocalUsers:
  enabled: true
  users:
OTCFG_HEAD
}

_fd_otcfg_tail() {
    cat <<'OTCFG_ENTITIES'

# Service lists backing the dropdowns; refreshed on the host by the timer
# (and by the panel's Refresh button).
entities:
  - name: svc_enable
    file: entities/enable.json
  - name: svc_disable
    file: entities/disable.json
  - name: svc_vpn
    file: entities/vpn.json
  - name: svc_wire
    file: entities/wire.json
  # logs / rollback / fix-perms all target an ENABLED service — the same set the
  # Disable dropdown offers — so they read disable.json rather than duplicate it.
  - name: svc_logs
    file: entities/disable.json
  - name: svc_rollback
    file: entities/disable.json
  - name: svc_fixperms
    file: entities/disable.json
  # unpin only makes sense for a currently-pinned service.
  - name: svc_unpin
    file: entities/pinned.json
  # live up/down tiles: one record per enabled service, glyph computed on the host.
  - name: status
    file: entities/status.json

# Actions MUST be defined here; the dashboard below only references them by
# title (OliveTin "pulls" them out of the default Actions view).
actions:
OTCFG_ENTITIES
    local row group title icon timeout cmd confirm flags lastgroup="" rest name kind src atitle c
    local -a order=()
    for row in "${PANEL[@]}"; do
        IFS='~' read -r group title icon timeout cmd confirm flags <<<"$row"
        if [[ "$group" != "$lastgroup" ]]; then
            [[ -z "$lastgroup" ]] || echo
            echo "  # -- ${PANEL_GROUP_NOTE[$group]} --"
            order+=("$group"); lastgroup=$group
        else
            echo
        fi
        printf '  - title: %s\n    icon: "%s"\n    timeout: %s\n' "$title" "$icon" "$timeout"
        [[ "$flags" == single ]] && echo "    maxConcurrent: 1"
        echo "    onclick: execution-dialog"
        echo "    shell: $FD_SSH $(_fd_panel_argv "$cmd")"
        [[ "$cmd" =~ $FD_PLACEHOLDER || -n "$confirm" ]] && echo "    arguments:"
        rest=$cmd
        while [[ "$rest" =~ $FD_PLACEHOLDER ]]; do
            name=${BASH_REMATCH[1]} kind=${BASH_REMATCH[2]} src=${BASH_REMATCH[3]} atitle=${BASH_REMATCH[4]}
            rest=${rest#*"${BASH_REMATCH[0]}"}
            echo "      - name: $name"
            [[ "$kind" == entity ]] && echo "        entity: $src"
            echo "        title: $atitle"
            echo "        choices:"
            if [[ "$kind" == entity ]]; then echo "          - value: '{{ $src.name }}'"
            else for c in ${src//,/ }; do echo "          - value: \"$c\""; done; fi
        done
        if [[ -n "$confirm" ]]; then
            printf '      - title: %s\n        type: confirmation\n' "${confirm%%|*}"
            # help text: a YAML double-quoted scalar, so ':' or '#' in it stay text
            [[ "$confirm" == *"|"* ]] && printf '        description: "%s"\n' "$(sed 's/[\\"]/\\&/g' <<<"${confirm#*|}")"
        fi
    done
    echo
    cat <<'OTCFG_DASHBOARD'
# Putting every action on a dashboard makes OliveTin hide the default "Actions"
# sidebar tab. The status fieldset iterates the `status` entity to render one
# live up/down tile per enabled service (host-refreshed).
dashboards:
  - title: Mediastack
    contents:
      - title: '{{ status.glyph }} {{ status.name }}'
        entity: status
        type: fieldset
        cssClass: ms-status
        contents:
          - type: display
            cssClass: '{{ status.cls }}'
            title: 'state: {{ status.state }} · health: {{ status.health }}'
OTCFG_DASHBOARD
    for group in "${order[@]}"; do
        printf '      - title: %s\n        type: fieldset\n        contents:\n' "$group"
        for row in "${PANEL[@]}"; do
            IFS='~' read -r c title _ <<<"$row"
            [[ "$c" == "$group" ]] && echo "          - title: $title"
        done
    done
}

panel_theme_render() { # the theme: per-service status rows as a coloured, wrapping grid
    cat <<'THEME_CSS'
/* Managed by mediastack.sh frontdoor-install. Regenerate via frontdoor-install. */

/* Action dialogs: the help line beside a confirmation checkbox. OliveTin's
   #666 is near-invisible on the dark theme. */
.argument-description {
  color: #b8b8b8;
  line-height: 1.4;
}

/* Only reflow the content area that holds status tiles (the Mediastack
   dashboard); leave every other view's section.transparent alone. */
main > section.transparent:has(fieldset.ms-status) {
  display: flex;
  flex-wrap: wrap;
  justify-content: center;
  align-items: flex-start;
  gap: 0.4rem;
}

/* a status tile = the dashboard-row that directly holds a status fieldset */
main > section.transparent:has(fieldset.ms-status) > .dashboard-row:has(> fieldset.ms-status) {
  width: 190px;
  margin: 0;
}
main > section.transparent:has(fieldset.ms-status) > .dashboard-row:has(> fieldset.ms-status) h2 {
  font-size: 1rem;
  text-align: center;
  margin: 0.2rem 0;
}

/* action rows (Diagnostics/Services/Maintenance) keep a full-width line */
main > section.transparent:has(fieldset.ms-status) > .dashboard-row:not(:has(> fieldset.ms-status)) {
  flex: 1 1 100%;
}

/* the tile's status box: fill the tile, small text, colour bar by state */
fieldset.ms-status {
  grid-template-columns: 1fr;
  padding: 0.3rem;
}
fieldset.ms-status .display {
  font-size: 0.8rem;
  padding: 0.4rem;
  border-left: 3px solid transparent;
}
.display.ms-up   { border-left-color: #3fb950; }
.display.ms-warn { border-left-color: #d29922; }
.display.ms-down { border-left-color: #f85149; }
THEME_CSS
}

panel_passwd_render() { # panel_passwd_render UID GID -> the container's minimal passwd (its uid resolvable)
    printf 'root:x:0:0:root:/root:/bin/sh\n%s:x:%s:%s:olivetin:/config:/bin/sh\n' "$FRONTDOOR_USER" "$1" "$2"
}
