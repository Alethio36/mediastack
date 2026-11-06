# Testing

Three layers, from cheap to slow: the checks CI runs on every push, the
config matrix inside them, and the soak harness that lives on a test box for
an hour and simulates days of use.

## CI: every push

`.github/workflows/lint.yml` runs shellcheck over every script, then each
`scripts/test-*.sh` and `scripts/check-*.sh`. Each test's header says what it
proves; run one locally from the repo root (`scripts/test-wire.sh`). A test
stubs Docker and the apps' APIs, so nothing in it needs a running stack.

A few render the compose config and need `docker compose` — the standalone
plugin renders without a daemon: `test-render`, `test-snapshot`,
`test-matrix`. `test-snapshot` compares generated files with reviewed
copies; when a change to them is intended, review its diff, then
`scripts/test-snapshot.sh --bless` and commit the new copies with the code.

Some tests hold a contract rather than one behaviour. `test-questions` runs
whole questionnaires with failing shims on PATH for sudo, docker, useradd
and the rest — a question that acts instead of asking fails it — and fails
a `*_PASSWORD` setting no service declares as a login. `test-certs` builds a
real root, intermediate and leaf with openssl and runs your-own-certificate
checks against them.

Rules these taught, Nov 2026:

- **A snapshot fixture pins every generated secret** in its `env.set`
  (`MEILI_MASTER_KEY=fixture-secret-…`, `GLUETUN_CONTROL_APIKEY=…`), or the
  generated files differ on every run.
- **The pipe rule holds in tests too**: never `producer | grep -q` — `grep -q`
  exits early, the producer can die of SIGPIPE, and under `pipefail` the
  check fails by timing (a function body over 4 KB did, in a fresh clone).
  Write `grep -q PATTERN <<<"$(producer)"`.
- **A check of a fail-safe path runs the code the way it runs live**: a
  function that reports a failure is tested under `set -Ee` with an ERR trap,
  since that is where an empty `grep` once ended a whole `wire`.
  `test-reasons` holds every reason function (`*_why`, `*_reason`,
  `*_problem(s)`, `*_hint`) to that: empty input, everything unreachable,
  return 0. A new one is picked up by its name.
- **New checks are mutation-checked** before they count: break the code they
  guard, see them fail, restore it.

`stable` moves only through `scripts/promote.sh`: it waits for CI to be green
on exactly the commit it fast-forwards to.

## The config matrix

Testing on an "everything" install hides a service that needs another one it
does not pull in: everything is always there. `scripts/test-matrix.sh`
renders every service on its own, with what `resolve_deps` adds (the VPN for
the arrs, Jellyfin for Seerr and Wizarr), plus the shipped default set and
everything at once. It also checks that `resolve_deps` answers service names
only — its notes once landed in `COMPOSE_PROFILES`, and `.env` validation
then refused every command.

Code-level dependencies are covered by `test-wire`: every wire step and
credential rotation first checks its service is enabled, and nothing a wire
step calls can end the whole run (see
[adding-a-service.md](adding-a-service.md#its-code)).

## The soak harness (test box only)

`scripts/soak.sh` simulates days of use. Each simulated day runs the stack's
night jobs — the record of the host's own address, manifest, update and
backup, whichever timers are enabled, on
the days and times their `OnCalendar` gives (systemd reads it, so a weekly
update lands on its day) — with the clock moved forward by `faketime`, in
transient units named like the real ones, so the script behaves as on a real
night. Before the simulated days, each enabled timer's real unit runs once at
the real time. After each day it judges:

* every night job exited 0
* `doctor`: no FAIL line beyond the known file, no notification stream whose
  last send failed
* `wire --verify`, at the real time: no drift
* `scripts/safety-live.sh`, at the real time: the full `leak-test` and the
  edge's safety rules — every FAIL and every UNPROVEN check is a problem (a
  known pattern can name an expected one, e.g. a rate-limited checker)
* containers: all running, none unhealthy, no restart count went up
* restore points: no more than the retention keeps

**It leaves restore points, manifests and state dated in the future. Run it
only on a box you revert afterwards.** It refuses to start without
`--test-box`.

```
sudo apt install -y faketime tmux
echo 'No indexers' > ~/soak.known          # doctor FAILs expected on this box
scripts/soak.sh --plan --days 7            # the simulated schedule, nothing run
tmux new -s soak                           # survives a dropped SSH session
scripts/soak.sh --test-box --days 7 --known ~/soak.known
```

* **Take the box's snapshot first**, and revert to it afterwards. **After a
  revert, wait before running anything:** the box's clock jumps forward, and
  every `Persistent=true` timer (backup, update, the leak checks) catches up
  at once and holds the stack — `systemctl list-units 'mediastack-*'
  --state=activating,active` shows nothing but timers when it is done.
* **The leak checks run on the real clock meanwhile** (every 5 minutes, the
  full run hourly): a command the soak runs waits up to 2 minutes for one
  that holds the stack.
* **Run it in tmux.** A dropped SSH session would otherwise end it; `nohup`
  does not do, because sudo remembers the password per terminal.
* **About 1–2 hours for 7 days** (Nov 2026) — each backup stops the stack and
  restarts the VPN group through the leak gate's full run, and every day runs
  `safety-live` — and a couple of ops notifications per simulated day.
* **Every judge prints its verdict, a pass included** (`doctor: ok`,
  `wire --verify: no drift`, `safety-live: ok`): a missing line means a check
  did not run.
* **The log is `~/soak-<time>.log`.** Copy it off before reverting, or it goes
  with the snapshot. A failed run also keeps its evidence before the apps
  rotate it away — every stack container's log and the apps' own log folders
  — in `~/soak-<time>-evidence/<day>/`: copy that off too. The known file's entries that matched nothing are listed,
  so a stale one surfaces.

**Not covered:** only the script's own clock moves. Anything it runs through
`sudo`, and the containers, see the real time, so a check that reads a
timestamp they wrote is judged against the real time. `curl` keeps the real
clock too (`FAKETIME_SKIP_CMDS=curl`): moved, it judged an app's fresh session
cookie already expired and dropped it — Deluge took the login, then refused
the next call, and the update night's own `wire --verify` reported drift that
did not exist (proven Oct 2026). The daily `wire --verify` runs at the real
time as well.

**What it has found so far** (first run, Oct 2026): every full update
recreated gluetun's whole VPN group whether or not gluetun changed;
trash-sync then reached the restarted tunnel before its DNS served, and
recyclarr deleted its guide copy; Prowlarr kept "all indexer proxies are
unavailable" in its health list after a passing test. All three are fixed.

**Stages still to build** (roadmap, the pre-alpha rollout): synthetic media
through the arrs' imports, a daily mishap (gluetun killed, a full disk, drift,
a reboot), and the presets live — each from a fresh install.
