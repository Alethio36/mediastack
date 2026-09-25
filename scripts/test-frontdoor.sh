#!/usr/bin/env bash
# test-frontdoor.sh — the web panel's security boundary, tested by BEHAVIOUR.
# Renders the real SSH forced-command wrapper from the PANEL table (exactly as
# frontdoor-install does), swaps mediastack.sh for a stub that prints its argv
# and sudo for a pass-through, then feeds it commands as the panel's key would.
# Pins three things:
#   1. every button's command gets through, argv intact
#   2. the CLI-only verbs (docs/frontdoor-safety.md: secrets + blast radius)
#      are refused — adding one to PANEL fails here, not silently in prod
#   3. shell metacharacters and extra arguments are refused
# plus the table's own integrity (verbs exist, entities exist, groups named).
#
#   scripts/test-frontdoor.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-frontdoor.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"

mkdir -p "$T/bin"
printf '#!/usr/bin/env bash\necho "RAN $*"\n' > "$T/mediastack.sh"
printf '#!/usr/bin/env bash\n[[ "$1" == -n ]] && shift\nexec "$@"\n' > "$T/bin/sudo"
chmod +x "$T/mediastack.sh" "$T/bin/sudo"
_fd_wrapper_render "$T/mediastack.sh" > "$T/wrapper"

# ssh_as CMD — run the wrapper as the panel's key would; sets RC and OUT
ssh_as() { set +e; OUT=$(SSH_ORIGINAL_COMMAND="$1" PATH="$T/bin:$PATH" bash "$T/wrapper" 2>&1); RC=$?; set -e; }

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

# 1. every button gets through, placeholders filled the way OliveTin would
for row in "${PANEL[@]}"; do
    IFS='~' read -r _ title _ _ cmd _ _ <<<"$row"
    sample=$(sed -E 's/\{[a-z]+:entity=[^}]*\}/radarr/g; s/\{[a-z]+:choices=([^,}:]+)[^}]*\}/\1/g' <<<"$cmd")
    ssh_as "$sample"
    [[ $RC == 0 && "$OUT" == "RAN $sample" ]] || fail_ "button '$title' ($sample) must pass: rc=$RC $OUT"
done; pass

# 2. never through the panel: secrets, blast radius, host changes, and the
#    two verbs the old hand-kept whitelist allowed with no button (vpn, list)
for cmd in credentials "set-credentials all" "restore --all" "uninstall --nuke" configure install \
           frontdoor-install "new-service x" "add-mount" upgrade "vpn radarr off" "list --json" \
           "manifest --accept" "trash-sync" "invite"; do
    ssh_as "$cmd"
    [[ $RC == 4 && "$OUT" == *"not permitted"* ]] || fail_ "'$cmd' must be refused as not permitted: rc=$RC $OUT"
done; pass

# 3. injection and shape: charset (3), empty (2), argument count (5)
for cmd in 'doctor; id' 'status $(id)' 'status `id`' 'status | cat' 'logs radarr && id' \
           'DOCTOR' 'doctor ' ' doctor' $'doctor\nid' 'logs ../../etc/passwd' 'logs radarr>x'; do
    ssh_as "$cmd"
    [[ $RC == 3 ]] || fail_ "illegal characters must be refused (rc 3): '$cmd' -> rc=$RC $OUT"
done; pass
ssh_as ""
[[ $RC == 2 ]] || fail_ "an empty command must be refused (rc 2): rc=$RC"; pass
ssh_as "logs radarr --no-follow extra"
[[ $RC == 5 ]] || fail_ "more arguments than any button passes must be refused (rc 5): rc=$RC $OUT"; pass

# table integrity
ents=$(_fd_otcfg_tail | sed -n 's/^  - name: //p')
for row in "${PANEL[@]}"; do
    IFS='~' read -r group title _ _ cmd _ flags <<<"$row"
    verb_entry "${cmd%% *}" >/dev/null || fail_ "button '$title' runs '${cmd%% *}', which is not a registry verb"
    [[ -n "${PANEL_GROUP_NOTE[$group]:-}" ]] || fail_ "button '$title': group '$group' has no PANEL_GROUP_NOTE"
    [[ -z "$flags" || "$flags" == single ]] || fail_ "button '$title': unknown flag '$flags'"
    rest=$cmd
    while [[ "$rest" =~ $FD_PLACEHOLDER ]]; do
        [[ "${BASH_REMATCH[2]}" == choices ]] || grep -qx "${BASH_REMATCH[3]}" <<<"$ents" \
            || fail_ "button '$title' reads entity '${BASH_REMATCH[3]}', which the config never defines"
        rest=${rest#*"${BASH_REMATCH[0]}"}
    done
done; pass

echo "OK frontdoor: $checks checks (${#PANEL[@]} buttons)"
