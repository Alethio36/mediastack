#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-env.sh — .env against its schema (lib/env.schema.tsv).
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
while IFS=$'\t' read -r k t e w m; do
    [[ -n "$m" && "$e" =~ ^(ok|no)$ && "$w" =~ ^(you|wizard|script|advanced|-)$ ]] || fail_ "malformed schema row: $k"
    [[ "$t" == retired:* || "$(env_type_expect "$t")" != "?" ]] || fail_ "$k: unknown type $t"
done < <(env_schema_rows); pass
[[ -z "$(env_schema_rows | cut -f1 | sort | uniq -d)" ]] || fail_ "a key appears twice in the schema"; pass

# ---- every key the code reads is in the schema ----
# (a literal name only: "TRASH_PROFILE_$x" and "$VAR" are built at runtime — their families are checked below)
mapfile -t read_by_script < <(grep -ohE 'env_(get|set) "?[A-Z][A-Z0-9_]+([" )]|$)' mediastack.sh lib/*.sh \
                              | sed -E 's/env_(get|set) "?//; s/[" )]$//' | grep -vx VAR | sort -u)
missing=$(comm -23 <(printf '%s\n' "${read_by_script[@]}" | sort -u) <(known_of "${read_by_script[@]}" | sort -u) | tr '\n' ' ')
[[ -z "$missing" ]] || fail_ "the script reads keys the schema does not hold: $missing"; pass
mapfile -t read_by_compose < <(grep -ohE '\$\{[A-Z][A-Z0-9_]+' docker-compose.yml compose.d/*.yml | cut -c3- | sort -u)
missing=$(comm -23 <(printf '%s\n' "${read_by_compose[@]}" | sort -u) <(known_of "${read_by_compose[@]}" | sort -u) | tr '\n' ' ')
[[ -z "$missing" ]] || fail_ "compose files read keys the schema does not hold: $missing"; pass

# ---- .env.example against the schema ----
ENV_FILE=.env.example
env_validate || fail_ ".env.example has values the schema refuses"; pass
[[ "$(env_get ENV_SCHEMA)" == "$SCRIPT_SCHEMA" ]] || fail_ ".env.example says ENV_SCHEMA=$(env_get ENV_SCHEMA), the script is $SCRIPT_SCHEMA"; pass
missing=""
while IFS=$'\t' read -r k t e w m; do
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
printf 'RECYCLE_DAYS=abc\nUPDATE_DEFER_ACTION=skip   # note\nARR_PASSWORD="s3cret pass"\nNOTIFY_GRACE=\nAUDIT_KEEP_DAYS=365\nRECYCLE_ROOT=\n' > "$ENV_FILE"
out=$( (env_validate) 2>&1 ) && fail_ "bad values must stop the command"
[[ "$out" == *"RECYCLE_DAYS='abc' is not a whole number"* ]] || fail_ "type problem: $out"; pass
[[ "$out" == *"UPDATE_DEFER_ACTION='skip   # note' has a comment after the value"* ]] || fail_ "inline comment: $out"; pass
[[ "$out" == *"ARR_PASSWORD=(hidden) is quoted"* && "$out" != *s3cret* ]] || fail_ "a secret must never be shown: $out"; pass
[[ "$out" == *"NOTIFY_GRACE is empty"* && "$out" != *RECYCLE_ROOT* && "$out" != *AUDIT_KEEP_DAYS* ]] || fail_ "empty: only where the schema says no: $out"; pass

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

echo "OK env: $checks checks"
