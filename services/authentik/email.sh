#!/usr/bin/env bash
# services/authentik/email.sh — the portal's outgoing email (SMTP): the
# settings' checks, `email status|test`, and what doctor reads. configure asks
# the settings (lib/configure.sh); compose hands them to authentik
# (compose.yml beside this file). Sourced by the entrypoint.

# The portal sends through any SMTP server (docs/email.md). authentik reads
# its settings when it starts: a change takes effect at the next `up`, and
# `email test` refuses while the running authentik has older ones.
EMAIL_WORKER_WAIT=300   # seconds email test waits for authentik's worker after a start (its migrations run first)
SMTP_KEYS=(SMTP_HOST SMTP_PORT SMTP_STARTTLS SMTP_TLS SMTP_USER SMTP_PASSWORD SMTP_FROM)
# .env key -> what authentik's containers carry (services/authentik/compose.yml)
declare -A SMTP_AK=([SMTP_HOST]=AUTHENTIK_EMAIL__HOST [SMTP_PORT]=AUTHENTIK_EMAIL__PORT [SMTP_USER]=AUTHENTIK_EMAIL__USERNAME
                    [SMTP_PASSWORD]=AUTHENTIK_EMAIL__PASSWORD [SMTP_STARTTLS]=AUTHENTIK_EMAIL__USE_TLS
                    [SMTP_TLS]=AUTHENTIK_EMAIL__USE_SSL [SMTP_FROM]=AUTHENTIK_EMAIL__FROM)

smtp_configured() { [[ -n "$(env_get SMTP_HOST)" ]]; }

smtp_problems() { # -> one line per thing wrong with the email settings (none: they can be tried)
    local pw; pw=$(env_get SMTP_PASSWORD)
    [[ -n "$(env_get SMTP_PORT)" ]] || echo "SMTP_PORT is empty — 587 (STARTTLS), 465 (TLS) or 25 (a LAN relay)"
    [[ -n "$(env_get SMTP_FROM)" ]] || echo "SMTP_FROM is empty — the address mail comes from"
    [[ "$(env_get SMTP_STARTTLS)" == true && "$(env_get SMTP_TLS)" == true ]] \
        && echo "SMTP_STARTTLS and SMTP_TLS are both true — a server speaks one: STARTTLS on 587, TLS on 465"
    [[ -n "$(env_get SMTP_USER)" && -z "$pw" ]] && echo "SMTP_USER is set but SMTP_PASSWORD is empty"
    [[ "$pw" =~ [\$[:space:]] ]] && echo "SMTP_PASSWORD holds a \$ or a space — compose would rewrite it; use an app password or SMTP key (Gmail shows its app passwords in groups of four: type it without the spaces)"
    return 0
}

smtp_fingerprint() { local k v=""; for k in "${SMTP_KEYS[@]}"; do v+="$(env_get "$k")|"; done; sha256sum <<<"$v" | cut -c1-16; }

smtp_live_stale() { # -> the settings the running authentik does not have yet (names only, never values)
    local envs k want have
    envs=$(sudo docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$(svc_cname authentik-worker)" 2>/dev/null) || return 0
    for k in "${SMTP_KEYS[@]}"; do
        want=$(env_get "$k")
        case "$k" in SMTP_HOST) want=${want:-localhost} ;; SMTP_PORT) want=${want:-25} ;;   # addr-ok: authentik's own defaults, not app-to-app
                     SMTP_STARTTLS|SMTP_TLS) want=${want:-false} ;; SMTP_FROM) want=${want:-authentik@localhost} ;; esac   # addr-ok: authentik's own defaults, not app-to-app
        have=$(grep -m1 "^${SMTP_AK[$k]}=" <<<"$envs" | cut -d= -f2-)
        [[ "$have" == "$want" ]] || echo "$k"
    done
}

smtp_hint() { # smtp_hint ERROR-TEXT -> what usually causes it
    case "${1,,}" in
        *authentication*|*"535"*|*"534"*|*username*|*credentials*)
            echo "the server refused the login — check SMTP_USER and SMTP_PASSWORD (Gmail and Fastmail need an app password, not your normal one)" ;;
        *"wrong version number"*|*ssl*|*tls*|*certificate*)
            echo "the encryption does not match the port — 587 takes STARTTLS, 465 takes TLS (./mediastack.sh configure)" ;;
        *"timed out"*|*timeout*|*"connection refused"*|*unreachable*|*"name or service not known"*|*"temporary failure in name resolution"*)
            echo "the server could not be reached — check SMTP_HOST and SMTP_PORT; many home connections block port 25 outbound (use 587 or 465)" ;;
        *sender*|*"not owned"*|*"not allowed"*|*"550"*|*"553"*|*"554"*)
            echo "the server refused the sender — SMTP_FROM must be an address this login may send as (a verified domain or your mailbox)" ;;
        *) echo "see docs/email.md (Troubleshooting) for the server's message above" ;;
    esac
}

cmd_email() { # email [status|test <address>]
    load_env; render
    local sub=${1:-status}
    svc_enabled authentik || die "the portal (authentik) is not enabled — nothing here sends email"
    case "$sub" in
        status)
            smtp_configured || { info "Email: off — set it up: ./mediastack.sh configure (docs/email.md)"; return 0; }
            info "Email: $(env_get SMTP_HOST):$(env_get SMTP_PORT) $( [[ "$(env_get SMTP_STARTTLS)" == true ]] && echo STARTTLS || { [[ "$(env_get SMTP_TLS)" == true ]] && echo TLS || echo unencrypted; } ), from $(env_get SMTP_FROM)$( [[ -n "$(env_get SMTP_USER)" ]] && echo ", login $(env_get SMTP_USER)" )"
            local p; p=$(smtp_problems); [[ -z "$p" ]] || { while IFS= read -r l; do fail "$l"; done <<<"$p"; }
            [[ "$(state_get SMTP_TESTED)" == "$(smtp_fingerprint)" ]] && ok "these settings passed a test" \
                || warn "these settings have not passed a test yet: ./mediastack.sh email test <your address>" ;;
        test)
            local to=${2:-} p stale out
            [[ "$to" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "usage: email test <address>   (where the test message goes)"
            smtp_configured || die "email is not set up — ./mediastack.sh configure (docs/email.md)"
            p=$(smtp_problems); [[ -z "$p" ]] || die "the email settings cannot work yet:
$(sed 's/^/  /' <<<"$p")"
            [[ "$(c_state "$(svc_cname authentik-worker)")" == running ]] || die "authentik's worker is not running — ./mediastack.sh up"
            # a send queued before the worker is up is not lost: it goes out
            # later, after the command has given up (found live: two mails)
            local waited=0
            if [[ "$(c_health "$(svc_cname authentik-worker)")" != healthy ]]; then
                info "authentik's worker is still starting (it runs its migrations first) — waiting up to $((EMAIL_WORKER_WAIT / 60)) min..."
                while [[ "$(c_health "$(svc_cname authentik-worker)")" != healthy ]]; do
                    (( waited >= EMAIL_WORKER_WAIT )) && die "authentik's worker did not become healthy — ./mediastack.sh status authentik; its log: ./mediastack.sh logs authentik-worker --no-follow"
                    sleep 5; waited=$((waited + 5))
                done
            fi
            stale=$(smtp_live_stale)
            [[ -z "$stale" ]] || die "authentik still runs older email settings ($(tr '\n' ' ' <<<"$stale" | sed 's/ $//')) — it reads them when it starts: ./mediastack.sh up, then test again"
            info "sending a test message to $to through $(env_get SMTP_HOST):$(env_get SMTP_PORT)..."
            if out=$(sudo docker exec -e USER=mediastack "$(svc_cname authentik-worker)" ak test_email "$to" 2>&1) \
                && grep -q "Test email sent" <<<"$out"; then
                state_set SMTP_TESTED "$(smtp_fingerprint)"
                ok "sent — check $to (and its spam folder; a message that lands there needs SPF/DKIM for $(env_get SMTP_FROM | cut -d@ -f2): docs/email.md)"
            elif grep -q ResultTimeout <<<"$out"; then
                # the command stopped waiting; the worker may still send it
                die "authentik's worker did not finish the send within the command's wait. It may still go out — check $to before testing again. What it did: ./mediastack.sh logs authentik-worker --no-follow | grep -iE 'email_sent|send_mail|smtp'"
            else
                fail "the server did not take it: $(ak_cmd_why "$out" | cut -c1-300)"
                die "$(smtp_hint "$out")"
            fi ;;
        *) die "usage: email [status|test <address>]" ;;
    esac
}
