# Mediastack — goals & roadmap

The project's north star, its standing rules, and its open work. The open work
is a **radar, not a mandate**: items marked *(explore)* are pursued only if the
appetite is real, and "lean scope" (below) is itself a goal — new work must
earn its place. Everything evaluated and *not* pursued (rejected tools, parked
features, deferred services) is in [watchlist.md](watchlist.md), each with the
condition that would reopen it.

## Project goals

- **FOSS-only, self-hosted, private.** Every component is open-source; nothing
  phones home; the stack runs entirely on operator-controlled hardware.
- **One script, one source of truth.** `mediastack.sh` is the only supported
  entry point — a finite set of validated, idempotent verbs. Operations go
  through it, never raw `docker compose` mid-session (that is the VPN safety
  boundary).
- **Modular by service.** One `compose.d/` fragment per service, explicitly
  included; user services live in `custom/compose.d/` (one file each) and
  changes to shipped ones in `custom/override.yml` — both survive upgrades.
- **Safe by construction.** VPN-gated, leak-tested torrent path; a front door
  that runs only allowlisted verbs; fail-loud over silent fallbacks; changes are
  health-gated and reversible (backup/restore, pinned images, rollback).
- **Lean scope.** Feature-complete for what it sets out to do; new services and
  features must earn their place against complexity and operational cost, not
  novelty.
- **Reproducible & recoverable.** Any box rebuilds from a restore point; every
  failure `doctor` reports states its own fix.

## Architecture rules

Standing decisions about how the stack is structured. Unlike the Direction
below, these are settled, not exploratory.

### Shards — the unit of isolation

The stack is organised into **shards**: one `compose.d/` fragment per shard.

- **A single-container service is its own shard.**
- **A multi-container service is a single shard** when every extra container
  exists *exclusively* to serve it — its own database, cache, or worker. These
  **private dependencies live inside the service's shard**, never in a shard of
  their own. One fragment holds the whole stack (e.g. an `authentik.yml` holding
  server + worker + Postgres + its LDAP outpost).
- **Anything shared across services gets its own shard.** Cross-cutting
  infrastructure — the edge proxy (Traefik), the VPN gateway (gluetun), the web
  front door — is shared by design, so it is neither folded into a consumer's
  shard nor duplicated per consumer; it stands alone in its own fragment.
- **Members run as the primary's UID and keep their data inside the primary's
  folders** (`CONFIG_ROOT/<primary>/…`), so ownership, `fix-perms` and backups —
  all keyed to the primary's folders — cover them unchanged. A member carries
  `mediastack.shard: <primary>` and no `mediastack.managed`, shares the
  primary's profile, and the primary `depends_on` it; CI checks every rule
  (`shard_problems`). Verbs that act on containers take the whole shard:
  update, restore, logs, disable, status, doctor.
- **The primary container owns the shard.** The `mediastack.managed` label, and
  the shard's identity in `status`, the dropdowns, and `enable`/`disable`, sit
  on the **primary** container. Private dependencies are members of the same
  shard with their health gated to the primary — the primary depends on them, so
  its health represents the whole shard; `status` reports the shard by its
  primary, not one row per container.

### No shared data tiers

A database — or cache, or similar stateful backend — is a **private dependency
by definition**, so each service or service-stack that needs one runs **its
own**, inside its own shard. Data tiers are **never shared** across services.
The marginal tidiness of a shared instance is not worth coupling independent
services' failure domains, upgrade cycles, and backup granularity — a shared
database's outage or bad migration would take down every service behind it. One
service, one shard, one database.

### Runtime & control plane — the deliberate choice

The stack is **Docker Compose driven by a single bash entry point**, and that is a
decision, not a default we haven't gotten around to revisiting. It is what makes
the project usable across its whole intended audience — from a newbie's first
self-host to a hardened veteran's box. The two invariants worth naming explicitly,
because they are what the old "one script" rule was really protecting:

- **One front door.** Operators drive the stack through `mediastack.sh` — a finite
  set of validated, idempotent, health-gated verbs. The *implementation* behind a
  verb is free to change; the guarded entry point is not. (This replaces the older,
  overloaded "one script" framing, which conflated the front door with an incidental
  "everything must be one bash file" preference. The front door is load-bearing; the
  single-file bit is not.)
- **One safety boundary.** The VPN leak boundary is inviolable: nothing may touch
  the container/network layer outside the guarded verbs, because raw
  `docker compose` mid-session is the one unguarded path that can drop the
  killswitch. `network_mode: "service:gluetun"` + a health-gated `depends_on` is the
  whole leak-proofing, and its legibility (one line a beginner can read) is a
  feature, not an accident.

**The rule for adopting any future tool or control surface:** it earns a place only
if it (a) reconciles its own domain natively — a real declarative diff of live
state, not a relocation of imperative logic — **and** (b) does not raise the floor
for the least-experienced user. A tool that fails either test is at most an opt-in
advanced path, never a dependency of the default install.

The tools assessed against this rule and rejected — Kubernetes, Ansible,
Terraform/OpenTofu, Podman as the default — are in
[watchlist.md](watchlist.md#runtime--tooling).

## Open work

Where the project goes next — decisions to make and work not yet built.

### Decisions pending
- **Ship Pinchflat?** YouTube archiving, rated ship-worthy; brings two
  house-rule exceptions (no VPN; a self-updating yt-dlp).
  Evaluation: [watchlist.md](watchlist.md#pinchflat--pick).
- **Ship Calibre-Web-Automated?** Rated ship-worthy; forks the books tree onto
  a Calibre `metadata.db`. Evaluation:
  [watchlist.md](watchlist.md#calibre-web-automated-cwa--book-management--e-reader-delivery).

### Storage layout — before migrate
To be discussed, not decided (tabled Sept 2026). Most users arrive with media
already spread over several drives or shares, while the stack assumes one
filesystem for DATA_ROOT (hardlinks, and now the recycle bin, need it):
- mergerfs pooling *in place* (a union over existing folders: nothing copied,
  per-drive top folders renamed to fit the layout, the apps' stored paths
  re-pointed — overlaps migrate's re-pathing), and a guided `add-pool` verb in
  the spirit of `add-mount`, including the create-policy setting hardlinks
  need.
- More than one library folder per media type (movies on two drives or two
  shares), and what that means for hardlinks, the recycle bin (today: one
  bin, refused per arr when its library is on another drive) and the manifest.

### End-user experience
- Web panel polishing.
- Script polishing for the end user (clearer prompts, output, ergonomics).
  - *`up`/`down` output is truncated on short terminals.*
    Compose's interactive progress view draws only as many rows as fit the
    terminal and folds the rest into "… N more", so a 29-container stack can
    hide services. Preferred fix: keep Compose's live view as progress, then
    print our own complete one-line-per-service result at the end (fits with
    a verdict-based wait, so the list shows health, not just "Started").
    Rejected: `--progress plain` — complete, but ~4 lines per container.
- Extend `--dry-run` / what-if to `enable`/`disable`/`vpn-apply`. (`update`,
  `wire` and `trash-sync` have it; `wire --verify` adds a non-zero exit on
  drift for scripts and cron.)
- **Richer notification layout** *(explore)*. Apprise can colour a message by
  its type, turn markdown headings into embed fields and attach an image, so
  Seerr's events could look closer to Seerr's own Discord embeds (poster,
  fields, colour per event) while still routing through the hub — check
  Apprise's Discord options against its docs first.

### Media monitoring
Answering "what happened to X?" after the fact: the nightly media manifest
(docs/disaster-recovery.md), the arr recycle bin and deletion attribution are
all built; what each still leaves open is noted below.
- *Arr recycle bin — built (Sept 2026).* On by default (existing installs too,
  with the warning), `RECYCLE_ENABLED` / `RECYCLE_ROOT` / `RECYCLE_DAYS`; set by
  `wire arr`, checked by doctor, its space watched nightly with the manifest
  (ops notified); mediastack never empties it. Follow-up, not built: the
  manifest's loss report could say a lost file is still in the recycle bin,
  and where.
- *Deletion attribution via auditd (opt-in) — built (phases 1–3).* The
  `audit` verb: `on` installs auditd (or joins one the host already runs,
  touching nothing of it) and loads the watch for the media root; `off`
  removes it (and auditd, if mediastack installed it); `status` and doctor
  check it with a live test delete; `report` reads the durable log, which an
  hourly timer copies out of auditd's rotating one (`BACKUP_ROOT/audit/`, kept
  `AUDIT_KEEP_DAYS`, gaps flagged and notified). Proven live on anzac3 (local
  disk, Sept 2026): operator and container deletes, a rename, a relative path,
  rules surviving a reboot; a container logs its own view of the path
  (`/data/media/x`), translated through that service's bind mounts. Earlier
  (anzac2's NFS mount): a `-F dir=` rule fires on an NFS client mount, and NFS
  refuses `renameat2` so callers retry with `renameat` — the rules keep
  successes only. Sees this host's syscalls only: NAS-side and other-host
  deletes are the manifest's to catch. The manifest's loss report, `manifest
  diff` and its ops alert name who removed each folder from the durable log
  (phase 3). Still open:
  - *Unproven live:* a watch loaded at boot onto an NFS automount that is not
    yet mounted (reboot a host with an NFS media root; doctor's live check
    catches it either way); SMB (doctor warns); ARM and the other 64-bit
    architectures (the calls come from `ausyscall`, never proven on a real
    one); and the parser's hand-built cases — `log_format=RAW`, a nested
    `rm -r` (a folder inside the folder being removed) — until a real capture
    of each replaces its lines in `scripts/fixtures/audit-synthetic.raw`. Hex
    names, a rename over an existing file and `rm -r` naming files only
    relative to their open folder are proven live (`audit2.raw`).

### Portability
- De-hardcode Debian; open up the OS assumptions.
- Podman support as an opt-in path (not the default — see the watchlist).
- Multi-arch / ARM as an explicit target.
- Rootless operation *(explore)* — folds together with the phase-2 sudo
  narrowing below into one "shrink the root surface" goal.

### Maybe
- JellySearch + Meilisearch as one shard *(to discuss)* — Meilisearch only serves
  JellySearch, but it is its own fragment today; merging changes existing
  installs' profiles.

### Security & access
- **Protect the unauthenticated UIs — before migrate, without SSO.** Apprise's
  UI and API have no login by design and hold the notification tokens; the panel
  runs stack commands. Until the gate exists (and for installs that choose
  Wizarr, which has none): Apprise not published over HTTPS and its port on
  127.0.0.1 only; the panel behind OliveTin's local-user login.
- **SSO: authentik** *(decided Sept 2026; part of the MVP — before migrate)* — reasoning and
  per-app evidence in [watchlist.md](watchlist.md#identity--sso). Build order:
  1. *Done:* shard support in the tooling (members, whole-shard verbs, CI rules).
  2. *Done:* `authentik.yml` — server, worker and its own PostgreSQL (pinned),
     secrets generated at the first `up` and refused if a database exists
     without them, the first admin created at first start (`credentials`),
     `portal.<domain>`, the API on 127.0.0.1 only. Upgrades walk its releases
     one at a time and never go back (`AUTHENTIK_RELEASES`; the release is
     recorded beside the database, so a restore point brings the right mark
     back). Backups are the existing cold restore points (the stack stops; a
     stopped PostgreSQL copies consistently). The account model is either/or,
     declared by `mediastack.conflicts`: `enable` refuses the second,
     `configure` asks which one, doctor fails both enabled.
  3. *Done:* the portal's setup as a blueprint (`blueprints/authentik/`,
     applied by the worker from a copy `up` keeps current): groups `media-users`
     and `admins`, sign-up by invitation only (username, password, name, email —
     all required) creating *internal* non-admin users in `media-users`, the
     portal's name (`PORTAL_TITLE`, asked by `configure`), a "Getting started"
     dashboard card. `wire authentik` sets the base URL; `invite` mints a
     single-use link (7 days; `--expires 1|7|30`). The LDAP outpost comes with
     Jellyfin (5).
  4. The gate. *Milestone 1 done:* `mediastack.auth: gate | native | open` on
     every web interface (CI: declared, and the gate middleware on exactly the
     gated routes); Traefik's `mediastack-gate` middleware asks authentik's
     built-in outpost when authentik runs and is a no-op without it; one
     domain-wide forward-auth provider ("Admin tools") lets `admins` through;
     `wire authentik` attaches it to the outpost (added, never replacing), puts
     akadmin in `admins` once, and keeps an admins-only dashboard card per gated
     tool. Gated so far: the panel and Apprise. *Milestone 2:* the arrs and the
     other admin tools (each tool's trust setting verified against its docs).
  5. Per app: Jellyfin LDAP, Audiobookshelf/Kavita/ErsatzTV OIDC, Seerr through
     Jellyfin, Navidrome header + its own password for music apps, the panel via
     OAuth2 with group permissions, Apprise and the arrs behind the gate.
  6. Converting an existing install's users (Jellyfin local users to directory
     users, keeping watch history; Audiobookshelf/Kavita match by username) —
     test the Jellyfin LDAP takeover of an existing user first.
  First milestone: the gate in front of the panel and Apprise.
- **Harden the gate** *(later — accepted risk for now)*: gated tools keep their
  host ports open to the LAN, so the gate protects their domain address only —
  anyone on the LAN can still reach them by IP and port. Binding those ports to
  127.0.0.1 closes that; it is also what lets a gated tool's own login be
  switched to "trust the gate" (until then a gated tool that has its own login
  asks twice through the domain: the portal, then its own).
- **Wizarr mode: Apprise and the panel** *(review later — accepted risk for
  now)*: without authentik there is no gate, and both have no login of their
  own; they stay LAN-open as before.
- **Access per tool** *(look into later)*: today there are two levels — `admins`
  (every admin tool) and the household front end (`media-users`). Finer rules
  (one person gets Sonarr but not qBittorrent) would be one application and
  binding per tool instead of the one domain-wide rule.
- **Email server for authentik** *(later)* — the standard for what email is
  used for: (1) a user resets their own forgotten password, (2) `invite` can
  e-mail the link, (3) authentik's own update notices reach its admins. Nothing
  else (no marketing, no digests). Email is already required at sign-up, so
  every account is ready for it. Until then invite links are copied by hand and
  passwords are reset by the admin.
- Post-migration hardening: move the panel off LAN-open once SSO lands; phase-2
  sudo narrowing (read-only verbs drop root); staging→production certs once a box
  stops being a test box.
- Secrets handling *(explore)* — Docker secrets or an external store instead of
  plaintext `.env`.

### Project health
- **Optimization & project-health pass.** The build phase prioritized capability
  over refinement. A deliberate sweep: audit `mediastack.sh` for dead code,
  redundant logic, and oversized functions; confirm every verb still earns its
  place; tighten style and error-handling consistency; find lean-ness wins
  (fewer moving parts, faster common paths); verify docs match behavior; re-check
  the whole against the goals above. A lean-and-correct sweep, not a rewrite.
- **A `--dry-run` smoke test in CI.** The rest of the suite is in place: each
  `scripts/test-*.sh` / `check-*.sh` states in its header what it pins, and the
  lint workflow runs them all.
- First-class migration (a `migrate` verb) — turns the manual cutover
  procedure into a validated command. The source is either a local path (old
  stack on the same machine) or a remote host over SSH (`--from host:/path`);
  the steps after the copy are identical. It copies app configs cold (source
  apps stopped — live SQLite copies corrupt), maps old config folders to
  `CONFIG_ROOT/<service>`, keeps database-stored paths valid (bind-mount
  reshaping over database surgery), hands files to each service's own user,
  and lets `wire` adopt the result. First run: against a fresh install.
