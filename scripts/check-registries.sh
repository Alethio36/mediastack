#!/usr/bin/env bash
# check-registries.sh — a verb that covers several services keeps an explicit,
# ordered list of them; each listed name's part lives with its service. This
# fails a listed name without exactly one matching function under services/
# (or with one defined outside it), a <service>_* function a lib calls by
# name that nothing defines, a service's hook outside its folder or found by
# a name no service has, and an app behind the portal without its icon (or
# an icon that does not say where it is from). The contributor's recipe
# (docs/contributing-a-service.md) names each rule where it applies.
#
#   scripts/check-registries.sh     run (exit 1 on any gap, every gap listed)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

rc=0
want_one() { # want_one <list name> <function>
    local n
    n=$({ grep -lE "^$2\(\)" services/*/*.sh || true; } | wc -l)   # none found is a count, not an error
    [[ "$n" == 1 ]] || { echo "FAIL $1: $n definitions of $2() under services/ (want 1)"; rc=1; }
    if grep -qE "^$2\(\)" lib/*.sh mediastack.sh; then echo "FAIL $1: $2() is defined outside services/"; rc=1; fi
}
list() { # list <file> <sed expression printing the list's words>
    local words; words=$(sed -n "$2" "$1")
    [[ -n "$words" ]] || { echo "FAIL the list in $1 was not found"; rc=1; }
    echo "$words"
}

# wire: WIRE_ROLES -> wire_<role>
for r in $(list lib/wire.sh 's/^WIRE_ROLES=(\(.*\))$/\1/p'); do want_one WIRE_ROLES "wire_$r"; done
# set-credentials: each login a service declares (<stem>_logins) is a target —
# its target= option, else the stem — rotated by sc_rotate_<target>; the
# portal's admin is the verb's own target. A rotation, an explanation
# (sc_explain_<target>) or a credentials hook (<service>_credentials, <service>_api_key)
# with no login or service behind it is never reached.
targets=" portal "
while IFS=: read -r _ line; do
    stem=${line%%_logins()*}
    t=$(sed -nE 's/.*target=([a-z0-9_]+).*/\1/p' <<<"$line"); t=${t:-$stem}
    want_one "set-credentials (${stem}_logins)" "sc_rotate_$t"; targets+="$t "
done < <(grep -hnE '^[a-z0-9_]+_logins\(\)' services/*/*.sh)
[[ "$targets" == *" arr "* ]] || { echo "FAIL set-credentials: no <stem>_logins line read — the services were not read"; rc=1; }
for f in $(grep -hoE '^sc_(rotate|explain)_[a-z0-9_]+\(\)' services/*/*.sh | sed 's/()$//'); do
    t=${f#sc_rotate_}; t=${t#sc_explain_}
    [[ "$targets" == *" $t "* ]] || { echo "FAIL ${f}() exists, but no login names the target $t (a <stem>_logins line, or target=$t on one) — set-credentials never runs it"; rc=1; }
done
for f in $(grep -hoE '^[a-z0-9_]+_(credentials|api_key)\(\)' services/*/*.sh | sed 's/()$//'); do
    s=${f%_credentials}; s=${s%_api_key}
    [[ -d "services/${s//_/-}" ]] || { echo "FAIL ${f}() exists, but there is no service ${s//_/-} — credentials never prints it"; rc=1; }
done
# rotate-secrets: ROTATE_ORDER -> <stem>_secrets and <stem>_secret_rotate
for s in $(list lib/rotate.sh 's/^ROTATE_ORDER=(\(.*\))$/\1/p'); do
    want_one ROTATE_ORDER "${s}_secrets"; want_one ROTATE_ORDER "${s}_secret_rotate"
done
# port forwarding: every torrent client (mediastack.torrent) takes the forwarded port — <client>_listen_port
for s in $(grep -l 'mediastack.torrent: "true"' services/*/compose.yml | sed 's|services/||; s|/compose.yml||'); do want_one mediastack.torrent "${s//-/_}_listen_port"; done
# people-sync: an app people sign in to (mediastack.auth native, or a household
# gate's mediastack.auth.group) says what happens to their accounts —
# mediastack.people follow (its <svc>_people_follow), none (a comment says
# why) or source (where people come from); a follow function needs the label
people_rows() { # -> svc|auth|group|people|comment(yes or no), one per service in services/*/compose.yml ("|": read keeps empty fields)
    awk '
        function out() { if (svc != "") printf "%s|%s|%s|%s|%s\n", svc, auth, grp, ppl, cmt }
        /^services:/ { ins = 1; next }
        /^[^ #]/ { out(); svc = ""; ins = 0; next }
        ins && /^  [a-z0-9-]+:[ ]*$/ { out(); svc = $1; sub(/:$/, "", svc); auth = grp = ppl = ""; cmt = "no"; next }
        svc != "" && /mediastack\.auth: / { v = $0; sub(/.*mediastack\.auth: "/, "", v); sub(/".*/, "", v); auth = v }
        svc != "" && /mediastack\.auth\.group: / { v = $0; sub(/.*mediastack\.auth\.group: "/, "", v); sub(/".*/, "", v); grp = v }
        svc != "" && /mediastack\.people: / { v = $0; sub(/.*mediastack\.people: "/, "", v); sub(/".*/, "", v); ppl = v; cmt = ($0 ~ /" *#/) ? "yes" : "no" }
        END { out() }' services/*/compose.yml
}
followers=0
while IFS='|' read -r s auth grp ppl cmt; do
    case "$ppl" in
        follow) want_one mediastack.people "${s//-/_}_people_follow"; followers=$((followers+1)) ;;
        none)   [[ "$cmt" == yes ]] || { echo "FAIL mediastack.people: $s says none without a comment saying why"; rc=1; } ;;
        source) ;;
        "")     if [[ "$auth" == native || -n "$grp" ]]; then
                    echo "FAIL mediastack.people: people sign in to $s, but it does not say what happens to their accounts — label it follow, none (with why) or source"; rc=1
                fi ;;
        *)      echo "FAIL mediastack.people: $s says '$ppl' — follow, none or source"; rc=1 ;;
    esac
done < <(people_rows)
(( followers )) || { echo "FAIL mediastack.people: no service follows the portal — the compose files were not read"; rc=1; }
for f in $(grep -hoE '^[a-z0-9_]+_people_follow\(\)' services/*/*.sh | sed 's/()$//'); do
    s=${f%_people_follow}
    people_rows | awk -F'|' -v s="$s" '{ n = $1; gsub(/-/, "_", n) } n == s && $4 == "follow" { f = 1 } END { exit !f }' \
        || { echo "FAIL mediastack.people: ${f}() exists, but no service named ${s//_/-} is labelled follow — people-sync would never run it"; rc=1; }
done
# disable authentik: a tool that drops its login behind the gate (gate_trusted
# <svc>, by name) brings <svc>_gate_login, which puts it back before the ports
# reopen — the arrs and Prowlarr (arr_login) have their own loop there
for s in $(find services -name '*.sh' ! -path 'services/authentik/*' -exec grep -hoE 'gate_(trusted|planned) [a-z0-9-]+' {} + | awk '{print $2}' | sort -u); do   # authentik's folder defines them
    want_one "gate_trusted/planned $s" "${s//-/_}_gate_login"
done
# a route that adds a tool's login past the gate (mediastack.auth.inject: true)
# names <svc>-login, which its <svc>_login_middleware defines; a hook without
# the label is never on a route
for f in services/*/compose.yml; do
    s=$(basename "$(dirname "$f")")
    if grep -qE '^\s*mediastack\.auth\.inject: "true"' "$f"; then want_one "mediastack.auth.inject $s" "${s//-/_}_login_middleware"
    elif grep -qE "^${s//-/_}_login_middleware\(\)" services/*/*.sh; then echo "FAIL ${s//-/_}_login_middleware() exists, but $s has no mediastack.auth.inject: \"true\" — no route would use it"; rc=1; fi
done
# a portal card's path (mediastack.card.path) follows the app's address, so it
# starts with "/" (svc_card_url)
for f in services/*/compose.yml; do
    p=$(sed -n 's/^[[:space:]]*mediastack\.card\.path: "\(.*\)".*/\1/p' "$f")
    [[ -z "$p" || "$p" == /* ]] || { echo "FAIL mediastack.card.path in $f is \"$p\": it follows the app's address, so it starts with /"; rc=1; }
done
# a hook belongs to its service: <svc>_<hook> lives in services/<svc>/ (the
# arr family's in services/_arr/) — a service's part lives in its folder. A
# hook found only by its service's name (<svc>_provision, _questions,
# _summary, _gate_sync) with no service of that name is never run, unless
# something calls it by its own name (gluetun_vpn_questions, vpn_summary)
hooks='provision|questions|summary|logins|gate_sync|gate_login|login_middleware|people_follow|listen_port|credentials|api_key|doctor|secrets|secret_rotate'
while IFS=: read -r file fn; do
    fn=${fn%"()"}
    stem=$(sed -E "s/_($hooks)\$//" <<<"$fn"); dir=${stem//_/-}; [[ "$stem" == arr ]] && dir=_arr
    if [[ -d "services/$dir" ]]; then
        [[ "$file" == "services/$dir/"* ]] || { echo "FAIL ${fn}() is $dir's hook, but lives in $file — a service's part lives in its folder (services/$dir/)"; rc=1; }
    elif [[ "$fn" =~ _(provision|questions|summary|gate_sync)$ ]]; then
        n=$({ grep -rhwE "$fn" lib mediastack.sh services --include='*.sh' || true; } | { grep -vcE "^$fn\(\)" || true; })   # none is a count, not an error
        (( n > 0 )) || { echo "FAIL ${fn}() is a hook found by its service's name, but no service is named $dir and nothing calls it — it never runs (a typo in the name?)"; rc=1; }
    fi
done < <(grep -oHE "^[a-z0-9_]+_($hooks)\(\)" lib/*.sh mediastack.sh services/*/*.sh)
# a portal card shows its app's icon: every app the portal fronts
# (mediastack.auth) ships services/<svc>/icon.png — the portal itself aside —
# and every shipped icon says where it is from, as services/NOTICE-icons.md
# promises: its PNG text fields carry its source, copyright, licence, change
# and trademark note
for f in services/*/compose.yml; do
    s=$(basename "$(dirname "$f")")
    [[ "$s" != authentik ]] && grep -qE '^\s*mediastack\.auth: "' "$f" || continue
    [[ -f "services/$s/icon.png" ]] || { echo "FAIL $s is behind the portal but ships no icon.png — its card would show a letter (services/NOTICE-icons.md)"; rc=1; }
done
for i in services/*/icon.png; do
    for k in Source Copyright License Modified Trademark; do
        LC_ALL=C grep -qaE "(tEXt|iTXt|zTXt)$k" "$i" || { echo "FAIL $i carries no $k text field — every icon says where it is from (services/NOTICE-icons.md)"; rc=1; }
    done
done
# doctor: DOCTOR_APPS -> <app>_doctor
for a in $(list lib/doctor.sh 's/^DOCTOR_APPS=(\(.*\))$/\1/p'); do want_one DOCTOR_APPS "${a}_doctor"; done
# by name: a lib or the entrypoint calling <service>_<anything> (a service's
# folder name, '-' as '_') needs that function to exist — a typo or a move
# that left a caller behind would otherwise fail only when that line runs
for n in $(ls services | sed 's/^_//; s/-/_/g'); do
    for f in $(grep -hoE "\b${n}_[a-z0-9_]+\b" lib/*.sh mediastack.sh | sort -u); do
        grep -qE "^$f\(\)" services/*/*.sh lib/*.sh mediastack.sh \
            || { echo "FAIL by name: $f is called but defined nowhere"; rc=1; }
    done
done

(( rc == 0 )) && echo "OK registries: every listed name has its function under services/"
exit $rc
