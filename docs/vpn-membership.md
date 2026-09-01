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

### trash-sync joins the existing tunnel, never recreates it

Recyclarr shares gluetun's namespace (`network_mode: service:gluetun`) and
`depends_on` gluetun. It must therefore be invoked through the same compose
wrapper the rest of the stack uses (correct merged config, incl. the overlay
and pins) and with `--no-deps`, so it *joins* the already-healthy gluetun
rather than recreating it. A bare `docker compose run recyclarr` renders a
different config, treats gluetun as drifted, and recreates it mid-sync —
tearing down the namespace every VPN'd service is joined to.

### Fail-closed: the reattach guard

`network_mode: service:gluetun` is fail-*open* at recreate time — a dependent
recreated while gluetun has a new container ID lands nowhere useful and, worst
case, on a bridge with real egress. The stack closes this with a single guard,
`vpn_reattach_guard`, run at the end of both `up` and `update`. It enumerates
every `service:gluetun` dependent from the rendered config, checks each running
one's live `NetworkMode` against gluetun's current full ID, force-recreates any
that drifted, and fails loudly (with an ops notification) if a re-pin does not
take. A ghost gluetun therefore cannot survive a normal `up` or `update`:
either every dependent is joined to the live tunnel, or the command stops and
says why. Stopped dependents are left to `doctor`/`leak-test` on next start.

### Update cascades the gluetun group

When an update recreates gluetun (new image → new container ID), its
`service:gluetun` borrowers would be left on the dead ID unless they are
recreated too. `update` therefore detects gluetun in the target set and
force-recreates gluetun together with its enabled borrowers as one group, so
no borrower is ever orphaned in the first place — prevention, with no repair
window. `vpn_reattach_guard` still runs afterward as the catch-all for drift
that arrives by any other route (out-of-band `docker compose`, reboots,
manual container ops); the cascade only covers the update path's own recreate.

### doctor permissions: writability decides, ownership is tiered

doctor's config-permission audit asks two separate questions and no longer
conflates them. The definitive one — *can the app write its config?* — is
probed live inside the container at its real mount path (not assumed to be
`/config`; kavita, for instance, uses `/kavita/config`), and decides pass/fail.
Ownership drift is reported separately and tiered: mis-owned files in actual
config are a FAIL (`fix-perms` fixes them); mis-owned files confined to
regenerable paths (`cache`, `logs`, `backups`, `tmp`) are a WARN, because
images that ignore PUID and run as root write those as root through normal
background activity (update checks, log rotation, nightly backups) and it does
not threaten config integrity. Backup *health* (validity, recency) is audited
separately in the vpn+backups section, so treating backup-file *ownership* as
cosmetic here does not hide a broken backup.
