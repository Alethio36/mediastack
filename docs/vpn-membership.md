# VPN membership — moving services in or out

Which services run inside the VPN is an operator choice, changed with the
`vpn` command. No fragment editing and no compose overrides: membership is
generated into `local/vpn-overlay.yml` and applied on the next `up`. Your
own services get the same treatment: `new-service` writes them on the
toggle model, so `vpn <name> on|off` works for them from day one. (Removing
one of yours: delete its block, then `up` — the overlay is regenerated
before anything renders; see docs/adding-a-service.md.)

Two views show membership: `./mediastack.sh vpn` (this listing, with the
recommended setting per service) and `./mediastack.sh status` (its `VPN`
column reads `on`/`off`, `self` for gluetun itself, and marks a service moved
off its recommendation with `*`). `leak-test` audits the live result.

## Defaults

The acquisition chain runs inside gluetun; the serving chain does not.

* **Inside (default):** qBittorrent, Deluge, Transmission, the arrs (Sonarr,
  Sonarr-Anime, Radarr, Radarr-4K, Lidarr, Prowlarr, Bazarr), LazyLibrarian.
* **Outside (default):** Apprise and Audiobookshelf (both toggleable — see
  below) and every other serving/infra service.

Apprise sits outside on purpose (inside until schema 32). Inside, an alert
that the tunnel is down needed the tunnel; a degraded tunnel made deliveries
fail although they arrived (duplicates, apps switching their notifications
off); and posting through the tunnel tied the address your downloads use to
your notification account. The tunnel never hid what a notification says —
the service you notify reads it either way; for that, point the `ops` stream
at an endpoint you host yourself. `vpn apprise on` moves it back in.
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
  which owns the shared namespace IP — and gluetun's resolv.conf (no host
  search domain).
* **Outside:** its own `networks: [mediastack]`, `dns_search: ["."]` (no host
  search domain), host port, and Traefik router on the service itself.

### Other apps follow the move

Moving a service changes how the rest of the stack reaches it. The rule
(proven live): a service behind the VPN is reached as `gluetun:<port>`, one
outside it by its own name, `<service>:<port>` — from any caller, on either
side. Only the *target's* side matters, so moving a service means re-pointing
the apps that call it, never the other way round.

That happens by itself: `vpn` marks the service (only when its side really
changes), and the next `up` re-runs the `wire` steps that write its address —
`WIRE_CALLERS` in `lib/addr.sh` lists who calls whom. For example,
moving apprise re-points the arrs', Prowlarr's, cleanuparr's and seerr's
notifications. Only addresses mediastack wrote are changed; one you set by hand
is reported and left alone. If a re-point fails, the mark stays: the next `up`
retries, and `doctor` shows "re-pointing pending" until it succeeds.
`wire --verify` reports any address that is out of date.

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
applying, that every rendered `service:gluetun` dependent sits in the *live*
gluetun's network namespace. Any that don't are force-recreated in
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
one's live `NetworkMode` against gluetun's current full ID **and** its network
namespace against gluetun's (`/proc/<pid>/ns/net`), force-recreates any that
drifted, and fails loudly (with an ops notification) if a re-pin does not
take. The ID alone is not enough: a gluetun restarted in place — Docker
restarting it after a crash, a `docker restart` — keeps its ID but builds a
new namespace, and its dependents stay in the old one with no network at all
(found live, Nov 2026; fail-safe, but downloads stop silently). A ghost
gluetun therefore cannot survive a normal `up` or `update`: either every
dependent is in the live tunnel's namespace, or the command stops and says
why. Stopped dependents are left to `doctor`/`leak-test` on next start.

### The leak gate

The VPN group — every enabled service in gluetun's namespace — runs only once
gluetun is proven (`services/gluetun/gate.sh`):

- **`up` starts in two phases** (and `enable` ends with `up`, so a service
  turned on later goes the same way): everything outside the group (gluetun with
  it), then a full `leak-test`, then the group. A FAIL leaves the group
  stopped and ends `up`; UNPROVEN (a third party down, say) starts it with a
  warning.
- **A FAIL stops the group, whoever ran the test** — `up`, you, the panel:
  gluetun stays up for inspection, and the stop is remembered in
  `local/state/leak-gate`. While it holds, nothing starts a member of the
  group: every compose start of one (or of the whole stack) is refused with
  the reason, and only `up` — after its own leak-test passes — opens it again.
- **Ops hears each change of verdict once:** a leak, a check that could not be
  proven, and the recovery — not the same news every run.
- The services that call the group (Cleanuparr, Seerr, Bazarr) keep running
  and log errors while it is stopped; nothing else is stopped.
- **Docker never starts the group:** its members carry `restart: "no"`
  (vpn_gen's overlay), so a boot or a Docker restart brings back gluetun and
  everything else, and the boot guard starts the group through the gate. A
  backup starts what it stopped the same way: the group last, through the gate.
- **The 5-minute check supervises it** (`vpn-watch`, `mediastack-leakcheck.timer`):
  `leak-test --local`, and any enabled member that is not running — crashed,
  or a boot that came too early — is started through the gate. To keep one
  stopped, `disable` it or `down` the stack; a `docker stop` is undone.
- **The full run comes hourly** (`vpn-watch --full`, `mediastack-leaktest.timer`,
  at a random minute): who the internet sees, whatever gluetun's proof. The
  record of this host's own address it compares against is refreshed once a
  day at a random time (`host-identity`), never in the same run.
- **How much proof a start needs follows gluetun:** a full run that finds no
  leak records which gluetun it proved (its container and start time). Until
  gluetun restarts, the local checks are enough before a member starts; after
  a restart (a crash, a backup, a boot) the full run comes first.
- **A deliberate stop of gluetun forgets what the host tracked from its
  address** (all of it from before the stop), so the gate after a nightly
  backup does not wait out old tunnel sessions.

### Update goes through the gate

`update` checks whether gluetun itself will be recreated — a new image, or a
config whose compose hash differs from the running container's
(`gluetun_recreates`); being in the target list is not enough (every full
update lists gluetun, and until Oct 2026 the whole group bounced every night).
Anything it cannot read counts as a change.

- **gluetun changed:** it is stopped (what the host tracked from its address
  is forgotten), recreated with the other non-VPN targets, proven by the full
  leak-test, and only then does the whole VPN group re-join it — the members
  sat in its old namespace, with no network, meanwhile. On a new gluetun
  *image*, the kill-switch proof (`leak-test --killswitch`'s disruptive
  checks) runs after the health gate, the same night.
- **gluetun unchanged:** the local checks run before the group's targets are
  recreated (gluetun was proven by the restore point's restart).
- **A FAIL** stops the group (the gate tells ops), and the update fails.
- **While the gate is closed** `update` refuses before anything is touched:
  `up` re-proves gluetun first.

After the tunnel restarts, gluetun reports healthy before its DNS serves.
`trash-sync` therefore waits until HTTPS by name works through the tunnel
twice in a row (`vpn_egress_ready`, up to 2 minutes) before starting
recyclarr — a failed fetch makes recyclarr delete its guide copy. `vpn_reattach_guard` still runs afterward as the catch-all for drift
that arrives by any other route (out-of-band `docker compose`, reboots,
manual container ops); the cascade only covers the update path's own recreate.

### doctor permissions: writability decides, ownership is tiered

doctor's config-permission audit asks two separate questions and no longer
conflates them. The definitive one — *can the app write its config?* — is
probed live inside the container at its real mount path (not assumed to be
`/config`; kavita, for instance, uses `/kavita/config`), and decides pass/fail.
Ownership drift is reported separately and tiered: mis-owned files in actual
config are a FAIL (`fix-perms` fixes them); mis-owned files confined to
regenerable paths (`cache`, `logs`, `backups`, `tmp`) are a WARN — they do not
threaten config integrity, but they mean something wrote as the wrong user.
The usual culprit is an image that ignores PUID and runs as root; that is not
excused as normal: the runtime audit FAILs any service whose processes don't
run as its `<SVC>_UID` (the fix is `user:` in the fragment — see
docs/adding-a-service.md). Backup *health* (validity, recency) is audited
separately in the vpn+backups section, so treating backup-file *ownership* as
cosmetic here does not hide a broken backup.

### Boot/daemon guard (systemd)

vpn_reattach_guard only runs when the script runs, so a reboot or
`systemctl restart docker` — which brings containers back by restart-policy
without the script — could leave borrowers on a recreated gluetun's dead
namespace with nothing to catch it. A oneshot unit,
`mediastack-vpnguard.service` (After/Requires=docker.service,
WantedBy=multi-user.target), runs `mediastack.sh vpn-guard --boot` on every
boot and docker restart. It waits (bounded) for gluetun to become healthy
first — at boot, containers start asynchronously, so checking too early would
race the startup it guards — then runs the same reattach guard. It does NOT
cover a raw `docker compose up` while the system is already running (only
script paths and daemon/boot events). The unit is installed unconditionally
and idempotently by every `cmd_up` (a removed unit reappears on next `up`), and
both uninstall paths remove it.
