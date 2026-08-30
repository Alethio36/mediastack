# VPN membership — moving services in or out

Which services run inside the VPN is an operator choice, changed with the
`vpn` command. No fragment editing and no compose overrides: membership is
generated into `local/vpn-overlay.yml` and applied on the next `up`.
`leak-test` audits the result and `status` shows a VPN column at a glance.

## Defaults

The acquisition chain runs inside gluetun; the serving chain does not.

* **Inside (default):** qBittorrent, Deluge, Transmission, the arrs (Sonarr,
  Sonarr-Anime, Radarr, Radarr-4K, Lidarr, Prowlarr, Bazarr), LazyLibrarian,
  Apprise.
* **Outside (default):** Audiobookshelf (toggleable — see below) and every
  other serving/infra service.
* **Pinned inside, not toggleable:** FlareSolverr and Recyclarr. Both are
  reached by their consumers *inside* the namespace (Prowlarr → FlareSolverr;
  Recyclarr → the arrs on `localhost`), so moving them out would break those
  references. They are deliberately excluded from the toggle.

## The command

```
./mediastack.sh vpn                  # list toggle-enabled services + membership
./mediastack.sh vpn <service> on     # move it inside the VPN
./mediastack.sh vpn <service> off    # move it outside
./mediastack.sh up                   # apply
```

`vpn <service> on|off` records your choice in `.env` — writing `<SERVICE>_VPN`
only when it differs from the shipped default, and clearing it when it matches —
then regenerates the overlay immediately; `up` recreates the affected
containers. The listing shows, per service: **SHIPPED** (the stack default),
**CURRENT** (what is applied after `up`), and **YOUR SETTING** (your override,
or `—` when you are using the default). Values read `in` (inside the VPN
tunnel) or `out`.

### Torrent-client guard

qBittorrent, Deluge and Transmission refuse to leave the VPN without an
explicit acknowledgement — moving a torrent client out exposes its traffic on
your real IP:

```
./mediastack.sh vpn deluge off             # refused
./mediastack.sh vpn deluge off --i-know    # proceeds
```

## How it works

Toggle-enabled services carry `mediastack.vpntoggle: "true"` and are wired by
`vpn_gen`, not by hand. For each one it writes, into `local/vpn-overlay.yml`
(loaded automatically by every stack command, gitignored):

* **Inside:** `network_mode: "service:gluetun"` plus a gluetun health gate on
  the service; its host port and Traefik router are published on gluetun,
  which owns the shared namespace IP.
* **Outside:** its own `networks: [mediastack]`, host port, and Traefik router
  on the service itself.

Because the wiring is generated, the fragment of a toggle service carries no
`network_mode`, `networks`, `ports`, or Traefik router labels — only the
metadata the generator reads: `mediastack.port`, `mediastack.subdomain`,
`mediastack.vpn` (the default membership), and optionally
`mediastack.hostport`.

### Traefik-only services (`mediastack.hostport: "false"`)

Serving apps whose container port would collide on the host — Audiobookshelf
listens on `:80`, which Traefik owns — set `mediastack.hostport: "false"`.
The generator then publishes no host port in either state; Traefik still
reaches the service over the docker network. Acquisition apps omit the label
(default `"true"`) and keep direct host access.

Re-run `leak-test` after any change: it validates the live topology via
`docker inspect`, not the labels, so it catches a service that failed to move.
