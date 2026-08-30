# Adding a service

Your services live in `docker-compose.override.yml` — untracked, merged
into every stack operation automatically, and upgrade-safe. Never add
services to `compose.d/` or edit `docker-compose.yml`: those are the
repo's territory, and local changes there block `upgrade` by design.

1. `./mediastack.sh new-service myapp` scaffolds the service into
   `docker-compose.override.yml` (creates the file if needed, verifies
   the result still renders, rolls back if it doesn't). Edit the image,
   ports and volumes.
2. `./mediastack.sh configure` — detects the new `MYAPP_UID` /
   `MYAPP_UPDATE` variables, assigns the next free UID, creates the
   system user and config folder. Then `./mediastack.sh enable myapp`.

The script discovers services from compose labels — it contains no
service lists, so override services get status rows, doctor checks,
backups and the update pipeline like any shipped service.

## The label contract

| Label | Meaning |
|---|---|
| `mediastack.managed: "true"` | required on every service |
| `mediastack.vpn: "true"` | default VPN membership. On a **toggle-enabled** service this is only the default (override per deployment via `<SVC>_VPN` in `.env` / the `vpn` command); on a **static** service the fragment itself must set `network_mode: "service:gluetun"` with no own `ports:`. `leak-test` audits the live result either way |
| `mediastack.vpntoggle: "true"` | opt into operator-selectable VPN membership: `vpn_gen` generates this service's network, host port and Traefik route from its metadata, so the fragment carries none of those directly. See docs/vpn-membership.md |
| `mediastack.hostport: "false"` | (toggle services only) Traefik-only — publish no host port in either VPN state, for serving apps whose container port would collide on the host (e.g. `:80`). Default `"true"` |
| `mediastack.config: "true"` | owns `${CONFIG_ROOT}/<service>` (provisioned, audited, backed up) |
| `mediastack.cache: "true"` | owns `${CACHE_ROOT}/<service>` (provisioned, never backed up) |
| `mediastack.internal: "true"` | reachable on the LAN only — status marks it instead of printing a URL |
| `mediastack.subdomain: "x"` | default hostname for the status URL column (`<X>_HOST` in `.env` overrides) |
| `traefik.http.routers.*` labels | HTTPS hostname — native Traefik labels, see docs/edge.md |

Conventions: config dir name == service name; env var stem == service name
uppercased (`myapp` → `MYAPP_UID`, `MYAPP_UPDATE`, `MYAPP_NAME`, `MYAPP_PORT`).

## Changing a shipped service

Same file: put overrides for shipped services in
`docker-compose.override.yml` too — compose merges your keys over the
fragment's. See docs/vpn-membership.md for a worked example.

## For contributors: shipped fragments

One service per file: service `x` lives in `compose.d/x.yml` — no bucket
files, no judgment calls. Every fragment carries its own `x-logging` and
`x-armour` anchors (YAML anchors do not cross `include:` boundaries).
`x-armour` disables a FOREIGN watchtower on the same host, which would
otherwise auto-update our containers behind the backup/rollback system's
back; our own update pipeline does not use those labels.
