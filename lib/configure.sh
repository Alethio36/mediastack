#!/usr/bin/env bash
# lib/configure.sh — the `configure` verb: runs the questionnaire
# (lib/questionnaire.sh) as its own process, then applies its answers —
# folders (made, moved as answered, their mounts recorded), users and
# folders for the services (provision), the timers, the host record, the
# web panel — and shows the summary. Sourced by the entrypoint; relies on
# lib/common.sh and the entrypoint's service helpers and provision() at call
# time.

_configure_selfheal() {
    # -- self-heal FIRST: adopt any *_UID / *_UPDATE vars new fragments
    # reference, so the render below never sees unset variables. Also run by
    # provision (up, enable): a service an `upgrade` added must get its own
    # UID before anything starts it, not only at the next `configure`.
    local ref base
    base=$(env_get UID_BASE)
    while read -r ref; do
        if ! grep -qE "^${ref}=" "$ENV_FILE"; then
            if [[ "$ref" == *_UID ]]; then
                local max
                max=$(grep -E '_UID=[0-9]+' "$ENV_FILE" | cut -d= -f2 | sort -n | tail -1)
                env_set "$ref" "$(( ${max:-$base} + 1 ))"
                info "New service variable $ref -> $(env_get "$ref")"
            elif [[ "$ref" == *_UPDATE ]]; then
                env_set "$ref" true
            fi
        fi
    done < <(grep -rhoE '\$\{[A-Z0-9_]+_(UID|UPDATE)[^}]*\}' docker-compose.yml services/*/compose.yml "$CUSTOM_DIR" 2>/dev/null \
             | sed -E 's/\$\{([A-Z0-9_]+).*/\1/' | sort -u)

}

questionnaire_ask() { # questionnaire_ask [--fresh] — the questions, in their own process; returns only when all were answered
    local rc=0
    # Ctrl-C reaches both processes: the questionnaire dies of it (130) and
    # says so by its exit code; this handler keeps configure alive to read it
    trap ':' INT
    bash "$SCRIPT_DIR/mediastack.sh" questionnaire "$@" || rc=$?
    trap - INT
    case "$rc" in
        0)   ;;
        130) echo; info "Cancelled — nothing was applied. The answers so far are next time's defaults (a folder change is asked again)."; exit 130 ;;
        3)   exit 3 ;;   # it said why: no terminal to ask on
        *)   die "the questions stopped (exit $rc, above) — nothing was applied. Run ./mediastack.sh configure again." ;;
    esac
}

roots_apply() { # the folders the questionnaire chose: made, their old contents handled as answered, recorded with their mount
    local -a rows; local row var path choice cur
    mapfile -t rows < <(state_get "$ROOTS_STATE")
    for row in "${rows[@]}"; do
        [[ -n "$row" ]] || continue
        IFS=$'\t' read -r var path choice <<<"$row"
        cur=$(env_get "$var"); [[ -z "$cur" ]] || cur=$(abspath "$cur")
        sudo mkdir -p "$path"
        [[ -z "$cur" || "$cur" == "$path" ]] || root_move_apply "$var" "$cur" "$path" "$choice"
        env_set "$var" "$path"
        env_set "${var}_SOURCE" "$(findmnt -rn -o SOURCE --target "$path")"
    done
    state_del "$ROOTS_STATE"
}

root_move_apply() { # root_move_apply VAR old new CHOICE — the old folder's contents, as the questionnaire's answer says
    local var="$1" old="$2" new="$3" choice="$4" n size
    sudo test -d "$old" || return 0
    n=$(sudo find "$old" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
    (( n > 0 )) || return 0
    case "$choice" in
        leave|new) env_set "${var}_PREVIOUS" "$old"; info "$old left in place — see doctor"; return 0 ;;
        move)      ;;
        *)         die "$var: $old holds $n entries configure did not see when it asked (it could not read the folder, or something wrote there since).
  Nothing was changed for $var. Run ./mediastack.sh configure again — it asks what happens to them." ;;
    esac
    size=$(sudo du -sh "$old" 2>/dev/null | cut -f1)
    # no merge semantics: the new path must be empty, or the move is refused
    if (( $(sudo find "$new" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l) > 0 )); then
        die "$new is not empty — a move needs an empty destination. Nothing was changed for $var (still $old).
  Empty it, or run ./mediastack.sh configure again and pick another path."
    fi
    if [[ -n "$(c_inspect_all; jq -r '.[] | select(.State.Status=="running") | .Name' <<<"$INSPECT_JSON")" ]]; then
        info "stopping the stack for a consistent move..."; DC stop >/dev/null
    fi
    if [[ "$(fsdev_of "$old")" == "$(fsdev_of "$new")" ]]; then
        sudo find "$old" -mindepth 1 -maxdepth 1 -exec mv -t "$new" {} + \
            || die "move failed — nothing was removed; $var still points at $old"
    else
        need_cmd rsync
        sudo rsync -a "$old"/ "$new"/ || die "copy failed — nothing was removed; $var still points at $old"
        # verify before deleting: a dry re-sync must have nothing to do
        if [[ -n "$(sudo rsync -a -n --itemize-changes "$old"/ "$new"/ | grep -v '^\.d\.\.t')" ]]; then
            die "copy verification failed — the old copy at $old is intact; $var still points at $old. Compare the two by hand before retrying."
        fi
        sudo find "$old" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    fi
    env_del "${var}_PREVIOUS"
    ok "$var contents moved to $new ($n $( (( n == 1 )) && echo entry || echo entries), $size)"
}

cmd_configure() {
    need_cmd jq; need_cmd docker
    local fresh=()
    if [[ ! -f "$ENV_FILE" ]]; then
        cp .env.example "$ENV_FILE"; chmod 600 "$ENV_FILE"; info "Created .env from .env.example"
        state_set configure-first yes   # until the questions are answered once, the .env holds no choices
    fi
    chmod 600 "$ENV_FILE" || true
    [[ -z "$(state_get configure-first)" ]] || fresh=(--fresh)
    # sudo's password now, before the first question: the questionnaire reads
    # the catalogue through compose (sudo), and it shares this terminal's ticket
    if (( $(id -u) != 0 )) && [[ -t 0 ]]; then
        info "configure makes users and folders with sudo — its password is asked once, now"
        sudo -v
    fi
    questionnaire_ask "${fresh[@]}"
    state_del configure-first

    roots_apply
    # the check `up` makes, made here: a port two services publish fails now, not halfway through a start
    vpn_gen
    # shellcheck disable=SC2034  # render's cache (mediastack.sh): cleared so the check sees this .env
    RENDERED_JSON=""
    require_free_ports
    provision
    cmd_apply_timer
    # leak-test compares the tunnel against this host's own address: the
    # first record now, before any tunnel runs — then once a day (host-identity)
    if [[ -z "$(hostid_age)" ]]; then
        if hostid_refresh; then ok "record of this host's own address made (RIPEstat)"
        else warn "record of this host's own address not made — $RIPESTAT_ERR. leak-test reports UNPROVEN until it is: ./mediastack.sh host-identity"; fi
    fi
    # new email settings: the portal's reset link follows them (none until they pass a test)
    if [[ -n "$(state_get "$EMAIL_STATE")" ]]; then state_del "$EMAIL_STATE"; authentik_recovery_refresh; fi
    if [[ -n "$(state_get "$PANEL_STATE")" ]]; then state_del "$PANEL_STATE"; echo; cmd_frontdoor_install; fi

    echo; questionnaire_summary
    hr "Configure complete"
    cat <<EOF
Next steps:
  1. ./mediastack.sh up          start everything
  2. ./mediastack.sh wire        connect the apps to each other (safe to re-run)
  3. ./mediastack.sh trash-sync  quality profiles from the TRaSH Guides
  4. ./mediastack.sh doctor      verify the deployment
  5. ./mediastack.sh leak-test   prove the VPN cannot leak
Addresses and ports: ./mediastack.sh status — passwords the stack made: credentials
EOF
}
