# Dispatcharr — Live TV

Dispatcharr keeps your IPTV sources — M3U playlists and Xtream Codes
accounts — and their programme guide (EPG) in one place: it matches channels
to the guide, lets you prune and order thousands of channels, and hands the
result to Jellyfin as one tuner. The household watches Live TV in Jellyfin;
Dispatcharr is where an admin sets the channels up.

mediastack ships no playlist and no provider, as it ships no indexer: the
sources are yours to add (Dispatcharr → M3U & EPG Manager).

## Turning it on

```
./mediastack.sh enable dispatcharr
```

Its address is `https://iptv.<your domain>` (rename: `traefik-setup --hosts`).
Its first start takes about half a minute (its database is made then).

## What mediastack sets up

- **The image:** Dispatcharr's all-in-one image — its database (PostgreSQL),
  Redis, its workers and its own web server in one container — pinned to one
  version (`ghcr.io/dispatcharr/dispatcharr:0.34.1`): it is young and changes
  quickly, so a new version comes with a mediastack release that checked it.
- **One admin, the stack's own:** `wire dispatcharr` creates it on a fresh
  install from the stack's login (`credentials` shows it,
  `set-credentials dispatcharr` changes it).
- **Signing in, with the portal:** Dispatcharr is an admin tool — the portal
  lets only its admins through (`access` can move it). Past the portal,
  Traefik adds a header that names the stack's admin, and Dispatcharr signs
  the browser in as it: no second login. Dispatcharr believes that header
  only from Traefik's address (`DISPATCHARR_TRUSTED_PROXIES`), and no route
  to it skips the portal, so nobody can send the header themselves.
- **Without the portal:** its own login page asks for the stack's admin, and
  its header sign-in is off (`wire` turns it off; Traefik removes the header).
  `disable authentik` turns it off before the port reopens.
- **Jellyfin:** not wired to it yet — its tuner and guide are the next part
  of this step (docs/roadmap.md, step 10). Meanwhile, add them by hand in
  Jellyfin's Live TV settings: tuner `http://dispatcharr:9191/hdhr`
  (HDHomeRun), guide `http://dispatcharr:9191/output/epg` (XMLTV).
- **Workers:** 2 web and 2 background workers — about 950 MiB of memory idle.
  More: `UWSGI_WORKERS` / `CELERY_MAX_WORKERS` in `custom/override.yml`.
- **VPN:** outside it by default; `./mediastack.sh vpn dispatcharr on` moves
  it in (its sources are then fetched through the tunnel).

## What it stores where

| What | Where |
|---|---|
| its database, settings, logos, guide files, logs | `config/dispatcharr/` (in every restore point) |
| recordings (its DVR) | `data/media/recordings/` (the data tree — never in a restore point) |
| its token-signing key | `config/dispatcharr/jwt` — made by mediastack before its first start; a new one: delete it, then `up` (everyone signs in again) |

## Known gaps

- **It asks GitHub for new versions** — when it starts and once a day; it has
  no switch for that ([watchlist](../../docs/watchlist.md), "Dispatcharr
  upstream gaps"). Its public-IP lookup is turned off.
- **Only Jellyfin plays its channels.** IPTV players on the LAN (TiviMate
  and the like) would need a route that skips the portal — not shipped
  ([watchlist](../../docs/watchlist.md), "Dispatcharr's channels in IPTV
  players on the LAN").
- **Sign-ins are limited** to 3 a minute from one address (its own rule,
  password and header alike). A refused sign-in says to wait a minute.

## Troubleshooting

- `./mediastack.sh logs dispatcharr` — its own log (its level after the time).
- `./mediastack.sh wire dispatcharr` — checks the admin and the header
  sign-in again, and proves the header signs nobody in from anywhere but
  Traefik.
