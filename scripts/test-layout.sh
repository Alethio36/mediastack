#!/usr/bin/env bash
# shellcheck disable=SC2034  # path globals set here are read by the sourced code
# test-layout.sh — where things live (README: "Where things live").
#   * the schema-28 move: what you wrote lands in custom/, what the script
#     generated in local/; idempotent, finishes an interrupted run, and stops
#     (changing nothing more) when both copies of a file exist
#   * .env backups: the oldest and the newest ENV_BACKUP_KEEP-1 are kept
#   * your compose files: drop-ins in name order, then the override (so it can
#     patch a drop-in); a drop-in may not redefine a shipped service or
#     another drop-in's, must define services, and a docker-compose.override.yml
#     back at the root is refused with where it belongs
#
#   scripts/test-layout.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-layout.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }
info() { :; }

rebase() { # point every layout path at a throwaway install in $1
    SCRIPT_DIR=$1; ENV_FILE=$1/.env
    CUSTOM_DIR=$1/custom; OVERRIDE_FILE=$CUSTOM_DIR/override.yml; DROPIN_DIR=$CUSTOM_DIR/compose.d
    PROXY_DIR=$CUSTOM_DIR/proxy.d; TRASH_OVERRIDES=$CUSTOM_DIR/trash-overrides.yml
    LOCAL_DIR=$1/local; OVERLAY_FILE=$LOCAL_DIR/vpn-overlay.yml; PINS_FILE=$LOCAL_DIR/pins.yml
    WIRED_FILE=$LOCAL_DIR/wired; ENV_BACKUP_DIR=$LOCAL_DIR/env-backups
}
old_install() { # old_install DIR — the layout before schema 28
    rm -rf "$1"; mkdir -p "$1/local/proxy.d"; rebase "$1"
    printf 'ENV_SCHEMA=27\nTRAEFIK_LOCAL_PROXY=%s/local/proxy.d\nKEEP=me\n' "$1" > "$1/.env"
    echo 'services: {}' > "$1/docker-compose.override.yml"
    echo pins > "$1/.pins.yml"; : > "$1/.wired"
    echo route > "$1/local/proxy.d/nas.yml"; echo trash > "$1/local/trash-overrides.yml"
    echo overlay > "$1/local/vpn-overlay.yml"
    echo a > "$1/.env.bak.20260101000000.schema3"; echo b > "$1/.env.bak.20260202000000.schema4"
}

# ---- the move ----
I=$T/i; old_install "$I"
migrate_env
[[ "$(env_get ENV_SCHEMA)" == "$SCRIPT_SCHEMA" ]] || fail_ "schema not current: $(env_get ENV_SCHEMA)"; pass
for f in custom/override.yml custom/proxy.d/nas.yml custom/trash-overrides.yml local/pins.yml local/wired \
         local/vpn-overlay.yml local/env-backups/.env.bak.20260101000000.schema3 local/env-backups/.env.bak.20260202000000.schema4; do
    [[ -e "$I/$f" ]] || fail_ "$f missing after the move"; pass
done
for f in docker-compose.override.yml .pins.yml .wired local/proxy.d local/trash-overrides.yml .env.bak.20260101000000.schema3; do
    [[ ! -e "$I/$f" ]] || fail_ "$f still at its old place"; pass
done
[[ "$(cat "$I/custom/override.yml")" == 'services: {}' && "$(cat "$I/local/pins.yml")" == pins ]] || fail_ "contents changed in the move"; pass
[[ -z "$(env_get TRAEFIK_LOCAL_PROXY)" && "$(env_get KEEP)" == me ]] || fail_ "only the dead TRAEFIK_LOCAL_PROXY may leave .env"; pass
[[ $(find "$I/local/env-backups" -name '.env.bak.*schema27' | wc -l) == 1 ]] || fail_ "the migration's own .env backup is not in local/env-backups"; pass

# ---- interrupted: a half-done move finishes on the next run ----
old_install "$I"; mkdir -p "$I/custom"; mv "$I/docker-compose.override.yml" "$I/custom/override.yml"
migrate_env_27_to_28
[[ -e "$I/local/pins.yml" && -e "$I/custom/override.yml" && ! -e "$I/.pins.yml" ]] || fail_ "an interrupted move was not finished"; pass

# ---- both copies: stop, change nothing more ----
old_install "$I"; mkdir -p "$I/custom"; echo mine > "$I/custom/override.yml"
if (migrate_env) 2>/dev/null; then fail_ "both copies of a file must stop the move"; fi; pass
[[ "$(cat "$I/custom/override.yml")" == mine && -e "$I/docker-compose.override.yml" ]] || fail_ "a conflict must leave both copies as they were"; pass
[[ "$(env_get ENV_SCHEMA)" == 27 ]] || fail_ "a stopped move must not bump the schema"; pass

# ---- .env backups: the oldest and the newest 9 ----
rm -rf "$ENV_BACKUP_DIR"; mkdir -p "$ENV_BACKUP_DIR"
for i in $(seq -w 1 15); do : > "$ENV_BACKUP_DIR/.env.bak.202601${i}000000.schema$i"; done
env_backups_prune
n=$(find "$ENV_BACKUP_DIR" -name '.env.bak.*' | wc -l)
[[ $n == 10 && -e "$ENV_BACKUP_DIR/.env.bak.20260101000000.schema01" && -e "$ENV_BACKUP_DIR/.env.bak.20260115000000.schema15" \
   && ! -e "$ENV_BACKUP_DIR/.env.bak.20260102000000.schema02" ]] || fail_ "backups kept: $n, wrong ones: $(ls -A "$ENV_BACKUP_DIR")"; pass

# ---- your compose files ----
rebase "$T/u"; mkdir -p "$DROPIN_DIR"
printf 'services:\n    # four-space indent, a comment\n    zapp:\n        image: a\n    zdb:   # its database\n        image: b\nnetworks:\n  x: {}\n' > "$DROPIN_DIR/b-zapp.yml"
printf 'services:\n  hello:\n    image: c\n' > "$DROPIN_DIR/a-hello.yml"
[[ "$(yaml_services "$DROPIN_DIR/b-zapp.yml" | tr '\n' ' ')" == "zapp zdb " ]] || fail_ "services of a file: $(yaml_services "$DROPIN_DIR/b-zapp.yml")"; pass
echo 'services: {}' > "$OVERRIDE_FILE"
user_compose_files
[[ "${USER_FILES[*]}" == "-f $DROPIN_DIR/a-hello.yml -f $DROPIN_DIR/b-zapp.yml -f $OVERRIDE_FILE" ]] \
    || fail_ "order must be drop-ins by name, then the override: ${USER_FILES[*]}"; pass
printf 'services:\n  radarr:\n    image: x\n' > "$DROPIN_DIR/c-radarr.yml"
out=$( (user_compose_files) 2>&1 ) && fail_ "a drop-in redefining a shipped service must be refused"
[[ "$out" == *"'radarr'"*"shipped (compose.d/radarr.yml)"* ]] || fail_ "the refusal must name both: $out"; pass
rm "$DROPIN_DIR/c-radarr.yml"
printf 'services:\n  hello:\n    image: y\n' > "$DROPIN_DIR/d-dup.yml"
if (user_compose_files) 2>/dev/null; then fail_ "two drop-ins defining one service must be refused"; fi; pass
rm "$DROPIN_DIR/d-dup.yml"
echo 'volumes: {}' > "$DROPIN_DIR/e-empty.yml"
if (user_compose_files) 2>/dev/null; then fail_ "a drop-in without services must be refused"; fi; pass
rm "$DROPIN_DIR/e-empty.yml"
echo 'services: {}' > "$SCRIPT_DIR/docker-compose.override.yml"
out=$( (user_compose_files) 2>&1 ) && fail_ "a root docker-compose.override.yml must be refused"
[[ "$out" == *"custom/override.yml"* ]] || fail_ "the refusal must say where it belongs: $out"; pass

echo "OK layout: $checks checks"
