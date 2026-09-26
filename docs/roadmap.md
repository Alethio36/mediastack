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
  included; user additions live in `docker-compose.override.yml` and survive
  upgrades.
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
  server + worker + Postgres + Redis).
- **Anything shared across services gets its own shard.** Cross-cutting
  infrastructure — the edge proxy (Traefik), the VPN gateway (gluetun), the web
  front door — is shared by design, so it is neither folded into a consumer's
  shard nor duplicated per consumer; it stands alone in its own fragment.
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
- **Notification follow-ups.** A `notify` management verb
  (`test` a stream, re-runnable `set`, redacted `status`, `clear`) and a curated
  "new media available → `users`" event (the raw arr import firehose is too
  noisy to point at the household directly).

### Media monitoring
Answering "what happened to X?" after the fact. The nightly media manifest is
in place (docs/disaster-recovery.md); still to build:
- *Arr recycle bin via `wire`.* User-configurable: on/off,
  location (default `${DATA_ROOT}/recycle/<svc>/`, must share the media
  filesystem — an arr recycle is a move, cross-filesystem it becomes a full
  copy), retention days (default 7; upgrades keep the old file for the whole
  window, so 4K remux chains cost disk). Covers arr-initiated deletes only.
- *Deletion attribution via auditd (opt-in) — phases 1–2 of 3 landed.* The
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
  deletes are the manifest's to catch. Still open:
  - *Phase 3 — the manifest's "media removed" alert names who removed each
    folder,* from the durable log.
  - *Unproven live:* a watch loaded at boot onto an NFS automount that is not
    yet mounted (reboot a host with an NFS media root; doctor's live check
    catches it either way); SMB (doctor warns); ARM and the other 64-bit
    architectures (the calls come from `ausyscall`, never proven on a real
    one); and the parser's hand-built cases — hex-encoded names (any path with
    a space), a rename over an existing file, `log_format=RAW` — until a real
    capture of each replaces its line in `scripts/fixtures/audit-synthetic.raw`.

### Extensibility
- An easier path to add services *beyond* the built-in framework.

### Portability
- De-hardcode Debian; open up the OS assumptions.
- Podman support as an opt-in path (not the default — see the watchlist).
- Multi-arch / ARM as an explicit target.
- Rootless operation *(explore)* — folds together with the phase-2 sudo
  narrowing below into one "shrink the root surface" goal.

### Structure
- Revisit the folder structure for config files (the compose-shard model is now settled — see Architecture rules above).
- Formalize the `.env` config schema and validate it (it is the whole config
  surface; `doctor`-style checks for it).
- One host-footprint registry. Four features put files outside the repo —
  the web panel (sudoers, wrapper, user, units), the timers (units),
  `add-mount` (fstab, credentials) and `audit` (`AUDIT_FOOTPRINT`) — and
  each removes its own. Each should declare its paths in one list that
  `uninstall` and doctor's leftover check both loop over.

### Security & access
- **SSO in front of the panel** *(explore)* — Authelia or Keycloak. An optional
  but interesting area: it would let the panel move off LAN-open and gate the
  `credentials` verb, and it is a natural candidate for the whole stack's app
  logins, not just the panel. The identity options are evaluated in
  [watchlist.md](watchlist.md#identity--sso).
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
