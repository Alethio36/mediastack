# Disaster recovery — full rebuild from a restore point

A restore point contains everything except media: service configs, the stack
definition (`env`), and the exact image digests (`images.lock`). A dead host
rebuilds like this:

1. Fresh Debian/Ubuntu host. Mount/attach the disk or share holding your
   old `BACKUP_ROOT` (and your media).
2. ```
   git clone <your-mediastack-repo> && cd mediastack
   ./mediastack.sh install
   cp /path/to/backups/<TIMESTAMP>/env .env && chmod 600 .env
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
