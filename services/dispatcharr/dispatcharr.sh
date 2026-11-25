#!/usr/bin/env bash
# services/dispatcharr/dispatcharr.sh — Dispatcharr's API client, its `wire
# dispatcharr` role (the stack's own admin, its header sign-in), what
# provision makes before its first start, Traefik's middleware that names
# its admin past the gate, and `set-credentials dispatcharr`. Sourced by the
# entrypoint; relies on lib/wire.sh and the entrypoint's helpers at call time.
#
# One Dispatcharr admin — the stack's own login. Behind the portal the admin
# gate decides who gets in; past it, Traefik adds a header naming that
# admin, and Dispatcharr's "Reverse Proxy Auth" signs the browser in as it.
# Dispatcharr believes the header only from DISPATCHARR_TRUSTED_PROXIES
# (Traefik's address alone, in its fragment), and no route to it skips the
# gate: a client's own copy of the header never reaches it from Traefik
# (docs/roadmap.md, its entry: the spike).

dispatcharr_logins() { printf "Dispatcharr's admin\tDISPATCHARR_ADMIN_USER\tDISPATCHARR_ADMIN_PASSWORD\treserve user_re=^[A-Za-z0-9.@+_-]+$\n"; }   # lib/logins.sh; Django's own username rule

DSP_HEADER=X-Mediastack-User   # the header Traefik adds past the gate, and Dispatcharr reads

dsp_url() { local p; p=$(svc_hostport dispatcharr) || return 1; echo "http://127.0.0.1:$p"; }
dsp_api() { # dsp_api METHOD PATH TOKEN [json] -> body; rc from HTTP
    local out code
    out=$(curl -sS -m 30 -X "$1" -H "Content-Type: application/json" ${3:+-H "Authorization: Bearer $3"} \
          ${4:+-d "$4"} -w '\n%{http_code}' "$(dsp_url)$2" 2>&1) || { api_timed_out $? && api_unanswered "$1" 30 || echo "$out"; return 1; }
    code=${out##*$'\n'}; echo "${out%$'\n'*}"
    [[ "$code" =~ ^2 ]]
}
dsp_ready() { http_ready dispatcharr "$(dsp_url)/api/core/version/" '^200$'; }
dsp_login() { # dsp_login [USER PASS] -> a token for the stack's own admin (or USER); rc 1, the reason in its place
    # Dispatcharr allows 3 sign-ins a minute from one address (password and header alike)
    local u=${1-$(env_get DISPATCHARR_ADMIN_USER)} p=${2-$(env_get DISPATCHARR_ADMIN_PASSWORD)} out tok
    out=$(dsp_api POST /api/accounts/token/ "" "$(jq -cn --arg u "$u" --arg p "$p" '{username:$u, password:$p}')") || {
        if [[ "$out" == *"Too many login attempts"* || "$out" == *throttled* ]]; then echo "dispatcharr allows 3 sign-ins a minute from one address — try again in a minute"
        else echo "dispatcharr rejected the stored admin login: $(oneline "$out")"; fi
        return 1; }
    tok=$(jq -r '.access // empty' <<<"$out")
    [[ -n "$tok" ]] || { echo "dispatcharr's login returned no token"; return 1; }
    echo "$tok"
}

# ---- before its first start (provision runs <service>_provision) ----
# Its start script runs as root and makes two things root's that doctor
# would call mis-owned config: uploads/ (a mkdir -p of its subfolders —
# upstream, docs/watchlist.md) and jwt (its token-signing key, made when
# missing). Made here first, they are its own; it reads jwt as root either
# way. A new key: delete jwt, then up (everyone signed in signs in again).
dispatcharr_provision() {
    local d uid
    d="$(env_get CONFIG_ROOT)/dispatcharr"; uid=$(env_get DISPATCHARR_UID)
    [[ -n "$uid" ]] || return 0
    sudo sh -c 'test -e "$1" || { mkdir "$1" && chown "$2:mediacenter" "$1"; }' _ "$d/uploads" "$uid" </dev/null
    if ! sudo test -e "$d/jwt"; then
        gen_secret 86 | sudo sh -c 'umask 077; cat > "$1" && chown "$2:mediacenter" "$1"' _ "$d/jwt" "$uid"
    fi
}

# ---- wire: the stack's own admin, then its header sign-in ----
wire_dispatcharr() {
    hr "wire: dispatcharr"
    svc_enabled dispatcharr || { info "dispatcharr not enabled — skipped"; return 0; }
    wire_gate dispatcharr
    dsp_ready || return 0
    local st user pass out tok
    st=$(dsp_api GET /api/accounts/initialize-superuser/ "") || { wfail "dispatcharr: first-run state unreadable: $(oneline "$st")"; return 0; }
    user=$(env_get DISPATCHARR_ADMIN_USER); pass=$(env_get DISPATCHARR_ADMIN_PASSWORD)
    if [[ "$(jq -r '.superuser_exists' <<<"$st")" == false ]]; then
        w_would "create Dispatcharr's admin — the stack's own (see: credentials)" || return 0
        [[ -n "$user" && -n "$pass" ]] \
            || { wfail "dispatcharr's admin login is not in .env (DISPATCHARR_ADMIN_USER / DISPATCHARR_ADMIN_PASSWORD) — ./mediastack.sh up records one, then re-run wire"; return 0; }
        out=$(dsp_api POST /api/accounts/initialize-superuser/ "" "$(jq -cn --arg u "$user" --arg p "$pass" '{username:$u, password:$p}')") \
            || { wfail "dispatcharr refused its first-run setup: $(oneline "$out")"; return 0; }
        jq -e '.superuser_exists == true' <<<"$out" >/dev/null || { wfail "dispatcharr's first-run setup answered without an admin: $(oneline "$out")"; return 0; }
        ok "dispatcharr: admin '$user' created (the stack's own — admins reach it through the portal)"
    elif [[ "$(jq -r '.superuser_exists' <<<"$st")" != true ]]; then
        wfail "dispatcharr: its first-run state reads neither way: $(oneline "$st")"; return 0
    elif [[ -z "$user" || -z "$pass" ]]; then
        wfail "dispatcharr was set up by hand and its admin login is not in .env. Either put it there (DISPATCHARR_ADMIN_USER / DISPATCHARR_ADMIN_PASSWORD), or start it fresh — this deletes its sources, channels and guide:
       ./mediastack.sh disable dispatcharr && sudo mv \"$(env_get CONFIG_ROOT)/dispatcharr\" \"$(env_get CONFIG_ROOT)/dispatcharr.old\" && ./mediastack.sh enable dispatcharr"
        return 0
    fi
    (( WIRE_DRY )) && [[ -z "$pass" ]] && return 0
    tok=$(dsp_login) || { wfail "$tok"; return 0; }
    ok "dispatcharr: admin login works"
    dsp_signin "$tok"
}

dsp_signin_want() { # -> the header sign-in Dispatcharr should hold (its reverse_proxy_auth value): on while the portal guards it, off otherwise
    if gate_trusted dispatcharr; then jq -cn --arg h "$DSP_HEADER" '{enabled: true, header: $h}'
    else echo '{"enabled":false,"header":""}'; fi
}
dsp_signin_words() { if jq -e '.enabled' <<<"$1" >/dev/null; then echo "on (Traefik's $DSP_HEADER, past the gate)"; else echo off; fi; }

# The stack owns this one setting both ways: on with another header, a header
# Traefik never sets would be believed from it — anyone past a route without
# the portal could name the admin. Put back, said, and proven.
dsp_signin() { # dsp_signin TOKEN — its header sign-in follows the gate, read back; then proven: the header from this host signs nobody in
    local tok=$1 rows id cur want out code
    rows=$(dsp_api GET /api/core/settings/ "$tok") || { wfail "dispatcharr: its settings are unreadable: $(oneline "$rows")"; return 0; }
    id=$(jq -r '.[] | select(.key == "reverse_proxy_auth") | .id' <<<"$rows")
    [[ -n "$id" ]] || { wfail "dispatcharr: it has no reverse_proxy_auth setting (renamed in a release?) — its header sign-in left as it is"; return 0; }
    cur=$(jq -c '.[] | select(.key == "reverse_proxy_auth") | .value' <<<"$rows")
    want=$(dsp_signin_want)
    if jq -e --argjson w "$want" 'if $w.enabled then (.enabled == true and .header == $w.header) else .enabled != true end' <<<"$cur" >/dev/null; then
        ok "dispatcharr: header sign-in $(dsp_signin_words "$want")"
    else
        w_would "dispatcharr: header sign-in $(dsp_signin_words "$want") (it held $(jq -c . <<<"$cur"))" || return 0
        out=$(dsp_api PATCH "/api/core/settings/$id/" "$tok" "$(jq -cn --argjson v "$want" '{value: $v}')") \
            || { wfail "dispatcharr refused its header sign-in setting: $(oneline "$out")"; return 0; }
        out=$(dsp_api GET "/api/core/settings/$id/" "$tok") || { wfail "dispatcharr: its header sign-in setting is unreadable after the change: $(oneline "$out")"; return 0; }
        jq -e --argjson w "$want" '.value.enabled == $w.enabled and (($w.enabled | not) or .value.header == $w.header)' <<<"$out" >/dev/null \
            || { wfail "dispatcharr: its header sign-in did not hold: $(oneline "$out")"; return 0; }
        ok "dispatcharr: header sign-in $(dsp_signin_words "$want")"
    fi
    # proven from this host — an address that is not Traefik's: refused (401), whatever the setting
    code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -X POST -H "$DSP_HEADER: $(env_get DISPATCHARR_ADMIN_USER)" \
           "$(dsp_url)/api/accounts/auth/proxy-login/" 2>/dev/null) || true   # soft read: curl prints 000 when nothing answers, judged below
    if [[ "$code" == 401 ]]; then ok "dispatcharr: its header signs nobody in from anywhere but Traefik"
    else wfail "dispatcharr: its header from this host answered HTTP $code, not 401 — it believes more than Traefik: check DISPATCHARR_TRUSTED_PROXIES in its container (./mediastack.sh up recreates it)"; fi
}

dispatcharr_gate_login() { # `disable authentik` (GATE_UNTRUSTED=1): its header sign-in off before its port reopens, proven — a failure counts in WIRE_FAILS
    local tok
    tok=$(dsp_login) || { wfail "$tok"; return 0; }
    dsp_signin "$tok"
}

# Traefik's dispatcharr-login (mediastack.auth.inject): past the gate, the
# header names the stack's admin. Without the portal it is removed instead
# (an empty value), so a client's own copy never reaches Dispatcharr — wire
# has its header sign-in off then too. Decided from .env (gate_planned).
dispatcharr_login_middleware() {
    local v=""
    if svc_enabled dispatcharr && gate_planned dispatcharr; then v=$(env_get DISPATCHARR_ADMIN_USER); fi
    printf '    dispatcharr-login:\n      headers:\n        customRequestHeaders:\n          %s: "%s"\n' "$DSP_HEADER" "$v"
}

sc_explain_dispatcharr() { echo "The admin is the stack's own account; with the portal, admins are signed in
as it. Only this password and .env move."; }   # set-credentials dispatcharr (lib/access.sh)
dispatcharr_credentials() { # credentials (lib/access.sh)
    signin_is authentik && info "With the portal, admins are signed in to Dispatcharr as that admin — its password is the way in without the portal."
    return 0
}
sc_rotate_dispatcharr() { # PASS — its admin (the stack's own), changed signed in with the old one, then proven
    svc_enabled dispatcharr || { info "dispatcharr not enabled — skipped"; return 0; }
    local new="$1" user old out tok
    user=$(env_get DISPATCHARR_ADMIN_USER); old=$(env_get DISPATCHARR_ADMIN_PASSWORD)
    [[ -n "$user" && -n "$old" ]] || die "no Dispatcharr admin stored — run 'wire dispatcharr' first"
    tok=$(dsp_login "$user" "$old") || die "$tok — is .env stale?"
    out=$(dsp_api PATCH /api/accounts/users/me/ "$tok" "$(jq -cn --arg p "$new" '{password:$p}')") \
        || die "Dispatcharr refused the password change: $(oneline "$out")"
    env_set DISPATCHARR_ADMIN_PASSWORD "$new"   # changed: the new one is the truth from here, verified or not
    dsp_login "$user" "$new" >/dev/null \
        || die "Dispatcharr's admin password changed (stored in .env), but signing in with it failed"
    ok "Dispatcharr admin password rotated and verified"
}
