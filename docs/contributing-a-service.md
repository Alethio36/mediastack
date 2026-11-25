# Contributing a service

The order to add a **shipped** service in — one that lives in `services/`
and comes with mediastack. (Your own services go in `custom/compose.d/`:
[adding-a-service.md](adding-a-service.md), which is also the reference this
recipe points into for every detail.) Dispatcharr was the first service
added this way, start to finish (docs/roadmap.md, step 10); its folder is
the worked example throughout.

A shipped service is **its folder**, `services/<name>/`, plus a short list
of places outside it that the contract names on purpose. Anything else you
find yourself changing outside the folder is a finding: say so in the pull
request — it usually means a list that should be derived, or a hook that
should exist.

## 0. Before any code: is it a fit?

Read the app's source and its image, not its README, and write down:

- **Licence**, and whether its versions are tagged — the image is pinned to
  a version, never `latest`.
- **How it takes its user**: `PUID`/`PGID`, or `user:`, or root by design —
  and what its start script makes root's before it switches
  ([Identity](adding-a-service.md#identity-puidpgid-or-user--verify-never-assume)).
- **How people sign in**, and what the portal can do for it: a header it
  trusts (only from Traefik's address?), its own login, OIDC, nothing.
- **What it calls home**, what it needs to reach, what it costs idle (memory,
  first start).
- **Who uses it**: which other apps talk to it, and through what.

Then a spike on a test box: run the pinned image beside the stack and prove
each claim you will build on (Dispatcharr's: 30 checks, among them that a
client's own copy of the sign-in header is overwritten by Traefik). The
evaluation and the decisions go under "Decisions pending" in
`docs/roadmap.md` before the folder exists.

## 1. The fragment — `services/<name>/compose.yml`

- One service per folder; the folder's name is the service's name, its
  config folder's and its settings' stem (`DISPATCHARR_UID`).
- Its own `x-logging` and `x-armour` anchors, `logging: *logging`,
  `dns_search: ["."]` unless it shares gluetun's namespace or is a VPN
  toggle (`vpn_gen` writes it for those; `test-render`
  fails a missing log limit or a wrong `dns_search`), and a healthcheck that
  asks the app, not the process.
- Labels, not code, for everything the stack derives
  ([the label contract](adding-a-service.md#the-label-contract)):
  `mediastack.managed`, `.port`, `.subdomain`, `.desc`, `.vpn` and
  `.vpntoggle`, `.config` / `.cache` / `.datadirs`, `.auth` and `.tier`
  under the portal, `.people` if people sign in to it, `.errors` if its log
  has levels. VPN off by default for anything that serves people.
- **Outside the folder:** its `include:` line in `docker-compose.yml`
  (`test-render` fails a fragment left out).

## 2. Its settings — `services/<name>/env.tsv` and `.env.example`

- A row per setting of its own (the columns of `lib/env.schema.tsv`): its
  type, default, who writes it, the recommended answer
  ([Its settings](adding-a-service.md#its-settings)).
- **Outside the folder:** its block in `.env.example` — its `<SVC>_UID`
  (the next free number), `<SVC>_UPDATE` and its keys, each with a comment
  saying what it is. No `ENV_SCHEMA` bump and no migration for a new
  service's own lines (`check-schema-bump` tells them apart).

## 3. Its logins and secrets

- An account the stack makes for itself is **declared**: `<name>_logins`
  (one line per login, with the app's own limits from its source), and
  `sc_rotate_<target>` to change it. Optional: `sc_explain_<target>`,
  `<name>_credentials` (its rows and notes in `credentials`),
  `<name>_api_key` ([the login contract](adding-a-service.md#its-code)).
- A secret the scripts generate is rotated by `rotate-secrets`
  (`<stem>_secrets` + `<stem>_secret_rotate`, and its stem in
  `ROTATE_ORDER`), or named in `ROTATE_NOT` with why.
- **CI:** `check-registries` fails a login without its rotation and a
  rotation, note or key with nothing behind it; `test-rotate` a generated
  secret with no way to rotate; `test-questions` a `*_PASSWORD` no login
  declares.

## 4. Its hooks — found by name, in its folder

Define only those it needs; nothing lists them:

| Hook | When it runs |
|---|---|
| `<name>_questions`, `<name>_summary` | `configure`, when it is enabled: asks and records, nothing else |
| `<name>_provision` | before its first start: makes what its image would make root's |
| `<name>_gate_login` | `disable authentik`: its own login back before the ports reopen |
| `<name>_login_middleware` | a route that adds its login past the gate (`mediastack.auth.inject`) |
| `<name>_people_follow` | `people-sync` / `access`, for `mediastack.people: follow` |
| `<name>_listen_port` | port forwarding, for a torrent client |

**CI:** `check-registries` fails a hook outside its service's folder, one
named for no service (a typo never runs), and a label or call that needs a
hook without it — `mediastack.auth.inject`, `mediastack.people: follow`,
`mediastack.torrent`, a `gate_trusted` call — or the hook without them.

## 5. Its wiring — `services/<name>/<name>.sh`

- `wire_<name>`: enabled check first; `wire_gate`; a readiness wait that
  asks the app (`http_ready` — *running is not answering*); every failure
  `wfail` and `return 0`; a read that decides whether to create something
  fails loud; every change read back; `w_would` before each change, so
  `--dry-run` shows exactly what a real run does
  ([two rules](adding-a-service.md#its-code)).
- Addresses of other apps from `svc_addr`, never a literal.
- **Outside the folder:** its word in `WIRE_ROLES` (`lib/wire.sh`), placed
  in the order it must run in — before the apps that consume it.
- If it plays a role the stack already has (a download client, a live TV
  source), it ships `provides/<role>.<consumer>.json` — data only, and the
  consumers' code is already written
  ([Providing a role](adding-a-service.md#providing-a-role-wiring-by-role)).
  A new role only when a second provider of it exists.
- Its own checks for `doctor`: `<name>_doctor`, and its word in
  `DOCTOR_APPS` (`lib/doctor.sh`).

## 6. Under the portal

- `mediastack.auth: gate` (a tool) or `native` (its own login): the tier,
  the card and the route come from the labels.
- A sign-in the portal hands it (a header): trusted from Traefik's address
  only, and **no route to it that skips the gate** — that route would carry
  a client's own header straight in.
- **Its icon**: `services/<name>/icon.png`, square, 512 pixels at most, its
  PNG text fields saying its Source, Copyright, License, Modified and
  Trademark; its source and licence in `services/NOTICE-icons.md` (and the
  licence's text in `LICENSES/` if it is a new one). **CI:**
  `check-registries` fails an app behind the portal without an icon, and an
  icon without those fields.

## 7. Its README — `services/<name>/README.md`

What it is for, how people sign in, what `wire` sets up and leaves to you,
what it costs (memory, first start), the VPN, what it stores where. The
upstream gaps you found go in `docs/watchlist.md`.

## 8. Its tests

- `scripts/lint.sh` before anything else: shellcheck as CI runs it, and it
  says when yours is another version.
- `scripts/test-<name>.sh`: the entrypoint sourced minus its last line, the
  app's API as stubs. CI runs it by itself (`scripts/ci-unlisted.sh`) — no
  workflow line.
- **Run the code the way a run does.** A call in a condition (`|| fail_`,
  `if`, `!`) runs without `set -e`, and a `$( )` does not inherit it: a
  failure a real run stops on passes there (`login_opt`'s test passed that
  way while `set-credentials all` would have stopped at the first login).
  Call the code with `as_run` (`scripts/testlib.sh`), plainly, then check
  `RC` — `check-test-runners` fails a runner in a condition; see
  [testing.md](testing.md).
- **Break it on purpose.** For every rule a test holds, change the code to
  break that rule and watch the test fail — for the reason you meant. A stub
  that answers every call the same can make a duplicate look like an
  update (`test-livetv`'s did, until each new entry got its own Id).
- The generated files change on purpose: read the diff, then
  `scripts/test-snapshot.sh --bless`; `scripts/gen-answers.sh` for the
  answers file; `scripts/test-dispatch.sh --update` if a verb's arguments
  changed.

## 9. Prove it live

On a test box, from a pull of your branch: `enable <name>`, `wire --dry-run`
then `wire`, a second `wire` that changes nothing, `doctor`, `wire --verify`;
the app in a browser, through the portal and signed out of it; its VPN
toggle both ways (`vpn <name> on`, `up`, then `off`, `up`) — what calls it
re-pointed in one run, and the app still doing its job; a restore point
while it runs. Then the thing the household will actually do with it
(Dispatcharr: a channel playing in Jellyfin, in and out of the VPN).

## 10. Write down what it took

In the pull request (and in `docs/roadmap.md` for a step): every file
outside its folder it made you touch, each as the contract allowing it or a
finding — fixed, or filed with what would fix it. That list is how the
next service gets cheaper.

## Lessons the first one paid for

- **Running is not answering.** A container can be running while its proxy
  answers 502 for the app still starting — wait for the answer you need.
- **A function that ends in a failing test returns 1.** `[[ … ]] && x` as a
  function's last line ends a run under `set -e`; end it with an `if` or
  `return 0`.
- **A route around the gate is a hole**, whatever it is for — an IPTV
  player's playlist included (docs/watchlist.md).
- **The app's own defaults belong in its README**: Dispatcharr's sign-in
  throttle (3 a minute per address), its playlist form that starts on Xtream
  Codes, Jellyfin's hour-long copy of a guide — each would have cost the
  next person the round trip it cost us.
- **A far VPN server costs every request.** Measure the app's real work in
  the VPN, not a speed test: 49 Mbit/s through the tunnel, and still a
  channel took 16 s to open, past Dispatcharr's 8 s timeout.
