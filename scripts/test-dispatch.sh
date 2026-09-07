#!/usr/bin/env bash
# test-dispatch.sh — the verb registry's argument contracts, end to end.
#
# Every cmd_* function is REMOVED after sourcing mediastack.sh, so main()'s
# dynamic call lands in command_not_found_handle, which prints the verb and
# its argv. Each line of scripts/fixtures/dispatch.cases is one invocation
# (<none> = no arguments at all);
# the combined stdout+stderr of all of them must match dispatch.expected
# byte for byte. A registry change that alters what reaches a verb — or
# what is refused before it — shows up as a diff.
#
#   scripts/test-dispatch.sh            run (exit 1 on any difference)
#   scripts/test-dispatch.sh --update   rewrite the expected file (review the diff!)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

cases=scripts/fixtures/dispatch.cases
expected=scripts/fixtures/dispatch.expected
[[ -s "$cases" ]] || { echo "ERROR no cases at $cases" >&2; exit 1; }

# a copy of the entrypoint without its last line (main "$@") so it can be
# sourced for its definitions; it lives beside the real one because the
# script locates lib/ relative to itself (no tty on capture: no colour codes)
lib=$(mktemp .test-dispatch.XXXXXX); trap 'rm -f "$lib"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"

# every cmd_* goes away; the dispatcher's call then reaches this handler
while read -r _ _ fn; do
    [[ "$fn" == cmd_* ]] && unset -f "$fn"
done < <(declare -F)
command_not_found_handle() { printf 'CALL %s [%d]%s\n' "$1" "$(($# - 1))" "${2:+ ${*:2}}"; }

actual=$(
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        echo "## $line"
        [[ "$line" == "<none>" ]] && line=""   # the bare invocation
        # word-split on purpose: a case line is literal argv
        # shellcheck disable=SC2086
        ( main $line ) 2>&1 || echo "rc=$?"
    done < "$cases"
)

if [[ "${1:-}" == --update ]]; then
    printf '%s\n' "$actual" > "$expected"
    echo "wrote $expected ($(grep -c '^## ' "$expected") cases) — review it before committing"
    exit 0
fi
[[ -s "$expected" ]] || { echo "ERROR no expected output at $expected — run with --update once" >&2; exit 1; }
if diff -u "$expected" <(printf '%s\n' "$actual"); then
    echo "OK dispatch: $(grep -c '^## ' "$expected") cases identical"
else
    echo "ERROR dispatch output differs from $expected (above: - expected, + actual)" >&2
    exit 1
fi
