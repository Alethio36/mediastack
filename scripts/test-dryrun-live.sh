#!/usr/bin/env bash
# test-dryrun-live.sh — the rules scripts/dryrun-live.sh judges a dry run by
# (its --judge): every read mediastack makes passes, every kind of write is
# caught, and a write is named without its body or headers (they carry secrets).
# The live run itself needs a running stack; these are its rules, in CI.
#
#   scripts/test-dryrun-live.sh     run (exit 1 on the first failed check)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

checks=0
judge() { scripts/dryrun-live.sh --judge "$@"; }
ok_()    { local v; v=$(judge "$@"); [[ "$v" == ok ]] || { echo "FAIL must pass: $* (got: $v)" >&2; exit 1; }; checks=$((checks+1)); }
write_() { local v; v=$(judge "$@"); [[ "$v" == write:* ]] || { echo "FAIL must be a write: $* (got: $v)" >&2; exit 1; }; checks=$((checks+1)); }

# ---- curl ----
ok_    curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:8989/api/v3/system/status
ok_    curl -sS -X GET -H 'X-Api-Key: k' http://127.0.0.1:7878/api/v3/rootfolder
ok_    curl -s -I https://portal.example.com/-/health/ready/
ok_    curl -s -X POST http://127.0.0.1:8000/get/mediastack
ok_    curl -sS -X POST -d '{"username":"u","password":"p"}' http://127.0.0.1:13378/login
ok_    curl -sS --data 'username=u&password=p' http://127.0.0.1:8080/api/v2/auth/login
ok_    curl -sS -X POST -d '{"Username":"u","Pw":"p"}' http://127.0.0.1:8096/Users/AuthenticateByName
ok_    curl -sS -d '{"method":"core.get_config_values","params":[["download_location"]],"id":1}' http://127.0.0.1:8112/json
ok_    curl -sS -d '{"method":"session-get"}' http://127.0.0.1:9091/transmission/rpc
write_ curl -sS -X PUT -d '{}' http://127.0.0.1:7878/api/v3/config/host
write_ curl -sS -X DELETE http://127.0.0.1:7878/api/v3/rootfolder/1
write_ curl -sS -X PATCH -d '{"base_url":"x"}' http://127.0.0.1:9000/api/v3/admin/settings/
write_ curl -sS -d '{"body":"x","tag":"ops"}' http://127.0.0.1:8000/notify/mediastack
write_ curl -sS -X POST http://127.0.0.1:9000/api/v3/managed/blueprints/bp/apply/
write_ curl -sS -d '{"method":"core.set_config","params":[{}]}' http://127.0.0.1:8112/json
write_ curl -sS -d '{"method":"session-set"}' http://127.0.0.1:9091/transmission/rpc
write_ curl -sS --json '{"a":1}' http://127.0.0.1:5055/api/v1/settings/main
v=$(judge curl -sS -X PUT -H 'X-Api-Key: SECRETKEY' -d '{"password":"SECRETPW"}' 'http://127.0.0.1:7878/api/v3/x?apikey=SECRETQ')
[[ "$v" != *SECRET* ]] || { echo "FAIL a write is named without its secrets: $v" >&2; exit 1; }; checks=$((checks+1))

# ---- docker ----
ok_    docker inspect --type container mediastack-radarr
ok_    docker ps -aq
ok_    docker image inspect img:latest
ok_    docker manifest inspect img:latest
ok_    docker buildx imagetools inspect img:latest
ok_    docker compose --project-directory /r -f a.yml --profile '*' config --format json
ok_    docker compose --project-directory /r -f a.yml --dry-run up -d --remove-orphans
ok_    docker compose --project-directory /r -f a.yml run --rm -t --no-deps recyclarr sync --preview --config /config/recyclarr.preview.yml
ok_    docker exec mediastack-authentik-worker ak apply_blueprint --dry-run mediastack/mediastack-portal.yaml
ok_    docker exec mediastack-gluetun wget -qO- --timeout=5 https://ipinfo.io
ok_    docker exec mediastack-gluetun wget -q --spider --timeout=8 https://github.com
ok_    docker exec mediastack-gluetun wget -qS -O /dev/null --timeout=5 http://127.0.0.1:8008/v1/vpn/status
ok_    docker exec -u 0 mediastack-gluetun iptables -S
ok_    docker exec mediastack-gluetun ip -o addr
write_ docker compose --project-directory /r -f a.yml up -d
write_ docker compose --project-directory /r -f a.yml pull radarr
write_ docker compose --project-directory /r -f a.yml run --rm --no-deps recyclarr sync
write_ docker restart mediastack-authentik-ldap
write_ docker stop mediastack-radarr
write_ docker pull img:latest
write_ docker exec mediastack-authentik-worker ak create_recovery_key 10 akadmin
write_ docker exec mediastack-jellyfin sh -c 'rm -rf /config/x'
write_ docker exec mediastack-gluetun wget -q -O /tmp/x https://example.com
write_ docker network create x

# ---- sudo ----
ok_    sudo -v
ok_    sudo -n docker inspect mediastack-radarr
ok_    sudo test -d /srv/config/recyclarr
ok_    sudo cmp -s a b
ok_    sudo du -sk /srv/config
ok_    sudo timeout 300 du -sb /srv/data
ok_    sudo timeout -k 60 30 find /srv -type f -printf '%s\n'
ok_    sudo find /srv/audit -maxdepth 1 -name '*.tsv' -newermt '7 days ago' -exec cat {} +
ok_    sudo sh -c 'command -v conntrack'
ok_    sudo systemctl is-active mediastack-update.timer
ok_    sudo tee /srv/config/recyclarr/recyclarr.preview.yml
ok_    sudo rm -f /srv/config/recyclarr/recyclarr.preview.yml
write_ sudo docker compose -f a.yml up -d
write_ sudo tee /srv/config/recyclarr/recyclarr.yml
write_ sudo rm -f /srv/config/x
write_ sudo find /srv -type d -exec chmod g+s {} +
write_ sudo find /srv -name '*.tmp' -delete
write_ sudo mkdir -p /srv/x
write_ sudo chown 1:1 /srv/x
write_ sudo systemctl restart mediastack-panel
write_ sudo sh -c 'sha256sum * > SHA256SUMS'
write_ sudo timeout 10 tcpdump -lni any 'port 53'

echo "OK dryrun-live rules: $checks checks"
