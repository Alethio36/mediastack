#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-doctor-perms.sh — doctor's config write probe asks as the app, not as root:
#   * the probe runs as <SVC>_UID:MEDIA_GROUP_GID, at the container's real mount path
#   * an image whose `test` answers root from the mode bits alone (the Rust
#     coreutils of Ubuntu 26.04 images: LazyLibrarian, Nov 2026) is not a FAIL
#   * a folder the app's own user cannot write still is
# Sources the real entrypoint (minus its last line, main "$@"); docker is a stub.
#
#   scripts/test-doctor-perms.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-doctor-perms.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"
set +e +E; trap - ERR

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

CROOT="$T/config"; mkdir -p "$CROOT/lazylibrarian"
env_get() { case "$1" in CONFIG_ROOT) echo "$CROOT" ;; MEDIA_GROUP_GID) echo 13000 ;; LAZYLIBRARIAN_UID) echo 13028 ;; esac; }
svc_managed_where() { echo lazylibrarian; }
svc_shard() { echo "$1"; }
svc_cname() { echo "mediastack-$1"; }
c_state() { echo running; }
c_get() { echo /config; }
D_FAILS=0
d_fail() { echo "DFAIL $1"; D_FAILS=$((D_FAILS + 1)); }
# the image's `test`: as root it judges the folder (13028:13000, 755) by its mode bits and
# says no (uutils); as the app's own user it says yes — and APP_CAN_WRITE=0 makes even that no
APP_CAN_WRITE=1
sudo() {
    case "$1 $2" in
        "find "*) return 0 ;;   # nothing mis-owned
        "docker exec")
            echo "$*" >> "$T/exec"
            if [[ "$*" == *"-u 13028:13000 "* ]]; then (( APP_CAN_WRITE )) && return 0; return 1; fi
            return 1 ;;   # root, as the Rust coreutils answers it
    esac
}

out=$(_doctor_permissions 2>&1)
grep -q -- "docker exec -u 13028:13000 mediastack-lazylibrarian test -w /config" "$T/exec" \
    || fail_ "the probe asks as the app's uid:gid ($(cat "$T/exec"))"; pass
[[ "$out" != *DFAIL* && "$out" == *"lazylibrarian config writable from inside the container (/config)"* ]] \
    || fail_ "an image whose test answers root from the mode bits: not a FAIL — $out"; pass
APP_CAN_WRITE=0; out=$(_doctor_permissions 2>&1)
[[ "$out" == *"DFAIL lazylibrarian cannot write /config from inside its container"* ]] \
    || fail_ "the app's own user cannot write: still a FAIL — $out"; pass

echo "test-doctor-perms: $checks checks passed"
