# Adding a service

Your services live in `custom/compose.d/`, one file each — untracked, passed
to compose on every stack operation, and upgrade-safe. Never add services to
`services/` or edit `docker-compose.yml`: those are the repo's territory,
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
* a container that is not a VPN toggle (a database, a cache — anything
  `vpn_gen` does not network for you) should declare `dns_search: ["."]`.
  Without it the container inherits the host's search domain, and a sibling
  name looked up while that sibling restarts can resolve to a public address
  through a wildcard record. Toggle services get it from `vpn_gen`.

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
| `mediastack.transcode: "true"` | owns `${TRANSCODE_ROOT}/<service>` (provisioned, never backed up) — for apps that write video segments while streaming; the root is local disk by design (tmpfs: docs/roadmap.md, look at later) |
| `mediastack.internal: "true"` | reachable on the LAN only — status marks it instead of printing a URL |
| `mediastack.user_facing: "true"` | household-facing: an update to this service notifies the `users` Apprise stream (not just `ops`). Per-deployment override via `set-user-facing` (writes `<SVC>_USER_FACING` in `.env`) |
| `mediastack.subdomain: "x"` | default hostname for the status URL column (`<X>_HOST` in `.env` overrides) |
| `mediastack.port: "1234"` | the port the app listens on INSIDE its container — `vpn_gen`'s published port, the Traefik backend port, and what other containers dial. The host-side port is derived from the rendered `ports:` (`svc_port`), so a `${MYAPP_PORT:-1234}:1234` mapping keeps the status table, `wire`'s API calls and the readiness gates on the overridden port |
| `mediastack.desc: "…"` | one-line description shown in the `configure` service picker |
| `mediastack.conflicts: "other"` | does the same job as `other` and never runs beside it (either side may declare it): `configure` asks which to keep, `enable` refuses the second |
| `mediastack.installer: "verb"` | set up by its own command, not `enable`/`configure`: `everything` and `custom` leave it out with a pointer to the verb, `enable` refuses — the verb enables it once its setup is in place |
| `mediastack.errors: '<regex>'` | what counts as an error line for `doctor`'s log-noise check (extended regex, case-insensitive) — on a service or a shard member (doctor counts every container of a shard). Default: any line containing the word `error` or `fatal`. Set it for an app whose logs carry a level, so a logger name or field key holding the word is not counted — authentik's is `"level": ?"(error\|critical\|fatal\|panic)"` |
| `mediastack.errors.except: '<regex>'` | lines the errors pattern matches that are routine for this app (extended regex, case-insensitive) — for one that logs normal events at an error level. Kavita logs its startup migrations at `[Fatal]` with "This is not an error" |
| `traefik.http.routers.*` labels | HTTPS hostname — native Traefik labels, see docs/edge.md |

Labels the arr family carries (only meaningful with `wire arr` / `trash-sync`):

| Label | Meaning |
|---|---|
| `mediastack.arrtype: "sonarr\|radarr\|lidarr"` | which arr this instance is — every per-type fact (API version, download-client category field, Prowlarr and cleanuparr registration, Jellyfin library type) comes from its row in `ARR_META` (services/_arr/arr.sh); a new type is one row there, and CI fails if a fragment names a type without one |
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

One service per folder: service `x` lives in `services/x/compose.yml` — no bucket
files, no judgment calls. Every fragment carries its own `x-logging` and
`x-armour` anchors (YAML anchors do not cross `include:` boundaries).
`x-armour` disables a FOREIGN watchtower on the same host, which would
otherwise auto-update our containers behind the backup/rollback system's
back; our own update pipeline does not use those labels.

Every service with its own network namespace declares `dns_search: ["."]`
(no host search domain — see the rule above); one sharing gluetun's
(`network_mode: service:gluetun`) must not, Docker refuses it, and gets
gluetun's instead. test-render fails a fragment that breaks either.

What the stack generates is pinned too: `scripts/test-snapshot.sh` runs the
`up` order for one fixture per branch (`scripts/fixtures/snapshot/`: the
plain install, the portal, Wizarr, an open edge, NPM, VPN membership moved,
your own files) and byte-compares the VPN overlay, Traefik's config, the
portal's email templates, the panel's files and the compose render (cut to
the fields mediastack writes). A new service changes those on purpose: read
the diff, then `scripts/test-snapshot.sh --bless` and commit `expected/` with
the code. A change you did not mean is what it is there to catch.

### Its code

A service's code lives in its folder beside its fragment:
`services/x/x.sh` holds the app's API client and its `wire` role
(`wire_x`), sourced by the entrypoint. A new role is also appended to
`WIRE_ROLES` in `lib/wire.sh` — that list sets the order `wire` runs in, and
CI fails a role without exactly one `wire_<role>` under `services/`. The arr
family shares one implementation in `services/_arr/arr.sh`; an arr instance
is a fragment only. A service with nothing to wire (Navidrome, say) has no
`.sh` at all; one with more to say can hold several, named by topic
(authentik: `authentik.sh` and `email.sh`).

A verb that covers several services keeps its own short list of them, in the
order it runs or prints them; a service's part lives in its folder. So far:
`wire` (`WIRE_ROLES` in `lib/wire.sh` -> `wire_<role>`), `set-credentials`
(the target list in `lib/access.sh` -> `sc_rotate_<target>`) and doctor's app
checks (`DOCTOR_APPS` in `lib/doctor.sh` -> `<name>_doctor`). A verb that
needs one service's code at one spot calls it by name — `<name>_<what>`
(`jellyfin_sessions_active` in the update, `link_<app>_*` in link-account,
`<name>_configure_secret` in configure).
`scripts/check-registries.sh` fails a listed name without exactly one
function under `services/`, and a `<service>_*` call that nothing defines.

Two rules keep one service's trouble from ending a whole run, both enforced
by `scripts/test-wire.sh`:

* **A wire step and a credential rotation first check their service is
  enabled** (`svc_enabled x || { info "x not enabled — skipped"; return 0; }`).
  Without it, a stack that never chose the service waits out its API and dies
  (`wire_qbit` on a Deluge-only stack did, until Oct 2026).
* **A failure is reported with `wfail` and the function returns 0** — the step
  itself and any helper it calls unguarded. Under `set -e` a `return 1` ends
  the entire `wire`, not just this app.

A service that cannot work without another declares it with `depends_on`
(`condition: service_started` when it only needs the other one present):
`configure` and `enable` read that and bring the other along — Seerr and
Wizarr bring Jellyfin. `scripts/test-matrix.sh` renders every service on its
own with what it pulls in, so a missing declaration shows as a render
failure rather than on someone's install.

### Providing a role (wiring by role)

Some connections are a *role* one service plays for others: a download client
for the arrs, Prowlarr and Cleanuparr. The consumers' code is written once
against the role (`lib/roles.sh`); a provider ships, per consumer type, how
that consumer reaches it — `services/x/provides/<role>.<consumer>.json`:

* **Data and placeholders only.** `{self.host}`, `{self.port}` (a number when
  it is the whole value), `{self.addr}` and `{env.NAME}` (a `.env` setting) —
  nothing else resolves, and anything that needs a decision is code.
* **One file per consumer type** of the role (`download-client.arr.json`,
  `.prowlarr.json`, `.cleanuparr.json`); `"priority"` orders the providers.
* **The stack uses one provider per role:** the role's setting
  (`DOWNLOAD_CLIENT`), else the first enabled; the others' entries are
  switched off, never deleted. A new provider joins that setting's `enum:` in
  `lib/env.schema.tsv`.
* `scripts/test-roles.sh` fails an unknown role, consumer or placeholder, and
  a provider missing a consumer's file. qBittorrent's are the worked example.
* **A role only where providers are interchangeable.** A relationship becomes
  a role when a second provider of it actually exists (download clients:
  qBittorrent, Deluge, Transmission — a usenet client would be one more). One
  provider wrapped in a role is indirection with nothing to gain: the arrs as
  servers (already one family), Jellyfin as the media server and Apprise as
  the hub stay plain code until a second one arrives.

### Its settings

A service's own `.env` settings are described beside it, in
`services/x/env.tsv` (the columns of `lib/env.schema.tsv`, which keeps the
shared ones); `lib/env.sh` reads them all as one schema. The settings
themselves still go in `.env.example` — the one file people read to
understand theirs — and `scripts/test-env.sh` holds the two together.

**A default is written once: in the schema's `default` column.** `env_get
KEY` returns it when the value is empty or absent, and takes no default of
its own (it refuses one). Every `${KEY}` in your fragment says the same
default — `${KEY:-x}`, never bare — and `.env.example` shows it or nothing;
CI holds all three together. `-` means none: empty is a value of its own
(not set up yet, never, any, generated on first use), and a derived value
(one setting standing in for another) is plain code, not a default. A
family key (`<svc>_PORT`, `<svc>_HOST`) differs per service, so its default
lives in the fragment — a `_HOST` fallback must equal the service's
`mediastack.subdomain`. A service's `<svc>_UID` is allocated, not defaulted:
it ships with its own line in `.env.example` (the next free number) and the
fragment reads a bare `${X_UID}` — `scripts/test-env.sh` fails a UID missing
from `.env.example` or carrying a compose fallback.

### Wiring it to other apps (`wire`)

If a `wire` role writes this service's address into another app's settings:

* **Build the address with `svc_addr <svc>`** (or `svc_host` + `svc_cport`),
  never a literal: it follows the service's VPN side (`gluetun:<port>` inside,
  `<svc>:<port>` outside). CI (`scripts/test-addr.sh`) rejects a hard-coded
  loopback or gluetun address.
* **List who calls it in `WIRE_CALLERS`** (`lib/addr.sh`), so a VPN
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
