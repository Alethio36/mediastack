#!/usr/bin/env bash
# lib/wire.sh — the `wire` engine: idempotent app-to-app configuration.
# The shared plumbing (api, ensure_*, readiness and gates, the role registry
# and cmd_wire); each role's code lives with its service in services/<name>/.
# Sourced by the entrypoint; relies on lib/common.sh primitives and the
# entrypoint's service/render helpers.

# ================================================================= wire ====
# Idempotent app-to-app configuration: read live state, compare intent
# (labels + .env), apply only the delta. Safe to re-run forever.
WIRE_DRY=0
WIRE_CHANGES=0
WIRE_FAILS=0
# The roles `wire` drives, in the order `wire all` runs them. This is the single
# source of truth for the role list: arg validation, the usage string, and
# dispatch all derive from it. Order is load-bearing — seerr signs in via
# jellyfin's admin and wizarr's first-run UI wants jellyfin claimed first, so
# jellyfin precedes both; authentik precedes jellyfin, whose portal sign-in
# needs the LDAP token `wire authentik` fetches (one `wire` finishes a fresh
# install). To add an integration: append its role here and define a matching
# wire_<role> function in its service's folder (services/<name>/<name>.sh);
# CI checks every role has exactly one.
WIRE_ROLES=(qbit deluge transmission arr prowlarr bazarr apprise cleanuparr lazylibrarian authentik jellyfin seerr wizarr audiobookshelf kavita)
# roles that write without observing (one big settings blob / blind writeCFG):
# their dry-run always says "would", so --verify cannot read drift from them
WIRE_BLIND=(bazarr lazylibrarian seerr)
WIRE_VERIFY=0
# shellcheck disable=SC2034  # read by wire_arrs_ready (services/_arr/arr.sh)
WIRE_ARRS_OK=0   # wire_arrs_ready passed this run
wire_is_blind() { local r; for r in "${WIRE_BLIND[@]}"; do [[ "$1" == "$r" ]] && return 0; done; return 1; }
wfail() { fail "$@"; WIRE_FAILS=$((WIRE_FAILS+1)); }

w_would() { # w_would "description" -> 0 if execution should proceed
    WIRE_CHANGES=$((WIRE_CHANGES+1))
    if (( WIRE_DRY )); then echo "  would: $1"; return 1; fi
    info "$1"
}

api() { # api METHOD URL APIKEY [json-body] -> body on stdout, rc from http
    local m="$1" u="$2" k="$3" b="${4:-}" out code
    out=$(curl -sS -m 20 -X "$m" -H "X-Api-Key: $k" -H "Content-Type: application/json" \
          ${b:+-d "$b"} -w '\n%{http_code}' "$u" 2>&1) || { echo "$out"; return 1; }
    code=${out##*$'\n'}; echo "${out%$'\n'*}"
    [[ "$code" =~ ^2 ]]
}

# The two reconcile primitives every wire recipe is built on. Rule that keeps
# them small: a nuance that recurs across services earns a primitive; a
# one-off stays inline in its recipe — never a per-case flag on the primitive.
#
# ensure_field <svc> <endpoint> <key> <cur_json> <field> <want> <noun>
#   Idempotent single-field set for a JSON config API that round-trips its whole
#   object. <cur_json> is what the caller already GET from <endpoint>; <field> is
#   a top-level scalar key. If it already equals <want>, report and skip; else,
#   w_would-gated, PUT the object with .<field>=<want> and report. <noun> labels
#   the evidence line; a rejected PUT fails loud via wfail.
ensure_field() {
    local svc="$1" endpoint="$2" key="$3" cur="$4" field="$5" want="$6" noun="$7" have
    have=$(jq -r --arg f "$field" '.[$f] // empty' <<<"$cur" 2>/dev/null)
    [[ "$have" == "$want" ]] && { ok "$svc: $noun '$have'"; return 0; }
    w_would "$svc: set $noun to '$want'" || return 0
    api PUT "$endpoint" "$key" "$(jq -c --arg f "$field" --arg v "$want" '.[$f]=$v' <<<"$cur")" >/dev/null \
        && ok "$svc: $noun set to '$want'" \
        || wfail "$svc: $noun update rejected — set it in its UI"
}

# ensure_resource <exists> <would_desc> <ok_msg> <fail_msg> -- <create-cmd...>
#   Create-if-missing skeleton. <exists> is "yes" when the caller has already
#   found the resource present in the live list — the caller owns the observe
#   and the match (patterns and whitespace handling differ per API). When
#   missing: w_would-gated, run <create-cmd>, capturing its output so a failure
#   carries the API's own words. <ok_msg> covers both already-present and
#   just-created; <fail_msg> gets the API response appended.
ensure_resource() {
    local exists="$1" would="$2" okmsg="$3" failmsg="$4"; shift 4
    [[ "${1:-}" == -- ]] && shift
    [[ "$exists" == yes ]] && { ok "$okmsg"; return 0; }
    w_would "$would" || return 0
    local out
    if out=$("$@"); then ok "$okmsg"
    else wfail "$failmsg — API said: $(head -c180 <<<"$out")"; fi
}

wire_gate() { # refuse to wire what isn't up
    local s missing=""
    for s in "$@"; do
        svc_enabled "$s" || continue
        [[ "$(c_state "$(svc_cname "$s")")" == running ]] || missing+="$s "
    done
    [[ -z "$missing" ]] || die "Cannot wire: not running: $missing
  Start the stack first: ./mediastack.sh up   (then wait for healthy: status)"
}

# http_ready [--until EPOCH] SVC URL OK_RE [curl-args...] — poll URL until it
# answers with an HTTP status matching OK_RE, or API_WAIT (or EPOCH, a shared
# deadline across several calls) runs out. The ONE API-readiness wait: a
# container being "running", even "healthy", doesn't prove the app answers
# from the host through its published port (gluetun's namespace, warm-up).
# 000 = no socket. On timeout: wfail with the last status, return 1.
API_WAIT=90
http_ready() {
    local until=0 svc url re code t0 deadline
    [[ "${1:-}" == --until ]] && { until="$2"; shift 2; }
    svc="$1" url="$2" re="$3"; shift 3
    t0=$(date +%s)
    if (( until )); then deadline=$until; else deadline=$(( t0 + API_WAIT )); fi
    while :; do
        # curl already prints 000 when there is no socket — no "|| echo 000"
        code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$@" "$url" 2>/dev/null) || true
        [[ "${code:=000}" =~ $re ]] && return 0
        if (( $(date +%s) >= deadline )); then
            wfail "$svc's API never became ready within $(( deadline - t0 ))s (last: HTTP $code) — inspect: ./mediastack.sh logs $svc"
            return 1
        fi
        sleep 5; info "waiting for $svc's API ($(( $(date +%s) - t0 ))s)..."
    done
}

wire_services() { # the enabled services the wire roles touch — derived, so a new role can't be missed
    local r s
    for r in "${WIRE_ROLES[@]}"; do
        case "$r" in
            qbit) s=qbittorrent ;;
            arr)  arr_instances; continue ;;
            *)    s=$r ;;       # every other role is named for its service
        esac
        if svc_enabled "$s"; then echo "$s"; fi
    done
}

oneline() { tr -s '[:space:]' ' ' <<<"$1" | head -c 200; }   # an app's (multi-line JSON) reply, for a message

wire_usage() { local IFS='|'; die "usage: wire [${WIRE_ROLES[*]}] [--dry-run|--verify]"; }

cmd_wire() {
    load_env; render
    local section="all"
    while [[ $# -gt 0 ]]; do case "$1" in
        --dry-run) WIRE_DRY=1; shift ;;
        --verify)  WIRE_DRY=1; WIRE_VERIFY=1; shift ;;
        all) section="all"; shift ;;
        *)  local r matched=""
            for r in "${WIRE_ROLES[@]}"; do [[ "$1" == "$r" ]] && { matched=1; break; }; done
            [[ -n "$matched" ]] || wire_usage
            section="$1"; shift ;;
    esac; done
    if (( WIRE_VERIFY )); then
        hr "wire --verify: checking for drift, touching nothing"
        [[ "$section" != all ]] && wire_is_blind "$section" \
            && die "wire --verify: '$section' writes without observing, so drift cannot be read from it (see WIRE_BLIND)"
    elif (( WIRE_DRY )); then
        hr "wire --dry-run: showing changes, touching nothing"
    fi
    if (( ! WIRE_DRY )) && [[ ! -f "$WIRED_FILE" ]]; then
        if confirm "First wire on this deployment — take a restore point first? (recommended)"; then
            backup_take manual "before the first wire"
            # the backup bounced every container — let the apps come back
            # before wiring their APIs
            info "waiting for Docker's verdict on the wired apps after the restore point (up to ${START_WAIT}s)..."
            local settle=(); mapfile -t settle < <(wire_services)
            (( ${#settle[@]} == 0 )) || wait_verdict "${settle[@]}" \
                || warn "not settled: $VERDICT_BAD — wiring anyway; anything that refuses gets a per-item FAIL and a re-run picks it up"
        fi
    fi
    # dispatch by the WIRE_ROLES registry: `all` runs every role in order,
    # a section runs its one wire_<role>. Both resolve the function by name,
    # so there is no second list to keep in sync with the one above.
    local role skipped=""
    if [[ "$section" == all ]]; then
        for role in "${WIRE_ROLES[@]}"; do
            if (( WIRE_VERIFY )) && wire_is_blind "$role"; then skipped+="$role "; continue; fi
            "wire_$role"
        done
    else
        "wire_$section"
    fi
    echo
    if (( WIRE_VERIFY )); then
        [[ -n "$skipped" ]] && info "not verifiable (write blind, skipped): ${skipped% }"
        if (( WIRE_FAILS )); then
            fail "wire --verify: $WIRE_FAILS check(s) could not run — see the FAIL lines above"; exit 1
        elif (( WIRE_CHANGES )); then
            fail "wire --verify: $WIRE_CHANGES drift item(s) — see the would: lines above. Apply: ./mediastack.sh wire"; exit 1
        fi
        ok "wire --verify: no drift"
    elif (( WIRE_DRY )); then
        info "dry-run complete: $WIRE_CHANGES change(s) would be applied. Run without --dry-run to apply."
        info "note: items marked as pending on credentials resolve mid-run — the real run creates them in order."
    else
        mkdir -p "$LOCAL_DIR"; touch "$WIRED_FILE"; repo_owned "$LOCAL_DIR" "$WIRED_FILE"
        if (( WIRE_FAILS )); then
            fail "wire finished with $WIRE_FAILS failure(s) — see the FAIL lines above. Re-run after fixing; completed items just skip."
            exit 1
        fi
        ok "wire complete. Verify: ./mediastack.sh doctor   Credentials: ./mediastack.sh credentials"
    fi
}
