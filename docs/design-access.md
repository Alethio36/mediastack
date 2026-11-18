# Design: access per tool, and app passwords

*Status: MVP plan step 5. Part 1 (app passwords) **agreed** 15 Nov 2026
after a live spike; slice 1 (the website refuses them) built and proven
live 15 Nov 2026; slice 2 (the switch) built and proven live 15 Nov 2026;
slice 3 (`signout`) built and proven live 16 Nov 2026; slice 4 (the how-to)
written 16 Nov 2026 — part 1 done. Part 2 (tiers, an authentik provider per
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

**Slice 3 — `signout <user>`** (*built and proven live 16 Nov 2026*). Any
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
*Proven live (16 Nov 2026, anzac4 at fe1d3d7):* first, `?userId=` for
spikeuser listed the admin's Seerr and `mediastack-wire` devices too — the
source read was right. `signout spikeuser` with Chrome and the phone signed
in: "signed out of 2 device(s)", the admin's two devices kept (so the device
list's `LastUserId` matches `/Users`' `Id`), Chrome at sign-in on its next
click, the phone at sign-in on reopening; `signout admin` refused.

**Slice 4 — the how-to** (*written 16 Nov 2026*, README, "A device's own
password"): making a device's password (set the expiry;
one per device; its name says which), revoking one (delete it, then
`signout`), what `LDAP_APP_PASSWORDS` changes.

**Not doing:** app passwords limited to one app (authentik binds them to the
person, not an app); automatic `signout` on deletion (needs an event
listener); changing the form's starting date.

## Part 2 — access per tool (outline of 9 Nov 2026; decisions **agreed** 16 Nov 2026)

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

### Decisions, **agreed** (16 Nov 2026)

Read in authentik 2026.8.5's source and checked live on anzac4 first.

1. **The rename happens inside the blueprint, in place.** Our blueprint
   finds each group by its name, so a blueprint that simply said `frontend`
   would make a new, empty group and bind the gate and the LDAP bind to it:
   every admin locked out of the tools, every Jellyfin sign-in refused.
   Instead each group gets one entry more, before its own: with a per-entry
   condition (`conditions:` — skipped while false; `!Find` gives nothing when
   no object matches), *a group named `media-users` exists → rename it to
   `frontend`*; likewise `admins` → `admin`. Same group object, so its
   members, its bindings, its attributes (part 1's year limit) and anything
   an admin bound to it in authentik's UI stay. A fresh install skips the
   rename and gets the new names. The rename entries stay; they cost nothing.
2. **The rename's reach — one patch, together:** the blueprint (groups, the
   admin gate's binding, the LDAP bindings, sign-up's group); Jellyfin's LDAP
   filters and admin sync; the admin syncs of Kavita, Audiobookshelf and
   Navidrome; the panel's `matchUsergroups`; Navidrome's household gate
   label; doctor, messages, tests, fixtures and docs. Outside the stack,
   anything set up by hand that matches a group by its *name* (a user's own
   LDAP or OIDC app) — the upgrade says so once.
   **Every reader of a group by name checks the group exists first and fails
   loudly if not.** authentik's user list already refuses an unknown group
   name (`groups_by_name` is a validated choice), but Navidrome's 15-minute
   sync reads each person's group names: between `upgrade` (new code on disk)
   and the rename's apply it would find nobody in `admin` and demote every
   Navidrome admin, silently.
3. **Order against a running portal:** `upgrade` changes nothing in
   authentik — the blueprint reaches the worker only when `up` or `wire`
   copies it into the config root (`authentik_blueprints_sync`; the worker
   watches only that folder). The rename lands in that apply; `wire` waits
   for it, then rewrites Jellyfin's filter and the panel's groups in the
   same run. New Jellyfin sign-ins are refused only between the rename and
   `wire jellyfin` (seconds); sessions already open are untouched.
4. **Taking access away ends the person's portal sessions.** *Live
   (16 Nov 2026, anzac4, Navidrome's household gate):* spikeuser removed from
   `media-users` with Navidrome open — Navidrome kept working, also after two
   minutes; their portal sessions deleted (authentik's admin: the user →
   Sessions) — the next request was refused. The outpost decides when a
   session starts, and ending the authentik session ends the outpost's. So
   `access revoke`, `access tier` moving someone's access away, and taking
   a person out of a tier end that person's portal sessions through
   authentik's API; when the change takes Jellyfin away, `signout` too.
   They sign in again to whatever they still have. A group changed by hand
   in authentik's UI ends no session — the README says to end them there too
   (the user → Sessions).
5. **App passwords and tiers: no new rule.** An app password opens only
   Jellyfin's LDAP bind, which admits whoever Jellyfin admits. The year
   limit goes on every group that admits Jellyfin: `frontend`, `admin`, and
   `app-jellyfin`.
   *Corrected by decision 9 (16 Nov 2026):* the gate takes them too, sent
   as HTTP Basic, for whatever their owner may open — so the same rule
   holds: an app password reaches what its owner reaches, no more.
6. **`admin` includes everything `frontend` has** — as today, where Jellyfin
   and Navidrome's household gate admit both groups. An admin is a household
   member who also gets the tools; nobody needs to be in both, and taking
   someone out of `frontend` never leaves an admin locked out of Jellyfin.

7. **A provider per gated app, `mediastack-app-<svc>`** — forward auth for
   that app's one address, the kind Navidrome's household gate already is
   (`mediastack-house-navidrome`, renamed to it in place). Its rule lives on
   the app's dashboard card (an authentik application, slug
   `mediastack-app-<svc>` for every app; the tools' old `mediastack-tool-*`
   cards go): the provider plus bindings to its tier's group and
   `app-<svc>`. One object says both who may open the app and whose
   dashboard shows it. The `app-<svc>` groups are made by `wire`, one per
   gated app, empty until a grant. Traefik does not change: the outpost picks
   the provider by address (proven live: a non-admin opened Navidrome while
   the domain-wide gate admits admins only). The domain-wide `mediastack-gate`
   stays as the catch-all: an address without a provider of its own admits
   admins only — a gap refuses, it never opens. Apps that sign in their own
   way follow the same rule later: Kavita's and Audiobookshelf's OIDC
   applications get the same bindings; Jellyfin's filter becomes `frontend`,
   `admin` or `app-jellyfin`; Seerr follows Jellyfin.
   **An authentik application with no bindings admits everyone signed in.**
   So per app, in this order: the provider made (not on the outpost); the
   card given the provider and its bindings; the bindings read back; only
   then the provider put on the outpost. doctor fails any of our cards that
   carries a provider and has no binding.
8. **`access`, the verb.** `access list` — every gated app: tier, who has it
   by grant, address. `access list <user>` — what that person can open and
   why (tier or grant). `access grant <user> <svc>` — into `app-<svc>`;
   says "spikeuser can now open Sonarr (granted)". `access revoke <user>
   <svc>` — out of it, their portal sessions ended (and `signout` for
   Jellyfin); refused, and said why, when the person has the app through
   their tier. `access tier <svc> frontend|admin` — the choice kept in `.env`
   as `<SVC>_TIER` (a family key; the service folder's label is the default);
   a download or settings tool moved to `frontend` warns what the household
   could then do and asks (`--yes` for no question); a move to `admin` ends
   the portal sessions of everyone who loses the app, and says how many.

9. **The arrs' API goes behind the gate** (*agreed 16 Nov 2026*, after the
   spike below). Until now the `/api` path of the arrs, Prowlarr and Bazarr
   skipped the gate (`mediastack.auth.bypass`) so companion apps worked with
   the API key alone. That key is one secret for everybody: the app's own
   page holds it, so anyone who ever opened the app could keep it and use it
   from anywhere, whatever `access` later says. *Found live (16 Nov 2026,
   slice 3):* spikeuser, moved off Sonarr by `access tier sonarr admin`
   with Sonarr open, added a show from the tab already open — the page's
   own calls go to `/api` with the key — until a reload met the gate. So
   the bypass goes from those seven (sonarr, sonarr-anime, radarr,
   radarr-4k, lidarr, prowlarr, bazarr); their whole address is behind the
   gate. A phone app sends the API key and a **device password as HTTP
   Basic** (`Authorization: Basic <username:app password>`, any app with a
   custom-header setting), checked like the page: the card's bindings, so
   `access` decides the API too. Navidrome's `/rest/ /share/` stays past
   the gate: each music app signs in as its own person there, and a share
   is meant to be open — no shared secret. The stack's own calls (the
   script on `127.0.0.1:<port>`, the apps on `<container>:<port>`) never
   pass Traefik. A test refuses any `/api` bypass; `safety-live` proves each
   gated app's `/api` sends a signed-out caller to sign in.
   **Costs:** an app with no custom-header setting cannot reach the arrs
   from outside (no fallback, by design: rotating the key when someone
   leaves is the answer for that one app). A device password lasts a year
   only with `LDAP_APP_PASSWORDS=yes` (the switch also sets every group's
   app-password lifetime); with `no`, a day. Taking access away reaches a
   phone within 60 s (the outpost keeps a Basic sign-in that long), with
   no session to end. And an app password now opens more than Jellyfin: an
   admin's TV password opens the arrs' API — one per device, deleted with it.
   *Spike (16 Nov 2026, anzac4, authentik 2026.8.5, unstable 6548781,
   Sonarr's bypass removed by hand):* the API key alone — 302 to sign-in,
   from curl and from nzb360; key and Basic with spikeuser's app password
   and the grant — 200, and nzb360 connected (a custom header); the real
   password as Basic — 302 (app passwords only); grant taken away —
   refused 31 s later (curl) and 32–47 s later (nzb360); a Basic sign-in
   leaves no cookie; Sonarr's web page works with `/api` gated; doctor
   and `wire prowlarr` unchanged.

### How it is built

**Slice 1 — a provider per gated app, nobody's access changed** (*built
and proven live 16 Nov 2026*). Every
gated tool and Navidrome get the shape of decision 7 with today's groups —
the tools `admins` (+ `app-<svc>`), Navidrome `media-users` and `admins`
(+ `app-navidrome`). Proven on the keeper's `upgrade`: each app still opens
for exactly whom it did, and a person put in `app-<svc>` by hand gets that
one app.
*Proven live (16 Nov 2026, the keeper from `stable` 8e8e03f, upgraded to
`unstable` 85bad35):* `wire` gave every tool its gate, renamed Navidrome's
household gate in place and removed the old cards, with no failure; doctor:
every gated app on a gate of its own. akadmin opened every tool (Bazarr and
qBittorrent then show their own login — step 6's work, as before); spikeuser
was refused Sonarr and opened Navidrome and Jellyfin; put in `app-sonarr` by
hand, spikeuser opened Sonarr; taken out again with their sessions ended,
refused. *Found on the way:* the first try was refused by authentik — a
partial update of a proxy provider is checked as a full proxy unless it
names its mode (now always sent). And spikeuser's dashboard showed no Sonarr
card after the grant: authentik keeps each person's list of apps for 24
hours, cleared when a user, group, application or binding is saved — a
change of group membership alone saves neither (read in 2026.8.5's source).
So **slice 4's grant and revoke save the person once after changing their
groups**, which clears it; a grant made by hand in authentik's UI shows on
their dashboard only after that, or a day later (the README says so).

**Slice 2 — the rename** (decisions 1–3; *built and proven live 16 Nov
2026*). The blueprint renames each group in place by a
conditioned entry before the entry that finds it by its new name (its
importer applies entries in order, in one transaction); every reader goes
through `PORTAL_FRONTEND` / `PORTAL_ADMIN` (a test holds the blueprint's
names to them, another refuses the old names in code). `wire authentik`
rewrites the panel's config when it differs from what the stack writes for
the login it holds — the installed list named `admins`, which would have
shut every admin out of the panel after the rename. Navidrome's sync moves
admin rights only while the admin group exists. The upgrade (schema 45)
says the rename once. A group by the new name made by hand before the
rename makes the rename fail (names are unique): authentik reports the
blueprint failed, doctor shows it.
*First live try (16 Nov 2026) failed:* the rename entry found the old group
by its name, and authentik's importer merges an entry's identifiers over its
attrs — the old name was written back, and the next entry made `frontend`
and `admin` new and empty beside the old (spikeuser left in `media-users`).
The entry now finds the old group by its pk; `wire` and doctor fail while a
group still has an old name (nothing had checked the rename happened).
*Second try (16 Nov 2026):* the rename held (spikeuser in `frontend`), but
right after the apply authentik answered three writes after more than 20 s —
two outpost writes and Navidrome's rename were reported refused, and had
landed (the next `wire` found them done; doctor agreed). Each outpost write
sends the whole provider list, so writes one after another could undo each
other when an answer is late. Now: every gate goes onto the outpost in one
write once all the cards are done; the outpost and provider writes wait as
long as authentik's slow writes (`AUTHENTIK_STAGE_WAIT`), and a write with no
answer is read back before it counts as a failure.
*Proven live (16 Nov 2026, the keeper from `stable` 8e8e03f, `upgrade` to
`unstable` 2aef583 pulling for real):* schema 44 → 45 said the rename once;
`wire` renamed both groups in place (spikeuser in `frontend`; no
`media-users` or `admins` left; `frontend` kept its year limit), put every
gate on the outpost in one write, rewrote the panel's list for `admin`
(its admin kept) and Jellyfin's filter, with no failure; doctor: every gated
app on its own gate. akadmin opened the panel (status, leak test) and the
tools; spikeuser was refused Sonarr, opened Navidrome, and signed in to
Jellyfin on the web and the phone with the portal password and with the app
password.
*Slice 4 also:* a grant's or revoke's change of groups is followed by one
save of the person — proven live (16 Nov 2026): it clears authentik's
day-long list of their apps (the card appears or goes on their next load).

**Slice 3 — tiers and `access`** (decisions 6, 8; *built and proven live
16 Nov 2026*). `<SVC>_TIER` (schema 46) over the service's
`mediastack.tier` label over its kind (the household gate's apps frontend,
the tools admin); `wire` binds each app's card by its tier (frontend: the
household and its admins, the Media shelf; admin: admins only, the tools —
the household's binding taken off). `access list [user]`, `access tier`:
opening an app to the household warns and asks; a move to admin applies the
rule first, then ends the portal sessions of the household members who lose
it (`bulk_delete`, the admin UI's own deletion). A binding's change clears
every person's cached list of apps (authentik's signals), so a tier needs no
save of each person.

*Proven live (16 Nov 2026, anzac4, `upgrade` from schema 45 to 46):*
`access tier navidrome admin` ended spikeuser's session (1) and took the
card away; signed in again, refused; `access tier navidrome frontend`
gave both back. `access tier sonarr frontend` asked, then gave spikeuser
Sonarr's card and the app without a new sign-in; back to `admin`, the next
reload was sent to sign in and then refused — but the tab already open had
added a show in between, through `/api` (decision 9).

**Slice 3b — the arrs' API behind the gate** (decision 9; *built and
proven live 16 Nov 2026*). The seven bypass labels go; the upgrade
(schema 47) says so once; the README's how-to for phone apps; `credentials`
says it.
*Proven live (16 Nov 2026, anzac4, `upgrade` from 6548781 to 7c76ca7):*
schema 46 → 47 said it once; `up` recreated only the VPN group and gluetun
(it carries their routes), the leak gate passed; `safety-live`: every
gated app's `/api`, signed out, sent to sign in; doctor unchanged. The
hole closed: with Sonarr open as spikeuser (`access tier sonarr
frontend`), `access tier sonarr admin` ended their session — the tab
already open could no longer search, and its status page showed an API
error. nzb360 with the header (a new device password, spikeuser granted
by hand) connected, without it refused, with it again connected; the
device password deleted — refused about 6 s later.

**Slice 4 — grants and taking access away** (decisions 4, 8; *built and
proven live 16 Nov 2026*). `access grant <user> <app>` — into
`app-<svc>` (stopping first when the group or the card's binding to it is
missing: `wire` makes them), read back, then one save of the person so
their dashboard follows; no session to end — the next request to that app
starts one. `access revoke <user> <app>` — out of it, read back, saved,
then their portal sessions ended; a device password of theirs stops within
a minute (decision 9). Refused, and told how, when they have the app
through `admin` or the app's `frontend` tier and no grant. *Changed from
decision 8:* a grant **beside** the tier is removed (it would come back to
life if the tier moved), with "they still open it through …" and no
session ended. `access tier` now reports only the cards it changed, and
"no portal session of theirs was open" in place of "ended (0)".
*Not in this slice:* grants for the apps that sign people in themselves
(Jellyfin, Seerr, Kavita, Audiobookshelf) — everyone in the portal has
them today; `app-jellyfin`, its year limit (decision 5) and `signout` on
its revoke come with them (decision 7's "later").
*Proven live (16 Nov 2026, anzac4, `upgrade` to 03c58c9):* `access grant
spikeuser sonarr` — the card on their open dashboard at the next refresh,
no new sign-in, Sonarr opened; `access list` named them. `access revoke`
with Sonarr open — sessions ended (1); the open tab could no longer
search, the dashboard asked to sign in, then showed no Sonarr card and the
address was refused. Twice over, the same. Revoke again: nothing to take
away; Navidrome (their tier) and akadmin (`admin`): refused, each told
how. `access tier navidrome admin`, then `frontend`: only Navidrome's
card reported.

## Part 3 — every app, not only the gated ones (decisions **agreed** 16 Nov 2026)

Part 2 decides who may open each app behind the gate. Jellyfin, Kavita,
Audiobookshelf and Seerr sign people in themselves, and each keeps a session
of its own that no portal change reaches: today everyone in the portal has
them, and a person turned off in the portal keeps an open session until it
expires. Part 3 puts them under the same rule, and makes taking an app away
reach a session already open.

*Spike (16 Nov 2026, anzac4, unstable 954f849):*
- **Navidrome's music apps ignore `access`** (found reading
  `services/navidrome/people.sh`, then proven): with Navidrome `admin`-only
  and spikeuser in `frontend` alone, `/rest/ping` with spikeuser's
  Navidrome password answered `ok`. `people-sync` takes that password only
  when the portal account is turned off or deleted, never when access moves.
- **Jellyfin:** spikeuser disabled in Jellyfin's dashboard — the open
  session's next requests refused (the web page spins; a reload goes to
  sign-in), and a new sign-in refused as not authorized (not as a wrong
  password). Re-enabled, back.
- **Kavita:** spikeuser's `Login` role removed — clicks in the tab already
  open kept working; its reload 2½ minutes later went to sign-in; a new
  portal sign-in refused by Kavita — and, because the portal still allowed
  it, Kavita's login page sent them to the portal and the portal back, in a
  loop. (With the portal's rule and Kavita's switch changed together, the
  portal refuses first, on its own page — to prove in its slice.)
- **Seerr:** spikeuser disabled in Jellyfin — Seerr kept them signed in
  through clicks and reloads. Seerr asks Jellyfin only at sign-in, keeps its
  own session, and has no disabled state for a person.
- **Audiobookshelf:** not enabled on the test box. Its source refuses a
  portal sign-in for an inactive account; whether an open session dies is
  spiked in its slice.
- **Found on the way:** Jellyfin's, Kavita's and Audiobookshelf's admin
  rights follow the portal's `admin` group only when `wire` runs — akadmin's
  Kavita account, made by a sign-in after the last wire, had none until
  `wire kavita`.

10. **One rule for every app.** A person may open an app when their portal
    account is on and they are in `admin`, or the app's tier is `frontend`
    and they are in `frontend`, or they were granted it (`app-<svc>`).
    `access tier|grant|revoke` cover Jellyfin, Kavita and Audiobookshelf.
    Seerr signs in through Jellyfin, so it follows Jellyfin's rule: no tier
    or grant of its own, its card bound like Jellyfin's.
11. **Where each app checks it at sign-in.** The gated apps: their card
    (done). Kavita and Audiobookshelf: their card is their OIDC application
    — wire binds it by tier and `app-<svc>`, the gated apps' code. Jellyfin:
    the LDAP application's bindings and Jellyfin's LDAP search filter both
    gain `app-jellyfin`; the `frontend` binding moves from the blueprint to
    wire (a re-applied blueprint would put back what a tier move took off);
    the blueprint keeps `admin`'s and the search account's.
12. **Taking it away reaches an open session: each app's own switch, kept in
    step with the rule.** Jellyfin — the person disabled, then `signout`
    (their apps go to sign-in instead of spinning); Kavita — `Login` taken
    off; Audiobookshelf — inactive; Navidrome — its music password
    scrambled, as for a turned-off account today. On again when they may
    again. Only accounts tied to the portal; the stack's own and local ones
    never (as the admin syncs). Only an account the stack turned off is
    turned back on — someone an admin disabled by hand in the app stays
    disabled — so each app keeps a record of whom it turned off
    (Navidrome's `navidrome-people` already does).
13. **When it runs.** At once for the people an `access` command changes; in
    `wire`; and every 15 minutes in `people-sync`, made from Navidrome's into
    every app's — so a change made by hand in authentik (a group, an account
    turned off) reaches the apps without anyone running a command. Admin
    rights ride the same sync, so they follow within 15 minutes too. A new
    app with accounts of its own adds one function, `<svc>_people_follow`.
14. **Seerr's open session is a known gap, kept** (*decided 16 Nov 2026*).
    Taking Jellyfin away stops new Seerr sign-ins (Jellyfin refuses them);
    a Seerr session already open runs until it expires, and in it the
    person can still make requests (they cannot watch). Weighed: Seerr
    behind the gate (taking access away ends the portal session, the gate
    refuses — proven on Sonarr; rejected: a second sign-in for anyone
    arriving without a portal session); deleting their rows in Seerr's own
    database (rejected: another app's private tables, silently broken by an
    update). The README says so; the watchlist holds what would close it.

**Costs:** a change made by hand in authentik reaches open sessions within
15 minutes (an `access` command: at once); Kavita's open tab until its next
reload; one more record per app of whom the stack turned off; six apps, so
several slices.

### How it is built

**Slice A — `people-sync` for every app; Navidrome first.** The sync
generalised (decision 13), Navidrome's people following the rule
(decision 12) — its hole closed — and the admin syncs of Jellyfin, Kavita
and Audiobookshelf moved into it. *Proven live 17 Nov 2026 (anzac4,
c0029da):* spikeuser's music app answered `/rest/ping` before; `access tier
navidrome admin` cut it at once (`failed`); grant, revoke and the tier back
each followed at once; the timer's run waited for authentik, Jellyfin, Kavita
and Navidrome and passed. Found on the way: `wire a b c` ran only `c` —
fixed, a second app is refused.
`lib/people.sh` holds the rule (`people_may`), the record of whom the stack
turned off (`local/<app>-people`; Navidrome's file as before) and the timer;
each app's part is `<app>_people_follow` in its folder, listed in
`PEOPLE_APPS`. An app is followed from the first `wire` that reaches its
portal step — a timer run must never beat the wire that makes the stack's
admin (found live with Navidrome) — and schema 48 keeps Navidrome followed
where it was. A run waits for authentik and each app to be up (the boot:
the timer catches up at once, before the portal answers — found live
17 Nov 2026), and skips while an update, a backup or `up` holds the stack.
A group the rule reads missing: nobody judged, a failure says why.

**Slice B — Jellyfin.** `app-jellyfin`, its tier and grants; the LDAP
rule (decision 11); disabled and signed out on loss (decision 12); Seerr's
card follows Jellyfin's rule. *Proven live 18 Nov 2026 (anzac4, 8e189f5):* `access tier
jellyfin admin` cut spikeuser's open tab (it spun, a reload went to sign-in,
signing in again was refused) and took Jellyfin's and Seerr's cards off their
dashboard at once; grant, revoke and the tier back each followed, the cards
returning. Found on the way: Jellyfin 12.4 ends a disabled person's sign-ins
itself — the sign-out after the disable found none and said "0 devices"
with a session open, so the devices are counted before the disable now; and
a people-sync run can get there before `access` does (both land the same),
so `access` says when an app's accounts were checked. Labels put it
under the rule: Jellyfin's `mediastack.tier: frontend` (`authentik_native_ruled`:
an app with its own login and a tier label — `access` covers it) and Seerr's
`mediastack.access.of: jellyfin` (its card by Jellyfin's tier, with
`app-jellyfin`). The LDAP application's household binding left the blueprint;
`ak_ldap_rule` keeps it by the tier, with `app-jellyfin` beside the
blueprint's admin and search-account bindings. Its accounts follow in
`jellyfin_people_follow`: the search filter (rewritten when a tier moved),
who may sign in (`jf_people_access`: disabled, then signed out of every
device; turned back on only when the stack turned it off), then admin rights.
`access` on Jellyfin ends no portal session — the follow is what reaches an
open one. A person deleted from the portal is disabled and renamed
`removed-<name>-<date>`, as Navidrome's (decided 18 Nov 2026): a later
sign-up under the same name gets a fresh account instead of the old one.
*Proven live 18 Nov 2026 (5931bdc):* spikedel, deleted in authentik, became
`removed-spikedel-20261118` — disabled, signed out of its one device — and
the next run left it alone.

**Slice C — Kavita.** Its card by the rule; `Login` on loss; proven: no
loop, and when an open tab is cut off. *Built 18 Nov 2026, to prove live.*
Its tier label (`mediastack.tier: frontend`) puts it under the rule; its card
is its OIDC application, so the portal refuses a sign-in first, on its own
page. Its accounts follow in `kavita_people_follow`: who may sign in
(`kav_people_access`: `Login` off on loss, back only when the stack took it —
Kavita never syncs roles from the portal, `syncUserSettings` off), then
admin rights. A person deleted from the portal is renamed
`removed-<name>-<date>` with the email `<that>@removed.invalid`: Kavita
links a portal sign-in by email, so the email, more than the name, is what a
newcomer would take over. `kav_login` is the one way in as the stack's own
admin (it was copied five times).

**Slice D — Audiobookshelf.** Spike first (enabled on the test box), then
the same.
