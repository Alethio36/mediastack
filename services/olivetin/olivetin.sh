#!/usr/bin/env bash
# services/olivetin/olivetin.sh — the web panel's provider: how OliveTin shows
# the panel. lib/frontdoor.sh holds the security boundary, whatever app shows
# it (the PANEL table, the forced-command wrapper, sudoers, the pinned key and
# host key, install and teardown) and calls only this interface:
#
#   panel_config_render HASH        OliveTin's config.yaml: the PANEL table as
#                                   its actions, run over FD_SSH; HASH is the
#                                   admin password's argon2id hash
#   panel_theme_render              its theme (custom-webui/themes/mediastack)
#   panel_passwd_render UID GID     the container's minimal passwd
#   panel_signin_check              wire authentik's word on whether the installed
#                                   config signs in through the portal yet
#
# A second panel app defines the same names. Sourced by the entrypoint (under
# the front-door audit, like every services/*/*.sh); relies on lib/frontdoor.sh
# (PANEL, PANEL_GROUP_NOTE, _fd_panel_argv, FRONTDOOR_USER) at call time.

# how OliveTin reaches the host: one narrow ssh call per button, landing on the
# forced-command wrapper (lib/frontdoor.sh)
FD_SSH='ssh -i /config/ssh/id_ed25519 -o UserKnownHostsFile=/config/ssh/known_hosts -o StrictHostKeyChecking=yes -o BatchMode=yes olivetin@host.docker.internal'

panel_config_render() { # panel_config_render HASH -> config.yaml; the hash is concatenated, never shell-expanded
    _fd_otcfg_head; printf "      password: '%s'\n" "$1"; _fd_otcfg_tail; panel_jwt_render
}

panel_jwt_render() { # while the portal runs: sign in with the token the gate passes on
    signin_is authentik || return 0
    cat <<EOF

# Signed in through the portal: the gate passes a token authentik signed —
# verified against the gate's published keys, and accepted only with the
# gate's audience (not Kavita's or Audiobookshelf's, which share the key).
# Its groups decide (admins: the list above). The local admin above stays:
# without the portal it is the only way in. Takes effect at OliveTin's start.
authJwtHeader: X-authentik-jwt
authJwtCertsUrl: http://$(svc_addr authentik)/application/o/mediastack-admin-tools/jwks/
authJwtAud: mediastack-gate
authJwtClaimUsername: preferred_username
authJwtClaimUserGroup: groups
# OliveTin joins the groups claim into one line and splits it again to match:
# split on spaces, a group named "Jellyfin admins" would count as admins.
# The unit separator never appears in a group's name.
authHttpHeaderUserGroupSep: "\u001f"
EOF
}

panel_signin_check() { # the installed config signs in through the portal, or says how to make it
    svc_enabled olivetin || return 0
    local cfg; cfg="$(env_get CONFIG_ROOT)/olivetin/config.yaml"
    sudo test -f "$cfg" || return 0   # the panel is not installed
    if sudo grep -q '^authJwtHeader: X-authentik-jwt$' "$cfg"; then ok "authentik: the panel signs in through the portal"
    else warn "authentik: the panel still asks for its own login after the portal — to sign in through it: ./mediastack.sh frontdoor-install"; fi
}

_fd_otcfg_head() {
    cat <<'OTCFG_HEAD'
# Managed by mediastack.sh frontdoor-install. Regenerate via frontdoor-install.
logLevel: "INFO"
pageTitle: "Mediastack"
# custom-webui/themes/mediastack/theme.css (written by frontdoor-install) styles
# the status tiles into a coloured grid.
themeName: "mediastack"
# hide the small on-start indicator badges on each button, for a cleaner grid
showNavigateOnStartIcons: false

# Everyone must log in; the panel can change the stack, so no guest access.
authRequireGuestsToLogin: true
accessControlLists:
  - name: admins
    matchUsergroups: [admins]
    permissions:
      view: true
      exec: true
      logs: true
    addToEveryAction: true

authLocalUsers:
  enabled: true
  users:
    - username: admin
      usergroup: admins
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
