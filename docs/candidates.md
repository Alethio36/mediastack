# Candidate services — evaluated, deferred

Services that were assessed for the stack and consciously *not* shipped
yet, with the reasoning, so the decision isn't re-litigated from scratch
later. Adding any of these is a `new-service` scaffold plus a fragment —
the notes here are about *whether*, not *how*.

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
