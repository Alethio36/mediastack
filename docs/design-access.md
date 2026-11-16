# Design: access per tool, and app passwords

*Status: MVP plan step 5. Part 1 (app passwords) **agreed** 15 Nov 2026
after a live spike; slice 1 (the website refuses them) built and proven
live 15 Nov 2026; slice 2 (the switch) built and proven live 15 Nov 2026;
slice 3 (`signout`) built 16 Nov 2026 after its live check, to prove live;
slice 4 not built yet. Part 2 (tiers, an authentik provider per
app, grants) designed in outline 9 Nov 2026 (roadmap, "Access per tool") — its
details are agreed here before it is built. Portal mode only: with Wizarr or
no accounts, each app keeps its own logins and none of this applies, except
`signout`.*

## Why

- **A TV should not hold the household password.** Typing your one password
  into a smart TV's Jellyfin app means anyone who gets at that TV, or its
  settings backup, has your portal account. A per-device password that can be
  revoked on its own fixes that.
- **The portal's website already accepts app passwords** (found in the
  spike, below): any portal user can make one today, and it signs into the
  website as them, not only into Jellyfin. A second, quietly made way into
  the account — closed whatever else is decided.
- **Two levels of access are too coarse** (part 2): `admins` get every admin
  tool, `media-users` the household front end; one person cannot get Sonarr
  without qBittorrent.

## Spike (15 Nov 2026, anzac4, authentik 2026.8, portal install at a29d1f3)

One ordinary user (`spikeuser`, joined by invitation, in `media-users`), one
app password (`spike-tv`). Binds straight at the LDAP outpost
(`ldapsearch` of the user's own entry — the outpost does not support
`ldapwhoami`'s extended operation: "Protocol error (2)", whatever the
password).

| Question | Result |
|---|---|
| An ordinary user can make one | **yes** — Settings → Credentials → Tokens and App passwords → New App Password |
| How long it lasts | the form starts at **30 minutes**; the most it accepts is **1 day** ("Token expires exceeds maximum lifetime") |
| The limit can be raised | **yes** — `goauthentik.io/user/token-maximum-lifetime: days=365` on the `media-users` group: a year accepted |
| An LDAP bind accepts it | **yes** (and the main password, as before) |
| Jellyfin accepts it | **yes** — signed in as `spikeuser` |
| The portal's **website** accepts it | **yes** — signed in as `spikeuser` |
| After deleting it: the next bind | **refused at once** (`Invalid credentials (49)`) |
| After deleting it: a device already signed in to Jellyfin | **still signed in** (Jellyfin keeps its own session) |
| After deleting it: the main password | works, for Jellyfin and the bind |

Not seen: a *new* Jellyfin sign-in with the deleted password (its key was
lost with it). Jellyfin's sign-in is the bind that was refused; the build's
proof checks it directly.

From authentik's source (`version-2026.8`), which explains the table:

- The limit is the system setting `default_token_duration`, whose default in
  the code is `days=1` (the docs still say 30 minutes; the 30 minutes is the
  form's starting value). `goauthentik.io/user/token-maximum-lifetime`
  overrides it, read through the user's **groups** too — so one line on a
  group covers everyone in it. Raising the system setting instead would
  lengthen every other kind of token as well: not done.
- "Never expires" (`goauthentik.io/user/token-expires: false`) is read from
  the user's own attributes only, not their groups, and not for superusers:
  per person. Not used — a year is enough, and nothing is set per person.
- An expired token is invisible to every lookup (authentik's manager for
  expiring objects excludes it), so it is refused the moment it expires — no
  wait for a cleanup job.
- authentik's default web sign-in (`default-authentication-flow`) checks
  passwords with four backends, `TokenBackend` among them — why the website
  took the app password. mediastack's LDAP bind has its own password stage
  (`mediastack-ldap-password`: `InbuiltBackend` and `TokenBackend`).

## Part 1 — app passwords: decisions, **agreed** (15 Nov 2026)

1. **The portal's website refuses app passwords, always.** `TokenBackend` is
   taken out of the default web sign-in's password stage
   (`default-authentication-password`); the other backends stay. Not behind
   the switch: it closes a gap that exists today.
2. **One switch, `LDAP_APP_PASSWORDS`, off by default** (`yes|no`).
   *Off*: the LDAP bind refuses them too — they work nowhere (a person can
   still make one in the portal; it opens nothing, and the how-to says so).
   *On*: the bind accepts them, and `media-users` and `admins` carry a
   maximum lifetime of a year. The year is fixed, not a setting.
3. **`signout <user>`** — a new verb: every Jellyfin session of that person
   ends (each of their Jellyfin devices removed). The second half of revoking
   a device, and useful on its own (a lost phone). A person deletes their app
   password in the portal; an admin runs `signout`. Works in every account
   mode. Reacting to a deleted app password by itself would need a listener
   for authentik's events — not in v1.
4. **The 30-minute default is documented, not changed.** It is the form's
   starting date in authentik's UI; the how-to says to set the expiry when
   making a device's password.

### How it is built — **proposed**

**Slice 1 — the website refuses app passwords** (*built and proven 15 Nov
2026*: `wire_authentik_web_tokens`, doctor's check in `_doctor_accounts`;
anzac4 — doctor failed, wire removed it, doctor passed, a second wire wrote
nothing; an app password refused at the website and the main password taken
there, the app password still taken by Jellyfin). The default password stage
belongs to authentik's own default blueprint. `wire authentik` sets its
backends through the API (read, drop `TokenBackend`, write back only if it
was there), and doctor fails while `TokenBackend` is in it ("an app password
signs into the portal's website").
*Found live during slice 2's proof (15 Nov 2026):* every apply of our
blueprint put it back — ours applies authentik's default brand first (for a
first start's order), and the default brand applies the default sign-in
flow. A wire undid it seconds later, but an apply the worker makes on its own
(a changed blueprint file after an `up`) left the website taking app
passwords until the next wire. So our blueprint now sets that stage's
backends itself, after the default brand (the other three as authentik lists
them); wire and doctor remain for authentik's default flow applied alone, on
an authentik upgrade.
*Proof:* an app password refused at the website; the main password still
signs in; an LDAP bind with the app password still accepted (the switch's
job, not this slice's).

**Slice 2 — the switch** (*built and proven live 15 Nov 2026*, schema 44).
`LDAP_APP_PASSWORDS` in authentik's `env.tsv` (`enum:yes|no`, default and
recommended `no`; asked by a full configure, and an answers key). Two ways
in, each where its object is owned:
- The LDAP bind's password step is mediastack's own blueprint object: its
  backends come from `!If` on a blueprint input, `MEDIASTACK_LDAP_APP_PASSWORDS`,
  which `up` writes as `yes` or empty (`AUTHENTIK_LDAP_APP_PASSWORDS`) —
  authentik's `!If` takes any text as true, and `!Condition` compares
  truthiness, not text, so "no" cannot be passed through. A change re-applies
  the blueprint (about four minutes — the known cost, step 11's audit).
- The year's limit is a group attribute, which the blueprint would set as a
  group's whole `attributes`, over any an admin added: so `wire authentik`
  merges it in through the API (set with yes, removed with no) and reads it
  back.

doctor reads the live step and both groups and names a mismatch with the
switch. The migration adds the key empty (no): an install that never asked
stops taking app passwords at Jellyfin, said once at the upgrade.
*Proof:* off — bind refused, Jellyfin refused; on — a year accepted in the
form, bind and Jellyfin accepted; deleting the password refuses the next
bind and the next Jellyfin sign-in.
*Proven live (15 Nov 2026, anzac4 at 34c14d8):* off — the bind refused (LDAP
result 49), Jellyfin refused; on — a year accepted in the form, the bind and
Jellyfin took the password, and `wire` afterwards printed no "now" (nothing
left to change); revoked — the bind refused (49), a fresh Jellyfin sign-in
refused.

**Slice 3 — `signout <user>`** (*built 16 Nov 2026*, to prove live). Any
account model: Jellyfin's users are there in each.
*Live check first (16 Nov 2026, anzac4, spikeuser on Chrome and Jellyfin for
Android):* `DELETE /Devices?id=` (204) ends exactly that device's session —
Chrome went to sign-in on its next click while the phone, same person, kept
working; the phone's own removal left it refused (its session never came
back), spinning until the app was closed and reopened, then at sign-in; the
admin's Seerr and `mediastack-wire` devices untouched; signing in again works.
*Read in Jellyfin's source (v12.4), before building:* `GET /Devices?userId=`
is **not** the person's devices — it lists every device they may use, which
by default is all of them, so "list by userId, remove each" would have signed
out everyone, Seerr included. Each `/Devices` entry is one sign-in, owned by
its `LastUserId`. And removing a device ID ends every sign-in on that ID,
whoever's.
*Built:* the whole list, the person's own entries (their `LastUserId`), each
device ID removed once (URL-encoded: a browser's ID is base64 and may hold
`+ / =`), then the list read back — any of theirs left is a failure with
Jellyfin's code. A device ID that also holds someone else's sign-in is
removed anyway and the other person named (skipping it would leave the
person signed in, which `signout` exists to end). The stack's own Jellyfin
admin is refused (Seerr and wire sign in as it); none signed in is not a
failure. The password is not changed, and the closing line says what does
keep them out in that account model.
*To prove live:* `signout spikeuser` with Chrome and the phone signed in —
both out, the admin's two devices kept, the count 2.

**Slice 4 — the how-to.** README: making a device's password (set the expiry;
one per device; its name says which), revoking one (delete it, then
`signout`), what `LDAP_APP_PASSWORDS` changes.

**Not doing:** app passwords limited to one app (authentik binds them to the
person, not an app); automatic `signout` on deletion (needs an event
listener); changing the form's starting date.

## Part 2 — access per tool (outline of 9 Nov 2026; details to agree next)

Two tiers, **`frontend`** and **`admin`** — the groups, renamed from
`media-users`/`admins` by an `upgrade` migration, and each service's default
(a label in its folder, moved with `access tier <svc> frontend|admin`).
Grants per person outside their tier (`access grant|revoke <user> <svc>`,
groups `app-<svc>`; `access list`). An app admits its tier's group or its
own. That needs an authentik application and provider per gated app
(database objects served by the same outpost — no new containers) in place
of the one domain-wide provider, which decides once at sign-in and so cannot
tell apps apart. Moving a download or settings tool to `frontend` warns.

Every gated route changes, so it is proven on a keeper install's `upgrade`
(a portal install made from `stable` before this lands), not only a clean
install.

To settle before building it: the rename's reach (Jellyfin's LDAP filter,
Navidrome's household gate, the panel's portal sign-in, `reset-password`,
`invite`, doctor and every message that names the groups); what a person
removed from a tier keeps until their next sign-in (the outpost's sessions);
the order of the upgrade migration against a running portal; and whether
app passwords (part 1) follow the tiers (`frontend` only?) once they exist.
