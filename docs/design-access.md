# Design: access per tool, and app passwords

*Status: MVP plan step 5. Part 1 (app passwords) **agreed** 15 Nov 2026
after a live spike; not built yet. Part 2 (tiers, an authentik provider per
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

**Slice 1 — the website refuses app passwords.** The default password stage
belongs to authentik's own default blueprint, which re-applies when an
authentik upgrade changes it — two blueprints owning one object would fight.
So `wire authentik` sets its backends through the API (read, drop
`TokenBackend`, write back only if it was there), and doctor fails while
`TokenBackend` is in it ("an app password signs into the portal's website").
An upgrade that puts it back is caught by doctor and undone by the next wire.
*Proof:* an app password refused at the website; the main password still
signs in; an LDAP bind with the app password still accepted (the switch's
job, not this slice's).

**Slice 2 — the switch.** `LDAP_APP_PASSWORDS` in authentik's `env.tsv`
(recommended `no`; asked by a full configure, and an answers key).
The blueprint takes it as an input like its others: the LDAP password stage's
backends with or without `TokenBackend`, and the two groups' attribute set or
removed. A change re-applies the blueprint (about four minutes — the known
cost, step 11's audit). doctor reads the live stage and groups and names a
mismatch with the switch.
*Proof:* off — bind refused, Jellyfin refused; on — a year accepted in the
form, bind and Jellyfin accepted; deleting the password refuses the next
bind and the next Jellyfin sign-in.

**Slice 3 — `signout <user>`.** Jellyfin's API: the person's devices
(`GET /Devices?userId=`), each removed (`DELETE /Devices?id=`), which ends
its session. The stack's own Jellyfin admin is refused (Seerr signs in as it).
Reports how many devices were signed out; none is not a failure.
*To prove first, live:* removing a device ends that device's session on its
next request (web and one app), and touches no other person's.

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
