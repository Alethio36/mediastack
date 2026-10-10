#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced libraries
# test-roles.sh — wiring by role (lib/roles.sh). Pins:
#   * every template parses, is named <role>.<consumer>.json for a known role
#     and consumer, and uses only the placeholder vocabulary
#   * a provider of a role ships a template for every consumer of it
#   * placeholders resolve once: .env values are never read as placeholders
#     (braces, backslashes and & in a password survive), {self.port} is a number
#   * providers are the enabled ones, in their priority order; missing
#     credentials are named; the stack uses one (DOWNLOAD_CLIENT, else the
#     first), a setting it cannot honour stops it, and its allowed values are
#     exactly the providers; switching an entry off changes .enable only
#   * what the consumers send for qBittorrent is what they sent before roles
#
#   scripts/test-roles.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lib=$(mktemp .test-roles.XXXXXX)
T=$(mktemp -d)
trap 'rm -rf "$lib" "$T"' EXIT
sed '$d' mediastack.sh > "$lib"
# shellcheck disable=SC1090
source "$lib"

checks=0
pass()  { checks=$((checks+1)); }
fail_() { echo "FAIL: $*" >&2; exit 1; }

ENV_FILE=$T/env
printf '%s\n' 'COMPOSE_PROFILES=gluetun,qbittorrent,radarr' 'QBITTORRENT_USER=admin' 'QBITTORRENT_PASSWORD=p{a}ss\1&x' > "$ENV_FILE"
svc_host()  { echo gluetun; }
svc_cport() { echo 8085; }
svc_addr()  { echo gluetun:8085; }

# ---- the templates themselves ----
for f in services/*/provides/*.json; do
    [[ -e "$f" ]] || continue
    b=$(basename "$f" .json); role=${b%.*}; cons=${b#*.}
    [[ " ${ROLES[*]} " == *" $role "* ]] || fail_ "$f: unknown role '$role' (roles: ${ROLES[*]})"
    [[ " ${ROLE_CONSUMERS[*]} " == *" $cons "* ]] || fail_ "$f: unknown consumer '$cons' (consumers: ${ROLE_CONSUMERS[*]})"
    p=${f#services/}; p=${p%%/*}
    (role_entry "$p" "$role" "$cons" >/dev/null) 2>/dev/null || fail_ "$f: does not resolve (bad JSON or an unknown placeholder)"
done; pass
for d in services/*/provides; do
    [[ -d "$d" ]] || continue
    for role in "${ROLES[@]}"; do
        ls "$d/$role".*.json >/dev/null 2>&1 || continue
        for cons in "${ROLE_CONSUMERS[@]}"; do
            [[ -e "$d/$role.$cons.json" ]] || fail_ "$d provides $role but ships no template for $cons"
        done
    done
done; pass

# ---- resolution ----
e=$(role_entry qbittorrent download-client arr)
[[ "$(jq -c '.fields.port' <<<"$e")" == 8085 ]] || fail_ "{self.port} must become a number"; pass
[[ "$(jq -r '.fields.password' <<<"$e")" == 'p{a}ss\1&x' ]] || fail_ "a .env value is taken as it is: $(jq -r '.fields.password' <<<"$e")"; pass
[[ "$(jq -r '.host' <<<"$(role_entry qbittorrent download-client cleanuparr)")" == http://gluetun:8085 ]] || fail_ "{self.addr} inside a string"; pass
mkdir -p "$T/services/x/provides"
printf '{"fields":{"host":"{self.hots}"}}\n' > "$T/services/x/provides/download-client.arr.json"
(cd "$T" && role_entry x download-client arr >/dev/null 2>&1) && fail_ "an unknown placeholder must fail"; pass
printf '{"fields":{"empty":{}, "host":"{self.host}"}}\n' > "$T/services/x/provides/download-client.arr.json"
(cd "$T" && role_entry x download-client arr >/dev/null 2>&1) || fail_ "an empty JSON object is not a placeholder"; pass

# ---- providers and their credentials ----
[[ "$(role_providers download-client arr)" == qbittorrent ]] || fail_ "the enabled provider: $(role_providers download-client arr)"; pass
mkdir -p "$T/services/a/provides" "$T/services/b/provides"
printf '{"priority":2}\n' > "$T/services/a/provides/download-client.arr.json"
printf '{"priority":1}\n' > "$T/services/b/provides/download-client.arr.json"
printf 'COMPOSE_PROFILES=a,b\n' > "$T/env2"
[[ "$(cd "$T" && ENV_FILE=$T/env2 role_providers download-client arr | paste -sd' ' -)" == "b a" ]] || fail_ "providers come in priority order"; pass
[[ "$(cd "$T" && ENV_FILE=$T/env role_providers download-client arr)" == "" ]] || fail_ "a disabled provider is no provider"; pass
[[ -z "$(role_env_missing qbittorrent download-client arr)" ]] || fail_ "credentials present: nothing missing"; pass
printf 'COMPOSE_PROFILES=qbittorrent\nQBITTORRENT_USER=admin\n' > "$T/env3"
[[ "$(ENV_FILE=$T/env3 role_env_missing qbittorrent download-client arr)" == QBITTORRENT_PASSWORD ]] || fail_ "a missing credential is named"; pass

# ---- the one the stack uses ----
[[ "$(role_pick download-client)" == qbittorrent ]] || fail_ "empty setting: the first enabled"; pass
printf 'COMPOSE_PROFILES=qbittorrent\nDOWNLOAD_CLIENT=qbittorrent\n' > "$T/env4"
[[ "$(ENV_FILE=$T/env4 role_pick download-client)" == qbittorrent ]] || fail_ "the setting is honoured"; pass
printf 'COMPOSE_PROFILES=radarr\nDOWNLOAD_CLIENT=qbittorrent\n' > "$T/env5"
(ENV_FILE=$T/env5 role_pick download-client >/dev/null 2>&1) && fail_ "a setting naming a client that is not enabled must stop wire"; pass
[[ -z "$(ENV_FILE=$T/env5 role_providers download-client arr)" ]] || fail_ "nothing enabled: no provider"; pass
# the note runs inside wire under set -e: one provider (nothing to say) must not
# stop it — a grep finding no other provider once ended wire silently
# (a fresh shell: inside a condition bash ignores set -e, and would hide it)
out=$(ENV_FILE=$ENV_FILE bash -c 'set -euo pipefail; source "$1"; svc_cport() { echo 8085; }; role_pick_note download-client; echo reached' _ "$lib" 2>&1 || true)
[[ "$out" == reached ]] || fail_ "one provider: no note, and wire carries on (got: $out)"; pass
mkdir -p "$T/n/services/a/provides" "$T/n/services/b/provides"
printf '{"priority":1}\n' > "$T/n/services/a/provides/download-client.arr.json"
printf '{"priority":2}\n' > "$T/n/services/b/provides/download-client.arr.json"
printf 'COMPOSE_PROFILES=a,b\n' > "$T/env6"
[[ "$(cd "$T/n" && ENV_FILE=$T/env6 role_pick_note download-client)" == *"download-client: a (also enabled: b)"* ]] || fail_ "two providers: the note names both"; pass
# a template without .env settings: none is no error
printf '{"fields":{"host":"{self.host}"}}\n' > "$T/n/services/a/provides/download-client.prowlarr.json"
[[ -z "$(cd "$T/n" && role_env_names a download-client prowlarr)" ]] || fail_ "no settings read: none named"; pass
# the setting's allowed values are exactly the role's providers, in priority order
allowed=$(awk -F'\t' '$1 == "DOWNLOAD_CLIENT" {sub(/^enum:/, "", $2); print $2}' lib/env.schema.tsv)
want=$(for p in $(role_all_providers download-client arr); do printf '%s\t%s\n' "$(jq -r '.priority // 50' "$(role_file "$p" download-client arr)")" "$p"; done | sort -n -k1,1 -k2,2 | cut -f2 | paste -sd'|' -)
[[ "$allowed" == "$want" ]] || fail_ "DOWNLOAD_CLIENT's enum ($allowed) must list the providers ($want)"; pass
# switching an entry off or on changes .enable only; off skips the app's test
api() { echo "$1 $2" >> "$T/calls"; [[ "$1" == PUT ]] && printf '%s' "$4" > "$T/put"; return 0; }
lst='[{"id":4,"name":"Deluge (mediastack)","enable":true,"fields":[{"name":"password","value":"********"}]}]'
: > "$T/calls"; arr_entry_enable http://h/api/v3 k downloadclient "$lst" "Deluge (mediastack)" false >/dev/null
[[ "$(cat "$T/calls")" == "PUT http://h/api/v3/downloadclient/4?forceSave=true" ]] || fail_ "off: one PUT, forceSave: $(cat "$T/calls")"; pass
[[ "$(jq -c '[.enable, .fields]' "$T/put")" == '[false,[{"name":"password","value":"********"}]]' ]] || fail_ "off changes .enable only: $(cat "$T/put")"; pass
: > "$T/calls"; arr_entry_enable http://h/api/v3 k downloadclient "$lst" "Deluge (mediastack)" true >/dev/null
[[ "$(cat "$T/calls")" == "PUT http://h/api/v3/downloadclient/4" ]] || fail_ "on: the app tests the client as it saves: $(cat "$T/calls")"; pass
arr_entry_enable http://h/api/v3 k downloadclient "$lst" gone true >/dev/null && fail_ "a missing entry is an error"; pass
for f in services/_arr/arr.sh services/prowlarr/prowlarr.sh services/cleanuparr/cleanuparr.sh; do
    grep -q 'role_pick download-client' "$f" && grep -q 'role_all_providers download-client' "$f" \
        || fail_ "$f must wire the picked client and switch the others off"
done; pass

# ---- what the consumers send for qBittorrent: the same as before roles ----
cat='movies'; catfield='movieCategory'
before=$(jq -c . <<<'{"enable":true,"protocol":"torrent","priority":1,
 "removeCompletedDownloads":true,"removeFailedDownloads":true,
 "name":"qBittorrent (mediastack)","implementation":"QBittorrent",
 "implementationName":"qBittorrent","configContract":"QBittorrentSettings",
 "fields":[{"name":"host","value":"gluetun"},{"name":"port","value":8085},{"name":"useSsl","value":false},
   {"name":"username","value":"admin"},{"name":"password","value":"p{a}ss\\1&x"},{"name":"movieCategory","value":"movies"}]}')
now=$(jq -c --arg cf "$catfield" --arg cat "$cat" '{enable: true, protocol, priority,
    removeCompletedDownloads, removeFailedDownloads, name, implementation, implementationName, configContract,
    fields: ([.fields | to_entries[] | {name: .key, value}] + [{name: $cf, value: $cat}])}' <<<"$e")
[[ "$now" == "$before" ]] || fail_ "an arr's qBittorrent entry changed:
  before $before
  now    $now"; pass
grep -qF '{name: $cf, value: $cat}' services/_arr/arr.sh || fail_ "the test's body must be the one wire_arr builds"; pass
c=$(jq -c '{enabled: true} + del(.priority)' <<<"$(role_entry qbittorrent download-client cleanuparr)")
[[ "$c" == "$(jq -cn '{enabled:true,name:"qbittorrent",typeName:"qBittorrent",type:"Torrent",host:"http://gluetun:8085",urlBase:"",username:"admin",password:"p{a}ss\\1&x"}')" ]] \
    || fail_ "cleanuparr's qBittorrent entry changed: $c"; pass
schema='[{"implementation":"QBittorrent","fields":[{"name":"host","value":"localhost"},{"name":"port","value":8080},{"name":"username","value":""},{"name":"password","value":""},{"name":"category","value":""},{"name":"useSsl","value":false}]}]'
pe=$(role_entry qbittorrent download-client prowlarr)
body=$(jq -c --argjson e "$pe" '.name = $e.name | .enable = true | .fields = [ .fields[] | .name as $n
    | if ($e.fields | has($n)) then .value = $e.fields[$n] elif .name == "category" then .value = "prowlarr" else . end ]' <<<"$(jq -c '.[0]' <<<"$schema")")
[[ "$(jq -c '[.name, .enable, (.fields | map({(.name): .value}) | add)]' <<<"$body")" == '["qbittorrent",true,{"host":"gluetun","port":8085,"username":"admin","password":"p{a}ss\\1&x","category":"prowlarr","useSsl":false}]' ]] \
    || fail_ "prowlarr's qBittorrent entry changed: $body"; pass

echo "OK roles: $checks checks"
