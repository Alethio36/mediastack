#!/usr/bin/env bash
# lib/integrations.sh — the service-integration layer: thin per-service API
# wrappers (arr/qbit/jellyfin/seerr/cleanuparr/apprise/...), the idempotent
# `wire` engine that drives them, and their shared globals. Sourced by the
# entrypoint; credentials/trash also call these API wrappers. Relies on
# lib/common.sh primitives and the entrypoint's service/render helpers.

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
# jellyfin precedes both. To add an integration: append its role here and define
# a matching wire_<role> function below.
WIRE_ROLES=(qbit arr prowlarr bazarr apprise cleanuparr lazylibrarian jellyfin seerr wizarr authentik)
# roles that write without observing (one big settings blob / blind writeCFG):
# their dry-run always says "would", so --verify cannot read drift from them
WIRE_BLIND=(bazarr lazylibrarian seerr)
WIRE_VERIFY=0
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

arr_key() { # arr_key <svc> -> api key from its config.xml ("" while initialising)
    sudo grep -oP '<ApiKey>\K[^<]+' "$(env_get CONFIG_ROOT)/$1/config.xml" 2>/dev/null | head -1 || true
}

arr_url() { local p; p=$(svc_hostport "$1") || return 1; echo "http://127.0.0.1:$p"; }

bazarr_key() { # bazarr_key -> api key from its config.yaml ("" while initialising)
    sudo grep -oP 'apikey:\s*\K\S+' "$(env_get CONFIG_ROOT)/bazarr/config/config.yaml" 2>/dev/null | head -1 || true
}

# ---- app-to-app addresses ----
# How one app reaches another — what wire writes INTO an app's settings (the
# script's own API calls use the host ports above instead). One rule, proven
# live on the stack: a service behind the VPN listens in gluetun's namespace,
# so every caller, behind the VPN or not, reaches it as gluetun:<port>; a
# service outside the VPN is reached by its service name on the stack network,
# from either side. The address depends only on the TARGET: moving a caller
# in or out of the VPN never breaks a connection, moving a target means
# re-pointing its callers — addr_stale/addr_repoint do it, and after a VPN
# toggle `up` runs them for every caller in WIRE_CALLERS.
svc_host() { # svc_host <target> -> gluetun | <target>, from its effective VPN membership
    if [[ "$(vpn_effective "$1" "$(svc_label "$1" mediastack.vpn)")" == true ]]; then echo gluetun; else echo "$1"; fi
}
svc_cport() { svc_label "$1" mediastack.port; }   # the port it listens on inside its namespace
svc_addr()  { echo "$(svc_host "$1"):$(svc_cport "$1")"; }
addr_of() { # addr_of <url | host:port> -> host:port (scheme and path dropped)
    local a=${1#*://}; echo "${a%%/*}"
}
addr_stale() { # addr_stale <what> <target> <stored host:port> -> 0 when mediastack's own address needs re-pointing
    # Only addresses mediastack itself makes are claimed: the target's port on
    # localhost, 127.0.0.1, gluetun or the target's name (any layout, before or
    # after a toggle). Anything else was set by hand — reported, never touched.
    local want; want=$(svc_addr "$2")
    [[ -z "$3" || "$3" == "$want" ]] && return 1
    if [[ "${3##*:}" == "$(svc_cport "$2")" && "${3%:*}" =~ ^(localhost|127\.0\.0\.1|gluetun|$2)$ ]]; then return 0; fi
    info "$1 points at $3 — not an address mediastack makes, so it is yours: left alone"
    return 1
}
addr_repoint() { # addr_repoint <what> <stored> <want> -- <command...> — re-point, or say it would
    local what="$1" stored="$2" want="$3" out; shift 3; [[ "${1:-}" == -- ]] && shift
    w_would "$what: re-point $stored -> $want" || return 0
    if out=$("$@" 2>&1); then ok "$what: re-pointed to $want"
    else wfail "$what: re-point to $want rejected — $(oneline "$out")"; fi
}
# WIRE_CALLERS — who calls whom: for each service wire points OTHER apps at,
# the wire roles that write its address. A VPN toggle moves that address
# (svc_addr), so after the move these roles re-run and re-point their entries
# (wire_repoint_pending, from `up`). "arr" stands for every arr instance.
# recyclarr's arr addresses need no role: trash-sync regenerates them each run.
# CI (scripts/test-repoint.sh) fails if wire points at a service not listed.
declare -A WIRE_CALLERS=(
    [qbittorrent]="arr prowlarr cleanuparr lazylibrarian"
    [apprise]="apprise cleanuparr seerr"
    [arr]="prowlarr cleanuparr seerr bazarr"
    [prowlarr]="prowlarr"
    [lazylibrarian]="prowlarr"
    [flaresolverr]="prowlarr"
    [jellyfin]="seerr"
)
wire_callers() { # wire_callers <svc> -> the roles that write an address of <svc>, one per line
    local key="$1"; [[ -n "$(svc_label "$1" mediastack.arrtype)" ]] && key=arr
    tr ' ' '\n' <<<"${WIRE_CALLERS[$key]:-}" | awk NF
}
repoint_mark() { # repoint_mark <svc> — its address is about to move: re-point its callers after `up`
    local cur; cur=$(state_get WIRE_REPOINT)
    [[ " $cur " == *" $1 "* ]] || state_set WIRE_REPOINT "${cur:+$cur }$1"
}
wire_repoint_pending() { # after `up`: re-point the callers of every service a VPN toggle moved
    local pending s role want="" roles="" failed=""
    pending=$(state_get WIRE_REPOINT); [[ -n "$pending" ]] || return 0
    # never wired: no app holds an address yet, so nothing can be stale
    [[ -f "$WIRED_FILE" ]] || { state_del WIRE_REPOINT; return 0; }
    for s in $pending; do want+=" $(wire_callers "$s" | tr '\n' ' ')"; done
    for role in "${WIRE_ROLES[@]}"; do [[ " $want " == *" $role "* ]] && roles+="$role "; done   # wire's own order
    [[ -n "$roles" ]] || { state_del WIRE_REPOINT; return 0; }
    hr "Re-pointing what calls: $pending (moved in or out of the VPN)"
    for role in $roles; do
        # cmd_wire exits on failure: a subshell keeps `up` alive to report it
        ( cmd_wire "$role" ) || failed+="$role "
    done
    if [[ -n "$failed" ]]; then
        fail "re-pointing incomplete — wire ${failed% } reported failures (above). Fix, then: ./mediastack.sh up (retries) or ./mediastack.sh wire"
        return 1
    fi
    state_del WIRE_REPOINT
    ok "everything that calls ${pending} re-pointed"
}

qbit_login_fields() { # qbit_login_fields <list JSON> <entry name> -> the login to (re)send, one field per line
    # none when the entry authenticates by qBittorrent API key: Sonarr, Radarr
    # and Prowlarr reject an entry holding a key AND a username/password
    [[ -n "$(arr_entry_field "$1" "$2" apiKey)" ]] && return 0
    printf '%s\n' "username=$(env_get QBITTORRENT_USER)" "password=$(env_get QBITTORRENT_PASSWORD)"
}
arr_repoint() { # arr_repoint <api base> <key> <resource> <list JSON> <entry name> field=value...
    # PUT the entry back with just those fields changed. Secrets the API masked
    # on GET ("********") go back as-is and the app keeps its stored value — the
    # same round trip its own UI does (Servarr SchemaBuilder.ReadFromSchema).
    local base="$1" key="$2" res="$3" list="$4" name="$5" kv entry; shift 5
    entry=$(jq -c --arg n "$name" '[.[]? | select(.name == $n)][0] // empty' <<<"$list")
    [[ -n "$entry" ]] || { echo "entry '$name' is gone"; return 1; }
    for kv in "$@"; do
        entry=$(jq -c --arg f "${kv%%=*}" --arg v "${kv#*=}" \
            '.fields |= map(if .name == $f then .value = (if (.value | type) == "number" then ($v | tonumber) else $v end) else . end)' <<<"$entry")
    done
    api PUT "$base/$res/$(jq -r '.id' <<<"$entry")" "$key" "$entry"
}
arr_entry_fields() { # arr_entry_fields <list JSON> <entry name> -> "field=value" lines
    jq -r --arg n "$2" '.[]? | select(.name == $n) | .fields[]? | "\(.name)=\(.value // "" | tostring)"' <<<"$1" 2>/dev/null || true
}
arr_entry_field() { # arr_entry_field <list JSON> <entry name> <field> -> value
    arr_entry_fields "$1" "$2" | sed -n "s/^$3=//p" | head -1
}
# ARR_META — every per-type fact wire needs, one row per arr type, so a new
# type (readarr, whisparr) is a row here instead of a hunt through recipes.
#   api       API version path            impl      Prowlarr implementation name
#   catfield  download-client category    major     app major (cleanuparr's "version")
#   jftype    Jellyfin collection type    jfname    default Jellyfin library name
declare -A ARR_META=(
    [sonarr.api]=v3  [sonarr.impl]=Sonarr [sonarr.catfield]=tvCategory    [sonarr.major]=4 [sonarr.jftype]=tvshows [sonarr.jfname]="TV Shows"
    [radarr.api]=v3  [radarr.impl]=Radarr [radarr.catfield]=movieCategory [radarr.major]=6 [radarr.jftype]=movies  [radarr.jfname]=Movies
    [lidarr.api]=v1  [lidarr.impl]=Lidarr [lidarr.catfield]=musicCategory [lidarr.major]=3 [lidarr.jftype]=music   [lidarr.jfname]=Music
)
arr_known() { [[ -n "${ARR_META[${1:-?}.api]:-}" ]]; }   # arr_known TYPE — a type wire supports
arr_meta() { # arr_meta TYPE FIELD — dies loud on a gap: a wrong default here is a silent misconfig
    local v="${ARR_META[${1:-?}.$2]:-}"
    [[ -n "$v" ]] || die "arr type '${1:-<none>}' has no '$2' in ARR_META (lib/integrations.sh)"
    echo "$v"
}
arr_apiver() { # prowlarr speaks v1; every arr instance its type's version
    [[ "$1" == prowlarr ]] && { echo v1; return; }
    arr_meta "$(svc_label "$1" mediastack.arrtype)" api
}

arr_pretty_name() { # sonarr-anime -> "Sonarr (Anime)", radarr-4k -> "Radarr (4K)"
    local s="$1" ty suffix
    ty=$(svc_label "$s" mediastack.arrtype)
    suffix=${s#"$ty"}; suffix=${suffix#-}
    case "$suffix" in
        "")    echo "${ty^}" ;;
        4k)    echo "${ty^} (4K)" ;;
        anime) echo "${ty^} (Anime)" ;;
        *)     echo "${ty^} (${suffix^})" ;;
    esac
}

arr_instance_name() { # brand the instance so notifications are tellable apart;
                      # only replaces the stock default — a custom name is yours
    local s="$1" key ep cur have want
    key=$(arr_key "$s"); [[ -n "$key" ]] || return 0
    ep="$(arr_url "$s")/api/$(arr_apiver "$s")/config/host"
    cur=$(api GET "$ep" "$key" || true)   # soft read: a failed read shows as a change; the write that follows fails loud
    have=$(jq -r '.instanceName // empty' <<<"$cur" 2>/dev/null)
    want=$(arr_pretty_name "$s")
    # one-off (stays inline, not an ensure_field concern): a custom name — non-empty,
    # different from what we'd set, and not the stock lowercase default — is the
    # operator's, so never touch it. Must check "!= want" first so a correctly
    # branded instance (e.g. "Radarr (4K)") reads as already-set, not custom.
    if [[ -n "$have" && "$have" != "$want" && "${have,,}" != "$(svc_label "$s" mediastack.arrtype)" ]]; then
        ok "$s: instance name '$have' (custom) — untouched"; return 0
    fi
    ensure_field "$s" "$ep" "$key" "$cur" instanceName "$want" "instance name"
}

arr_login() { # the arr's own login: "external" (trust the gate) when gate_trusted, the shared forms login otherwise
    local s="$1" key url cur
    gate_trusted "$s" || { arr_forms_login "$s"; return; }
    key=$(arr_key "$s"); [[ -n "$key" ]] || return 0
    url=$(arr_url "$s")
    cur=$(api GET "$url/api/$(arr_apiver "$s")/config/host" "$key" || true)   # soft read: a failed read shows as a change; the write that follows fails loud
    local match=no
    jq -e '.authenticationMethod == "external"' <<<"$cur" >/dev/null 2>&1 && match=yes
    # external: the arr trusts what is in front of it — the portal; its API
    # still demands the API key (companion apps reach /api past the gate)
    ensure_resource "$match" "$s: trust the portal (one login) — reachable only through it" \
        "$s: trusts the portal" "$s: could not switch to trusting the portal — check: logs $s" \
        -- api PUT "$url/api/$(arr_apiver "$s")/config/host" "$key" "$(jq -c '.authenticationMethod="external"' <<<"$cur")"
}

arr_forms_login() { # shared operator login on an arr-family UI; idempotent
    local s="$1" auser apass key url cur body verb=enable match=no
    [[ "${2:-}" == force ]] && verb=rotate
    auser=$(env_get ARR_USER); apass=$(env_get ARR_PASSWORD)
    [[ -n "$auser" && -n "$apass" ]] || { info "$s: shared arr login not set yet — 'wire arr' creates it"; return 0; }
    key=$(arr_key "$s"); [[ -n "$key" ]] || return 0
    url=$(arr_url "$s")
    cur=$(api GET "$url/api/$(arr_apiver "$s")/config/host" "$key" || true)   # soft read: a failed read shows as a change; the write that follows fails loud
    # match on the readable subset (the password is write-only); a forced
    # rotate never matches — one-off, stays inline
    [[ "${2:-}" != force ]] && jq -e --arg u "$auser" '.authenticationMethod=="forms" and .username==$u' <<<"$cur" >/dev/null 2>&1 && match=yes
    body=$(jq -c --arg u "$auser" --arg p "$apass" \
        '.authenticationMethod="forms" | .authenticationRequired="enabled"
         | .username=$u | .password=$p | .passwordConfirmation=$p' <<<"$cur")
    ensure_resource "$match" "$s: $verb forms login for '$auser'" \
        "$s: forms login already set for '$auser'" "$s: auth setup rejected by the API — set it once in its UI; check: logs $s" \
        -- api PUT "$url/api/$(arr_apiver "$s")/config/host" "$key" "$body"
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

# container "running" is not API "ready" — after a cold restart the arrs
# answer errors for a few seconds. Poll each instance before touching it.
arr_api_ready() { # arr_api_ready <svc> <shared-deadline-epoch> -> 0 ready
    local key; key=$(arr_key "$1")
    [[ -n "$key" ]] || { wfail "$1: no API key readable from its config — is it initialised? (./mediastack.sh wire arr)"; return 1; }
    http_ready --until "$2" "$1" "$(arr_url "$1")/api/$(arr_apiver "$1")/system/status" '^200$' -H "X-Api-Key: $key"
}
wire_arrs_ready() { # every arr-family API answering before a role reads or writes it
    # `up` runs roles right after recreating the VPN group, when the containers
    # run (wire_gate passes) but their APIs still refuse — and a refused read
    # must never look like "nothing configured". One shared budget; remembered
    # for the rest of this run.
    (( WIRE_ARRS_OK )) && return 0
    local s deadline=$(( $(date +%s) + API_WAIT )) rc=0
    for s in $(arr_instances) $(svc_enabled prowlarr && echo prowlarr); do
        arr_api_ready "$s" "$deadline" || rc=1
    done
    (( rc )) || WIRE_ARRS_OK=1
    return $rc
}
oneline() { tr -s '[:space:]' ' ' <<<"$1" | head -c 200; }   # an app's (multi-line JSON) reply, for a message

# shellcheck disable=SC2120  # type argument is optional by design
arr_instances() { # arr_instances [type] -> enabled arr services (optionally by type)
    local s t
    for s in $(svc_enabled_managed); do
        t=$(svc_label "$s" mediastack.arrtype)
        [[ -n "$t" ]] || continue
        [[ -z "${1:-}" || "$t" == "$1" ]] || continue
        echo "$s"
    done
}

# ---- qbit ----
QB_COOKIE=""
QB_LOGIN_BODY=""
qb_bind_tun0() { # requires QB_COOKIE
    [[ -n "$QB_COOKIE" ]] || { info "no qBittorrent session — interface bind skipped"; return 0; }
    local cur
    cur=$(qb_api /app/preferences | jq -r '.current_network_interface // .network_interface // empty' 2>/dev/null || true)
    if [[ "$cur" == tun0 ]]; then
        ok "transfers bound to tun0"
    elif w_would "bind qBittorrent's transfers to tun0 (VPN interface)"; then
        qb_api /app/setPreferences 'json={"current_network_interface":"tun0"}' >/dev/null || true  # read-back below is the verdict
        cur=$(qb_api /app/preferences | jq -r '.current_network_interface // .network_interface // empty' 2>/dev/null || true)
        [[ "$cur" == tun0 ]] && ok "transfers bound to tun0" \
            || wfail "interface bind did not stick (reads back '$cur') — set it in the UI: Advanced -> Network interface"
    fi
}

qb_url() { local p; p=$(svc_hostport qbittorrent) || return 1; echo "http://127.0.0.1:$p"; }
qb_login() { # rc: 0 = logged in (QB_COOKIE set), 1 = credentials rejected, 2 = unreachable
             # QB_LOGIN_BODY always carries the server's reply / curl error
    local r
    local jar r code
    jar=$(mktemp)
    if ! r=$(curl -sS -m 10 -c "$jar" -w $'\n%{http_code}' \
        --data-urlencode "username=$1" --data-urlencode "password=$2" \
        "$(qb_url)/api/v2/auth/login" 2>&1); then
        QB_LOGIN_BODY="unreachable: ${r:-<no detail>}"
        rm -f "$jar"; return 2
    fi
    code=${r##*$'\n'}
    QB_LOGIN_BODY="[HTTP ${code}] ${r%%$'\n'*}"; [[ "$QB_LOGIN_BODY" == "[HTTP ${code}] ${code}" ]] && QB_LOGIN_BODY="[HTTP ${code}] <empty body>"
    # qBittorrent >= 5.2 returns 204 on success and names the cookie
    # QBT_SID_<port>; older versions use 200 + "SID". Take name AND value
    # from the jar so we send back exactly what was issued.
    QB_COOKIE=$(awk -F'\t' '$6 ~ /(^|_)SID(_|$)|^SID$/ {print $6"="$7}' "$jar" 2>/dev/null | tail -1 || true)
    rm -f "$jar"
    [[ -n "$QB_COOKIE" ]] || return 1
}
qb_api() { # qb_api PATH [data...] (form-encoded) -> body on stdout, rc from http
    local p="$1"; shift
    local args=(); local a; for a in "$@"; do args+=(--data-urlencode "$a"); done
    local out code
    out=$(curl -sS -m 20 -b "$QB_COOKIE" "${args[@]}" -w '\n%{http_code}' \
          "$(qb_url)/api/v2$p" 2>&1) || { echo "$out"; return 1; }
    code=${out##*$'\n'}; echo "${out%$'\n'*}"
    [[ "$code" =~ ^2 ]]
}

wire_qbit() {
    hr "wire: qBittorrent"
    wire_gate qbittorrent
    # auth-free settle: any HTTP status proves the listener (000 = no socket);
    # avoids misreading a boot gap as bad credentials on re-runs
    http_ready qbittorrent "$(qb_url)/api/v2/app/webapiVersion" '^[1-9]' \
        || die "cannot wire qBittorrent without its WebUI (see above)"
    local user pass gen
    user=$(env_get QBITTORRENT_USER)
    pass=$(env_get QBITTORRENT_PASSWORD)
    if [[ -n "$user" && -n "$pass" ]] && qb_login "$user" "$pass"; then
        ok "credentials from .env work"
    elif (( WIRE_DRY )); then
        w_would "harvest qBittorrent's boot password and set permanent credentials (you pick or accept generated)" || true
        info "category preview needs credentials — computed on the real run"
        return 0
    else
        # No stored credentials: don't forensically read old boots' logs —
        # restart qBittorrent ourselves and watch for the password THIS
        # restart mints. Deterministic: our restart, our time window.
        local tmp="" t=0 qcn ts
        qcn=$(svc_cname qbittorrent)
        info "restarting qBittorrent to mint a fresh temporary password (~20s)..."
        ts=$(date +%s)
        sudo docker restart "$qcn" >/dev/null
        # shellcheck disable=SC2034  # the inspect cache lives in the entrypoint (CACHE RULE at c_inspect)
        INSPECT_JSON=""
        while [[ -z "$tmp" && $t -lt 90 ]]; do
            sleep 5; t=$((t+5))
            # relative window covering everything since our restart
            tmp=$(sudo docker logs --since "$(( $(date +%s) - ts + 2 ))s" "$qcn" 2>&1 \
                  | grep -oP 'temporary password .*: \K\S+' | tail -1 || true)
            [[ -n "$tmp" ]] || info "waiting for qBittorrent to boot (${t}s)..."
        done
        [[ -n "$tmp" ]] || die "qBittorrent printed no temporary password within 90s of a fresh
  restart. Either it already has a password set that isn't in .env
  (set QBITTORRENT_USER/QBITTORRENT_PASSWORD there and re-run), or it
  is failing to boot: ./mediastack.sh logs qbittorrent"
        # the password prints BEFORE the WebUI is fully ready: during warmup
        # it can be unreachable (rc2) OR answer with empty non-auth replies
        # (rc1, empty body). Retry BOTH through the window, evidence inline —
        # a real "Fails." repeated to window-end is still a clean diagnosis.
        local lrc=2 lt=0
        while (( lt < 45 )); do
            if qb_login admin "$tmp"; then lrc=0; break; else lrc=$?; fi
            info "login attempt at ${lt}s: rc=$lrc, server said: $QB_LOGIN_BODY"
            sleep 3; lt=$((lt+3))
        done
        case $lrc in
            0) ok "logged in with the freshly minted password" ;;
            2) die "qBittorrent's WebUI never became reachable on port $(svc_port qbittorrent) within 45s.
  Last state: $QB_LOGIN_BODY
  Inspect: ./mediastack.sh logs qbittorrent" ;;
            *) die "qBittorrent rejected the password it just printed — genuinely unexpected
  (restart clears auth bans, so that isn't it). Server said: $QB_LOGIN_BODY
  Inspect: ./mediastack.sh logs qbittorrent" ;;
        esac
        gen=$(head -c12 /dev/urandom | base64 | tr -d '=+/')
        explain "qBittorrent credentials" \
"Pick the permanent WebUI login. Enter accepts a generated password;
type your own to use it instead. Stored in .env (view: credentials)."
        ask QB_USER "Username" "${user:-admin}"; user="$REPLY_VAL"
        ask_secret "Password" "$gen"; pass="$REPLY_VAL"
        if w_would "set permanent qBittorrent credentials"; then
            qb_api /app/setPreferences \
                "json={\"web_ui_username\":\"$user\",\"web_ui_password\":\"$pass\"}" >/dev/null || true  # re-login below is the verdict
            env_set QBITTORRENT_USER "$user"; env_set QBITTORRENT_PASSWORD "$pass"
            sleep 2   # let the preference write settle
            local vrc=0; qb_login "$user" "$pass" || vrc=$?
            (( vrc == 0 )) \
                || die "qBittorrent did not accept the new credentials (rc=$vrc). Server said: $QB_LOGIN_BODY — inspect: logs qbittorrent"
            ok "permanent credentials set and verified"
        fi
    fi
    # bind transfers to the tunnel interface: belt on top of the killswitch —
    # even a firewall wipe inside gluetun cannot make qbit talk past tun0
    qb_bind_tun0
    # categories: one per arr instance, distinct save paths = hardlink discipline
    [[ -n "$QB_COOKIE" ]] || { info "no qBittorrent session — categories skipped"; return 0; }
    local existing s cat cexists
    existing=$(qb_api /torrents/categories || true)
    for s in $(arr_instances); do
        cat=$(svc_label "$s" mediastack.category)
        cexists=no; grep -q "\"$cat\"" <<<"$existing" && cexists=yes
        ensure_resource "$cexists" "create category '$cat' -> /data/torrent/$cat" \
            "category '$cat' exists" "category '$cat' creation failed" \
            -- qb_api /torrents/createCategory "category=$cat" "savePath=/data/torrent/$cat"
    done
    # manual grabs from prowlarr get their own bucket
    cexists=no; grep -q '"prowlarr"' <<<"$existing" && cexists=yes
    ensure_resource "$cexists" "create category 'prowlarr' -> /data/torrent/prowlarr (manual grabs)" \
        "category 'prowlarr' exists" "category 'prowlarr' creation failed" \
        -- qb_api /torrents/createCategory "category=prowlarr" "savePath=/data/torrent/prowlarr"
}

# ---- arr root folders + download client ----
wire_arr() {
    hr "wire: arr instances (root folders + download client + recycle bin)"
    local insts; insts=$(arr_instances)
    [[ -n "$insts" ]] || { info "no arr instances enabled"; return 0; }
    wire_gate $insts
    wire_arrs_ready || true
    local recycle_ok=1   # the bin's placement is checked once, before any arr
    if recycle_on; then recycle_prepare || recycle_ok=0; fi
    # --- arr login (the first-run "authentication required" gate) ---
    local auser apass
    auser=$(env_get ARR_USER); apass=$(env_get ARR_PASSWORD)
    if [[ -z "$auser" || -z "$apass" ]]; then
        if (( WIRE_DRY )); then
            w_would "set one shared login on every arr instance (the first-run auth gate)" || true
        else
            explain "Arr login" \
"The arrs refuse to serve their UI until an authentication method and
login are set. One login is used for ALL instances (they share one
operator). Stored in .env (view: credentials)."
            ask ARR_U "Username" "${auser:-admin}"; auser="$REPLY_VAL"
            ask_secret "Password" "$(head -c12 /dev/urandom | base64 | tr -d '=+/')"; apass="$REPLY_VAL"
            env_set ARR_USER "$auser"; env_set ARR_PASSWORD "$apass"
        fi
    fi
    local user pass; user=$(env_get QBITTORRENT_USER); pass=$(env_get QBITTORRENT_PASSWORD)
    if [[ -z "$pass" ]]; then
        if (( WIRE_DRY )); then
            info "download-client previews pend on qBittorrent credentials — they're created earlier in the same real run"
        else
            warn "qBittorrent credentials not set (scoped run?) — download-client wiring skipped; 'wire qbit' or a full 'wire' sets them"
        fi
    fi
    local s key url root t catfield cat cur
    for s in $insts; do
        key=$(arr_key "$s")
        [[ -n "$key" ]] || { wfail "$s: no ApiKey in config.xml yet (still initialising?) — re-run wire in a minute"; continue; }
        url=$(arr_url "$s"); root=$(svc_label "$s" mediastack.rootfolder)
        # authentication — its own forms login, or trusting the portal (gate_trusted)
        arr_login "$s"
        arr_instance_name "$s"
        (( recycle_ok )) && arr_recycle "$s" "$url" "$key"
        # root folder
        t=$(svc_label "$s" mediastack.arrtype)
        cur=$(api GET "$url/api/$(arr_apiver "$s")/rootfolder" "$key") \
            || { wfail "$s: could not read its root folders — nothing created [$(oneline "$cur")]"; continue; }
        local rexists=no; grep -q "\"path\":\"$root\"" <<<"${cur//[[:space:]]/}" && rexists=yes
        local rbody
        if [[ "$t" == lidarr ]]; then
            # lidarr root folders carry library defaults (unlike sonarr/radarr);
            # profile IDs 1 = the built-in Standard profiles on a fresh install
            rbody="{\"name\":\"Music\",\"path\":\"$root\",\"defaultMetadataProfileId\":1,\"defaultQualityProfileId\":1,\"defaultMonitorOption\":\"all\",\"defaultTags\":[]}"
        else
            rbody="{\"path\":\"$root\"}"
        fi
        ensure_resource "$rexists" "$s: register root folder $root" \
            "$s: root folder $root registered" "$s: root folder rejected" \
            -- api POST "$url/api/$(arr_apiver "$s")/rootfolder" "$key" "$rbody"
        # download client
        [[ -n "$pass" ]] || continue
        cat=$(svc_label "$s" mediastack.category)
        catfield=$(arr_meta "$t" catfield)
        cur=$(api GET "$url/api/$(arr_apiver "$s")/downloadclient" "$key") \
            || { wfail "$s: could not read its download clients — nothing created [$(oneline "$cur")]"; continue; }
        local dexists=no; grep -q '"qBittorrent (mediastack)"' <<<"$cur" && dexists=yes
        local dbody; dbody=$(cat <<JSON
{"enable":true,"protocol":"torrent","priority":1,
 "removeCompletedDownloads":true,"removeFailedDownloads":true,
 "name":"qBittorrent (mediastack)","implementation":"QBittorrent",
 "implementationName":"qBittorrent","configContract":"QBittorrentSettings",
 "fields":[{"name":"host","value":"$(svc_host qbittorrent)"},
   {"name":"port","value":$(svc_cport qbittorrent)},
   {"name":"useSsl","value":false},
   {"name":"username","value":"$user"},{"name":"password","value":"$pass"},
   {"name":"$catfield","value":"$cat"}]}
JSON
)
        if [[ "$dexists" == yes ]]; then
            local dst; dst="$(arr_entry_field "$cur" "qBittorrent (mediastack)" host):$(arr_entry_field "$cur" "qBittorrent (mediastack)" port)"
            if addr_stale "$s -> qbittorrent" qbittorrent "$dst"; then
                local -a login; mapfile -t login < <(qbit_login_fields "$cur" "qBittorrent (mediastack)")
                addr_repoint "$s -> qbittorrent" "$dst" "$(svc_addr qbittorrent)" -- \
                    arr_repoint "$url/api/$(arr_apiver "$s")" "$key" downloadclient "$cur" "qBittorrent (mediastack)" \
                    "host=$(svc_host qbittorrent)" "port=$(svc_cport qbittorrent)" "${login[@]}"
            fi
        fi
        ensure_resource "$dexists" "$s: register qBittorrent (category $cat)" \
            "$s: download client registered" "$s: download client registration failed — check: logs $s" \
            -- api POST "$url/api/$(arr_apiver "$s")/downloadclient" "$key" "$dbody"
    done
}

# ---- prowlarr: applications + flaresolverr proxy ----
prowlarr_app_repoint() { # <target> <entry name> <applications JSON> <prowlarr api url> <prowlarr key>
    # an application entry holds BOTH directions; re-point only the fields that
    # are stale AND mediastack-made, so a hand-set other direction survives
    local t="$1" name="$2" cur="$3" purl="$4" pkey="$5" b pr
    local -a fields=() was=() want=()
    b=$(addr_of "$(arr_entry_field "$cur" "$name" baseUrl)")
    pr=$(addr_of "$(arr_entry_field "$cur" "$name" prowlarrUrl)")
    if addr_stale "prowlarr -> $t" "$t" "$b"; then
        fields+=("baseUrl=http://$(svc_addr "$t")"); was+=("$b"); want+=("$(svc_addr "$t")")
    fi
    if addr_stale "$t -> prowlarr" prowlarr "$pr"; then
        fields+=("prowlarrUrl=http://$(svc_addr prowlarr)"); was+=("$pr"); want+=("$(svc_addr prowlarr)")
    fi
    (( ${#fields[@]} )) || return 0
    addr_repoint "prowlarr <-> $t" "${was[*]}" "${want[*]}" -- \
        arr_repoint "$purl/api/v1" "$pkey" applications "$cur" "$name" "${fields[@]}"
}
prowlarr_download_client() { # manual grabs in prowlarr's UI go straight to qbit
    local key url ver have qu qp schema tmpl body resp
    key=$(arr_key prowlarr); url=$(arr_url prowlarr); ver=$(arr_apiver prowlarr)
    [[ -n "$key" ]] || { wfail "prowlarr: no ApiKey readable — re-run wire in a minute"; return 1; }
    qu=$(env_get QBITTORRENT_USER); qp=$(env_get QBITTORRENT_PASSWORD)
    [[ -n "$qu" && -n "$qp" ]] || { info "prowlarr download client pends on 'wire qbit' storing credentials"; return 0; }
    local dcs; dcs=$(api GET "$url/api/$ver/downloadclient" "$key") \
        || { wfail "prowlarr: could not read its download clients — nothing created [$(oneline "$dcs")]"; return 1; }
    have=$(jq -r '[.[].name] | join(" ")' <<<"$dcs" 2>/dev/null || true)
    if [[ " $have " == *" qbittorrent "* ]]; then
        ok "prowlarr download client registered"
        local dst; dst="$(arr_entry_field "$dcs" qbittorrent host):$(arr_entry_field "$dcs" qbittorrent port)"
        if addr_stale "prowlarr -> qbittorrent" qbittorrent "$dst"; then
            local -a login; mapfile -t login < <(qbit_login_fields "$dcs" qbittorrent)
            addr_repoint "prowlarr -> qbittorrent" "$dst" "$(svc_addr qbittorrent)" -- \
                arr_repoint "$url/api/$ver" "$key" downloadclient "$dcs" qbittorrent \
                "host=$(svc_host qbittorrent)" "port=$(svc_cport qbittorrent)" "${login[@]}"
        fi
        return 0
    fi
    w_would "prowlarr: register qBittorrent as its download client (manual grabs -> category 'prowlarr')" || return 0
    schema=$(api GET "$url/api/$ver/downloadclient/schema" "$key" || true)   # soft read: create path only: an empty schema FAILs below, nothing created
    tmpl=$(jq -c '[.[] | select(.implementation=="QBittorrent")][0] // empty' <<<"$schema" 2>/dev/null)
    [[ -n "$tmpl" ]] || { wfail "prowlarr: its API offers no QBittorrent client type — is the image very old?"; return 1; }
    body=$(jq -c --arg u "$qu" --arg p "$qp" --arg host "$(svc_host qbittorrent)" --argjson port "$(svc_cport qbittorrent)" '
        .name = "qbittorrent" | .enable = true
        | .fields = [ .fields[]
            | if   .name == "host"     then .value = $host
              elif .name == "port"     then .value = $port
              elif .name == "username" then .value = $u
              elif .name == "password" then .value = $p
              elif .name == "category" then .value = "prowlarr"
              else . end ]' <<<"$tmpl")
    resp=$(api POST "$url/api/$ver/downloadclient" "$key" "$body") \
        && ok "prowlarr download client registered" \
        || wfail "prowlarr: download client rejected: $(head -c200 <<<"$resp")"
}

ll_url() { local p; p=$(svc_hostport lazylibrarian) || return 1; echo "http://127.0.0.1:$p"; }
ll_key() { # LazyLibrarian mints its API key on first run into config.ini
    local f
    f="$(env_get CONFIG_ROOT)/lazylibrarian/config.ini"
    [[ -r "$f" ]] || { sudo cat "$f" 2>/dev/null | sed -n 's/^api_key = *//p' | head -1; return; }
    sed -n 's/^api_key = *//p' "$f" | head -1
}
ll_api() { # ll_api cmd [k=v ...] -> body; the &cmd= API, apikey-authenticated
    local cmd="$1"; shift
    local q kv
    q="apikey=$(ll_key)&cmd=$cmd"
    for kv in "$@"; do q+="&$kv"; done
    curl -sS -m 15 "$(ll_url)/api?$q" 2>/dev/null
}

wire_lazylibrarian() {
    hr "wire: LazyLibrarian"
    svc_enabled lazylibrarian || { info "lazylibrarian not enabled — skipped"; return 0; }
    wire_gate lazylibrarian
    http_ready lazylibrarian "$(ll_url)/" '^([23][0-9][0-9]|401|403)$' || return 1
    local key; key=$(ll_key)
    if [[ -z "$key" ]]; then
        # first-ever start: the API key is minted only after the web UI has
        # been opened once and config saved. Cannot proceed headless.
        wfail "lazylibrarian has no API key yet — open https://books-dl.\$TRAEFIK_DOMAIN once,
     go to Config -> Interface, set a username/password and Save, restart it
     in the UI, then re-run: ./mediastack.sh wire lazylibrarian"
        return 1
    fi
    ok "API key found"

    # download client: qBittorrent, at its app-to-app address (svc_addr)
    (( WIRE_DRY )) && { w_would "point lazylibrarian at qBittorrent and set its book folder" || true; }
    if ! (( WIRE_DRY )); then
        local qu qp
        qu=$(env_get QBITTORRENT_USER); qp=$(env_get QBITTORRENT_PASSWORD)
        if [[ -z "$qu" || -z "$qp" ]]; then
            wfail "no qBittorrent credentials in .env — run 'wire qbit' first"
        else
            # LazyLibrarian's qBittorrent settings live in [QBITTORRENT]
            ll_api writeCFG "name=HOST&group=QBITTORRENT&value=http://$(svc_host qbittorrent)" >/dev/null
            ll_api writeCFG "name=PORT&group=QBITTORRENT&value=$(svc_cport qbittorrent)" >/dev/null
            ll_api writeCFG "name=USER&group=QBITTORRENT&value=$qu" >/dev/null
            ll_api writeCFG "name=PASS&group=QBITTORRENT&value=$qp" >/dev/null
            ll_api writeCFG "name=LABEL&group=QBITTORRENT&value=prowlarr" >/dev/null
            ll_api writeCFG "name=TOR_DOWNLOADER&group=General&value=qbittorrent" >/dev/null
            ok "qBittorrent set as download client"
            # book destination on the shared media tree
            ll_api writeCFG "name=EBOOK_DEST_FOLDER&group=General&value=/data/media/books" >/dev/null
            ll_api writeCFG "name=AUDIO_DEST_FOLDER&group=General&value=/data/media/audiobooks" >/dev/null
            ll_api writeCFG "name=DESTINATION_DIR&group=General&value=/data/media/books" >/dev/null
            ok "book folders set (/data/media/books, /data/media/audiobooks)"
            ll_api loadCFG >/dev/null
            ok "config reloaded"
        fi
    fi
    info "indexers arrive automatically from Prowlarr (registered in the prowlarr pass)"
}

wire_prowlarr() {
    hr "wire: Prowlarr"
    svc_enabled prowlarr || { info "prowlarr not enabled — skipped"; return 0; }
    wire_gate prowlarr
    wire_arrs_ready || true
    local pkey purl; pkey=$(arr_key prowlarr); purl=$(arr_url prowlarr)
    [[ -n "$pkey" ]] || { wfail "prowlarr: no ApiKey yet — re-run wire shortly"; return 0; }
    # prowlarr has no arrtype label so wire_arr's loop never sees it: its login
    # here — its own, or trusting the portal (gate_trusted), like the arrs
    arr_login prowlarr
    local s key t impl cur aexists abody
    cur=$(api GET "$purl/api/v1/applications" "$pkey") \
        || { wfail "prowlarr: could not read its apps — nothing created [$(oneline "$cur")]"; return 1; }
    for s in $(arr_instances); do
        t=$(svc_label "$s" mediastack.arrtype)
        arr_known "$t" || continue
        impl=$(arr_meta "$t" impl)
        key=$(arr_key "$s") || true
        [[ -n "$key" ]] || { wfail "prowlarr<-$s: $s has no ApiKey yet"; continue; }
        aexists=no; grep -q "\"$s (mediastack)\"" <<<"$cur" && aexists=yes
        if [[ "$aexists" == yes ]]; then
            prowlarr_app_repoint "$s" "$s (mediastack)" "$cur" "$purl" "$pkey"
        fi
        abody=$(cat <<JSON
{"name":"$s (mediastack)","syncLevel":"fullSync",
 "implementation":"$impl","configContract":"${impl}Settings",
 "fields":[{"name":"prowlarrUrl","value":"http://$(svc_addr prowlarr)"},
   {"name":"baseUrl","value":"http://$(svc_addr "$s")"},
   {"name":"apiKey","value":"$key"}]}
JSON
)
        ensure_resource "$aexists" "register $s in prowlarr (Full Sync)" \
            "prowlarr -> $s registered" "prowlarr -> $s failed — check: logs prowlarr" \
            -- api POST "$purl/api/v1/applications" "$pkey" "$abody"
    done
    # LazyLibrarian is a first-class Prowlarr app — register it so its book
    # indexers sync exactly like the arrs (needs its API key from config.ini)
    if svc_enabled lazylibrarian; then
        local llkey
        llkey=$(ll_key)
        if [[ -z "$llkey" ]]; then
            info "prowlarr -> lazylibrarian: skipped (no API key yet — run 'wire lazylibrarian' first)"
        else
            aexists=no; grep -q '"LazyLibrarian (mediastack)"' <<<"$cur" && aexists=yes
            if [[ "$aexists" == yes ]]; then
                prowlarr_app_repoint lazylibrarian "LazyLibrarian (mediastack)" "$cur" "$purl" "$pkey"
            fi
            abody=$(cat <<JSON
{"name":"LazyLibrarian (mediastack)","syncLevel":"fullSync",
 "implementation":"LazyLibrarian","configContract":"LazyLibrarianSettings",
 "fields":[{"name":"prowlarrUrl","value":"http://$(svc_addr prowlarr)"},
   {"name":"baseUrl","value":"http://$(svc_addr lazylibrarian)"},
   {"name":"apiKey","value":"$llkey"}]}
JSON
)
            ensure_resource "$aexists" "register lazylibrarian in prowlarr (Full Sync)" \
                "prowlarr -> lazylibrarian registered" "prowlarr -> lazylibrarian failed — check: logs prowlarr" \
                -- api POST "$purl/api/v1/applications" "$pkey" "$abody"
        fi
    fi
    if svc_enabled flaresolverr; then
        # tag 'flared': put it on any indexer that needs FlareSolverr and
        # prowlarr routes that indexer through the proxy. Nothing carries it
        # by default — only Cloudflare-protected indexers should pay the tax.
        local fid
        local tags; tags=$(api GET "$purl/api/v1/tag" "$pkey") \
            || { wfail "prowlarr: could not read its tags — flaresolverr not set up [$(oneline "$tags")]"; prowlarr_download_client; return 1; }
        fid=$(jq -r '.[] | select(.label=="flared") | .id' <<<"$tags" 2>/dev/null | head -1)
        if [[ -n "$fid" ]]; then
            ok "tag 'flared' exists"
        elif w_would "create prowlarr tag 'flared' (attach to indexers needing FlareSolverr)"; then
            fid=$(api POST "$purl/api/v1/tag" "$pkey" '{"label":"flared"}' | jq -r '.id' 2>/dev/null || true)
            [[ -n "$fid" && "$fid" != null ]] && ok "tag 'flared' created" \
                || { wfail "prowlarr tag 'flared' creation failed — check: logs prowlarr"; fid=""; }
        fi
        if ! cur=$(api GET "$purl/api/v1/indexerproxy" "$pkey"); then
            wfail "prowlarr: could not read its indexer proxies — nothing created [$(oneline "$cur")]"
        elif grep -q '"FlareSolverr (mediastack)"' <<<"$cur"; then
            if [[ -n "$fid" ]] && jq -e --argjson id "$fid" \
                    '.[] | select(.name=="FlareSolverr (mediastack)") | .tags | index($id) | not' \
                    <<<"$cur" >/dev/null 2>&1; then
                if w_would "attach tag 'flared' to the FlareSolverr proxy"; then
                    local fbody
                    fbody=$(jq -c --argjson id "$fid" \
                        '[.[] | select(.name=="FlareSolverr (mediastack)")][0] | .tags += [$id]' <<<"$cur")
                    api PUT "$purl/api/v1/indexerproxy/$(jq -r '.id' <<<"$fbody")" "$pkey" "$fbody" >/dev/null \
                        && ok "flaresolverr proxy tagged 'flared'" \
                        || wfail "could not tag the flaresolverr proxy — check: logs prowlarr"
                fi
            else
                ok "flaresolverr proxy registered"
            fi
            local fst; fst=$(addr_of "$(arr_entry_field "$cur" "FlareSolverr (mediastack)" host)")
            if addr_stale "prowlarr -> flaresolverr" flaresolverr "$fst"; then
                addr_repoint "prowlarr -> flaresolverr" "$fst" "$(svc_addr flaresolverr)" -- \
                    arr_repoint "$purl/api/v1" "$pkey" indexerproxy "$cur" "FlareSolverr (mediastack)" \
                    "host=http://$(svc_addr flaresolverr)/"
            fi
        elif w_would "register FlareSolverr as indexer proxy"; then
            api POST "$purl/api/v1/indexerproxy" "$pkey" "$(cat <<JSON
{"name":"FlareSolverr (mediastack)","implementation":"FlareSolverr",
 "configContract":"FlareSolverrSettings","tags":[${fid:-}],
 "fields":[{"name":"host","value":"http://$(svc_addr flaresolverr)/"},
   {"name":"requestTimeout","value":60}]}
JSON
)" >/dev/null && ok "flaresolverr proxy registered (tag 'flared')" \
              || wfail "flaresolverr proxy registration failed"
        fi
    fi
    prowlarr_download_client
}

# ---- bazarr ----
wire_bazarr() {
    hr "wire: Bazarr"
    svc_enabled bazarr || { info "bazarr not enabled — skipped"; return 0; }
    wire_gate bazarr
    local bkey burl
    bkey=$(bazarr_key)
    [[ -n "$bkey" ]] || { wfail "bazarr: no api key found yet (config/config.yaml) — re-run wire shortly"; return 0; }
    burl=$(arr_url bazarr)
    # readiness gate: on a virgin install bazarr is still migrating its DB when
    # wire reaches it and resets the connection (HTTP 000). Poll before posting.
    if (( ! WIRE_DRY )); then
        local waited=0 bprobe
        until bprobe=$(curl -sS -m 5 -o /dev/null -w '%{http_code}' \
                -H "X-API-KEY: $bkey" "$burl/api/system/status" 2>&1) \
                && [[ "$bprobe" == 200 ]]; do
            if (( waited >= 90 )); then
                wfail "bazarr not ready after ${waited}s (last probe: $(head -c120 <<<"$bprobe")) — re-run wire once it settles; check: logs bazarr"
                return 0
            fi
            (( waited == 0 )) && info "waiting for bazarr to come up (budget 90s)..."
            sleep 3; waited=$((waited+3))
        done
    fi
    local pairs=() t skey
    for t in sonarr radarr; do
        svc_enabled "$t" || continue
        skey=$(arr_key "$t"); [[ -n "$skey" ]] || continue
        pairs+=("$t" "$skey")
    done
    (( ${#pairs[@]} )) || { info "no base sonarr/radarr to pair — skipped"; return 0; }
    if w_would "point bazarr at base sonarr/radarr (extra instances are out of bazarr's scope)"; then
        # auth fields exactly ONCE — duplicate form keys become lists on
        # bazarr's side and fail its type validation
        local form=("settings-auth-type=form"
                    "settings-auth-username=$(env_get ARR_USER)"
                    "settings-auth-password=$(env_get ARR_PASSWORD)") i
        for ((i=0; i<${#pairs[@]}; i+=2)); do
            t=${pairs[i]}; skey=${pairs[i+1]}
            form+=("settings-general-use_${t}=true"
                   "settings-${t}-ip=$(svc_host "$t")"
                   "settings-${t}-port=$(svc_cport "$t")"
                   "settings-${t}-base_url=/"
                   "settings-${t}-ssl=false"
                   "settings-${t}-apikey=${skey}")
        done
        local args=() a
        for a in "${form[@]}"; do args+=(--data-urlencode "$a"); done
        local bresp bcode
        bresp=$(curl -sS -m 20 -w $'\n%{http_code}' -X POST -H "X-API-KEY: $bkey" \
                "${args[@]}" "$burl/api/system/settings" 2>&1) || bresp="${bresp}"$'\n000'
        bcode=${bresp##*$'\n'}
        if [[ "$bcode" =~ ^2 ]]; then
            ok "bazarr paired with base sonarr/radarr (+ shared login)"
        else
            wfail "bazarr pairing rejected [HTTP $bcode]: $(head -c200 <<<"${bresp%$'\n'*}")
     pair manually meanwhile (Settings -> Sonarr/Radarr) and paste the above"
        fi
    fi
}

JF_LDAP_GUID=958aad66-3784-4d2a-b89a-a7b6fab6e25c           # "LDAP Authentication" (jellyfin/jellyfin-plugin-ldapauth)
JF_LDAP_PROVIDER=Jellyfin.Plugin.LDAP_Auth.LdapAuthenticationProviderPlugin   # AuthenticationProviderId of users it created

jf_plugin_ids() { # jf_plugin_ids PLUGINS-JSON -> "|id|id|" (dashes removed, lower case)
    # by ID, not name: a plugin can load under another name than its catalog
    # entry (found live: "LDAP Authentication" loads as "LDAP-Auth")
    jq -r '"|" + ([.[].Id | ascii_downcase | gsub("-"; "")] | join("|")) + "|"' <<<"$1" 2>/dev/null
}
jf_guid() { tr -d '-' <<<"$1" | tr '[:upper:]' '[:lower:]'; }

jf_plugins_ensure() { # jf_plugins_ensure TOKEN "Name|GUID|why"... — install what is missing, then ONE jellyfin restart
    local tok="$1"; shift
    local plist plugins spec name guid why missing=() mguids=()
    plist=$(jf_api GET /Plugins "$tok") \
        || { wfail "could not list jellyfin plugins [HTTP $(jf_code)] — nothing installed, jellyfin not restarted"; return 1; }
    plugins=$(jf_plugin_ids "$plist")
    for spec in "$@"; do
        IFS='|' read -r name guid why <<<"$spec"
        if [[ "$plugins" == *"|$(jf_guid "$guid")|"* ]]; then ok "$name plugin installed"; continue; fi
        w_would "install Jellyfin's $name plugin ($why)" || continue
        jf_api POST "/Packages/Installed/$(jq -rn --arg n "$name" '$n|@uri')?assemblyGuid=$guid" "$tok" >/dev/null \
            || { wfail "$name plugin install rejected [HTTP $(jf_code)] — install it in Dashboard -> Plugins -> Catalog"; return 1; }
        missing+=("$name"); mguids+=("$guid")
    done
    (( ${#missing[@]} )) || return 0
    info "plugin(s) downloaded (${missing[*]}) — restarting jellyfin once to load them..."
    is_user_facing jellyfin && notify_interruption "Jellyfin maintenance" "Jellyfin is restarting briefly for maintenance — back in a moment."
    DC restart jellyfin >/dev/null 2>&1 || { wfail "jellyfin restart failed — restart it, then re-run wire jellyfin"; return 1; }
    jf_ready || return 1
    plist=$(jf_api GET /Plugins "$tok" || true)   # soft read: re-check after the install: empty FAILs below
    plugins=$(jf_plugin_ids "$plist")
    local i rc=0
    for i in "${!missing[@]}"; do
        if [[ "$plugins" == *"|$(jf_guid "${mguids[$i]}")|"* ]]; then ok "${missing[$i]} plugin installed and loaded"
        else wfail "${missing[$i]} plugin not visible after restart — check Dashboard -> Plugins (a repository fetch may have failed)"; rc=1; fi
    done
    return $rc
}

jf_plugin_webhook() { # its consumer is WatchState (the hub hears Seerr, not Jellyfin)
    jf_plugins_ensure "$1" "Webhook|71552A5A-5C5C-4350-A2AE-EBE451A30173|WatchState's webhooks need it"
}

jf_ldap_want() { # the LDAP plugin's settings mediastack manages, as JSON (the rest stay yours)
    local dn=dc=ldap,dc=mediastack host skip=false
    host="$(env_get AUTHENTIK_LDAP_HOST ldap).$(env_get TRAEFIK_DOMAIN)"
    # a staging certificate is not trusted inside Jellyfin: checking waits for production ones
    [[ "$(env_get ACME_ENV production)" == production ]] || skip=true
    jq -cn --arg host "$host" --arg dn "$dn" --arg pw "$(env_get AUTHENTIK_LDAP_BIND_PASSWORD)" --argjson skip "$skip" '{
        LdapServer: $host, LdapPort: 443, UseSsl: true, UseStartTls: false, SkipSslVerify: $skip,
        LdapBindUser: ("cn=mediastack-ldap-search,ou=users," + $dn), LdapBindPassword: $pw,
        LdapBaseDn: $dn, LdapAdminBaseDn: $dn,
        LdapSearchFilter: ("(|(memberOf=cn=media-users,ou=groups," + $dn + ")(memberOf=cn=admins,ou=groups," + $dn + "))"),
        LdapAdminFilter: ("(memberOf=cn=admins,ou=groups," + $dn + ")"),
        LdapSearchAttributes: "uid, cn, mail, displayName", LdapUidAttribute: "uid", LdapUsernameAttribute: "cn",
        CreateUsersFromLdap: true, EnableAllFolders: true, AllowPassChange: false }'
}

jf_ldap_configure() { # point the LDAP plugin at authentik's outpost — only the settings mediastack manages
    local tok="$1" cur want merged
    cur=$(jf_api GET "/Plugins/$JF_LDAP_GUID/Configuration" "$tok") \
        || { wfail "could not read the LDAP plugin's settings [HTTP $(jf_code)]"; return 1; }
    want=$(jf_ldap_want)
    if jq -e --argjson w "$want" '. as $c | $w | to_entries | all(.value == $c[.key])' <<<"$cur" >/dev/null 2>&1; then
        ok "LDAP plugin points at the portal ($(jq -r '.LdapServer' <<<"$want"), certificate checking $( [[ "$(jq -r '.SkipSslVerify' <<<"$want")" == true ]] && echo "off until production certificates" || echo on))"
        return 0
    fi
    w_would "point Jellyfin's LDAP plugin at the portal: $(jq -r '.LdapServer' <<<"$want"):443 (LDAPS), media-users and admins may sign in, new users get every library" || return 0
    merged=$(jq -c --argjson w "$want" '. + $w' <<<"$cur")
    jf_api POST "/Plugins/$JF_LDAP_GUID/Configuration" "$tok" "$merged" >/dev/null \
        && ok "LDAP plugin configured — portal accounts sign in to Jellyfin (created on their first sign-in)" \
        || wfail "Jellyfin rejected the LDAP plugin's settings [HTTP $(jf_code)]"
}

jf_admin_sync() { # directory users in authentik's `admins` are Jellyfin administrators; other directory users are not
    # (the plugin sets this only when it creates a user). Local accounts — the
    # stack's own admin above all — are never touched.
    local tok="$1" out admins users u name id pol want
    out=$(ak_api GET "/core/users/?groups_by_name=admins&page_size=500") || { wfail "authentik: admins unreadable — Jellyfin admin rights not synced"; return 1; }
    admins=" $(jq -r '[.results[].username] | join(" ")' <<<"$out") "
    users=$(jf_api GET /Users "$tok") || { wfail "could not list jellyfin users [HTTP $(jf_code)]"; return 1; }
    while IFS= read -r u; do
        [[ -n "$u" ]] || continue
        name=$(jq -r '.Name' <<<"$u"); id=$(jq -r '.Id' <<<"$u")
        want=false; [[ "$admins" == *" $name "* ]] && want=true
        [[ "$(jq -r '.Policy.IsAdministrator' <<<"$u")" == "$want" ]] && continue
        w_would "Jellyfin: $name $( [[ $want == true ]] && echo "becomes an administrator (in admins)" || echo "is no longer an administrator (not in admins)")" || continue
        pol=$(jq -c --argjson w "$want" '.Policy | .IsAdministrator = $w' <<<"$u")
        jf_api POST "/Users/$id/Policy" "$tok" "$pol" >/dev/null && ok "Jellyfin: $name administrator = $want" \
            || wfail "Jellyfin rejected $name's admin change [HTTP $(jf_code)]"
    done < <(jq -c --arg p "$JF_LDAP_PROVIDER" '.[] | select(.Policy.AuthenticationProviderId == $p)' <<<"$users")
    return 0
}

jf_ldap() { # with the portal: Jellyfin checks passwords against it (LDAP), admin rights follow `admins`
    local tok="$1"
    svc_enabled authentik || return 0
    [[ -n "$(env_get AUTHENTIK_LDAP_TOKEN)" ]] || { info "the portal's LDAP outpost has no token yet — run 'wire authentik' first, then 'wire jellyfin'"; return 0; }
    jf_plugins_ensure "$tok" "LDAP Authentication|$JF_LDAP_GUID|portal accounts sign in to Jellyfin" || return 1
    (( WIRE_DRY )) && ! jf_api GET "/Plugins/$JF_LDAP_GUID/Configuration" "$tok" >/dev/null && return 0   # not installed yet: nothing to compare
    jf_ldap_configure "$tok" || return 1
    jf_admin_sync "$tok"
}

jf_server_name() { # the name apps/casting show; container default is the ID hash
    local tok="$1" cfg have want
    cfg=$(jf_api GET /System/Configuration "$tok" || true)   # soft read: a failed read shows as a change; the write that follows fails loud
    have=$(jq -r '.ServerName // empty' <<<"$cfg" 2>/dev/null)
    if [[ -n "$have" && ! "$have" =~ ^[0-9a-f]{12}$ ]]; then
        ok "server name '$have'"
        return 0
    fi
    if (( WIRE_DRY )); then w_would "name the Jellyfin server (asked on the real run)" || true; return 0; fi
    [[ -t 0 ]] || { info "server name still the container ID — run 'wire jellyfin' interactively to set it"; return 0; }
    ask JF_SRVNAME "Server name (shows in Jellyfin apps and casting)" "Jellyfin"
    want="$REPLY_VAL"
    jf_api POST /System/Configuration "$tok" "$(jq -c --arg n "$want" '.ServerName=$n' <<<"$cfg")" >/dev/null \
        && ok "server name set to '$want'" \
        || wfail "Jellyfin rejected the server name [HTTP $(jf_code)] — set it in Dashboard -> General"
}

JF_TRANSCODE_PATH=/cache/transcodes   # inside the container; ${TRANSCODE_ROOT}/jellyfin on the host
jf_transcode_path() { # transcodes belong on the cache volume, not in /config
    # Jellyfin's default is <data>/transcodes = /config/data/transcodes: the
    # config volume, which backup archives and which sits wherever CONFIG_ROOT
    # does. Segments are written at source bitrate for the whole session.
    local tok="$1" cfg have
    cfg=$(jf_api GET /System/Configuration/encoding "$tok" || true)   # soft read: a failed read shows as a change; the write that follows fails loud
    [[ "$(jf_code)" =~ ^2 ]] || { wfail "could not read jellyfin's encoding settings [HTTP $(jf_code)]: $(head -c200 <<<"$cfg")"; return 1; }
    have=$(jq -r '.TranscodingTempPath // empty' <<<"$cfg" 2>/dev/null)
    if [[ "$have" == "$JF_TRANSCODE_PATH" ]]; then ok "transcodes go to $JF_TRANSCODE_PATH (the cache volume)"; return 0; fi
    w_would "point jellyfin's transcodes at $JF_TRANSCODE_PATH (now: ${have:-the default, /config/data/transcodes})" || return 0
    jf_api POST /System/Configuration/encoding "$tok" "$(jq -c --arg p "$JF_TRANSCODE_PATH" '.TranscodingTempPath=$p' <<<"$cfg")" >/dev/null \
        && ok "transcodes now go to $JF_TRANSCODE_PATH" \
        || wfail "Jellyfin rejected the transcode path [HTTP $(jf_code)] — set Dashboard -> Playback -> Transcoding -> Transcode path to $JF_TRANSCODE_PATH"
}

# ---- apprise: the notification hub (sending, routing, `notify`: lib/notify.sh) ----
wire_apprise() {
    hr "wire: apprise"
    svc_enabled apprise || { info "apprise not enabled — skipped"; return 0; }
    wire_gate apprise
    http_ready apprise "$(apprise_url)/status" '^2' || return 1
    wire_arrs_ready || true

    # --- notification endpoints: stored once under key 'mediastack';
    # an existing config is never touched (edit in apprise's UI or re-add)
    code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -X POST "$(apprise_url)/get/mediastack" 2>/dev/null || echo 000)
    if [[ "$code" == 200 ]]; then
        # the URLs are yours (notify set / Apprise's UI); only the event tags on
        # the lines mediastack wrote are kept current, so Seerr's events route
        local cur want
        cur=$(notify_cfg_get); want=$(notify_cfg_edit retag <<<"$cur")
        local t; while IFS= read -r t; do warn "$(notify_legacy_note "$t")"; done < <(notify_legacy_lines <<<"$cur")
        if [[ "$cur" == "$want" ]]; then
            ok "notification endpoints configured, routing current (manage: ./mediastack.sh notify)"
        elif w_would "tag the streams' URLs with the Seerr events each receives (${NOTIFY_EVENTS[users]// /, } -> users, the rest -> ops)"; then
            notify_cfg_put "$want"
            ok "notification routing updated"
        fi
    elif (( WIRE_DRY )); then
        w_would "store notification endpoints (URLs asked per tag on the real run)" || true
    elif [[ ! -t 0 ]]; then
        info "no notification endpoints stored yet — run './mediastack.sh wire apprise' interactively to add them"
    else
        explain "Notifications (Apprise)" \
"One hub, two streams — give each one or more Apprise URLs
(comma-separated), or leave blank to skip a stream:
  ops    you: errors, update pipeline, backups, doctor, requests
  users  household: new media, restarts, updates, invites
Getting a URL:
  Discord   channel -> gear -> Integrations -> Webhooks -> New Webhook
            -> Copy Webhook URL, and paste that https://... URL as-is
  ntfy      pick any unique topic name: ntfy://ntfy.sh/your-topic
            (subscribe to the topic in the ntfy app — zero signup)
  anything  else: https://github.com/caronc/apprise/wiki"
        local ops_u usr_u cfg="" u
        ask AP_OPS "URLs for ops" ""; ops_u="$REPLY_VAL"
        ask AP_USR "URLs for users" ""; usr_u="$REPLY_VAL"
        for u in ${ops_u//,/ }; do cfg+="$(notify_tagline ops)=$u"$'\n'; done
        for u in ${usr_u//,/ }; do cfg+="$(notify_tagline users)=$u"$'\n'; done
        if [[ -z "$cfg" ]]; then
            info "no URLs given — notifications stay off until 'wire apprise' stores some"
        elif w_would "store the notification endpoints under key 'mediastack'"; then
            local resp acode
            resp=$(curl -sS -m 10 -X POST -H "Content-Type: application/json" \
                   -d "$(jq -cn --arg c "$cfg" '{config:$c,format:"text"}')" \
                   -w $'\n%{http_code}' "$(apprise_url)/add/mediastack" 2>&1) \
                || { wfail "apprise unreachable while storing config: $(head -c200 <<<"$resp")"; return 1; }
            acode=${resp##*$'\n'}
            [[ "$acode" =~ ^2 ]] \
                || { wfail "apprise rejected the config [HTTP $acode]: $(head -c200 <<<"${resp%$'\n'*}")
     check the URL syntax against https://github.com/caronc/apprise/wiki"; return 1; }
            ok "notification endpoints stored"
            notify ops "Mediastack" "Notifications are wired up — this is your ops stream." info
            info "a test notification went to the ops stream — check it arrived"
        fi
    fi

    # --- each arr notifies the hub (tag: ops); create-if-missing by
    # name, schema-driven so per-type event flags stay version-proof
    local s ty key url ver have schema tmpl body resp
    for s in $(arr_instances); do
        ty=$(svc_label "$s" mediastack.arrtype)
        arr_known "$ty" || continue
        key=$(arr_key "$s"); url=$(arr_url "$s"); ver=$(arr_apiver "$s")
        [[ -n "$key" ]] || { wfail "$s: no ApiKey readable — re-run wire in a minute"; continue; }
        local notes; notes=$(api GET "$url/api/$ver/notification" "$key") \
            || { wfail "$s: could not read its notifications — nothing created [$(oneline "$notes")]"; continue; }
        have=$(jq -r '[.[].name] | join(" ")' <<<"$notes" 2>/dev/null || true)
        if [[ " $have " == *" mediastack-apprise "* ]]; then
            ok "$s already notifies the hub — untouched"
            local nst; nst=$(addr_of "$(arr_entry_field "$notes" mediastack-apprise serverUrl)")
            if addr_stale "$s -> apprise" apprise "$nst"; then
                addr_repoint "$s -> apprise" "$nst" "$(svc_addr apprise)" -- \
                    arr_repoint "$url/api/$ver" "$key" notification "$notes" mediastack-apprise "serverUrl=http://$(svc_addr apprise)"
            fi
            continue
        fi
        if ! w_would "$s: notify the hub on grab/import/health (tag: ops)"; then continue; fi
        schema=$(api GET "$url/api/$ver/notification/schema" "$key") \
            || { wfail "$s: could not read its notification types — nothing created [$(oneline "$schema")]"; continue; }
        tmpl=$(jq -c '[.[] | select(.implementation=="Apprise")][0] // empty' <<<"$schema" 2>/dev/null)
        [[ -n "$tmpl" ]] || { wfail "$s: its API offers no Apprise notification type — is the image very old?"; continue; }
        body=$(jq -c --arg srv "http://$(svc_addr apprise)" '
            .name = "mediastack-apprise"
            | .fields = [ .fields[]
                | if .name == "serverUrl"         then .value = $srv
                  elif .name == "configurationKey" then .value = "mediastack"
                  elif .name == "tags"             then .value = ["ops"]
                  else . end ]
            | reduce ("onGrab","onDownload","onUpgrade","onReleaseImport",
                      "onImportComplete","onHealthIssue","onHealthRestored",
                      "onApplicationUpdate") as $k
                (.; if has($k) then .[$k] = true else . end)' <<<"$tmpl")
        resp=$(api POST "$url/api/$ver/notification" "$key" "$body") \
            && ok "$s now notifies the hub" \
            || wfail "$s: notification connection rejected: $(head -c200 <<<"$resp")"
    done
    # prowlarr too — indexer/health events are ops signal
    if svc_enabled prowlarr; then
        key=$(arr_key prowlarr); url=$(arr_url prowlarr); ver=$(arr_apiver prowlarr)
        local pnotes=""
        if ! pnotes=$(api GET "$url/api/$ver/notification" "$key"); then
            wfail "prowlarr: could not read its notifications — nothing created [$(oneline "$pnotes")]"
        elif [[ " $(jq -r '[.[].name] | join(" ")' <<<"$pnotes" 2>/dev/null) " == *" mediastack-apprise "* ]]; then
            ok "prowlarr already notifies the hub — untouched"
            local pst; pst=$(addr_of "$(arr_entry_field "$pnotes" mediastack-apprise serverUrl)")
            if addr_stale "prowlarr -> apprise" apprise "$pst"; then
                addr_repoint "prowlarr -> apprise" "$pst" "$(svc_addr apprise)" -- \
                    arr_repoint "$url/api/$ver" "$key" notification "$pnotes" mediastack-apprise "serverUrl=http://$(svc_addr apprise)"
            fi
        elif w_would "prowlarr: notify the hub on indexer/health events (tag: ops)"; then
            schema=$(api GET "$url/api/$ver/notification/schema" "$key" || true)   # soft read: create path only: an empty schema FAILs below, nothing created
            tmpl=$(jq -c '[.[] | select(.implementation=="Apprise")][0] // empty' <<<"$schema" 2>/dev/null)
            if [[ -z "$tmpl" ]]; then
                wfail "prowlarr: its API offers no Apprise notification type — is the image very old?"
            else
                body=$(jq -c --arg srv "http://$(svc_addr apprise)" '
                    .name = "mediastack-apprise"
                    | .fields = [ .fields[]
                        | if .name == "serverUrl"          then .value = $srv
                          elif .name == "configurationKey" then .value = "mediastack"
                          elif .name == "tags"             then .value = ["ops"]
                          else . end ]
                    | reduce ("onHealthIssue","onHealthRestored","onApplicationUpdate") as $k
                        (.; if has($k) then .[$k] = true else . end)' <<<"$tmpl")
                resp=$(api POST "$url/api/$ver/notification" "$key" "$body") \
                    && ok "prowlarr now notifies the hub" \
                    || wfail "prowlarr: notification connection rejected: $(head -c200 <<<"$resp")"
            fi
        fi
    fi
}

# ---- cleanuparr (wave 5) ----
# Bootstrap the account (reusing the stack's arr login), store the API key,
# point it at qBittorrent and every arr, and switch the queue cleaner on
# with its conservative upstream defaults. Existing entries: untouched.
cup_url() { local p; p=$(svc_hostport cleanuparr) || return 1; echo "http://127.0.0.1:$p"; }
CUP_CODE_F="${TMPDIR:-/tmp}/.mediastack-cup-code.$$"
cup_code() { cat "$CUP_CODE_F" 2>/dev/null || echo 000; }
cup_api() { # cup_api METHOD PATH AUTHHDR [json-body] -> body; rc = http 2xx
    local m="$1" p="$2" hdr="$3" b="${4:-}" out code
    if ! out=$(curl -sS -m 20 -X "$m" ${hdr:+-H "$hdr"} -H "Content-Type: application/json" \
          ${b:+-d "$b"} -w $'\n%{http_code}' "$(cup_url)/api$p" 2>&1); then
        printf '000' > "$CUP_CODE_F"; echo "$out"; return 1
    fi
    code=${out##*$'\n'}; printf '%s' "$code" > "$CUP_CODE_F"
    echo "${out%$'\n'*}"
    [[ "$code" =~ ^2 ]]
}

wire_cleanuparr() {
    hr "wire: cleanuparr"
    svc_enabled cleanuparr || { info "cleanuparr not enabled — skipped"; return 0; }
    wire_gate cleanuparr
    http_ready cleanuparr "$(cup_url)/health" '^2' || return 1

    local user pass st out
    user=$(env_get ARR_USER); pass=$(env_get ARR_PASSWORD)
    [[ -n "$user" && -n "$pass" ]] || { wfail "cleanuparr bootstrap reuses the arr login — run 'wire arr' first (a full 'wire' does both in order)"; return 1; }

    st=$(cup_api GET /auth/status "" || true)   # soft read: unread = not set up: the setup call below answers 409 when it is, which is accepted
    if [[ "$(jq -r '.setupCompleted' <<<"$st" 2>/dev/null)" != true ]]; then
        if w_would "create cleanuparr's account ('$user' — same login as the arrs) and complete setup"; then
            out=$(cup_api POST /auth/setup/account "" "$(jq -cn --arg u "$user" --arg p "$pass" '{username:$u,password:$p}')")
            [[ "$(cup_code)" =~ ^2 || "$(cup_code)" == 409 ]] \
                || { wfail "cleanuparr account creation rejected [HTTP $(cup_code)]: $(head -c200 <<<"$out")"; return 1; }
            out=$(cup_api POST /auth/setup/complete "")
            [[ "$(cup_code)" =~ ^2 || "$(cup_code)" == 409 ]] \
                || { wfail "cleanuparr setup completion rejected [HTTP $(cup_code)]: $(head -c200 <<<"$out")"; return 1; }
            ok "account created — sign in with the arr login (view: credentials)"
        fi
    else
        ok "account already set up"
    fi
    (( WIRE_DRY )) && { info "remaining cleanuparr previews pend on signing in — shown on the real run"; return 0; }

    # login -> bearer -> durable API key
    local tok akey
    out=$(cup_api POST /auth/login "" "$(jq -cn --arg u "$user" --arg p "$pass" '{username:$u,password:$p}')") \
        || { wfail "cleanuparr rejected the arr login [HTTP $(cup_code)]: $(head -c200 <<<"$out")
     if you changed its password in the UI, this is expected — its config stays yours"; return 1; }
    tok=$(jq -r '.tokens.accessToken // empty' <<<"$out")
    [[ -n "$tok" ]] || { wfail "cleanuparr login gave no access token: $(head -c200 <<<"$out")"; return 1; }
    akey=$(cup_api GET /account/api-key "Authorization: Bearer $tok" | jq -r '.apiKey // empty' 2>/dev/null || true)   # soft read: checked on the next line
    [[ -n "$akey" ]] || { wfail "could not read cleanuparr's API key [HTTP $(cup_code)]"; return 1; }
    [[ "$(env_get CLEANUPARR_API_KEY)" == "$akey" ]] || env_set CLEANUPARR_API_KEY "$akey"
    local KH="X-Api-Key: $akey"

    # download client: create-if-missing by name
    local qu qp have
    qu=$(env_get QBITTORRENT_USER); qp=$(env_get QBITTORRENT_PASSWORD)
    local cdc=""
    if ! cdc=$(cup_api GET /configuration/download_client "$KH"); then
        wfail "cleanuparr: could not read its download clients — nothing created [HTTP $(cup_code)]"
    elif [[ " $(jq -r '[.clients[]?.name] | join(" ")' <<<"$cdc" 2>/dev/null) " == *" qbittorrent "* ]]; then
        ok "qbittorrent already connected — untouched"
        local cst cbody; cst=$(addr_of "$(jq -r '.clients[]? | select(.name=="qbittorrent") | .host' <<<"$cdc" 2>/dev/null | head -1)")
        if addr_stale "cleanuparr -> qbittorrent" qbittorrent "$cst"; then
            cbody=$(jq -c --arg h "http://$(svc_addr qbittorrent)" --arg u "$(env_get QBITTORRENT_USER)" --arg p "$(env_get QBITTORRENT_PASSWORD)" \
                '[.clients[]? | select(.name=="qbittorrent")][0] | .host = $h | .username = $u | .password = $p' <<<"$cdc")
            addr_repoint "cleanuparr -> qbittorrent" "$cst" "$(svc_addr qbittorrent)" -- \
                cup_api PUT "/configuration/download_client/$(jq -r '.id' <<<"$cbody")" "$KH" "$cbody"
        fi
    elif [[ -z "$qu" || -z "$qp" ]]; then
        wfail "no qBittorrent credentials in .env — run 'wire qbit' first"
    else
        local dc
        dc=$(jq -cn --arg u "$qu" --arg p "$qp" --arg h "http://$(svc_addr qbittorrent)" \
             '{enabled:true,name:"qbittorrent",typeName:"qBittorrent",type:"Torrent",
               host:$h,urlBase:"",username:$u,password:$p}')
        out=$(cup_api POST /configuration/download_client/test "$KH" "$dc") \
            || { wfail "cleanuparr could not reach qBittorrent [HTTP $(cup_code)]: $(head -c200 <<<"$out")"; return 1; }
        out=$(cup_api POST /configuration/download_client "$KH" "$dc") \
            && ok "qbittorrent connected" \
            || wfail "qbittorrent entry rejected [HTTP $(cup_code)]: $(head -c200 <<<"$out")"
    fi

    # arrs: create-if-missing by name, per type
    wire_arrs_ready || true
    local s ty key port cfg names
    for s in $(arr_instances); do
        ty=$(svc_label "$s" mediastack.arrtype)
        arr_known "$ty" || continue
        key=$(arr_key "$s"); port=$(svc_label "$s" mediastack.port)
        [[ -n "$key" ]] || { wfail "$s: no ApiKey readable — re-run wire in a minute"; continue; }
        cfg=$(cup_api GET "/configuration/$ty" "$KH") \
            || { wfail "cleanuparr: could not read its $ty connections — nothing created [HTTP $(cup_code)]"; continue; }
        names=$(jq -r '[.instances[]?.name] | join(" ")' <<<"$cfg" 2>/dev/null)
        if [[ " $names " == *" $s "* ]]; then
            ok "$s already connected — untouched"
            local ist ibody; ist=$(addr_of "$(jq -r --arg n "$s" '.instances[]? | select(.name==$n) | .url' <<<"$cfg" 2>/dev/null | head -1)")
            if addr_stale "cleanuparr -> $s" "$s" "$ist"; then
                ibody=$(jq -c --arg n "$s" --arg u "http://$(svc_addr "$s")" '[.instances[]? | select(.name==$n)][0] | .url = $u' <<<"$cfg")
                addr_repoint "cleanuparr -> $s" "$ist" "$(svc_addr "$s")" -- \
                    cup_api PUT "/configuration/$ty/instances/$(jq -r '.id' <<<"$ibody")" "$KH" "$ibody"
            fi
            continue
        fi
        # version = the arr application major, exactly the value cleanuparr's
        # own UI offers per type (ARR_META major)
        local aver; aver=$(arr_meta "$ty" major)
        out=$(cup_api POST "/configuration/$ty/instances" "$KH" \
              "$(jq -cn --arg n "$s" --arg u "http://$(svc_addr "$s")" --arg k "$key" --argjson v "$aver" \
                 '{enabled:true,name:$n,url:$u,apiKey:$k,version:$v}')") \
            && ok "$s connected" \
            || wfail "$s: cleanuparr rejected it [HTTP $(cup_code)]: $(head -c200 <<<"$out")"
    done

    # queue cleaner: switch on, keep upstream's conservative defaults
    cfg=$(cup_api GET /configuration/queue_cleaner "$KH" || true)   # soft read: unread = nothing written: the PUT needs the config it read
    if [[ "$(jq -r '.enabled' <<<"$cfg" 2>/dev/null)" == true ]]; then
        ok "queue cleaner already on — its settings are yours to manage in the UI"
    elif [[ -n "$cfg" ]]; then
        out=$(cup_api PUT /configuration/queue_cleaner "$KH" "$(jq -c '.enabled = true' <<<"$cfg")") \
            && ok "queue cleaner enabled (conservative defaults — tune in its UI)" \
            || wfail "could not enable the queue cleaner [HTTP $(cup_code)]: $(head -c200 <<<"$out")"
    else
        wfail "could not read the queue-cleaner config [HTTP $(cup_code)]"
    fi

    # ops notifications via the hub, when the hub is wired
    if svc_enabled apprise && [[ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST "$(apprise_url)/get/mediastack" 2>/dev/null || echo 000)" == 200 ]]; then
        local cnp=""
        if ! cnp=$(cup_api GET /configuration/notification_providers "$KH"); then
            wfail "cleanuparr: could not read its notification providers — nothing created [HTTP $(cup_code)]"
        elif [[ " $(jq -r '[.providers[]?.name] | join(" ")' <<<"$cnp" 2>/dev/null) " == *" mediastack-apprise "* ]]; then
            ok "already notifies the hub — untouched"
            local ast abody; ast=$(addr_of "$(jq -r '.providers[]? | select(.name=="mediastack-apprise") | (.url // .configuration.url // "")' <<<"$cnp" 2>/dev/null | head -1)")
            if addr_stale "cleanuparr -> apprise" apprise "$ast"; then
                # GET nests events{} and configuration{}; PUT takes them flat —
                # a naive round trip would reset every event toggle to false
                abody=$(jq -c --arg u "http://$(svc_addr apprise)" '[.providers[]? | select(.name=="mediastack-apprise")][0]
                    | {name, isEnabled} + .events
                      + (.configuration | {mode, url: $u, key, tags: (.tags // ""), serviceUrls})' <<<"$cnp")
                addr_repoint "cleanuparr -> apprise" "$ast" "$(svc_addr apprise)" -- \
                    cup_api PUT "/configuration/notification_providers/apprise/$(jq -r --arg n mediastack-apprise '.providers[]? | select(.name==$n) | .id' <<<"$cnp" | head -1)" "$KH" "$abody"
            fi
        else
            out=$(cup_api POST /configuration/notification_providers/apprise "$KH" \
                  "$(jq -cn --arg u "http://$(svc_addr apprise)" '{name:"mediastack-apprise",isEnabled:true,mode:"Api",
                              url:$u,key:"mediastack",tags:"ops",
                              onQueueItemDeleted:true,onDownloadCleaned:true,
                              onStalledStrike:true,onFailedImportStrike:true}')") \
                && ok "now notifies the hub (tag: ops)" \
                || wfail "hub connection rejected [HTTP $(cup_code)]: $(head -c200 <<<"$out")"
        fi
    fi
}

# ---- jellyfin (wave 4) ----
# Wire's jellyfin surface is deliberately tiny: complete the first-run wizard
# (once, ever — the API gate closes itself), create libraries whose PATH is
# not yet covered, and mint the stack's API key. It never updates or deletes
# anything: rename/merge/tune libraries in the GUI freely — wire matches by
# path, not name, so it will not recreate or touch them.
JF_AUTH_HDR='Authorization: MediaBrowser Client="mediastack", Device="mediastack", DeviceId="mediastack-wire", Version="1.0"'
# The token rides INSIDE the MediaBrowser header. Jellyfin 12.0 disables the
# legacy carriers (X-Emby-Token / X-Emby-Authorization / ?api_key=) by default
# and a migration switches them off on existing installs, so they 401.
jf_auth_hdr() { printf '%s%s' "$JF_AUTH_HDR" "${1:+, Token=\"$1\"}"; }
# jf_api runs inside $( ) at every call site, so a plain global would be lost
# to the subshell — the last HTTP code crosses back via a per-PID file.
JF_CODE_F="${TMPDIR:-/tmp}/.mediastack-jf-code.$$"
jf_code() { cat "$JF_CODE_F" 2>/dev/null || echo 000; }
jf_url() { local p; p=$(svc_hostport jellyfin) || return 1; echo "http://127.0.0.1:$p"; }
jf_api() { # jf_api METHOD PATH TOKEN [json-body] -> body on stdout; rc = http 2xx
    local m="$1" p="$2" tok="$3" b="${4:-}" out code
    if ! out=$(curl -sS -m 20 -X "$m" -H "$(jf_auth_hdr "$tok")" \
          -H "Content-Type: application/json" \
          ${b:+-d "$b"} -w $'\n%{http_code}' "$(jf_url)$p" 2>&1); then
        printf '000' > "$JF_CODE_F"; echo "$out"; return 1
    fi
    code=${out##*$'\n'}; printf '%s' "$code" > "$JF_CODE_F"
    echo "${out%$'\n'*}"
    [[ "$code" =~ ^2 ]]
}
jf_ready() { http_ready jellyfin "$(jf_url)/health" '^200$'; }
jf_libname() { # jf_libname <arr service> <media subdir> -> default library name
    # an instance names its own library (mediastack.jflibrary: "Movies (4K)");
    # otherwise its type's name; a type wire doesn't know, its folder's name
    local n ty; n=$(svc_label "$1" mediastack.jflibrary); ty=$(svc_label "$1" mediastack.arrtype)
    if [[ -n "$n" ]]; then echo "$n"
    elif arr_known "$ty"; then arr_meta "$ty" jfname
    else echo "${2^}"; fi
}

wire_jellyfin() {
    hr "wire: jellyfin"
    svc_enabled jellyfin || { info "jellyfin not enabled — skipped"; return 0; }
    wire_gate jellyfin
    jf_ready || return 1
    local pub completed juser jpass
    pub=$(jf_api GET /System/Info/Public "" || true)   # soft read: checked two lines below
    # NB: jq's // operator treats false as missing — read booleans plainly
    completed=$(jq -r '.StartupWizardCompleted' <<<"$pub" 2>/dev/null)
    [[ "$completed" == true || "$completed" == false ]] \
        || { wfail "jellyfin gave no readable public info [HTTP $(jf_code)]: $(head -c200 <<<"$pub")"; return 1; }
    juser=$(env_get JELLYFIN_ADMIN_USER); jpass=$(env_get JELLYFIN_ADMIN_PASSWORD)

    # --- first-run wizard: only ever runs while jellyfin says it is unclaimed.
    # This also closes a real hole: an unconfigured jellyfin lets ANY visitor
    # create the admin account.
    if [[ "$completed" == false ]]; then
        if [[ -z "$juser" || -z "$jpass" ]]; then
            if (( WIRE_DRY )); then
                w_would "complete jellyfin's first-run wizard (admin login asked on the real run)" || true
            elif [[ ! -t 0 ]]; then
                wfail "jellyfin's first-run wizard is incomplete and there is no terminal to ask for the admin login — run './mediastack.sh wire jellyfin' interactively"
                return 1
            else
                explain "Jellyfin admin" \
"Jellyfin needs one administrator account. This is the operator/recovery
login (it also signs in to Seerr as its owner) — your household gets
their own accounts later via invites. Everything else about Jellyfin
(look, libraries' settings, users) stays yours to manage in its GUI;
wire only performs this minimum first-run. Stored in .env (view:
credentials)."
                ask JF_U "Admin username" "${juser:-admin}"; juser="$REPLY_VAL"
                ask_secret "Admin password" "$(head -c12 /dev/urandom | base64 | tr -d '=+/')"; jpass="$REPLY_VAL"
                env_set JELLYFIN_ADMIN_USER "$juser"; env_set JELLYFIN_ADMIN_PASSWORD "$jpass"
            fi
        fi
        if [[ -n "$juser" && -n "$jpass" ]] && w_would "complete jellyfin's first-run wizard (admin '$juser', remote access on, UPnP off)"; then
            local step out
            for step in cfg getuser postuser remote complete; do
                case "$step" in
                    cfg)      out=$(jf_api POST /Startup/Configuration "" '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}') ;;
                    getuser)  out=$(jf_api GET /Startup/User "") ;;  # initialises the first-user record
                    postuser) out=$(jf_api POST /Startup/User "" "$(jq -cn --arg u "$juser" --arg p "$jpass" '{Name:$u,Password:$p}')") ;;
                    remote)   out=$(jf_api POST /Startup/RemoteAccess "" '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}') ;;
                    complete) out=$(jf_api POST /Startup/Complete "") ;;
                esac || { wfail "jellyfin wizard step '$step' rejected [HTTP $(jf_code)]: $(head -c200 <<<"$out")"; return 1; }
            done
            ok "first-run wizard completed — admin '$juser'"
        fi
    else
        ok "first-run wizard already completed"
    fi

    # --- everything below needs an admin session
    if [[ -z "$juser" || -z "$jpass" ]]; then
        if (( WIRE_DRY )); then
            info "library/API-key previews pend on the admin login — created earlier in the same real run"
        else
            info "jellyfin was configured outside wire and no JELLYFIN_ADMIN_USER/PASSWORD is in .env — libraries and the stack API key stay manual (set them in .env to let wire manage those)"
        fi
        return 0
    fi
    local auth tok
    auth=$(jf_api POST /Users/AuthenticateByName "" "$(jq -cn --arg u "$juser" --arg p "$jpass" '{Username:$u,Pw:$p}')") \
        || { (( WIRE_DRY )) && { info "cannot verify further without logging in — real run continues from here"; return 0; }
             wfail "jellyfin rejected the admin login from .env [HTTP $(jf_code)]: $(head -c200 <<<"$auth")"; return 1; }
    tok=$(jq -r '.AccessToken // empty' <<<"$auth")
    [[ -n "$tok" ]] || { wfail "jellyfin login succeeded but returned no token: $(head -c200 <<<"$auth")"; return 1; }
    jf_server_name "$tok"
    jf_transcode_path "$tok"
    jf_plugin_webhook "$tok"
    jf_ldap "$tok"

    # --- libraries: create-if-path-missing, derived from the arrs' own
    # rootfolder labels. Match by the HOST directory a library's location
    # resolves to through the container's mounts, not by the container path:
    # a migrated jellyfin sees the same tree under an alias (an extra mount
    # in the override, e.g. /data/tvshows) and must not be offered a twin
    # at /media/tv. GUI renames/merges are respected the same way.
    local vf droot jcn; vf=$(jf_api GET /Library/VirtualFolders "$tok" || true)   # soft read: checked on the next line
    [[ "$(jf_code)" =~ ^2 ]] || { wfail "could not list jellyfin libraries [HTTP $(jf_code)]: $(head -c200 <<<"$vf")"; return 1; }
    droot=$(env_get DATA_ROOT); jcn=$(svc_cname jellyfin)
    local -A covered=()   # host dir -> the container location a library uses for it
    local loc hp
    while IFS= read -r loc; do
        [[ -n "$loc" ]] || continue
        hp=$(c_host_path "$jcn" "$loc")
        [[ -n "$hp" ]] || { warn "jellyfin library location $loc is not backed by any mount of the container — a library pointing at nothing"; continue; }
        covered[$(readlink -f "$hp" 2>/dev/null || echo "$hp")]=$loc
    done < <(jq -r '.[].Locations[]?' <<<"$vf")
    local -A seen=()
    local s rf base path hdir ty ctype lname enc_n enc_p resp
    for s in $(arr_instances); do
        rf=$(svc_label "$s" mediastack.rootfolder); base=${rf##*/}
        [[ -n "$base" && -z "${seen[$base]:-}" ]] || continue; seen[$base]=1
        path="/media/$base"
        hdir=$(readlink -f "$droot/media/$base" 2>/dev/null || echo "$droot/media/$base")
        ty=$(svc_label "$s" mediastack.arrtype)
        arr_known "$ty" || continue
        ctype=$(arr_meta "$ty" jftype)
        if [[ -n "${covered[$hdir]:-}" ]]; then
            if [[ "${covered[$hdir]}" == "$path" ]]; then
                ok "a library already covers $path — untouched (yours to manage in the GUI)"
            else
                ok "a library already covers $hdir (as ${covered[$hdir]} inside the container) — untouched (yours to manage in the GUI)"
            fi
            continue
        fi
        if (( WIRE_DRY )); then
            w_would "create jellyfin library for $path (${ctype}; name asked on the real run)" || true
            continue
        fi
        if [[ ! -t 0 ]]; then
            info "$path has no library yet — creation asks for a name, so it only happens interactively: ./mediastack.sh wire jellyfin"
            continue
        fi
        # jellyfin sees /media read-only; the host dir must exist or the
        # library is born broken. Same ownership pattern as configure's tree.
        sudo test -d "$droot/media/$base" \
            || { sudo install -d -m 2775 -g mediacenter "$droot/media/$base" && info "created $droot/media/$base (was missing)"; }
        ask JF_LN "Library name for $path" "$(jf_libname "$s" "$base")"; lname="$REPLY_VAL"
        if w_would "create jellyfin library '$lname' -> $path"; then
            enc_n=$(jq -rn --arg v "$lname" '$v|@uri'); enc_p=$(jq -rn --arg v "$path" '$v|@uri')
            resp=$(jf_api POST "/Library/VirtualFolders?name=${enc_n}&collectionType=${ctype}&paths=${enc_p}&refreshLibrary=true" "$tok" '{"LibraryOptions":{}}') \
                && ok "library '$lname' created" \
                || wfail "library '$lname' rejected [HTTP $(jf_code)]: $(head -c200 <<<"$resp")"
        fi
    done

    # --- one API key for the stack (update-defer streaming check + doctor)
    local keys have
    keys=$(jf_api GET /Auth/Keys "$tok") \
        || { wfail "could not list jellyfin API keys [HTTP $(jf_code)] — nothing created"; return 1; }
    have=$(jq -r '.Items[]? | select(.AppName=="mediastack") | .AccessToken' <<<"$keys" 2>/dev/null | head -1)
    if [[ -n "$have" ]]; then
        [[ "$(env_get JELLYFIN_API_KEY)" == "$have" ]] || env_set JELLYFIN_API_KEY "$have"
        ok "stack API key present"
    elif w_would "mint a jellyfin API key for the stack (app 'mediastack')"; then
        jf_api POST "/Auth/Keys?app=mediastack" "$tok" >/dev/null \
            || { wfail "API key creation rejected [HTTP $(jf_code)]"; return 1; }
        keys=$(jf_api GET /Auth/Keys "$tok" || true)   # soft read: re-read after creating the key: empty FAILs below
        have=$(jq -r '.Items[]? | select(.AppName=="mediastack") | .AccessToken' <<<"$keys" 2>/dev/null | head -1)
        [[ -n "$have" ]] || { wfail "API key created but not readable back — check Dashboard -> API Keys"; return 1; }
        env_set JELLYFIN_API_KEY "$have"
        ok "stack API key minted and stored (JELLYFIN_API_KEY)"
    fi
}

# ---- seerr (wave 4) ----
# Seerr federates auth to jellyfin (users sign in with their jellyfin logins;
# no seerr-local passwords exist here). Wire bootstraps an UNINITIALISED
# seerr only: first sign-in as the jellyfin admin (which creates seerr's
# owner), library sync + enable, one server entry per arr, initialise. An
# initialised seerr is never touched — its settings are GUI territory.
seerr_url() { local p; p=$(svc_hostport seerr) || return 1; echo "http://127.0.0.1:$p"; }
SEERR_CODE_F="${TMPDIR:-/tmp}/.mediastack-seerr-code.$$"
seerr_code() { cat "$SEERR_CODE_F" 2>/dev/null || echo 000; }
seerr_api() { # seerr_api METHOD PATH JAR [json-body] -> body; rc = http 2xx
    local m="$1" p="$2" jar="$3" b="${4:-}" out code
    if ! out=$(curl -sS -m 30 -X "$m" -b "$jar" -c "$jar" -H "Content-Type: application/json" \
          ${b:+-d "$b"} -w $'\n%{http_code}' "$(seerr_url)/api/v1$p" 2>&1); then
        printf '000' > "$SEERR_CODE_F"; echo "$out"; return 1
    fi
    code=${out##*$'\n'}; printf '%s' "$code" > "$SEERR_CODE_F"
    echo "${out%$'\n'*}"
    [[ "$code" =~ ^2 ]]
}

wire_seerr() {
    hr "wire: seerr"
    svc_enabled seerr || { info "seerr not enabled — skipped"; return 0; }
    svc_enabled jellyfin || { wfail "seerr is enabled but jellyfin is not — seerr cannot function without it"; return 1; }
    wire_gate seerr jellyfin
    # /settings/public, not /status: /status asks GitHub for the latest release
    # on every call, so without outbound DNS it outlasts the probe (seen live:
    # EAI_AGAIN on api.github.com, HTTP 000 for 90s on a healthy seerr)
    http_ready seerr "$(seerr_url)/api/v1/settings/public" '^200$' || return 1
    local jar pub
    jar=$(mktemp)
    pub=$(seerr_api GET /settings/public "$jar" || true)   # soft read: unread = uninitialised: the hostname re-send below is handled as already configured
    local seerr_initialized=false
    [[ "$(jq -r '.initialized' <<<"$pub" 2>/dev/null)" == true ]] && seerr_initialized=true
    local juser jpass
    juser=$(env_get JELLYFIN_ADMIN_USER); jpass=$(env_get JELLYFIN_ADMIN_PASSWORD)
    if [[ -z "$juser" || -z "$jpass" ]]; then
        if (( WIRE_DRY )); then
            w_would "bootstrap seerr (sign in as the jellyfin admin, sync + enable libraries, add the arrs, initialise)" || true
        else
            wfail "seerr bootstrap needs the jellyfin admin login — run 'wire jellyfin' first (a full 'wire' does both in order)"
        fi
        rm -f "$jar"; return 0
    fi
    if $seerr_initialized; then
        # initialised = its settings are yours; wire only CREATES missing arr
        # entries (matched by name), mirroring the jellyfin library contract
        if ! w_would "verify seerr's arr entries (create missing only — nothing existing is touched)"; then rm -f "$jar"; return 0; fi
    else
        if ! w_would "bootstrap seerr: jellyfin sign-in ('$juser'), libraries, arr servers, initialise"; then rm -f "$jar"; return 0; fi
    fi

    # the API demands the hostname iff seerr does not have one yet: a prior
    # partial bootstrap leaves it stored, and re-sending it is a hard 500
    local jfport out
    jfport=$(svc_label jellyfin mediastack.port)
    out=$(seerr_api POST /auth/jellyfin "$jar" "$(jq -cn --arg u "$juser" --arg p "$jpass" --arg h "$(svc_host jellyfin)" --argjson port "$jfport" \
          '{username:$u,password:$p,hostname:$h,port:$port,useSsl:false,urlBase:"",serverType:2}')") || {
        if grep -q "already configured" <<<"$out"; then
            $seerr_initialized || info "seerr already holds the jellyfin hostname (earlier attempt) — signing in without it"
            out=$(seerr_api POST /auth/jellyfin "$jar" "$(jq -cn --arg u "$juser" --arg p "$jpass" \
                  '{username:$u,password:$p,serverType:2}')") \
                || { wfail "seerr rejected the jellyfin sign-in [HTTP $(seerr_code)]: $(head -c200 <<<"$out")"; rm -f "$jar"; return 1; }
        else
            wfail "seerr rejected the jellyfin sign-in [HTTP $(seerr_code)]: $(head -c200 <<<"$out")"; rm -f "$jar"; return 1
        fi
    }
    ok "signed in — seerr owner is jellyfin admin '$juser'"

    if ! $seerr_initialized; then
    # v3.4.1 API: ?sync=true fetches from jellyfin and returns the list;
    # ?enable=<csv-ids> declares the complete enabled set in one call
    local libs ids n
    libs=$(seerr_api GET "/settings/jellyfin/library?sync=true" "$jar") \
        || { wfail "library sync failed [HTTP $(seerr_code)]: $(head -c200 <<<"$libs")"; rm -f "$jar"; return 1; }
    ids=$(jq -r '[.[].id] | join(",")' <<<"$libs" 2>/dev/null)
    [[ -n "$ids" ]] || { wfail "seerr returned no libraries from jellyfin — are the libraries created? re-run 'wire jellyfin' first: $(head -c200 <<<"$libs")"; rm -f "$jar"; return 1; }
    libs=$(seerr_api GET "/settings/jellyfin/library?enable=$ids" "$jar") \
        || { wfail "enabling libraries failed [HTTP $(seerr_code)]: $(head -c200 <<<"$libs")"; rm -f "$jar"; return 1; }
    n=$(jq '[.[] | select(.enabled)] | length' <<<"$libs" 2>/dev/null)
    ok "libraries synced — ${n:-0} enabled"
    fi

    # one server entry per arr instance, connection details straight from the
    # stack's own labels/keys. The arrs live in gluetun's network namespace,
    # so 'gluetun' is their in-network hostname. Existing entries (matched by
    # name) are never touched — create-if-missing only.
    local have_radarr have_sonarr set_radarr set_sonarr
    wire_arrs_ready || true
    set_radarr=$(seerr_api GET /settings/radarr "$jar") \
        || { wfail "seerr: could not read its radarr servers — nothing created [HTTP $(seerr_code)]"; rm -f "$jar"; return 1; }
    set_sonarr=$(seerr_api GET /settings/sonarr "$jar") \
        || { wfail "seerr: could not read its sonarr servers — nothing created [HTTP $(seerr_code)]"; rm -f "$jar"; return 1; }
    have_radarr=$(jq -r '[.[].name] | join(" ")' <<<"$set_radarr" 2>/dev/null || true)
    have_sonarr=$(jq -r '[.[].name] | join(" ")' <<<"$set_sonarr" 2>/dev/null || true)
    local s ty key port root profs pid pname body ep is4k
    for s in $(arr_instances); do
        ty=$(svc_label "$s" mediastack.arrtype)
        [[ "$ty" == radarr || "$ty" == sonarr ]] || { info "$s: seerr does not manage $ty — skipped"; continue; }
        if [[ "$ty" == radarr && " $have_radarr " == *" $s "* ]] || [[ "$ty" == sonarr && " $have_sonarr " == *" $s "* ]]; then
            ok "$s already in seerr — untouched (yours to manage in the GUI)"
            local sset sentry sst
            if [[ "$ty" == radarr ]]; then sset=$set_radarr; else sset=$set_sonarr; fi
            sentry=$(jq -c --arg n "$s" '[.[]? | select(.name == $n)][0] // empty' <<<"$sset")
            sst="$(jq -r '.hostname // ""' <<<"$sentry"):$(jq -r '.port // ""' <<<"$sentry")"
            if addr_stale "seerr -> $s" "$s" "$sst"; then
                addr_repoint "seerr -> $s" "$sst" "$(svc_addr "$s")" -- \
                    seerr_api PUT "/settings/$ty/$(jq -r '.id' <<<"$sentry")" "$jar" \
                    "$(jq -c --arg h "$(svc_host "$s")" --argjson p "$(svc_cport "$s")" '.hostname = $h | .port = $p' <<<"$sentry")"
            fi
            continue
        fi
        key=$(arr_key "$s"); port=$(svc_label "$s" mediastack.port); root=$(svc_label "$s" mediastack.rootfolder)
        [[ -n "$key" ]] || { wfail "$s: no ApiKey readable — is it initialised? re-run wire in a minute"; continue; }
        profs=$(api GET "$(arr_url "$s")/api/$(arr_apiver "$s")/qualityprofile" "$key" || true)   # soft read: empty FAILs below: that seerr entry is skipped
        pid=$(jq -r --arg n "$(env_get "TRASH_PROFILE_$(uvar "$s")")" \
              '(map(select(.name==$n)) + .)[0].id // empty' <<<"$profs" 2>/dev/null)
        pname=$(jq -r --arg n "$(env_get "TRASH_PROFILE_$(uvar "$s")")" \
              '(map(select(.name==$n)) + .)[0].name // empty' <<<"$profs" 2>/dev/null)
        [[ -n "$pid" ]] || { wfail "$s: could not read a quality profile from its API — seerr entry skipped"; continue; }
        is4k=false; [[ "$s" == *-4k ]] && is4k=true
        body=$(jq -cn --arg name "$s" --argjson port "$port" --arg key "$key" \
                     --argjson pid "$pid" --arg pname "$pname" --arg root "$root" --argjson is4k "$is4k" \
                     --arg host "$(svc_host "$s")" \
              '{name:$name,hostname:$host,port:$port,apiKey:$key,useSsl:false,baseUrl:"",
                activeProfileId:$pid,activeProfileName:$pname,activeDirectory:$root,
                tags:[],is4k:$is4k,isDefault:true,syncEnabled:true,preventSearch:false,
                tagRequests:false,overrideRule:[]}')
        ep="/settings/$ty"
        [[ "$ty" == radarr ]] && body=$(jq -c '. + {minimumAvailability:"released"}' <<<"$body")
        [[ "$ty" == sonarr ]] && body=$(jq -c '. + {enableSeasonFolders:true}' <<<"$body")
        # seerr's default server per type: the base instance, or the 4K one
        # (4K has its own default slot); any other extra instance is opt-in
        [[ "$s" == "$ty" || "$is4k" == true ]] || body=$(jq -c '. + {isDefault:false}' <<<"$body")
        out=$(seerr_api POST "$ep/test" "$jar" "$body") \
            || { wfail "$s: seerr could not reach it [HTTP $(seerr_code)]: $(head -c200 <<<"$out")"; continue; }
        out=$(seerr_api POST "$ep" "$jar" "$body") \
            && ok "$s added to seerr (profile '$pname'${is4k:+, 4k=$is4k})" \
            || wfail "$s: seerr rejected the server entry [HTTP $(seerr_code)]: $(head -c200 <<<"$out")"
    done

    # request/media/issue events -> the hub, each tagged with its own event
    # name so the hub routes it to its stream (lib/notify.sh: NOTIFY_EVENTS).
    # An agent mediastack made is kept current (the one from before per-event
    # routing is upgraded); one edited in Seerr's UI is left alone — except
    # its address, when mediastack made it and a VPN toggle moved apprise.
    if svc_enabled apprise && [[ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST "$(apprise_url)/get/mediastack" 2>/dev/null || echo 000)" == 200 ]]; then
        local wh want_t hub next
        want_t=$(seerr_hub_types); hub="http://$(svc_addr apprise)/notify/mediastack"
        if ! wh=$(seerr_api GET /settings/notifications/webhook "$jar"); then
            wfail "seerr: could not read its webhook settings — left as they are [HTTP $(seerr_code)]"
        elif [[ "$(jq -r '.enabled' <<<"$wh" 2>/dev/null)" == true ]]; then
            next=$(seerr_agent_next "$wh")
            case "$next" in
                same)  ok "seerr sends its events to the hub, routed per stream" ;;
                yours) ok "seerr's webhook agent has a template set in its UI — untouched (per-stream routing needs the tag {{notification_type}})" ;;
                *)     if w_would "seerr: route its events per stream (${NOTIFY_EVENTS[users]// /, } -> users, the rest -> ops) — the events it has on and its poster setting stay as they are"; then
                           out=$(seerr_api POST /settings/notifications/webhook "$jar" "$next") \
                               && { ok "seerr's events now route per stream"; wh=$next; } \
                               || wfail "seerr rejected the updated webhook agent [HTTP $(seerr_code)]: $(head -c200 <<<"$out")"
                       fi ;;
            esac
            local wst; wst=$(addr_of "$(jq -r '.options.webhookUrl // ""' <<<"$wh")")
            if addr_stale "seerr -> apprise" apprise "$wst"; then
                addr_repoint "seerr -> apprise" "$wst" "$(svc_addr apprise)" -- \
                    seerr_api POST /settings/notifications/webhook "$jar" \
                    "$(jq -c --arg u "$hub" '.options.webhookUrl = $u' <<<"$wh")"
            fi
        elif w_would "notify the hub on requests, availability and issues, routed per stream"; then
            out=$(seerr_api POST /settings/notifications/webhook "$jar" "$(jq -cn --arg u "$hub" --arg p "$SEERR_HUB_PAYLOAD" --argjson t "$want_t" '
                {enabled:true, embedPoster:false, types:$t,
                 options:{webhookUrl:$u, authHeader:"", jsonPayload:$p}}')") \
                && ok "seerr now notifies the hub" \
                || wfail "seerr rejected the webhook agent [HTTP $(seerr_code)]: $(head -c200 <<<"$out")"
        fi
    fi
    if $seerr_initialized; then
        rm -f "$jar"
        ok "seerr arr entries verified"
        return 0
    fi
    out=$(seerr_api POST /settings/initialize "$jar") \
        || { wfail "seerr initialise call failed [HTTP $(seerr_code)]: $(head -c200 <<<"$out")"; rm -f "$jar"; return 1; }
    local skey
    skey=$(seerr_api GET /settings/main "$jar" | jq -r '.apiKey // empty' 2>/dev/null || true)   # soft read: optional: stored only when read
    [[ -n "$skey" ]] && env_set SEERR_API_KEY "$skey"
    rm -f "$jar"
    ok "seerr initialised — users sign in with their jellyfin logins"
}

# ---- wizarr (wave 4) ----
# Wizarr's admin account, jellyfin connection, and API keys are web-UI-only
# by upstream design — no bootstrap API exists. One documented first-run in
# the UI, then wire holds the API key and './mediastack.sh invite' does the
# rest forever.
wizarr_url() { local p; p=$(svc_hostport wizarr) || return 1; echo "http://127.0.0.1:$p"; }

wire_wizarr() {
    hr "wire: wizarr"
    svc_enabled wizarr || { info "wizarr not enabled — skipped"; return 0; }
    wire_gate wizarr
    # a virgin wizarr 302s /health to /setup (onboarding middleware) —
    # any 2xx/3xx means the app is up and serving
    http_ready wizarr "$(wizarr_url)/health" '^[23]' || return 1
    local key host domain
    key=$(env_get WIZARR_API_KEY)
    if [[ -z "$key" ]]; then
        if (( WIRE_DRY )); then
            w_would "store + verify a wizarr API key (pasted by you after wizarr's one-time UI first-run)" || true
            return 0
        fi
        if [[ ! -t 0 ]]; then
            info "no WIZARR_API_KEY yet — wizarr's first-run is a one-time UI step; run './mediastack.sh wire wizarr' interactively after it"
            return 0
        fi
        host=$(env_get WIZARR_HOST invites); domain=$(env_get TRAEFIK_DOMAIN)
        local jfkey; jfkey=$(env_get JELLYFIN_API_KEY "(empty — run 'wire jellyfin' first to mint it)")
        explain "Wizarr first-run (one-time, in its UI)" \
"Wizarr's admin account and API keys can only be created in its web UI —
there is no automation API for this by upstream design. Once, ever:
  1. open ${domain:+https://$host.$domain (or }http://$(hostname -I 2>/dev/null | awk '{print $1}'):$(svc_hostport wizarr)${domain:+)}
  2. create the admin account
  3. Settings -> Servers -> Add Server:
       Name            jellyfin
       Server Type     Jellyfin
       URL (Internal)  http://$(svc_addr jellyfin)
       API Key         $jfkey
     then Test & Add
  4. Settings -> API Keys -> create one, and paste it below
Paste nothing to skip for now — re-run 'wire wizarr' any time."
        ask_token "Wizarr API key (input is hidden; empty = skip)" ""
        key="$REPLY_VAL"
        [[ -n "$key" ]] || { info "skipped — invites stay in wizarr's UI until a key is stored"; return 0; }
        env_set WIZARR_API_KEY "$key"
    fi
    local out
    if ! out=$(curl -sS -m 15 -H "X-API-Key: $key" -w $'\n%{http_code}' "$(wizarr_url)/api/invitations" 2>&1); then
        wfail "wizarr unreachable while verifying the API key: $(head -c200 <<<"$out")"; return 1
    fi
    code=${out##*$'\n'}
    if [[ "$code" =~ ^2 ]]; then
        ok "API key verified — mint invites with: ./mediastack.sh invite"
    else
        wfail "wizarr rejected the stored API key [HTTP $code] — recreate it in Settings -> API Keys, then re-run 'wire wizarr' (the old value stays in .env until replaced)"
        return 1
    fi
}

wire_authentik() {
    hr "wire: authentik"
    svc_enabled authentik || { info "authentik not enabled — skipped"; return 0; }
    wire_gate authentik
    http_ready authentik "$(authentik_url)/-/health/ready/" '^2' || return 1
    # its base URL: the address in links it generates (invitations included).
    # Set when unset, or when it is still the one mediastack last wrote (a
    # renamed host); a URL you set in authentik's UI is left alone.
    local want cur mine
    want=$(authentik_portal); mine=$(state_get AUTHENTIK_BASE_URL)
    cur=$(ak_api GET /admin/settings/ | jq -r '.base_url // ""') \
        || { wfail "authentik: its settings are unreadable — is AUTHENTIK_API_TOKEN the one it started with?"; return 1; }
    if [[ "$cur" == "$want" ]]; then
        ok "authentik: base URL $want"
    elif [[ -n "$cur" && "$cur" != "$mine" ]]; then
        ok "authentik: base URL $cur was set in its UI — untouched"
    elif w_would "authentik: set its base URL to $want (the address in the links it generates)"; then
        if ak_api PATCH /admin/settings/ "$(jq -cn --arg u "$want" '{base_url:$u}')" >/dev/null; then
            state_set AUTHENTIK_BASE_URL "$want"; ok "authentik: base URL set"
        else wfail "authentik rejected the base URL $want"; fi
    fi
    local st; st=$(authentik_blueprint_status)
    local applied=0
    if [[ "$st" == outdated || "$st" == error ]] && w_would "authentik: apply mediastack's current portal setup now (an earlier version is in place)"; then
        st=$(authentik_blueprint_apply); applied=1
    fi
    # the LDAP outpost caches bind results: a changed setup starts it afresh,
    # so an answer from before the change cannot outlive it (found live)
    if (( applied )) && [[ "$st" == successful && "$(c_state "$(svc_cname authentik-ldap)")" == running ]]; then
        sudo docker restart "$(svc_cname authentik-ldap)" >/dev/null && ok "authentik: LDAP outpost restarted on the new setup (its bind cache cleared)"
    fi
    case "$st" in
        successful) ok "authentik: mediastack's portal setup applied (media-users, admins, sign-up by invitation)" ;;
        "") info "authentik: mediastack's portal setup not discovered yet — authentik finds it within minutes of starting; re-run to check"; return 0 ;;
        outdated) wfail "authentik: an earlier version of mediastack's portal setup is still in place — ./mediastack.sh logs authentik --no-follow | grep -i blueprint"; return 0 ;;
        *) wfail "authentik rejected mediastack's portal setup ($st). Its validator says:"
           authentik_blueprint_why | sed 's/^/       /'
           return 0 ;;
    esac
    wire_authentik_gate
}

wire_authentik_gate() { # the gate on the built-in outpost, the first admin in `admins`, the dashboard cards
    # 1. the gate's provider on the built-in outpost — added to what is there, never replacing it
    local out prov
    out=$(ak_api GET "/providers/proxy/?name__iexact=mediastack-gate") || { wfail "authentik: gate provider unreadable"; return 0; }
    prov=$(jq -r '.results[0].pk // empty' <<<"$out")
    [[ -n "$prov" ]] || { wfail "authentik: the gate provider (mediastack-gate) is missing — the blueprint creates it: ./mediastack.sh logs authentik --no-follow | grep -i blueprint"; return 0; }
    if authentik_gate_attached; then ok "authentik: the gate is on its built-in outpost"
    else authentik_outpost_add "$prov" "the gate"; fi
    # 2. the first admin joins `admins` once — after that, membership is yours to manage
    if [[ -z "$(state_get AUTHENTIK_ADMINS_SEEDED)" ]] && w_would "authentik: put akadmin in 'admins' (the gate lets admins through)"; then
        local g u
        g=$(ak_api GET "/core/groups/?search=admins") && g=$(jq -r '[.results[] | select(.name == "admins") | .pk][0] // empty' <<<"$g")
        u=$(ak_api GET "/core/users/?username=akadmin") && u=$(jq -r '.results[0].pk // empty' <<<"$u")
        if [[ -n "$g" && -n "$u" ]] && ak_api POST "/core/groups/$g/add_user/" "$(jq -cn --argjson u "$u" '{pk:$u}')" >/dev/null; then
            state_set AUTHENTIK_ADMINS_SEEDED 1; ok "authentik: akadmin is in 'admins'"
        else wfail "authentik: could not add akadmin to 'admins'"; fi
    fi
    # 3. dashboard cards: admin tools (admins), household apps (media-users) — slugs mediastack-*: ours
    wire_authentik_cards
    # 4. the LDAP outpost's token: the outpost can only start with it
    wire_authentik_ldap_token
}

wire_authentik_ldap_token() { # fetch the mediastack-ldap outpost's token into .env; restart the outpost on a change
    local out pk key
    out=$(ak_api GET "/outposts/instances/?name__iexact=mediastack-ldap") || { wfail "authentik: outposts unreadable"; return 0; }
    pk=$(jq -r '.results[0].pk // empty' <<<"$out")
    [[ -n "$pk" ]] || { wfail "authentik: the LDAP outpost (mediastack-ldap) is missing — the blueprint creates it"; return 0; }
    out=$(ak_api GET "/core/tokens/ak-outpost-$pk-api/view_key/") || { wfail "authentik: the LDAP outpost's token is unreadable"; return 0; }
    key=$(jq -r '.key // empty' <<<"$out")
    [[ -n "$key" ]] || { wfail "authentik answered without the LDAP outpost's token"; return 0; }
    if [[ "$(env_get AUTHENTIK_LDAP_TOKEN)" == "$key" ]]; then ok "authentik: the LDAP outpost has its token"; return 0; fi
    w_would "authentik: give the LDAP outpost its token, then start it" || return 0
    env_set AUTHENTIK_LDAP_TOKEN "$key"
    # shellcheck disable=SC2034  # the render cache lives in the entrypoint (read by DC's callers)
    RENDERED_JSON=""
    DC up -d --no-deps authentik-ldap >/dev/null && ok "authentik: LDAP outpost started with its token" \
        || wfail "the LDAP outpost did not start: ./mediastack.sh logs authentik"
}

ak_group_pk() { # ak_group_pk NAME -> its pk (exact name, not a lookalike)
    local g; g=$(ak_api GET "/core/groups/?search=$1") || return 1
    jq -r --arg n "$1" '[.results[]? | select(.name == $n) | .pk][0] // empty' <<<"$g"
}

ak_flow_pk() { # ak_flow_pk SLUG -> its pk
    local f; f=$(ak_api GET "/flows/instances/?slug=$1") || return 1
    jq -r '.results[0].pk // empty' <<<"$f"
}

authentik_outpost_add() { # authentik_outpost_add PROVIDER-PK LABEL — beside what is on the built-in outpost, never replacing it
    local out outpost provs
    out=$(ak_api GET "/outposts/instances/?managed__iexact=goauthentik.io/outposts/embedded") || { wfail "authentik: built-in outpost unreadable"; return 1; }
    outpost=$(jq -r '.results[0].pk // empty' <<<"$out"); provs=$(jq -c '.results[0].providers // []' <<<"$out")
    [[ -n "$outpost" ]] || { wfail "authentik: its built-in outpost is missing"; return 1; }
    jq -e --argjson p "$1" 'index($p) != null' <<<"$provs" >/dev/null && return 0
    w_would "authentik: put $2 on its built-in outpost" || return 0
    ak_api PATCH "/outposts/instances/$outpost/" "$(jq -cn --argjson ps "$provs" --argjson p "$1" '{providers: ($ps + [$p])}')" >/dev/null \
        && ok "authentik: $2 attached" || { wfail "authentik refused to attach $2 to its outpost"; return 1; }
}

authentik_house_provider() { # authentik_house_provider SVC -> HOUSE_PK: its household gate (forward auth for its one address)
    # the pk comes back in HOUSE_PK (not stdout: a $(…) subshell would lose wire's failure count)
    HOUSE_PK=""
    local s="$1" name="mediastack-house-$1" url out pk az inv
    url=$(svc_url "$s")
    out=$(ak_api GET "/providers/proxy/?name__iexact=$name") || { wfail "authentik: providers unreadable"; return 1; }
    pk=$(jq -r '.results[0].pk // empty' <<<"$out")
    if [[ -z "$pk" ]]; then
        w_would "authentik: a household gate for $s ($url — media-users get through)" || return 1
        az=$(ak_flow_pk default-provider-authorization-implicit-consent); inv=$(ak_flow_pk default-provider-invalidation-flow)
        [[ -n "$az" && -n "$inv" ]] || { wfail "authentik: its default provider flows are missing"; return 1; }
        out=$(ak_api POST /providers/proxy/ "$(jq -cn --arg n "$name" --arg u "$url" --arg a "$az" --arg i "$inv" \
            '{name:$n, mode:"forward_single", external_host:$u, authorization_flow:$a, invalidation_flow:$i}')") \
            || { wfail "authentik refused $s's household gate: $(head -c160 <<<"$out")"; return 1; }
        pk=$(jq -r '.pk' <<<"$out")
    elif [[ "$(jq -r '.results[0].external_host' <<<"$out")" != "$url" ]]; then
        w_would "authentik: move $s's household gate to $url (its address changed)" || return 1
        ak_api PATCH "/providers/proxy/$pk/" "$(jq -cn --arg u "$url" '{external_host:$u}')" >/dev/null \
            || { wfail "authentik refused to update $s's household gate"; return 1; }
    fi
    authentik_outpost_add "$pk" "$s's household gate" || return 1
    HOUSE_PK=$pk
}

ak_card() { # ak_card ALL SLUG NAME URL DESC SECTION PROVIDER GROUP-PK... — a dashboard card only those groups see
    local all="$1" slug="$2" name="$3" url="$4" desc="$5" section="$6" prov="$7" have body app bind g
    shift 7
    body=$(jq -cn --arg n "$name" --arg sl "$slug" --arg u "$url" --arg d "$desc" --arg sec "$section" --arg p "$prov" \
        '{name:$n, slug:$sl, meta_launch_url:$u, meta_description:$d, meta_publisher:"mediastack", group:$sec,
          open_in_new_tab:true, policy_engine_mode:"any"} + (if $p != "" then {provider: ($p|tonumber)} else {} end)')
    have=$(jq -c --arg sl "$slug" '[.results[] | select(.slug == $sl)][0] // empty' <<<"$all")
    if [[ -z "$have" ]]; then
        w_would "authentik: add the $section card for $name" || return 0
        app=$(ak_api POST /core/applications/ "$body") || { wfail "authentik refused the card for $name: $(head -c160 <<<"$app")"; return 0; }
    elif [[ "$(jq -r '.meta_launch_url' <<<"$have")" != "$url" || "$(jq -r '.provider // "" | tostring' <<<"$have" | sed 's/^null$//')" != "$prov" ]]; then
        w_would "authentik: update $name's card" || return 0
        app=$(ak_api PATCH "/core/applications/$slug/" "$body") || { wfail "authentik refused to update $name's card"; return 0; }
    else
        app=$have
    fi
    bind=$(ak_api GET "/policies/bindings/?target=$(jq -r '.pk' <<<"$app")") || { wfail "authentik: bindings unreadable"; return 0; }
    for g in "$@"; do
        jq -e --arg g "$g" '.results[] | select(.group == $g)' <<<"$bind" >/dev/null && continue
        ak_api POST /policies/bindings/ "$(jq -cn --arg t "$(jq -r '.pk' <<<"$app")" --arg g "$g" '{target:$t, group:$g, order:0}')" >/dev/null \
            || { wfail "authentik: could not limit $name's card"; return 0; }
    done
    ok "authentik: $name card ($section)"
}

ak_card_prune() { # ak_card_prune ALL PREFIX WANTED... — cards mediastack made for services no longer wanted leave
    local all="$1" prefix="$2" slug; shift 2
    for slug in $(jq -r --arg p "$prefix" '.results[].slug | select(startswith($p))' <<<"$all"); do
        [[ " $* " == *" ${slug#"$prefix"} "* ]] && continue
        w_would "authentik: remove the card for ${slug#"$prefix"}" || continue
        ak_api DELETE "/core/applications/$slug/" >/dev/null && ok "authentik: ${slug#"$prefix"} card removed" \
            || wfail "authentik refused to remove ${slug#"$prefix"}'s card"
    done
}

wire_authentik_cards() { # admin tools for admins; household apps for media-users (and admins); ours only, by slug prefix
    local all adm mu s prov
    all=$(ak_api GET "/core/applications/?superuser_full_list=true&page_size=500") || { wfail "authentik: applications unreadable"; return 0; }
    adm=$(ak_group_pk admins); mu=$(ak_group_pk media-users)
    [[ -n "$adm" && -n "$mu" ]] || { wfail "authentik: groups 'admins'/'media-users' missing (the blueprint creates them)"; return 0; }
    for s in $(authentik_gated); do
        ak_card "$all" "mediastack-tool-$s" "$s" "$(svc_url "$s")" "$(svc_label "$s" mediastack.desc)" "Admin tools" "" "$adm"
    done
    for s in $(authentik_household); do
        prov=""
        # a household app behind the household gate: its card carries the gate's rule
        if [[ -n "$(svc_label "$s" mediastack.auth.group)" ]]; then authentik_house_provider "$s" || continue; prov=$HOUSE_PK; fi
        ak_card "$all" "mediastack-app-$s" "$s" "$(svc_url "$s")" "$(svc_label "$s" mediastack.desc)" "Media" "$prov" "$mu" "$adm"
    done
    # shellcheck disable=SC2046  # service names, one word each
    ak_card_prune "$all" mediastack-tool- $(authentik_gated)
    # shellcheck disable=SC2046
    ak_card_prune "$all" mediastack-app- $(authentik_household)
    return 0
}

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
            cmd_backup
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
