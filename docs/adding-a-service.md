# Adding a service

Your services live in `docker-compose.override.yml` — untracked, merged
into every stack operation automatically, and upgrade-safe. Never add
services to `compose.d/` or edit `docker-compose.yml`: those are the
repo's territory, and local changes there block `upgrade` by design.

`./mediastack.sh new-service myapp` does the whole thing at a terminal:

1. asks for the image (verified against its registry — an unverifiable
   image is a question, not a silent accept), the port the app listens on
   inside its container, the HTTPS hostname (default: the name), a
   description, VPN membership (default off — acquisition apps in, serving
   apps out), whether it has a config folder, its data access (none /
   media read-only for serving / torrent+media read-write as one mount for
   acquisition, so imports hardlink), and whether the image honours
   PUID/PGID (answer no for root-by-design images: the variables are
   omitted and `doctor` won't expect a non-root process);
2. writes a complete service into `docker-compose.override.yml` on the
   toggle model (metadata labels only — `vpn_gen` generates its network,
   host port and Traefik route), verifies it renders and rolls back if not;
3. refuses a host port that something enabled already publishes and asks
   for another (`MYAPP_PORT` in `.env`), allocates `MYAPP_UID`/`MYAPP_UPDATE`
   like any new fragment, then — on "Start it now?" — enables it (system
   user, folders, start), waits for it to report healthy and prints its URL.
   "n" prints the `enable` command for later.

The result is an ordinary override service: edit the YAML any time,
compose merges it, and `upgrade` never touches it.

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
| `mediastack.transcode: "true"` | owns `${TRANSCODE_ROOT}/<service>` (provisioned, never backed up) — for apps that write video segments while streaming; the root is local disk or a tmpfs by design |
| `mediastack.internal: "true"` | reachable on the LAN only — status marks it instead of printing a URL |
| `mediastack.subdomain: "x"` | default hostname for the status URL column (`<X>_HOST` in `.env` overrides) |
| `mediastack.port: "1234"` | the port the app listens on INSIDE its container — `vpn_gen`'s published port, the Traefik backend port, and what other containers dial. The host-side port is derived from the rendered `ports:` (`svc_port`), so a `${MYAPP_PORT:-1234}:1234` mapping keeps the status table, `wire`'s API calls and the readiness gates on the overridden port |
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

Host ports must be unique across everything enabled. `up` and `enable` refuse
to proceed when two services would publish the same host port (a VPN'd
service's port counts against gluetun, which publishes it), naming both;
`doctor` reports the same finding. Fix by setting `<SVC>_PORT=<free port>` in
`.env` for one of them.

## Removing your service

```
./mediastack.sh disable myapp          # stops and removes its container
# delete its block from docker-compose.override.yml (remove the file if it was the only one)
sed -i '/^MYAPP_/d' .env               # its UID/UPDATE/PORT/VPN/HOST variables
sudo rm -rf config/myapp               # its settings, if you're sure
./mediastack.sh up                     # regenerates local/vpn-overlay.yml without it
```

`up` must be the step that follows the deletion: the generated overlay still
carries the service's network/port stanza until then, and `status`/`doctor`
cannot render with it (they say so and point here).

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
