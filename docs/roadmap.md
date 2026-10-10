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
- **Modular by service.** One folder per service under `services/` (its fragment, `compose.yml`), explicitly
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

The stack is organised into **shards**: one `services/<name>/` folder per shard (its fragment, `compose.yml`).

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

### Next: the pre-alpha rollout
The MVP queue is built (auditd, the arr recycle bin, structure, `.env`
validation, notifications, SSO). Before `migrate` moves the first household:
1. *Done:* `wire` finishes a fresh install in one run: `authentik` ahead of
   `jellyfin` in the role order (Jellyfin's portal sign-in needs the LDAP
   token), and `wire authentik` waits up to five minutes for the blueprint to
   be discovered after authentik's first start — a timeout is a wire failure,
   not a skip. To prove on the rebuild (3).
2. *Done:* the account model stays the user's choice — none, Wizarr or
   authentik: `configure` asks it on its own, whatever the preset (before,
   "standard" chose none silently and "everything" hit a generic either/or
   prompt with no "neither"); leaving the portal warns first. Without a
   portal, every verb that needs one refuses with a way forward (read in
   code; to prove on the rebuild).
3. testhost rebuilt from zero: install, configure, snapshot, then a close look
   at installing and everyday use. Watch there whether the household's files
   direct-play; frequent transcodes would pull the transcoding evaluation
   forward.
4. A restore drill — a disaster test: `backup`, `restore --service
   authentik`, `restore --all`, the portal's database, Kavita and
   Audiobookshelf included.
5. The README as a chapter-style tutorial for every technical level, and a
   small built-in page with local how-tos and a household quick-start.
6. Then `migrate` (below, under Project health).
Lower priority: RAM and system requirements, measured on the rebuilt box.

### Organised by service — phases 1–2 done (Oct 2026), phase 3 decided later
One folder per service, `services/<name>/`: its fragment (`compose.yml`),
its code (`<name>.sh`, more files by topic where it has more to say), its
settings' schema rows (`env.tsv`), its role templates (`provides/`) and
anything else it ships (authentik's blueprints). Adding a service means
adding a folder, plus its lines in `.env.example` and a word in each verb
list it joins.
1. *Done:* fragments, blueprints and every app's wire code moved in as a pure
   move (rendered config byte-identical; the same functions and globals).
2. *Done:* each verb's per-app code moved into the folders — credentials,
   doctor's app checks, link-account, update's probes, configure's secrets —
   with each verb keeping an explicit, ordered list of the services it covers
   (`WIRE_ROLES`, the set-credentials targets, `DOCTOR_APPS`;
   `scripts/check-registries.sh` holds the lists to the functions). Download
   clients became the first role (`lib/roles.sh`): qBittorrent, Deluge and
   Transmission, one chosen by `DOWNLOAD_CLIENT`. Each service's schema rows
   moved to its `env.tsv`.
   Decided against: a hook-dispatch framework (explicit lists instead), roles
   with a single provider (arr servers, the media server, the hub — a role
   when a second provider exists), and splitting `.env.example`.
3. Later, if it pays: platform features with interchangeable providers
   (sign-in: authentik | Wizarr | none; edge: Traefik | NPM; the VPN) out of
   `lib/`.

Guardrails in place: a template holds data and placeholders only;
`scripts/test-roles.sh` fails an unknown role, consumer or placeholder, a
provider missing a consumer's template, and a setting whose allowed values
drift from the providers.

### Release channels — decided (Sept 2026)
`stable` is the default branch (what a clone gets and end users run),
`unstable` gets every change first (the test box runs it), `legacy` is the old
project, frozen. Promotion is a fast-forward once a change is proven and CI
is green on it: `scripts/promote.sh` waits for the checks on `unstable`'s
tip, refuses on any red one, then fast-forwards `stable` and pushes.
`upgrade` follows the checked-out branch.

### Versions from the repo — direction agreed (Oct 2026), not scheduled
Today the image an install runs is whatever its upstream tag points at the
night it updates (26 of 28 images float; on 6 Oct a Jellyfin minor and a
PostgreSQL patch landed unattended). The direction: **git is the source of
truth for versions.** Every install on a commit runs byte-identical images,
and only versions the repo owner promoted reach `stable` — updates still
arrive on their own, as with watchtower, but validated first.
- **Digest pins in the fragments** — `image: <repo>:<tag>@sha256:<digest>`,
  every image, shard members included (a database bump becomes a visible
  commit). Versioned tags wherever upstream publishes them; `latest`-only
  images get digest pins. `local/pins.yml` (rollback) still layers on top.
- **Renovate edits the lines** — the FOSS CLI in the repo's own GitHub Actions
  (token: a GitHub App scoped to this repo), weekly. Minor/patch/digest bumps
  as one group, auto-merged into `unstable` once CI is green (branch automerge:
  history stays linear); majors and authentik wait for the owner; PostgreSQL
  and Recyclarr majors frozen; lsio tags need a versioning rule. Its config
  is read from the default branch (`stable`), so config changes take effect on
  promotion. The Dependency Dashboard issue is the view of what upstream has.
- **The canary validates** — testhost follows `unstable` nightly; a bump that
  breaks it is never promoted.
- **Every commit that changes a pin is a release** — `promote.sh` tags each
  one in the range, not just the tip.
- **`upgrade` walks the releases in order** (fast-forward to each tag, hand
  over to that release's script, apply the services whose pin changed, gate,
  next). Installs replay the channel's history, not upstream's: every version
  the channel shipped runs, in order; a jump the channel took is taken.
  Stepping every upstream release was rejected — it would run versions
  upstream pulled for bugs. A stale install walks every hop (print hops and
  download size first; doctor warns when it is ~8+ releases behind); a failed
  hop halts on the last good one, undo is `restore --all` to the pre-walk
  point. authentik keeps `authentik_step` as the runtime net.
- **Installs follow their channel nightly** — the update timer runs the walk;
  `UPDATE_CHANNEL=manual` opts out.
- **Signed releases** *(second phase)* — auto-follow means whoever can push
  `stable` gets root on every install (the timers run the tree as root), so
  `promote.sh` signs and `upgrade` verifies against a key pinned in `local/` at
  install, never one read from the repo. Costs: key management, a rotation
  procedure.
- **Jellyfin plugins the same way** *(third phase)* — a tracked lock (plugin,
  version, checksum) bumped in the same commit as the server; `wire` installs
  exactly those, doctor reports drift, plugins a user added stay theirs. A
  third-party repo can prune a locked version: install fails loud.
- **Costs** — the owner reviews majors and promotes; security fixes arrive at
  that cadence (state it in the README); if promotion stops, installs freeze.
  Estimated ~300 lines with tests for pins, Renovate, tags and the walk.

### Decisions pending
- **Ship Pinchflat?** YouTube archiving, rated ship-worthy; brings two
  house-rule exceptions (no VPN; a self-updating yt-dlp).
  Evaluation: [watchlist.md](watchlist.md#pinchflat--pick).
- **Ship Calibre-Web-Automated?** Rated ship-worthy; forks the books tree onto
  a Calibre `metadata.db`. Evaluation:
  [watchlist.md](watchlist.md#calibre-web-automated-cwa--book-management--e-reader-delivery).
- **Ship Whisparr?** *(to evaluate)* The arr for adult content, from the
  Sonarr/Radarr family: it fits the arr pattern (VPN toggle, Prowlarr sync, a
  download-client category, the recycle bin, `wire`). To weigh: its own media
  root and Jellyfin library, and above all who in the household can see it —
  check whether people signing in through the portal get every library by
  default, and keep it to the users it is meant for; Prowlarr indexer
  coverage; which Whisparr line to track (it has had more than one). Decide
  in the watchlist before shipping.
- **A transcoding tool** *(to evaluate)*: re-encode media ahead of time
  (smaller files, formats every client plays, fewer live transcodes in
  Jellyfin). Candidates: HandBrake (manual, per file, web GUI), Tdarr
  (library-wide rules, automated, can spread work over machines), Unmanic
  (simpler automation). Hidden costs to weigh: sustained CPU/GPU load, disk
  churn and temporary space, and the arrs noticing replaced files (re-import,
  upgrade loops). Decide in the watchlist before shipping. After the MVP,
  unless the rollout shows the household's files seldom direct-play.

### Storage layout — decided (Sept 2026), after the MVP
- **No mergerfs in the tooling** — pooling drives is a host storage decision,
  beyond this project. The stack already works on top of a pool the user sets
  up themselves (`DATA_ROOT` pointed at it); the README may later say which
  two settings matter (a non-path-preserving create policy for hardlinks,
  `cache.files=partial` for qBittorrent).
- **More than one library folder per media type, across the board** — the
  arrs' root folders, Jellyfin's libraries, Kavita, Audiobookshelf and
  Navidrome each take several folders (e.g. movies on two drives). An import
  onto a different drive than the download is a copy, not a hardlink: accepted.
  To work out with it: the recycle bin (today one bin, refused per arr when its
  library is on another drive), the manifest and deletion auditing (every
  folder, not just `DATA_ROOT/media`), and doctor's space checks per drive.
  Not needed for the first migration (that household matches oldhost's single
  data root), so it comes after the MVP.

### End-user experience
- **Password reset by email** *(after email, Oct 2026)*: with SMTP set
  (docs/email.md), a "forgot password?" link on the portal's sign-in — a
  recovery flow (identify, email a link, set a new password) bound to the
  brand only when email works, so a portal without it never shows a dead
  link. Until then `reset-password` mints the link for an admin to send.
  Ship mediastack's own email template with it (authentik reads
  `CONFIG_ROOT/authentik/templates`): authentik's built-in one references its
  logo as an inline `cid:logo` image that Gmail shows as a broken image plus
  an attachment (seen on the first test mail, Oct 2026) — the template
  comes from the household's branding below.
- **Personalization: the household's own look, everywhere** *(direction, Oct
  2026)*. Today one setting reaches people: `PORTAL_TITLE` (the portal's
  name, its sign-up page, the app cards). The direction is one branding kit
  the household fills once, which `wire` carries into every app that can
  take it and `doctor` checks:
  * **The kit:** the name (`PORTAL_TITLE`), a logo, a small icon (favicon),
    a background picture, an accent colour, and a welcome line — files in a
    `custom/branding/` folder (the household's own, never overwritten), with
    the shipped defaults when a file is absent.
  * **The portal (authentik):** its brand takes the name, logo, icon and the
    sign-in background; its emails (password reset, invitations) use a
    mediastack template carrying the name and a logo the portal itself
    serves — a linked image, not an inline attachment (see above).
  * **Each app, as far as it allows:** to survey per app before building —
    what Jellyfin's branding settings take (login message, custom styling,
    its splash screen), Seerr's title and logo, Kavita's, Audiobookshelf's,
    Navidrome's, the web panel's (OliveTin) — and what only a custom
    stylesheet can reach. An app that takes none is listed, not forced.
  * **Media of the household's own:** pictures for the sign-in page, the
    built-in quick-start page (Next, step 5) in the same look, and a
    welcome note for new people.
  Constraints: images are checked (type, size) before any app gets them;
  every value `wire` set is re-applied only while it is still the one
  mediastack wrote (a change made in an app's own settings is left alone,
  as the base URL is today); nothing is required — an empty kit is today's
  look.
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
  `AUDIT_KEEP_DAYS`, gaps flagged and notified). Proven live on testhost (local
  disk, Sept 2026): operator and container deletes, a rename, a relative path,
  rules surviving a reboot; a container logs its own view of the path
  (`/data/media/x`), translated through that service's bind mounts. Earlier
  (oldhost's NFS mount): a `-F dir=` rule fires on an NFS client mount, and NFS
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
- **Traefik without the Docker socket** *(recommended, Oct 2026 — after the
  rollout, before a household relies on the Internet-facing edge)*. Traefik
  mounts `/var/run/docker.sock:ro` to read routes from labels; `:ro` covers
  the socket file, not the API, so Traefik holds the whole Docker API — root
  on the host — and it is the one container the Internet reaches.
  * *A socket proxy* (the usual answer: a filtered API allowing list,
    inspect, events) narrows it but leaves a hole: Traefik's Docker provider
    *inspects* containers, and an inspect returns every container's
    environment — most of the stack's secrets. Root becomes "every secret in
    `.env`", plus one more container to keep.
  * *The recommendation: no socket at all.* Traefik's file provider is
    already on (`/dynamic`); mediastack already renders every label
    (`RENDERED_JSON`, drop-ins included) and knows every address (`svc_addr`,
    `gluetun:<port>` for VPN'd services). A generator turns the `traefik.*`
    labels into route files on every `up`/`enable`/`disable`/VPN toggle — as
    the VPN overlay is regenerated today — and the Docker provider and the
    mount go. A Traefik compromise then reaches Traefik only.
  * Costs: the generator (~100-150 lines + tests; label semantics translated
    exactly, the gate middleware included); a stopped service's route stays
    and answers 502 instead of vanishing; a route only appears through
    mediastack (no labels added by hand at runtime).
- **Container DNS: no host search domain** — *decided (7 Oct 2026), shipped*.
  Docker copies the host's search domain into every container, so a bare
  sibling name looked up while that sibling is off the network falls through
  to the LAN resolver, and a wildcard record there (a `*.<domain>` front door
  is the common case) answers with a public address. Seen live twice: the
  LDAP outpost dialed Cloudflare for 4.5 minutes (1 Oct 2026), and the
  authentik server got a Cloudflare IPv6 address for its database while an
  update recreated it (6 Oct 2026). gluetun keeps the search line when it
  rewrites the nameserver, so the VPN group had it too. Every shipped service
  now runs with `dns_search: ["."]` (fragments, vpn_gen's off-VPN stanza,
  gluetun for the VPN group); test-render enforces it. The cost, accepted: a
  short LAN name typed into an app (an SMTP relay, a NAS) must be written in
  full or as an address.
- **Protect the unauthenticated UIs — before migrate, without SSO.** Apprise's
  UI and API have no login by design and hold the notification tokens; the panel
  runs stack commands. Until the gate exists (and for installs that choose
  Wizarr, which has none): Apprise not published over HTTPS and its port on
  127.0.0.1 only; the panel behind OliveTin's local-user login.
- **SSO: authentik** *(decided Sept 2026; built and proven live Sept 2026)* — reasoning and
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
  3. *Done:* the portal's setup as a blueprint (`services/authentik/blueprints/`,
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
     tool. *Milestone 2 done:* every admin tool gated (the arrs, Prowlarr, Bazarr,
     the download clients, LazyLibrarian, Cleanuparr, WatchState, Pi-hole,
     Traefik's dashboard). With the portal on, their host ports listen on
     127.0.0.1 only (`MEDIASTACK_GATE_BIND`); an arr (and Prowlarr) then trusts the portal
     (`External`) — only once it is gated and unreachable by IP — and its `/api`
     skips the gate for companion apps (the API still demands its key;
     `mediastack.auth.bypass`). Disabling authentik restores and *verifies* each
     arr's own login before the ports reopen. Still their own login behind the
     gate (two logins): qBittorrent (its only bypass also opens its API),
     Pi-hole (one password for UI and API), and the rest until each is checked.
  5. Per app. *Done:* household cards (Media, for `media-users` and `admins`)
     for every `mediastack.user_facing` app; ErsatzTV behind the admin gate (its
     UI is for building channels; households watch through Jellyfin); Navidrome
     behind a *household* gate (`mediastack.auth.group: media-users` — its own
     forward-auth rule for its one address), told who the user is by the portal
     (`ExtAuth`, trusting only Traefik, which now has a fixed address on a fixed
     network range), with `/rest/` (music apps: a password each user sets once
     in Navidrome) and `/share/` past the gate — and every route past any gate
     strips the portal's headers, so no client can name itself a user. *Done
     (LDAP, part 1):* the LDAP outpost joins the shard (the server's release,
     moved in lockstep by `update --to`); the blueprint adds an LDAP provider
     (`dc=ldap,dc=mediastack`) whose binds run a flow with no MFA step,
     throttled by a reputation policy, open to `media-users`, `admins` and one
     search account (the only one with search rights); Traefik serves it as
     LDAPS on `ldap.<domain>` with the wildcard certificate, to the stack network
     only; `wire authentik` fetches the outpost's token. *Done (LDAP, part 2):*
     `wire jellyfin` installs the LDAP plugin and points it at
     `ldap.<domain>:443` (certificate checking on with production certificates),
     `media-users` or `admins` may sign in, created on first sign-in with every
     library; administrator rights follow `admins` for directory users; the
     stack's own Jellyfin admin stays a local account (the script's and the
     emergency login). Seerr follows Jellyfin (proven). *Done:*
     Audiobookshelf through OIDC — `wire audiobookshelf` does its first run
     (the stack's root account), sets up sign-in through the portal (created on
     first sign-in, never matched to an existing account: by username the root
     account was claimable at sign-up; a root already linked is unlinked
     loudly), keeps admin rights in step with `admins` (a guest stays a guest); the portal's address leads to Traefik inside the stack (an app's
     server talks to authentik there — production certificates required).
     *Done (Kavita, D4 part 2 — proven live):* `wire kavita` does its
     first run (the stack's own admin, with an email nobody can sign up with:
     Kavita always matches an existing account by email), sets up OIDC (one
     restart: it is set up at start-up), its login page straight to the portal
     (`?skipAutoLogin=true` for the admin), every current library for new
     people (refreshed each run; existing people's access never changed —
     `doctor` lists gaps), admin rights synced by wire; its verified-email
     check off (authentik sends `email_verified: false`).
  6. *Done (E — proven live: history, reading and listening progress kept):*
     `link-account <portal-user>` — the
     operator picks each app's local account (never guessed), a plan shows the
     change and its admin effect, then: Jellyfin's login method becomes the LDAP
     plugin (it adopts an account by name only then — checked in its source);
     Kavita's email becomes the portal's (it links by email), its own password
     replaced; Audiobookshelf (no API to link) gets a fenced 10-minute
     username-matching window for the person's one sign-in, refused when any
     other unlinked account could be claimed. Navidrome (links by username at
     the household gate) needs only a rename — later.
  First milestone: the gate in front of the panel and Apprise.
- **One login for the remaining tools** *(later)*: qBittorrent, Pi-hole, Deluge,
  Transmission, LazyLibrarian, Cleanuparr, WatchState and Bazarr are gated and
  closed to the LAN, but still ask for their own login too. Each can drop it
  only where its API stays protected (Bazarr: auth None + its API key;
  Pi-hole: an empty password is safe now its port is local, but its phone apps
  would lose the API) — checked tool by tool.
- **Wizarr mode: Apprise and the panel** *(review later — accepted risk for
  now)*: without authentik there is no gate, and both have no login of their
  own; they stay LAN-open as before.
- **Access per tool** *(look into later)*: today there are two levels — `admins`
  (every admin tool) and the household front end (`media-users`). Finer rules
  (one person gets Sonarr but not qBittorrent) would be one application and
  binding per tool instead of the one domain-wide rule.
- **LDAP app passwords** *(option, later)*: authentik lets a user bind with a
  per-device app password (a TV gets its own, revocable without changing the
  main password). Breaks "one password for everything", so an option, not a
  default.
- **Email for authentik** — *SMTP shipped (Oct 2026)*: the portal sends
  through any SMTP server (`configure`, `email test`, docs/email.md). What
  email is for stays the standard: (1) a user resets their own forgotten
  password — see End-user experience; (2) `invite` can e-mail the link;
  (3) authentik's own update notices reach its admins. Nothing else (no
  marketing, no digests). Still to build: (1)–(3). **Follow-up:** Kavita's
  verified-email check (wire keeps it off) can come on now that a portal
  email is unique and only an admin changes it (Oct 2026) — it needs a scope
  mapping of mediastack's own asserting `email_verified`, the same one ROMM
  needs (authentik's default sends false).
- **Credential coverage** *(audit Sept 2026 — the rest later)*: every login the
  stack stores rotates with `set-credentials` (arr, qBittorrent, Jellyfin admin,
  Pi-hole, Traefik dashboard, Audiobookshelf root, Kavita's admin, the portal's
  akadmin), and a locked-out portal user comes back with `reset-password`. Still
  to do: (1) service secrets, each with its own mechanism: the LDAP search account's
  password and the OIDC client secrets, Audiobookshelf's and Kavita's (regenerate → blueprint →
  wire), the LDAP outpost token, authentik's API token and database password,
  the Meilisearch key, the arr/Seerr/Wizarr/cleanuparr API keys (each app, then
  everything that stores it) — a `rotate-secret <name>` verb or `set-credentials`
  targets; (2) Wizarr mode's `reset-password` through Jellyfin's API (today it
  points at Jellyfin's dashboard); (3) Wizarr's admin (no API found yet — UI
  only); (4) Navidrome's per-user Subsonic password, reset by the admin.
- **LDAP bind cache after a password change** *(test in the rebuild's
  household pass, then decide)*. Jellyfin asks authentik's LDAP outpost to
  bind each sign-in; the outpost runs `bind_mode: cached` and, after a
  successful bind, answers that user + password from memory until the
  authentik session the bind created expires. So a password changed in the
  portal can keep working in Jellyfin (and its TV/phone apps) for a while —
  proven live (Sept 2026); a new or long-unused password is checked
  properly. Only LDAP sign-ins are affected (Kavita and Audiobookshelf use
  OIDC, Navidrome the forward-auth gate — each asks authentik every time).
  * *Unknowns:* how long the window lasts, and — the more important one —
    whether a **deactivated** person is also served from the cache (still in
    Jellyfin after being switched off in the portal).
  * *Test (~15 min):* sign in to Jellyfin as a test user with password A;
    change it to B in the portal; sign in again at once with A — the outpost
    logs `authenticated from session` if the cache served it; repeat every
    few minutes until A fails (the window). Then sign in with B, deactivate
    the user, and try once more.
  * *Fix options:* `bind_mode: direct` — every bind runs authentik's real
    login flow, no window, deactivation included; costs a slower sign-in,
    and Jellyfin binds only when someone signs in (its own token carries the
    session after), so the cost is small — the likely choice if the test
    confirms binds happen only at sign-in. Or keep the cache with a short
    session on the LDAP login stage (e.g. 10 minutes): bounded, not closed.
    `wire` already restarts the outpost after a portal-setup change for the
    same reason (its bind cache cleared).
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
- **Doctor sees what the apps send the hub, not only the script's sends.** The
  notification check records `notify`'s own sends; an arr or Seerr posting
  straight to the hub is invisible to it — three weeks of arr events answered
  424 (a retired tag) showed only as log noise. Doctor should read the hub's
  log for failed sends since its last run and name the sender and tag.
- **Prowlarr's indexers after a restart (next, after the re-org).** Every
  nightly restore point restarts the stack; Prowlarr validates its FlareSolverr
  proxy before FlareSolverr (a browser) is up, its first indexer requests fail,
  it backs the indexer off, and the arrs report "all indexers unavailable"
  (seen nightly in Prowlarr's log, 04:0x). FlareSolverr gets a healthcheck,
  and once it is healthy after any stack start, Prowlarr re-tests its
  indexers. Not covered: FlareSolverr losing Cloudflare's challenge in the
  day — a second indexer (not behind Cloudflare) is the operator's fix.
- **An ERR trap that names an unexpected stop (to discuss).** The scripts run
  under `set -e`: an unguarded command that fails ends the run with no message
  (found when a `grep` matching nothing stopped `wire` mid-way). A trap in the
  entrypoint printing file, line and command before exiting would make every
  such stop fail loud. Open questions: interaction with subshells and
  `|| true` guards, `set -E` for functions, and what the panel shows.
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
