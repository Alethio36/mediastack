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
- **Jellyfin:** `wire jellyfin` adds Dispatcharr as Jellyfin's Live TV
  tuner (HDHomeRun, `http://dispatcharr:9191/hdhr`) and guide (XMLTV,
  `http://dispatcharr:9191/output/epg`), and reads both back. A VPN toggle
  re-points both in place; their other settings — name, tuner count, channel
  mappings — are yours. Channels appear once Dispatcharr has some: add a
  source (M3U and EPG) in its UI — a plain playlist URL is account type
  **Standard** (its form starts on Xtream Codes) — and make channels from
  its streams (the Streams pane's create-channels button, or a stream's own
  green +), then refresh the guide in Jellyfin (Dashboard → Live TV).
  Jellyfin keeps the guide file up to an hour: after changing channels,
  open the XMLTV guide there and save it unchanged (that drops its copy),
  then Refresh Guide Data. Wired from `provides/live-tv.jellyfin.json`
  — the live-tv role, which ErsatzTV provides too; with both on, Dispatcharr
  is the one wired, and ErsatzTV's channels reach Jellyfin through it: add
  `http://ersatztv:8409/iptv/channels.m3u` as a source in Dispatcharr (guide
  `http://ersatztv:8409/iptv/xmltv.xml`). A tuner you added by hand for it is taken over (found by
  its DeviceID), not doubled.
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
