#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-prompts.sh — answers the wizards refuse (lib/questionnaire.sh, lib/common.sh):
#   * a folder path with a backslash is refused and asked again — the key
#     beside Enter (found live: CACHE_ROOT became .../mediastack/\)
#   * the fstab check matches the path as text: a path with regex characters
#     neither breaks it nor matches what it should not; an fstab entry that is
#     not mounted is still caught
#   * ask_valid: a refused answer is said and asked again, and never becomes
#     the default (found live: a refused email came back as the default)
#   * hidden input: terminal escape sequences and control characters are taken
#     out of a pasted value, and said (found live: ^[[B glued onto a webhook URL)
#   * one way to ask each kind of question: yes/no only through confirm and
#     confirm_yes, choices in ( ), a default in [ ] and no empty [ ], "(input
#     hidden)" and "Enter = ..." — the convention written at ask
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
grep -q "has a backslash in it" "$T/out" && [[ "${Q_ROOT[CACHE_ROOT]}" == "$SCRIPT_DIR/cache" ]] \
    || fail_ "'\\' refused, then Enter took the default ./cache — out: $(cat "$T/out") chosen: ${Q_ROOT[CACHE_ROOT]-}"; pass
[[ ! -s "$T/err" ]] || fail_ "the path went into a pattern again: $(cat "$T/err")"; pass

# ---- the fstab check, as text ----
printf '# /mnt/a+b  commented out\n192.168.1.5:/media /mnt/a+b nfs defaults 0 0\n' > "$FSTAB"
fresh '/mnt/a+b' '/mnt/abb'
configure_root DATA_ROOT "Data directory" "x" yes 2> "$T/err"
grep -q "'/mnt/a+b' is listed in /etc/fstab but NOT currently mounted" "$T/out" && [[ "${Q_ROOT[DATA_ROOT]}" == /mnt/abb ]] \
    || fail_ "an unmounted fstab entry is caught; /mnt/abb (what a+b matches as a pattern) is not — out: $(cat "$T/out") chosen: ${Q_ROOT[DATA_ROOT]-}"; pass
[[ ! -s "$T/err" ]] || fail_ "the fstab check printed errors: $(cat "$T/err")"; pass

# ---- ask_valid ----
fresh 'alethio36' '' 'alethio36@example.com'
ask_valid email AE "Email" "" "an email address"
[[ "$REPLY_VAL" == alethio36@example.com ]] || fail_ "ask_valid returned '$REPLY_VAL'"; pass
[[ "$(sort -u "$T/defaults")" == "" ]] || fail_ "a refused answer became the default: $(tr '\n' '|' < "$T/defaults")"; pass
[[ "$(grep -c "is not an email address" "$T/out")" == 2 ]] || fail_ "each refusal is said ($(cat "$T/out"))"; pass

# ---- one way to ask each kind of question (the convention at ask, lib/common.sh) ----
src() { grep -rnE "$1" mediastack.sh lib services --include=*.sh | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true; }
bad=$(src '(ask[a-z_]*|_ns_ask|read -r[ a-z-]*-p) [A-Z_]* *"[^"]*(\((y/n|Y/n|y/N|yes/no)\)|\[(y/n|Y/n|y/N)\])' \
      | grep -vE '^lib/common\.sh:[0-9]+:    read -r -p "\$1 \[(Y/n|y/N)\]: " ans')
[[ -z "$bad" ]] || fail_ "a yes/no question outside confirm/confirm_yes ([Y/n] / [y/N], the capital the default): $bad"; pass
bad=$(src '(ask[a-z_]*|_ns_ask) [A-Z_]* *"[^"]*\[[^]"]*/[^]"]*\]')
[[ -z "$bad" ]] || fail_ "choices in [ ] (they go in ( ), the default in [ ]): $bad"; pass
bad=$(src '(ask[a-z_]*|_ns_ask|read -r[ a-z-]*-p|warn) [A-Z_]* *"[^"]*(input is hidden|empty = )')
[[ -z "$bad" ]] || fail_ "say '(input hidden)' and 'Enter = ...': $bad"; pass
grep -q '\[\[ -n "\$def" \]\] && hint=" \[\$def\]"' lib/common.sh || fail_ "ask prints [ ] again when there is no default"; pass

# ---- hidden input: an arrow key pressed while pasting is not part of the value ----
warn() { echo "WARN $*" >> "$T/warn"; }
: > "$T/warn"
hidden_clean $'https://discord.com/api/webhooks/1/abc\e[B'
[[ "$HIDDEN_VAL" == "https://discord.com/api/webhooks/1/abc" ]] || fail_ "a pasted URL with an arrow key glued on (found live): the URL alone ($HIDDEN_VAL)"; pass
grep -q "took 3 terminal control character" "$T/warn" || fail_ "and it says so"; pass
: > "$T/warn"; hidden_clean "plain-token_123/+="
[[ "$HIDDEN_VAL" == "plain-token_123/+=" && ! -s "$T/warn" ]] || fail_ "a clean value: untouched, nothing said"; pass
hidden_clean $'tok\eOAen\x01d\t'
[[ "$HIDDEN_VAL" == tokend ]] || fail_ "the other arrow-key form, a control character, a tab: all out ($HIDDEN_VAL)"; pass
unset -f ask
ask_token "Token" "" <<<$'secret\e[A' >/dev/null 2>&1
[[ "$REPLY_VAL" == secret ]] || fail_ "ask_token: the pasted value cleaned ($REPLY_VAL)"; pass
ask_hidden "URLs" <<<$'json://hub\e[D' >/dev/null 2>&1
[[ "$REPLY_VAL" == json://hub ]] || fail_ "ask_hidden: the pasted value cleaned ($REPLY_VAL)"; pass

echo "test-prompts: $checks checks passed"
