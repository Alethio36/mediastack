# VPN membership — moving services in or out

Which services run inside the VPN is an operator choice, changed with the
`vpn` command. No fragment editing and no compose overrides: membership is
generated into `local/vpn-overlay.yml` and applied on the next `up`.

Two views show membership: `./mediastack.sh vpn` (this listing, with the
recommended setting per service) and `./mediastack.sh status` (its `VPN`
column reads `on`/`off`, `self` for gluetun itself, and marks a service moved
off its recommendation with `*`). `leak-test` audits the live result.

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
only when it differs from the recommended setting, and clearing it when it
matches — then regenerates the overlay immediately; `up` recreates the affected
containers. The listing shows, per service, **VPN** (what it is set to now) and
**RECOMMENDED** (the maintainer's suggested setting), each `on` (inside the VPN
tunnel) or `off`; a service you have changed away from the recommendation is
flagged in the row.

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

### The update pipeline guards the attachment

Recreating gluetun gives it a new container ID, and compose does **not**
recreate `network_mode` dependents whose own config is unchanged — they stay
joined to the dead namespace and silently lose egress (health checks keep
passing; the apps run fine offline). `update` therefore verifies, after
applying, that every rendered `service:gluetun` dependent is joined to the
*live* gluetun by full container ID. Any that aren't are force-recreated in
the same run; if a dependent still isn't joined afterwards, the update fails
loudly and notifies. Stopped containers are left alone — they are caught by
`doctor`/`leak-test` when started.
