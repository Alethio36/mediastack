# Candidate services — evaluated, deferred

Services that were assessed for the stack and consciously *not* shipped
yet, with the reasoning, so the decision isn't re-litigated from scratch
later. Adding any of these is a `new-service` scaffold plus a fragment —
the notes here are about *whether*, not *how*.

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

## Bindery — book acquisition (Readarr replacement, modern)

**What it is:** the newest Readarr replacement; imports old Readarr DBs,
architected to survive metadata-provider outages (the actual thing that
killed Readarr).

**Why deferred:** young and **Usenet/SABnzbd-first**, where this stack is
torrent-first via qBittorrent. LazyLibrarian already fills the book-
acquisition slot and wires cleanly to Prowlarr.

**Revisit when:** Bindery matures, or if the stack ever gains a Usenet
path — at which point it may be the better book manager.

## Komga — comics/manga server (Kavita alternative)

**What it is:** comics/manga specialist with a rock-solid, well-documented
REST API and the best Mihon/Tachiyomi integration.

**Why deferred:** Kavita was chosen for breadth (ebooks + comics + manga +
light novels in one server). Komga's edge is its API, which matters for
*building automation against it* — not for serving and reading.

**Revisit when:** a concrete need to script against a comic server's API
appears. Komga and Kavita don't conflict (different ports, shared
storage) and can run side by side if that ever happens.
