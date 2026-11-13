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

questionnaire_ask() { # questionnaire_ask [--fresh] [--answers FILE] — the questions, in their own process; returns only when all were answered
    local rc=0
    # Ctrl-C reaches both processes: the questionnaire dies of it (130) and
    # says so by its exit code; this handler keeps configure alive to read it
    trap ':' INT
    bash "$SCRIPT_DIR/mediastack.sh" questionnaire "$@" || rc=$?
    int_trap_default   # the run record notes a Ctrl-C after this (lib/runs.sh)
    case "$rc" in
        0)   ;;
        130) echo; info "Cancelled — nothing was applied. The answers so far are next time's defaults (a folder change is asked again)."; exit 130 ;;
        3)   exit 3 ;;   # it said why: no terminal to ask on
        4)   die "the answers file has the problems listed above — nothing was asked or applied. Fix them and run configure again." ;;
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

cmd_configure() { # configure [--answers FILE] [--domain D] [--services a,b] [--signin X] — the questions (answered ahead or asked), then everything they decide
    need_cmd jq; need_cmd docker
    local fresh=()
    answers_opts "$@"
    (( ${#ANSWERS_REST[@]} == 0 )) || die "unknown argument '${ANSWERS_REST[0]}' for 'configure' (accepts: --answers FILE, --domain D, --services a,b, --signin none|wizarr|authentik)"
    sudo_unattended_check
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
    questionnaire_ask "${fresh[@]}" "${ANSWERS_OPTS[@]}"
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
        if hostid_refresh; then ok "record of this host's own address made (RIPEstat): your ISP's network is $(hostid_network)"
        else warn "record of this host's own address not made — $RIPESTAT_ERR. leak-test reports UNPROVEN until it is: ./mediastack.sh host-identity"; fi
    fi
    # new email settings: the portal's reset link follows them (none until they pass a test)
    if [[ -n "$(state_get "$EMAIL_STATE")" ]]; then state_del "$EMAIL_STATE"; authentik_recovery_refresh; fi

    echo; questionnaire_summary
    local steps=(); mapfile -t steps < <(chain_steps)
    echo
    if chain_wanted; then chain_run "${steps[@]}"; closing_todo; else chain_left "${steps[@]}"; fi
}

chain_wanted() { # a first run (never wired) starts everything on Enter; a live stack serves people and applying restarts things: No unless asked
    local start; start=$(state_get "$START_STATE"); state_del "$START_STATE"
    case "$start" in
        yes) info "Start: yes (from the answers)"; return 0 ;;
        no)  info "Start: no (from the answers)"; return 1 ;;
    esac
    if [[ ! -f "$WIRED_FILE" ]]; then confirm_yes "Start everything now?"; else confirm "Apply the changes now?"; fi
}

sudo_unattended_check() { # with answers given and no terminal, sudo cannot ask its password: refuse before anything starts
    (( ${#ANSWERS_OPTS[@]} )) && [[ ! -t 0 ]] && (( $(id -u) != 0 )) || return 0
    sudo -n true 2>/dev/null || die "sudo needs its password, and with no terminal nothing can ask for it — run 'sudo -v' first (in the same session), or run this as root"
}

# ------------------------------------------------------------ the chain --
# configure's (and enable's) last part: each step is the verb itself, run as
# its own process, so a step that stops (die) stops the chain, not configure —
# and the message names every step still to run. Every step is safe to run
# again, which is how a chain that stopped carries on: run configure again.
chain_steps() { # the steps this stack needs, in order: the panel first (it adds a container up starts)
    # asked for now, or enabled on a host it was never installed on (a restored .env, found live Nov 2026)
    if [[ -n "$(state_get "$PANEL_STATE")" ]] || { svc_enabled olivetin && ! frontdoor_installed; }; then echo frontdoor-install; fi
    echo up; echo wire
    if [[ -n "$(trash_instances)" ]]; then echo trash-sync; fi
}

chain_left() { # chain_left STEP... — what is left to run by hand, in order
    (( $# )) || return 0
    info "Still to run, in this order: $(printf './mediastack.sh %s, ' "$@" | sed 's/, $//')"
}

chain_ssh_warn() { # over SSH outside tmux or screen, a dropped session stops the chain
    [[ -n "${SSH_CONNECTION:-}" && -z "${TMUX:-}" && -z "${STY:-}" ]] || return 0
    warn "you are connected over SSH outside tmux or screen: if the connection drops, the steps stop where they are (expect ~15-20 min on a first run)."
    warn "  Running ./mediastack.sh configure again carries on — every step is safe to repeat."
}

chain_run() { # chain_run STEP... — each in turn, stopping at the first that fails
    local i rc
    chain_ssh_warn
    for (( i = 1; i <= $#; i++ )); do
        hr "Step $i of $#: ${!i}"
        rc=0; bash "$SCRIPT_DIR/mediastack.sh" "${!i}" || rc=$?
        if (( rc )); then
            fail "'${!i}' stopped (exit $rc, above) — nothing was undone."
            chain_left "${@:i}"
            exit "$rc"
        fi
        [[ "${!i}" != frontdoor-install ]] || state_del "$PANEL_STATE"
    done
    ok "All $# steps done."
    notify ops "Mediastack" "$CMD finished: $(printf '%s, ' "$@" | sed 's/, $//') all done." info   # configure's chain, or enable's
}

closing_todo() { # what is proven, what is still yours to do, where things are
    local out d=0 l
    hr "Verified"
    out=$(bash "$SCRIPT_DIR/mediastack.sh" doctor 2>&1) || d=1
    if (( d )); then
        # doctor's FAIL lines, each with its why/fix lines
        sed 's/\x1b\[[0-9;]*m//g' <<<"$out" | awk '/^FAIL doctor:/ { next } /^FAIL / { p = 1; print; next } p && /^     (why|fix) :/ { print; next } { p = 0 }'
    else
        ok "doctor: no problems"
    fi
    out=$(bash "$SCRIPT_DIR/mediastack.sh" leak-test 2>&1) || true
    l=$(sed 's/\x1b\[[0-9;]*m//g' <<<"$out" | grep -E '^(FAIL|WARN UNPROVEN|OK leak-test)' || true)
    printf '%s\n' "${l:-leak-test: no verdict line — run ./mediastack.sh leak-test}"
    hr "Still yours to do"
    if signin_is authentik; then echo "  * make your own account in the portal: invite yourself (./mediastack.sh invite) — the stack's logins are not for people"; fi
    if svc_enabled prowlarr; then echo "  * add your indexers in Prowlarr: doctor reports the arrs without them until you do"; fi
    if signin_is wizarr; then echo "  * Wizarr's API key: ./mediastack.sh wire wizarr (its UI must exist first)"; fi
    if signin_is authentik && [[ -n "$(env_get SMTP_HOST)" ]]; then echo "  * prove the portal's email: ./mediastack.sh email test <your address>"; fi
    if svc_enabled traefik; then echo "  * the LAN DNS record *.$(env_get STACK_DOMAIN) -> this host — to reach the services by name"; fi
    hr "Where things are"
    echo "  * logins and passwords: ./mediastack.sh credentials"
    echo "  * what runs, and where: ./mediastack.sh status"
    if svc_enabled olivetin; then echo "  * the panel: https://$(svc_subdomain olivetin).$(env_get STACK_DOMAIN)"; fi
}
