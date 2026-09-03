# Mediastack — goals & roadmap

The project's north star, its forward direction, and services evaluated but
deferred. The direction is a **radar, not a mandate**: items marked *(explore)*
are pursued only if the appetite is real, and "lean scope" (below) is itself a
goal — new work must earn its place.

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

## Direction

Candidate directions, grouped by theme — where the project *could* go next, not
a committed plan.

### End-user experience
- Web panel polishing.
- Script polishing for the end user (clearer prompts, output, ergonomics).
- Extend `--dry-run` / what-if beyond `update` to `enable`/`disable`/`wire`/
  `vpn-apply`, so more operations are previewable before they apply.

### Extensibility
- An easier path to add services *beyond* the built-in framework.
- Rework `wire`: make it modular/pluggable (per-service wiring definitions)
  instead of one hardcoded list — easier to extend and reason about.

### Portability
- De-hardcode Debian; open up the OS assumptions.
- Podman support, alongside or instead of Docker.
- Multi-arch / ARM as an explicit target.
- Rootless operation *(explore)* — folds together with the phase-2 sudo
  narrowing below into one "shrink the root surface" goal.

### Structure
- Revisit the folder structure for config files (the compose-shard model is now settled — see Architecture rules above).
- Formalize the `.env` config schema and validate it (it is the whole config
  surface; `doctor`-style checks for it).

### Security & access
- **SSO in front of the panel** *(explore)* — Authelia or Keycloak. An optional
  but interesting area: it would let the panel move off LAN-open and gate the
  `credentials` verb, and it is a natural candidate for the whole stack's app
  logins, not just the panel.
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
- Expand CI/tests: a shellcheck gate, `docker compose config` validation across
  every fragment, and a render/`--dry-run` smoke test.
- First-class host-to-host migration (a `migrate` / export-import verb) — turns
  the manual cutover procedure into a validated command.

---

## Candidate services — evaluated, deferred

Services that were assessed for the stack and consciously *not* shipped
yet, with the reasoning, so the decision isn't re-litigated from scratch
later. Adding any of these is a `new-service` scaffold plus a fragment —
the notes here are about *whether*, not *how*.

Grouped by domain. Within each entry: what it is, why it's parked, what
adding it would look like, and the trigger to revisit.

## At a glance

| Candidate | Domain | Verdict | Held back by |
|---|---|---|---|
| Calibre-Web-Automated | Books | **Ship-worthy, radar** | Forks the books tree onto a Calibre `metadata.db` |
| Bindery | Books | Deferred | LazyLibrarian already fills the slot; Usenet-first |
| Kapowarr | Comics | Deferred | Off-model acquisition (scrapes GetComics, not Prowlarr) |
| Komga | Comics/manga | Deferred | Kavita chosen for breadth; Komga's edge is its API |
| ROMM | Games | Deferred, decision pending | First DB-backed service (MariaDB + Valkey) |
| **Pinchflat** | Video (YouTube) | **Ship-worthy [pick]** | Adversarial upstream; two house-rule exceptions |
| TubeArchivist | Video (YouTube) | Deferred | Heavy (Elasticsearch + Redis + app) |
| ytdl-sub | Video (YouTube) | Alternative | No UI — wrong for unknown end users |
| TubeSync | Video (YouTube) | Alternative | Pinchflat is lighter with more momentum |
| **authentik** | Identity/SSO | Deferred (post-migration) | 4-container DB stack; needs the `wire` rework |
| Authelia (+ file / + LLDAP) | Identity/SSO | Lighter alternative | Leanest; no enrolment UI |
| Kanidm | Identity/SSO | Lighter alternative | No built-in forward-auth (needs a proxy) |

---

# Books

## Calibre-Web-Automated (CWA) — book management + e-reader delivery

**What it is:** a hard fork of Calibre-Web that bolts the full Calibre
engine and heavy automation on top: watch-folder ingest with ~28-format
auto-conversion to EPUB, metadata fetch/enforcement (Google, Hardcover,
DNB…), duplicate detection, a web reader, OPDS, KOReader + Kobo sync, and
send-to-Kindle/Kobo email delivery. It is a *management + delivery* layer
over a Calibre library, not just a reader.

**Health: excellent** — one of the healthiest candidates here. ~5.8k
stars, single very active lead plus a broad contributor base, aggressive
release cadence, ships to GHCR as well as Docker Hub, has a real
`/health` endpoint, and a documented critical-security-fix discipline.
High open-issue/PR counts reflect volume of attention, not neglect. A
community fork (`Calibre-Web-NextGen`) exists to ship CWA's PR backlog
faster — a mild single-maintainer-bottleneck signal, but canonical is
clearly alive. Stay on canonical, pin a tag.

**Why deferred (a deliberate scope decision — radar, not roadmap):** it is *not* a drop-in
sidecar. CWA manages a **Calibre library** (`metadata.db` + Calibre's
Author/Title folder scheme), which is a different on-disk structure than
the flat `${DATA_ROOT}/media/{books,comics}` tree Kavita reads and
LazyLibrarian fills. Adopting CWA means adopting a Calibre-managed library
as the book source of truth — a *structural fork of the books vertical*,
not a bolt-on. That's the real cost, and the reason to sit on it.

Note it is **not** a ROMM-style DB problem: state is SQLite only
(`metadata.db` + CWA's `app.db`, both on the config bind), so it does not
reopen the database-aware-backup question. That's why it's safe to add
whenever the appetite exists, independent of the ROMM decision.

**What adding it would look like:**

* CWA owns management/conversion/delivery over a Calibre library; **Kavita
  demotes to reader-over-Calibre-library** (it can read one) and stays the
  comics/manga reader regardless. One source of truth: CWA writes it,
  Kavita reads it.
* **Wire LazyLibrarian's output into CWA's ingest folder** — LazyLibrarian
  keeps acquisition (Prowlarr-fed), drops the file, CWA converts/tags/
  files/delivers.
* **Never add CWA's downloader companion** (Shelfmark, ex cwa-book-
  downloader — maintenance-only since May 2026). LazyLibrarian owns
  acquisition; the companion would duplicate it.
* LAN-side with jellyfin/kavita, **not** behind gluetun (only outbound is
  metadata lookups). Pin the GHCR image tag per the deployed-tag rule;
  don't ride `latest`.

**Revisit when:** you want format conversion + e-reader delivery
(send-to-Kindle/Kobo, KOReader sync) — the genuine gap neither Kavita nor
LazyLibrarian covers — enough to accept a Calibre `metadata.db` as the
book source of truth. Until then, Kavita serves and LazyLibrarian acquires
over the flat tree.

## Bindery — book acquisition (Readarr replacement, modern)

**What it is:** the newest Readarr replacement; imports old Readarr DBs,
architected to survive metadata-provider outages (the actual thing that
killed Readarr).

**Why deferred:** young and **Usenet/SABnzbd-first**, where this stack is
torrent-first via qBittorrent. LazyLibrarian already fills the book-
acquisition slot and wires cleanly to Prowlarr.

**Revisit when:** Bindery matures, or if the stack ever gains a Usenet
path — at which point it may be the better book manager.

---

# Comics & manga

## Kapowarr — comic acquisition

**What it is:** a comic library manager in the *arr family, best-in-class
for automated comic collection.

**Why deferred (not rejected):** its acquisition model doesn't match the
rest of the stack. Kapowarr does **not** use Prowlarr/torznab indexers —
it scrapes GetComics directly and optionally pushes torrents to a client.
So unlike LazyLibrarian (a first-class Prowlarr app), it can't ride the
shared indexer flow; it's a standalone getter with its own source. It
also needs a user-supplied **ComicVine API key** for metadata.

**What adding it would look like:** optional profile, light wire — root
folder `/comics` mapped to `${DATA_ROOT}/media/comics`, a download temp
folder *outside* the root, qBittorrent as an optional torrent client, and
the ComicVine key entered in its UI. Kavita already *serves* comics, so
this is purely the acquisition half.

**Revisit when:** you actually want automated comic collection and are OK
with GetComics as the primary source. Until then, drop CBZ/CBR files into
`${DATA_ROOT}/media/comics` manually and Kavita serves them.

## Komga — comics/manga server (Kavita alternative)

**What it is:** comics/manga specialist with a rock-solid, well-documented
REST API and the best Mihon/Tachiyomi integration.

**Why deferred:** Kavita was chosen for breadth (ebooks + comics + manga +
light novels in one server). Komga's edge is its API, which matters for
*building automation against it* — not for serving and reading.

**Revisit when:** a concrete need to script against a comic server's API
appears. Komga and Kavita don't conflict (different ports, shared
storage) and can run side by side if that ever happens.

---

# Games

## ROMM — ROM library manager (game emulation)

**What it is:** best-in-class self-hosted ROM manager — IGDB metadata,
in-browser play (EmulatorJS), save-state and asset management, 80+
platforms, multi-user. On-brand for a gaming-adjacent deployment.

**Why deferred:** it's the first candidate that doesn't fit the stack's
single-container, cold-copy-the-config architecture. ROMM is a **three-
container application**: the app **+ MariaDB** (its real data store —
library, users, save associations) **+ Valkey/Redis** (sessions + scan
task queue). That brings three problems the current stack doesn't solve:

1. **Database-aware backup.** The backup model cold-copies config dirs; a
   live MariaDB cold-copies to a torn, useless database. ROMM's restore
   points would need a `mariadb-dump` before the copy.
2. **Startup ordering as a data dependency.** The app crash-loops if it
   starts before MariaDB has applied migrations — needs a DB healthcheck
   and `depends_on: service_healthy` gating (like gluetun, but for data).
3. **User-supplied IGDB key** from Twitch for metadata (same shape as
   ComicVine for Kapowarr) — setup, not a blocker.

**What adding it would look like — three options, decision pending:**

* **(a) Full integration** — ship ROMM + MariaDB + Valkey and teach
  `backup`/`doctor` to be database-aware (dump before restore points,
  health-gate the app on the DB). Correct and durable; touches the backup
  engine — the biggest change since the wave.
* **(b) Contained integration** — ship the 3-container unit, but ROMM's
  MariaDB dumps itself to `${CONFIG_ROOT}/romm/db-dump.sql` via a
  pre-backup hook, which then rides the normal cold-copy. Backup engine
  stays naive; the DB concern stays local to ROMM. Sets a clean pattern
  for any future DB-backed service. **Leaning option.**
* **(c) Keep deferred** until the appetite for a ROM manager is concrete.

**Revisit when:** you want game-library management enough to accept the
first database-backed service — then decide (a) vs (b). Kavita/Jellyfin
don't cover this; there's no manual stopgap beyond a plain file share.

---

# Video — YouTube archiving

The one candidate domain with an **adversarial upstream**: every tool here
wraps yt-dlp, so all inherit YouTube's active anti-bot arms race. Since
2024 the web client requires a **PO token** (proof-of-origin, generated by
YouTube's own BotGuard JS); without one yt-dlp silently loses high-quality
formats or hits "Sign in to confirm you're not a bot" — now one of the
most common failures. Expect periodic breakage. This is the only fragment
whose upstream is trying to break it; everything else talks to stable APIs.

**Two house-rule exceptions this domain forces — record them as decisions,
not surprises:**

1. **VPN asymmetry — must NOT route through gluetun.** Datacenter and VPN
   exit IPs are bot-flagged *harder*; the standard fix is a residential
   ISP connection. So YouTube archiving sits on residential LAN egress —
   the exact opposite of the torrent clients. Put a loud comment in the
   fragment so nobody "helpfully" VPNs it later.
2. **Pin-vs-freshness — breaks "verify against the deployed image tag."**
   Pinning the container staleness-freezes the bundled yt-dlp, which is
   exactly what breaks (a build more than a few weeks old often targets a
   client YouTube already killed). Needs an image that self-updates yt-dlp
   on start / tracks nightly. This fragment's reproducibility story is
   deliberately weaker than the rest of the stack, by necessity.

**Optional hardening (opt-in, off by default):** a bgutil PO-token-provider
sidecar (needs a Node.js runtime) for users who hit the bot wall; cookies
from a throwaway account is the lighter alternative.

**Jellyfin integration — two models:**

* **NFO-native** (Pinchflat, ytdl-sub): the tool writes `.nfo` + poster
  into a folder by your template; you add that folder as an ordinary
  Jellyfin library and Jellyfin's built-in NFO reader ingests it. No
  plugin, no API coupling; if the archiver dies, Jellyfin keeps serving
  what's on disk. Matches the stack's decoupled, on-disk-truth pattern.
* **Plugin-bridge** (TubeArchivist): the `tubearchivist-jf-plugin` talks to
  TA's API for metadata, thumbnails, and watch-progress sync-back. Richer,
  but couples Jellyfin's lifecycle to TA being up and reachable.

**Common fit:** new fragment, own stack UID + traefik router `youtube`,
output into a new `${DATA_ROOT}/media/youtube` subtree (provisioner grows
`media/` as it did for audiobooks/podcasts/comics/manga), one new Jellyfin
library. Ship Pinchflat first; defer the other three.

## Pinchflat — [pick]

**What it is:** Elixir, **single container, SQLite** (no external DB, so no
ROMM-style backup question). "Sonarr for YouTube": add a channel or
playlist as a source, set indexing frequency, cutoff days, and retention;
it downloads, names by your template, and writes NFO + poster. Low
resources, actively maintained, mature. NFO-native Jellyfin integration —
no plugin. Highest value for the lowest operational surface.

## TubeArchivist — heavier, richer

**What it is:** its own web UI + robust in-app search, plus watch-state
sync-back to Jellyfin via the jf-plugin. **Cost:** requires Elasticsearch
**+ Redis + app** — three stateful containers including a search engine,
significant RAM, and it reopens the DB-backup question. Still described as
the most actively supported YouTube-to-Jellyfin option despite periodic
"is it dead?" chatter.

**Revisit when:** in-app search and watch-state sync-back are worth the
Elasticsearch/Redis weight. For a lean public share, they aren't.

## ytdl-sub — config-as-code alternative

**What it is:** a pure config-driven yt-dlp wrapper — no DB, no UI —
generating native NFO for Jellyfin/Kodi/Plex/Emby with no extra plugins or
scrapers. Philosophically the closest match to this stack's single-
installer, config-driven, fail-loud ethos.

**Why not the pick:** no web UI, wrong for unknown end users on a public
share. Keep as the documented headless/power alternative.

## TubeSync — the other "Sonarr for YouTube"

**What it is:** Django-based channel/playlist sync with a built-in download
client, updates the media server on new media.

**Why not the pick:** fine, but Pinchflat has the lighter footprint and the
momentum.

---

# Identity & SSO

The stack has no single sign-on today — each app has its own login. SSO is a
Direction item (Security & access); this is the candidate landscape. Short
version: real pooled logins across the whole stack is achievable but **not
uniform** — apps split into three tiers (native OIDC / forward-auth gate /
LDAP), and Jellyfin's native clients are the constraint that shapes everything.

## authentik — full identity provider

**What it is:** a complete self-hosted IdP — OIDC, SAML, SCIM, an LDAP outpost,
and a forward-auth proxy, plus native user enrollment, groups/RBAC, and a
polished admin UI. The "does everything" option.

**Why it's a candidate:** the only option that delivers *both* halves of the
SSO goal at once — pooled logins **and** self-service enrollment (invite links,
self-registration, MFA enrolment, password recovery). Groups become the access
switches: enrol a user into a default `jellyfin-users` group, then grant more
services later by adding groups from the dashboard — no per-app provisioning.

**How the stack would attach (three tiers):**

- **OIDC apps** (Kavita, Audiobookshelf, Navidrome web) → native OIDC, gated by
  an authentik group policy. Real per-user SSO.
- **Forward-auth apps** (the *arrs, qBittorrent, Pi-hole) → a Traefik
  middleware gate. It's a *gate*, not per-user SSO — the arrs don't read
  identity headers. Each needs an explicit per-app `/api` bypass or the
  inter-service automation hangs (the fiddly, error-prone part).
- **Jellyfin** → the LDAP plugin against authentik's LDAP outpost. Works on
  *all* clients (native apps included) because Jellyfin mints its own session —
  but it's username/password, so authentik's MFA doesn't reach it (the
  JellyfinSecurity plugin can add 2FA / device-pairing back on top).
- **Jellyseerr** → stays on Sign-in-with-Jellyfin and rides the chain
  (Jellyseerr → Jellyfin → authentik). Its own OIDC is **preview-only**
  (`preview-new-oidc`, no auto account-linking), so not a stable path.

**Why deferred:** the biggest scope expansion discussed. It's a **4-container
DB-backed stack** (server + worker + PostgreSQL + Redis) — under the shard
rules, its own shard with its own DB, ~2 GB RAM floor, a migration-aware
`update`, and `pg_dump`-based `backup` (the same DB-backed pattern as ROMM
option (b)). And the integration *is* the **`wire` rework**: SSO wiring isn't
one action, it's per-service descriptors (OIDC vs forward-auth vs LDAP) —
exactly the pluggable-`wire` Direction item. Payoff worth naming: if `wire`
*generates* the per-app forward-auth bypass rules, it turns the single most
error-prone piece into regenerable config.

**Revisit when:** self-service enrollment for a real, changing user base is a
firm requirement *and* the `wire` rework + a DB-backed-service pattern are in
place. Post-migration. If enrolment isn't firm, a lighter option below wins.

## Lighter alternatives (same pooled-logins goal, less weight)

- **Authelia + file backend** — the leanest: one container, a YAML users file
  (< 50 MB), no DB, no directory. Forward-auth for admin UIs + its own OIDC
  provider for the good-citizen apps, and Jellyfin via `jellyfin-plugin-authelia`
  (native form → all clients, no MFA). No enrolment UI — add users by editing
  YAML. **The default if self-service isn't required.**
- **Kanidm** — the middle: one Rust container, native OIDC + LDAP-for-Jellyfin +
  some self-service, fully FOSS (MPL). Best philosophical fit for the project's
  lean / FOSS / safe / CLI-driven goals — *but* no built-in forward-auth, so
  admin-UI gating needs a small separate proxy (traefik-oidc-auth / oauth2-proxy).
- **LLDAP** — a tiny SQLite-backed LDAP directory with a web UI, if you want a
  real directory (groups, a management UI) behind Authelia without a full DC.
- **Samba4 AD** — already on the management plane; could be the shared user
  store (Authelia via LDAP + Jellyfin LDAP plugin), but it's the sledgehammer
  and couples the media stack's identity to the DC. Too heavy *for this
  project*; relevant only if identity is unified across the wider platform.
