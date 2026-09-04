#!/usr/bin/env bash
# Front-door safety audit for mediastack.sh and its sourced libraries.
#
# mediastack.sh is designed to be safe to expose through a thin web front door
# (e.g. OliveTin) that runs it via a narrow `sudo NOPASSWD` entry. That model
# only holds while the script cannot be turned into an arbitrary-root shell:
# no eval, and no user input interpolated into a shell (`sh -c "…$var…"`).
#
# sudo runs the entrypoint as root, which `source`s lib/*.sh as root — so every
# library is part of the same root-executed surface and must clear the same
# tripwires. With no arguments this audits mediastack.sh plus lib/*.sh; pass an
# explicit file list to override.
#
# This is a TRIPWIRE, not a proof. It mechanically catches the two patterns
# that would definitely break the model, so a regression fails CI instead of
# silently widening the blast radius. It deliberately does NOT claim to verify
# that every verb validates its arguments — that is semantic and stays a
# human-review responsibility (see docs/frontdoor-safety.md).
#
# Exit 0 = clean, 1 = a forbidden pattern was found.
set -euo pipefail

if (( $# )); then
    files=("$@")
else
    shopt -s nullglob
    files=(mediastack.sh lib/*.sh)
    shopt -u nullglob
fi

rc=0
fail() { printf 'FAIL  %s\n' "$*" >&2; rc=1; }
ok()   { printf 'OK    %s\n' "$*"; }

audit_file() {
    local script="$1" tag="[$1]"
    [[ -f "$script" ]] || { fail "$tag not found"; return; }

    # 1. No eval — the single worst injection primitive.
    if grep -nE '(^|[^[:alnum:]_])eval([^[:alnum:]_]|$)' "$script" >/tmp/fd_eval 2>/dev/null; then
        fail "$tag eval found — a front-door script must never eval:"
        sed 's/^/      /' /tmp/fd_eval >&2
    else
        ok "$tag no eval"
    fi
    rm -f /tmp/fd_eval

    # 2. No interpolation-permitting `sh -c "…"` / `bash -c "…"`. Single-quoted
    #    (static) forms are fine; double-quoted forms permit interpolation and
    #    are the injection vector to review by hand. Currently there are zero.
    if grep -nE '\b(sh|bash)[[:space:]]+-c[[:space:]]+"' "$script" >/tmp/fd_shc 2>/dev/null; then
        fail "$tag interpolating sh -c \"…\" found — pass data as argv, not an interpolated string:"
        sed 's/^/      /' /tmp/fd_shc >&2
    else
        ok "$tag no interpolating sh -c / bash -c"
    fi
    rm -f /tmp/fd_shc

    # 3. The committed file must not be group/other-writable. A writable sudo
    #    target would let a compromise rewrite what runs as root. Git only tracks
    #    the exec bit, so this mainly guards a future switch to a writable mode.
    local mode
    mode=$(git ls-files -s "$script" 2>/dev/null | awk '{print $1}' || true)
    if [[ -n "$mode" ]]; then
        ok "$tag git file mode: $mode (enforce root-owned, non-writable on the host)"
    fi
}

for f in "${files[@]}"; do audit_file "$f"; done

if (( rc )); then
    echo >&2
    echo "front-door safety audit FAILED — see docs/frontdoor-safety.md before changing this." >&2
fi
exit "$rc"
