#!/usr/bin/env bash
# lint.sh — shellcheck as CI runs it: the same files, the same severity, and
# the version CI has. Another version reads the code differently (found Nov
# 2026: 0.11 passed a test file CI's 0.9 failed with SC2218, and unstable
# stayed red until a promote noticed), so a local run on another one says so;
# in CI a different one fails, so a new runner image is a deliberate change.
#
#   scripts/lint.sh     run (exit 1 on any finding, or on CI's version changing)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

SHELLCHECK_CI=0.9.0   # Ubuntu 24.04's (lint.yml's runs-on): change both together

command -v shellcheck >/dev/null || { echo "lint: shellcheck is not installed — CI runs $SHELLCHECK_CI" >&2; exit 1; }
have=$(shellcheck --version | sed -n 's/^version: //p')
if [[ "$have" != "$SHELLCHECK_CI" ]]; then
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        echo "lint: CI's shellcheck is $have, not $SHELLCHECK_CI — the runner changed: update SHELLCHECK_CI here, then fix what it finds" >&2
        exit 1
    fi
    echo "lint: your shellcheck is $have; CI runs $SHELLCHECK_CI — a pass here can fail there, and the reverse" >&2
fi
shellcheck -S warning -x mediastack.sh lib/*.sh services/*/*.sh services/*/providers/*/*.sh scripts/*.sh
echo "OK lint: shellcheck $have, as CI runs it"
