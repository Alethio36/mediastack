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
sudo() { "\$@"; }; docker() { return 1; }; systemctl() { echo "(no systemd here)"; }; repo_owned() { :; }
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
    printf 'asn 20055\nholder AS-WHOLESAIL - Wholesail networks LLC\n' > "$T/local/host-identity"
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
    "ipv6 2001:db8:85a3::8a2e:370:7334 and fe80::1"
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
grep -qF 'https://portal.example.test and ldap.example.test:443' "$b" || fail_ "the domain, any case, keeps its names"; pass
grep -qF '(<isp>, 61 blocks)' "$b" && grep -qF 'is <isp> (<isp>)' "$b" || fail_ "the ISP's number and name"; pass
grep -qF 'https://discord.com/<redacted>' "$b" && grep -qF 'https://<redacted>@host.lan/x?token=<redacted>&a=1' "$b" \
    && grep -qF 'tgram://<redacted>' "$b" && grep -qF 'url <secret:state/notify-urls>' "$b" || fail_ "credential URLs keep their host or scheme only"; pass
grep -qF 'config at ~/mediastack/config' "$b" && grep -qF 'mail <email-1>' "$b" || fail_ "home and e-mail"; pass
[[ "$(sed -n 4p "$b")" =~ ^\#\ Taken\ out\ before\ it\ was\ written:\ .*addresses.*domain.*e-mails.*isp.*secrets.*urls ]] || fail_ "what was taken out, by kind: $(sed -n 4p "$b")"; pass

# ---- settings and records ----
grep -qx 'ARR_PASSWORD=<set>' "$b" && grep -qx 'STACK_DOMAIN=example.test' "$b" && grep -qx 'TZ=America/Los_Angeles' "$b" \
    && grep -qx 'MY_OWN_THING (not a setting the schema knows — value left out)' "$b" || fail_ "settings: secrets <set>, unknown keys by name"; pass
reset
for i in $(seq -w 1 14); do rec "202611${i}-000000-status-$i.log" 0 "status $i"; done
rec 20261102-000001-wire-50.log 1 "wire failed"; touch -d '2 days ago' "$T/local/runs/20261102-000001-wire-50.log"
rec 20261103-000001-up-51.log - "up cut off"; touch -d '2 days ago' "$T/local/runs/20261103-000001-up-51.log"
rec 20261101-000001-wire-52.log 1 "old failure"; touch -d '9 days ago' "$T/local/runs/20261101-000001-wire-52.log"
run 'cmd_support --note x' || fail_ "support runs (records)"
b=$(bundle); r=$(grep -c '^--- 2026' "$b")
grep -q 'status 14$' "$b" && grep -q 'status 05$' "$b" && ! grep -q 'status 04$' "$b" && grep -q 'wire failed' "$b" && grep -q 'up cut off' "$b" \
    && ! grep -q 'old failure' "$b" && (( r == 12 )) || fail_ "the newest 10 and the failed or unfinished of the last 7 days ($r)"; pass

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

# ---- the verb ----
bash -c "source \"$PWD/$lib\"; verb_entry support >/dev/null" || fail_ "support is a verb"; pass
grep -qE '`support( |`)' README.md || fail_ "README documents it"; pass

echo "OK support: $checks checks"
