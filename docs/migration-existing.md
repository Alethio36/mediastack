# Migrating an existing docker-compose deployment onto mediastack

For deployments running a hand-maintained compose file (including older
versions of this project). Principle: **nothing moves** — `.env` points at
your existing paths; only the definition changes shape. All examples use
placeholders; substitute your own paths.

## 1. Safety net
```
cd /path/to/old-stack
git init 2>/dev/null; git add -A; git commit -m "pre-migration state"
sudo docker compose config > /tmp/before.yaml
```

## 2. Bring in mediastack
Clone this repo (separate directory), `./mediastack.sh install`, then
`configure` — answer with your EXISTING paths: CONFIG_ROOT and DATA_ROOT
as they are today, profiles matching what you actually run. If your
current PUIDs differ from the defaults, put your numbers in the UID map —
matching UIDs means zero chown, zero data movement.

## 3. Prove equivalence before touching anything
```
./mediastack.sh doctor          # permissions vs your existing tree
sudo docker compose --project-directory . config > /tmp/after.yaml
diff /tmp/before.yaml /tmp/after.yaml | less
```
Iterate on `.env` (ports, names, paths) until differences are intentional.
If your old project name differs from `mediastack`, stop the old stack
(`docker compose down` in the OLD directory) before step 4, or ports
collide.

## 4. Cut over
```
./mediastack.sh up
./mediastack.sh doctor && ./mediastack.sh status
```
Rollback at any point: `down` here, `up` in the old directory — state never
moved, so both definitions point at the same configs.

## Jellyfin: linuxserver → official image
This stack uses the official `jellyfin/jellyfin` image. It keeps its
database at `/config/data/jellyfin.db`; the linuxserver image nested it one
level deeper (`/config/data/data/jellyfin.db`). One-time fix, stack stopped:
```
sudo mv /your/config/jellyfin /your/config/jellyfin-lsio
sudo mv /your/config/jellyfin-lsio/data /your/config/jellyfin
# verify /your/config/jellyfin/data/jellyfin.db exists, then clean leftovers
```
Then `./mediastack.sh fix-perms jellyfin`. To keep the linuxserver image
instead, override the jellyfin image and the jellysearch mount in
`docker-compose.override.yml`.

## First backup sizing
Your first `backup` archives the whole config tree — Jellyfin metadata can
be many GB. The command checks free space first and refuses rather than
writing a partial archive; point BACKUP_ROOT somewhere with room.
