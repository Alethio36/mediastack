# Design: run records and the support bundle

*Status: proposed (Nov 2026), MVP plan step 2. Nothing built yet. Sections
marked **proposed** are open; each becomes **agreed** as it is settled.*

## Why

- **What happened is lost.** A run's output lives in a terminal, the panel's
  page, or the journal (timers): a dropped SSH session, a closed tab or a
  rotated journal takes it. Found live (Nov 2026): `logs` shows the last 100
  lines, which hid authentik's first start; a failed timer's notice quoted
  sudo's audit lines, home paths included, instead of the run's own words.
- **Helping someone means their output.** Today that is "paste what you
  see", which is partial, and nobody knows what in it is a secret.
- **The install matrix (step 12) needs it.** Many unattended installs are
  triaged from their records, not watched.

## Goals

- **Every run is recorded, whoever starts it** — a terminal, the panel, a
  timer, the boot guard — in one place, `local/runs/`. No new host footprint.
- **A record never changes a run.** Same output on screen, same exit code,
  same prompts; a full disk or an unwritable record does not stop the run.
- **The bundle holds nothing secret and is read before it leaves.** Built
  from an allowlist, checked against every secret the stack knows, written
  as one plain-text file the owner reads first. Nothing is ever sent by the
  script.
- **No new settings.** Fixed retention, no `.env` keys.

## Run records

### What is recorded — **proposed**
One file per run: `local/runs/<YYYYmmdd-HHMMSS>-<verb>-<pid>.log`, mode
0600, owned by the repo's owner (`repo_owned`, as for everything in
`local/`), git-ignored with `local/`.

```
# mediastack run
verb:     wire --dry-run
commit:   5e146a8 (unstable)
by:       terminal | panel | timer mediastack-people | boot guard | other
started:  2026-11-12T21:46:32-08:00
---
…everything the run printed, stdout and stderr, colours stripped…
---
exit:     0 after 412s
```

- **by** is read, not guessed: a terminal on stdin; `SUDO_USER=olivetin` for
  the panel (its wrapper runs `sudo -n mediastack.sh …`); the unit's name from
  `scheduled_run`'s cgroup for a timer or the boot guard; `other` otherwise.
- **No footer means it never finished** — killed, an SSH drop, a reboot.
  Doctor names such runs from the last 7 days ("wire started 21:46, never
  finished").
- **Prompts are recorded, typed answers are not.** Only output is captured;
  stdin never is, so a typed password cannot reach a record.

### Verbs whose output is a secret — **proposed**
`credentials`, `invite`, `reset-password` and `set-credentials` print logins,
invitation links or sign-in links. Their record keeps the header and the
footer only (`output: not recorded — it prints secrets`). A column in the
verb registry says so, and CI holds the list: a verb that prints a stored
secret without being marked fails.

### How — **proposed**
In `main()`, before the verb runs: stdout and stderr each go through
`tee -p -a` into the record, back to their own stream. Two streams, not one,
so a verb whose stdout is read by a program (`list --json`, for the panel)
gets exactly the bytes it got before; the cost is that a line on stderr can
land a few lines out of order in the record. `tee -p`: a record that cannot
be written (disk full) is reported once and the run carries on.

Hidden complexity, each handled in the one function that sets this up:
- **The terminal checks move.** Colours and `DC`'s quiet pulls look at
  `[[ -t 1 ]]`, which turns false once stdout is a pipe. Both read a flag
  taken before the redirect, so an interactive run still gets colours and
  pull progress.
- **The last lines must not be lost.** At exit the streams are closed and
  both `tee`s waited for before the footer is written.
- **`upgrade` execs the new script.** The record's path and owning pid
  travel in the environment; a process that inherits them writes into the
  same record and opens none of its own, and the footer is written by the pid
  that opened it (`exec` keeps the pid). `sudo` drops the environment, so a
  `sudo mediastack.sh …` inside a run makes a record of its own — expected.
- **Root-made records.** Timers run as root; the record is handed to the
  repo's owner when it is opened.

### Retention — **proposed**
Pruned at each run's start: per verb and its options (`vpn-watch` and
`vpn-watch --full` count apart), the newest 20; a run that failed or never
finished is also kept for 30 days. The every-5-minutes timers (`vpn-watch`,
`frontdoor-refresh`) therefore hold 20 records each, and a failure is never
pruned within a month by routine runs. Worst case is a few MB.

### The failure notice — **proposed**
`unit-failed` quotes the last lines of the failed run's record instead of the
journal: the run's own words, without sudo's `COMMAND=` audit lines (which
carry home paths) — the 12 Nov notice showed four of them for one useful
line.

## The support bundle

### Usage — **proposed**
```
./mediastack.sh support [--logs SVC,...]
```
Writes `local/support/support-<YYYYmmdd-HHMMSS>.txt` (0600), opens it in a
pager when there is a terminal, then prints its path and size and says that
nothing was sent: the owner reads it and decides where it goes. One plain
text file, never an archive, so every byte can be read before it is shared.

### What goes in — an allowlist — **proposed**
1. **The install:** commit and branch, `ENV_SCHEMA`, OS and kernel, Docker and
   compose versions, CPU count, memory, free space on each root.
2. **Settings:** the `.env` keys the schema marks as not secret, nothing else.
   A key the schema does not know is listed by name only.
3. **The stack:** enabled services, each container's state, health, image and
   the version it reports (`status`); the stack's timers and failed units.
4. **`doctor`**, run fresh (read-only).
5. **Run records:** the newest 10, plus every failed or unfinished run from
   the last 7 days; each cut to its last 400 lines.
6. **Container logs only when asked:** `--logs jellyfin,authentik` adds each
   one's last 300 lines. Apps log people's activity (titles, client
   addresses), so none are included by default.

### Redaction — **proposed**
Applied to the whole file after it is assembled:
- **Every secret the stack knows** — each `.env` and `local/state` value the
  schema types as a secret — becomes `<secret:KEY>`, wherever it appears.
- **The domain** becomes `example.test`, keeping its names
  (`portal.example.test`). E-mail addresses become `<email-1>`, `<email-2>`.
- **Public IP addresses** become `<ip-1>`, `<ip-2>`…, the same address always
  the same token, so "the tunnel exits at `<ip-3>`, not your ISP's `<ip-1>`"
  still reads. Private ranges (LAN, the stack's networks) stay: they explain
  routing and identify no one. The ISP's name and AS number recorded in
  `local/host-identity` become `<isp>`.
- **Paths and names:** the host user's home becomes `~`, the host user's name
  `<user>`, the host name `<host>`. Webhook and other credential-bearing URLs
  keep their host only (`https://discord.com/<redacted>`).
- **Kept:** the portal's usernames, which are often the point of the question
  (agreed Nov 2026: no personal data beyond necessities like usernames).

Then a final check, fail-loud: if any secret value still appears in the file,
the bundle is deleted and `support` stops naming the key it found. The
allowlist decides what goes in; this check only proves the redaction held.

## Out of scope
- **Sending the bundle anywhere.** No upload, no paste service: the owner
  shares the file however they choose.
- **`logs` with a longer view** (`--tail N`): a small change to `logs`, not
  part of this design; noted for the batch after it.
- **A `runs` listing verb.** `ls local/runs` and the records' names are enough
  until someone asks for more.

## Tests (CI)
- A run is recorded: header, the output both streams carried, the footer with
  the real exit code; a failed and a killed run look as described.
- An interactive run keeps its colours and pull progress; a verb's stdout is
  byte-identical with and without the record.
- A record that cannot be written leaves the run's output and exit code
  unchanged.
- `upgrade`'s exec continues one record, with one footer.
- Retention: 20 per verb, failures kept 30 days.
- The secret-printing verbs record no output; an unmarked verb that prints a
  stored secret fails CI.
- The bundle from a fixture install with planted secrets, domain, public
  addresses, e-mails, home path and webhooks contains none of them; a planted
  secret the redaction misses deletes the bundle and fails loud.

## Live proof (anzac4)
An install from `base-cert` with the answers file, then: the records of
`install`, a timer and a panel action read back; `support` on that install,
read through by eye, with `grep` for the domain, the tokens and the home path
coming back empty.

## Build order
1. Run records (capture, header and footer, retention, the secret-printing
   verbs) — proven live before step 2.
2. The failure notice from the record; doctor's unfinished runs.
3. `support`: allowlist, redaction, the final check, the pager.
