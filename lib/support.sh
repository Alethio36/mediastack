#!/usr/bin/env bash
# lib/support.sh — `support`: one plain-text file someone can send to whoever
# helps them (docs/design-runs.md). What goes in is an allowlist of parts, each
# saying where it came from; the whole file is then redacted (secrets, the
# domain, public addresses, e-mails, paths and names, credential URLs) and
# checked: a secret that survives deletes the bundle. Nothing is ever sent.
# Sourced by the entrypoint.

SUPPORT_DIR=""              # LOCAL_DIR/support, set when it runs
SUPPORT_RECORDS=10          # the newest run records in the bundle (plus every failed or unfinished one of the last 7 days)
# every few minutes, much the same each time: only the latest of each (and any that failed)
SUPPORT_ROUTINE=" vpn-watch frontdoor-refresh people-sync "
# the bundle runs these fresh: their old records add nothing
SUPPORT_NOT_RECORDS=" doctor support "
SUPPORT_RECORD_LINES=400    # each cut to its last this many lines
SUPPORT_WAIT=300            # seconds for doctor and wire --verify
SUPPORT_WARNING="PLEASE PROOFREAD IT FOR SECRETS OR SENSITIVE INFORMATION AND REDACT ANY BEFORE SENDING"
# a host user or host name this short or this common would match ordinary words: left as is
SUPPORT_COMMON_NAMES=" root admin user media debian ubuntu pi docker mediastack server localhost host "

# ---- the parts (each prints its own lines; a failing command is said, the part goes on) ----
sp_list() { if [[ -n "$1" ]]; then sed 's/^/  /' <<<"$1"; else echo "  (none)"; fi; }   # sp_list TEXT — indented, or (none)
sp_try() { # sp_try LABEL CMD... — run CMD; its output, or why there is none
    local out rc=0
    out=$("${@:2}" 2>&1) || rc=$?
    if (( rc )); then printf '%s: (unavailable: exit %s) %s\n' "$1" "$rc" "$(oneline "$out")"
    else printf '%s: %s\n' "$1" "$out"; fi
}

support_stamp() { # the system: enough to rule the host out, or to build one like it
    local dev mtu cpu
    echo "## hardware"
    cpu=$(lscpu 2>/dev/null | sed -n 's/^Model name: *//p' | sed -n 1p) || true
    printf 'cpu: %s; %s logical CPUs; %s\n' "${cpu:-unknown}" "$(nproc)" "$(uname -m)"
    lscpu 2>/dev/null | grep -E '^(Thread\(s\) per core|Core\(s\) per socket|Socket\(s\)):' || true
    awk '/^(MemTotal|SwapTotal):/ { printf "%s %.1f GiB\n", $1, $2 / 1048576 }' /proc/meminfo
    sp_try "virtualisation" systemd-detect-virt
    if compgen -G '/dev/dri/*' >/dev/null; then echo "gpu: /dev/dri present ($(ls /dev/dri | paste -sd' ' -))"; else echo "gpu: no /dev/dri"; fi
    command -v nvidia-smi >/dev/null && sp_try "nvidia" nvidia-smi -L
    echo; echo "## where the stack writes"
    local level mnt labels size avail itot ifree src
    while IFS=$'\t' read -r level mnt labels size avail itot ifree; do
        src=$(fs_source_of "$mnt")
        printf '%s (%s): %s, %s, %s, %s\n' "$mnt" "$labels" "$(disk_words "$size" "$avail" "$itot" "$ifree")" \
            "$(fstype_of "$mnt")" "$(case "$(lsblk -dno ROTA "$src" 2>/dev/null || true)" in *1*) echo 'rotational as the disk reports it (a VM'"'"'s virtual disk often says so)' ;; *0*) echo 'not rotational as the disk reports it' ;; *) echo 'rotational: unknown (not a local disk)' ;; esac)" "$level"
    done < <(disk_report)
    echo; echo "## software"
    sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"' | sed 's/^/os: /'
    echo "kernel: $(uname -r)"
    sp_try "docker engine" sudo docker version --format '{{.Server.Version}}'
    sp_try "docker compose" sudo docker compose version --short
    sp_try "docker storage, cgroup" sudo docker info --format '{{.Driver}}, cgroup v{{.CgroupVersion}}'
    echo "bash: ${BASH_VERSION}"
    sp_try "awk" bash -c 'awk --version 2>/dev/null | sed -n 1p || awk -W version 2>&1 | sed -n 1p'
    sp_try "jq" jq --version
    sp_try "curl" bash -c 'curl --version | sed -n 1p'
    sp_try "sudo" bash -c 'sudo -V | sed -n 1p'
    echo; echo "## network and clocks"
    if [[ -n "$(ip -6 route show default 2>/dev/null || true)" ]]; then echo "ipv6: a default route"; else echo "ipv6: no default route"; fi
    dev=$(ip -4 route show default 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1) }' | sed -n 1p) || true
    mtu=$(cat "/sys/class/net/${dev:-none}/mtu" 2>/dev/null || true)
    echo "default interface: ${dev:-none}, MTU ${mtu:-unknown}"
    echo "host time: $(date --iso-8601=seconds)"
    sp_try "ntp synchronised" timedatectl show -p NTPSynchronized --value
    sp_try "host time zone" timedatectl show -p Timezone --value
    echo "stack time zone (TZ): $(env_get TZ)"
}

support_install() { # the code and what is yours
    echo "commit: $(run_commit)"
    echo "env schema: $(env_get ENV_SCHEMA) (this script: $SCRIPT_SCHEMA)"
    echo "local edits to tracked files (git status):"
    sp_list "$(git -c safe.directory="$SCRIPT_DIR" -C "$SCRIPT_DIR" status --short -uno 2>&1 || true)"
    echo "files in custom/ (names only — --custom adds their contents):"
    sp_list "$(find "$SCRIPT_DIR/custom" -type f -printf '%P (%s bytes)\n' 2>/dev/null | sort || true)"
}

support_settings() { # .env: what differs from .env.example — secrets as <set>, keys the schema does not know by name only
    local line k v t same=0
    local -A typ=() shipped=()
    while IFS=$'\t' read -r k t _; do typ[$k]=$t; done < <(env_schema_known "$ENV_FILE" all 2)   # one pass over the schema, not one per key
    while IFS= read -r line; do [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] && shipped[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}; done < "$SCRIPT_DIR/.env.example"
    while IFS= read -r line; do
        [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || continue
        k=${BASH_REMATCH[1]}; v=${BASH_REMATCH[2]}
        t=${typ[$k]:-}
        if [[ -z "$t" ]]; then echo "$k (not a setting the schema knows — value left out)"; continue; fi
        if [[ -n "${shipped[$k]+set}" && "${shipped[$k]}" == "$v" ]]; then same=$((same + 1)); continue; fi
        if [[ "$t" == secret ]]; then echo "$k=$( [[ -n "$v" ]] && echo '<set>' || echo '<empty>')"
        else echo "$k=$v"; fi
    done < "$ENV_FILE"
    echo "($same more as shipped in .env.example — not listed)"
}

support_stack() { # each container, then the timers, restore points and pins
    local names
    names=$(sudo docker ps -a --format '{{.Names}}' --filter 'name=^mediastack-' | sort) || true
    if [[ -z "$names" ]]; then echo "no mediastack containers"; else
        # shellcheck disable=SC2086  # a word list of container names
        sudo docker inspect $names | jq -r '.[] |
            "\(.Name | ltrimstr("/")): \(.State.Status)\(if .State.Health then ", health " + .State.Health.Status else "" end), restarts \(.RestartCount), exit \(.State.ExitCode)\(if .State.OOMKilled then ", OOM-KILLED" else "" end), started \(.State.StartedAt)\n  image \(.Config.Image) \(.Image[7:19])" +
            (if .State.Health then
                ([.State.Health.Log[-3:][] | select(.ExitCode != 0)] as $bad
                 | if ($bad | length) == 0 then "\n  health checks: the last \(.State.Health.Log[-3:] | length) passed"
                   else "\n" + ([$bad[] | "  check \(.End[0:19]) failed: exit \(.ExitCode) \(.Output | gsub("\\s+"; " ") | .[0:200])"] | join("\n")) end)
             else "" end)'
        echo
        echo "images (created, pulled, version label):"
        # shellcheck disable=SC2046,SC2086  # word lists of image ids and container names
        sudo docker image inspect $(sudo docker inspect --format '{{.Image}}' $names | sort -u) 2>/dev/null | jq -r '.[] |
            "  \((.RepoTags // ["<untagged>"])[0]): created \(.Created[0:19]), pulled \(.Metadata.LastTagTime[0:19] // "?"), version \(.Config.Labels["org.opencontainers.image.version"] // "-")"' || true
    fi
    echo; echo "timers:"
    systemctl list-timers 'mediastack-*' --all --no-pager 2>&1 | sed 's/^/  /' || true
    echo "failed units:"
    sp_list "$(systemctl list-units 'mediastack-*' --state=failed --no-pager --plain --no-legend 2>&1 || true)"
    echo; echo "restore points:"
    timeout "$SUPPORT_WAIT" "$SCRIPT_DIR/mediastack.sh" backup list 2>&1 | sed 's/^/  /' || true
    echo "pins (local/pins.yml):"
    if [[ -s "$PINS_FILE" ]]; then sed 's/^/  /' "$PINS_FILE"; else echo "  (none)"; fi
}

support_markers() { # what the stack is in the middle of: names and dates, values only where they are the point
    local f k v
    v=$(stack_down_since); echo "stopped with down: ${v:-no}"
    if [[ -e "$STOP_MARKER" ]]; then echo "services a backup stopped: $(head -1 "$STOP_MARKER") (since $(date -r "$STOP_MARKER" --iso-8601=seconds))"
    else echo "services a backup stopped: none"; fi
    v=$(state_get "$LEAK_GATE"); echo "leak gate: ${v:-open}"
    for k in WIRE_REPOINT UID_HANDOVER; do v=$(state_get "$k"); echo "pending $k: ${v:-none}"; done
    echo "maintenance lock: $(flock -n "$MAINT_LOCK" true 2>/dev/null && echo free || echo held)"
    echo "mediastack runs going now:"
    pgrep -af 'mediastack\.sh' 2>/dev/null | grep -v " support" | sed 's/^/  /' || echo "  (none)"
    echo "local/state (names and dates only):"
    sp_list "$(for f in "$STATE_DIR"/*; do [[ -e "$f" ]] && echo "${f##*/} ($(date -r "$f" --iso-8601=seconds))"; done; true)"
}

support_doctor() { timeout "$SUPPORT_WAIT" "$SCRIPT_DIR/mediastack.sh" doctor 2>&1; }
support_verify() { timeout "$SUPPORT_WAIT" "$SCRIPT_DIR/mediastack.sh" wire --verify 2>&1; }

support_record_verb() { local n=${1##*/}; n=${n:16}; n=${n%-*.log}; echo "${n%%--*}"; }   # 20261113-011537-vpn-watch--full-1.log -> vpn-watch
support_records() { # the newest of yours and the occasional timers, the latest of each routine one, every failed or unfinished one of the last 7 days
    local d f v i since=$(( EPOCHSECONDS - 7 * 86400 )) n=0
    local -a all=() pick=()
    local -A latest=()
    d=$(run_records_dir)
    for f in "$d"/*.log; do
        [[ -e "$f" && "$f" != "${MS_RUN_RECORD:-}" ]] || continue
        [[ "$SUPPORT_NOT_RECORDS" == *" $(support_record_verb "$f") "* ]] && continue
        all+=("$f")
    done
    (( ${#all[@]} )) || { echo "(no run records in local/runs/)"; return 0; }
    for (( i = ${#all[@]} - 1; i >= 0; i-- )); do   # newest first
        f=${all[i]}; v=$(support_record_verb "$f")
        if [[ "$SUPPORT_ROUTINE" == *" $v "* ]]; then
            [[ -n "${latest[$v]:-}" ]] || { latest[$v]=1; pick+=("$f"); continue; }
        elif (( n < SUPPORT_RECORDS )); then n=$((n + 1)); pick+=("$f"); continue
        fi
        (( $(stat -c %Y "$f") >= since )) && ! run_succeeded "$f" && pick+=("$f")
    done
    mapfile -t pick < <(printf '%s\n' "${pick[@]}" | sort)   # oldest first, as they ran
    for f in "${pick[@]}"; do
        echo "--- ${f##*/}"
        head -n 6 "$f"
        tail -n +7 "$f" | tail -n "$SUPPORT_RECORD_LINES"
    done
}

# ---- redaction ----
support_redaction_rules() { # literal<TAB>replacement<TAB>kind — the exact values this host would give away
    local k v h u n holder asn f
    while IFS=$'\t' read -r k v; do printf '%s\t<secret:%s>\tsecrets\n' "$v" "$k"; done < <(run_secret_pairs)
    # the notification endpoints configure recorded, waiting for wire to store them ("stream<TAB>urls"):
    # secrets too. Other state is not (the portal's address there is the domain, redacted as such)
    f="$STATE_DIR/$NOTIFY_URLS_STATE"
    if [[ -r "$f" ]]; then
        while IFS=$'\t' read -r _ v; do
            [[ -n "$v" ]] && printf '%s\t<secret:state/%s>\tsecrets\n' "$v" "$NOTIFY_URLS_STATE"
        done < "$f"
    fi
    v=$(env_get STACK_DOMAIN); [[ -n "$v" ]] && printf '%s\texample.test\tdomain\n' "$v"
    u=$(stat -c %U "$SCRIPT_DIR"); h=$(getent passwd "$u" | cut -d: -f6)
    [[ -n "$h" && "$h" != / ]] && printf '%s\t~\tpaths\n' "$h"
    [[ ${#u} -ge 4 && "$SUPPORT_COMMON_NAMES" != *" $u "* ]] && printf '%s\t<user>\tnames\n' "$u"
    n=$(hostname)
    [[ ${#n} -ge 3 && "$SUPPORT_COMMON_NAMES" != *" $n "* ]] && printf '%s\t<host>\tnames\n' "$n"
    if [[ -r "$HOSTID_FILE" ]]; then
        holder=$(sed -n 's/^holder //p' "$HOSTID_FILE"); asn=$(sed -n 's/^asn //p' "$HOSTID_FILE")
        [[ -n "$holder" ]] && printf '%s\t<isp>\tisp\n' "$holder"
        [[ -n "$asn" ]] && printf 'AS%s\t<isp>\tisp\n' "$asn"
    fi
    return 0
}

# shellcheck disable=SC2016  # perl, not shell
SUPPORT_REDACT_PL='
use strict; use warnings;
my (%n, @rules, %ip, %ip6, %mail);
open(my $r, "<&=3") or die "no rules: $!";
while (<$r>) { chomp; my ($lit, $rep, $kind) = split /\t/, $_, 3; next unless defined $kind && length $lit; push @rules, [$lit, $rep, $kind]; }
@rules = sort { length($b->[0]) <=> length($a->[0]) } @rules;   # the longest first: a value inside another goes with it
local $/; my $t = <STDIN>;
for my $x (@rules) {
    my ($lit, $rep, $kind) = @$x; my $q = quotemeta $lit; my $c;
    if ($kind eq "names") { $c = ($t =~ s/(?<![\w.-])$q(?![\w-])/$rep/g); }
    elsif ($kind eq "domain") { $c = ($t =~ s/$q/$rep/gi); }
    else { $c = ($t =~ s/$q/$rep/g); }
    $n{$kind} += $c || 0;
}
# URLs that carry a credential: other schemes (Apprise: discord://, tgram://, ntfys://, mailto://...) keep their scheme only
$n{urls} += ($t =~ s{\b(?!(?:https?|ldaps?|file|unix|tcp|udp)://)([a-z][a-z0-9+.-]{1,15})://[^\s"<>`]+}{$1://<redacted>}gi);
$n{urls} += ($t =~ s{\b(https?://)[^\s/\@"<>]+\@}{$1<redacted>\@}gi);
$n{urls} += ($t =~ s{\b(https?://(?:discord(?:app)?\.com|hooks\.slack\.com)/)[^\s"<>`]+}{$1<redacted>}gi);
$n{urls} += ($t =~ s{([?&](?:token|key|apikey|api_key|access_token|secret|password|sig|signature)=)[^&\s"<>`]+}{$1<redacted>}gi);
sub token { my ($h, $k, $p) = @_; $h->{$k} = "<$p-" . (scalar(keys %$h) + 1) . ">" unless exists $h->{$k}; return $h->{$k}; }
$t =~ s{\b[A-Za-z0-9._%+-]+\@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b}{ $n{"e-mails"}++; token(\%mail, lc $&, "email") }ge;
sub private4 { my @o = @_; return 1 if $o[0] == 10 || $o[0] == 127 || $o[0] == 0 || $o[0] >= 224;
    return 1 if $o[0] == 172 && $o[1] >= 16 && $o[1] <= 31; return 1 if $o[0] == 192 && $o[1] == 168;
    return 1 if $o[0] == 169 && $o[1] == 254; return 1 if $o[0] == 100 && $o[1] >= 64 && $o[1] <= 127; return 0; }
# public addresses become tokens, the same address always the same one; private ranges stay (they explain routing)
$t =~ s{(?<![\d.])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?![\d.]*\d)}{
    my @o = ($1, $2, $3, $4);
    ((grep { $_ > 255 } @o) || private4(@o)) ? $& : do { $n{addresses}++; token(\%ip, "$1.$2.$3.$4", "ip") } }ge;
$t =~ s{(?<![\w:])([23][0-9a-f]{3}(?::[0-9a-f]{0,4}){2,7})(?![\w:])}{ $n{addresses}++; token(\%ip6, lc $1, "ip6") }gie;
print $t;
for (sort keys %n) { printf STDERR "%s\t%d\n", $_, $n{$_}; }
'
support_redact() { # support_redact IN OUT COUNTS — rules on fd 3, never on a command line (ps would show them)
    perl -e "$SUPPORT_REDACT_PL" < "$1" > "$2" 2> "$3" 3< <(support_redaction_rules)
}

support_leftover() { # support_leftover FILE -> the first secret or host-specific value still in it ("" when none)
    local lit rep kind
    while IFS=$'\t' read -r lit rep kind; do
        [[ "$kind" == secrets || "$kind" == domain || "$kind" == paths ]] || continue
        (( ${#lit} >= RUNS_SCRUB_MIN )) || continue
        if [[ "$kind" == domain ]]; then grep -qiF -- "$lit" "$1" && { echo "$rep"; return 0; }
        else grep -qF -- "$lit" "$1" && { echo "$rep"; return 0; }; fi
    done < <(support_redaction_rules)
    return 0
}

# ---- the run ----
support_part() { # support_part TITLE FUNCTION — its lines into the bundle; how it went into SUPPORT_SUMMARY
    local tmp rc=0 n
    tmp=$(mktemp)
    ( "$2" ) > "$tmp" 2>&1 || rc=$?
    n=$(grep -c '' "$tmp" || true)
    { printf '\n===== %s =====\n' "$1"; cat "$tmp"
      (( rc )) && printf '(this part ended with exit %s — what it printed is above)\n' "$rc"; } >> "$SUPPORT_RAW"
    rm -f "$tmp"
    SUPPORT_SUMMARY+=("$(printf '%-28s %6s lines%s' "$1" "$n" "$( (( rc )) && echo "  — ended with exit $rc")")")
}

cmd_support() { # support [--note TEXT] — the bundle to send to whoever helps (docs/design-runs.md)
    local note="" ts out counts lan user size kind count taken="" left
    while (( $# )); do case "$1" in
        --note) [[ -n "${2:-}" ]] || die "usage: support [--note \"what went wrong\"]"; note=$2; shift 2 ;;
        *) die "unknown support argument '$1' (usage: support [--note \"what went wrong\"])" ;;
    esac; done
    load_env   # no render: support reads the stack as it is, even one compose cannot render (doctor says why)
    if [[ -z "$note" && -t 0 ]]; then
        read -r -p "In one line, what went wrong? (Enter to skip) " note || true
    fi
    SUPPORT_DIR="$LOCAL_DIR/support"
    mkdir -p "$SUPPORT_DIR"; chmod 700 "$SUPPORT_DIR"; repo_owned "$LOCAL_DIR" "$SUPPORT_DIR"
    ts=$(date +%Y%m%d-%H%M%S); out="$SUPPORT_DIR/support-$ts.txt"
    SUPPORT_RAW=$(mktemp); counts=$(mktemp); SUPPORT_SUMMARY=()
    info "building the bundle — doctor and wire --verify take a minute or two"
    { echo "# mediastack support bundle — made $(date --iso-8601=seconds) by \`./mediastack.sh support\`"
      echo "# commit $(run_commit)"
      echo "# What went wrong, in the sender's words: ${note:-(not given)}"; } > "$SUPPORT_RAW"
    support_part "the system" support_stamp
    support_part "the install" support_install
    support_part "settings (.env)" support_settings
    support_part "the stack" support_stack
    support_part "in progress" support_markers
    support_part "doctor" support_doctor
    support_part "wire --verify" support_verify
    support_part "run records" support_records
    ( umask 077; support_redact "$SUPPORT_RAW" "$out" "$counts" ) || { rm -f "$SUPPORT_RAW" "$counts" "$out"; die "support: the redaction failed — no bundle written"; }
    rm -f "$SUPPORT_RAW"
    left=$(support_leftover "$out")
    if [[ -n "$left" ]]; then
        rm -f "$out" "$counts"
        die "support: a value that must not leave this host survived the redaction ($left) — the bundle was deleted. This is a bug: please report it without the bundle."
    fi
    while IFS=$'\t' read -r kind count; do (( count > 0 )) && taken+="${taken:+, }$count $kind"; done < "$counts"
    rm -f "$counts"
    sed -i "3a # Taken out before it was written: ${taken:-nothing}" "$out"
    repo_owned "$out"
    size=$(du -h "$out" | cut -f1)
    user=$(stat -c %U "$SCRIPT_DIR")
    lan=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1) }' | sed -n 1p) || true
    hr "support: the bundle"
    echo "What is in it:"; printf '  %s\n' "${SUPPORT_SUMMARY[@]}"
    echo "Taken out: ${taken:-nothing}"
    echo "File: $out ($size)"
    echo "Read it first: cat $out   (or open it in any text editor)"
    echo "Copy it to your own computer — run this there, not here:"
    echo "  scp $user@${lan:-THIS-HOST-ADDRESS}:$out ."
    echo "Send it by e-mail to whoever helps you. A GitHub issue on this project is public:"
    echo "anyone can read what you attach there, so the redaction is all that protects it."
    echo "Nothing was sent."
    echo
    echo "${C_BLD}${SUPPORT_WARNING}${C_RST}"
}
