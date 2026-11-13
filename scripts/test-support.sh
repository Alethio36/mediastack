#!/usr/bin/env bash
# test-support.sh — `support` (lib/support.sh, docs/design-runs.md):
#   * one 0600 text file in local/support/, its parts each named, a part that
#     fails said and the rest still there; the sender's note at the top
#   * redaction: every secret .env holds (and a one-shot URL in local/state),
#     the domain (any case, its names kept), e-mails, public addresses (the
#     same one, the same token; private ones kept), the ISP's name and AS
#     number, the owner's home, credential URLs (Apprise schemes, user:pass@,
#     webhooks, token= parameters) — none survive; counted by kind
#   * settings: secrets as <set>/<empty>, keys the schema does not know by
#     name only
#   * run records: the newest 10 and every failed one of the last 7 days
#   * a value the redaction missed deletes the bundle and fails loud
#   * the summary: the file, how to read it, the scp line, the public-issue
#     warning, and — the very last line — the proofread warning
# Sources the real entrypoint (minus its last line, main "$@"); docker, sudo,
# systemctl, doctor and wire --verify are stubs.
#
#   scripts/test-support.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-support.XXXXXX)
T=$(mktemp -d); export T
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; [[ -s "$T/out" ]] && { echo "--- output:" >&2; cat "$T/out" >&2; }; exit 1; }

home=$(getent passwd "$(stat -c %U "$PWD")" | cut -d: -f6)
cat > "$T/fx.sh" <<EOF
source "$PWD/$lib"; set +e +E; trap - ERR
LOCAL_DIR=\$T/local; STATE_DIR=\$T/local/state; ENV_FILE=\$T/env; HOSTID_FILE=\$T/local/host-identity; PINS_FILE=\$T/local/pins.yml
sudo() { "\$@"; }; systemctl() { echo "(no systemd here)"; }; repo_owned() { :; }
CUSTOM_DIR=\$T/custom
# the outside: every name resolves but one, one site does not answer; the portal's name points here
getent() { case "\$1 \$2" in
    "ahosts ghcr.io") return 2 ;;
    "ahostsv4 portal.media.example-real.com") echo "192.168.70.36 STREAM portal" ;;
    ahosts*) echo "1.2.3.4 STREAM \$2" ;;
    *) command getent "\$@" ;; esac; }
curl() { [[ "\$*" == *api.nordvpn.com* ]] && { echo "curl: (28) Connection timed out after 8001 ms"; return 28; }; printf '200 0.120000'; }
hostname() { [[ "\${1:-}" == -I ]] && echo "192.168.70.36 172.17.0.1" || command hostname "\$@"; }
journalctl() { case "\$*" in
    "-k "*) echo "2026-11-12T03:00:00 kernel: Out of memory: Killed process 4242 (jellyfin)"; echo "2026-11-12T03:00:01 kernel: unrelated line" ;;
    "-u docker"*) echo "2026-11-13T01:00:00 dockerd[1]: level=error msg=\"pull failed for 203.0.113.9\""; echo "-- No entries --" ;; esac; }
docker() { # two containers: one healthy (its checks' noisy output), one whose last check failed
    case "\$*" in
        "ps -a"*) printf 'mediastack-good\nmediastack-bad\n' ;;
        "inspect --format"*) printf 'sha256:aaa\nsha256:bbb\n' ;;
        "inspect "*) cat "\$T/inspect.json" ;;
        "image inspect"*) echo '[]' ;;
        "logs --tail 300 -t mediastack-jellyfin") echo "2026-11-13T01:00:00Z user bob@home.example signed in from 203.0.113.9" ;;
        "logs "*) echo "Error: No such container"; return 1 ;;
        *) return 1 ;;
    esac
}
support_doctor() { echo "doctor: ACME mail nick.real@gmail.com, key 0123456789abcdef0123456789abcdef"; }
support_verify() { echo "verify: a write would happen"; return 3; }
EOF
reset() {
    rm -rf "$T/local"; mkdir -p "$T/local/state" "$T/local/runs"
    cat > "$T/env" <<EOF
ENV_SCHEMA=$(sed -n 's/^SCRIPT_SCHEMA=//p' mediastack.sh)
TZ=America/Los_Angeles
STACK_DOMAIN=media.example-real.com
ARR_PASSWORD=Sup3rS3cretArrPass
JELLYFIN_API_KEY=0123456789abcdef0123456789abcdef
ACME_EMAIL=nick.real@gmail.com
MY_OWN_THING=private-value-123
EOF
    printf 'ops\tdiscord://12345/abcdefTOKENxyz\n' > "$T/local/state/notify-urls"
    echo "https://portal.media.example-real.com" > "$T/local/state/AUTHENTIK_BASE_URL"   # not a secret: the domain
    printf 'asn 20055\nholder AS-WHOLESAIL - Wholesail networks LLC\n' > "$T/local/host-identity"
    echo LOG_MAX_SIZE=10m >> "$T/env"   # as shipped: counted, not listed
    cat > "$T/inspect.json" <<'J'
[{"Name":"/mediastack-good","RestartCount":0,"Image":"sha256:aaaaaaaaaaaaaaaaaaaa","Config":{"Image":"x/good:latest"},
  "State":{"Status":"running","ExitCode":0,"OOMKilled":false,"StartedAt":"2026-11-13T05:47:00Z","Health":{"Status":"healthy","Log":[
    {"End":"2026-11-13T01:31:36.1","ExitCode":0,"Output":"<!DOCTYPE html> noisy page"},{"End":"2026-11-13T01:32:06.1","ExitCode":0,"Output":"<!DOCTYPE html> noisy page"},
    {"End":"2026-11-13T01:32:36.1","ExitCode":0,"Output":"<!DOCTYPE html> noisy page"}]}}},
 {"Name":"/mediastack-bad","RestartCount":4,"Image":"sha256:bbbbbbbbbbbbbbbbbbbb","Config":{"Image":"x/bad:latest"},
  "State":{"Status":"running","ExitCode":0,"OOMKilled":true,"StartedAt":"2026-11-13T05:47:00Z","Health":{"Status":"unhealthy","Log":[
    {"End":"2026-11-13T01:31:36.1","ExitCode":0,"Output":"ok"},{"End":"2026-11-13T01:32:06.1","ExitCode":1,"Output":"connection refused\n on 8080"}]}}}]
J
}
rec() { # rec NAME EXIT|- LINE... — a run record (- : never finished)
    local f="$T/local/runs/$1" x=$2; shift 2
    { printf '# mediastack run\nverb:     x\ncommit:   x\nby:       terminal\nstarted:  t\n---\n'
      printf '01:00:00 %s\n' "$@"
      [[ "$x" == - ]] || printf -- '---\nexit:     %s after 1s\n' "$x"; } > "$f"
}
run() { bash -c "source \"\$T/fx.sh\"; $1" > "$T/out" 2>&1 < /dev/null; }
bundle() { ls "$T"/local/support/support-*.txt 2>/dev/null | tail -n 1; }

# ---- a bundle ----
reset
rec 20261113-010000-leak-test-1.log 1 \
    "OK tunnel exits at 187.15.91.164 (Datacamp): not your ISP's (AS20055, 61 blocks)" \
    "your ISP's network is AS20055 (AS-WHOLESAIL - Wholesail networks LLC); the tunnel again 187.15.91.164; LAN 192.168.69.1, stack 172.31.250.3" \
    "portal https://portal.media.example-real.com and ldap.MEDIA.Example-Real.com:443" \
    "webhook https://discord.com/api/webhooks/1111/abcSECRET, https://admin:pw123@host.lan/x?token=zzz9&a=1, tgram://bot:chat" \
    "config at $home/mediastack/config, mail nick.real@gmail.com, pw Sup3rS3cretArrPass, url discord://12345/abcdefTOKENxyz" \
    "ipv6 2001:db8:85a3::8a2e:370:7334 and fe80::1" \
    "UA Chrome/142.0.0.0 Safari/537.36 from 203.0.113.9 at http://198.51.100.7/x, Version=21.0.0.0, LDAP Authentication_22.0.0.0" \
    "Loaded plugin: TMDb 12.0.0.0 and 192.0.2.44 asked"
run 'cmd_support --note "it broke, my pw is Sup3rS3cretArrPass"' || fail_ "support runs"
b=$(bundle); [[ -n "$b" && "$(stat -c %a "$b")" == 600 ]] || fail_ "one file, yours alone"; pass
for p in "the system" "the install" "settings (.env)" "the stack" "in progress" doctor "wire --verify" "run records"; do
    grep -qx "===== $p =====" "$b" || fail_ "the part '$p' is in it"
done; pass
grep -q '(this part ended with exit 3' "$b" && grep -q 'verify: a write would happen' "$b" || fail_ "a part that fails is said, its output kept"; pass
[[ "$(sed -n 3p "$b")" == "# What went wrong, in the sender's words: it broke, my pw is <secret:ARR_PASSWORD>" ]] || fail_ "the note at the top, redacted too"; pass

# ---- nothing that must not leave ----
for v in Sup3rS3cretArrPass 0123456789abcdef0123456789abcdef abcdefTOKENxyz example-real nick.real 187.15.91.164 \
         20055 Wholesail abcSECRET pw123 zzz9 "bot:chat" "$home/" 2001:db8 private-value-123; do
    grep -qiF -- "$v" "$b" && fail_ "'$v' left in the bundle: $(grep -niF -- "$v" "$b")"
done; pass
grep -qF 'tunnel exits at <ip-1> (Datacamp)' "$b" && grep -qF 'the tunnel again <ip-1>;' "$b" || fail_ "a public address: one token, the same each time"; pass
grep -qF 'LAN 192.168.69.1, stack 172.31.250.3' "$b" && grep -qF 'fe80::1' "$b" || fail_ "private addresses stay"; pass
grep -qE 'UA Chrome/142\.0\.0\.0 Safari/537\.36 from <ip-[0-9]+> at http://<ip-[0-9]+>/x, Version=21\.0\.0\.0, LDAP Authentication_22\.0\.0\.0$' "$b" \
    && grep -qE 'Loaded plugin: TMDb 12\.0\.0\.0 and <ip-[0-9]+> asked$' "$b" || fail_ "versions stay, addresses beside them go: $(grep -E 'UA Chrome|Loaded plugin' "$b")"; pass
grep -qF 'https://portal.example.test and ldap.example.test:443' "$b" || fail_ "the domain, any case, keeps its names"; pass
grep -qF '(<isp>, 61 blocks)' "$b" && grep -qF 'is <isp> (<isp>)' "$b" || fail_ "the ISP's number and name"; pass
grep -qF 'https://discord.com/<redacted>' "$b" && grep -qF 'https://<redacted>@host.lan/x?token=<redacted>&a=1' "$b" \
    && grep -qF 'tgram://<redacted>' "$b" && grep -qF 'url <secret:state/notify-urls>' "$b" || fail_ "credential URLs keep their host or scheme only"; pass
grep -qF 'config at ~/mediastack/config' "$b" && grep -qF 'mail <email-1>' "$b" || fail_ "home and e-mail"; pass
[[ "$(sed -n 4p "$b")" =~ ^\#\ Taken\ out\ before\ it\ was\ written:\ .*addresses.*domain.*e-mails.*isp.*secrets.*urls ]] || fail_ "what was taken out, by kind: $(sed -n 4p "$b")"; pass

# ---- settings and records ----
grep -qx 'ARR_PASSWORD=<set>' "$b" && grep -qx 'STACK_DOMAIN=example.test' "$b" && grep -qx 'TZ=America/Los_Angeles' "$b" \
    && grep -qx 'MY_OWN_THING (not a setting the schema knows — value left out)' "$b" || fail_ "settings: secrets <set>, unknown keys by name"; pass
! grep -q '^LOG_MAX_SIZE=' "$b" && grep -qxE '\([0-9]+ more as shipped in \.env\.example — not listed\)' "$b" || fail_ "settings as shipped are counted, not listed"; pass
! grep -qF 'secret:state/AUTHENTIK_BASE_URL' "$b" || fail_ "other state is not a secret (the portal's address is the domain)"; pass
grep -qx 'mediastack-good: running, health healthy, restarts 0, exit 0, started 2026-11-13T05:47:00Z' "$b" && grep -qx '  health checks: the last 3 passed' "$b" \
    && ! grep -q 'noisy page' "$b" || fail_ "a healthy container: one line for its checks, no output"; pass
grep -q 'mediastack-bad: running, health unhealthy, restarts 4, exit 0, OOM-KILLED' "$b" && grep -qx '  check 2026-11-13T01:32:06 failed: exit 1 connection refused on 8080' "$b" \
    && ! grep -qx '  check 2026-11-13T01:31:36 failed.*' "$b" || fail_ "an unhealthy one: only its failed checks, their output"; pass
reset
for i in $(seq -w 1 14); do rec "202611${i}-000000-status-$i.log" 0 "status $i"; done
for i in 1 2 3; do rec "2026111${i}-000001-vpn-watch-7$i.log" 0 "watch $i"; done
rec 20261110-000002-vpn-watch-79.log 1 "watch failed"; touch -d '1 day ago' "$T/local/runs/20261110-000002-vpn-watch-79.log"
rec 20261113-000003-doctor-80.log 1 "an old doctor"
rec 20261102-000001-wire-50.log 1 "wire failed"; touch -d '2 days ago' "$T/local/runs/20261102-000001-wire-50.log"
rec 20261103-000001-up-51.log - "up cut off"; touch -d '2 days ago' "$T/local/runs/20261103-000001-up-51.log"
rec 20261101-000001-wire-52.log 1 "old failure"; touch -d '9 days ago' "$T/local/runs/20261101-000001-wire-52.log"
run 'cmd_support --note x' || fail_ "support runs (records)"
b=$(bundle); r=$(grep -c '^--- 2026' "$b")
grep -q 'status 14$' "$b" && grep -q 'status 05$' "$b" && ! grep -q 'status 04$' "$b" && grep -q 'wire failed' "$b" && grep -q 'up cut off' "$b" \
    && ! grep -q 'old failure' "$b" && (( r == 14 )) || fail_ "the newest 10 and the failed or unfinished of the last 7 days ($r)"; pass
grep -q 'watch 3$' "$b" && ! grep -q 'watch 2$' "$b" && grep -q 'watch failed$' "$b" || fail_ "a routine timer: its latest run, and any that failed"; pass
! grep -q 'an old doctor' "$b" || fail_ "no old doctor records (the bundle has a fresh one)"; pass
mapfile -t order < <(grep '^--- 2026' "$b"); [[ "$(printf '%s\n' "${order[@]}" | sort)" == "$(printf '%s\n' "${order[@]}")" ]] || fail_ "in the order they ran"; pass

# ---- reachability ----
reset; rm -rf "$T/custom"; run 'cmd_support --note x' || fail_ "support runs (reach)"
b=$(bundle)
grep -qx "Jellyfin's plugin repository (repo.jellyfin.org): HTTP 200 in 120 ms" "$b" && grep -qx "GitHub's registry, ghcr.io (images) (ghcr.io): its name does not resolve" "$b" \
    && grep -qx "NordVPN's API (the VPN key) (api.nordvpn.com): no answer — curl: (28) Connection timed out after 8001 ms" "$b" \
    || fail_ "each outside address: answered, unresolved, or no answer and why"; pass
grep -qx "the stack's own names (portal.example.test): resolve to this host (192.168.70.36)" "$b" || fail_ "the portal's name points at this host"; pass
! grep -q '===== container logs\|===== custom/\|===== host events' "$b" || fail_ "logs, custom/ and host events only when asked"; pass
grep -qx '  (none)' <(sed -n '/^files in custom/,/^$/p' "$b") || fail_ "no custom/: (none)"; pass

# ---- only when asked ----
reset; mkdir -p "$T/custom/compose.d"; printf 'services:\n  mine:\n    environment:\n      MY_TOKEN: Sup3rS3cretArrPass\n' > "$T/custom/compose.d/mine.yml"
run 'cmd_support --note x --logs jellyfin,nosuch --custom --host-events' || fail_ "support runs (asked)"
b=$(bundle)
grep -qxE '2026-11-13T01:00:00Z user <email-[0-9]+> signed in from <ip-[0-9]+>' "$b" && grep -q "(no logs: is 'nosuch' a service that runs here?" "$b" \
    || fail_ "--logs: each one's lines, redacted; an unknown one said"; pass
grep -qx -- '--- custom/compose.d/mine.yml' "$b" && grep -qx '      MY_TOKEN: <secret:ARR_PASSWORD>' "$b" || fail_ "--custom: the files, a known secret still taken out"; pass
grep -qx '  2026-11-12T03:00:00 kernel: Out of memory: Killed process 4242 (jellyfin)' "$b" && ! grep -q 'unrelated line' "$b" \
    && grep -q 'dockerd\[1\]: level=error msg="pull failed for <ip-' "$b" && ! grep -q -- '-- No entries --' "$b" \
    || fail_ "--host-events: OOM kills and Docker's errors, journalctl's own chatter left out"; pass
grep -qx "Jellyfin's plugin repository (repo.jellyfin.org): HTTP 200 in 120 ms" "$b" || fail_ "reachability timings in ms"; pass
grep -q '^custom/ is in it: secrets you wrote there are not ones the stack knows' "$T/out" && grep -q "^Container logs are in it: they can hold people's names" "$T/out" \
    || fail_ "the summary warns what the asked-for parts may hold"; pass

# ---- the summary ----
mapfile -t L < "$T/out"
[[ "${L[-1]}" == "PLEASE PROOFREAD IT FOR SECRETS OR SENSITIVE INFORMATION AND REDACT ANY BEFORE SENDING" ]] || fail_ "the very last line is the warning: '${L[-1]}'"; pass
grep -q "^File: $b (" "$T/out" && grep -q "^Read it first: cat $b" "$T/out" && grep -qE "^  scp [a-z_][a-z0-9_-]*@[^:]+:$b \.$" "$T/out" \
    && grep -q 'A GitHub issue on this project is public' "$T/out" && grep -q '^Nothing was sent.$' "$T/out" || fail_ "the file, how to read it, the scp line, the public warning"; pass
grep -qE '^  doctor +[0-9]+ lines$' "$T/out" && grep -qE '^  wire --verify +[0-9]+ lines  — ended with exit 3$' "$T/out" || fail_ "each part and how it went"; pass

# ---- a value the redaction misses: no bundle ----
reset; rec 20261113-010000-x-1.log 0 "pw Sup3rS3cretArrPass"
run 'support_redact() { cp "$1" "$2"; : > "$3"; }; cmd_support --note x' && fail_ "a missed secret must fail"
[[ -z "$(bundle)" ]] && grep -qF 'survived the redaction (<secret:ARR_PASSWORD>) — the bundle was deleted' "$T/out" || fail_ "the bundle is deleted, the leak named by its key, not its value"; pass
grep -qF Sup3rS3cretArrPass "$T/out" && fail_ "the refusal never prints the secret"; pass

run 'cmd_support --logs "jelly fin"' && fail_ "a bad service name is refused"
grep -q "support --logs: 'jelly fin' is not a service name" "$T/out" || fail_ "and says what it wants"; pass

# ---- the verb ----
bash -c "source \"$PWD/$lib\"; verb_entry support >/dev/null" || fail_ "support is a verb"; pass
grep -qE '`support( |`)' README.md || fail_ "README documents it"; pass

echo "OK support: $checks checks"
