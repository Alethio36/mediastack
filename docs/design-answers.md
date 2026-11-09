# Design: the answers file — configure, answered ahead

*Status: built (Nov 2026), steps 1–5; proven by scripts/test-answers.sh,
not yet on a live install. Builds on
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

- **Keys.** Every schema row whose `recommended` column is not `-`: the
  `.env` keys a question writes, and the answers file's own keys — rows with
  writer `answers`, which are never `.env`'s (doctor names one found there):
  the services (`ENABLE_<SVC>`), how people sign in (`SIGNIN`), the unified
  password (`STACK_PASSWORD`), the web panel (`PANEL`), the notification URLs
  (`NOTIFY_OPS`, `NOTIFY_USERS` — still one-shot through `local/state`), an
  input that becomes something else (`NORDVPN_TOKEN` -> the WireGuard key),
  the mode (`CONFIGURE_MODE`) and the closing question (`START`). One table
  holds every key of either file. An unknown key is an error — no typo
  tolerance, as for `.env`. **agreed**
- **Blank means "not answered".** A missing key, `KEY=` and a blank file are
  the same thing. **agreed**
- **Blank keeps what is set; the recommendation fills only what is not.** As
  quick does today: on a re-run, a blank leaves the current value alone, so
  a partial file never resets the settings it does not name. On a fresh
  install nothing is set, so a blank takes the recommendation. **agreed**

  | Answer                               | quick                   | full                         | no terminal          |
  |--------------------------------------|-------------------------|------------------------------|----------------------|
  | written                              | used                    | used                         | used                 |
  | blank, a value is set                | kept                    | asked, the value as default  | kept                 |
  | blank, nothing set, a recommendation | taken, and said so      | asked, recommendation as default | taken            |
  | blank, nothing set, `ask`            | asked                   | asked                        | listed as missing    |

  Optional questions (`skip`) keep today's quick behaviour with a terminal:
  the ones quick asks now (the notification URLs, the tunnel's token) are
  still asked, Enter leaving them unset; without a terminal they stay unset.
- **The services are answered as a whole.** If the file answers any
  `ENABLE_` line, the blank ones take the standard preset; if it answers
  none, the services question is asked (or, with no terminal, missing) —
  quick asks it today, and a file saying nothing about services must not
  install the preset silently. **agreed**
- **One yes/no rule.** Every yes/no question shows `yes | no`; the file takes
  `yes`, `no`, `y`, `n`, `true` or `false` in any case and records the form
  the key keeps (`true`/`false` for the email switches, which `.env` holds).
  Any other word (`on`, `1`) is refused, named. **agreed**
- **Paths are read as typed ones**: `~` is the user's home, a relative path
  is inside the repo folder. **agreed**
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

Recommended answers lived in code (`SCHED_UPDATE_RECOMMENDED`,
`TRASH_RECOMMENDED`, the `STD` list, `.env.example`'s folders). They moved
to one source that the questionnaire and the template both read. **agreed**

- **A `recommended` column** in `lib/env.schema.tsv` and in each service's
  `env.tsv` (a service owns its recommendations), before `meaning`. Its
  value is one of: **agreed**
  - `-` — not a question: the answers file has no such key;
  - `ask` — no recommendation, always asked (sign-in, the VPN details, the
    domain, a typed password);
  - `default` — the `default` column's value. Most recommendations are the
    default already (`STACK_USER`, `PORTAL_TITLE`, `TLS_SOURCE`, …), and a
    default is written once;
  - `skip` — optional, recommended left unset (email, the tunnel, the
    notification URLs);
  - `=text` — worked out by the questionnaire (the host's time zone, the
    backup an hour after the update, the first download client by
    priority); the text says how, for the template;
  - anything else — the value itself, checked against the key's type
    (`UPDATE_SCHEDULE` `Tue 04:00`, `TRASH_PROFILE_<arr>` `1080p`, the
    folders `./config` … — `.env.example` must suggest the same).
- **The standard preset is a label**, `mediastack.preset: standard`,
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
ENABLE_LIDARR=     # music — recommended: no
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

1. *Done:* the inventory, the `recommended` column and the preset label;
   quick reads the column (the folders, the update schedule, the TRaSH
   profile, the panel, the mode). No change in behaviour.
2. *Done:* `check` / `ask` / `record` for configure's own sections. A check
   prints why a value is refused and writes nothing; an answer with no check
   of its own is held to its schema type, one with no record is written with
   `env_set`. Checks: `root_problem`, `vpn_provider_problem`,
   `vpn_countries_problem`, `wg_addresses_problem`, `sched_problem`,
   `login_user_problem` / `login_pass_problem` (already split), the time
   zone's type; `nord_wg_key` turns the token into the key. Records:
   `services_record` (dependencies, conflicts, `COMPOSE_PROFILES`),
   `accounts_record`, `panel_record`. No change in behaviour, one tightening:
   a time zone with `/../` in it is refused, as `.env` already refused it.
3. *Done:* the same for the services' question hooks. Checks:
   `traefik_domain_problem` (with `cf_check` and `own_cert_problem`, already
   apart), `portal_title_problem`, `smtp_host_problem`,
   `smtp_password_problem` (and `smtp_problems` for the settings together),
   `jf_server_name_problem`, `trash_profile_problem`, `notify_urls_ok`.
   Records: `email_changed`, `notify_urls_record`, `cloudflared_off`. The
   logins' record waits for step 4: where a typed password comes from is the
   one thing the file changes there, so it is shaped then.
4. *4a done:* `configure --answers FILE` (lib/answers.sh). Pass 1 is the
   questionnaire itself on a scratch copy of `.env` and `local/state`, with
   nothing asked: each section takes its written answer, checks it and
   reports a refusal (`answer_refused`); where it would ask it calls
   `q_unasked` instead — asked in pass 2, or (no terminal) a missing answer.
   No check is written twice. Any question the check pass reaches without
   that guard stops it loud (`prompt_guard` in every prompt). A blank file
   key is quick; no terminal means quick, and `CONFIGURE_MODE=full` without
   one is refused. Names the questions take in any case (`SMTP_HOST`,
   `STACK_DOMAIN`, `VPN_PROVIDER`) are lowercased as typed ones are.
   Network checks (Cloudflare, Nord) run in both passes. Exit 4 with the
   list; configure applies nothing.
   *4b done:* `install` and `configure` take the same four options
   (`--answers FILE`, `--domain`, `--services a,b`, `--signin`; one parser,
   `answers_opts`), and `install` carries on into `configure` with them
   instead of asking. A flag is an answer over the file's; `--services` is
   the exact set (the file's `ENABLE_` lines give way, and it says so).
   Answers given and no terminal: sudo that would ask for a password is
   refused before anything starts (`sudo -v` first, or root). `START`,
   recorded by the questionnaire, answers configure's closing question;
   blank keeps its defaults. The file is read in two passes over the schema
   instead of three per line (test-answers: 65s to 27s).
   *After the first live run (anzac4, Nov 2026):* the yes/no rule and paths
   as typed (above); `TLS_CERT_FILE`/`TLS_KEY_FILE` are of a new `file` type
   (a file path, not a folder); with no terminal, compose pulls quietly
   (`up --quiet-pull`, `pull --quiet` — the per-layer lines had buried the
   install log); a written sign-in says so like every other answer.
5. *Done:* `answers.example`, written by `scripts/gen-answers.sh` from the
   schema (meaning, type, recommendation) and the labels (description,
   preset, own installer, arr type) on a throwaway render; CI runs it with
   `--check`. Sections: how configure runs, the services, sign-in, the
   stack, then each service's. A login's password says it is typed only
   with `STACK_LOGINS=each`. `answers*.env` is git-ignored.

## Not in v1

- A separate `--check`: pass 1 and configure's summary are the check.
- Secrets from the environment.
- Changing folders from the file on a live stack.
- The service preview before `install` has put Docker on the host
  (resolving dependencies renders through `docker compose`).
