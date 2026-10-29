#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-prompts.sh — answers the wizards refuse (lib/configure.sh, lib/common.sh):
#   * a folder path with a backslash is refused and asked again — the key
#     beside Enter (found live: CACHE_ROOT became .../mediastack/\)
#   * the fstab check matches the path as text: a path with regex characters
#     neither breaks it nor matches what it should not; an fstab entry that is
#     not mounted is still caught
#   * ask_valid: a refused answer is said and asked again, and never becomes
#     the default (found live: a refused email came back as the default)
# Sources the real entrypoint (minus its last line, main "$@"); the prompts,
# mounts and .env are stubs.
#
#   scripts/test-prompts.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-prompts.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"
set +e +E; trap - ERR

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

ANSWERS=() N=0
ask() { # the next scripted answer; Enter (empty) takes the default, as the real one does
    echo "$3" >> "$T/defaults"
    local a="${ANSWERS[$N]:-}"; N=$((N + 1))
    REPLY_VAL="${a:-$3}"
}
explain() { :; }; info() { :; }; ok() { echo "OK $*" >> "$T/out"; }
fail() { echo "FAIL $*" >> "$T/out"; }
env_get() { :; }
env_set() { echo "$1=$2" >> "$T/env"; }
sudo() { :; }   # mkdir
fstype_of() { echo ext4; }
findmnt() { [[ "$*" == *" -o SOURCE "* ]] && echo /dev/sda1; return 1; }   # nothing is mounted
FSTAB="$T/fstab"; : > "$FSTAB"
fresh() { ANSWERS=("$@"); N=0; : > "$T/out"; : > "$T/env"; : > "$T/defaults"; }

# ---- a backslash ----
fresh '\' ''
configure_root CACHE_ROOT "Cache directory" "x" yes 2> "$T/err"
grep -q "has a backslash in it" "$T/out" && grep -qx "CACHE_ROOT=$SCRIPT_DIR/cache" "$T/env" \
    || fail_ "'\\' refused, then Enter took the default ./cache — out: $(cat "$T/out") env: $(cat "$T/env")"; pass
[[ ! -s "$T/err" ]] || fail_ "the path went into a pattern again: $(cat "$T/err")"; pass

# ---- the fstab check, as text ----
printf '# /mnt/a+b  commented out\n192.168.1.5:/media /mnt/a+b nfs defaults 0 0\n' > "$FSTAB"
fresh '/mnt/a+b' '/mnt/abb'
configure_root DATA_ROOT "Data directory" "x" yes 2> "$T/err"
grep -q "'/mnt/a+b' is listed in /etc/fstab but NOT currently mounted" "$T/out" && grep -qx "DATA_ROOT=/mnt/abb" "$T/env" \
    || fail_ "an unmounted fstab entry is caught; /mnt/abb (what a+b matches as a pattern) is not — out: $(cat "$T/out") env: $(cat "$T/env")"; pass
[[ ! -s "$T/err" ]] || fail_ "the fstab check printed errors: $(cat "$T/err")"; pass

# ---- ask_valid ----
fresh 'alethio36' '' 'alethio36@example.com'
ask_valid email AE "Email" "" "an email address"
[[ "$REPLY_VAL" == alethio36@example.com ]] || fail_ "ask_valid returned '$REPLY_VAL'"; pass
[[ "$(sort -u "$T/defaults")" == "" ]] || fail_ "a refused answer became the default: $(tr '\n' '|' < "$T/defaults")"; pass
[[ "$(grep -c "is not an email address" "$T/out")" == 2 ]] || fail_ "each refusal is said ($(cat "$T/out"))"; pass

echo "test-prompts: $checks checks passed"
