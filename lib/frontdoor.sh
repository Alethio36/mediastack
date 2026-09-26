#!/usr/bin/env bash
# lib/frontdoor.sh — the OliveTin web front door: constants, entity/status
# generation, the forced-command wrapper + config emitters, and the CLI-only
# frontdoor-install. Sourced by the entrypoint; relies on lib/common.sh
# primitives and the entrypoint's service/render helpers at call time.
# The wrapper heredoc lives here so the CI front-door audit covers it.

# =============================================================== frontdoor --
# OliveTin web front door: a browser panel of buttons/dropdowns over this
# script's SAFE verbs. Zero new capability — every button is one narrow SSH
# call that lands, on the host, as `sudo mediastack.sh <verb> <arg>` through a
# forced-command wrapper that whitelists verbs and rejects shell metacharacters.
# The container is unprivileged (no docker.sock, non-root, all host-provided
# files read-only). Path to root is guarded twice (forced-command key + narrow
# sudoers) and the mediastack.sh injection-safety the CI audit enforces.
#
# frontdoor-install is CLI-ONLY and never exposed through the panel — it writes
# host users, sudoers, keys and a password. It is idempotent: safe to re-run.
FRONTDOOR_USER=olivetin
FRONTDOOR_WRAPPER=/usr/local/bin/olivetin-frontdoor
FRONTDOOR_SUDOERS=/etc/sudoers.d/mediastack-frontdoor

frontdoor_teardown() { footprint_remove panel; }   # everything frontdoor-install placed (lib/footprint.sh: fp_panel)

# frontdoor_status_json: JSONL for the panel's live up/down tiles — one
# {name,state,health,glyph} record per enabled service. The glyph is computed
# HERE because the panel container has no docker access; the host owns it.
# ✅ = running (healthy or no healthcheck), ⚠️ = running but unhealthy/starting,
# ❌ = not running.
frontdoor_status_json() {
    render; c_inspect_all
    local s cn st h glyph cls
    for s in $(svc_enabled_managed); do
        cn=$(svc_cname "$s"); st=$(c_state "$cn"); h=$(c_health "$cn")
        case "$st" in
            running) case "$h" in healthy|-) glyph="✅"; cls="ms-up" ;; *) glyph="⚠️"; cls="ms-warn" ;; esac ;;
            *)       glyph="❌"; cls="ms-down" ;;
        esac
        jq -nc --arg name "$s" --arg state "$st" --arg health "$h" --arg glyph "$glyph" --arg cls "$cls" \
            '{name:$name,state:$state,health:$health,glyph:$glyph,cls:$cls}'
    done
}

# frontdoor-refresh: (re)write the entity lists that back the panel dropdowns
# and the live status tiles. Runs on the HOST via the mediastack-frontdoor-
# refresh timer, once at install, and on demand from the panel's Refresh button,
# so the panel container needs no docker access and no dependency on OliveTin's
# in-container scheduler. It is front-door-exposed (0-arg, whitelisted): all it
# does is regenerate these entity files.
cmd_frontdoor_refresh() {
    load_env
    local ent; ent="$(env_get CONFIG_ROOT)/olivetin/entities"
    sudo test -d "$ent" || { info "front door not installed — nothing to refresh"; return 0; }
    # enable dropdown offers what you CAN enable (currently disabled), and so on.
    cmd_list disabled  --json | sudo tee "$ent/enable.json"  >/dev/null
    cmd_list enabled   --json | sudo tee "$ent/disable.json" >/dev/null
    cmd_list vpntoggle --json | sudo tee "$ent/vpn.json"     >/dev/null
    cmd_list wire      --json | sudo tee "$ent/wire.json"    >/dev/null
    cmd_list pinned    --json | sudo tee "$ent/pinned.json"  >/dev/null
    frontdoor_status_json     | sudo tee "$ent/status.json"  >/dev/null
    sudo chown "$FRONTDOOR_USER:$FRONTDOOR_USER" \
        "$ent"/enable.json "$ent"/disable.json "$ent"/vpn.json "$ent"/wire.json "$ent"/pinned.json "$ent"/status.json
    sudo chmod 644 \
        "$ent"/enable.json "$ent"/disable.json "$ent"/vpn.json "$ent"/wire.json "$ent"/pinned.json "$ent"/status.json
    ok "refreshed OliveTin entity lists + status tiles"
}

# --- front-door static payloads (kept in this file so the CI audit covers the
#     wrapper; emitted verbatim, byte-for-byte identical to the former inline
#     heredocs). See cmd_frontdoor_install for how they are assembled. ---
_fd_wrapper_src() {
    cat <<'FRONTDOOR_WRAPPER'
#!/usr/bin/env bash
# olivetin-frontdoor — SSH forced-command wrapper (the path-to-root chokepoint).
# authorized_keys pins this as the ONLY command the olivetin key may run; the
# client's request arrives in $SSH_ORIGINAL_COMMAND. We whitelist the charset,
# whitelist the verb, bound the arg count, then hand argv (never a shell string)
# to mediastack.sh via a narrow sudo entry. No arbitrary evaluation, no
# interpolating shell: injection has nowhere to land.
set -euo pipefail
MEDIASTACK="__MEDIASTACK__"
cmd=${SSH_ORIGINAL_COMMAND:-}
[[ -n "$cmd" ]] || { echo "frontdoor: no command supplied" >&2; exit 2; }
[[ "$cmd" =~ ^[a-z0-9]([a-z0-9' '-]*[a-z0-9])?$ ]] \
    || { echo "frontdoor: rejected — illegal characters" >&2; exit 3; }
read -r -a argv <<<"$cmd"
verb=${argv[0]}; args=("${argv[@]:1}")
# the verbs and the argument limit are generated from the panel's PANEL table
# (lib/frontdoor.sh) at frontdoor-install — exactly what a button runs
case "$verb" in
    __VERBS__) ;;
    *) echo "frontdoor: verb '$verb' not permitted" >&2; exit 4 ;;
esac
(( ${#args[@]} <= __MAXARGS__ )) || { echo "frontdoor: too many arguments" >&2; exit 5; }
exec sudo -n "$MEDIASTACK" "$verb" "${args[@]}"
FRONTDOOR_WRAPPER
}

_fd_wrapper_render() { # _fd_wrapper_render MEDIASTACK-PATH -> the wrapper, whitelist from PANEL
    local verbs; verbs=$(_fd_panel_verbs | paste -sd'|')
    [[ "$verbs" =~ ^[a-z0-9|-]+$ ]] || die "frontdoor: PANEL yields an unsafe verb list '$verbs'"
    _fd_wrapper_src | sed -e "s#__MEDIASTACK__#$1#" -e "s#__VERBS__#$verbs#" -e "s#__MAXARGS__#$(_fd_panel_maxargs)#"
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

# ---- the panel: ONE table, everything else generated from it ----
# One line per button: group~title~icon~timeout~command~confirm~flags
#   command   the mediastack.sh argv the button runs. Arguments come ONLY from
#             placeholders — there is no free-text input type at all:
#               {NAME:entity=ENTITY:Title}   dropdown fed by a host-refreshed list
#               {NAME:choices=a,b:Title}     fixed choices
#   confirm   Label|help — the checkbox label (keep it short: the dialog's label
#             column is as wide as its longest label) and the line of help
#             shown beside it; empty = no confirmation step
#   flags     single = one run at a time (maxConcurrent: 1)
# The wrapper's verb whitelist and argument limit are DERIVED from the command
# column at frontdoor-install (_fd_wrapper_render), so a verb is reachable
# through the panel's key exactly when a button here runs it. Adding a line
# here is the security decision: review it as one (docs/frontdoor-safety.md).
PANEL=(
    "Diagnostics~Doctor~🩺~300~doctor~~"
    "Diagnostics~Status~📊~120~status~~"
    "Diagnostics~VPN leak test~🛡️~120~leak-test~~"
    "Diagnostics~View logs~📜~60~logs {svc:entity=svc_logs:Service} --no-follow~~"
    "Services~Enable service~▶️~180~enable {svc:entity=svc_enable:Service to enable}~Confirm~"
    "Services~Disable service~⏹️~180~disable {svc:entity=svc_disable:Service to disable}~Confirm~"
    "Services~Toggle VPN~🔒~300~vpn-apply {svc:entity=svc_vpn:Service} {state:choices=on,off:VPN}~Confirm|Restarts the VPN and every service behind it — about 1 minute; downloads resume.~"
    "Services~Wire service~🔗~180~wire {svc:entity=svc_wire:Service to wire}~Confirm~"
    "Maintenance~Update stack~⬆️~300~update~Confirm|Takes a restore point, then pulls and applies new images for every service.~single"
    "Maintenance~Backup now~💾~300~backup~Confirm|Stops the stack briefly and writes a new restore point.~single"
    "Maintenance~Verify backup~🔍~120~backup verify~~"
    "Maintenance~Rollback service~⏮️~300~rollback {svc:entity=svc_rollback:Service to roll back}~Confirm|Restores its config and image from the newest restore point, then pins it.~"
    "Maintenance~Unpin service~📌~180~unpin {svc:entity=svc_unpin:Service to unpin}~Confirm|Releases the pin: the next update includes it again.~"
    "Maintenance~Apply / reconcile~🔁~300~up~Confirm|Applies pending changes; services whose settings changed restart.~single"
    "Maintenance~Fix perms~🔧~120~fix-perms {svc:entity=svc_fixperms:Service}~Confirm~"
    "Maintenance~Refresh panel~♻️~60~frontdoor-refresh~~"
)
declare -A PANEL_GROUP_NOTE=(
    [Diagnostics]="diagnostics (read-only)"
    [Services]="services (pick one from the dropdown; confirm to run)"
    [Maintenance]="maintenance"
)
FD_SSH='ssh -i /config/ssh/id_ed25519 -o UserKnownHostsFile=/config/ssh/known_hosts -o StrictHostKeyChecking=yes -o BatchMode=yes olivetin@host.docker.internal'
FD_PLACEHOLDER='\{([a-z]+):(entity|choices)=([^:}]+):([^}]*)\}'

_fd_panel_argv() { # _fd_panel_argv COMMAND -> the argv with placeholders as {{ NAME }}
    local cmd="$1" out=""
    while [[ "$cmd" =~ $FD_PLACEHOLDER ]]; do
        out+="${cmd%%"${BASH_REMATCH[0]}"*}{{ ${BASH_REMATCH[1]} }}"
        cmd=${cmd#*"${BASH_REMATCH[0]}"}
    done
    echo "$out$cmd"
}
_fd_panel_verbs() { # the verbs the panel runs, one per line, sorted
    local row cmd
    for row in "${PANEL[@]}"; do
        IFS='~' read -r _ _ _ _ cmd _ _ <<<"$row"
        echo "${cmd%% *}"
    done | sort -u
}
_fd_panel_maxargs() { # the most arguments any button passes
    local row cmd argv max=0 n; local -a words
    for row in "${PANEL[@]}"; do
        IFS='~' read -r _ _ _ _ cmd _ _ <<<"$row"
        # a placeholder is ONE argument: collapse "{{ svc }}" to "svc" to count
        argv=$(_fd_panel_argv "$cmd"); argv=${argv//\{\{ /}; argv=${argv// \}\}/}
        read -r -a words <<<"$argv"
        n=$(( ${#words[@]} - 1 )); (( n > max )) && max=$n
    done
    echo "$max"
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

_fd_theme_css() {
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

cmd_frontdoor_install() {
    load_env
    need_cmd argon2; need_cmd openssl; need_cmd ssh-keygen
    local script="$SCRIPT_DIR/mediastack.sh"
    # mediastack.sh sources lib/*.sh, and sudo runs the lot as root — so every lib
    # is part of the same root-executed surface and must be non-writable too.
    local sudo_targets=("$script" "$SCRIPT_DIR"/lib/*.sh) t
    local otdir keydir ent
    otdir="$(env_get CONFIG_ROOT)/olivetin"; keydir="$otdir/ssh"; ent="$otdir/entities"

    hr "OliveTin front door — install"

    # 1. Unprivileged, no-login host user. --system + nologin: it can never open
    #    an interactive session; its ONLY reachable path is the forced-command
    #    key below. Distinct from the repo owner so mode-755 on the script is a
    #    real barrier (verified in step 3).
    if id -u "$FRONTDOOR_USER" >/dev/null 2>&1; then
        ok "host user '$FRONTDOOR_USER' already present"
    else
        sudo useradd --system --create-home --shell /bin/sh "$FRONTDOOR_USER"
        ok "created host user '$FRONTDOOR_USER' (system, /bin/sh)"
    fi
    local ot_uid ot_gid ot_home
    sudo usermod -s /bin/sh "$FRONTDOOR_USER"   # sshd execs the forced command via this shell
    ot_uid=$(id -u "$FRONTDOOR_USER"); ot_gid=$(id -g "$FRONTDOOR_USER")
    ot_home=$(getent passwd "$FRONTDOOR_USER" | cut -d: -f6)
    [[ -n "$ot_home" ]] || die "could not resolve $FRONTDOOR_USER home directory"
    # The container runs as this same numeric uid/gid so it can read its key and
    # write its own entity cache, without any file being world-readable.
    env_set OLIVETIN_UID "$ot_uid"; env_set OLIVETIN_GID "$ot_gid"

    # 2. Harden the sudo target: owner keeps write (upgrade git-pulls as the repo
    #    owner), group/other read-only. With a distinct olivetin user this makes
    #    the script unwritable by the front door — asserted next.
    sudo chmod 755 "$script"
    sudo chmod 644 "$SCRIPT_DIR"/lib/*.sh          # sourced as root; must not be writable

    # 3. THE load-bearing check: prove olivetin cannot rewrite what it can run as
    #    root. If it can, the whole model is void — fail loud, change nothing.
    for t in "${sudo_targets[@]}"; do
        if sudo -u "$FRONTDOOR_USER" /usr/bin/test -w "$t"; then
            die "SECURITY: '$FRONTDOOR_USER' can WRITE $t — a compromise would run as root.
  Fix perms/ownership so $FRONTDOOR_USER cannot write it (it must share no write-group with the owner)."
        fi
    done
    ok "verified: '$FRONTDOOR_USER' cannot write the sudo target ($script) or its libraries"

    # 4. Narrow sudoers: olivetin may sudo ONLY this script (no password). The
    #    wrapper (step 5) is what bounds WHICH verbs; sudoers bounds WHICH binary.
    #    Validated with visudo -c before install so a typo can't wedge sudo.
    local stmp; stmp=$(mktemp)
    printf '# Managed by mediastack.sh frontdoor-install. Do not edit.\n%s ALL=(root) NOPASSWD: %s\n' \
        "$FRONTDOOR_USER" "$script" > "$stmp"
    sudo visudo -cf "$stmp" >/dev/null || { rm -f "$stmp"; die "sudoers validation failed — not installed."; }
    sudo install -m 0440 -o root -g root "$stmp" "$FRONTDOOR_SUDOERS"; rm -f "$stmp"
    ok "sudoers installed: $FRONTDOOR_USER may sudo only $script"

    # 5. Dedicated key + forced-command wrapper + pinned authorized_keys.
    sudo mkdir -p "$keydir"
    if sudo test -f "$keydir/id_ed25519"; then
        ok "ssh keypair already present"
    else
        sudo ssh-keygen -t ed25519 -N '' -C 'olivetin-frontdoor' -f "$keydir/id_ed25519" >/dev/null
        ok "generated ed25519 keypair"
    fi
    # Install the wrapper (embedded below as a literal heredoc — kept in this
    # file so the CI front-door audit covers it too), pinned to this script.
    local wtmp; wtmp=$(mktemp)
    _fd_wrapper_render "$script" > "$wtmp"
    sudo install -m 0755 -o root -g root "$wtmp" "$FRONTDOOR_WRAPPER"; rm -f "$wtmp"
    ok "forced-command wrapper installed at $FRONTDOOR_WRAPPER"

    local akdir="$ot_home/.ssh" pub
    pub=$(sudo cat "$keydir/id_ed25519.pub")
    sudo mkdir -p "$akdir"
    printf 'command="%s",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding %s\n' \
        "$FRONTDOOR_WRAPPER" "$pub" | sudo tee "$akdir/authorized_keys" >/dev/null
    sudo chown -R "$FRONTDOOR_USER:$FRONTDOOR_USER" "$akdir"
    sudo chmod 700 "$akdir"; sudo chmod 600 "$akdir/authorized_keys"
    ok "authorized_keys pinned (forced command, no pty, no forwarding)"

    # 6. known_hosts for the container->host hop. The host key is IP-independent,
    #    so scan it via loopback and label it for the name the container uses
    #    (host.docker.internal). StrictHostKeyChecking stays ON in the panel.
    local hostpub=/etc/ssh/ssh_host_ed25519_key.pub
    sudo test -f "$hostpub" || die "host ed25519 key $hostpub not found — is openssh-server installed?"
    # authoritative source; ssh-keyscan can capture the banner line instead of the key
    sudo awk '{print "host.docker.internal", $1, $2}' "$hostpub" | sudo tee "$keydir/known_hosts" >/dev/null
    ok "pinned host key for host.docker.internal (from $hostpub)"

    # 7. Panel admin password. Reuse the existing hash on re-runs (so config-only
    #    updates don't force a re-auth); prompt only on first install or when
    #    --set-password is given. The hash is offline (OliveTin's own hasher needs
    #    a running instance); the password is read on the terminal and piped on
    #    stdin — never in argv or the process list.
    local hash="" setpw=0 a
    for a in "$@"; do [[ "$a" == --set-password ]] && setpw=1; done
    if (( ! setpw )) && sudo test -f "$otdir/config.yaml"; then
        hash=$(sudo sed -n "s/^ *password: '\(.*\)'\$/\1/p" "$otdir/config.yaml" | head -1)
    fi
    if [[ -n "$hash" ]]; then
        ok "reusing existing admin password (change it with: frontdoor-install --set-password)"
    else
        [[ -t 0 ]] || die "run frontdoor-install interactively to set the panel password."
        hr "OliveTin admin password"
        local pw pw2
        read -rs -p "Set OliveTin admin password: " pw; echo
        read -rs -p "Confirm password: "            pw2; echo
        [[ -n "$pw" ]] || die "empty password."
        [[ "$pw" == "$pw2" ]] || die "passwords did not match."
        hash=$(printf '%s' "$pw" | argon2 "$(openssl rand -base64 16)" -id -t 4 -m 16 -p 6 -l 32 -e)
        unset pw pw2
        [[ "$hash" == '$argon2id$'* ]] || die "argon2 did not produce an argon2id hash — aborting."
        ok "password hashed (argon2id)"
    fi

    # 8. Write the OliveTin config. Static parts via literal heredocs; the hash is
    #    concatenated between them so its $-laden text is never shell-expanded.
    sudo mkdir -p "$otdir" "$ent"
    local ctmp; ctmp=$(mktemp)
    { _fd_otcfg_head; printf "      password: '%s'\n" "$hash"; _fd_otcfg_tail; } > "$ctmp"
    sudo install -m 0640 -o "$FRONTDOOR_USER" -g "$FRONTDOOR_USER" "$ctmp" "$otdir/config.yaml"; rm -f "$ctmp"
    ok "wrote $otdir/config.yaml"

    # Theme: pack the per-service status rows into a coloured, wrapping grid.
    # :has() scopes the flex override to the dashboard that has status tiles, so
    # other views (Diagnostics/Entities/Logs) are untouched. Class names come
    # from the status fieldset (ms-status) and the host-computed cls field.
    local themedir="$otdir/custom-webui/themes/mediastack"
    sudo mkdir -p "$themedir"
    local ttmp; ttmp=$(mktemp)
    _fd_theme_css > "$ttmp"
    sudo install -m 0644 -o "$FRONTDOOR_USER" -g "$FRONTDOOR_USER" "$ttmp" "$themedir/theme.css"; rm -f "$ttmp"
    ok "wrote $themedir/theme.css"

    # Minimal passwd so the container ssh client can resolve its own uid
    # (it runs as OLIVETIN_UID:GID, which is absent from the image passwd).
    printf 'root:x:0:0:root:/root:/bin/sh\n%s:x:%s:%s:olivetin:/config:/bin/sh\n' \
        "$FRONTDOOR_USER" "$ot_uid" "$ot_gid" | sudo tee "$otdir/passwd" >/dev/null
    sudo chmod 644 "$otdir/passwd"
    ok "wrote $otdir/passwd (uid $ot_uid resolvable in-container)"

    # 9. Ownership: the container runs as OLIVETIN_UID and owns its whole config
    #    tree, so OliveTin can persist sessions and themes under /config. The
    #    private key stays 600; config.yaml/known_hosts are read-only mounts.
    sudo chown -R "$FRONTDOOR_USER:$FRONTDOOR_USER" "$otdir"
    sudo chmod 755 "$otdir" "$ent"; sudo chmod 700 "$keydir"
    sudo chmod 600 "$keydir/id_ed25519"
    sudo chmod 644 "$keydir/id_ed25519.pub" "$keydir/known_hosts" "$otdir/passwd"
    sudo chmod 640 "$otdir/config.yaml"

    # 10. Enable the profile (container defined in compose.d/olivetin.yml).
    if svc_enabled olivetin; then
        ok "'olivetin' already in COMPOSE_PROFILES"
    else
        env_set COMPOSE_PROFILES "$(env_get COMPOSE_PROFILES | tr ',' '\n' | awk 'NF && !seen[$0]++; END{print "olivetin"}' | paste -sd, -)"
        ok "added 'olivetin' to COMPOSE_PROFILES"
    fi

    # Host-side entity-refresh timer: fills the dropdowns from the host, every
    # 5 min and on boot. No userless OliveTin action, no container write needed.
    sudo tee "$SYSTEMD_DIR/mediastack-frontdoor-refresh.service" >/dev/null <<EOF
[Unit]
Description=Mediastack OliveTin entity-list refresh
After=docker.service
[Service]
Type=oneshot
WorkingDirectory=$SCRIPT_DIR
ExecStart=$SCRIPT_DIR/mediastack.sh frontdoor-refresh
EOF
    sudo tee "$SYSTEMD_DIR/mediastack-frontdoor-refresh.timer" >/dev/null <<EOF
[Unit]
Description=Refresh OliveTin entity lists
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true
[Install]
WantedBy=timers.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now mediastack-frontdoor-refresh.timer >/dev/null 2>&1 || true
    ok "entity-refresh timer installed (every 5 min)"
    cmd_frontdoor_refresh   # populate now so dropdowns render on first start

    # 11. Re-verify both narrowings before declaring success.
    for t in "${sudo_targets[@]}"; do
        sudo -u "$FRONTDOOR_USER" /usr/bin/test -w "$t" \
            && die "post-check FAILED: $FRONTDOOR_USER can write $t."
    done
    sudo visudo -cf "$FRONTDOOR_SUDOERS" >/dev/null \
        || die "post-check FAILED: installed sudoers is invalid."
    grep -q '^command=' "$akdir/authorized_keys" 2>/dev/null \
        || sudo grep -q '^command=' "$akdir/authorized_keys" \
        || die "post-check FAILED: authorized_keys is not forced-command pinned."
    ok "both narrowings verified (forced-command key + narrow sudoers)"

    echo
    hr "Front door ready"
    # the panel is served only through Traefik (no host port): no domain, no URL
    local url; url=$(svc_url olivetin)
    [[ "$url" == https://* ]] || url="none yet — the panel is served through Traefik: ./mediastack.sh traefik-setup"
    cat <<EOT
Bring it up:   ./mediastack.sh up        (starts the 'olivetin' container)
Reach it:      $url  (LAN)
Log in as 'admin' (change the password: ./mediastack.sh frontdoor-install --set-password).

Host-side checks worth confirming once (needs the live box):
  * sshd accepts the olivetin key from containers (host-gateway reachable, sshd up)
  * dropdowns are filled now and every 5 min by mediastack-frontdoor-refresh.timer
EOT
}
