#!/usr/bin/env bash
# lib/rotate.sh — `rotate-secrets` (docs/design-rotate.md): every machine
# secret the stack made gets a new value, each one all-or-nothing, and the
# stack is up and proven at the end. The verb keeps the order and the words;
# each secret's part lives with its service:
#   <stem>_secrets              one line per secret it rotates on this install:
#                               NAME<TAB>cost tags (comma-separated, ROTATE_COSTS)
#   <stem>_secret_rotate NAME   rotates NAME: rc 0 proven, 1 put back on its old
#                               value (said why), 2 left changed (the run stops)
# No value is ever printed: the run's output, its run record and the journal's
# reader see names only. Sourced by the entrypoint; relies on lib/common.sh,
# lib/backup.sh and the services' own helpers at call time.

# The order secrets are rotated in — a service's stem, as its functions are named.
# Whatever holds a copy is rewired once, by a full `wire` after the last one:
# an owner-made key cannot go back anyway, and every holder's step follows
# the owner's current key (desired state).
ROTATE_ORDER=(authentik jellyfin arr seerr cleanuparr bazarr lazylibrarian meilisearch gluetun portal_sessions)

# What a cost tag means: said before the run (a cost), and in the closing
# warning when the tag is set (left empty: nothing outside the stack to do).
declare -A ROTATE_COSTS=(
    [akadmin]="the portal's own admin (akadmin) gets a new password"
    [companion]="phone and companion apps (nzb360, LunaSea, …) and integrations you set up lose their access to the arrs, Prowlarr, Bazarr and Seerr until you give them the new keys"
    [portal]="the portal restarts (sign-in is down for about a minute), and Jellyfin's sign-in for a few seconds while its LDAP outpost restarts"
    [signout]="everyone is signed out of the portal and of every tool behind it, the panel included"
    [search]="search answers nothing while Meilisearch and JellySearch restart (a minute)"
    [vpn]="the VPN'd services restart through the leak gate (a minute or two)"
    [wizarr-jellyfin]="Wizarr keeps the old Jellyfin key until you paste the new one into it"
)
declare -A ROTATE_AFTER=(
    [akadmin]="The portal's akadmin password changed: ./mediastack.sh credentials shows it."
    [companion]="Phone and companion apps (nzb360, LunaSea, …) and any integration you set up yourself: give them the new API keys — ./mediastack.sh credentials shows them."
    [portal]=""
    [signout]="Everyone was signed out of the portal: sign in again."
    [search]=""
    [vpn]=""
    [wizarr-jellyfin]="Wizarr: paste the new Jellyfin API key into its Settings → Servers (./mediastack.sh credentials shows it)."
)

# Secrets held outside the stack: never rotated here — the end says where a new one comes from.
ROTATE_EXTERNAL=(
    "WIREGUARD_PRIVATE_KEY|the VPN's key: a new one from your VPN provider, then ./mediastack.sh configure (full) and replace it at the VPN step"
    "CF_DNS_API_TOKEN|Cloudflare's DNS token: a new one in Cloudflare's dashboard, then ./mediastack.sh traefik-setup"
    "CLOUDFLARE_TUNNEL_TOKEN|the Cloudflare tunnel's token: a new one in Cloudflare's dashboard, into CLOUDFLARE_TUNNEL_TOKEN in .env, then ./mediastack.sh up"
    "SMTP_PASSWORD|the mail login: a new app password from your mail provider, then ./mediastack.sh configure (its Email step) and ./mediastack.sh up"
    "NOTIFY_OPS|the ops stream's URLs: new ones from where they point, then ./mediastack.sh notify set ops"
    "NOTIFY_USERS|the users stream's URLs: new ones from where they point, then ./mediastack.sh notify set users"
)

ROTATE_DIR="$LOCAL_DIR/rotate"
ROTATE_JOURNAL="$ROTATE_DIR/journal"   # 0600: the restore point, and the secret in flight (old and new value)

# ---------------------------------------------------------------- journal --
rotate_journal_start() { # rotate_journal_start POINT — a run begins: its restore point, nothing in flight
    install -d -m 700 "$ROTATE_DIR"; repo_owned "$LOCAL_DIR" "$ROTATE_DIR"
    ( umask 077; printf 'point\t%s\n' "$1" > "$ROTATE_JOURNAL" ); repo_owned "$ROTATE_JOURNAL"
}
rotate_journal_hold() { # rotate_journal_hold NAME OLD NEW [NAME OLD NEW]... — written before any of them changes anywhere
    local point; point=$(rotate_journal_point)
    ( umask 077
      { printf 'point\t%s\n' "$point"
        while (( $# >= 3 )); do printf 'inflight\t%s\t%s\t%s\n' "$1" "$2" "$3"; shift 3; done; } > "$ROTATE_JOURNAL" )
}
rotate_journal_release() { # NAME is settled (proven, or back on its old value): nothing in flight
    rotate_journal_start "$(rotate_journal_point)"
}
rotate_journal_end() { rm -f "$ROTATE_JOURNAL"; }   # the run finished
rotate_journal_point() { awk -F'\t' '$1 == "point" { print $2 }' "$ROTATE_JOURNAL" 2>/dev/null || true; }
rotate_inflight() { awk -F'\t' '$1 == "inflight" { print $2 }' "$ROTATE_JOURNAL" 2>/dev/null | paste -sd' ' - || true; }   # -> the names in flight, "" when none

# ------------------------------------------------------------ declarations --
rotate_secrets_list() { # -> STEM<TAB>NAME<TAB>TAGS per secret this install rotates, in ROTATE_ORDER
    local stem name tags
    for stem in "${ROTATE_ORDER[@]}"; do
        while IFS=$'\t' read -r name tags; do
            [[ -n "$name" ]] && printf '%s\t%s\t%s\n' "$stem" "$name" "$tags"
        done < <("${stem}_secrets")
    done
}
rotate_tags() { # rotate_tags LIST -> each cost tag the list carries, once, in first-seen order
    cut -f3 <<<"$1" | tr ',' '\n' | awk 'NF && !seen[$0]++'
}

# ---------------------------------------------------------------- helpers --
rotate_http_code() { # rotate_http_code URL HEADER -> the HTTP code URL answers a request carrying HEADER with (000: no answer)
    local c
    c=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -H "$2" "$1" 2>/dev/null) || true
    echo "${c:-000}"
}
rotate_proven() { # rotate_proven WHAT URL NEW-HEADER OLD-HEADER — the new key opens URL (waited for, up to a minute), the old one is refused (401/403)
    local what="$1" url="$2" c _
    for _ in $(seq 1 30); do c=$(rotate_http_code "$url" "$3"); [[ "$c" =~ ^2 ]] && break; sleep 2; done
    [[ "$c" =~ ^2 ]] || { fail "$what: the new key is refused (HTTP $c)"; return 1; }
    c=$(rotate_http_code "$url" "$4")
    [[ "$c" == 401 || "$c" == 403 ]] || { fail "$what: the old key still opens it (HTTP $c)"; return 1; }
    ok "$what: takes the new key, refuses the old one"
}
rotate_hex() { head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n'; }   # 32 hex: the shape Bazarr's and LazyLibrarian's own keys have
rotate_up() { # the stack's own `up` (the leak gate included), quiet unless it fails
    local out rc=0
    info "starting what the change touched (up)..."
    out=$( (cmd_up) 2>&1 ) || rc=$?
    if (( rc )); then fail "up failed (exit $rc):"; tail -n 15 <<<"$out" | sed 's/^/    /'; return 1; fi
}
rotate_env() { # rotate_env KEY NEW PROVE-FN — a secret compose hands its containers: .env, up, PROVE-FN NEW OLD; put back when not proven
    local key="$1" new="$2" prove="$3" old
    old=$(env_get "$key")
    [[ -n "$old" ]] || { fail "$key: no value in .env to replace"; return 1; }
    rotate_journal_hold "$key" "$old" "$new"
    env_set "$key" "$new"
    if rotate_up && "$prove" "$new" "$old"; then rotate_journal_release; return 0; fi
    fail "$key: the new value is not proven — putting the old one back"
    env_set "$key" "$old"
    if rotate_up && "$prove" "$old" "$new"; then rotate_journal_release; return 1; fi
    fail "$key: the old value is not proven either"
    return 2
}

# ------------------------------------------------------------------- words --
rotate_box() { # rotate_box LINE... — the closing warning: framed, bold, impossible to miss
    local w=74 l LC_ALL=C.UTF-8   # widths in characters: the frame and the bullets are multibyte
    printf '%s\n' "${C_YLW}${C_BLD}╔$(printf '═%.0s' $(seq 1 $w))╗${C_RST}"
    for l in "$@"; do
        if [[ "$l" == --- ]]; then printf '%s\n' "${C_YLW}${C_BLD}╠$(printf '═%.0s' $(seq 1 $w))╣${C_RST}"; continue; fi
        local ind=""; [[ "$l" == "• "* ]] && ind="  "   # a bullet's next lines sit under its words
        while IFS= read -r l; do
            printf '%s\n' "${C_YLW}${C_BLD}║ ${l}$(printf '%*s' $((w - 2 - ${#l})) '') ║${C_RST}"
        done < <(fold -s -w $((w - 2 - ${#ind})) <<<"$l" | sed "s/ *\$//; 2,\$s/^/$ind/")
    done
    printf '%s\n' "${C_YLW}${C_BLD}╚$(printf '═%.0s' $(seq 1 $w))╝${C_RST}"
}
rotate_box_lines() { # rotate_box_lines TAGS — the closing warning's lines for what this run touched
    local t e key words any=0 todo=()
    while IFS= read -r t; do
        [[ -n "${ROTATE_AFTER[$t]:-}" ]] && todo+=("• ${ROTATE_AFTER[$t]}")
    done <<<"$1"
    if (( ${#todo[@]} )); then
        echo "SECRETS ROTATED — ANYTHING OUTSIDE THE STACK NOW HAS A STALE ONE"; echo ---
        printf '%s\n' "${todo[@]}"; any=1
    else
        echo "SECRETS ROTATED"; echo ---
        echo "• Nothing outside the stack held these secrets."
    fi
    for e in "${ROTATE_EXTERNAL[@]}"; do
        key=${e%%|*}; words=${e#*|}
        [[ -n "$(env_get "$key")" ]] || continue
        (( any == 2 )) || { echo ---; echo "Not rotated — held outside the stack, yours to replace:"; any=2; }
        echo "• $words"
    done
}

# ------------------------------------------------------------------- verb --
cmd_rotate_secrets() {
    load_env
    local stem name tags list n point rc rotated=() back=() stuck=""
    if [[ -n "$(rotate_inflight)" ]]; then
        point=$(rotate_journal_point)
        die "A rotation never finished: $(rotate_inflight) was in flight (local/rotate/journal).
  Put the stack back as it was before it, then rotate again:
    ./mediastack.sh restore --all --from $point
    ./mediastack.sh rotate-secrets"
    fi
    [[ -t 0 ]] || die "rotate-secrets is interactive — run it at a terminal."
    list=$(rotate_secrets_list)
    [[ -n "$list" ]] || { info "nothing to rotate: none of the services with machine secrets is enabled."; return 0; }
    n=$(wc -l <<<"$list")

    explain "Rotate every machine secret" \
"Every secret the stack made for itself gets a new value ($n on this install:
$(cut -f2 <<<"$list" | paste -sd' ' - | fold -s -w 72 | sed 's/^/  /'))
and everything that holds one is rewired. Values are never shown; the new
ones are read with: ./mediastack.sh credentials

What it costs:
  - the stack stops for a restore point, then restarts: playback stops for a
    few minutes
$(while IFS= read -r t; do [[ -n "$t" ]] && echo "  - ${ROTATE_COSTS[$t]}"; done <<<"$(rotate_tags "$list")")

Anything outside the stack that holds one of these stops working until you
give it the new value — the end of the run lists what."
    local reply=""
    read -r -p "Type ROTATE to go on (anything else stops here): " reply
    [[ "$reply" == ROTATE ]] || { info "Nothing changed."; return 0; }

    maint_lock rotate-secrets 0
    backup_take rotate "before rotate-secrets"
    point=$(latest_restore_point)
    [[ -n "$point" ]] || die "no restore point was made — nothing rotated."
    rotate_journal_start "$point"
    ok "restore point $point — rotating"

    while IFS=$'\t' read -r stem name tags; do
        hr "rotate: $name"
        rc=0; "${stem}_secret_rotate" "$name" || rc=$?
        case $rc in
            0) ok "$name: rotated and proven"; rotated+=("$name") ;;
            1) back+=("$name") ;;
            *) stuck=$name; break ;;
        esac
    done <<<"$list"

    if [[ -n "$stuck" ]]; then
        fail "$stuck is neither on its new value nor back on its old one — the run stops here."
        die "Put the stack back as it was before the run, then rotate again:
    ./mediastack.sh restore --all --from $point
    ./mediastack.sh rotate-secrets"
    fi

    hr "rotate: everything that holds one (wire)"
    local wout wrc=0 vrc=0 dline
    wout=$(MAINT_LOCKED=1 "$SCRIPT_DIR/mediastack.sh" wire 2>&1) || wrc=$?
    { grep -E 'API key updated|its API key stored|^.{0,12}FAIL' <<<"$wout" || true; } | sed 's/^/  /'
    if (( wrc )); then fail "wire reported failures (above) — fix them, then: ./mediastack.sh wire"; vrc=1
    else ok "wire: everything that holds one has its new value"; fi

    hr "rotate: the stack, proven"
    MAINT_LOCKED=1 "$SCRIPT_DIR/mediastack.sh" wire --verify >/dev/null 2>&1 || vrc=$?
    if (( vrc )); then fail "wire --verify finds drift after the rotation — see: ./mediastack.sh wire --verify"
    else ok "wire --verify: no drift"; fi
    # doctor's findings may predate the run: reported, never the run's verdict
    dline=$(MAINT_LOCKED=1 "$SCRIPT_DIR/mediastack.sh" doctor 2>&1 | sed -n 's/.*\(doctor: \(all checks passed\|[0-9]* problem(s)\)\).*/\1/p' | tail -n 1 || true)
    case "$dline" in
        *problem*) warn "$dline (some may predate this run) — see: ./mediastack.sh doctor" ;;
        "")        warn "doctor gave no summary — see: ./mediastack.sh doctor" ;;
        *)         ok "$dline" ;;
    esac
    rotate_journal_end

    echo
    (( ${#rotated[@]} )) && ok "rotated: ${rotated[*]}"
    (( ${#back[@]} )) && fail "kept their old value (each said why above): ${back[*]}"
    echo
    local box=(); mapfile -t box < <(rotate_box_lines "$(rotate_tags "$(grep -F -f <(printf '\t%s\t\n' "${rotated[@]:-}") <<<"$list" || true)")")
    rotate_box "${box[@]}"
    (( ${#back[@]} == 0 && vrc == 0 )) || exit 1
}
