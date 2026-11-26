#!/usr/bin/env bash
# scripts/test-roots.sh — the folders mediastack deletes or moves whole:
#   * a root is never a system or shared folder, the home folder, or one
#     holding this repo (configure refuses it: root_unsafe, root_problem)
#   * nuke and uninstall delete a root whole only when that is safe: never
#     one holding DATA_ROOT or BACKUP_ROOT, and they say what they keep
#   * a root moved across disks is deleted only after a dry re-sync that
#     itself succeeded finds nothing left to copy (found: an rsync that
#     failed printed nothing, and the empty answer counted as verified)
#   * a targeted update's pre-update point survives its own prune, even at
#     BACKUP_KEEP_PREUPDATE=0 (found: the point was pruned before the update)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-roots.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "OK $*" >> "$T/out"; }; info() { echo "INFO $*" >> "$T/out"; }; warn() { echo "WARN $*" >> "$T/out"; }

# ---- a root of its own ----
for p in / /home /srv /opt /var /mnt /media /etc /tmp/ /srv/../srv "$HOME" "$SCRIPT_DIR" "$(dirname "$SCRIPT_DIR")"; do
    [[ -n "$(root_unsafe "$p")" ]] || fail_ "'$p' refused as a root"; pass
done
for p in /srv/mediastack /mnt/nas/media "$HOME/mediastack-config" "$SCRIPT_DIR/config" ./cache; do
    [[ -z "$(root_unsafe "$p")" ]] || fail_ "'$p' accepted as a root: $(root_unsafe "$p")"; pass
done
FSTAB=$T/fstab; : > "$FSTAB"
[[ "$(root_problem /srv no)" == *"system or shared folder"* ]] || fail_ "configure refuses /srv as a root: $(root_problem /srv no)"; pass
ln -s "$SCRIPT_DIR" "$T/repo-link"
( SCRIPT_DIR=$T/repo-link; [[ -n "$(root_unsafe "$(dirname "$(realpath "$T/repo-link")")")" ]] ) \
    || fail_ "a symlinked checkout: the folder holding the real repo is refused too"; pass

# ---- nuke and uninstall keep what holds the kept roots ----
mkdir -p "$T/srv/ms/config" "$T/srv/ms/data" "$T/own/cache"
env_get() { case "$1" in CONFIG_ROOT) echo "$T/srv/ms" ;; DATA_ROOT) echo "$T/srv/ms/data" ;; CACHE_ROOT) echo "$T/own/cache" ;; BACKUP_ROOT) echo "$T/b" ;; *) echo "" ;; esac; }
[[ "$(root_keep_why "$T/srv/ms")" == *"holds DATA_ROOT"* ]] || fail_ "a config root holding the media is kept: $(root_keep_why "$T/srv/ms")"; pass
[[ -z "$(root_keep_why "$T/own/cache")" ]] || fail_ "a root of its own may go: $(root_keep_why "$T/own/cache")"; pass
sudo() { "$@"; }
: > "$T/out"; roots_remove "$T/srv/ms" "$T/own/cache"
[[ -d "$T/srv/ms/data" && ! -e "$T/own/cache" ]] || fail_ "roots_remove deletes the safe root only"; pass
grep -F "WARN $T/srv/ms left in place: it holds DATA_ROOT" "$T/out" >/dev/null || fail_ "the kept root is said: $(cat "$T/out")"; pass
[[ "$(_nuke_root CONFIG_ROOT config)" == "$T/srv/ms" ]] || fail_ "_nuke_root resolves the path"; pass
unset -f sudo env_get

# ---- a move across disks: deleted only after a clean, complete check ----
sudo() { "$@"; }
rsync() { echo "rsync: read errors mapping \"/old/x\": Input/output error (5)" >&2; return 23; }
root_copy_verified /old /new && fail_ "an rsync check that failed is no verification"
[[ "$ROOT_VERIFY_WHY" == *"rsync rc 23"*"Input/output error"* ]] || fail_ "its failure is said: $ROOT_VERIFY_WHY"; pass
rsync() { printf '.d..t...... ./\n>f+++++++++ x\n'; }
root_copy_verified /old /new && fail_ "a file still to copy fails the check"
[[ "$ROOT_VERIFY_WHY" == "1 entries still differ, first: >f+++++++++ x" ]] || fail_ "what differs is said: $ROOT_VERIFY_WHY"; pass
rsync() { printf '.d..t...... ./\n'; }
root_copy_verified /old /new || fail_ "a folder's time alone passes: $ROOT_VERIFY_WHY"; pass
unset -f rsync sudo

# ---- the pre-update point survives its own prune ----
sudo() { "$@"; }
for kp in 0 1 2; do
    rm -rf "$T/b"; mkdir -p "$T/b/pre-update/20261124-010000" "$T/b/pre-update/20261125-010000" "$T/b/pre-update/20261126-031500"
    env_get() { case "$1" in BACKUP_ROOT) echo "$T/b" ;; BACKUP_KEEP_PREUPDATE) echo "$kp" ;; esac; }
    prune_preupdate
    [[ -d "$T/b/pre-update/20261126-031500" ]] || fail_ "BACKUP_KEEP_PREUPDATE=$kp: the newest point (the update's own) stays"; pass
    want=$(( kp < 1 ? 1 : kp ))
    [[ "$(find "$T/b/pre-update" -mindepth 1 -maxdepth 1 | wc -l)" == "$want" ]] || fail_ "BACKUP_KEEP_PREUPDATE=$kp keeps $want"; pass
done

echo "OK roots: $checks checks"
