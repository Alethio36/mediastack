# Design: rotate-secrets

*Status: proposed (13 Nov 2026), MVP plan step 4. Direction agreed 13 Nov:
one verb, no arguments, every machine secret at once; `.env` before the
holders are rewired (agreed 13 Nov). Spike: authentik's part done (1, 2 and
its share of 7, below); the rest next on the test box, then this doc is
revised to agreed before any build.*

## Why

- **A secret that may have leaked has no way out today.** `set-credentials`
  rotates the logins people type; the keys and tokens the stack generated for
  itself (API keys, the portal's tokens, database and client secrets) are set
  once and never change.
- **A leak is all-or-nothing in practice.** Whoever had the host, a backup or
  a pasted `.env` had every secret at once, so rotating one at a time leaves
  the rest open.

## Goals

- **One command, everything.** `rotate-secrets` takes no arguments: every
  machine secret the stack owns gets a new value, every consumer is rewired,
  and the stack is up and working again at the end.
- **Nothing is left half-changed.** Each secret moves all-or-nothing; a
  failure puts that one back on its old value and the run goes on.
- **No value is ever printed.** The run's output, its run record and the
  support bundle hold no secret; `credentials` shows the new values.
- **What breaks outside the stack is impossible to miss.** Said before the
  run starts, and again as the last thing printed.

## Decisions — **agreed** (13 Nov 2026)

1. **One verb, no names, no `--all`.** These are machine secrets; picking
   among them is not worth the code. A retry after a partial failure is a
   full re-run.
2. **authentik's secret key and Meilisearch's master key are in.** Their
   costs (everyone signed out; JellySearch re-wired, re-indexed if the spike
   says so) are said up front, not avoided. A rarely used tool.
3. **The stack's own logins are in when `STACK_LOGINS=generated`** — nobody
   chose those passwords. With `unified` or `each` they are the user's: left
   alone, and the end says `set-credentials all` changes them.
4. **A restore point first** (kind `rotate`), **the maintenance lock held**
   for the whole run (no timer, backup or update in between).
5. **External accounts are out of scope** — the run says where to make a new
   one and what to paste where.
6. **People's own portal accounts are never touched.**
7. **With it:** Wizarr mode's `reset-password` through Jellyfin's API, and
   Navidrome's admin reset through its API (the second is also the rotator
   for Navidrome's generated login).

## What is rotated

Owner = where the value is authoritative. Holders = what keeps a copy and is
rewired. Each row's code lives in its service's folder.

| secret | owner | holders (rewired by) | cost |
|---|---|---|---|
| `AUTHENTIK_DB_PASSWORD` | authentik's PostgreSQL role | server, worker (recreated) | portal down ~1 min |
| `AUTHENTIK_SECRET_KEY` | server, worker (compose) | — | the portal's own sessions (the gates' are ended below) |
| `AUTHENTIK_API_TOKEN` | its token in authentik | the script only | — |
| `AUTHENTIK_ADMIN_PASSWORD` (akadmin) | authentik (`sc_rotate_portal`) | — | — |
| `AUTHENTIK_LDAP_TOKEN` | the outpost's token in authentik | LDAP outpost (recreated) | Jellyfin sign-in down ~30 s |
| `AUTHENTIK_LDAP_BIND_PASSWORD` | the search account (blueprint) | Jellyfin's LDAP plugin (`wire jellyfin`) | — |
| `AUTHENTIK_ABS_CLIENT_SECRET` | the provider (blueprint) | Audiobookshelf (`wire audiobookshelf`) | — |
| `AUTHENTIK_KAVITA_CLIENT_SECRET` | the provider (blueprint) | Kavita (`wire kavita`, one restart) | — |
| each arr's API key (Radarr, Sonarr, the 4K/anime instances, Lidarr) | the arr (its `ResetApiKey` command; read back from `config.xml`) | Prowlarr, Seerr, Bazarr, Cleanuparr, Recyclarr (their `wire` roles, `trash-sync`'s config) | **companion apps** |
| Prowlarr's API key | Prowlarr (`ResetApiKey`; read back from `config.xml`) | every arr's indexers (Prowlarr pushes them itself), LazyLibrarian | **companion apps** |
| Bazarr's API key | Bazarr (`settings-auth-apikey` through its settings form; `config.yaml` follows) | — | **companion apps** |
| LazyLibrarian's API key | its `config.ini` (`ll_api_enable` writes a new one while it is stopped) | Prowlarr's application entry | — |
| `JELLYFIN_API_KEY` | Jellyfin (the old key deleted, then `wire jellyfin` mints and stores a new one) | Wizarr's server entry | Wizarr mode: see spike 4 |
| `SEERR_API_KEY` | Seerr (`POST /settings/main/regenerate`; `wire seerr` stores it) | the script only | **companion apps** |
| `CLEANUPARR_API_KEY` | Cleanuparr (`POST /account/api-key/regenerate`; `wire cleanuparr` stores it) | the script only | — |
| `WIZARR_API_KEY` | Wizarr | the script only | see spike 5 |
| `MEILI_MASTER_KEY` | Meilisearch (compose) | JellySearch (compose; re-indexes from Jellyfin's database at every start) | search down until both are back |
| `GLUETUN_CONTROL_APIKEY` | gluetun (compose: `.env`, then `up` through the leak gate) | — | **the VPN group restarts through the leak gate** |
| **every session** (not a secret: the run's last step) | authentik (`DELETE /core/authenticated_sessions/<uuid>/` for each) | the gates' sessions end with them (authentik tells its outposts) | **everyone signed out**: portal, gated tools, panel, household gates |
| the generated logins (arr, qBittorrent, Deluge, Transmission, Jellyfin's admin, Pi-hole, Traefik's dashboard, Audiobookshelf's root, Kavita's admin, Navidrome's admin) | each app (`sc_rotate_*`, non-interactive) | what `set-credentials` already updates | **companion apps** using a login; the operator's saved passwords |

**Not rotated**, and said so at the end: the VPN's `WIREGUARD_PRIVATE_KEY` /
`NORDVPN_TOKEN`, `CF_DNS_API_TOKEN`, `CLOUDFLARE_TUNNEL_TOKEN`,
`SMTP_PASSWORD`, the Apprise URLs and an own certificate's key (external
accounts: where to make a new one, then the command that takes it); Wizarr's
admin (its UI only); the panel's fallback login (only its hash is stored —
`frontdoor-install --set-password`); people's accounts and their Navidrome
music-app passwords. Inside authentik's database: the gates' `cookie_secret`
(`mediastack-gate`, each `mediastack-house-<svc>`) — no API writes it, and a
gate's sessions live in the database, so the secret alone opens nothing; and
the "authentik Self-signed Certificate" that signs Audiobookshelf's and
Kavita's sign-in tokens — authentik cannot regenerate a certificate in place
and the blueprint finds it by name (roadmap, after the MVP).

## How one secret moves — **proposed**

```
generate -> journal (old + new) -> owner -> .env -> rewire holders
         -> read back (wire <roles> --verify; the old value refused) -> journal cleared
on failure: owner + .env back to old -> rewire again -> reported, run goes on
the put-back fails: the run stops, names the restore point:
                    ./mediastack.sh restore --all --from <ts>
```

**Change from principle 2** (*agreed 13 Nov*; was "only then `.env`"): `.env` takes the
new value *before* the holders are rewired, because `wire` reads `.env`, and
the compose-carried secrets (authentik's, Meilisearch's, gluetun's) only
reach their container through it. The journal keeps the old value until the
secret is proven, so a put-back is always possible.

- **The journal** — `local/rotate/journal`, 0600, one block per secret in
  flight (name, old, new). Cleared when that secret is proven or put back. A
  run killed mid-secret leaves it: the next `rotate-secrets` refuses to start
  and names the restore point; `doctor` names it too. Never in the support
  bundle (the bundle is an allowlist; nothing under `local/rotate/` joins it).
- **Holders are rewired by `wire`, not by rotator code.** `wire` is
  desired-state and reads every key from its owner or `.env`, so a rotator
  only changes the owner and names the roles to re-run. **Hidden work:** a
  wire step that only creates an entry and never corrects an existing one's
  key would leave a stale copy — spike 7 audits every holder first.
- **Order** — an explicit list in `lib/rotate.sh`, like `WIRE_ROLES`:
  authentik's (DB password, secret key, API token, akadmin, LDAP token, bind
  password, client secrets), Jellyfin's key, the arrs', Prowlarr's, Bazarr's,
  LazyLibrarian's, Seerr's, Cleanuparr's, Wizarr's, Meilisearch's, gluetun's,
  the generated logins, then every session ended. authentik first: everything
  after it may need the portal's API; the sessions last, so none opened
  during the run outlives it.
- **Per service** — each service declares its secrets with a `<svc>_secrets`
  function (one TSV line each: title, key, holders' roles, cost words) and
  rotates them with `<svc>_secret_rotate KEY NEW OLD`, as `<svc>_logins`
  does for logins. CI holds every `secret` row whose writer is `script` in
  every `env.tsv` to a declaration or to the "not rotated" list in
  `lib/rotate.sh`: a new service cannot add a secret the verb forgets.

## The run — **proposed**

1. **Terminal only** (`[[ -t 0 ]]`, as `set-credentials`): not in the panel,
   not from an answers file. A rarely used tool; the panel's session would be
   signed out mid-run anyway.
2. **The cost, then one confirmation.** What will change and what that
   breaks, from the declarations (only for enabled services): everyone
   signed out of the portal, each companion-app key and login that will stop
   working, the VPN group restarting, search down for a minute, the
   generated logins that change. `Type ROTATE to go on.`
3. The restore point (`backup_take rotate`), the maintenance lock.
4. Each secret, in order. Progress says names, never values.
5. `up` (whatever a recreate left behind), `wire --verify`, `doctor`.
6. **The end** — failures first (each secret put back, why, what to run),
   then the warning below as the very last thing printed.

### The final warning — **agreed** (a big warning at the end, hard to miss)

A framed block in bold yellow, the last lines of the run, also when every
secret succeeded:

```
╔══════════════════════════════════════════════════════════════════════╗
║  SECRETS ROTATED — ANYTHING OUTSIDE THE STACK NOW HAS A STALE ONE   ║
╠══════════════════════════════════════════════════════════════════════╣
║  • Phone and companion apps (nzb360, LunaSea, …) and any integration ║
║    you set up yourself: re-enter their API keys and logins.          ║
║    The new values:  ./mediastack.sh credentials                      ║
║  • Everyone was signed out of the portal: sign in again.             ║
║  • The stack's own logins changed: update your password manager.     ║
║  • Not rotated (external accounts): <only those this install uses>   ║
╚══════════════════════════════════════════════════════════════════════╝
```

Lines appear only when they apply (no portal → no sign-out line; `unified`
logins → the `set-credentials all` hint instead of the login line).

## Spike — on the test box, before the build

1. *Done (13 Nov 2026).* **authentik's secret key.** Its docs: cookie
   signing, a change ends active sessions; before 2023.6 it also derived user
   IDs, hence the old "never change it" (the schema's note is stale — we run
   2026.8). Its source (2026.8.5): session cookies, file links signed for 15
   minutes, the built-in outpost's own sign-in to the server (same container)
   and an error-report tag — nothing stored is encrypted with it. Live on the
   test box: a new key, `up` recreated server and worker, `wire --verify`
   clean, doctor unchanged. Rotation: `.env`, recreate both.
   **It does not sign everyone out** (found live): the portal's session went,
   radarr's through the gate stayed — a gate keeps its own session (its
   cookie keyed by the gate's `cookie_secret`, the session in authentik's
   database), ended only when the portal session it came from is deleted
   (authentik's `pre_delete` hook tells its outposts) or when it expires. A
   new key deletes no session row. Proven live: `DELETE
   /core/authenticated_sessions/<uuid>/` for each, then radarr — untouched
   since — went to the portal's sign-in. So the run ends every session
   itself, as its last step.
2. *Done (13 Nov 2026, from its source).* **API token and LDAP outpost
   token**: `POST /core/tokens/<identifier>/set_key/` sets a new key on the
   same token (`authentik-bootstrap-token`, `ak-outpost-<pk>-api`). The
   bootstrap blueprint's token entry is `state: created`, so a restart never
   puts the old key back. The outpost's: `wire authentik` already copies it
   into `.env` and restarts the outpost.
   **Database password**: `POSTGRES_PASSWORD` is read only when the database
   is created — `ALTER ROLE` inside `authentik-db` (SQL on stdin, never in a
   process list), then `.env`, then server and worker recreated: open
   connections survive the change, so only a fresh start proves it.
   **Bind password, client secrets**: the blueprint reads them from the
   worker (`!Env`), and authentik applies a blueprint only when its file
   changes — found and fixed first (`fix(authentik)`, reproduced live: a new
   `PORTAL_TITLE` never reached authentik, `wire --verify` clean). With it:
   `.env`, `up` (the worker recreated), `wire authentik` applies, then
   `wire jellyfin`/`audiobookshelf`/`kavita` — each already compares the
   secret itself (Kavita by its digest).
3. *Done for the arrs and Prowlarr (13 Nov 2026).* **The arr-family keys.**
   No API sets a chosen key (`PUT /config/host` skips `ApiKey`); each app
   makes its own: `POST /command {"name":"ResetApiKey"}` writes a new random
   key to `config.xml`, read on every request — proven live on Sonarr: 201,
   the old key 401, the new 200, no restart. So for these the owner
   generates and the run reads the new key back (`arr_key`). Prowlarr's own
   reset raises `ApiKeyChangedEvent`, a forced full sync of every indexer to
   every app with the new key (from its source; the test box has no indexers
   to watch it — proven with the build). *Bazarr (13 Nov, live):* its settings
   form takes `settings-auth-apikey` (204), the old key 401, the new 200,
   `config.yaml` follows. *LazyLibrarian:* `ll_api_enable` already writes a
   new key while it is stopped — it is the rotator (proven with the build).
4. *Jellyfin's own part done (13 Nov 2026, live).* Deleting the stack key
   (`DELETE /Auth/Keys/<key>`, 204) refuses it at once (401); `wire
   jellyfin` mints a new one and stores it (200). Still open, **Jellyfin's
   key in Wizarr mode**: Wizarr's server entry holds a pasted
   copy. Through Wizarr's API, or by hand — if by hand, the end says so and
   it is a cost line.
5. **Wizarr's API key** is minted in its UI only today. If no API mints one,
   it moves to "not rotated" with how to make a new one and `wire wizarr`.
6. *Seerr's done (13 Nov 2026, live).* `POST /settings/main/regenerate`:
   the old key 403, the new 200. `wire seerr` stored the key only at Seerr's
   first setup, so a regenerated one left `.env` dead with wire and doctor
   silent — reproduced and fixed (`fix(seerr)`: stored on every run, doctor
   tests it). *Cleanuparr's (13 Nov, live):* `POST /account/api-key/regenerate`
   with its API key answers the new one; `wire cleanuparr` already stores it.
   *gluetun's control key (13 Nov, live):* `.env`, `up` — recreated through
   the leak gate, the control server still asks for credentials (401).
7. **Every holder's wire step corrects a stale key** (and `--verify` reports
   one). Any create-only step is fixed first, as its own patch. authentik's
   holders: done (2). The arrs' holders: Prowlarr's and Seerr's entries were
   create-only — reproduced live (a new Sonarr key: Prowlarr's test 400,
   Seerr's copy old, `wire --verify` clean) and fixed (`fix(wire)`): Prowlarr's
   masked copy is tested and replaced when refused as the key, Seerr's
   compared. Seerr writes blind, so `--verify` skips it; `wire` heals it.
   Bazarr posts its whole settings form on every `wire` — its copy follows
   (live). Cleanuparr's instances were create-only too — reproduced live (its
   test 400, wire silent) and fixed (`fix(cleanuparr)`): its masked copy is
   tested, and replaced when only the arr's current key passes. Its
   `--verify` stopped before signing in yet said "no drift" — fixed too: a dry
   run reads it with the stored key. Recyclarr's
   config is written from `arr_key` at every `trash-sync` (proven with the
   build).
8. **Meilisearch**: a new master key in `.env`, `up` recreated both; JellySearch
   re-indexed from Jellyfin's database at its start ("Indexed 7 items") — no
   re-index step of ours (13 Nov 2026, live). The current key 200, any other
   403 (live, with `curl`: the image has no `wget`).

## Proof (anzac4)

An install from `base-cert` with every rotated service enabled (authentik
mode), then `rotate-secrets`: `wire --verify` clean; every sign-in working
(portal, Jellyfin via LDAP, Audiobookshelf and Kavita via OIDC, Navidrome,
the arrs through the gate); each old value refused by its owner; `doctor`
clean; the run record and a `support` bundle grep-clean of every old and new
value. Then a run killed mid-secret: the journal named, `restore --all`
brings the stack back. Wizarr mode: the same, with `reset-password` through
Jellyfin's API.

## Build order

1. The spike; this doc to agreed.
2. `lib/rotate.sh`: the verb, the cost and confirmation, the restore point
   and lock, the journal, the order, the end and its warning; the CI
   coverage check; doctor's leftover journal.
3. The keys outside authentik (gluetun, Meilisearch, Jellyfin, Seerr,
   Cleanuparr, the arr family) — proven live.
4. authentik's — proven live.
5. The generated logins and Navidrome's admin rotator — proven live.
6. Wizarr mode's `reset-password`.
7. README, the full proof, promote.

Hidden cost on record: a run restarts most of the stack (the VPN group
through the leak gate), so it takes minutes and interrupts playback; one
secret at a time means an arr restarts once per rotation that touches it.
Accepted for a tool run rarely.
