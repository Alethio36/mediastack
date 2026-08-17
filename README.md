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

## What runs (profiles)

| profile | services | default |
|---|---|---|
| core | gluetun (VPN), qBittorrent, Sonarr, Radarr, Prowlarr, Jellyfin, Nginx Proxy Manager | ✔ |
| search | Meilisearch + JellySearch — instant, typo-tolerant Jellyfin search | ✔ |
| requests | Seerr — request/discovery site for your users | ✔ |
| music / subs | Lidarr / Bazarr | |
| dns / tunnel | Pi-hole / Cloudflare tunnel | |
| flaresolverr | captcha helper for some indexers | |
| torrents-extra | Deluge + Transmission (most people want neither) | |
| tv | ErsatzTV virtual live-TV channels | |

`enable <profile>` / `disable <profile>` at any time.

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
