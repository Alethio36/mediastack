# Mediastack

A self-hosted media server stack — VPN-isolated downloading, the *arr suite,
Jellyfin with fast search, and a request site — managed by one script that
installs, configures, updates, backs up, and diagnoses the whole thing.

Built to work for anyone: every setting has a sane default, every wizard
prompt explains itself, and every failure states its fix.

## Quick start

```
git clone <this-repo> && cd mediastack
./mediastack.sh install      # host dependencies (Debian/Ubuntu)
./mediastack.sh configure    # guided setup — explains every question
./mediastack.sh up
./mediastack.sh doctor       # verify
./mediastack.sh leak-test    # prove the VPN can't leak
```

`./mediastack.sh` with no arguments lists every command with an explanation;
`./mediastack.sh menu` gives you an interactive menu.

## What runs (à la carte)

Pick any combination of services — the wizard walks you through it, and
`enable <service>` / `disable <service>` change it any time. Dependencies
are handled automatically (picking qBittorrent brings the VPN; JellySearch
brings its search engine) and disabling something another service needs is
refused with an explanation.

| service | what it is |
|---|---|
| gluetun | VPN gateway — all download traffic exits through this tunnel |
| qbittorrent | torrent client (runs inside the VPN) |
| sonarr / radarr / lidarr | TV / movie / music automation |
| prowlarr | indexer manager feeding the arrs |
| jellyfin | the media server your users watch |
| meilisearch + jellysearch | instant, typo-tolerant Jellyfin search |
| npm | reverse proxy + HTTPS certificates |
| seerr | request/discovery site for your users |
| bazarr | subtitle automation |
| pihole / cloudflared | ad-blocking DNS / expose without port-forwarding |
| flaresolverr | captcha bypass helper for some indexers |
| deluge / transmission | extra torrent clients (most people need neither) |
| ersatztv | virtual live-TV channels from your library |

The recommended "standard" pick is the first eight rows.

## The rules the tooling enforces

* **Configs on local disk only** — SQLite corrupts on NFS/SMB; the wizard
  refuses network paths for CONFIG_ROOT. Media (DATA_ROOT) on a NAS is fine;
  backups (BACKUP_ROOT) on a NAS is encouraged.
* **Every update is preceded by a restore point.** `update` = backup → pull →
  apply → health gate. Anything broken: `rollback <service>` returns
  yesterday's config *and* yesterday's exact image, and holds it there until
  you `unpin`.
* **Downloads cannot leak.** VPN'd services run inside gluetun's network
  namespace, start only after the tunnel is verifiably up, and `leak-test`
  proves the whole chain (add `--killswitch` for the destructive proof).
* **`git pull` is always safe.** Your state lives in `.env` and gitignored
  dirs; tracked files are never written at runtime. `upgrade` wraps pull +
  config migration.

## VPN membership

Which services run inside the VPN is defined in the compose fragments, not
asked by the wizard — it is a safety boundary, and `leak-test` audits it.
Default: the acquisition chain (torrent clients, arrs, flaresolverr) is
inside gluetun; the serving chain (Jellyfin, proxy, Seerr, search) is not.
`status` shows a VPN column so you can see membership at a glance.

To change it for your deployment, use `docker-compose.override.yml`
(gitignored — survives upgrades). Example, moving sonarr OUT of the VPN:

```yaml
# docker-compose.override.yml
services:
  sonarr:
    network_mode: !reset null
    networks: [mediastack]
    ports:
      - "8989:8989"
    labels:
      mediastack.vpn: "false"
```

and set `SONARR_PORT=18989` in `.env` so gluetun's (now unused) mapping
frees host port 8989. Moving a service IN is the reverse: set
`network_mode: "service:gluetun"`, `!reset` its `networks:` and `ports:`,
label `mediastack.vpn: "true"`, add its port to gluetun's `ports:` in the
override (lists merge), and add a `depends_on: gluetun:
condition: service_healthy` leak guard. Re-run `leak-test` after either
change — it validates the labels against the running topology.

## Search (JellySearch)

The `search` profile makes Jellyfin search instant and typo-tolerant for
every client. One manual step: your reverse proxy must route search requests
to JellySearch. In NPM, open the Jellyfin proxy host, find the custom nginx
config field (gear icon on the tab row in current versions), and paste:

```
location ~* (/Users/.*/Items|/Items|/Artists|/Genres|/Persons|/Studios)$ {
    if ($args ~* "searchterm=") {
        proxy_pass http://jellysearch:5000;
        break;
    }
    proxy_pass http://jellyfin:8096;
}
```

Search via your domain (direct `:8096` bypasses the proxy and stays slow).

## Default ports

| app | port | | app | port |
|---|---|---|---|---|
| Jellyfin | 8096 | | Prowlarr | 9696 |
| NPM admin | 81 | | Lidarr | 8686 |
| qBittorrent | 8085 | | Bazarr | 6767 |
| Sonarr | 8989 | | Seerr | 5055 |
| Radarr | 7878 | | Pi-hole web | 83 |

All overridable in `.env` (`SONARR_PORT=` etc).

## After install (manual app wiring — phase 2 will automate this)

1. **Jellyfin** (`:8096`): run the wizard, add `/media/tv` + `/media/movies`.
2. **qBittorrent** (`:8085`): password is in `docker logs` on first run;
   set download dir to `/data/torrent`.
3. **arrs**: root folder `/data/media/<type>`, download client
   `localhost:8085`, then connect Prowlarr → each arr (Full Sync).
4. **Seerr** (`:5055`): connect to Jellyfin, then Sonarr/Radarr by API key.
5. **NPM** (`:81`, default `admin@example.com`/`changeme` — change it):
   add proxy hosts per app; wildcard cert via DNS challenge.
   [TRaSH Guides](https://trash-guides.info/) for arr tuning.

## Docs

* [docs/adding-a-service.md](docs/adding-a-service.md) — extend the stack
* [docs/migration-existing.md](docs/migration-existing.md) — adopt an existing deployment
* [docs/disaster-recovery.md](docs/disaster-recovery.md) — full rebuild from a restore point
