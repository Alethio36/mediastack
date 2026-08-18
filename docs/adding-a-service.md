# Adding a service

The script discovers services from compose labels — it contains no service
lists. Adding one is two touches:

1. `./mediastack.sh new-service myapp` scaffolds `compose.d/myapp.yml`.
   Edit image/ports/volumes, then add `- compose.d/myapp.yml` to the
   `include:` list in `docker-compose.yml`.
2. `./mediastack.sh configure` — it detects the new `MYAPP_UID` /
   `MYAPP_UPDATE` variables, assigns the next free UID, creates the system
   user and config folder. Then `./mediastack.sh enable myapp`.

## The label contract

| Label | Meaning |
|---|---|
| `mediastack.managed: "true"` | required on every service |
| `mediastack.vpn: "true"` | must run inside gluetun (`network_mode: "service:gluetun"`, no own `ports:`) — leak-test enforces both |
| `mediastack.config: "true"` | owns `${CONFIG_ROOT}/<service>` (provisioned, audited, backed up) |
| `mediastack.cache: "true"` | owns `${CACHE_ROOT}/<service>` (provisioned, never backed up) |
| `traefik.http.routers.*` labels | HTTPS hostname — native Traefik labels, see docs/edge.md |

Conventions: config dir name == service name; env var stem == service name
uppercased (`myapp` → `MYAPP_UID`, `MYAPP_UPDATE`, `MYAPP_NAME`, `MYAPP_PORT`).

## Fragment layout and boilerplate

One service per file: service `x` lives in `compose.d/x.yml` — no bucket
files, no judgment calls. Every fragment carries its own `x-logging` and
`x-armour` anchors (YAML anchors do not cross `include:` boundaries).
`x-armour` disables a FOREIGN watchtower on the same host, which would
otherwise auto-update our containers behind the backup/rollback system's
back; our own update pipeline does not use those labels.

## Changing a shipped service

Don't edit tracked files — put overrides in `docker-compose.override.yml`
(gitignored, auto-loaded by compose). Your changes then survive every
`upgrade`.
