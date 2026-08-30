# Candidate services — evaluated, deferred

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

**Why deferred (Nick's call — radar, not roadmap):** it is *not* a drop-in
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
