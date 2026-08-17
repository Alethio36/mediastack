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
