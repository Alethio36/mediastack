#!/usr/bin/env bash
# promote.sh — fast-forward stable to unstable's tip once CI is green on it.
# stable's bar is "CI green on exactly what is promoted"; this makes the bar
# mechanical instead of a glance at the Actions tab. Standalone on purpose:
# it runs on the git authority, not a stack host (Git Bash on Windows is
# enough: bash, git, curl — no jq, no docker). GITHUB_TOKEN, if set, lifts
# the API's anonymous rate limit.
set -euo pipefail
die() { echo "promote: $*" >&2; exit 1; }
cd "$(dirname "${BASH_SOURCE[0]}")/.."

repo=$(git remote get-url origin | sed -E 's#.*github\.com[:/]##; s#\.git$##')
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "origin is not a GitHub repo: $repo"
git fetch -q origin
sha=$(git rev-parse origin/unstable)
[[ "$(git rev-parse unstable 2>/dev/null)" == "$sha" ]] \
    || die "local unstable is not origin/unstable — push what is unpushed, or pull, then retry"
if [[ "$(git rev-parse origin/stable)" == "$sha" ]]; then echo "stable already is ${sha:0:7}"; exit 0; fi
git merge-base --is-ancestor origin/stable "$sha" \
    || die "stable is not behind unstable — only a fast-forward promotes; reconcile the branches first"

auth=(); [[ -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
count() { awk -v p="$1" '$0 ~ p { n++ } END { print n + 0 }' <<<"$json"; }   # awk: a zero count is not a failure (grep | wc is, under pipefail)
echo "waiting for CI on ${sha:0:7} ($(git log -1 --format=%s "$sha"))"
for (( i = 0; i < 40; i++ )); do   # up to 20 minutes, one call per 30s
    json=$(curl -sS -H 'Accept: application/vnd.github+json' "${auth[@]}" \
           "https://api.github.com/repos/$repo/commits/$sha/check-runs?per_page=100") || die "GitHub API unreachable"
    grep -q '"message": *"API rate limit' <<<"$json" && die "GitHub API rate limit hit — set GITHUB_TOKEN, or retry later"
    total=$(awk '/"total_count":/ { gsub(/[^0-9]/, ""); print; exit }' <<<"$json")
    if (( ${total:-0} == 0 )); then echo "  no CI run registered yet"; sleep 30; continue; fi
    bad=$(count '"conclusion": *"(failure|cancelled|timed_out|action_required|startup_failure)"')
    (( bad == 0 )) || die "CI is RED on ${sha:0:7} — see https://github.com/$repo/commit/$sha/checks — nothing promoted"
    done_n=$(count '"status": *"completed"')
    good=$(count '"conclusion": *"success"')
    if (( done_n >= total && good >= total )); then
        echo "CI green: $good/$total check(s) on ${sha:0:7}"
        git checkout -q -B stable origin/stable
        git merge -q --ff-only "$sha"
        git push origin stable
        git checkout -q unstable
        echo "stable -> ${sha:0:7}"
        exit 0
    fi
    echo "  $done_n/$total complete"; sleep 30
done
die "CI still running after 20 minutes — retry"
