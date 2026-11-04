#!/usr/bin/env bash
# services/authentik/questions.sh — the portal's questions: the questionnaire's
# authentik_questions hook (docs/design-install.md) — its name, then its email
# (authentik_configure_email, email.sh). They ask and record only. Sourced by
# the entrypoint; relies on lib/common.sh and lib/questionnaire.sh at call time.

authentik_questions() {
    if q_quick && [[ "$(env_get PORTAL_TITLE)" =~ [^[:space:]] ]]; then
        env_set PORTAL_TITLE "$(env_get PORTAL_TITLE)"; q_took "Portal name" "$(env_get PORTAL_TITLE)"
    else
        explain "The portal's name" \
"authentik is the portal your users sign up and log in at. Its name is shown
on the login and sign-up pages (\"Join <name>\")."
        while true; do
            ask PORTAL_TITLE "Portal name" "$(env_get PORTAL_TITLE)"
            [[ "$REPLY_VAL" =~ [^[:space:]] ]] && break
            fail "The portal needs a name."
        done
        env_set PORTAL_TITLE "$REPLY_VAL"
    fi
    authentik_configure_email
}
