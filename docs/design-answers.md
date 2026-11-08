# Design: the answers file — configure, answered ahead

*Status: agreed (Nov 2026), not built. Builds on
[design-install.md](design-install.md) (the questionnaire, quick and full,
each service's question hooks). Sections marked **agreed** were settled one
by one.*

## Goals

- **One path: `configure`.** The answers file answers questions ahead of
  time; whatever it leaves blank, configure takes the recommendation or asks.
  There is no separate unattended installer to keep in step. **agreed**

  | File    | Terminal | What happens                 |
  |---------|----------|------------------------------|
  | full    | none     | an unattended install        |
  | partial | yes      | only the gaps are asked      |
  | none    | yes      | today's `configure`          |

- **One check per question.** A typed answer and a written one go through
  the same check, so neither path accepts what the other refuses.
- **Fail loud, all at once.** Every problem in the file is listed in one
  error, before a single question is asked or anything is written.
- **A new service is a new folder.** A service's questions, keys,
  recommendations and its lines in the template come from its own folder.

## Usage

```
./mediastack.sh install   --answers FILE [--domain D] [--services a,b] [--signin none|wizarr|authentik]
./mediastack.sh configure --answers FILE [same flags]
```

`install` passes `--answers` and the flags on to the configure it carries on
into. A flag writes into the same answers before they are checked and wins
over the file. **agreed**

## The file

`.env` syntax: `KEY=value`, `#` comments, nothing else. **agreed**

- **Keys.** The `.env` keys a question writes, plus a few answers-only keys
  for answers that are not `.env` values: the services (`ENABLE_<SVC>`), how
  people sign in (`SIGNIN`), the web panel (`PANEL`), the notification URLs
  (`NOTIFY_OPS`, `NOTIFY_USERS` — still one-shot through `local/state`),
  inputs that become something else (`NORDVPN_TOKEN` -> the WireGuard key),
  the mode (`CONFIGURE_MODE`) and the closing question (`START`). The exact
  list comes from build step 1's inventory. An unknown key is an error — no
  typo tolerance, as for `.env`.
- **Blank means "not answered".** A missing key, `KEY=` and a blank file are
  the same thing. **agreed**

  | Answer                               | quick                   | full                         | no terminal          |
  |--------------------------------------|-------------------------|------------------------------|----------------------|
  | written                              | used                    | used                         | used                 |
  | blank, the question has a recommendation | taken, and said so  | asked, recommendation as default | taken            |
  | blank, no recommendation             | asked                   | asked                        | listed as missing    |

- **Empty is never an answer.** Keys where an empty value means something
  (`BACKUP_SCHEDULE=` = never, `VPN_SERVER_COUNTRIES=` = auto) take the
  question's word in the file: `never`, `auto`. **agreed**
- **The mode.** Blank `CONFIGURE_MODE` is quick: a file exists to skip
  questions. `full` asks every blank one.
- **Secrets** live in the file, which must be mode 0600 and owned by the user
  running it, or the run refuses. Never on the command line. Not from the
  environment either: two sources for one secret drift. **agreed**
- **Choices that exclude each other are one key**, not y/n rows: `SIGNIN`,
  `DOWNLOAD_CLIENT`. Other conflicts (Traefik and NPM) are caught by the
  `mediastack.conflicts` labels in the first pass. **agreed**

## Recommended answers: one source

Today recommended answers live in code (`SCHED_UPDATE_RECOMMENDED`,
`TRASH_RECOMMENDED`, the `STD` list, the values `q_took` reports). They move
to one source that the questionnaire and the template both read. **agreed**

- **A `recommended` column** in `lib/env.schema.tsv` and in each service's
  `env.tsv` (a service owns its recommendations). Its value is one of:
  a value; `-` for none (the question is always asked: services, sign-in,
  the VPN details); or `=` followed by a rule's text for one that is
  computed (the backup an hour after the update, the host's time zone) — the
  code computes it, the text goes in the template.
- **The standard preset becomes a label**, `mediastack.preset: standard`,
  replacing the hard-coded `STD` list in `_configure_services`. This reverses
  the earlier "not a label" choice: the list meant adding a standard service
  edited the questionnaire. `ENABLE_<SVC>`'s recommendation is read from it.
- **Not in the user's file.** The file holds only decisions. A release that
  changes a recommendation reaches every blank line; a copied recommendation
  would go stale and override it. **agreed**
- **Quick** takes the recommendation for a blank; **full** offers it as the
  prompt's default — the same column either way.

## The template

`answers.example`, committed, generated by `scripts/gen-answers.sh` from the
schema, the services' `env.tsv` files and their labels; CI fails when it is
stale, as `.env.example` is held to the schema. **agreed**

```
SIGNIN=            # none | wizarr | authentik — required, no recommendation
BACKUP_SCHEDULE=   # daily | weekly | never | a time — recommended: daily, an hour after the update
ENABLE_LIDARR=     # music — recommended: n
TZ=                # recommended: this host's time zone
```

Every line ships blank, its choices and recommendation in the comment. The
services section takes each service's `mediastack.desc`; a service set up by
its own command is left out, as custom mode skips it today.

## The run

**Pass 1 — check (nothing written).** Read the file and the flags; refuse
unknown keys and a readable-by-others file; run each answer's check in
question order, against the answers before it. A check that depends on a
refused answer says `not checked: depends on X` rather than being skipped.
Network checks run here too (the Cloudflare token and zone, the certificate
chain, the NordVPN token). Without a terminal, every blank question with no
recommendation is an error. Print the resolved services (`+ gluetun,
required by qbittorrent`) and any conflict. Any error: one list, exit
non-zero, nothing written. **agreed**

**Pass 2 — the questions.** A written answer is used and said so (`from the
answers file`); a blank one is taken from the recommendation or asked. Then
as today: provisioning, the summary, the closing question, the chain. The
closing question's answer is `START`; blank keeps today's defaults (first
run: start everything; a live stack: don't apply).

**A live stack.** A written answer acts like a typed one. The exception: a
changed folder needs the move-or-leave decision, so it is an error — change
folders with `configure`.

**Each question splits in three**, in `lib/questionnaire.sh` and the service
hooks:

- `check` — pure, shared: why a value is refused, or nothing;
- `ask` — the terminal only, looping on `check`;
- `record` — shared: writes the value. A menu records the value its number
  stands for, so the file holds values, never menu numbers.

## Around it

- **sudo.** Without a terminal, sudo cannot ask for a password: if it would,
  the run refuses before anything starts — `sudo -v` first, or run as root.
  **agreed**
- **Wizarr's API key** stays interactive (its UI makes it) and stays a to-do
  in the closing summary. **agreed**

## Tests (`scripts/test-answers.sh`, in CI)

- The same answers typed and written produce a byte-identical `.env` and
  `local/state`. **agreed**
- Every question has a key in the file (a registry check), and the template
  is current.
- Blank, missing and `KEY=` behave alike; `never`/`auto` record the empty
  value.
- A file others can read is refused; two refused answers are both listed.

## Build order

Each step touches more than three files — known and accepted for this work.

1. The inventory, the `recommended` column and the preset label; quick reads
   the column. No change in behaviour: test-questions' output is unchanged.
2. `check` / `ask` / `record` for configure's own sections.
3. The same for the services' question hooks.
4. `--answers`: the two passes, the flags, the secrets rule, the sudo refusal.
5. The template, its generator and CI step; README and docs.

## Not in v1

- A separate `--check`: pass 1 and configure's summary are the check.
- Secrets from the environment.
- Changing folders from the file on a live stack.
- The service preview before `install` has put Docker on the host
  (resolving dependencies renders through `docker compose`).
