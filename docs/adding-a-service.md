# Adding a service

Your services live in `custom/compose.d/`, one file each — untracked, passed
to compose on every stack operation, and upgrade-safe. Never add services to
`compose.d/` or edit `docker-compose.yml`: those are the repo's territory,
and local changes there block `upgrade` by design. (What you change about a
*shipped* service goes in `custom/override.yml` — see below.)

`./mediastack.sh new-service myapp` does the whole thing at a terminal:

1. asks for the image (verified against its registry — an unverifiable
   image is a question, not a silent accept), the port the app listens on
   inside its container, the HTTPS hostname (default: the name), a
   description, VPN membership (default off — acquisition apps in, serving
   apps out), whether it has a config folder, its data access (none /
   media read-only for serving / torrent+media read-write as one mount for
   acquisition, so imports hardlink), and how the image takes its user
   (PUID/PGID, `user:`, or neither for root-by-design images — see
   *Identity* below; `doctor` fails a service whose processes don't run as
   its UID);
2. writes a complete service into `custom/compose.d/<name>.yml` on the
   toggle model (metadata labels only — `vpn_gen` generates its network,
   host port and Traefik route), verifies it renders and rolls back if not;
3. refuses a host port that something enabled already publishes and asks
   for another (`MYAPP_PORT` in `.env`), allocates `MYAPP_UID`/`MYAPP_UPDATE`
   like any new fragment, then — on "Start it now?" — enables it (system
   user, folders, start), waits for it to report healthy and prints its URL.
   "n" prints the `enable` command for later.

The result is an ordinary compose file: edit it any time — add environment
variables, devices, volumes, or the other containers an app needs (a
database, a cache: one file can hold several services) — and `upgrade` never
touches it. You can also write a file there by hand or drop in one someone
shared; the label contract below is what makes the stack manage it.

Rules for a file in `custom/compose.d/`:

* it has a top-level `services:` block (block YAML, as `new-service` writes);
* it adds services — a name already used by a shipped service or another of
  your files is refused, naming both. To change a shipped service, use
  `custom/override.yml`;
* relative paths resolve from the repo folder, as in every compose file here;
* a container without `mediastack.managed: "true"` runs, but gets no status
  row, backups, doctor checks or updates.

The script discovers services from compose labels — it contains no
service lists, so your services get status rows, doctor checks,
backups and the update pipeline like any shipped service.

## The label contract

| Label | Meaning |
|---|---|
| `mediastack.managed: "true"` | required on every service |
| `mediastack.vpn: "true"` | default VPN membership. On a **toggle-enabled** service this is only the default (override per deployment via `<SVC>_VPN` in `.env` / the `vpn` command); on a **static** service the fragment itself must set `network_mode: "service:gluetun"` with no own `ports:`. `leak-test` audits the live result either way |
| `mediastack.torrent: "true"` | a torrent client: out of the VPN its traffic leaks on the host IP, so `vpn_gen` warns and `vpn <svc> off` refuses without `--i-know` |
| `mediastack.vpntoggle: "true"` | opt into operator-selectable VPN membership: `vpn_gen` generates this service's network, host port and Traefik route from its metadata, so the fragment carries none of those directly. See docs/vpn-membership.md |
| `mediastack.hostport: "false"` | (toggle services only) Traefik-only — publish no host port in either VPN state, for serving apps whose container port would collide on the host (e.g. `:80`). Default `"true"` |
| `mediastack.config: "true"` | owns `${CONFIG_ROOT}/<service>` (provisioned, audited, backed up) |
| `mediastack.cache: "true"` | owns `${CACHE_ROOT}/<service>` (provisioned, never backed up) |
| `mediastack.transcode: "true"` | owns `${TRANSCODE_ROOT}/<service>` (provisioned, never backed up) — for apps that write video segments while streaming; the root is local disk or a tmpfs by design |
| `mediastack.internal: "true"` | reachable on the LAN only — status marks it instead of printing a URL |
| `mediastack.user_facing: "true"` | household-facing: an update to this service notifies the `users` Apprise stream (not just `ops`). Per-deployment override via `set-user-facing` (writes `<SVC>_USER_FACING` in `.env`) |
| `mediastack.subdomain: "x"` | default hostname for the status URL column (`<X>_HOST` in `.env` overrides) |
| `mediastack.port: "1234"` | the port the app listens on INSIDE its container — `vpn_gen`'s published port, the Traefik backend port, and what other containers dial. The host-side port is derived from the rendered `ports:` (`svc_port`), so a `${MYAPP_PORT:-1234}:1234` mapping keeps the status table, `wire`'s API calls and the readiness gates on the overridden port |
| `mediastack.desc: "…"` | one-line description shown in the `configure` service picker |
| `traefik.http.routers.*` labels | HTTPS hostname — native Traefik labels, see docs/edge.md |

Labels the arr family carries (only meaningful with `wire arr` / `trash-sync`):

| Label | Meaning |
|---|---|
| `mediastack.arrtype: "sonarr\|radarr\|lidarr"` | which arr this instance is — every per-type fact (API version, download-client category field, Prowlarr and cleanuparr registration, Jellyfin library type) comes from its row in `ARR_META` (lib/integrations.sh); a new type is one row there, and CI fails if a fragment names a type without one |
| `mediastack.jflibrary: "Movies (4K)"` | the Jellyfin library name `wire jellyfin` offers for this instance's folder (default: its type's name, e.g. "Movies") |
| `mediastack.trashprofile: "uhd"` | the TRaSH profile this instance exists for (`uhd`, `anime`, …) — `trash-sync` pre-answers it instead of asking. Any `sonarr`/`radarr`-type instance is managed by `trash-sync`; this only skips the question |
| `mediastack.category: "movies-4k"` | its qBittorrent category (`wire qbit` creates it; `wire arr` sets it on the download client) |
| `mediastack.rootfolder: "/data/media/${MEDIA_DIR_MOVIES_4K:-movies-4k}"` | its root folder inside the container (`wire arr` registers it; seerr and jellyfin libraries derive from it; `configure` creates the directory). The subdir name comes from `.env` so an existing tree's names can be adopted |
| `mediastack.datadirs: "torrent/movies-4k media/${MEDIA_DIR_MOVIES_4K:-movies-4k}"` | extra `${DATA_ROOT}` subtrees `configure` provisions for this instance |
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
rm custom/compose.d/myapp.yml          # its definition
sed -i '/^MYAPP_/d' .env               # its UID/UPDATE/PORT/VPN/HOST variables
sudo rm -rf config/myapp               # its settings, if you're sure
./mediastack.sh up                     # regenerates local/vpn-overlay.yml without it
```

`up` must be the step that follows the deletion: the generated overlay still
carries the service's network/port stanza until then, and `status`/`doctor`
cannot render with it (they say so and point here).

## Changing a shipped service

Put the keys you want to change in `custom/override.yml` — compose merges
them over the shipped fragment's (and over your own services' files: it is
applied after them). See docs/vpn-membership.md for a worked example.

## For contributors: shipped fragments

One service per file: service `x` lives in `compose.d/x.yml` — no bucket
files, no judgment calls. Every fragment carries its own `x-logging` and
`x-armour` anchors (YAML anchors do not cross `include:` boundaries).
`x-armour` disables a FOREIGN watchtower on the same host, which would
otherwise auto-update our containers behind the backup/rollback system's
back; our own update pipeline does not use those labels.

### Wiring it to other apps (`wire`)

If a `wire` role writes this service's address into another app's settings:

* **Build the address with `svc_addr <svc>`** (or `svc_host` + `svc_cport`),
  never a literal: it follows the service's VPN side (`gluetun:<port>` inside,
  `<svc>:<port>` outside). CI (`scripts/test-addr.sh`) rejects a hard-coded
  loopback or gluetun address.
* **List who calls it in `WIRE_CALLERS`** (`lib/integrations.sh`), so a VPN
  toggle re-points those roles. CI (`scripts/test-repoint.sh`) fails if `wire`
  writes an address for a service the table doesn't list.
* **A read that decides whether to create something must fail loud.** A refused
  API read must never look like "nothing configured" — that creates duplicates.
  CI rejects a swallowed read (`|| true`) that doesn't carry a
  `# soft read: <why>` reason.

### Identity: PUID/PGID or `user:` — verify, never assume

Every service runs as its own UID (`<SVC>_UID`) in the `mediacenter` group.
How that is applied depends on the image, and getting it wrong is silent:
an image that ignores `PUID`/`PGID` just runs as root, writes root-owned
files, and later locks itself out when anything corrects the ownership.

* **The image switches user itself** (linuxserver.io, hotio, most *arr
  images): set `PUID=${X_UID}` and `PGID=${MEDIA_GROUP_GID}`.
* **The image runs as whoever starts it** (most official images — jellyfin,
  seerr, navidrome, kavita, audiobookshelf): set
  `user: "${X_UID}:${MEDIA_GROUP_GID}"` and no PUID/PGID. Before shipping,
  confirm from the image's Dockerfile/entrypoint and source that every
  runtime write lands on a bind mount (the image's own tree is root-owned),
  and that it does not bind a port below 1024 (move it with the app's own
  port setting rather than relying on the host's
  `ip_unprivileged_port_start`).

A `PUID` the image never reads is the failure mode this guards against:
audiobookshelf dropped its UID variables in 2.4.0 and kavita commented its
entrypoint user-switch out, and both ran as root here since they shipped, behind
fragments that set `PUID`. `doctor`'s runtime audit now FAILs any service
whose processes don't run as its `<SVC>_UID` — check it on first start.
