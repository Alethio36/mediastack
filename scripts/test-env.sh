#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-env.sh — .env against its schema (lib/env.schema.tsv + services/*/env.tsv).
#   * the schema is well-formed, and holds every key the script or a compose
#     file reads; .env.example holds every key you or a setup step writes,
#     its values pass, and its ENV_SCHEMA is the script's
#   * values: each type accepts what it should and refuses what it should; a
#     quoted value or one with a trailing comment is refused (the script and
#     compose would read different values); secrets never appear in a message;
#     every problem is listed before the command stops
#   * a family key (<svc>_NAME) counts only for a service that exists, so a
#     variable of your own (MYAPP_DB_NAME) is never checked as a setting
#   * doctor's unknown keys: nothing reads it -> reported; a retired key says
#     since when; COMPOSE_*/DOCKER_*, anything custom/ uses, and a key marked
#     '# mediastack: ignore' on the line above are not
#   * schema 29: pending-work markers leave .env for local/state; the shipped
#     inline comment on UPDATE_DEFER_ACTION is stripped
#   * one default per setting, in the schema: env_get takes no default at the
#     call, compose's ${KEY:-x} says the schema's x (never a bare ${KEY}),
#     .env.example shows the default or nothing, a family's _HOST fallback is
#     its service's subdomain label, and empty or absent reads as the default
#
#   scripts/test-env.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-env.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }
known_of() { printf '%s=\n' "$@" > "$T/keys"; env_schema_known "$T/keys" | cut -f1; }   # which of these keys the schema knows

# ---- the schema itself ----
while IFS=$'\t' read -r k t e w d m; do
    [[ -n "$d" && -n "$m" && "$m" != *$'\t'* && "$e" =~ ^(ok|no)$ && "$w" =~ ^(you|wizard|script|advanced|-)$ ]] || fail_ "malformed schema row: $k"
    [[ "$t" == retired:* || "$(env_type_expect "$t")" != "?" ]] || fail_ "$k: unknown type $t"
    # a family's defaults differ per service; a retired key has none
    [[ "$d" == - || ( "$k" != *'<'* && "$t" != retired:* ) ]] || fail_ "$k: a family or retired key carries no default (got '$d')"
    [[ "$d" == - || "$t" == retired:* ]] || env_type_ok "$t" "$d" || fail_ "$k: its default '$d' is not a $t"
done < <(env_schema_rows); pass

# ---- one default per setting: the schema's ----
calls=$(grep -rnoE '\$\(env_get ("[^"]*"|[^ )"]+) [^)|;&<>]' mediastack.sh lib services scripts || true)
[[ -z "$calls" ]] || fail_ "env_get with a default at the call — write it in the schema instead: $calls"; pass
( ENV_FILE=$T/none.env; : > "$ENV_FILE"; [[ "$(env_get BACKUP_KEEP_DAILY)" == 7 && -z "$(env_get UPDATE_SCHEDULE)" ]] ) \
    || fail_ "absent: the schema's default, or empty when it has none"; pass
( ENV_FILE=$T/empty.env; printf 'BACKUP_KEEP_DAILY=\nBACKUP_KEEP_WEEKLY=9\n' > "$ENV_FILE"
  [[ "$(env_get BACKUP_KEEP_DAILY)" == 7 && "$(env_get BACKUP_KEEP_WEEKLY)" == 9 ]] ) || fail_ "empty reads as the default, a value as itself"; pass
( env_get BACKUP_KEEP_DAILY 5 ) >/dev/null 2>&1 && fail_ "env_get refuses a default at the call"; pass
bad=""
while IFS=$'\t' read -r k _ _ _ d _; do
    [[ "$d" != - && "$k" != *'<'* ]] || continue
    while read -r ref; do
        [[ "$ref" == "\${$k:-$d}" ]] || bad+="  $ref (schema: $d)"$'\n'
    done < <(grep -ohE "\\\$\{$k(:-[^}]*)?\}" docker-compose.yml services/*/compose.yml | sort -u)
    ex=$(grep -E "^$k=" .env.example | head -1 | cut -d= -f2- || true)
    [[ -z "$ex" || "$ex" == "$d" ]] || bad+="  .env.example $k=$ex (schema: $d)"$'\n'
done < <(env_schema_rows)
[[ -z "$bad" ]] || fail_ "compose or .env.example disagree with the schema's default:"$'\n'"$bad"; pass
# a family's _HOST: the fallback a fragment writes is its service's subdomain label
bad=""
for f in services/*/compose.yml; do
    while read -r ref; do
        k=${ref#\$\{}; k=${k%%:*}; v=${ref#*:-}; v=${v%\}}
        awk -F'\t' -v k="$k" '$1==k {f=1} END {exit !f}' <(env_schema_rows) && continue   # an exact key: checked above
        svc=""; for d in services/*/; do d=${d%/}; d=${d#services/}; [[ "$(uvar "$d")_HOST" == "$k" ]] && svc=$d; done
        grep -qE "^\s+mediastack\.subdomain: \"$v\"" "services/$svc/compose.yml" 2>/dev/null || bad+="  $f: $ref ($svc's subdomain label differs)"$'\n'
    done < <(grep -ohE '\$\{[A-Z0-9_]+_HOST:-[^}]*\}' "$f" | sort -u)
done
[[ -z "$bad" ]] || fail_ "a _HOST fallback is not its service's subdomain label:"$'\n'"$bad"; pass
[[ -z "$(env_schema_rows | cut -f1 | sort | uniq -d)" ]] || fail_ "a key appears twice in the schema"; pass

# ---- every key the code reads is in the schema ----
# (a literal name only: "TRASH_PROFILE_$x" and "$VAR" are built at runtime — their families are checked below)
mapfile -t read_by_script < <(grep -ohE 'env_(get|set) "?[A-Z][A-Z0-9_]+([" )]|$)' mediastack.sh lib/*.sh \
                              | sed -E 's/env_(get|set) "?//; s/[" )]$//' | grep -vx VAR | sort -u)
missing=$(comm -23 <(printf '%s\n' "${read_by_script[@]}" | sort -u) <(known_of "${read_by_script[@]}" | sort -u) | tr '\n' ' ')
[[ -z "$missing" ]] || fail_ "the script reads keys the schema does not hold: $missing"; pass
mapfile -t read_by_compose < <(grep -ohE '\$\{[A-Z][A-Z0-9_]+' docker-compose.yml services/*/compose.yml | cut -c3- | sort -u)
missing=$(comm -23 <(printf '%s\n' "${read_by_compose[@]}" | sort -u) <(known_of "${read_by_compose[@]}" | sort -u) | tr '\n' ' ')
[[ -z "$missing" ]] || fail_ "compose files read keys the schema does not hold: $missing"; pass

# ---- .env.example against the schema ----
ENV_FILE=.env.example
env_validate || fail_ ".env.example has values the schema refuses"; pass
[[ "$(env_get ENV_SCHEMA)" == "$SCRIPT_SCHEMA" ]] || fail_ ".env.example says ENV_SCHEMA=$(env_get ENV_SCHEMA), the script is $SCRIPT_SCHEMA"; pass
missing=""
while IFS=$'\t' read -r k t e w d m; do
    [[ "$w" =~ ^(you|wizard)$ && "$k" != *'<'* ]] || continue
    grep -qE "^$k=" .env.example || missing+="$k "
done < <(env_schema_rows)
[[ -z "$missing" ]] || fail_ "settings you or a setup step write, missing from .env.example: $missing"; pass
unknown=$(env_unknown | cut -f1 | tr '\n' ' ')
[[ -z "$unknown" ]] || fail_ ".env.example holds keys the schema does not: $unknown"; pass

# ---- types ----
good() { env_type_ok "$1" "$2" || fail_ "$1 must accept '$2'"; pass; }
bad()  { if env_type_ok "$1" "$2"; then fail_ "$1 must refuse '$2'"; fi; pass; }
good int 0; good int 30; bad int -1; bad int 3x; good pint 1; bad pint 0
good pct 100; bad pct 101; good bool true; bad bool yes; good port 8080; bad port 70000; bad port 0
good size 10m; good size 512K; bad size 10mb; good dirname movies-4k; bad dirname a/b
good 'enum:proceed|skip' skip; bad 'enum:proceed|skip' 'skip   # note'; good host notify; good host tv.home; bad host Notify
good domain media.example.com; bad domain example; good email a@b.co; bad email a@b; good url https://x.y; bad url x.y
good cname mediastack-radarr; bad cname 'my app'; good profiles gluetun,radarr-4k; bad profiles 'gluetun, radarr'
good tz Etc/UTC; bad tz Nowhere/Atlantis; good path /srv/media; good path './data'; bad path ' /srv'
if command -v systemd-analyze >/dev/null; then good calendar '*-*-* 03:30'; bad calendar 'every day'; fi

# ---- values in a .env ----
ENV_FILE=$T/.env
printf 'RECYCLE_DAYS=abc\nUPDATE_DEFER_ACTION=skip   # note\nARR_PASSWORD="s3cret pass"\nNOTIFY_GRACE=\nCONFIG_ROOT=\nAUDIT_KEEP_DAYS=365\nRECYCLE_ROOT=\n' > "$ENV_FILE"
out=$( (env_validate) 2>&1 ) && fail_ "bad values must stop the command"
[[ "$out" == *"RECYCLE_DAYS='abc' is not a whole number"* ]] || fail_ "type problem: $out"; pass
[[ "$out" == *"UPDATE_DEFER_ACTION='skip   # note' has a comment after the value"* ]] || fail_ "inline comment: $out"; pass
[[ "$out" == *"ARR_PASSWORD=(hidden) is quoted"* && "$out" != *s3cret* ]] || fail_ "a secret must never be shown: $out"; pass
# empty is fine where the schema allows it or has a default (NOTIFY_GRACE: 30); only a required key without one is a problem
[[ "$out" == *"CONFIG_ROOT is empty"* && "$out" != *NOTIFY_GRACE* && "$out" != *RECYCLE_ROOT* && "$out" != *AUDIT_KEEP_DAYS* ]] || fail_ "empty: only a required key without a default: $out"; pass

# ---- family keys: only for services that exist ----
DROPIN_DIR=$T/custom/compose.d; OVERRIDE_FILE=$T/custom/override.yml; CUSTOM_DIR=$T/custom; mkdir -p "$DROPIN_DIR"
printf 'services:\n  myapp:\n    image: x\n    environment:\n      - KEY=${MYAPP_API_KEY}\n' > "$DROPIN_DIR/myapp.yml"
printf 'MYAPP_PORT=8080\nMYAPP_DB_NAME=my db\nRADARR_4K_NAME=mediastack-radarr-4k\nNOSUCH_NAME=x\n' > "$ENV_FILE"
[[ "$(known_of MYAPP_PORT MYAPP_DB_NAME RADARR_4K_NAME NOSUCH_NAME | tr '\n' ' ')" == "MYAPP_PORT RADARR_4K_NAME " ]] \
    || fail_ "family keys: $(known_of MYAPP_PORT MYAPP_DB_NAME RADARR_4K_NAME NOSUCH_NAME | tr '\n' ' ')"; pass
env_validate || fail_ "a variable of your own must never be checked as a setting"; pass

# ---- doctor's unknown keys ----
printf 'RECYLE_DAYS=3\nMYAPP_API_KEY=k\nCOMPOSE_HTTP_TIMEOUT=120\n# mediastack: ignore\nMY_NOTE=x\nERSATZTV_UID=1\nNOSUCH_NAME=x\n# mediastack: ignore\n\nLATER=1\n' > "$ENV_FILE"
got=$(env_unknown | tr '\t\n' ': ')
[[ "$got" == "RECYLE_DAYS:unknown ERSATZTV_UID:retired:3 NOSUCH_NAME:unknown LATER:unknown " ]] \
    || fail_ "unknown keys (a mark covers only the line right below it): $got"; pass

# ---- schema 29 ----
LOCAL_DIR=$T/local; STATE_DIR=$T/local/state; ENV_BACKUP_DIR=$T/local/env-backups; info() { :; }
printf 'ENV_SCHEMA=28\nWIRE_REPOINT=apprise radarr\nUID_HANDOVER=kavita\nUPDATE_DEFER_ACTION=skip   # proceed|skip after max deferral\nKEEP=me\n' > "$ENV_FILE"
migrate_env
[[ "$(state_get WIRE_REPOINT)" == "apprise radarr" && "$(state_get UID_HANDOVER)" == kavita ]] || fail_ "markers not moved to local/state"; pass
! grep -qE '^(WIRE_REPOINT|UID_HANDOVER)=' "$ENV_FILE" || fail_ "markers left in .env"; pass
[[ "$(env_get UPDATE_DEFER_ACTION)" == skip && "$(env_get KEEP)" == me ]] || fail_ "the inline comment must go and nothing else: $(env_get UPDATE_DEFER_ACTION)"; pass

# ---- migration 35 -> 36: TRAEFIK_DOMAIN becomes STACK_DOMAIN, in place; your custom/ files follow ----
(
    ENV_FILE=$T/m36.env; CUSTOM_DIR=$T/m36custom; WARNED=$T/m36.warn; : > "$WARNED"
    warn() { echo "$*" >> "$WARNED"; }
    printf 'ENV_SCHEMA=35\nTZ=Etc/UTC\n# writes them here (TRAEFIK_DOMAIN, ACME_EMAIL)\nTRAEFIK_DOMAIN=media.example.com\nACME_EMAIL=a@example.com\n' > "$ENV_FILE"
    mkdir -p "$CUSTOM_DIR/compose.d"
    printf 'services:\n  x:\n    labels:\n      h: "x.${TRAEFIK_DOMAIN}"\n' > "$CUSTOM_DIR/compose.d/reads.yml"
    printf 'services:\n  y:\n    image: y\n' > "$CUSTOM_DIR/compose.d/plain.yml"; cp "$CUSTOM_DIR/compose.d/plain.yml" "$T/plain.before"
    migrate_env_35_to_36
    [[ "$(sed -n 4p "$ENV_FILE")" == STACK_DOMAIN=media.example.com ]] || fail_ "the key is renamed in place, value kept: $(sed -n 4p "$ENV_FILE")"
    ! grep -qw TRAEFIK_DOMAIN "$ENV_FILE" || fail_ "no TRAEFIK_DOMAIN left in .env"
    grep -q 'x.${STACK_DOMAIN}' "$CUSTOM_DIR/compose.d/reads.yml" || fail_ "a custom file reading TRAEFIK_DOMAIN is rewritten"
    cmp -s "$CUSTOM_DIR/compose.d/plain.yml" "$T/plain.before" || fail_ "a custom file that does not read it is left alone"
    [[ $(grep -c 'rewritten to STACK_DOMAIN' "$WARNED") == 1 ]] && grep -q 'reads.yml' "$WARNED" || fail_ "each rewritten file is named, only those: $(cat "$WARNED")"
); pass
[[ "$(awk -F'\t' '$1=="TRAEFIK_DOMAIN" {print $2}' lib/env.schema.tsv)" == retired:36 ]] || fail_ "TRAEFIK_DOMAIN is retired in the schema (doctor names a leftover)"; pass

echo "OK env: $checks checks"
