#!/usr/bin/env bash
# test-ownership.sh — repo state stays the operator's, whoever ran the script.
# The panel and every timer run mediastack.sh as root, the CLI as the operator;
# a root run that created local/, .pins.yml or an .env backup locked the
# operator out of it (their overlay, pin or backup read was refused). Pins
# repo_owned (root hands what it made to the repo's owner; a no-op for a normal
# user) and, statically, that every repo-local creation outside sudo calls it.
#
#   scripts/test-ownership.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-ownership.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

# shellcheck disable=SC2034  # read by the sourced repo_owned
SCRIPT_DIR=$T
want=$(stat -c '%u:%g' "$T")
chown() { echo "$*" > "$T/chown"; }

UID_IS=0; id() { [[ "$1" == -u ]] && echo "$UID_IS"; }
repo_owned "$T/x"
[[ "$(cat "$T/chown" 2>/dev/null)" == "$want $T/x" ]] || fail_ "as root, repo_owned must give the path to the repo's owner ($want): got '$(cat "$T/chown" 2>/dev/null)'"; pass

rm -f "$T/chown"; UID_IS=1000
repo_owned "$T/x"
[[ ! -e "$T/chown" ]] || fail_ "as a normal user, repo_owned must do nothing"; pass

# static guard: a repo-local folder or file the script creates without sudo is
# handed over on the same line (install -d, the migration backup, .wired, pins)
if grep -nE '(^|[;&|] *|^\s+)(install -d|cp "\$ENV_FILE"|touch "\$SCRIPT_DIR)' lib/*.sh mediastack.sh \
        | grep -v 'sudo ' | grep -v 'repo_owned'; then
    fail_ "a repo-local creation outside sudo (above) does not call repo_owned — a root run would lock the operator out"
fi; pass

echo "OK ownership: $checks checks"
