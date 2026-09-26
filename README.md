# Mediastack

A self-hosted media server stack — VPN-isolated downloading, the *arr suite,
Jellyfin, a request site, and HTTPS for everything — managed by one script
that installs, configures, wires, updates, backs up, and diagnoses the whole
thing.

Built to work for anyone: every setting has a sane default, every wizard
prompt explains itself, and every failure states its fix.

```
your users ──HTTPS──▶ traefik ──▶ jellyfin / seerr / dashboards
                                      │
                                      ▼ (watches)
media library  ◀── imports ──  sonarr / radarr / lidarr / bazarr
                                      │
                              qBittorrent + prowlarr
                                      │
internet  ◀──── VPN tunnel ────  gluetun  (kill-switch enforced)
```

One wildcard certificate covers every service; nothing is exposed to the
internet — the hostnames resolve to your LAN.

## Requirements

* 64-bit Debian 12+ or Ubuntu 22.04+ (the installer handles Docker and
  dependencies)
* 4 CPU cores, 8 GB RAM, 40 GB SSD for the OS and app configs
  * search profile with a large library: 12 GB+ (Meilisearch keeps its
    index in memory)
  * Jellyfin *transcoding* wants an iGPU or more cores; direct play is
    fine at the floor
* Media storage separate from configs — any size, NAS over NFS/SMB is fine
  (`add-mount` sets it up)
* A VPN subscription with WireGuard from a
  [gluetun-supported provider](https://github.com/qdm12/gluetun-wiki)
* Optional, for HTTPS hostnames: a domain with DNS on Cloudflare

## Install

```
git clone <this-repo> && cd mediastack
./mediastack.sh install      # host dependencies
./mediastack.sh configure    # guided setup — explains every question
./mediastack.sh up           # start (runs the HTTPS wizard if traefik is on)
./mediastack.sh wire         # connect the apps to each other
./mediastack.sh trash-sync   # quality profiles from the TRaSH Guides
./mediastack.sh doctor       # verify everything
./mediastack.sh leak-test    # prove the VPN cannot leak
```

`./mediastack.sh` with no arguments lists every command; `menu` gives you an
interactive menu. Passwords the stack created: `credentials`; every
service's address: `status`.

The only remaining hands-on step is Wizarr's one-time first run — `wire`
walks you through it with the exact values to paste.

## What runs (à la carte)

Pick any combination — the wizard walks you through it, and
`enable <service>` / `disable <service>` change it any time. Dependencies
are automatic (qBittorrent brings the VPN; JellySearch brings its search
engine), and disabling something another service needs is refused with an
explanation.

| service | what it is |
|---|---|
| gluetun | VPN gateway — all download traffic exits through this tunnel |
| qbittorrent | torrent client (runs inside the VPN) |
| sonarr / radarr / lidarr | TV / movie / music automation |
| radarr-4k / sonarr-anime | separate 4K movie and anime TV instances |
| prowlarr | indexer manager feeding the arrs |
| jellyfin | the media server your users watch |
| meilisearch + jellysearch | instant, typo-tolerant Jellyfin search |
| traefik | HTTPS edge: hostnames + certificates for every UI |
| npm | Nginx Proxy Manager — GUI reverse proxy, the alternative edge (shipped, not wired: add hosts in its UI) |
| seerr | request/discovery site for your users |
| bazarr | subtitle automation |
| wizarr | invitation links — "set up my account" becomes a URL (the simple account model; each app keeps its own accounts) |
| authentik | the portal (`portal.<domain>`): one login for every app, sign-up by invitation, groups as permissions (the full account model — authentik *or* Wizarr, never both). Its own PostgreSQL and worker run in the same shard; the admin login is in `credentials`. It is also the **gate**: a web interface marked `mediastack.auth: gate` (so far the panel and Apprise) asks the portal first, and only the `admins` group gets through — see "The gate" below |
| apprise | one notification hub for the whole stack (ops/users) |
| cleanuparr | strikes stalled downloads, cleans the queue |
| watchstate | syncs + backs up per-user watch state across media servers |
| navidrome | music server (Subsonic API) over lidarr's library |
| audiobookshelf | audiobook + podcast server with progress sync |
| kavita | reading server for ebooks, comics and manga |
| lazylibrarian | book acquisition (Readarr replacement) |
| pihole / cloudflared | ad-blocking DNS / expose without port-forwarding |
| flaresolverr | captcha bypass helper for some indexers |
| deluge / transmission | extra torrent clients (most people need neither) |
| ersatztv | virtual live-TV channels from your library |
| olivetin | the web front door — the stack's safe verbs as buttons ([docs/frontdoor.md](docs/frontdoor.md)) |

Recyclarr rides along as a tool container (not a service) powering
`trash-sync`. The recommended "standard" pick: gluetun, qbittorrent, the
base arrs, prowlarr, jellyfin, search, traefik, seerr.

## Command reference

Setup
| command | what it does |
|---|---|
| `install` | host dependencies (Docker, jq, ...) on Debian/Ubuntu |
| `configure` | interactive wizard; safe to re-run, answers become defaults. Changing a root's path offers to move its contents (stack stopped, copy verified before the old copy goes) or to leave them and have `doctor` remind you; `DATA_ROOT` is never moved by the script |
| `add-mount` | guided NFS/SMB mount for media (fstab automount + poison layer) |

Run
| command | what it does |
|---|---|
| `up` / `down` | start / stop the stack. `up` also finishes any pending one-time step — re-pointing the apps that call a service you moved in or out of the VPN, or a service's file-ownership handover — and retries it until it succeeds |
| `enable <svc>` / `disable <svc>` | turn one service on/off (dependencies handled) |
| `status [svc]` | overview table (ports, VPN, health, versions, URLs) or one-service deep view |
| `logs <svc> [--no-follow]` | follow one service's logs; `--no-follow` prints a bounded snapshot and returns (used by the web panel) |

Maintain
| command | what it does |
|---|---|
| `update [svc] [--to TAG] [--dry-run] [--now]` | container images: backup → pull → apply → health gate. A targeted `update <svc>` bounces only that service (scoped restore point; the rest stay up); a full update stops the whole stack. Warns the household first when a user-facing service is affected. Nightly via timer (`--auto`) |
| `apply-timer` | install/refresh the systemd timers: scheduled updates (`UPDATE_SCHEDULE`) and the media manifest (`MANIFEST_SCHEDULE`); an empty schedule removes its timer |
| `manifest [--accept]` | snapshot every file under `DATA_ROOT/media` into `BACKUP_ROOT/manifest/` (nightly via timer). Alerts the ops stream when a folder loses media files — arr renames and upgrades are not losses. Refuses to record a snapshot whose file count fell more than `MANIFEST_ALERT_PCT` (usually an unmounted share); `--accept` records an intended one. With deletion attribution on (`audit`), the report and the alert name who removed each folder |
| `manifest diff [A [B]]` / `manifest find <text>` | what was lost between two snapshots (default: the last two; timestamps may be shortened to a unique prefix) / when each path matching `<text>` was first and last seen, and whether it is still there |
| `backup` / `backup verify [ts]` | restore point now / verify checksums + archives |
| `restore --service <svc>\|--all [--from TS]` | restore configs + exact image |
| `rollback <svc>` / `unpin <svc>` | restore from the newest point covering it (prefers the scoped pre-update point) and pin / release the pin |
| `upgrade` | mediastack itself: git pull + `.env` migration, run by the freshly pulled code; then says whether `up` has anything to apply, naming the services it would change (Compose's own dry run of `up` — a comment edit never triggers it). Images stay put — that's `update` |

Connect
| command | what it does |
|---|---|
| `wire [qbit\|arr\|prowlarr\|bazarr\|apprise\|cleanuparr\|lazylibrarian\|jellyfin\|seerr\|wizarr\|authentik] [--dry-run\|--verify]` | connect the apps to each other (the arrs also get their recycle bin — see below); idempotent — GUI-configured apps are never overwritten, with one exception: an address mediastack itself wrote (how one app reaches another) is re-pointed when a VPN toggle moves its target — an address you set by hand is left alone. `--dry-run` previews; `--verify` previews and exits 1 on drift (for scripts and cron; bazarr/lazylibrarian/seerr write blind and are skipped as not verifiable) |
| `invite [--expires 1\|7\|30]` | mint an invitation and print the ready-to-share URL — with authentik: a single-use sign-up link to the portal (default: 7 days); with Wizarr: a Wizarr invitation (default: never expires) |
| `set-credentials <arr\|qbit\|jellyfin\|pihole\|traefik\|all>` | rotate a stored login everywhere it lives — apps, dependents, and `.env` — atomically; `all` sets one password across the stack (Wizarr's admin is its own account — rotate it in Wizarr's UI) |
| `notify [status\|test [stream]\|set <stream>\|clear <stream>\|send <stream> <title> <message> [--type T]]` | the notification streams (`ops`, `users`): what each is set to (URLs hidden) and whether it delivered, a test, replace or clear a stream's URLs, or send your own message — see "Notifications" |
| `set-user-facing [<svc> true\|false]` | show or change which services notify the household (the `users` stream) when they're updated; no args lists the current set. The fragment ships a default; an override lands in `.env` only when it differs |
| `trash-sync [--dry-run]` | TRaSH Guides quality profiles via Recyclarr; rides the nightly update. `--dry-run` previews the drift (`recyclarr --preview`) and changes nothing |
| `traefik-setup` | HTTPS wizard: domain, Cloudflare token, cert environment, dashboard login |
| `traefik-setup --hosts` | guided rename of every service's subdomain |
| `traefik-setup --certs` | switch staging/production certificates (applied end to end) |
| `credentials` | every login the stack created or stores |

Check
| command | what it does |
|---|---|
| `doctor` | full health/permission/cert/backup/host-port audit — every failure states its fix |
| `leak-test [--killswitch]` | prove no VPN'd service can leak (`--killswitch` = destructive proof) |
| `audit [status\|on\|off\|report]` | deletion attribution, opt-in: the kernel logs every delete and rename under `DATA_ROOT/media` with who made it — each service runs as its own UID, so the UID names the service; a person is named by their login, even through sudo (the manifest says *what* went missing, this says *who*). `on` installs auditd if the host has none (a host that already runs auditd keeps its own setup: one rules file and one timer are added, nothing else is touched), asks how long to keep the history (`AUDIT_KEEP_DAYS`, default 365) and proves the watch with a test delete; `off` removes it again (and auditd, if mediastack installed it; the history stays). `report [--since YYYY-MM-DD] [--path TEXT]` lists what was deleted or renamed, by whom (default: the last 7 days); a container's paths are shown as host paths. `status` (default) is doctor's check, including the live test delete. Sees this host only — deletes made on the NAS itself or from another machine are the manifest's to catch |
| `vpn [svc on/off]` | show or change which services run behind the VPN (torrent clients need `--i-know` to leave). A move changes how other apps reach the service, so the next `up` re-points everything wired to call it (`WIRE_CALLERS`); if that fails, the next `up` retries and `doctor` says it is pending |
| `fix-perms [svc]` | repair ownership of a service's config, cache and transcode folders from the UID map |

Other
| command | what it does |
|---|---|
| `new-service <name>` | interactive: define, enable and start your own service in `custom/compose.d/<name>.yml` (untracked, upgrade-safe) |
| `uninstall [--nuke]` | tiered removal; `--nuke` = everything, one confirmation. Media and backups are never touched. Everything placed outside this folder is removed through one registry (see "Where things live"); each `add-mount` mount is offered separately, default No (`--nuke` only lists them), and whatever should have gone but did not is named at the end |
| `menu` | interactive menu wrapping all of the above |
| `help` | the command list (also: no arguments) |

Web front door
| command | what it does |
|---|---|
| `frontdoor-install` | install/refresh the OliveTin web panel over the safe verbs; first interactive run sets the admin password (`--set-password` to change it) |
| `frontdoor-refresh` | regenerate the panel's dropdown + status-tile data (also on a 5-min timer and the panel's Refresh button) |

Internal (called by the panel, timers and units — not meant for hand use)
| command | what it does |
|---|---|
| `list [all\|managed\|enabled\|disabled\|vpntoggle\|wire\|pinned] [--json]` | enumerate services by set — the panel's dropdown source |
| `vpn-apply <svc> on\|off` | the one-shot the panel's Toggle VPN button runs (`vpn` is the interactive form) |
| `vpn-guard [--boot]` | re-attach VPN'd services after a host boot / docker restart (systemd unit) |
| `audit-extract` | hourly (timer): copy new deletion events from auditd's rotating log into `BACKUP_ROOT/audit/`, prune it to `AUDIT_KEEP_DAYS`, flag a gap if auditd rotated first |

Every verb rejects arguments it does not accept — a typo or an unsupported
flag fails with the verb's contract instead of silently running the default
form. The user-facing rows above mirror `./mediastack.sh help`; the script's
own help is always authoritative.

## Arr recycle bin

**On by default.** Files an arr (Radarr, Sonarr, Lidarr, every instance)
deletes — including the old copy it replaces on an upgrade — are *moved* to
`RECYCLE_ROOT/<arr>` (default `DATA_ROOT/recycle`) instead of deleted, and the
arrs remove them after `RECYCLE_DAYS` (default 7; 0 = never). `wire arr` sets
it up; a recycle bin you set in an arr's own UI is left alone.

**It costs disk.** The bin lives on the media drive and needs room for
`RECYCLE_DAYS` of deletes and upgrades — a 4K remux can be 50+ GB, and a
quality-profile change can replace a whole library at once. `doctor` and the
nightly manifest warn (and notify the ops stream) when the bin holds more than
10% of the media drive or the drive is under 10% free. mediastack never
deletes from the bin: free space early by deleting what you no longer need
from it yourself, or lower `RECYCLE_DAYS` and run `wire arr`.

**Where it may live:** inside `DATA_ROOT` (the arrs already see it), outside
`DATA_ROOT/media` (the library must not see recycled files), on the same drive
as the media (a recycle is a move; across drives it would be a full copy).
Anything else is refused with the reason. Turn it off: `RECYCLE_ENABLED=false`
in `.env`, then `./mediastack.sh wire arr` (it clears only what it set).

It covers arr deletes only — a delete by Jellyfin, a person or another tool is
gone at once (deletion attribution, `audit`, still says who made it).

## Web front door

An optional OliveTin web panel exposes the stack's safe verbs as buttons, so
routine operations don't need a shell — live per-service status tiles plus
Diagnostics / Services / Maintenance actions. It is thin by design: no Docker
access, and it can only run a fixed allowlist of verbs, each as one SSH call
through a forced-command wrapper. Enable it with `./mediastack.sh
frontdoor-install`. See [docs/frontdoor.md](docs/frontdoor.md) for usage and
[docs/frontdoor-safety.md](docs/frontdoor-safety.md) for the safety model.

## The rules the tooling enforces

* **Configs on local disk only** — SQLite corrupts on NFS/SMB; the wizard
  refuses network paths for CONFIG_ROOT. Media on a NAS is fine; backups on
  a NAS is encouraged.
* **DATA_ROOT should be one filesystem.** Imports work by hardlinking
  torrent → media: instant, zero duplicate space, seeding uninterrupted —
  and hardlinks cannot cross filesystems. If your media spans multiple
  drives, don't point apps at per-drive folders (that forces slow, space-
  doubling copies); union the drives into one filesystem first — mergerfs
  is the standard tool — and use the pool as DATA_ROOT. `configure` warns
  when it detects a split.
* **Every update is preceded by a restore point**, and restore points are
  kept on a daily/weekly/monthly schedule (7 daily, one per week for 4
  weeks, one per month for 6 months — `BACKUP_KEEP_*` in `.env`).
  Anything broken after an update: `rollback <service>`.
* **Downloads cannot leak.** VPN'd services run inside gluetun's network
  namespace, start only after the tunnel is verifiably up, qBittorrent's
  transfers are additionally bound to the tunnel interface itself (tun0),
  and `leak-test` proves the chain. Membership is operator-selectable with the
  `vpn` command and audited by the tooling — see
  [docs/vpn-membership.md](docs/vpn-membership.md).
* **Host ports are yours to move, and never collide.** Every service's
  host port is `<SVC>_PORT` in `.env` (default: its container port); the
  status table, `wire`, `doctor` and the readiness gates all follow the
  override. `up` and `enable` refuse to proceed when two enabled services
  would publish the same host port, naming both — you fix it in `.env`
  instead of docker failing halfway through a start.
* **One wildcard certificate, nothing exposed.** HTTPS via Let's Encrypt
  DNS-01: the hostnames point at your LAN, no ports are forwarded, and a
  staging mode exists so testing never hits production rate limits
  (`traefik-setup --certs` switches, safely, either way).
* **Machine-managed settings are marked.** Synced quality profiles carry a
  `[synced]` prefix and a banner custom format; hand edits to them are
  reverted nightly by design — durable tuning goes in
  `custom/trash-overrides.yml` ([docs/trash-sync.md](docs/trash-sync.md)).
* **`git pull` is always safe.** Your state lives in `.env` and gitignored
  dirs; tracked files are never written at runtime. `upgrade` wraps pull +
  config migration.

## Where things live

| Where | What | Who writes it |
|---|---|---|
| repo root | the code (`mediastack.sh`, `lib/`, `compose.d/`, `docs/`) | the project — `upgrade` replaces it |
| `.env` | every setting | you (and `configure`) |
| `custom/` | `override.yml` (changes to shipped services), `compose.d/` (your own services, one file each), `proxy.d/` (your own Traefik routes), `trash-overrides.yml` | you — never touched by the script's upgrades, saved in every restore point |
| `local/` | the VPN overlay, pinned images, `.env` backups (the first and the newest 9) | the script — delete it and it is rebuilt (pins and backups excepted) |
| `config/` `cache/` `transcodes/` `data/` `backups/` | the default roots | the apps — move them with `configure` |

A deployment is `.env` + `custom/` + the roots: that is what to keep, copy
or back up.

**`.env` is checked.** Every setting is described in `lib/env.schema.tsv`
(its type, whether it may be empty, who writes it, what it means — including
the advanced ones read with a default, like `<SERVICE>_PORT` or
`WIZARR_HOST`). Before any command runs, every value is checked against it: a
malformed one stops the command, naming the key and what is expected (a
secret's value is never shown). Write values plain — no quotes, no comment
after the value: compose would strip them but the script would not, so the
two would read different settings; a comment goes on its own line. `doctor`
lists keys nothing reads (a typo, a leftover); one that is yours on purpose
— say, for a script of your own — is marked with a line directly above it:

```
# mediastack: ignore
MY_OWN_VAR=value
```

Variables your `custom/` files use (`${MYAPP_API_KEY}`) count as used and need
no mark. The script's own pending work (a re-point after a VPN toggle, an
ownership handover) lives in `local/state/`, not in `.env`.

**Outside this folder**, mediastack places only what its features need, and
one registry (`lib/footprint.sh`) lists all of it — `doctor` shows what is on
this host under "on this host, outside this folder", and `uninstall` removes
through the same list:

| Feature | What | Uninstall |
|---|---|---|
| timers | `/etc/systemd/system/mediastack-*` (updates, manifest, VPN guard) | removed |
| web panel | its refresh units, `/etc/sudoers.d/mediastack-frontdoor`, `/usr/local/bin/olivetin-frontdoor`, the `olivetin` user | removed |
| deletion attribution | `/etc/audit/rules.d/99-mediastack.rules`, its units; auditd itself if mediastack installed it | removed (auditd: asked) |
| service users | one system user per service, the `mediacenter` group | asked (tier 2) |
| `add-mount` | an `/etc/fstab` entry (marked `# mediastack add-mount`), `/etc/mediastack-cifs-*` for SMB, the mountpoint | offered one at a time, default No |
| `install` | Docker's apt source and key, the packages it installed | kept — your host may use them |

CI fails a change that writes anywhere else outside the repo.

### Removing a mount

`uninstall` offers each mount `add-mount` made; to remove one yourself
(stop the stack first, or anything using the share):

```
sudo systemctl stop "$(systemd-escape -p --suffix=automount /mnt/media)"
sudo umount /mnt/media                        # "target is busy": something still uses it
sudo sed -i '\|^# mediastack add-mount /mnt/media$|,+1d' /etc/fstab
sudo systemctl daemon-reload
sudo rm -f /etc/mediastack-cifs-media         # SMB only: the stored credentials
sudo chattr -i /mnt/media && sudo rmdir /mnt/media
```

The share itself (and everything on it) is not touched. Entries added before
the marker existed — or by hand — are yours: mediastack never claims them. Installs from before schema 28 are moved into this layout once,
on `upgrade`; a `docker-compose.override.yml` that later reappears at the
root is refused with where it belongs.

## Adding your own services

`./mediastack.sh new-service <name>` asks for the image, container port,
hostname, VPN membership, folders and permissions, writes a complete
service into `custom/compose.d/<name>.yml` — untracked, upgrade-safe, yours
to extend (a file can hold the database an app needs too) — then enables
and starts it and prints its URL. Its HTTPS route and VPN membership are generated like a
shipped service's (`vpn <name> on|off` works immediately). Never add
services to `compose.d/` or edit `docker-compose.yml`: those are the repo's
territory and local changes there block `upgrade` by design.

## Notifications (Apprise)

The `apprise` profile gives the stack one notification hub with two
streams, routed by audience: **ops** (you — errors, the update
pipeline, backups, doctor, incoming requests) and **users** (the
household — new media, invites, and service notices like restarts and
updates). `wire apprise` asks for your endpoints once, stores them
under one key, and connects every arr to the hub; after that, manage them
with `notify`:

```
./mediastack.sh notify                   # each stream: its services (URLs hidden), last delivered, last failure
./mediastack.sh notify test [ops|users]  # a test to each stream, plus Seerr's own test through the hub
./mediastack.sh notify set users         # replace a stream's URLs (hidden input), then test it
./mediastack.sh notify clear ops         # remove a stream's URLs
./mediastack.sh notify send users "Maintenance tonight" "Jellyfin is down 8-9pm" [--type warning]
```

`set` and `clear` change only that stream's lines in the hub's
configuration — anything you added in Apprise's UI (your own tags) is
kept. A notification that fails is recorded: `notify` and `doctor` show
the last failure and why.

**Seerr's events** (requests, approvals, availability, failures, issues)
reach the hub tagged with the event's own name, and each stream's URLs
carry the events that stream receives, so the hub routes them: *media
available* goes to **users** ("X is ready to watch"), everything else to
**ops**. The wording is Seerr's. The table is `NOTIFY_EVENTS` in
`lib/notify.sh`; `wire apprise` keeps the tags on mediastack's lines
current. Seerr only announces media that was *requested* through it — a
title an arr adds on its own (an import list, a manual add) is not
announced.

When an update bounces a **user-facing** service, the **users** stream
gets a heads-up before the restore-point backup and a follow-up once it
is back (with a note that it may take a few minutes to fully warm up). A
full update or `update gluetun` bounces the whole stack ("Mediastack
maintenance"); a targeted `update <svc>` notifies only if that service
is user-facing, named for it. Which services count is the
`mediastack.user_facing` label (jellyfin, navidrome, audiobookshelf,
kavita and seerr by default) — change it per deployment with
`set-user-facing <svc> true|false`. Services that aren't user-facing
(the arrs, prowlarr, torrent clients, …) update quietly to `ops` only.

If someone is streaming, an update that bounces jellyfin also pauses
`NOTIFY_GRACE` seconds (default 30; `0` = no pause) first so viewers can
reach a stopping point — the pause is jellyfin-only, since it's the one
service with a live-session check. Automatic (`--auto`) updates instead
defer while a stream is active (`UPDATE_DEFER_IF_ACTIVE`, on by default;
`UPDATE_DEFER_MAX_MIN` caps the wait before proceeding).

Upgrading an existing install: `wire seerr` updates the message template
of the agent it made in any earlier version (tag `activity`, then `ops`)
to per-event routing; the events you turned on in Seerr and its poster
setting stay as they are, and a template you wrote yourself is never
touched. A hub line tagged `activity` (the stream before `ops`) receives
nothing any more — `wire apprise`, `notify` and `doctor` name it; remove
it in Apprise's UI.

Prowlarr also registers qBittorrent as its own download client, so a
manual search in Prowlarr's UI can send a grab straight to qbit — those
land under the dedicated `prowlarr` category, out of the arrs' way.

Getting an endpoint URL:

* **Discord** — channel -> gear (Edit Channel) -> Integrations ->
  Webhooks -> New Webhook -> Copy Webhook URL. Paste the
  `https://discord.com/api/webhooks/...` URL as-is.
* **ntfy** (zero signup) — pick any unique topic name; the URL is
  `ntfy://ntfy.sh/your-topic`. Subscribe to the topic in the ntfy app.
* **Anything else** — email, Telegram, Slack, 100+ services:
  [the Apprise wiki](https://github.com/caronc/apprise/wiki).

For invite notifications, add an agent in Wizarr's UI (Settings ->
Notifications): type *apprise*, URL
`apprise://gluetun:8000/mediastack?tags=users`.

Apprise's own UI lives at `https://notify.<your-domain>` (or
`http://<host>:8000` on the LAN) — that's where stored endpoints are
edited after the first wire.

wire installs Jellyfin's Webhook plugin for WatchState's webhook mode;
its destinations stay yours to configure in Jellyfin's Dashboard ->
Plugins -> Webhook (WatchState's UI hands you the exact URL to paste per
backend).

Apprise lives inside the VPN namespace like the arrs, so notifications
egress through the tunnel. Known property: if the tunnel is hard down,
push notifications are down with it — the script still logs locally.

## Jellyfin polish (GUI, once)

wire names the server (the container default is a random ID hash) and
builds libraries/keys, but three worthwhile settings stay yours in the
Dashboard: **Networking -> Published server URL** (set your
`https://jellyfin.<domain>` so apps and casting advertise the right
address), **Playback -> Transcoding** (enable hardware acceleration only
if you pass a GPU/QSV device into the container), and library metadata
language/country if you want something other than en-US.

## Search (JellySearch)

The `search` profile makes Jellyfin search instant and typo-tolerant.
Routing is automatic: JellySearch carries a Traefik router on Jellyfin's
own hostname that captures `?searchTerm` requests at a higher priority
(Traefik >= 3.0 — the stack's edge). No configuration needed.

## Media apps (Jellyfin, Seerr)

`wire jellyfin` performs the minimum first-run only: metadata defaults,
one admin account (the operator/recovery login, stored in `.env` — view:
`credentials`), remote access on with UPnP off, a server name you choose
(the container default is a random ID hash), the transcode path moved
to `TRANSCODE_ROOT` (Jellyfin's default is inside `/config`, which
`backup` archives; segments are written at source bitrate for the whole
session, so give `TRANSCODE_ROOT` a few GB per concurrent stream on local
disk — a NAS share stutters, a tmpfs flies), and
libraries derived from the arrs' root folders — you name each library at
creation. Everything
else is yours to manage in the GUI, and wire can't undo you: libraries
are matched by **path, never name**, so renames, merges, and settings
changes are respected — wire only ever creates what's missing, and the
wizard gate closes itself after the first run.

Seerr has no logins of its own: everyone signs in with their Jellyfin
account. `wire seerr` bootstraps an uninitialised Seerr (owner = the
Jellyfin admin, libraries enabled, every arr connected with its TRaSH
profile); an initialised Seerr is never touched.

## Books & audiobooks (Audiobookshelf, Kavita)

Two serving apps cover the reading/listening side, both wire-free —
create their accounts on first visit:

* **Audiobookshelf** (`https://audiobooks.<your-domain>`) — audiobooks
  and podcasts, progress sync, official mobile apps. Reads
  `${DATA_ROOT}/media/audiobooks` and `.../podcasts`.
* **Kavita** (`https://books.<your-domain>`) — ebooks, comics and manga
  in one modern reader with OPDS and Kobo/KOReader sync. Reads
  `.../media/books`, `.../comics`, `.../manga`.

### Acquisition (LazyLibrarian)

The `lazylibrarian` profile automates book acquisition — the Readarr
replacement. It monitors authors, grabs ebooks/audiobooks, and hands them
to qBittorrent. `wire lazylibrarian` sets its download client and book
folders (`/data/media/books`, `/data/media/audiobooks`) and registers it
in Prowlarr as a first-class app, so indexers sync automatically like the
arrs. One manual step on first run: LazyLibrarian mints its API key only
after you open its UI (`https://books-dl.<your-domain>`), set a login
under Config -> Interface, and restart it — then re-run
`wire lazylibrarian`. It lives in the VPN namespace, so grabs ride the
tunnel.

## Music (Navidrome)

The `navidrome` profile serves the music lidarr manages through the
Subsonic API — any Subsonic client (phone, desktop, car stereo) plays
your collection, a real music experience where Jellyfin's is an
afterthought. It reads `${DATA_ROOT}/media/music` **read-only**: it
serves, lidarr owns the files. No wiring — create your account on first
visit at `https://music.<your-domain>`.

## Watch state (WatchState)

The `watchstate` profile runs [WatchState](https://github.com/arabcoders/watchstate):
per-user play state, matched by metadata GUIDs rather than server-internal
IDs, so it survives server rebuilds and library path changes. Use it to
sync state between media servers (this stack's Jellyfin and any other
Jellyfin/Plex/Emby you point it at) and to take portable play-state
backups — its `/config` rides the stack's restore points.

Backends are configured once in its UI (`https://watch.<your-domain>`):
add each server with an API key, choose Import/Export per backend, and
enable the scheduled tasks. Run exactly ONE instance per household —
state lives here, and two instances means two divergent truths.

## The portal and the gate (authentik)

With authentik enabled, `portal.<domain>` is where your users join (by
invitation: `./mediastack.sh invite`) and log in; its dashboard shows each person
the apps they may use. Two groups decide access: `media-users` (everyone who
joins) and `admins` (you — `wire authentik` puts the first admin there; add
others in authentik's Directory → Groups).

The **gate**: every web interface declares who logs it in —
`mediastack.auth: gate` (behind the portal), `native` (its own login) or `open`.
A gated interface's domain address asks the portal first: not logged in → the
portal's login, then straight back; logged in but not in `admins` → refused.
Gated: the panel, Apprise, every admin tool (the arrs, Prowlarr, Bazarr, the
download clients, LazyLibrarian, Cleanuparr, WatchState, Pi-hole) and Traefik's
dashboard. While the portal runs, their host ports listen on 127.0.0.1 only —
the domain address is the way in — and the arrs trust the portal (one login;
`wire arr` switches them, never before their ports are closed). Companion apps
(nzb360, LunaSea, Home Assistant…) use the domain address: the arrs' and
Bazarr's `/api` skips the gate and still demands their API key. The others
still ask for their own login behind the portal for now. Disabling authentik
gives every arr its own login back — verified — before the ports reopen. After
enabling authentik, run `./mediastack.sh wire authentik` once: it attaches the
gate and adds the admin cards to your dashboard (doctor fails until it has).

## Invites (Wizarr)

Wizarr turns "set up my account" into a link. Its first run is a one-time
UI step: create the admin account, add Jellyfin as a server (URL
`http://jellyfin:8096`, using the stack's Jellyfin API key — shown by
`credentials`), and mint a Wizarr API key. `wire wizarr` walks you through
it with the exact values to paste, and stores the key. After that:

```bash
./mediastack.sh invite               # never-expiring invitation URL
./mediastack.sh invite --expires 7   # or 1 | 30 days
```

## Status

Shipped: one-fragment-per-service architecture · app wiring (`wire`) ·
TRaSH Guides sync with ownership model and nightly automation · HTTPS edge
with staging/production certificates and guided hostnames · tiered backup
retention · Jellyfin + Seerr automated setup · JellySearch routing ·
invite management (Wizarr) · notification hub (Apprise) · download
cleanup (cleanuparr) · credential rotation, including one-password mode
(`set-credentials all`) · tunnel interface binding · runtime audits in
`doctor` · drift checks (`wire --verify`, `trash-sync --dry-run`) ·
manual grabs from Prowlarr · user services as drop-in files
(`custom/compose.d/`) · service URLs in `status` · watch-state
sync and backup (WatchState) · a dedicated music server (Navidrome) ·
audiobook/podcast and ebook/comic serving (Audiobookshelf, Kavita) ·
a web control panel over the safe verbs (OliveTin front door).

The stack is feature-complete for its scope; changes from here are
maintenance, fixes, and polish. Project goals and forward direction live
in [docs/roadmap.md](docs/roadmap.md); what was evaluated and set aside, and
what would reopen it, in [docs/watchlist.md](docs/watchlist.md).

## Docs

* [docs/edge.md](docs/edge.md) — HTTPS, hostnames, certificates, proxying non-stack hosts
* [docs/trash-sync.md](docs/trash-sync.md) — quality profiles, overrides, ownership
* [docs/vpn-membership.md](docs/vpn-membership.md) — moving services in/out of the VPN
* [docs/adding-a-service.md](docs/adding-a-service.md) — extend the stack
* [docs/migration-existing.md](docs/migration-existing.md) — adopt an existing deployment
* [docs/disaster-recovery.md](docs/disaster-recovery.md) — full rebuild from a restore point
* [docs/roadmap.md](docs/roadmap.md) — project goals, architecture rules, and open work
* [docs/watchlist.md](docs/watchlist.md) — rejected, parked and deferred items, each with what would reopen it
* [docs/frontdoor.md](docs/frontdoor.md) — the OliveTin web panel: what it is, enabling it, the buttons
* [docs/frontdoor-safety.md](docs/frontdoor-safety.md) — the front door's safety model and what is (and isn't) exposable

## License

MIT — see [LICENSE](LICENSE). Share it around.
