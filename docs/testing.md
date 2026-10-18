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
night jobs — manifest, update and backup, whichever timers are enabled, on
the days and times their `OnCalendar` gives (systemd reads it, so a weekly
update lands on its day) — with the clock moved forward by `faketime`, in
transient units named like the real ones, so the script behaves as on a real
night. Before the simulated days, each enabled timer's real unit runs once at
the real time. After each day it judges:

* every night job exited 0
* `doctor`: no FAIL line beyond the known file, no notification stream whose
  last send failed
* `wire --verify`, at the real time: no drift
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

* **Take the box's snapshot first**, and revert to it afterwards.
* **Run it in tmux.** A dropped SSH session would otherwise end it; `nohup`
  does not do, because sudo remembers the password per terminal.
* **About 40–50 minutes for 7 days** — each backup stops the stack for a
  minute — and a couple of ops notifications per simulated day.
* **The log is `~/soak-<time>.log`.** Copy it off before reverting, or it goes
  with the snapshot. The known file's entries that matched nothing are listed,
  so a stale one surfaces.

**Not covered:** only the script's own clock moves. Anything it runs through
`sudo`, and the containers, see the real time, so a check that reads a
timestamp they wrote is judged against the real time. `wire --verify` runs at
the real time on purpose: under the moved clock qBittorrent's session read as
expired and showed a login drift that does not exist.

**What it has found so far** (first run, Oct 2026): every full update
recreated gluetun's whole VPN group whether or not gluetun changed;
trash-sync then reached the restarted tunnel before its DNS served, and
recyclarr deleted its guide copy; Prowlarr kept "all indexer proxies are
unavailable" in its health list after a passing test. All three are fixed.

**Stages still to build** (roadmap, the pre-alpha rollout): synthetic media
through the arrs' imports, a daily mishap (gluetun killed, a full disk, drift,
a reboot), and the presets live — each from a fresh install.
