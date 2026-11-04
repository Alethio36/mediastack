# Design: ask once, then install — and services that describe themselves

*Status: agreed (Nov 2026), being built one patch at a time (the order is in
the session handoff). Built so far: the questionnaire's own process, quick or
full, its exit codes and test-questions (2a); the `<n>_questions` hook, with
Traefik's questions (the token and the domain's zone checked with Cloudflare
as it is pasted) and Jellyfin's server name moved in, library names dropped
(2b). Sections marked **agreed**
were settled one by one before the whole was.*

## Goals

- **Ask once, at the start.** Every question comes in the first minutes; then
  the stack installs, starts and wires itself while the operator walks away.
  Today `up`, `wire` and `trash-sync` stop to ask between long waits.
- **Safe to re-run, step by step.** A dropped SSH session, a failed step or a
  second `configure` never leaves a half-built stack: running it again checks
  what is done and does only what is missing or wrong.
- **Fail loud, with the next step.** A step that fails stops the run and says
  exactly what to run next. A missing answer is always the same error:
  `X is not set — run: ./mediastack.sh configure`.
- **A new service is a new folder.** What a service is, asks, wires, shows and
  checks lives in `services/<name>/`; the core finds it there and never names
  it (the service contract, below).

## The flow

```
install ──> "Configure now? [Y/n]" ──> configure        (agreed: install carries on into configure)
                                         │  1. the questionnaire (asks, records — nothing else)
                                         │  2. provisioning (users, folders, timers, host record)
                                         │  3. the summary (secrets in outline)
                                         ▼
               first run:  "Start everything now? [Y/n]"     re-run on a live stack:  "Apply the changes now? [y/N]"
                                         │
                                         ▼
                     the chain:  up ─> panel ─> wire ─> trash-sync
                                         │  (stops at the first failure, names what is left)
                                         ▼
                     the closing to-do and validation
```

- **First run** (nothing installed): Enter starts everything. **agreed**
- **Re-run on a live stack** (to change one thing): every question shows the
  current answer as its default, secrets keep theirs unless a new one is
  pasted, and the closing question defaults to **No** — the stack is serving
  people, and applying restarts things. **agreed**
- **No separate chain verb.** Answering No (the test box, before dropping a
  certificate in) leaves the three steps to run by hand: `up`, then `wire`,
  then `trash-sync`. **agreed**

## The questionnaire

**agreed:** its own script, called by `configure`. It asks and records — and
does nothing else.

- **Where:** `lib/questionnaire.sh`, run by `configure` as its own process. It
  shares `lib/common.sh`'s prompt helpers (one way to ask each kind of
  question) and `lib/env.sh`; it does not copy them.
- **What it may touch:** `.env`, and `local/state` for the one-shot answers.
  No sudo, no Docker (rendering the catalogue aside), no users or folders —
  `test-questions` runs it with failing shims for each and fails on any call.
  What used to happen between questions now happens after them, in
  `configure`: a folder answer is held in `local/state` and applied there
  (made, its contents moved as answered, its mount recorded) — a cancelled
  run never leaves `.env` pointing at a half-moved folder; the panel is
  installed and the portal's reset link follows new email settings after
  provisioning.
- **Who asks what:** the shared questions (below) are the questionnaire's own;
  every service's questions are its folder's `<name>_questions` hook, asked in
  wire phase order for the enabled services (the service contract). A service
  with nothing to ask has no hook.

### Only what applies **agreed**

- **Services first.** The preset (or the custom picks) is asked first and its
  dependencies resolved (`resolve_deps`); a service's questions are asked only
  when it is enabled — no Sonarr, no TRaSH profile for it; no Wizarr, nothing
  about Wizarr.
- **Shared questions follow the answers before them:** no VPN service, no VPN
  provider or token; no Traefik, no domain or certificates; no portal, no
  email; a certificate of your own, no Cloudflare token. The logins question
  lists only the enabled services' accounts.
- **A service enabled later asks its questions then** (below): nothing is lost
  by leaving one out at install.

### Quick or full **agreed**

The first question:

```
How much should configure ask?
  1) quick   only what has no sensible default — your VPN token, your
             domain and its Cloudflare token, the certificate email, the
             notification URLs; everything else takes the recommended answer
  2) full    every question, each with its recommended answer as the default
Choice [1]:
```

- Every question declares whether it has a safe default. One that does not (a
  token, a domain) is asked in quick too — quick never guesses. The services
  and the sign-in model are the stack's shape: quick asks them on a first
  run, and keeps them on a re-run.
- Quick on a re-run keeps every answer, a schedule set to never included; a
  first run (a `.env` whose questions were never all answered) takes the
  recommended ones.
- Quick on the standard preset is five or six questions; folders, timezone,
  schedules, logins (generated), the server name and the TRaSH profiles
  (1080p) take their recommended answers.
- The summary shows every answer, the defaulted ones too. Something wrong:
  answer No to "Start everything now?", run `configure` again in full — the
  answers so far are the defaults, so Enter carries through the rest.

### A service enabled later **agreed**

`enable <svc>` is the questionnaire and the chain for one service:

1. Its questions: the same `<name>_questions` hook the install runs.
2. Its login, in the mode chosen at install — recorded in `.env`
   (`STACK_LOGINS=generated|unified|each`): generated → a random password;
   each → asked; unified → the shared password. If the shared password fails
   the new service's own rule, `enable` says so and offers
   `set-credentials` to change it everywhere, rather than quietly breaking
   "unified".
3. Applied as the chain does: `up` (the leak gate first — `enable` already
   ends with `up`, Nov 2026), then `wire` for it and for what calls it, then
   trash-sync when it is an arr.
4. Disabled and enabled again: its answers are still in `.env`, the defaults.

### What is asked, and where it moves from

| Asked today by | Question | In the design |
|---|---|---|
| configure | timezone, folders, services, accounts, VPN, tunnel, schedules, email, panel | stays, the shared part |
| `up` (traefik-setup) | domain, certificate email, Cloudflare token, production/staging | Traefik's `traefik_questions`; **the token is verified when it is pasted** (Cloudflare's token-verify call), not after the image pulls |
| `wire` | "take a restore point first?" | **not asked**: the first wire always takes one (it defaulted to Yes) |
| `wire` | the stack's own logins (download clients, arrs, Jellyfin admin, Audiobookshelf and Kavita roots) | one question, the logins mode (below) |
| `wire` | Jellyfin server name | Jellyfin's `jellyfin_questions` |
| `wire` | Jellyfin library names (×5) | **not asked**: the defaults; renamed in Jellyfin if wanted. Also fixes a run without a terminal skipping library creation |
| `wire` | notification URLs (ops, users) | Apprise's `apprise_questions`, held one-shot (below) |
| `trash-sync` | the TRaSH profile per instance | Recyclarr's `recyclarr_questions` (already `.env` keys) |
| `wire wizarr` | the Wizarr API key | **stays interactive** — Wizarr's UI must exist first; it becomes a closing to-do |

### The stack's own logins **agreed**

These are the installer's and the bots' accounts; the household's admin makes
their own account in the portal (authentik). **One username for all of them**,
asked once (default `admin`); then one question for the passwords:

```
The stack's own logins — the download clients, the arrs, Jellyfin's admin,
Audiobookshelf's and Kavita's roots:
  username [admin]:
  passwords:
  1) generated   a random password for each (recommended)
  2) unified     one password for all of them — one leaked password then
                 opens every one
  3) each        typed for each, one at a time
Choice [1]:
```

Each account is declared by the service that owns it (`<name>_logins`: its
username and password keys, and its password rule), so the list is the
enabled services', not a central one. With sign-in **none** (no portal) the
operator signs in with these logins directly — the case unified exists for.

**The portal reserves the name.** Jellyfin, Audiobookshelf and Kavita keep a
local account for the stack and make a person's account on their first
portal sign-in; a person joining under the stack account's name could be
taken for it ("sign up as its name and you are root", Audiobookshelf). Two
guards hold already: Audiobookshelf never matches a sign-in to an existing
account (`authOpenIDMatchExistingBy: null`; wire undoes a root linked
before), and the portal's join flow refuses a reserved username, any case
(`mediastack-join-username-free`, fed from `MEDIASTACK_RESERVED_USERNAMES`).
With one username, that name is reserved, so the two roots use it too — the
`mediastack` they have today was a habit, not a need. The guard covers the
join flow; a user an admin makes by hand in authentik's own screens is that
admin's deliberate act, outside it. In the contract, `<name>_logins` says
whether its account's name must be reserved, and authentik builds the list
from those (today: three names in its compose file).

### Checking the answers **agreed**

Every question declares its check, and a refused answer is said and asked
again (`ask_valid`, the one-way-to-ask convention):

- **No accidental blank:** a required answer refuses an empty one — a stray
  Enter cannot empty it. Where Enter means something (keep the current value,
  accept a generated one), the prompt says so.
- **Formats:** domain, email, URL, path (no backslash), time — as configure
  checks some of them today.
- **Typed passwords:** entered twice; at least 12 characters; no whitespace
  and none of `$`, `"`, `'`, `\` or the backtick — they break `.env` and compose's interpolation.
  On top, each service's own rule from `<name>_logins` (Kavita, for one, has
  a password policy of its own): a **unified** password must pass every
  enabled service's rule, so one answer cannot break one app.
- **Pasted secrets:** terminal escapes and control characters are taken out,
  and said (shipped, Nov 2026); tokens are verified where the service can be
  asked (Nord's, Cloudflare's).

### One-shot answers

Notification URLs are held in `local/state` (0600), handed to Apprise by
`wire apprise`, then deleted: a `.env` copy would drift from Apprise, which
`notify set` edits. **agreed**

### The prompts

The one-way-to-ask convention (`test-prompts`) holds for every hook; the
TRaSH prompt's missing newline (a `::` line glued to the answer) is fixed on
the way. **agreed**

## The chain

| Step | Re-run safety (what it checks first) | To prove in the build |
|---|---|---|
| `up` | renders, starts what is not running, recreates what changed, the leak gate before the VPN group | already re-run nightly by backups; the gate proven by three soaks |
| panel install | the `olivetin` user, key, sudo rule and config exist and match | re-run on an installed panel changes nothing |
| `wire` | every role compares before it writes (`wire --verify` is the same code without the writes) | a second `wire` right after the first reports no changes |
| `trash-sync` | recyclarr is idempotent; the sentinel banners are created once | a second run reports no changes |

- **A dropped SSH session:** before it starts, the chain checks for an SSH
  session outside tmux or screen (`SSH_CONNECTION` set, `TMUX` and `STY`
  not) and says so: the time to expect (~15–20 min) and that running
  `./mediastack.sh configure` again carries on. **agreed** (a background
  systemd job was considered and rejected: root context and terminal
  handling for no gain over re-running)
- **A failed step** stops the chain; nothing is undone. The message names the
  failure and every step still to run, in order. **agreed**
- **The end:** one ops notification when the chain finishes (Apprise was
  wired in the chain), and the closing to-do.

## The closing to-do and validation **agreed**

After the chain, on the screen:

- **Verified:** `doctor` (its FAIL lines, if any, with their fixes) and
  `leak-test` (passed, or what is UNPROVEN).
- **Still yours to do:** create your own admin account in the portal (or
  invite yourself); the Wizarr API key (`./mediastack.sh wire wizarr`) when
  Wizarr is on; `./mediastack.sh email test <address>` when email is set; the
  LAN DNS record (`*.<domain>` → this host) — needed to reach the services by
  name, not for the certificates.
- **Where things are:** `./mediastack.sh credentials`, `status`, the panel's
  address.

## Certificates

The certificate question gets a third answer:

1. **Let's Encrypt through Cloudflare** — as today (DNS-01: nothing is opened
   to the internet).
2. **Your own certificate.** Two files you provide:
   - `config/traefik/certs/fullchain.pem` — the certificate followed by its
     chain, PEM; it must cover the domain and the wildcard (`<domain>` and
     `*.<domain>`), since every service has its own name under it;
   - `config/traefik/certs/privkey.pem` — its private key, PEM, unencrypted
     (Traefik cannot ask for a passphrase); mode 600.
   Traefik serves them through its file provider; replace both files to
   renew (Traefik reloads them on change). **Renewal is yours:** doctor warns
   30 days before expiry and fails at 7, and `safety-live` already reads the
   served certificate's dates. `docs/certificates.md` says all of this, with
   the commands to check a pair before using it (the build writes it).
3. **Staging** — Let's Encrypt's test certificates, for test installs.

Other DNS providers for Let's Encrypt: after the MVP (roadmap, Portability).

## The service contract

**agreed** in shape. A service's folder describes it completely; the core
crawls `services/*/` and never names an app.

**Two kinds of service.** *Platform services* — gluetun, Traefik, authentik,
Apprise — are what the others plug into; the core may know them by name. *App
services* — the arrs, the download clients, the media apps — are only ever
found by crawling.

**Labels** (in the service's compose fragment, beside the ones that exist
today: `mediastack.vpn`, `.auth`, `.port`, `.errors`, …):

| Label | Says | Replaces |
|---|---|---|
| `mediastack.wire.phase` | when it is wired: 10 download clients, 20 arrs, 30 Prowlarr, 40 its consumers (Bazarr, Cleanuparr, Seerr), 50 the portal and Jellyfin, 60 the rest | `WIRE_ROLES` (lib/wire.sh) |
| `mediastack.calls` | the services it holds an address of, e.g. Bazarr's `sonarr radarr` | `WIRE_CALLERS` (lib/addr.sh), inverted by the core |
| `mediastack.preset` | the presets it is in (`standard`) | the preset list in lib/questionnaire.sh |

**Hooks** (functions in `services/<name>/<name>.sh`, found by name; none is
required):

| Hook | Does | Replaces |
|---|---|---|
| `<name>_questions` | asks its questions, records them | the questions in configure, `up`, `wire`, `trash-sync` |
| `<name>_logins` | its stack-owned account's username and password keys | the logins list |
| `<name>_wire` | wires it (today's role functions, renamed) | the dispatch in lib/wire.sh |
| `<name>_credentials` | prints its rows for `credentials` | the listing in lib/access.sh |
| `<name>_doctor` | its own checks | the named checks in lib/doctor.sh (some already are: `jellyfin_doctor_*`, `gluetun_doctor`) |

**Already drop-in today:** the compose fragment and its labels, the service's
`.sh` (sourced automatically), its settings schema (`services/<name>/env.tsv`,
defaults included, crawled by lib/env.sh), its dependencies (`svc_deps`).

**Stays central, on purpose:** the compose include list (compose cannot glob;
`new-service` will add the line, and test-render fails when one is missing),
the internal networks (compose refuses a network defined in one include and
joined from another), migrations (history), the panel (its own service).

**The order of the work:**
1. The questionnaire, built on `<name>_questions` and `<name>_logins` — the
   contract's first use, needed anyway.
2. After the MVP, one piece at a time: `<name>_credentials`; then the wire
   phase and calls labels with `<name>_wire`; then the preset label; then
   `<name>_doctor` for what remains central.
3. Each piece lands with a test that fails if the core names an app for it.

### How the questionnaire ends

It runs as its own process, so it tells `configure` how it ended by its exit
code — nothing else:

| Exit | Meaning | `configure` then |
|---|---|---|
| 0 | every question answered | carries on: provisioning, the summary, the closing question |
| 130 | cancelled (Ctrl-C) | stops; nothing is applied, the answers so far are kept as next time's defaults |
| 3 | no terminal to ask on (the panel, piped input) | stops: "configure asks questions — run it in a terminal" |

## Open, to decide during the build

- The order of the shared questions: kept organized, adjusted if something
  reads wrong in practice.
