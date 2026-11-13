#!/usr/bin/env bash
# dryrun-live.sh — a dry run touches nothing, checked on a RUNNING stack (not CI).
# Runs `wire --dry-run`, `update --dry-run` and `trash-sync --dry-run` against
# the real apps, through wrappers for sudo, docker and curl that let every read
# through and block every write (recorded as a violation, never run). Run it
# on the box, from the repo, in a terminal (trash-sync's preview needs one):
#   scripts/dryrun-live.sh
# Pass = each verb exits 0 and prints its dry-run line, no violation, and
# .env, local/ (but its run records) and every container (id, start time, restarts, state) are the
# same afterwards. Exit 0 = passed.
#
# What a write is (the --judge rules below; scripts/test-dryrun-live.sh pins them):
#   curl     any method but GET/HEAD, or a body — except the reads that use
#            POST: a login, Apprise's /get/<key>, and the JSON-RPC reads of
#            Deluge and Transmission (judged by the method named in the body)
#   docker   anything but inspect/ps/logs/info/version/images/port and their
#            inspect/ls forms; compose only config/ps/images/ls, its own
#            `--dry-run`, and recyclarr's `sync --preview` (trash-sync's
#            preview); exec only the read commands mediastack runs in a
#            container (wget/curl reads, ip, nslookup, test, iptables -S/-L,
#            ak apply_blueprint --dry-run)
#   sudo     anything but reads (test, cat, cmp, grep, stat, du, df, ls,
#            readlink, sha256sum, find without -delete or a writing -exec,
#            `sh -c 'command -v …'`, systemctl's queries, timeout around a
#            read) — docker under sudo is judged as docker; trash-sync's
#            preview may install, write and remove its scratch file
# A violation shows the tool and its target only (no bodies or headers: they
# carry secrets). Not covered: a write by any other route.
#
#   scripts/dryrun-live.sh                  run it
#   scripts/dryrun-live.sh --judge TOOL ARG...   ok | write: <what> (the rules)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
repo=$PWD
SELF="$repo/scripts/dryrun-live.sh"

# ------------------------------------------------------------------ the rules --
PREVIEW_FILE=recyclarr.preview.yml   # trash-sync --dry-run's scratch copy
SUDO_READS="test cat cmp grep stat du df ls readlink sha256sum true id getent head tail wc lsof ausearch journalctl"
FIND_EXEC_READS="cat ls stat test grep head wc sha256sum"

judge_curl() { # judge_curl ARG... -> ok | write: METHOD URL
    local a prev="" method="" body="" url=""
    for a in "$@"; do
        case "$prev" in
            -X|--request) method=$a ;;
            -d|--data|--data-raw|--data-binary|--data-urlencode|--json) body=$a ;;
            -F|--form|-T|--upload-file) body=$a ;;
        esac
        [[ "$a" =~ ^https?:// ]] && url=$a
        prev=$a
    done
    [[ -n "$method" ]] || { [[ -n "$body" ]] && method=POST || method=GET; }
    local path=${url%%\?*}; path=${path#*://*/}; path="/$path"
    local where="$method ${url%%\?*}"
    case "$method" in GET|HEAD) [[ -z "$body" ]] && { echo ok; return; } ;; esac
    if [[ "$method" == POST ]]; then
        # logins and Apprise's read of its configuration
        if [[ "$path" =~ (^|/)(login|auth/login|api/account/login|api/v2/auth/login|Users/AuthenticateByName)/?$ \
              || "$path" =~ (^|/)get/[A-Za-z0-9_-]+/?$ ]]; then echo ok; return; fi
        # JSON-RPC (Deluge /json, Transmission /transmission/rpc): the method in the body
        local rpc; rpc=$(jq -r '.method // empty' <<<"$body" 2>/dev/null || true)
        if [[ "$rpc" =~ ^(auth\.login|auth\.check_session|web\.connected|web\.get_hosts|web\.get_host_status|daemon\.info|daemon\.get_version|core\.get_[a-z_]+|session-get|session-stats|torrent-get)$ ]]; then
            echo ok; return
        fi
    fi
    echo "write: curl $where"
}

judge_exec() { # judge_exec CMD... -> ok | write: … (a command run inside a container)
    case "$1" in
        test|ip|nslookup) echo ok; return ;;
        wget) # to stdout, /dev/null or --spider: nothing kept
            local a prev=""
            for a in "$@"; do
                [[ "$a" =~ ^-[a-zA-Z]*O-$ || "$a" == --spider || ( "$prev" =~ ^-[a-zA-Z]*O$ && "$a" =~ ^(-|/dev/null)$ ) ]] && { echo ok; return; }
                prev=$a
            done ;;
        curl) judge_curl "${@:2}"; return ;;
        iptables) [[ " $* " =~ \ -(S|L|-list|-list-rules)\  ]] && { echo ok; return; } ;;
        ak) [[ "$2" == apply_blueprint && " $* " == *" --dry-run "* ]] && { echo ok; return; } ;;
    esac
    echo "write: docker exec $1 ${2:-}"
}

judge_docker() { # judge_docker ARG... -> ok | write: …
    local a sub="" i
    case "${1:-}" in
        inspect|ps|logs|info|version|images|port) echo ok; return ;;
        image|network|volume|container|manifest)
            [[ "${2:-}" =~ ^(inspect|ls|list)$ ]] && { echo ok; return; }
            echo "write: docker $1 ${2:-}"; return ;;
        buildx) [[ "${2:-} ${3:-}" == "imagetools inspect" ]] && { echo ok; return; }
            echo "write: docker buildx ${2:-}"; return ;;
        exec)
            shift; while [[ "${1:-}" == -* ]]; do
                case "$1" in -u|--user|-w|--workdir|-e|--env) shift ;; esac; shift
            done
            shift   # the container
            judge_exec "$@"; return ;;
        compose)
            shift
            for a in "$@"; do [[ "$a" == --dry-run ]] && { echo ok; return; }; done
            # the first word after compose's own options is its subcommand
            for (( i = 1; i <= $#; i++ )); do
                a=${!i}
                case "$a" in
                    -f|--file|--project-directory|-p|--project-name|--profile|--env-file) (( i++ )) ;;
                    -*) ;;
                    *) sub=$a; break ;;
                esac
            done
            case "$sub" in
                config|ps|images|ls|version) echo ok; return ;;
                run) [[ " $* " == *" recyclarr sync --preview "* ]] && { echo ok; return; } ;;
            esac
            echo "write: docker compose ${sub:-?}"; return ;;
    esac
    echo "write: docker ${1:-?}"
}

judge_sudo() { # judge_sudo ARG... -> ok | write: …
    while [[ "${1:-}" == -* ]]; do
        case "$1" in -v|--validate) echo ok; return ;; -u|--user|-g|--group) shift ;; esac; shift
    done
    local c=${1:-}; shift || true
    [[ -n "$c" && " $SUDO_READS " == *" $c "* ]] && { echo ok; return; }
    case "$c" in
        docker) judge_docker "$@"; return ;;
        timeout)
            while [[ "${1:-}" == -* ]]; do [[ "$1" =~ ^-(k|s)$ ]] && shift; shift; done
            shift; judge_sudo "$@"; return ;;
        sh) [[ "${1:-}" == -c && "${2:-}" == "command -v "* ]] && { echo ok; return; } ;;
        find)
            [[ " $* " == *" -delete "* ]] && { echo "write: sudo find -delete"; return; }
            local a prev=""
            for a in "$@"; do
                [[ "$prev" =~ ^-exec(dir)?$ && " $FIND_EXEC_READS " != *" $a "* ]] && { echo "write: sudo find -exec $a"; return; }
                prev=$a
            done
            echo ok; return ;;
        systemctl)
            [[ "${1:-}" =~ ^(is-active|is-enabled|is-failed|status|show|cat|list-units|list-timers|list-unit-files)$ ]] && { echo ok; return; } ;;
        install) # trash-sync's preview installs its scratch copy (the destination: the last word)
            local dest=${!#}
            [[ "$dest" == */"$PREVIEW_FILE" ]] && { echo ok; return; }
            echo "write: sudo install ${dest##*/}"; return ;;
        tee|rm) # trash-sync's preview writes and removes its scratch copy, nothing else
            local a; for a in "$@"; do [[ "$a" == -* ]] && continue
                [[ "${a##*/}" == "$PREVIEW_FILE" ]] || { echo "write: sudo $c ${a##*/}"; return; }
            done
            echo ok; return ;;
    esac
    echo "write: sudo $c ${1:-}"
}

if [[ "${1:-}" == --judge ]]; then
    shift; tool=$1; shift
    "judge_$tool" "$@"; exit 0
fi
if [[ "${1:-}" == --wrap ]]; then   # the wrappers' body: judge, then run or block
    tool=$2; shift 2
    verdict=$("judge_$tool" "$@")
    if [[ "$verdict" == ok ]]; then
        real="DRYRUN_REAL_${tool^^}"
        exec "${!real}" "$@"
    fi
    echo "${verdict#write: }" >> "$DRYRUN_LOG"
    echo "dryrun-live: BLOCKED ${verdict#write: }" >&2
    exit 1
fi

# ------------------------------------------------------------------ the run --
[[ -f .env ]] || { echo "ERROR no .env — this checks an installed stack" >&2; exit 2; }
[[ -t 0 ]] || { echo "ERROR run it in a terminal: trash-sync's preview needs one" >&2; exit 2; }
for t in sudo docker curl; do
    p=$(command -v "$t") || { echo "ERROR $t not found" >&2; exit 2; }
    export "DRYRUN_REAL_${t^^}=$p"
done
sudo -v

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
export DRYRUN_LOG="$work/violations"; : > "$DRYRUN_LOG"
mkdir "$work/bin"
for t in sudo docker curl; do
    printf '#!/usr/bin/env bash\nexec %q --wrap %s "$@"\n' "$SELF" "$t" > "$work/bin/$t"
    chmod +x "$work/bin/$t"
done

snapshot() { # what a dry run must leave as it was
    sha256sum .env
    # some of local/ is 0600; local/runs/ is every run's own record (lib/runs.sh), these dry runs' too
    sudo find local -path local/runs -prune -o -type f -print0 | sort -z | sudo xargs -0r sha256sum
    sudo docker ps -aq | xargs -r sudo docker inspect -f '{{.Name}} {{.Id}} {{.State.StartedAt}} {{.RestartCount}} {{.State.Status}}'
}
snapshot > "$work/before"

fails=0
run() { # run LINE VERB ARG... — LINE: the text its dry run prints
    local line=$1 rc=0; shift
    echo "── ./mediastack.sh $*"
    PATH="$work/bin:$PATH" ./mediastack.sh "$@" 2>&1 | tee "$work/out" || rc=${PIPESTATUS[0]}
    if (( rc )); then echo "FAIL $*: exit $rc"; fails=$((fails + 1))
    elif ! grep -qF "$line" "$work/out"; then echo "FAIL $*: no '$line' line"; fails=$((fails + 1))
    else echo "ok   $*"; fi
}
run "dry-run complete"          wire --dry-run
run "update --dry-run"          update --dry-run
run "trash-sync --dry-run"      trash-sync --dry-run

snapshot > "$work/after"
echo
if [[ -s "$DRYRUN_LOG" ]]; then
    echo "FAIL writes a dry run tried (blocked):"; sort "$DRYRUN_LOG" | uniq -c | sed 's/^/  /'
    fails=$((fails + 1))
fi
if ! diff "$work/before" "$work/after" > "$work/diff"; then
    echo "FAIL changed by a dry run (< before, > after):"; sed 's/^/  /' "$work/diff"
    fails=$((fails + 1))
fi
if (( fails )); then echo "dryrun-live: $fails failure(s)"; exit 1; fi
echo "dryrun-live: every dry run touched nothing"
