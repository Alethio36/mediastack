#!/usr/bin/env bash
# Front-door safety audit for mediastack.sh.
#
# mediastack.sh is designed to be safe to expose through a thin web front door
# (e.g. OliveTin) that runs it via a narrow `sudo NOPASSWD` entry. That model
# only holds while the script cannot be turned into an arbitrary-root shell:
# no eval, and no user input interpolated into a shell (`sh -c "…$var…"`).
#
# This is a TRIPWIRE, not a proof. It mechanically catches the two patterns
# that would definitely break the model, so a regression fails CI instead of
# silently widening the blast radius. It deliberately does NOT claim to verify
# that every verb validates its arguments — that is semantic and stays a
# human-review responsibility (see docs/frontdoor-safety.md).
#
# Exit 0 = clean, 1 = a forbidden pattern was found.
set -euo pipefail

script="${1:-mediastack.sh}"
[[ -f "$script" ]] || { echo "audit: $script not found"; exit 1; }

rc=0
fail() { printf 'FAIL  %s\n' "$*" >&2; rc=1; }
ok()   { printf 'OK    %s\n' "$*"; }

# 1. No eval — the single worst injection primitive.
if grep -nE '(^|[^[:alnum:]_])eval([^[:alnum:]_]|$)' "$script" >/tmp/fd_eval 2>/dev/null; then
    fail "eval found — a front-door script must never eval:"
    sed 's/^/      /' /tmp/fd_eval >&2
else
    ok "no eval"
fi
rm -f /tmp/fd_eval

# 2. No interpolation-permitting `sh -c "…"` / `bash -c "…"`.
#    Single-quoted (static) forms are fine; double-quoted forms permit variable
#    interpolation and are the injection vector to review by hand. Currently
#    there are zero — any new one must be justified and, if it must exist, added
#    to an explicit allowlist here with a comment.
if grep -nE '\b(sh|bash)[[:space:]]+-c[[:space:]]+"' "$script" >/tmp/fd_shc 2>/dev/null; then
    fail "interpolating sh -c \"…\" found — pass data as argv, not an interpolated string:"
    sed 's/^/      /' /tmp/fd_shc >&2
else
    ok "no interpolating sh -c / bash -c"
fi
rm -f /tmp/fd_shc

# 3. The committed script must not be group/other-writable. The sudo target
#    being writable by the front-door user would let a compromise rewrite what
#    runs as root. Host ownership can't be checked from CI, but a loosened mode
#    in git can.
mode=$(git ls-files -s "$script" 2>/dev/null | awk '{print $1}' || true)
if [[ -n "$mode" ]]; then
    # git stores 100644 or 100755; anything with group/other write is a red flag,
    # but git only tracks the executable bit, so this mainly guards against a
    # future switch to a mode git would record as writable. Informational.
    ok "git file mode: $mode (git tracks only the exec bit; enforce root-owned, non-writable on the host)"
fi

if (( rc )); then
    echo >&2
    echo "front-door safety audit FAILED — see docs/frontdoor-safety.md before changing this." >&2
fi
exit "$rc"
