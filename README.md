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
interactive menu. Passwords the stack created: `credentials`.

Still manual until the next wave: Jellyfin's first-run wizard (add
`/media/tv` and `/media/movies`) and connecting Seerr to Jellyfin and the
arrs.

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
| seerr | request/discovery site for your users |
| bazarr | subtitle automation |
| pihole / cloudflared | ad-blocking DNS / expose without port-forwarding |
| flaresolverr | captcha bypass helper for some indexers |
| deluge / transmission | extra torrent clients (most people need neither) |
| ersatztv | virtual live-TV channels from your library |

Recyclarr rides along as a tool container (not a service) powering
`trash-sync`. The recommended "standard" pick: gluetun, qbittorrent, the
base arrs, prowlarr, jellyfin, search, traefik, seerr.

## Command reference

Setup
| command | what it does |
|---|---|
| `install` | host dependencies (Docker, jq, ...) on Debian/Ubuntu |
| `configure` | interactive wizard; safe to re-run, answers become defaults |
| `add-mount` | guided NFS/SMB mount for media (fstab automount + poison layer) |

Run
| command | what it does |
|---|---|
| `up` / `down` | start / stop the stack |
| `enable <svc>` / `disable <svc>` | turn one service on/off (dependencies handled) |
| `status [svc]` | overview table (ports, VPN, health, versions) or one-service deep view |
| `logs <svc>` | follow one service's logs |

Maintain
| command | what it does |
|---|---|
| `update [svc] [--to TAG] [--dry-run] [--now]` | backup → pull → apply → health gate; nightly via timer |
| `apply-timer` | install/refresh the scheduled-update systemd timer |
| `backup` / `backup verify [ts]` | restore point now / verify checksums + archives |
| `restore --service <svc>\|--all [--from TS]` | restore configs + exact image |
| `rollback <svc>` / `unpin <svc>` | restore from newest point and pin / release the pin |
| `upgrade` | pull the latest mediastack + migrate `.env` |

Connect
| command | what it does |
|---|---|
| `wire [qbit\|arr\|prowlarr\|bazarr\|apprise\|jellyfin\|seerr\|wizarr] [--dry-run]` | connect the apps to each other; idempotent — GUI-configured apps are never overwritten |
| `invite [--expires 1\|7\|30]` | mint a Wizarr invitation, print the ready-to-share URL (default: never expires) |
| `set-credentials <arr\|qbit\|jellyfin>` | rotate a stored login everywhere it lives — apps, dependents, and `.env` — atomically |
| `trash-sync` | TRaSH Guides quality profiles via Recyclarr; rides the nightly update |
| `traefik-setup` | HTTPS wizard: domain, Cloudflare token, cert environment, dashboard login |
| `traefik-setup --hosts` | guided rename of every service's subdomain |
| `traefik-setup --certs` | switch staging/production certificates (applied end to end) |
| `credentials` | every login the stack created or stores |

Check
| command | what it does |
|---|---|
| `doctor` | full health/permission/cert/backup audit — every failure states its fix |
| `leak-test [--killswitch]` | prove no VPN'd service can leak (`--killswitch` = destructive proof) |
| `fix-perms [svc]` | repair config ownership from the UID map |

Other
| command | what it does |
|---|---|
| `new-service <name>` | scaffold a new compose fragment |
| `uninstall [--nuke]` | tiered removal; `--nuke` = everything, one confirmation. Media and backups are never touched |
| `menu` | interactive menu wrapping all of the above |

This table mirrors `./mediastack.sh help` as of the current version; the
script's own help is always authoritative.

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
  and `leak-test` proves the chain. Membership is defined in the fragments, audited by the
  tooling — see [docs/vpn-membership.md](docs/vpn-membership.md) to change it.
* **One wildcard certificate, nothing exposed.** HTTPS via Let's Encrypt
  DNS-01: the hostnames point at your LAN, no ports are forwarded, and a
  staging mode exists so testing never hits production rate limits
  (`traefik-setup --certs` switches, safely, either way).
* **Machine-managed settings are marked.** Synced quality profiles carry a
  `[synced]` prefix and a banner custom format; hand edits to them are
  reverted nightly by design — durable tuning goes in
  `local/trash-overrides.yml` ([docs/trash-sync.md](docs/trash-sync.md)).
* **`git pull` is always safe.** Your state lives in `.env` and gitignored
  dirs; tracked files are never written at runtime. `upgrade` wraps pull +
  config migration.

## Notifications (Apprise)

The `apprise` profile gives the stack one notification hub with three
streams: **ops** (update pipeline results, backup failures, doctor
problems), **activity** (arr grabs, imports, health events), **users**
(invite activity). `wire apprise` asks for your endpoints once,
stores them under one key, and connects every arr to the hub. Endpoints
already stored are never touched.

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

Seerr's request/approval/availability events flow to the hub too. Jellyfin
events would need its Webhook plugin (GUI-installable) — deliberately out
of wire's scope.

Apprise lives inside the VPN namespace like the arrs, so notifications
egress through the tunnel. Known property: if the tunnel is hard down,
push notifications are down with it — the script still logs locally.

## Search (JellySearch)

The `search` profile makes Jellyfin search instant and typo-tolerant.
Routing is automatic: JellySearch carries a Traefik router on Jellyfin's
own hostname that captures `?searchTerm` requests at a higher priority
(Traefik >= 3.0 — the stack's edge). No configuration needed.

## Media apps (Jellyfin, Seerr)

`wire jellyfin` performs the minimum first-run only: metadata defaults,
one admin account (the operator/recovery login, stored in `.env` — view:
`credentials`), remote access on with UPnP off, and libraries derived from
the arrs' root folders — you name each library at creation. Everything
else is yours to manage in the GUI, and wire can't undo you: libraries
are matched by **path, never name**, so renames, merges, and settings
changes are respected — wire only ever creates what's missing, and the
wizard gate closes itself after the first run.

Seerr has no logins of its own: everyone signs in with their Jellyfin
account. `wire seerr` bootstraps an uninitialised Seerr (owner = the
Jellyfin admin, libraries enabled, every arr connected with its TRaSH
profile); an initialised Seerr is never touched.

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

## Roadmap

Shipped: one-fragment-per-service architecture · app wiring (`wire`) ·
TRaSH Guides sync with ownership model and nightly automation · HTTPS edge
with staging/production certificates and guided hostnames · tiered backup
retention · Jellyfin + Seerr automated setup · JellySearch routing ·
invite management (Wizarr) · notification hub (Apprise) · download
cleanup (cleanuparr) · credential rotation (`set-credentials`) · tunnel
interface binding · runtime audits in `doctor`.

Next: production go-live (certificates, NAS backups) and the anzac2
migration.

## Docs

* [docs/edge.md](docs/edge.md) — HTTPS, hostnames, certificates, proxying non-stack hosts
* [docs/trash-sync.md](docs/trash-sync.md) — quality profiles, overrides, ownership
* [docs/vpn-membership.md](docs/vpn-membership.md) — moving services in/out of the VPN
* [docs/adding-a-service.md](docs/adding-a-service.md) — extend the stack
* [docs/migration-existing.md](docs/migration-existing.md) — adopt an existing deployment
* [docs/disaster-recovery.md](docs/disaster-recovery.md) — full rebuild from a restore point

## License

MIT — see [LICENSE](LICENSE). Share it around.
