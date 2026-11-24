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
* A VPN subscription from one of the providers in
  `services/gluetun/providers/` — every provider gluetun knows, over WireGuard
  where it has it, OpenVPN otherwise (only NordVPN is tested live so far) — or
  your own WireGuard or OpenVPN config (`custom`)
* Optional, for HTTPS hostnames: a domain with DNS on Cloudflare

## Install

Six steps. Run every command from the `mediastack` folder as your normal
user — the script asks for your `sudo` password when it needs it and
keeps it for the rest of that run, so a long step does not stop to ask again.

### Before you start

`configure` asks for these, so have them ready:

* **A user that can use `sudo`.** A Debian install given a root password
  has no `sudo` at all: as root, `apt install sudo && usermod -aG sudo
  <your-user>`, then log out and back in.
* **Your VPN:** a NordVPN access token (nordvpn.com → Services → NordVPN →
  *Set up NordVPN manually*) — it gives the WireGuard key or the OpenVPN login;
  or your provider's WireGuard private key (and, for some, the address and
  pre-shared key of its config file), or its OpenVPN service login (and, for a
  few, the certificate and key files it gives) — configure asks only what yours
  needs, and says where its account page shows it; or your own WireGuard
  `.conf` or OpenVPN `.ovpn` file.
* **For HTTPS names and the authentik portal** (skip otherwise): a domain;
  a wildcard A record `*.<domain>` → this machine's LAN IP (on Cloudflare:
  proxy **off**, grey cloud); and either the domain's DNS on Cloudflare with
  an API token holding the single permission Zone / DNS / Edit, scoped to
  that zone (Let's Encrypt), or a certificate of your own from a public CA
  covering `<domain>` and `*.<domain>` ([docs/certificates.md](docs/certificates.md)).
* **For notifications** (optional): one URL per stream — `ops` (you) and
  `users` (your household). A Discord channel's webhook URL works as-is;
  any [Apprise URL](https://github.com/caronc/apprise/wiki) does.
* **For the portal's email** (optional, authentik only): an SMTP account —
  [docs/email.md](docs/email.md).

### 1. Get the code

```
sudo apt update && sudo apt install -y git
git clone https://github.com/Alethio36/mediastack.git
cd mediastack
```

This follows `stable`, the release channel for everyday use (see
**Release channels** below).

### 2. Install the host dependencies

```
./mediastack.sh install
```

Installs curl, git, jq, ca-certificates, argon2 and rsync, leak-test's tools
(conntrack and tcpdump — uninstall removes them again unless they were
already there), and Docker with its compose plugin from Docker's own
repository (skipped when Docker is already there). Debian 12+ or Ubuntu
22.04+. Safe to re-run: an existing install gets the tools that way. At the
end it offers to carry straight on into `configure` (Enter).

### 3. Set it up

```
./mediastack.sh configure
```

In order: your timezone; where configs, media, cache, transcodes and
backups live; which services run — **standard**, **everything** or
**custom**; how people sign in — **none**, **Wizarr** or **authentik**;
the download client, when you picked more than one; your VPN; with
Traefik, your domain and Cloudflare token (checked with Cloudflare as you
paste it) and the certificates; with authentik, the portal's name and
email; Jellyfin's server name; **the stack's own logins** — one username
for the download clients, the arrs, Jellyfin's admin, Audiobookshelf's and
Kavita's roots and the dashboard, their passwords **generated** (default),
**unified** (one for all) or typed for **each**; with Apprise, your
notification URLs (kept privately until wire hands them to the hub, then
changed with `notify`); each arr's TRaSH profile; when updates and backups
run; and, with Traefik, whether to install the web panel now (default yes).
**Quick** (the default) asks only what has no recommended answer; **full**
asks everything. Every question
explains itself, and Enter takes the default. Re-run it any time: your
answers become the new defaults.

**standard** has no proxy — services answer on `http://<host>:<port>`. The
authentik portal needs Traefik and a domain: pick **everything**, or
**custom** with `traefik`, if you want it.

### 4. Start it, connect it, check it — configure's last steps

After the summary of your answers, configure asks **"Start everything
now?"** — Enter runs, in order: the web panel's install (when you chose
it), `up`, `wire` and `trash-sync`, then `doctor` and `leak-test`, and
lists what is still yours to do. Expect ~15-20 minutes on a first run.
Over SSH, run it in tmux or screen: configure warns when you are not, and
if the connection drops, running `./mediastack.sh configure` again carries
on — every step is safe to repeat. A step that fails stops the rest, and
the message names every step still to run. Answering **No** (to drop in a
saved certificate first, say) leaves those steps to run by hand, in the
order it prints. On a stack that is already running, the question is
**"Apply the changes now?"** and defaults to No.

Each step on its own, for reference:

```
./mediastack.sh up
```

The first start downloads every image, which takes several minutes.
Traefik's answers (domain, email, Cloudflare token, real or test
certificates) come from configure; `up` asks nothing. Pick **staging**
while you are still trying things out: Let's
Encrypt allows only 5 identical real certificates a week, and switching to
production later is one setting (`traefik-setup --certs`). Known limitation:
apps that check the portal's certificate themselves refuse a staging one,
so Kavita's portal sign-in is skipped until production (wire says so) and
Audiobookshelf's is expected to fail; Jellyfin's LDAP sign-in skips the
check on staging.

### 5. Connect the apps (configure runs these)

```
./mediastack.sh wire
./mediastack.sh trash-sync
```

`wire` connects the apps to each other — download client and indexers to
the arrs, libraries to Jellyfin, the request site to the arrs, the portal's
sign-in to every app — with the logins configure recorded (it asks
nothing about them) — and hands the hub the notification URLs configure
recorded. The first wire on a deployment takes a restore point first. With Wizarr, it walks you through
Wizarr's one-time first run with the exact values to paste. Safe to re-run;
`wire --verify` shows what has drifted without changing anything.

`trash-sync` applies the [TRaSH Guides](https://trash-guides.info) quality
profile configure recorded for each arr (`--dry-run` previews;
[docs/trash-sync.md](docs/trash-sync.md)). An arr without one — enabled
after configure — is refused by name until configure asks it.

### 6. Check it (configure runs these too)

```
./mediastack.sh doctor
./mediastack.sh leak-test
```

`doctor` audits the whole deployment and gives a fix for every problem it
finds; `leak-test` proves downloads cannot leave outside the VPN.

### After install

* Every service's address: `./mediastack.sh status`. The logins the stack
  generated: `./mediastack.sh credentials`.
* With authentik, people sign in at `https://portal.<domain>`. The portal's
  own admin is `akadmin` (its password is in `credentials`) — keep it for
  when no one else can get in. Make your own account with
  `./mediastack.sh invite`, make it an admin with
  `./mediastack.sh access admin <you> on`, and add your household with
  `invite` too — see **The portal and the gate**.
* Three Jellyfin settings stay yours — see **Jellyfin polish**.
* Updates and backups run on the schedule you chose.
  `./mediastack.sh down` stops the stack and pauses them until
  `./mediastack.sh up`.

`./mediastack.sh` with no arguments lists every command; `menu` gives you an
interactive menu. Passwords the stack created: `credentials`; every
service's address: `status`.

How your household signs in is your choice, and one at most — `configure`
asks it on its own, whatever services you picked: **none** (you make each
person's accounts in each app), **Wizarr** (invitation links; each app keeps
its own login) or **authentik** (the portal — one login for every app; see
"The portal and the gate"). Re-run `configure` to switch; leaving the portal
warns you first (its accounts stay in its database, unusable, and every app
goes back to its own login — each one put back and checked while the ports
are still closed; if one cannot be, the portal stays and nothing reopens). With Wizarr, its one-time first run is the only
hands-on step — `wire` walks you through it with the exact values to paste.

**Release channels.** A clone follows `stable`, the default branch, and
`upgrade` pulls whatever branch is checked out. `unstable` gets every change
first (for testing it: `git checkout -b unstable origin/unstable`, then
`upgrade`); `legacy` is the old project, kept frozen.

**Knowing an upgrade exists.** The update run pulls images, never mediastack
itself, so the script moves only when you run `upgrade`. To say when to,
`doctor` shows how far your checkout is behind its branch, and the update run
tells ops once per new commit there, with the newest subjects — a `git fetch`
as the repo's owner, never a pull (`SCRIPT_UPDATES=notify`, the default;
`off` never asks). A remote that needs your SSH key's passphrase cannot be
fetched unattended: the check says so once, and a public `https://` remote
needs none. Upgrading on its own comes with versions from the repo
(docs/roadmap.md).

## What runs (à la carte)

Pick any combination — the wizard walks you through it, and
`enable <service>` / `disable <service>` change it any time. Dependencies
are automatic (qBittorrent brings the VPN; JellySearch brings its search
engine; Seerr and Wizarr bring Jellyfin), and disabling something another
service needs is refused with an explanation.

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
| authentik | the portal (`portal.<domain>`): one login for every app, sign-up by invitation, groups as permissions (the full account model — authentik *or* Wizarr, never both). Its own PostgreSQL and worker run in the same shard; the admin login is in `credentials`. It is also the **gate**: a web interface marked `mediastack.auth: gate` (every admin tool, the panel and Apprise) asks the portal first, and only the `admin` group (or someone given that app) gets through — see "The gate" below |
| apprise | one notification hub for the whole stack (ops/users) |
| cleanuparr | strikes stalled downloads, cleans the queue |
| watchstate | syncs + backs up per-user watch state across media servers |
| navidrome | music server (Subsonic API) over lidarr's library |
| audiobookshelf | audiobook + podcast server with progress sync |
| kavita | reading server for ebooks, comics and manga |
| lazylibrarian | book acquisition (Readarr replacement) |
| pihole / cloudflared | ad-blocking DNS / expose without port-forwarding |
| flaresolverr | captcha bypass helper for some indexers |
| deluge / transmission | other torrent clients (most people need neither). With more than one enabled, `DOWNLOAD_CLIENT` (asked by `configure`) names the one the arrs, Prowlarr and Cleanuparr use — the others' entries are switched off. `wire deluge` sets Deluge up: its own password, downloads on the data tree, the Label plugin, transfers bound to tun0; `wire transmission` gives Transmission a login (its container carries it) and downloads on the data tree — it binds by address, not interface, so gluetun's kill switch is what keeps it in the tunnel |
| ersatztv | virtual live-TV channels from your library |
| olivetin | the web front door — the stack's safe verbs as buttons ([docs/frontdoor.md](docs/frontdoor.md)) |

Recyclarr rides along as a tool container (not a service) powering
`trash-sync`. The recommended "standard" pick: gluetun, qbittorrent, the
base arrs, prowlarr, jellyfin, search, traefik, seerr.

## Command reference

Setup
| command | what it does |
|---|---|
| `install [--answers FILE] [--domain D] [--services a,b] [--signin X]` | host dependencies (Docker, jq, ...) on Debian/Ubuntu, then configure; with answers given it carries on into `configure` with them and asks nothing. Unattended (no terminal), sudo must not need a password: run `sudo -v` first, or run as root |
| `configure [--answers FILE] [--domain D] [--services a,b] [--signin X]` | interactive wizard, **quick** (the default: only what has no recommended answer — the services, how people sign in, your VPN details — the rest takes the recommended answer, and the summary at the end shows every answer) or **full** (every question): folders, services, how people sign in (none / Wizarr / authentik), VPN, update and backup schedules; safe to re-run, answers become defaults. All questions come first; nothing is applied until they are answered, so Ctrl-C leaves the stack as it was. Changing a root's path offers to move its contents (stack stopped, copy verified before the old copy goes) or to leave them and have `doctor` remind you; `DATA_ROOT` is never moved by the script. **`--answers FILE`**: the questions answered ahead, in `.env` syntax (yours alone: `chmod 600`; Unix line endings — a file saved with Windows ones is refused, with the command that converts it) — a written answer is used, a blank one keeps what is set or takes the recommendation; every problem in the file is listed before anything is asked or written, and with no terminal every answer that would be asked must be in it The flags are answers too, over the file's: `--domain` (`STACK_DOMAIN`), `--signin` (`SIGNIN`), `--services a,b` (exactly these run, with what they need); `START=yes|no` in the file answers the closing question. The blank file to start from is **`answers.example`**: every question, with its choices and recommendation — `cp answers.example answers.env && chmod 600 answers.env` (`answers*.env` is git-ignored) ([docs/design-answers.md](docs/design-answers.md)) |
| `add-mount` | guided NFS/SMB mount for media (fstab automount + poison layer) |

Run
| command | what it does |
|---|---|
| `up` / `down` | start / stop the stack. A stack stopped with `down` stays down: its scheduled jobs (updates, backups, the media manifest, the panel's refresh, the boot guard) skip until `up`, and doctor says so. `up` starts the VPN'd services last: everything else (gluetun with it) first, then a full `leak-test`, and only on a pass (or nothing failed but something UNPROVEN, with a warning) the VPN'd services — a FAIL leaves them stopped. `up` also finishes any pending one-time step — re-pointing the apps that call a service you moved in or out of the VPN, or a service's file-ownership handover — and retries it until it succeeds |
| `enable <svc>` / `disable <svc>` | turn one service on/off (dependencies handled). `enable` asks what the services it brings need, the way configure does (quick: a token, a domain, a login under the stack's mode — a unified password one of them refuses is stopped, named, with `set-credentials all` as the fix), then runs `up` (a VPN'd service starts through the leak gate), `wire`, and `trash-sync` for an arr; cancelled, nothing changes |
| `status [svc]` | overview table (ports, VPN, health, versions, URLs) or one-service deep view |
| `logs <svc> [--no-follow]` | follow one service's logs; `--no-follow` prints a bounded snapshot and returns (used by the web panel) |

Maintain
| command | what it does |
|---|---|
| `update [svc] [--to TAG] [--dry-run] [--now]` | container images: backup → pull → apply (the VPN'd services through the leak gate: when gluetun changed, its full leak-test first, and on a new gluetun image its kill-switch proven the same night; refused while the gate is closed) → health gate → `wire --verify` when a version changed (a new version that reset settings wire owns is reported to ops with the fix, never applied unattended). A targeted `update <svc>` bounces only that service (scoped restore point; the rest stay up); a full update stops the whole stack. Warns the household first when a user-facing service is affected. Nightly via timer (`--auto`) |
| `apply-timer` | install/refresh the systemd timers: scheduled updates (`UPDATE_SCHEDULE`), scheduled backups (`BACKUP_SCHEDULE`), the media manifest (`MANIFEST_SCHEDULE`) and the scheduled doctor (`DOCTOR_SCHEDULE`, daily 06:00); an empty schedule removes its timer. `configure` asks the update and backup schedules together; the other two are set in `.env` |
| `manifest [--accept]` | snapshot every file under `DATA_ROOT/media` into `BACKUP_ROOT/manifest/` (nightly via timer). Alerts the ops stream when a folder loses media files — arr renames and upgrades are not losses. Refuses to record a snapshot whose file count fell more than `MANIFEST_ALERT_PCT` (usually an unmounted share); `--accept` records an intended one. With deletion attribution on (`audit`), the report and the alert name who removed each folder |
| `manifest diff [A [B]]` / `manifest find <text>` | what was lost between two snapshots (default: the last two; timestamps may be shortened to a unique prefix) / when each path matching `<text>` was first and last seen, and whether it is still there |
| `backup [--note TEXT]` / `backup verify [ts]` / `backup list [svc]` | restore point now (a note says why; the backup timer runs `backup --auto`, which skips after an update's restore point under 6 hours old, waits for a running update, and waits while someone is watching in Jellyfin) / verify checksums + archives / every point, newest first, with its kind (manual, scheduled, update, update-scoped, migrate) and note — given a service, its version in each and which one is running |
| `restore --service <svc>\|--all [--from TS]` | restore configs + exact image |
| `rollback <svc> [--from TS] [--yes]` / `unpin <svc>` | return a service to the image it ran before — the newest restore point holding a different image; `--from` picks any point (`backup list <svc>` shows them, and which one rollback takes). Its config goes back with the image, so its data since then is replaced (the current folder is kept); it shows the plan and asks first. Pins it there / release the pin (the next `update` applies it). A shard (authentik's containers) goes back and is released as one. Going back: `rollback`; moving to a chosen version: `update <svc> --to <tag>` |
| `upgrade` | mediastack itself: git pull + `.env` migration, run by the freshly pulled code; then says whether `up` has anything to apply, naming the services it would change (Compose's own dry run of `up` — a comment edit never triggers it). Images stay put — that's `update`. `doctor` and the update run say when there is one to run ("Knowing an upgrade exists") |

Connect
| command | what it does |
|---|---|
| `wire [qbit\|deluge\|transmission\|arr\|lazylibrarian\|prowlarr\|bazarr\|apprise\|authentik\|cleanuparr\|jellyfin\|seerr\|wizarr\|audiobookshelf\|kavita\|navidrome] [--dry-run\|--verify]` | connect the apps to each other (the arrs also get their recycle bin — see below); idempotent — GUI-configured apps are never overwritten, with one exception: an address mediastack itself wrote (how one app reaches another) is re-pointed when a VPN toggle moves its target — an address you set by hand is left alone. `--dry-run` previews; `--verify` previews and exits 1 on drift (for scripts and cron; bazarr/lazylibrarian/seerr write blind and are skipped as not verifiable). An app that does not answer in time may still make the change: at the end, `wire` waits 20s and reads that app's settings back (its own `--verify`) — everything in place, and those failures are taken back; anything missing, and they stand, with what is missing shown |
| `invite [--expires 1\|7\|30] [--email ADDRESS]` | mint an invitation and print the ready-to-share URL — with authentik: a single-use sign-up link to the portal (default: 7 days), and with `--email` the portal emails it too (needs email that passed `email test`); with Wizarr: a Wizarr invitation (default: never expires) |
| `set-credentials <arr\|qbit\|deluge\|transmission\|jellyfin\|pihole\|traefik\|audiobookshelf\|kavita\|navidrome\|panel\|portal\|all>` | rotate a stored login everywhere it lives — apps, dependents, and `.env` — atomically; `audiobookshelf` rotates its root password and ends every root session; `kavita` its admin's; `navidrome` its admin's (through its API, the new one proven to sign in and the old one not); `panel` the web panel's admin (its hash rewritten, the panel restarted to read it); `portal` sets akadmin's password through authentik's API; `all` sets one password across the stack except `portal`, which guards the rest (Wizarr's admin is its own account — rotate it in Wizarr's UI) |
| `rotate-secrets` | give every secret the stack made for itself a new value — its API keys, the portal's tokens, signing key, database and client secrets, Meilisearch's and gluetun's keys — each proven (the new one taken, the old refused) or put back, after a restore point; whatever holds a copy is rewired and the run ends with `wire --verify`. With the portal it ends by signing everyone out of it and the tools behind it (apps with their own sign-in — Jellyfin, Navidrome — keep theirs). Interactive: it says first what it costs, and ends with a framed warning naming what outside the stack now holds a stale value and what it does not rotate — secrets from outside (VPN, Cloudflare, mail), Wizarr's API key (made in its UI), and the stack's own logins (`set-credentials`). [design](docs/design-rotate.md) |
| `link-account <portal-user>` | an existing household's people keep their history: after someone joins the portal, their local Jellyfin, Kavita and Audiobookshelf accounts become their portal account — you confirm which account is whose, see the plan, then it links (Audiobookshelf needs them to sign in once, within 10 minutes) |
| `reset-password <user>` | someone locked out — with the portal: clears their login throttle and prints a single-use sign-in link (24 hours) to send them — they then set a new password in the portal's Settings. Not for akadmin (`set-credentials portal`). With Wizarr: Wizarr's single-use reset link (24 hours) to send them privately — they choose their own password on it, so no one else ever sees it; a newer link voids the last; a disabled Jellyfin account is reported, not re-enabled. Wizarr has no email, so you pass the link on yourself |
| `access [list [user]]` / `access tier <app> frontend\|admin [--yes]` / `access grant\|revoke <user> <app>` / `access admin <user> on\|off` / `access portal <user> on\|off [--yes]` | who may open which app — those behind the portal's gate, Jellyfin, Kavita and Audiobookshelf (Seerr follows Jellyfin's rule): the list (each app's tier, who has it on its own), one person's (what they may open, and why), or move an app between the household (`frontend`: the household and its admins) and `admin` (admins only). Opening a tool to the household warns and asks; moving an app to `admin` ends the portal sessions of the household members who lose it. Kept in `.env` (`<APP>_TIER`, only where it differs from the app's default). `grant` gives one person one app whatever its tier (its card shows on their dashboard at once); `revoke` takes that back and ends their portal sessions — refused, and told how, when they have the app through their group instead. On Jellyfin, Kavita and Audiobookshelf, which sign people in themselves, losing it turns off their account there instead (Jellyfin: disabled and signed out of every device; Kavita: its `Login` role taken; Audiobookshelf: inactive), and getting it back turns it on again (only an account the stack turned off). `admin on` puts a person in the portal's `admin` group — every app behind the gate, and admin rights in Jellyfin, Kavita, Audiobookshelf and Navidrome at once; `admin off` takes them out and ends their portal sessions — and their management of the portal with it. `portal on` lets an admin manage the portal itself (authentik's admin screens, through its own superuser group): it warns what that gives — signing in as anyone, changing anyone's password and the gate's rules — and asks (`--yes` for scripts); `portal off` takes it back and ends their portal sessions. Neither touches akadmin, which stays an admin and a superuser. Someone who has never opened Kavita, Audiobookshelf or Navidrome gets their account there at their first visit, with admin rights within 15 minutes (people-sync; Jellyfin at once) |
| `signout <user>` | ends someone's Jellyfin sign-ins on every device — a browser goes to sign-in on its next click; an app may spin until it is closed and reopened, then asks. Their password is not changed, so it does not keep them out alone: with the portal, delete a device's password first; otherwise change their password. Works with any account model; never the stack's own Jellyfin admin (Seerr signs in as it). A device two people share is signed out for both, and the other is named |
| `set-email <user> <address> [--yes]` | change a person's portal email — people cannot change their own (Kavita, and later ROMM, sign people in by email, so it is who they are there). Kavita's account follows the change, so their next sign-in lands on the same account. An address another person already has is warned about and asks first; `--yes` decides for scripts. Use this rather than authentik's admin page, which changes the portal only |
| `users` | the portal's people: username, name, email, groups, and whether they can sign in (the stack's own `akadmin` and service accounts left out) |
| `email [status\|test <address>]` | the portal's outgoing email: `status` shows the settings and whether they passed a test; `test` sends a real message through authentik and, if the server refuses, says why it usually happens; a pass turns on the sign-in page's **Forgot password?** (a reset link by email). Set up with `configure` — [docs/email.md](docs/email.md) |
| `notify [status\|test [stream]\|set <stream>\|clear <stream>\|send <stream> <title> <message> [--type T]]` | the notification streams (`ops`, `users`): what each is set to (URLs hidden) and whether it delivered, a test, replace or clear a stream's URLs, or send your own message — see "Notifications" |
| `set-user-facing [<svc> true\|false]` | show or change which services notify the household (the `users` stream) when they're updated; no args lists the current set. The fragment ships a default; an override lands in `.env` only when it differs |
| `trash-sync [--dry-run]` | TRaSH Guides quality profiles via Recyclarr; rides the nightly update. `--dry-run` previews the drift (`recyclarr --preview`) and changes nothing |
| `traefik-setup` | ask Traefik's questions again (`configure` asks them first): domain, Cloudflare token — checked with Cloudflare when pasted, with the domain's zone — and the cert environment (the dashboard's login is one of the stack's own: `set-credentials traefik`) |
| `traefik-setup --hosts` | guided rename of every service's subdomain |
| `traefik-setup --certs` | where the certificate comes from — Let's Encrypt, your own files, or staging — applied end to end ([docs/certificates.md](docs/certificates.md)) |
| `credentials` | every login the stack created or stores, and the API keys companion apps ask for (the arrs, Prowlarr, Bazarr, Seerr) with the address to give them |

Check
| command | what it does |
|---|---|
| `doctor [--scheduled]` | full health/permission/cert/backup/host-port audit — every failure states its fix. It also runs on its own (`DOCTOR_SCHEDULE`, daily 06:00: `--scheduled`, which succeeds whatever it finds): ops hears its problems, listed, when they change — a new one, one gone, all clear — and once a week while they stand; a run by hand follows the same rule. Includes each arr's and Prowlarr's own health list (indexers, download client, root folders, the notification connection to the hub), read after each re-checks it: an error there is a doctor problem — on a fresh install, "no indexers" until you add some in Prowlarr. Room on every filesystem the stack writes to (each root, Docker's own data, this folder): a problem under 2 GiB free or 5% of its inodes, a warning under 10% free unless more than 50 GiB is left; the nightly manifest run tells ops too (a full one every night, a filling one once a week). Runs that never finished in the last 7 days (`local/runs/`) |
| `support [--note TEXT] [--logs SVC,...] [--custom] [--host-events]` | one text file to send to whoever helps you: the system (CPU, memory, disks, OS, Docker, clocks), the install and your settings that differ from the shipped ones (secrets as `<set>`), each container (state, health checks, restarts, image and when it was pulled), what is in progress, each service's own view (authentik's blueprints and outposts, Jellyfin's plugins and libraries, each arr's health, root folders and download client, qBittorrent's bound interface, Seerr's servers, the VPN's last verdict, Navidrome's people, the certificate Traefik serves), whether this host reaches what the stack needs (the plugin repository, the image registries, GitHub, the VPN and certificate APIs) and whether your names point at it, a fresh `doctor` and `wire --verify`, and recent runs. Only when asked: `--logs jellyfin,authentik` (their last 300 lines — they can hold people's names and titles), `--custom` (your files in `custom/` — secrets you wrote there are unknown to the redaction), `--host-events` (the kernel's out-of-memory kills, 7 days; Docker's errors, 24 hours). Secrets, your domain, public addresses, e-mails, your home path and names, and credential URLs are taken out, and a bundle that still holds a secret is deleted. It is written to `local/support/`, never sent: `support` prints what is in it, how to copy it off this host (`scp`), and ends asking you to proofread it. A GitHub issue is public — e-mail it if unsure |
| `leak-test [--killswitch\|--local]` | prove no VPN'd service can leak: exit 0 every check proven, 1 a leak or a missing safeguard, 2 nothing failed but something UNPROVEN. A FAIL stops the VPN'd services (gluetun stays up for inspection) and only `up` starts them again, after its own leak-test passes; ops hears each change of verdict once (`--killswitch` = destructive proof; `--local` = only what the host sees itself, no outside party asked) |
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
| `frontdoor-install` | install/refresh the OliveTin web panel over the safe verbs; its admin is one of the stack's own logins (the stack's username; the password generated, shared or typed per `STACK_LOGINS` — see `credentials`, change it with `set-credentials panel`), so it asks nothing and runs from an answers file |
| `frontdoor-refresh` | regenerate the panel's dropdown + status-tile data (also on a 5-min timer and the panel's Refresh button) |

Internal (called by the panel, timers and units — not meant for hand use)
| command | what it does |
|---|---|
| `list [all\|managed\|enabled\|disabled\|vpntoggle\|wire\|pinned] [--json]` | enumerate services by set — the panel's dropdown source |
| `vpn-apply <svc> on\|off` | the one-shot the panel's Toggle VPN button runs (`vpn` is the interactive form) |
| `vpn-guard [--boot]` | after a host boot / docker restart: start what a cut-off backup stopped, then the VPN'd services through the leak gate — Docker itself never starts them (systemd unit) |
| `vpn-watch [--full]` | every 5 minutes (`mediastack-leakcheck.timer`): `leak-test --local` — or the full run when gluetun restarted since its last full proof — and any enabled VPN'd service that is not running is started through the gate (a crash, a boot that came too early). To keep one stopped, `disable` it or `down` the stack: a `docker stop` is undone within 5 minutes. `--full`: the hourly run (`mediastack-leaktest.timer`, at a random minute), the full checks whatever gluetun's proof. Its news goes to ops once per change |
| `questionnaire [--fresh] [--answers FILE] \| --for SVC...` | `configure`'s questions (`--for`: those of the services `enable` brings), run as their own process ([docs/design-install.md](docs/design-install.md)): they record the answers in `.env` and `local/state` and do nothing else. Exit 0: all answered; 130: cancelled; 3: no terminal to ask on (and no answers file); 4: the answers file's problems, listed |
| `host-identity` | refresh the record of this host's own address (RIPEstat) that `leak-test` compares the tunnel against — once a day at a random time (`mediastack-hostid.timer`), never inside a leak-test, so no run asks about both of your addresses at once. `configure` makes the first record; by hand when leak-test reports it missing or stale |
| `unit-failed <unit>` | tell the `ops` stream that a scheduled or boot run failed — its result, exit status and last lines (systemd's OnFailure hook; once per unit per 6 hours) |
| `people-sync` | every 15 minutes (`mediastack-people.timer`, with the portal; each app is followed from its first `wire` that reaches the portal, which starts the timer): the apps' own accounts follow the portal — Navidrome's music apps stop for anyone it no longer lets open Navidrome (account deactivated or deleted, its tier, a grant taken away; see "Music (Navidrome)"), Jellyfin disables and signs out, Kavita takes `Login` from, and Audiobookshelf turns off, anyone it no longer lets open them (the same reasons), and each turns back on only those it turned off — ops hears each one; Jellyfin, Kavita and Audiobookshelf admin rights follow its `admin` group. Waits for authentik and each app first; also run at once by `access` on Navidrome, Jellyfin, Kavita and Audiobookshelf |
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
  a NAS is encouraged — `doctor` warns while BACKUP_ROOT shares a filesystem
  with the configs (the default does).
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
  Anything broken after an update: `rollback <service>`. A new version that
  merely reset its settings shows up as drift (`wire --verify` runs after
  every version change) and `wire` puts them back.
* **Downloads cannot leak.** VPN'd services run inside gluetun's network
  namespace, start only after the tunnel is verifiably up, qBittorrent's
  transfers are additionally bound to the tunnel interface itself (tun0),
  and `leak-test` proves the chain — who the internet sees over TCP and UDP,
  every resolver that answers, gluetun's DNS, firewall and control server,
  and the traffic the host itself sees leaving gluetun — without
  telling any one outside party both of your addresses. A check it cannot run
  is UNPROVEN, never a pass. A proven leak stops the VPN'd services until
  `up` proves gluetun again. Membership is operator-selectable with the
  `vpn` command and audited by the tooling — see
  [docs/vpn-membership.md](docs/vpn-membership.md); what leaves your box, and
  to whom: [docs/privacy.md](docs/privacy.md).
* **No telemetry by default.** Every app that reports usage, errors or its
  own installation to its makers has it switched off: the arrs and Prowlarr,
  Bazarr, Navidrome, Kavita, authentik and Meilisearch; the version checks of
  authentik, Traefik and gluetun too (the stack owns updates). Bazarr's and
  Kavita's live in their own settings, so `wire` turns them off once and a
  choice you make in their UI afterwards stays. What is left — version checks
  with no switch — is in [docs/privacy.md](docs/privacy.md).
* **Containers ignore the host's search domain.** A bare name inside the
  stack means a sibling container and nothing else — never
  `<name>.<your-domain>`, which a wildcard DNS record would answer with a
  public address. So a LAN machine you point an app at (a NAS, an SMTP
  relay) needs its full name or its address, not a short one.
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
* **No silent stops.** A command the script did not expect to fail names
  itself before the run ends — one `ERROR unhandled failure` line with the
  exit code, file:line, the functions it was called from and the command
  (as written, so no secret is printed). Paste that line into a bug report.
* **`git pull` is always safe.** Your state lives in `.env` and gitignored
  dirs; tracked files are never written at runtime. `upgrade` wraps pull +
  config migration.

## Where things live

| Where | What | Who writes it |
|---|---|---|
| repo root | the code (`mediastack.sh`, `lib/`, `services/` — one folder per service, `docs/`) | the project — `upgrade` replaces it |
| `.env` | every setting | you (and `configure`) |
| `custom/` | `override.yml` (changes to shipped services), `compose.d/` (your own services, one file each), `proxy.d/` (your own Traefik routes), `trash-overrides.yml` | you — never touched by the script's upgrades, saved in every restore point |
| `local/` | the VPN overlay, pinned images, `.env` backups (the first and the newest 9), a marker while a backup has services stopped, and `runs/`: a record of every run (below) | the script — delete it and it is rebuilt (pins and backups excepted) |
| `config/` `cache/` `transcodes/` `data/` `backups/` | the default roots | the apps — move them with `configure` |

A deployment is `.env` + `custom/` + the roots: that is what to keep, copy
or back up.

**`.env` is checked.** Every setting is described in `lib/env.schema.tsv`
(the shared ones) and `services/<name>/env.tsv` (each service's own) — its type, whether it may be empty, who writes it, its default, configure's recommended answer, what it means — including
the advanced ones read with a default, like `<SERVICE>_PORT` or
`WIZARR_HOST`). **Empty means the default.** `KEY=` with nothing after it and
no line at all read the same, for the script and compose alike: the
setting's default, written once in the schema. A setting without one (a
schedule, where empty means never; a secret, generated on first use) keeps
empty as a value of its own. Before any command runs, every value is checked against it: a
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

**Every run is recorded** in `local/runs/` — from a terminal, the panel, a
timer or the boot guard: one file per run, named for when it started and the
command, with who started it, the commit, everything it printed (each line
timestamped in the stack's time zone) and, at the end, its exit status. A
record without that last line never finished (a dropped SSH session, a
reboot): `doctor` names any from the last 7 days. When a timer's run fails,
the notice to ops quotes the last lines of its record and names the file. The screen shows exactly what it did before; one difference: image
pulls show a line per image, not the progress bars. `credentials`,
`invite`, `reset-password`, `set-credentials` and `logs` record only when
they ran and how they ended, and any secret from `.env` that a run prints is
kept in its record as `<secret:KEY>`. The newest 20 runs of each command are
kept, and a failed or unfinished one 30 days. Records are yours alone
(mode 600) and never leave the host by themselves.

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
services to `services/` or edit `docker-compose.yml`: those are the repo's
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

**How messages look.** Every message is a title, a short markdown text and
a type — info, success, warning or failure — so any service Apprise reaches
shows it its own way. On **Discord** each message is a card in its type's
colour, with the host and stream at its foot; Seerr's events are cards with
the title's poster, large below the text (a neutral placeholder when Seerr has none; a poster
address that stopped working simply shows no picture). Every message comes
from the webhook itself, named *Mediastack* with mediastack's icon:
`notify set` and `wire apprise` set the webhook's name and avatar once
(uploaded from this host — no public address needed). Change either in
Discord afterwards and it stays as you set it. The branding kit
(roadmap) brings your own name, icon and colours.

The hub's configuration is Apprise's YAML: mediastack's entries sit
between two marker lines and are rewritten from the streams' URLs (on
Discord one webhook becomes a few entries — the stream's own messages and
Seerr's events by outcome, each through a template of mediastack's in the
hub's folder). `set` and `clear` change only that stream's URLs —
anything you added in Apprise's UI outside the markers (your own tags) is
kept. A configuration in Apprise's older text format is converted the
first time `wire apprise` runs, your own lines entry for entry. A Discord
webhook's own options (`?avatar=...`) are mediastack's to set; keep your
own on a URL outside the markers. A notification that fails is recorded: `notify` and `doctor` show
the last failure and why. `doctor` also reads the hub's own log for the
past week: any send it could not deliver — the apps' own (the arrs, Seerr,
Prowlarr) included — is named with its sender and tag (an app behind the
VPN sends as gluetun, so those show as the VPN group).

**Seerr's events** (requests, approvals, availability, failures, issues)
reach the hub tagged with the event's own name, and each stream's URLs
carry the events that stream receives, so the hub routes them: *media
available* goes to **users**, everything else to **ops**. The card leads
with Seerr's event and who asked, then the title (with its year) and its
overview — Seerr's own words (Seerr's own test, which has neither, reads
*Seerr · test*). The table is `NOTIFY_EVENTS` in `lib/notify.sh` (the
card colour per event: `NOTIFY_EVENT_TYPE`); `wire apprise` keeps
mediastack's entries current. Seerr only announces media that was *requested* through it — a
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
service with a live-session check. Scheduled updates and backups instead
defer while someone is watching in Jellyfin (`UPDATE_DEFER_IF_ACTIVE`, on by
default; `UPDATE_DEFER_MAX_MIN` caps the wait, then `UPDATE_DEFER_ACTION`
proceeds or skips the run). Jellyfin is the only app asked: listening in
Navidrome or Audiobookshelf, or reading in Kavita, is not seen (see the
watchlist, "Deferring for other apps' sessions").

Upgrading an existing install: `wire seerr` updates the message template
of the agent it made in any earlier version (tag `activity`, then `ops`,
then the plain one before the cards, then the first card) to the current one; the events you turned on in Seerr and its poster
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
`apprise://apprise:8000/mediastack?tags=users` (`gluetun:8000` if you
moved Apprise into the VPN; an agent added before schema 32, when it ran
inside, still says `gluetun:8000` — change it).

Apprise's own UI lives at `https://notify.<your-domain>` (or
`http://<host>:8000` on the LAN) — that's where stored endpoints are
edited after the first wire.

With WatchState enabled, wire installs Jellyfin's Webhook plugin for its
webhook mode (without WatchState, no plugin and no Jellyfin restart);
its destinations stay yours to configure in Jellyfin's Dashboard ->
Plugins -> Webhook (WatchState's UI hands you the exact URL to paste per
backend).

Apprise runs outside the VPN by default, so an alert that the tunnel is down
still gets out, and your downloads' address is never tied to your
notification account (why, and how to move it: docs/vpn-membership.md).
What a notification says is read by the service you send it to either way —
for the `ops` stream, an endpoint you host yourself keeps it at home.

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
`credentials`), remote access on with UPnP off, the server name `configure` asked
(`JELLYFIN_SERVER_NAME`; set once, while the name is still the container's
random ID hash — a name set in Jellyfin stays), Traefik's address in Known
proxies while Traefik is on (so sessions show each client's own address
rather than Traefik's; one Jellyfin restart when it changes; any other
entries stay yours), the transcode path moved
to `TRANSCODE_ROOT` (Jellyfin's default is inside `/config`, which
`backup` archives; segments are written at source bitrate for the whole
session, so give `TRANSCODE_ROOT` a few GB per concurrent stream on local
disk — a NAS share stutters, a tmpfs flies), and
libraries derived from the arrs' root folders — created with their default
names (Movies, Shows, ...), never asked; rename them in Jellyfin. Everything
else is yours to manage in the GUI, and wire can't undo you: libraries
are matched by **path, never name**, so renames, merges, and settings
changes are respected — wire only ever creates what's missing, and the
wizard gate closes itself after the first run.

Seerr has no logins of its own: everyone signs in with their Jellyfin
account. It asks Jellyfin only at sign-in and keeps its own session: someone
whose Jellyfin access you take away (or whose portal account you turn off)
cannot sign in to Seerr again, but a Seerr page they already have open keeps
working until its session expires — they can still make requests there (not
watch) ([docs/design-access.md](docs/design-access.md), decision 14).
`wire seerr` bootstraps an uninitialised Seerr (owner = the
Jellyfin admin, libraries enabled, every arr connected with its TRaSH
profile); an initialised Seerr is never touched.

## Books & audiobooks (Audiobookshelf, Kavita)

Two serving apps cover the reading/listening side. `wire audiobookshelf` and
`wire kavita` do each one's first run (the stack's own admin, in
`credentials`); with the portal, people sign in to both with their portal
accounts (see "The portal and the gate"). Without it, create accounts in each
app's UI.

* **Audiobookshelf** (`https://audiobooks.<your-domain>`) — audiobooks
  and podcasts, progress sync, official mobile apps. Reads
  `${DATA_ROOT}/media/audiobooks` and `.../podcasts`.
* **Kavita** (`https://books.<your-domain>`) — ebooks, comics and manga
  in one modern reader with OPDS and Kobo/KOReader sync. Reads
  `.../media/books`, `.../comics`, `.../manga`. Its portal card opens its
  sign-in through the portal (`/oidc/login`) and lands you inside; its bare
  address works too, after an "unauthorized" notice and its login page.

### Acquisition (LazyLibrarian)

The `lazylibrarian` profile automates book acquisition — the Readarr
replacement. It monitors authors, grabs ebooks/audiobooks, and hands them
to the download client. `wire lazylibrarian` sets qBittorrent as that client
when it is the stack's choice (`DOWNLOAD_CLIENT`) — with Deluge or
Transmission, wire says so and you add it in LazyLibrarian's UI (Config ->
Downloaders) — and its book folders (`/data/media/books`, `/data/media/audiobooks`) and registers it
in Prowlarr as a first-class app, so indexers sync automatically like the
arrs. A fresh LazyLibrarian has its API off: `wire` switches it on with a
key of its own (written to its `config.ini` while it is stopped), before
Prowlarr registers it. It lives in the VPN namespace, so grabs ride the
tunnel. Its page has no login of its own: behind the authentik portal the
portal guards it; otherwise `wire` gives it the arr login (a browser
sign-in prompt — its API still takes only its key, so Prowlarr is
unaffected), and `set-credentials arr` keeps it in step. LazyLibrarian
keeps that password in plain text in its `config.ini`.

## Music (Navidrome)

The `navidrome` profile serves the music lidarr manages through the
Subsonic API — any Subsonic client (phone, desktop, car stereo) plays
your collection, a real music experience where Jellyfin's is an
afterthought. It reads `${DATA_ROOT}/media/music` **read-only**: it
serves, lidarr owns the files. Its first account is the stack's own admin:
`wire navidrome` makes it on a fresh install (see `credentials`). Without the
portal, that admin adds people in Navidrome (Settings → Users). With the
portal, nobody creates one: the portal signs people in and Navidrome makes
their account on the first visit (see "The portal and the gate"); admin
rights follow the portal's `admin` group. Their music apps sign in with
their Navidrome password, which each person sets once in Navidrome's own
change-password form (Navidrome has no separate app password; the
current-password field stays blank — nobody ever chose the first one). The
portal never checks it — so every 15
minutes (`people-sync`), and at once after an `access` command on Navidrome,
the stack takes it back from anyone the portal no longer lets open Navidrome:
their portal account deactivated or deleted, or Navidrome made admin-only
(`access tier navidrome admin`) or their grant revoked. Their password is
replaced (their music and history stay; allowed again, they set a new one),
and a deleted person's account is renamed `removed-<name>-<date>`, so someone
joining later under that name starts fresh. An account Navidrome had before the portal, or one
made by hand, is never touched. Navidrome on an install from before this
already has its first visitor as admin: `wire navidrome` says how to add the
stack's.

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

Its first visit asks you to make its account (WatchState has one). Behind
the portal it then asks for it no more; keep the password anyway — it is the
way in once the portal is off, and `disable authentik` warns if no account
was ever made.

## The portal and the gate (authentik)

With authentik enabled, `portal.<domain>` is where your users join (by
invitation: `./mediastack.sh invite`, or `invite --email <address>` to have the
portal send it) and log in; its dashboard shows each person
the apps they may use. Two groups decide access: `frontend` (everyone who
joins) and `admin` (you — `wire authentik` puts akadmin there; make your own
account with `invite`, then `./mediastack.sh access admin <you> on`, and use
akadmin only when no one else can get in; `access admin <user> off` takes it
back and ends their portal sessions. authentik's own admin screens are a
separate choice: `access portal <you> on` (an admin only, asked first) — the
verbs cover people, invites, groups and resets without them; before Nov 2026
the groups were named
`media-users` and `admins` — an upgrade renames them in place, members and
access kept; a group changed by hand there ends nobody's session, so end the
person's sessions too: Directory → Users → the person → Sessions). Sign-up refuses a username the
apps would confuse: the stack's own accounts there (Audiobookshelf's root,
Jellyfin's local admin) and an existing person's name in a different case.
The sign-in page has a show-password button, so a mistyped password can be
seen before it is sent (`wire authentik` adds it once; switched off in
authentik's UI, it stays off). The portal's website takes only a person's
password, never an app password (Settings → Credentials → Tokens and App passwords):
authentik's own sign-in would let one in as its owner, so `wire authentik`
turns that off and `doctor` fails if an authentik upgrade turns it back on
([docs/design-access.md](docs/design-access.md)). Jellyfin takes app
passwords only with `LDAP_APP_PASSWORDS=yes` (a full `configure` asks; off by
default): then a person can give each device — a TV, a phone — its own
password, up to a year, so the device never holds their real one, and
deleting it stops that device signing in again (how: "A device's own
password" below). Someone locked out — a forgotten
password, or too many wrong ones from the Jellyfin app — helps themselves
once email works: the sign-in page's **Forgot password?** emails them a link
(30 minutes, single use) to choose a new one, which clears their login
throttle and works in every app. The link shows only while the portal's email
settings have passed `email test`, so a portal without email never offers a
dead one. Without email, `./mediastack.sh reset-password <username>` clears
their login throttle and prints a single-use sign-in link to send them; they
set a new password in the portal's Settings.

Each person's email is their own: sign-up refuses one another account already
has, and nobody can change their own (apps such as Kavita know people by it).
An admin changes one with `./mediastack.sh set-email <user> <address>` —
Kavita's account follows, and an address someone else already has is warned
about first. `./mediastack.sh users` lists everyone with their email and
groups. The portal can also send email — optional, through any SMTP service
(a Gmail account with an app password is the simplest):
[docs/email.md](docs/email.md), then `./mediastack.sh email test <address>` —
a passed test turns on **Forgot password?** on the sign-in page.

Moving an existing household onto the portal: invite each person, and once
they have joined, `./mediastack.sh link-account <username>` ties their local
accounts to the portal one — same accounts, so watch history, reading and
listening progress and Seerr requests stay. You pick which local account is
theirs in each app (never guessed from a name or an email) and confirm a plan
that says what changes, including admin rights: those follow the portal's
`admin` group from then on, so put them there first to keep them. Jellyfin
and Kavita are done at once; Audiobookshelf's own API cannot link an account,
so for one sign-in it matches by username — only after checking no other
account could be claimed that way, and closed again as soon as they sign in
(or after 10 minutes). Their old passwords stop working in these apps.

The **gate**: every web interface declares who logs it in —
`mediastack.auth: gate` (behind the portal), `native` (its own login) or `open`.
A gated interface's domain address asks the portal first: not logged in → the
portal's login, then straight back; logged in but not in `admin` → refused.
Each gated app has a gate of its own — an authentik provider for its one
address, with its dashboard card saying who may open it (`admin` and
`app-<svc>` for a tool) — and the domain-wide gate stays behind them as the
catch-all: an address without a gate of its own admits `admin` only. `doctor`
fails a card of ours that has a gate but no rule (authentik would let everyone
signed in through it).
**Tiers:** each app behind the gate is for the household (`frontend` — the
household and its admins; on the dashboard's Media shelf) or for admins only
(`admin`; with the tools). The tools start as `admin`, Navidrome, Jellyfin,
Kavita and Audiobookshelf as `frontend`; `./mediastack.sh access` lists them and `access tier <app>
frontend|admin` moves one. One person, one app: `access grant <user> <app>`
(and `access revoke`) — the `app-<svc>` group. A grant made by hand in
authentik's admin shows on that person's dashboard only once the person is
saved there (Directory → Users → the person → Edit, saved unchanged) or a day later;
`access grant` does that itself.
Gated: the panel, Apprise, every admin tool (the arrs, Prowlarr, Bazarr, the
download clients, LazyLibrarian, Cleanuparr, WatchState, Pi-hole, ErsatzTV) and
Traefik's dashboard. Navidrome sits behind a *household* gate: anyone in
`frontend` gets in, and the portal tells Navidrome who they are (it creates
them on their first visit); music apps use `/rest/` with a password each user
sets once in Navidrome's settings, taken back when their portal account goes
(see "Music (Navidrome)"). Past the gate, the arrs, Prowlarr, Bazarr and
LazyLibrarian ask for no login of their own either — without the portal they
take the shared arr login again — and qBittorrent asks none of the people the
portal let in (it skips its login for Traefik's address alone; the arrs and
the script still sign in), and Pi-hole's page and API ask no password (it
reads it only at its start, so `up` applies the change; a Pi-hole phone app
then needs a device password like the arrs'), and Transmission asks nothing
of them either (Traefik adds its login past the gate; everything else still
signs in), and WatchState signs them in without its own login (it trusts
Traefik's address alone, read at its start, so `up` applies the change; its
account is still the way in without the portal). Cleanuparr signs in through
the portal itself: its login page gets a "Sign in with <portal title>" button
— one click, no password, about once a week per browser — and keeps its own
login (the arrs') for the script and for when the portal is off; `wire
cleanuparr` sets it up and `disable authentik` takes the button away first.
Deluge alone still asks its own password past the gate: its web
UI cannot turn it off (`credentials` shows it; docs/watchlist.md). The rest
follow tool by tool: docs/design-logins.md. The panel needs no login of its own past
the gate (its own admin is only the way in without the portal): it trusts the portal's identity headers, on a network only the edge
joins (`mediastack-panel`; docs/frontdoor.md). Every route past a gate strips the portal's
identity headers, and Navidrome trusts only Traefik's address — Traefik keeps
one fixed address on the stack network's fixed range (`MEDIASTACK_SUBNET`,
`MEDIASTACK_IP_RANGE`, `TRAEFIK_ADDRESS`; change them only if they clash with
your LAN — the first `up` after the change recreates the network once). Your
household apps appear on everyone's dashboard under Media.

Jellyfin checks passwords against the portal (LDAP, through Traefik on
`ldap.<domain>`, reachable from the stack only): anyone who may open Jellyfin
— `admin`, those granted it (`app-jellyfin`), and `frontend` while its tier is
`frontend` — signs in to Jellyfin (the web, the TV and phone apps) with their
portal username and password, and gets a Jellyfin account with every library on
their first sign-in. `wire jellyfin` sets this up (one Jellyfin restart) and
keeps Jellyfin administrator rights in step with the portal's `admin` group.
Taking Jellyfin away (`access tier jellyfin admin`, `access revoke`, or their
portal account turned off or deleted, even by hand in authentik) disables
their Jellyfin account and signs them out of every device — at once from
`access`, within 15 minutes otherwise (`people-sync`); their history stays,
and getting it back turns the account on again. A person deleted from the
portal also has their Jellyfin account renamed `removed-<name>-<date>` (as
Navidrome does), so someone who later signs up under that name starts fresh. Someone you disabled yourself
in Jellyfin's dashboard stays disabled. Seerr's card follows Jellyfin's rule
and Seerr signs people in through Jellyfin, so a new Seerr sign-in is refused
too — but a Seerr session already open runs until it expires (Seerr has no
switch to turn a person off; docs/watchlist.md).
The stack's own Jellyfin admin (in `credentials`) stays a local account: it is
what the script uses, and your way in if the portal is ever down.

A Jellyfin sign-in takes several seconds (about eight today): the portal checks
the password live every time, with nothing remembered, so a changed password, a
deactivated person or a lockout counts at once. Only signing in waits — the app
keeps its session, so playback is not slowed. About five wrong passwords in
Jellyfin lock that person out of Jellyfin's sign-in for a day; a password reset
clears it at once (**Forgot password?** on the portal's sign-in page, or
`./mediastack.sh reset-password <username>`). Wrong passwords on the portal's
own page do not count toward it. Jellyfin refuses a locked-out person exactly
as it refuses a wrong password, even when they typed the right one; authentik's
log names each such refusal (`./mediastack.sh logs authentik --no-follow | grep throttled`).

**A device's own password** (Jellyfin only, with `LDAP_APP_PASSWORDS=yes`). A
TV or a phone can sign in to Jellyfin with a password made just for it, so it
never holds the person's real one. The person makes it themselves:
1. In the portal: Settings (⚙) → Credentials → Tokens and App passwords →
   **New App Password**. Name it after the device (`living-room-tv`), one per
   device, so each can be taken away on its own.
2. Set its expiry: the form starts at 30 minutes from now, so change it —
   up to a year.
3. On the device, sign in to Jellyfin with the portal username and that
   password.

The portal's own website refuses these passwords. They open Jellyfin, and,
sent by an app as a header, the apps behind the portal their owner may open
(next how-to): an admin's TV password opens the arrs' API too, so keep one
per device and delete it with the device. When one expires, that device's next sign-in is refused; a
device already signed in stays signed in. To take a device's access away:
delete its password in the same list (its next sign-in is refused at once),
then `./mediastack.sh signout <user>`, which ends the sign-ins Jellyfin
already holds. `signout` signs the person out of Jellyfin on **every**
device, so their other devices sign in again, each with its own password. A
browser goes to the sign-in page on its next click; a phone app may spin
until it is closed and reopened. With `LDAP_APP_PASSWORDS=no` (the default)
Jellyfin takes only the real password. To change it: a full
`./mediastack.sh configure`, or `.env`, then `./mediastack.sh up` and
`./mediastack.sh wire authentik` (the portal's setup takes about four
minutes to apply).

**A phone app for the arrs** (nzb360 and the like, with the portal). The
arrs', Prowlarr's and Bazarr's API is behind the portal's gate, like their
pages: their API key is one key that everyone who ever opened the app could
read, so on its own it opens nothing. A phone app sends the key *and* a
device password, which the gate checks against who may open that app
(`./mediastack.sh access list <user>`). The person makes it:
1. A device password as above (Settings → Credentials → Tokens and App
   passwords), named after the phone and the app (`phone-nzb360`), expiry up
   to a year. Needs `LDAP_APP_PASSWORDS=yes`: with `no`, an app password lasts
   at most a day.
2. Turn it into the header's value, on any machine with bash (Git Bash on
   Windows) — it does not echo the password:
   ```bash
   read -rp 'portal username: ' U; read -rsp 'device password: ' AP; echo
   printf 'Basic %s\n' "$(printf '%s:%s' "$U" "$AP" | base64 -w0)"; unset U AP
   ```
   The printed line *is* the password, only encoded: treat it as one.
3. In the app, for each of the arrs: the https address and API key from
   `./mediastack.sh credentials`, and one custom header — name
   `Authorization`, value the whole printed line, starting `Basic ` (nzb360:
   the service's settings → Custom Headers).

Without the header the app reports it cannot reach the server. An app with
no custom-header setting cannot reach the arrs from outside. Taking the app
away from the person (`access tier`, or out of a group) or deleting the
password refuses the phone within a minute: the gate checks the password
afresh after that long, with no session to end. The stack's own calls between the apps never
pass the gate.

Audiobookshelf signs people in through the portal (OIDC): its login page goes
straight to the portal (the app shows a "Log in with <portal name>" button);
the root account's password form is behind
`https://audiobooks.<domain>/audiobookshelf/login?autoLaunch=0` (in
`credentials`). The account is made on the first sign-in
(never matched to an existing account — a username match would let anyone who
signs up as the root account's name sign in as root), and the
Audiobookshelf app signs in the same way. `wire audiobookshelf` does its first
run itself — the root account it creates is the stack's own (in `credentials`,
also the way in if the portal is down; its name is the stack's username,
which the portal refuses to anyone joining) — sets up the sign-in, and keeps admin
rights in step with the portal's `admin` group. An Audiobookshelf set up by
hand is never taken over: put its root login in `.env`, or start it fresh
(wire prints how). Its libraries are yours to add in its UI. Who may open
it follows the same rule as Jellyfin and Kavita (`access tier
audiobookshelf`, `access grant`): the portal refuses anyone else at sign-in,
and losing it turns their Audiobookshelf account off — Audiobookshelf checks
on every request, so even an open tab ends at its next click — at once from
`access`, within 15 minutes otherwise; getting it back turns it on again
(only if the stack turned it off). A person deleted from the portal has their
account renamed `removed-<name>-<date>`, so someone joining later under that
name can register. Its folders stay writable — it downloads podcast episodes,
and admins upload and write metadata — but a household account cannot
change, delete or upload anything: Audiobookshelf gives it download only,
checked on every request.

Kavita works the same way: its login page goes straight to the portal, the
account is made on the first sign-in, and `wire kavita` does its first run
(the stack's own admin, whose password form is behind
`https://books.<domain>/login?skipAutoLogin=true`, in `credentials`), sets up
the sign-in (one Kavita restart, the household warned) and keeps admin rights
in step with `admin`. New people get every library that exists when they
first sign in; a library added later reaches existing people only when you
grant it in Kavita (Settings → Users) — `doctor` lists who lacks one, and wire
never changes anyone's access, so restrictions you set there stay. Kavita
matches a portal sign-in to an existing account by email, so the stack's admin
gets an address nobody can sign up with; a hand-made admin with a real address
gets a warning from wire (change it in Kavita). Who may open Kavita follows
the same rule as Jellyfin (`access tier kavita`, `access grant`): the portal
refuses anyone else at sign-in, and losing it takes their `Login` role in
Kavita away — an open tab ends at its next reload — at once from `access`,
within 15 minutes otherwise; getting it back gives it back (only if the stack
took it). Someone you shut out yourself in Kavita stays out. A tab already
open keeps reading until it is reloaded or closed — Kavita has no way for an
admin to end someone else's session (docs/watchlist.md). Signing out of the
portal does sign that browser out of Kavita too, so the next person at a
shared computer starts at the portal, not in the last person's Kavita. In it they can read
and download, but not change or delete a book: Kavita's libraries are mounted
read-only. Libraries, settings and people are for Kavita's `Admin` role,
which the household does not get — though an admin you demote keeps admin
rights in a tab they already have open until it reloads. A person deleted
from the portal has their Kavita account renamed `removed-<name>-<date>` with
an email nobody can sign up with, so a newcomer with their name or email
starts fresh. While the portal runs, their host ports listen on 127.0.0.1 only —
the domain address is the way in — and the arrs trust the portal (one login;
`wire arr` switches them, never before their ports are closed). Companion apps
(nzb360, Home Assistant…) use the domain address, and their API is behind the
gate like their pages: an app sends its API key *and* a device password, so
the key alone opens nothing (how: "A phone app for the arrs" above). The others
still ask for their own login behind the portal for now. Disabling authentik
gives every arr its own login back — verified — before the ports reopen.
Apprise has no login of its own, so it is served only through the portal:
without it (Wizarr, or no account model) its address is refused to everyone
and its port listens on 127.0.0.1 only — `notify` does what its UI would. After
enabling authentik, run `./mediastack.sh wire` once: it waits for the portal's
first start, attaches the gate, adds the admin cards to your dashboard and
switches Jellyfin's sign-in to the portal (doctor fails until it has).

## Invites (Wizarr)

For installs that chose Wizarr as the account model (with the portal,
`invite` makes a portal sign-up link instead — see above). Wizarr turns "set
up my account" into a link. Its first run is a one-time
UI step: create the admin account, add Jellyfin as a server (URL
`http://jellyfin:8096`, its **External URL** the stack's Jellyfin address —
where a new person lands after signing up — and the stack's Jellyfin API key,
shown by `credentials`), and make a Wizarr API key (Settings → General, at the
bottom). `wire wizarr` walks you through it with the exact values to paste,
stores the key once Wizarr takes it (a paste cut short is asked again), and
checks the External URL; doctor checks both. After that:

```bash
./mediastack.sh invite               # never-expiring invitation URL
./mediastack.sh invite --expires 7   # or 1 | 30 days
```

Someone locked out: `./mediastack.sh reset-password <user>` prints Wizarr's
single-use reset link (valid 24 hours) — send it to them privately; they
choose their own password on it. A newer link voids the last. Wizarr sends no
email, so the link is yours to pass on. A disabled Jellyfin account is
reported, not enabled.
After `rotate-secrets`, paste the new Jellyfin API key into Wizarr's server
entry (Settings → Servers): Wizarr's API cannot set it.

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
a web control panel over the safe verbs (OliveTin front door) · the portal
(authentik): one login for Jellyfin (LDAP), Audiobookshelf and Kavita (OIDC,
their apps included) and Navidrome, invitation-only sign-up, every admin tool
behind it · moving an existing household's accounts onto it with their
history (`link-account`) · password reset for someone locked out
(`reset-password`, with the portal or Wizarr) · every machine secret rotated
and proven in one run (`rotate-secrets`) · each person's email their own, changed by an admin
(`set-email`, `users`) · optional outgoing email for the portal (any SMTP
service, `email test`) · deletion attribution and the media manifest · the
arr recycle bin · restore points that keep a shard (authentik's four
containers) together · containers that ignore the host's search domain.

**Pre-alpha.** The first household rollout comes next (see the roadmap);
changes from here are fixes, polish and the rollout itself. Project goals and forward direction live
in [docs/roadmap.md](docs/roadmap.md); what was evaluated and set aside, and
what would reopen it, in [docs/watchlist.md](docs/watchlist.md).

## Docs

* [docs/edge.md](docs/edge.md) — HTTPS, hostnames, certificates, proxying non-stack hosts
* [docs/email.md](docs/email.md) — adding email (SMTP): picking a sender, the settings, testing, troubleshooting
* [docs/certificates.md](docs/certificates.md) — where the certificate comes from: Let's Encrypt, your own, staging; renewal
* [docs/trash-sync.md](docs/trash-sync.md) — quality profiles, overrides, ownership
* [docs/vpn-membership.md](docs/vpn-membership.md) — moving services in/out of the VPN
* [docs/privacy.md](docs/privacy.md) — what leaves your box, to whom, from which address
* [docs/adding-a-service.md](docs/adding-a-service.md) — extend the stack
* [docs/migration-existing.md](docs/migration-existing.md) — adopt an existing deployment
* [docs/disaster-recovery.md](docs/disaster-recovery.md) — full rebuild from a restore point
* [docs/troubleshooting.md](docs/troubleshooting.md) — problems that look like the stack but aren't (e.g. Android phones blocked from the LAN)
* [docs/roadmap.md](docs/roadmap.md) — project goals, architecture rules, and open work
* [docs/watchlist.md](docs/watchlist.md) — rejected, parked and deferred items, each with what would reopen it
* [docs/frontdoor.md](docs/frontdoor.md) — the OliveTin web panel: what it is, enabling it, the buttons
* [docs/frontdoor-safety.md](docs/frontdoor-safety.md) — the front door's safety model and what is (and isn't) exposable
* [docs/testing.md](docs/testing.md) — the checks CI runs, the config matrix, and the soak harness that simulates days of use on a test box

## License

MIT — see [LICENSE](LICENSE). Share it around.
