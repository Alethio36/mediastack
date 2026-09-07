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
| `mediastack.port: "1234"` | the host-side port the service is reached on — drives the status table, `wire`'s API calls, `vpn_gen`'s published port, and the readiness gates |
| `mediastack.desc: "…"` | one-line description shown in the `configure` service picker |
| `traefik.http.routers.*` labels | HTTPS hostname — native Traefik labels, see docs/edge.md |

Labels the arr family carries (only meaningful with `wire arr` / `trash-sync`):

| Label | Meaning |
|---|---|
| `mediastack.arrtype: "sonarr\|radarr\|lidarr"` | which arr this instance is — selects the API version, the download-client category field, and the TRaSH profile menu |
| `mediastack.category: "movies-4k"` | its qBittorrent category (`wire qbit` creates it; `wire arr` sets it on the download client) |
| `mediastack.rootfolder: "/data/media/movies-4k"` | its root folder inside the container (`wire arr` registers it; seerr and jellyfin libraries derive from it) |
| `mediastack.datadirs: "torrent/movies-4k media/movies-4k"` | extra `${DATA_ROOT}` subtrees `configure` provisions for this instance |
| `mediastack.appport: "7879"` | in-app listening port seeded into `config.xml` before first boot — extra instances share gluetun's namespace, so the image default would collide |

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
