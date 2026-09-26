#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-footprint.sh — everything mediastack puts on the host outside its folder.
#   * CI guard: every literal outside-repo path a lib writes with sudo (tee,
#     install, cp, mv, mkdir, ln) and every path constant for such a write
#     falls under FOOTPRINT_PREFIXES — a new feature cannot add clutter the
#     registry does not know about
#   * add-mount's marker: only marked fstab entries are mediastack's; your own
#     lines, and a marker whose next line is not its entry, are never claimed
#   * a mount is removed whole (fstab entry + marker, credentials, empty
#     folder), only on a yes (default No), and a busy one is kept untouched
#   * removal through the registry: every present "remove" entry, units
#     stopped first, nothing marked keep/ask/users touched
#
#   scripts/test-footprint.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-footprint.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "OK $*" >> "$T/out"; }; info() { echo "INFO $*" >> "$T/out"; }; warn() { echo "WARN $*" >> "$T/out"; }
under_prefix() { local p; for p in "${FOOTPRINT_PREFIXES[@]}"; do [[ "$1" == "$p"* ]] && return 0; done; return 1; }

# ---- CI guard: writes outside the repo land where the registry looks ----
bad=$(grep -nE 'sudo (tee( -a)?|install|cp|mv|mkdir|ln)( |$)' mediastack.sh lib/*.sh \
      | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
      | grep -oE '^[^:]+:[0-9]+:|"?/(etc|usr|var|opt|srv|lib|boot)/[^" ;|)]*' \
      | awk '/:$/ { loc = $0; next } { gsub(/"/, ""); print loc " " $0 }' \
      | while read -r loc p; do under_prefix "$p" || echo "$loc $p"; done)
[[ -z "$bad" ]] || fail_ "a write outside the repo that no footprint provider owns (add it to a provider and FOOTPRINT_PREFIXES):
$bad"; pass
for v in FRONTDOOR_SUDOERS FRONTDOOR_WRAPPER AUDIT_RULES VPNGUARD_UNIT AUDIT_LOGDIR FSTAB; do
    under_prefix "${!v}" || fail_ "$v=${!v} is outside FOOTPRINT_PREFIXES"; pass
done
for u in "${AUDIT_FOOTPRINT[@]}" "$SYSTEMD_DIR/mediastack-x.timer"; do under_prefix "$u" || fail_ "$u is outside FOOTPRINT_PREFIXES"; pass; done
out=$( (sudo() { echo "WROTE $*"; }; timer_write foo d v hourly) 2>&1 ) && fail_ "a timer not named mediastack-* must be refused"
[[ "$out" == *"must be named mediastack-"* && "$out" != *WROTE* ]] || fail_ "the refusal must come before anything is written: $out"; pass

# ---- the fstab marker ----
FSTAB=$T/fstab
cat > "$FSTAB" <<EOF
UUID=abc / ext4 defaults 0 1
nas:/tv /mnt/mine nfs4 defaults 0 0
# mediastack add-mount /mnt/media
nas:/media /mnt/media nfs4 _netdev,x-systemd.automount,hard,nfsvers=4.2,nofail 0 0
# mediastack add-mount /mnt/smb
//nas/share /mnt/smb cifs _netdev,x-systemd.automount,hard,nofail,credentials=/etc/mediastack-cifs-smb,uid=0 0 0
# mediastack add-mount /mnt/orphan
nas:/other /mnt/elsewhere nfs4 defaults 0 0
EOF
[[ "$(fstab_marked | cut -f1 | tr '\n' ' ')" == "/mnt/media /mnt/smb " ]] || fail_ "marked mounts: $(fstab_marked | cut -f1)"; pass
got=$(fp_mounts | cut -f2,3 | tr '\t\n' ': ')
[[ "$got" == "fstab:/mnt/media fstab:/mnt/smb file:/etc/mediastack-cifs-smb " ]] || fail_ "mount entries: $got"; pass

# ---- removing a mount ----
sudo() { # the host, faked: root-owned places become $T/root, commands are logged
    case "$1" in
        systemctl|umount|chattr|rmdir) echo "$*" >> "$T/log"; [[ "$1" != umount || ! -e "$T/busy" ]] ;;
        rm) shift; local a; for a in "$@"; do [[ "$a" == -* ]] || echo "rm $a" >> "$T/log"; done ;;
        install) shift 7; cp "$1" "$2" ;;   # install -m 0644 -o root -g root SRC DST
        *) "$@" ;;
    esac
}
findmnt() { [[ "$*" == *"-rn /mnt/"* ]]; }   # every marked mount is mounted
systemd-escape() { echo "mnt-${3##*/}.automount"; }
: > "$T/log"; mount_remove /mnt/smb
grep -q '^umount /mnt/smb$' "$T/log" && grep -q '^rm /etc/mediastack-cifs-smb$' "$T/log" && grep -q '^rmdir /mnt/smb$' "$T/log" \
    || fail_ "a removed mount must be unmounted, lose its credentials and folder: $(cat "$T/log")"; pass
grep -q '/mnt/smb' "$FSTAB" && fail_ "the fstab entry and its marker must be gone: $(cat "$FSTAB")"
grep -q '^nas:/tv /mnt/mine' "$FSTAB" && grep -q '^# mediastack add-mount /mnt/media$' "$FSTAB" || fail_ "other lines must stay: $(cat "$FSTAB")"; pass
touch "$T/busy"; cp "$FSTAB" "$T/before"; : > "$T/log"; rm -f "$T/out"
mount_remove /mnt/media
cmp -s "$FSTAB" "$T/before" && ! grep -q '^rm ' "$T/log" && grep -q 'in use' "$T/out" || fail_ "a busy mount must be kept untouched and said so"; pass
rm "$T/busy"
confirm() { return 1; }; : > "$T/log"; footprint_mounts_offer
cmp -s "$FSTAB" "$T/before" && ! grep -q umount "$T/log" || fail_ "No (the default) must keep the mount"; pass
confirm() { return 0; }; footprint_mounts_offer
[[ -z "$(fstab_marked)" ]] || fail_ "yes must remove the offered mount"; pass
grep -q '^nas:/tv /mnt/mine' "$FSTAB" || fail_ "your own fstab entry must never be offered or touched"; pass

# ---- removing through the registry ----
fp_present() { [[ "$2" != *absent* ]]; }   # everything is present except what says otherwise
fp_timers() { printf 'timers\tunit\t%s\tremove\n' /etc/systemd/system/mediastack-a.timer /etc/systemd/system/mediastack-absent.timer; }
fp_panel() { printf 'panel\tfile\t/etc/sudoers.d/mediastack-x\tremove\npanel\tuser\tolivetin\tremove\n'; }
fp_deps() { printf 'deps\tfile\t/etc/apt/sources.list.d/docker.list\tkeep\n'; }
userdel() { echo "userdel $*" >> "$T/log"; }
: > "$T/log"; footprint_remove timers panel deps
[[ "$(cat "$T/log")" == $'systemctl disable --now mediastack-a.timer\nrm /etc/systemd/system/mediastack-a.timer\nrm /etc/sudoers.d/mediastack-x\nuserdel -r olivetin\nsystemctl daemon-reload' ]] \
    || fail_ "registry removal: $(cat "$T/log")"; pass

echo "OK footprint: $checks checks"
