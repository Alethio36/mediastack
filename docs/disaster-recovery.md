# Disaster recovery — full rebuild from a restore point

A restore point contains everything except media: service configs, the stack
definition (`env`), your own files (`custom.tar.gz`: your services, overrides,
proxy routes, TRaSH overrides) and the exact image digests (`images.lock`).
Its `meta` says what made it — manual, scheduled, update, update-scoped or
migrate, with an optional note (`backup --note "why"`) — and each service's
version; `backup list [svc]` shows them all, newest first. A dead host
rebuilds like this:

1. Fresh Debian/Ubuntu host. Mount/attach the disk or share holding your
   old `BACKUP_ROOT` (and your media).
2. ```
   git clone <your-mediastack-repo> && cd mediastack
   ./mediastack.sh install
   cp /path/to/backups/<TIMESTAMP>/env .env && chmod 600 .env
   tar -xzf /path/to/backups/<TIMESTAMP>/custom.tar.gz   # if the point has one
   ```
   Edit `.env` if paths differ on the new host.
3. `./mediastack.sh configure` — existing answers become the defaults;
   recreates users, group and folders from the UID map.
4. `./mediastack.sh up` once (creates containers), then
   `./mediastack.sh restore --all --from <TIMESTAMP>` — restores every
   config and pins every service to the exact image digest it ran before.
5. `./mediastack.sh doctor && ./mediastack.sh leak-test` — both must pass.
6. When satisfied, `unpin` services to resume normal updates.

Practice this once on a scratch VM before you need it. The restore drill is
the only real proof your backups work.

**Where restore points live.** All of this assumes the restore points outlived
the host. Keep `BACKUP_ROOT` on another disk or a NAS — `doctor` warns when it
shares a filesystem with the configs, which the default `./backups` does.

**With the portal (authentik).** Every sign-in goes through it, so it is the
part to get right. Its database lives in its config folder and is restored
with everything else; the secrets that open it (`AUTHENTIK_SECRET_KEY`,
`AUTHENTIK_DB_PASSWORD`, `AUTHENTIK_API_TOKEN`) are in the restore point's
`env` — restore the two together, never a new `.env` over an old database
(with those secrets missing from `.env`, the tooling refuses to start it). The stack's own app
accounts (Jellyfin's local admin, Audiobookshelf's root, Kavita's admin) stay
the way in while the portal is down: their logins are in `credentials`, and
the password forms are behind the addresses `credentials` prints.

## Restore-point retention

Tiered (grandfather-father-son), pruned after every backup, knobs in `.env`:

* `BACKUP_KEEP_DAILY` (7) — the newest N restore points, kept unconditionally.
* `BACKUP_KEEP_WEEKLY` (4) — beyond those, the newest point per ISO week,
  for N distinct weeks.
* `BACKUP_KEEP_MONTHLY` (6) — beyond those, the newest point per month,
  for N distinct months.

Defaults give ~6 months of reach at 17 points steady state. `0` disables a
tier. The newest point is never pruned, and nothing in `BACKUP_ROOT` that
isn't a restore-point directory is ever touched. Every prune prints what it
removed and a `retention 7d/4w/6m: kept X, pruned Y` summary.

### Pre-update points (separate pool)

A targeted `update <svc>` takes a *scoped* restore point — it stops and
snapshots only that one service, leaving the rest of the stack running — and
writes it under `BACKUP_ROOT/pre-update/` instead of the top-level pool. The
grandfather-father-son schedule above **never sees this pool** (it globs
top-level timestamp dirs only), so scoped update points can't displace a
daily/weekly/monthly slot. They have their own retention, `BACKUP_KEEP_PREUPDATE`
(3) — the newest N "undo that update" points, pruned after each targeted update.

`rollback <svc>` returns a service to the image it ran before: the newest
point, in either pool, holding a different image than the one running (so a
second rollback undoes the first). Its config comes back with the image — a
newer version may have upgraded its data, which an older one cannot read — so
the service's data since that point is replaced; the current folder is kept as
`<svc>.pre-restore.<ts>`. It shows the plan and asks first (`--yes` skips the
question; the panel's button passes it after its own confirmation).
`rollback <svc> --from <ts>` takes any point; `backup list <svc>` shows each
point's version, marking the running image (`current`) and rollback's target.
`restore --service <svc>` is for a broken config on the same image: it takes
the newest point, losing the least. To move to a chosen version instead, use
`update <svc> --to <tag>` — image only, so going *back* that way can meet data
a newer version upgraded; if it fails, `rollback` returns to the point that
update takes first. A full
`restore --all` only ever draws from the top-level GFS pool, never a partial
pre-update point. Full `update` (all services) and `update gluetun` still take
the full stop-the-world restore point into the GFS pool as before.

### A backup that is cut off

A backup stops services, and Docker never restarts them on its own — `compose
stop` marks them deliberately stopped, which outlives a reboot. So whatever
ends a backup early (an error, Ctrl-C, a dropped SSH session, a shutdown), the
services it stopped are started again and ops is told. What no script can
catch (a power cut, `kill -9`) leaves `local/stopped-for-backup` behind: the
next boot starts those services and tells ops, `doctor` fails until they run,
and `up` settles it. `restore` is the exception, on purpose — a service is
never started on a half-extracted config; run the restore again.

A point is written as `<timestamp>.partial` and renamed only once complete,
so an incomplete one is never restored from, verified or counted as the
newest. A failed one stays for inspection until the next backup removes it.
If the services cannot start again, the alert may not arrive: Apprise is one
of them — `doctor` still says so.

## Media manifest — what was in the library

Restore points cover configs, not media. The media manifest is the record of
the media itself: a read-only snapshot of every file under `DATA_ROOT/media`
(size, mtime, inode, path), taken nightly by the `mediastack-manifest` timer
(`MANIFEST_SCHEDULE`, default `*-*-* 03:30`) into `BACKUP_ROOT/manifest/`,
one gzipped file per run, kept `MANIFEST_KEEP_DAYS` (365). The newest
snapshot is never pruned. Nothing else in `BACKUP_ROOT` is touched, and the
GFS schedule never sees this folder.

**Answering "what happened to X?"**

* `./mediastack.sh manifest find "the office"` — every path matching the
  text (case-insensitive), with the first and last snapshot it appears in and
  whether it is still there. The last-seen date bounds when it went.
* `./mediastack.sh manifest diff` — the folders that lost media files between
  the last two snapshots, with the file names; give timestamps (or a unique
  prefix of one) to compare any two.

**What alerts.** Files are identified by inode + size, so an arr renaming a
file or a whole folder is a move, not a loss. A folder alerts (ops stream,
warning) only when it lost more media files than it gained: an upgrade (one
out, one in) is quiet; a deleted movie or episodes are not. Artwork, NFO and
subtitle files never count. Known blind spot: an upgrade that also renames its
folder reads as one loss in the old folder.

**What refuses.** If the media-file count fell more than `MANIFEST_ALERT_PCT`
(5%) — and by at least 25 files — or the media root came back empty, the run
is refused: nothing is recorded, ops gets a failure, and the previous snapshot
stays the baseline. That is almost always an unmounted or half-visible share.
If the deletion was intended, `./mediastack.sh manifest --accept` records it.
A scan that cannot read a path also refuses (a partial scan would look like
lost media).

**Where it lives.** Keep `BACKUP_ROOT` off the disk that holds the media —
after a disk loss, the manifest is the list of what to re-add. `doctor` warns
when they share a filesystem. A snapshot lists your whole library, so the
script refuses to write one inside this repo unless the folder is gitignored
(the default `./backups` is).

**Who removed it.** With deletion attribution on (`./mediastack.sh audit on`),
the loss report, `manifest diff` and the ops alert name who removed each
folder — a service, or a person by their login — from the deletion log for
that window. "No deletion recorded here" means it did not happen through this
host (the NAS itself, another machine) or happened while attribution was off.
`./mediastack.sh audit report` lists every delete and rename with its time.
Without attribution, the manifest says *what* went and *when* (to within a
day), not *who*.

Existing installs get the schedule on `upgrade`; install its timer with
`./mediastack.sh apply-timer`.
