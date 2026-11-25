# Mediastack — watchlist

Everything evaluated and **not** pursued, with the reasoning, so a question is
never re-opened from scratch. Open work lives in [roadmap.md](roadmap.md).

Every entry ends with the condition that would change the verdict:

- **Rejected** — decided no. **Reopen only if:** names what would have to
  change first.
- **Parked / deferred** — the idea is sound, something is in the way.
  **Revisit when:** names that something.

When a condition fires, the item moves to the roadmap (open work) and leaves
this file.

## Rejected

### Runtime & tooling

Alternatives assessed and consciously *not* adopted, with the reasoning, so the
"shouldn't we use X?" question isn't re-opened from scratch. The verdict in every
case is the same: each buys one benefit at the cost of raising the newbie floor or
forcing dual-maintenance, and neither price is worth paying for an open,
accessibility-first project under lean scope.

#### Kubernetes

**Verdict:** rejected (default and as an owned optional target).

A newbie cannot stand up k8s; Compose is the on-ramp. Owning a second runtime
means dual maintenance, a split doc/support surface, and — worst — the
killswitch stops being one readable compose line and becomes pods + a
default-deny NetworkPolicy + native sidecar ordering, i.e. the most
safety-critical thing requires the most expertise to reason about. Pod
rescheduling is itself a leak vector the static compose model doesn't have. A
veteran who wants k8s can port `services/` downstream; the project won't carry
it.

**Reopen only if:** the project gives up the Compose on-ramp for newcomers —
i.e. never while accessibility is a goal.

#### Ansible

**Verdict:** rejected.

`ansible.builtin.uri` is a dumb HTTP client: it does not diff remote state, so
the arr wiring you'd want declaratively still has to be hand-written
(`changed_when` / GET-then-conditional-PUT) — Ansible's idempotency covers
files/packages/services, not REST config. The genuinely hard services
(qBittorrent password mint, Jellyfin claim, seerr-through-jellyfin) drop to
`shell:` blocks — bash inside YAML, strictly worse. Plus a Python/ansible-core
runtime and a second entry point against the front-door model. Its good ideas
(`until/retries` readiness, `--check` dry-run, `--diff` drift) are worth
borrowing into the native wire engine; its runtime is not.

**Reopen only if:** its HTTP module gains real remote-state diffing. Until then
its good ideas are borrowed into `wire`, not its runtime.

#### Terraform / OpenTofu

**Verdict:** rejected as a runtime dependency; viable only as an optional generated export.

The `devopsarr` providers are real and maintained, and `plan` / `plan
-detailed-exitcode` give dry-run and drift detection for free — a genuinely good
fit for the arr *converge*. But as part of the default `wire` it adds an
OpenTofu binary, provider downloads (a network/airgap failure surface), a state
file holding secrets, and HCL as a second config language — it fails the
newbie-floor test. As a co-equal alternative engine it re-introduces the
dual-maintenance trap. It also can't touch the bootstrap 20% (bash stays), and
authentik is better served by native Blueprints (no state file) than by the TF
provider. If IaC is ever wanted, the accessibility-respecting shape is a
`mediastack.sh`-generated `wire.d/arr/` HCL export a veteran can manage
themselves — not a dependency imposed on everyone. (FOSS note: it would be
OpenTofu (MPL), never HashiCorp Terraform (BSL), per the FOSS-only goal.)

**Reopen only if:** an operator asks for IaC — and then only as that optional
generated export, never as a dependency of the default install.

#### Podman as the default runtime

**Verdict:** not adopted as default; retained as an opt-in hardening path.

Docker's ubiquity *is* the newbie on-ramp, so it stays the default runtime.
Rootful Podman is close to a drop-in (a `CE` container-engine indirection over
the ~70 `docker` calls, the compose-on-podman-socket path to preserve
`depends_on: service_healthy` fidelity, repoint Traefik's socket) but delivers
no security payoff — still root. Rootless Podman is the real prize ("shrink the
root surface") but is a genuine redesign of the three riskiest subsystems — the
provisioner's UID/bind-mount model vs userns remapping, privileged-port binding
at the edge, and `NET_ADMIN` + tun for gluetun — and it stresses the killswitch
directly, so it ships only behind an exhaustive `leak-test` pass, as a
documented veteran mode, never the default.

**Reopen only if:** Docker stops being the newcomer's default. The opt-in
rootless path is open work on the roadmap (Portability).

### Jellyfin in-app toast

**Verdict:** evaluated and rejected (kept so it is not retried).

`POST /Sessions/{id}/Message` works on 12.0 from an external API caller — the
issue #15865 "204-no-op / empty `SupportedCommands`" regression does *not* bite the
web client (`DisplayMessage` is advertised and delivered) — but jellyfin-web
clamps the toast to ~5s regardless of `TimeoutMs`, its position is client-fixed,
and a 204 is not a delivery ack. A ~5s flash is too brief to read, so it stays
dropped unless jellyfin-web ever renders `DisplayMessage` as a persistent
element instead of a transient toast.

**Reopen only if:** jellyfin-web renders `DisplayMessage` as a persistent
element. Apprise stays the notification path.

### Deletion attribution in a container

**Verdict:** rejected (Sept 2026) — `audit on` runs auditd on the host.

The kernel keeps one audit rule set and one audit daemon per host; audit is not
namespaced per container. An auditd container would need host networking, the
host PID namespace and the audit capabilities — a host daemon in a costume, no
isolation gained — and would fight any auditd the host already runs. Its rules
live in the kernel, so stopping the container leaves them loaded with nothing
collecting the events. Also weighed: Falco and Tetragon (eBPF; they name the
container directly, but run privileged, are heavy, and depend on the kernel's
eBPF support), Elastic's Auditbeat (brings the Elastic stack), fanotify (cannot
attribute deletes on NFS).

**Reopen only if:** services stop running as their own host UIDs — rootless
Docker or userns-remap would shift them and break attribution by UID. An eBPF
tool that names the container is the answer then.

## Parked

### Email from a custom-domain address (alias) *(Oct 2026, to review)*

Today the portal's mail comes from the SMTP login's own address (e.g. the
stack's Gmail account). Sending as `portal@<your domain>` through the same
login is possible: Gmail's **Send mail as** adds the address after a
confirmation code mailed to it (so it must receive mail), and `configure`'s
"Send as" then takes it. Until it is verified, Gmail rewrites the From back
to the account address — no error. Mail from a domain whose SPF/DMARC does
not include Google's senders (`include:_spf.google.com`) tends to land in
spam.

**Revisit when:** the household wants mail to come from the domain. Then:
a short alias section in `docs/email.md` (Gmail and the sending services'
equivalents), and the domain's SPF updated.

### Deluge's own password behind the portal *(Nov 2026)*

Deluge is the one gated tool that still asks for its own password after the
portal (docs/design-logins.md). Its web UI has no setting to turn its
password off. Its sign-in is a JSON-RPC call that sets a session cookie, not
HTTP Basic, so Traefik cannot add it the way it does Transmission's. A
longer `session_timeout` would only make a stolen cookie worth more. The
password is the stack's own (`credentials`; `set-credentials deluge`).

**Revisit when:** Deluge's web UI can turn off its password, or can trust a
proxy's header or address. Most households run qBittorrent alone and never
see this.

### qBittorrent API keys

**Verdict:** evaluated, parked (Sept 2026, verified in source at the versions then running).

qBittorrent 5.2+ has one WebUI API key (`Authorization: Bearer`;
`app/rotateAPIKey` / `app/deleteAPIKey`; readable in preferences; a session is
needed to create one). Consumer support: Sonarr 4.0.20, Radarr 6.4.4, Prowlarr
2.6.5 — yes; Lidarr 3.1.0 — no (on its develop branch); cleanuparr and
LazyLibrarian — no (login only). Servarr apps reject an entry holding a key AND
a username/password, so an entry is one or the other. Parked because it cannot
replace the login while cleanuparr and LazyLibrarian lack it: two auth methods
and two secrets for one client, for a partial gain. If adopted: each entry's
mode is derived at every `wire` run from that app's own field list (never
stored, never version-checked), so an app that gains the field converts on the
next run; one `set-credentials` path rotates both. Already in place: re-point
and `set-credentials qbit` respect an entry someone switched to a key by hand
(`qbit_login_fields`).

**Revisit when:** cleanuparr supports qBittorrent API keys (then only
LazyLibrarian would still need the login), or qBittorrent's login becomes
unreliable again as it did in 5.2.

### Write-only wire recipes

`bazarr`, `lazylibrarian` and `seerr` write without observing (one settings
blob / blind `writeCFG`), so they carry no drift signal and are listed in
`WIRE_BLIND` (`wire --verify` skips them). Making them observe is per-recipe
API work.

**Revisit when:** beta shows blind-write drift happening in practice.

### Announcing media that arrives outside Seerr

Seerr's *media available* event covers what was requested through Seerr. A
title an arr adds on its own (an import list, a manual add, RSS) is never
announced. Covering it means asking Jellyfin what is new on a timer (one
batched message per run, each title announced once ever by its TMDB/TVDB ID,
the first run recording without sending), and skipping what Seerr already
announced so requested titles are not announced twice.

**Revisit when:** someone wants arrivals that did not come through Seerr
announced to the household.

### A poster sent as a file, inside the Discord card *(Nov 2026)*

Seerr's poster reaches a Discord card as a link (TMDB's address): Discord
fetches it, and a removed one shows no picture. Sent as a file instead, it
would be Discord's own copy and other services (ntfy, Telegram, email) would
show it too — but Apprise's Discord plugin drops the card when a message
carries an attachment and posts the file as a second message below it (its
`send()`, read Nov 2026). Discord itself allows an uploaded file inside a
card (`attachment://name` in the same request).

**Revisit when:** Apprise keeps the embed with an attachment and points its
image at the upload (worth raising with Apprise) — then Seerr's payload
attaches the poster, and every service gets it.

### More of the household's look, app by app *(Nov 2026)*

Step 9 carried the kit (`brand`: name, icon, logo, background, accent,
message colours, app icons) to the messages, the portal, Jellyfin, Seerr's
and the panel's titles. Every other place it could reach is listed here, so
none is lost. *Checked* means read in the app's source in Nov 2026; the rest
is from memory and is checked in the source before any work starts.

**Each app's own screens**
- **Kavita** — themes are uploadable CSS (its *Theme* settings): the accent,
  perhaps the logo, as a theme of mediastack's, made the default. Its site
  name: check whether it has one.
- **Navidrome** — a sign-in background and a welcome message
  (`ND_UILOGINBACKGROUNDURL`, `ND_UIWELCOMEMESSAGE`; settings at its start,
  so a change restarts it). People reach it signed in through the portal, so
  its sign-in page is rarely seen: worth it only if that changes. The
  background must be an address the browser can load (not authentik's
  signed one).
- **Audiobookshelf** — no branding settings known; check for custom CSS or a
  server name.
- **Jellyfin's logo** — its header banner, replaceable only by a picture
  inside its custom CSS (sent with every page; *checked*); a small logo
  (say, under 100 KiB) would be affordable. Its **server name**
  (`JELLYFIN_SERVER_NAME`, what the TV and phone apps list) could default to
  the household's name. Its fixed blues (sliders, toggles, the loading ring:
  about 15 places, *checked*) only by CSS against its internals, which breaks
  across versions.
- **Seerr** — no logo setting (*checked*: its title only, done); its emails'
  sender name could take the household's name.
- **The web panel (OliveTin)** — its `mediastack` theme (`theme.css`,
  written by `frontdoor-install`) could take the accent for its tiles.
- **Wizarr** (the sign-up app without the portal) — check for a title, a logo
  or a welcome text on its invitation pages.
- **ErsatzTV** (Live TV, step 10) — a channel watermark (a small picture in
  the corner of the picture): the household's icon on its channels.
- **The arrs, qBittorrent, Transmission, Pi-hole, Prowlarr** — admin tools
  with built-in themes only; nothing to brand. qBittorrent's alternative web
  interfaces (VueTorrent) take themes — not one mediastack ships.

**The portal**
- **Its footer** — "Powered by authentik"; authentik's footer links are a
  setting (`footer_links`, *checked*), so a household link (the quick-start
  page, step 6) could sit beside it.
- **Its emails' logo** — needs an address the Internet can reach (the portal
  is on the network only); with the public icon address below, it can.
- **Its other pages** — the sign-up and password-reset pages' titles carry
  the name already; their welcome text (the join page's) could take a line
  of the household's own.

**Messages**
- **A public icon address** — for the services that cannot take an upload
  as the Discord webhook does (Slack, ntfy, Matrix avatars by address), and
  for the emails' logo: one optional setting (an `https://` address of the
  icon) the kit hands to each.
- **Email** — if a stream sends email, an Apprise email template (HTML) in the
  kit's colours and name.
- **Per-stream senders** — ops and users with different names or icons
  (e.g. "Mediastack" and the household's name), when they post to different
  webhooks.

**Beyond the apps**
- **Error pages** — Traefik's own (a name that does not resolve, an app that
  is down) are bare; a page in the kit's look, naming the household and what
  to try, served by Traefik for every app.
- **Installed web apps** — the name a phone shows when an app is added to its
  home screen (Seerr's is its title now; Jellyfin's and the portal's are
  their own).
- **The quick-start page** (step 6) — in the kit's look from the start.

**Revisit when:** after the step 11 audit, or sooner for one item the
household asks for — each is checked in its app's source first, then built
the way step 9's slices were (a spike on the test box, then the kit's rule:
set only while it is the app's own or mediastack's last).

### Deferring for other apps' sessions

Scheduled updates and backups wait while someone plays something in Jellyfin
(`jellyfin_sessions_active`: its `/Sessions` API, a `NowPlayingItem` present).
No other app is asked, so a 4am restore point interrupts someone listening in
Navidrome or Audiobookshelf, or reading in Kavita. Checked Sept 2026: their
session reporting is spotty — each would be one more check with its own
failure modes and one more key to manage, for an interruption that is rare at
the hours these jobs run. If adopted, each app gets its own `*_sessions_active`
beside Jellyfin's, and `defer_while_streaming` asks them all.

**Revisit when:** an app's API reports live sessions reliably and the
household actually uses it at the hours updates and backups run.

### Ending a person's Seerr session *(Nov 2026)*

Taking Jellyfin away from someone (or turning their portal account off)
stops new Seerr sign-ins, but a Seerr session already open keeps working
until it expires — they can still make requests in it. Seerr asks Jellyfin
only at sign-in, keeps its own session, and has no disabled state for a
person (spiked live 16 Nov 2026: disabled in Jellyfin, still in Seerr).
Weighed and not taken: Seerr behind the gate (a second sign-in for anyone
arriving without a portal session) and deleting their rows in Seerr's
database (another app's private tables). OIDC sign-in in Seerr (only in its
`preview-new-oidc` branch, not a release, Nov 2026) would put the sign-in
under the portal's rule, as Kavita's is — but alone it does not end a
session already open; that needs a switch Seerr checks on every request.
[design-access.md](design-access.md), decision 14.

**Revisit when:** a Seerr release can disable a person or end their
sessions (an admin API, or a state it checks per request) — then it joins
`people-sync` like Kavita — or ships OIDC, which moves its sign-in onto the
portal's rule.

### Ending a person's Kavita session *(Nov 2026)*

Taking Kavita away from someone (or turning their portal account off) stops
every new sign-in and every reload at once — the portal refuses on its own
page — and takes their `Login` role. A Kavita tab already open keeps reading
until it reloads: Kavita re-checks no role while it runs (spikeuser's tab
kept working 15 minutes and more after `Login` went, proven live 18 Nov 2026),
and an admin can end no one else's session — `DELETE
/api/device/client/device` is scoped to the caller's own devices
(`DeleteDeviceAsync(userId, deviceId)` answered `client-device-doesnt-exist`
for spikeuser's), and the auth-key and OIDC-link calls act on the caller only.
What an open tab can still do: read and download (its roles); it cannot
change or delete a book (the libraries are mounted read-only). Roles ride in
Kavita's sign-in token, so an admin demoted with a tab open may keep admin
rights in it until it reloads — Kavita's own database (libraries, settings,
people) is what that tab could still change. Weighed and not taken: Kavita
behind the gate (an instant cut, but OPDS readers and the Mihon/Tachiyomi
extension would need a device password as a header, which some cannot send).
[design-access.md](design-access.md), decision 15.

**Revisit when:** a Kavita release lets an admin end another person's
sessions (a device delete that works across people, a sign-out-everywhere,
or roles re-checked per request) — then the follow calls it on loss.

### Signing out of the portal, in the apps' own sessions *(Nov 2026)*

Signing out of the portal (or another person signing in at the same browser)
does not end a session an app keeps itself — found live 18 Nov 2026, when a
browser that had opened Kavita as akadmin stayed akadmin there after alethio
signed in. authentik (2025.10+) sends OIDC front-channel (a hidden frame in
the browser) and back-channel (server to server) logout, but each app must
take it:

- **Kavita** — *done*: its provider's logout URI is `/signout-oidc`,
  front-channel (the blueprint; authentik's own Kavita guide). Proven live:
  signed out of the portal, Kavita's next load went to the portal's sign-in.
  Front-channel needs the browser, so it covers someone signing out, not an
  admin's `access` command (that is the open-tab gap above).
- **Audiobookshelf** — waits upstream: its docs offer only a logout URL the
  other way (signing out of Audiobookshelf ends the portal session; set) and
  say a signed-in session refreshes against Audiobookshelf, not the provider.
  **Revisit when:** it takes front- or back-channel logout.
- **Jellyfin** — waits upstream: it signs people in through LDAP, so there is
  no OIDC session to end; its OIDC plugin is weighed under "Identity & SSO". `signout <user>` ends a
  person's sessions on purpose.
- **Seerr** — decision 14 (its OIDC is a preview).

Weighed and not taken: putting these apps behind the gate, so the portal's
session decides — their own apps (Jellyfin's TV and phone apps,
Audiobookshelf's app, OPDS readers) cannot sign in through a browser, as
decision 15 found for Kavita.

### Email from Wizarr

**Verdict:** parked (Nov 2026). With Wizarr, `reset-password` prints Wizarr's reset link
and the operator passes it on; `invite` likewise. Wizarr has no mailer at all
(its source, Nov 2026: no SMTP code; the reset API returns a path only), so
emailing those links would mean mediastack sending mail itself — a second
mail path beside the portal's (authentik sends its own), with its own
security, auth and error handling to maintain, for one account model.

**Revisit when:** Wizarr ships its own email (SMTP settings or a send API).
Then wire carries the stack's `SMTP_*` into it, configure's Email step and
`email test` cover Wizarr mode, and links are emailed only once the settings
pass `email test` (the `SMTP_TESTED` fingerprint, as the portal's "Forgot
password?" is gated today) — without proven email, the link is printed as now.

### NordVPN over OpenVPN TCP *(Nov 2026)*

**Verdict:** parked (23 Nov 2026). The `nordvpn` folder offers OpenVPN over
UDP only (`vpnp_nordvpn_protocols`); `OPENVPN_PROTOCOL=tcp` is refused before
gluetun starts. Over TCP gluetun dials port 443 — its NordVPN server data lists
no TCP ports (gluetun-servers, 6 Nov 2026: none of the OpenVPN entries), so its
default is used — and NordVPN's servers now answer OpenVPN over TCP on
1231–1234: the connection opens and the server hangs up, every retry (live on
the test box: us13319, us12607; NordVPN's own `.ovpn` for us12607 connected on
1233 with the same login). gluetun refuses `OPENVPN_ENDPOINT_PORT` for
NordVPN, so mediastack cannot set the port; routing NordVPN TCP through
`custom` would lose its server choices.

**Revisit when:** gluetun's NordVPN server data carries `tcp_ports` (its
updater fills them), or gluetun allows a custom port for NordVPN. Then
`vpnp_nordvpn_protocols` goes back to `udp tcp`, proven live over TCP.

The same risk stands over UDP: NordVPN's own `.ovpn` files now list UDP on
1231–1234 too, while gluetun dials 1194 — still answered (23 Nov 2026: nl834,
us8219). If NordVPN over OpenVPN/UDP ever stops connecting, check 1194 first;
WireGuard (51820) is not affected.

### Dispatcharr's channels in IPTV players on the LAN *(Nov 2026)*

**Verdict:** parked (24 Nov 2026). Dispatcharr can serve its channels to
players other than Jellyfin (TiviMate and the like) as M3U + XMLTV or an
Xtream Codes login. mediastack ships Jellyfin as its only consumer: no route
to Dispatcharr skips the admin gate. A route that did would carry any header
a client sent from Traefik's address — the one address Dispatcharr trusts
for its header sign-in — so a client naming the admin would be signed in as
it (proven in the step 10 spike). The household watches through Jellyfin,
which reaches Dispatcharr inside the stack.

**Revisit when:** the household needs a player Jellyfin does not cover. Then
a route for the player paths only (`/output/`, `/player_api.php`, the
stream paths), the header stripped on it (`mediastack-strip`'s rule), each
player signing in with its own Dispatcharr account (its XC users), proven
from a LAN address before it ships.

### Dispatcharr upstream gaps *(Nov 2026)*

**Verdict:** parked (24 Nov 2026, v0.34.1, from source and the spike):

- **The version check has no switch.** It asks `api.github.com` for the
  latest release when its worker starts and then daily
  (`core.tasks.check_for_version_update`); the stack turns off what it can
  (`DISPATCHARR_ENABLE_IP_LOOKUP=false`, the public-IP lookup).
- **`/data/uploads` is made root's.** Its start script runs `mkdir -p` of
  `uploads/m3us` and `uploads/epgs` as root and hands only those two to
  `PUID`; nothing writes into `uploads/` itself, but doctor would call it a
  mis-owned config folder. The stack makes the folder, owned right, before
  the first start.

**Revisit when:** a release adds a switch for the version check (then the
stack sets it), or makes `uploads/` itself `PUID`'s (then the stack's
pre-made folder goes).

## Deferred services

Services assessed for the stack and consciously *not* shipped yet. Adding any
of these is a `new-service` scaffold plus a fragment — the notes are about
*whether*, not *how*. Within each entry: what it is, why it's parked, what
adding it would look like, and the trigger to revisit.

### At a glance

| Candidate | Domain | Verdict | Held back by |
|---|---|---|---|
| Calibre-Web-Automated | Books | **Ship-worthy, radar** | Forks the books tree onto a Calibre `metadata.db` |
| Bindery | Books | Deferred | LazyLibrarian already fills the slot; Usenet-first |
| Kapowarr | Comics | Deferred | Off-model acquisition (scrapes GetComics, not Prowlarr) |
| Mylar3 | Comics | To evaluate | On-model (Prowlarr) comic acquisition; needs a ComicVine key |
| Unpackerr | Downloads | To evaluate | Only earns its place if releases arrive archived |
| SABnzbd | Downloads (Usenet) | To evaluate | A new subsystem: paid provider + NZB indexers + this downloader |
| Komga | Comics/manga | Deferred | Kavita chosen for breadth; Komga's edge is its API |
| ROMM | Games | Deferred, fits now | A shard (app + MariaDB + Valkey) with portal sign-in |
| **Pinchflat** | Video (YouTube) | **Ship-worthy [pick]** | Adversarial upstream; two house-rule exceptions |
| TubeArchivist | Video (YouTube) | Deferred | Heavy (Elasticsearch + Redis + app) |
| ytdl-sub | Video (YouTube) | Alternative | No UI — wrong for unknown end users |
| TubeSync | Video (YouTube) | Alternative | Pinchflat is lighter with more momentum |
| spotDL | Music (playlist → local audio) | Deferred, radar | YouTube-sourced audio (lossy ceiling, adversarial upstream); overlaps lidarr's role |
| SongMirror | Music (playlist sync) | Deferred, watch | Very young (single maintainer, no published image, no UI login); spotDL underneath |
| **authentik** | Identity/SSO | **Shipped** (the portal) | Its 4 containers run as one shard — the DB-backed-service pattern ROMM can reuse |
| Authelia (+ file / + LLDAP) | Identity/SSO | Lighter alternative | Leanest; no enrolment UI |
| Kanidm | Identity/SSO | Lighter alternative | No built-in forward-auth (needs a proxy) |

---

### Books

#### Calibre-Web-Automated (CWA) — book management + e-reader delivery

**What it is:** a hard fork of Calibre-Web that bolts the full Calibre
engine and heavy automation on top: watch-folder ingest with ~28-format
auto-conversion to EPUB, metadata fetch/enforcement (Google, Hardcover,
DNB…), duplicate detection, a web reader, OPDS, KOReader + Kobo sync, and
send-to-Kindle/Kobo email delivery. It is a *management + delivery* layer
over a Calibre library, not just a reader.

**Health: excellent** — one of the healthiest candidates here. ~5.8k
stars, single very active lead plus a broad contributor base, aggressive
release cadence, ships to GHCR as well as Docker Hub, has a real
`/health` endpoint, and a documented critical-security-fix discipline.
High open-issue/PR counts reflect volume of attention, not neglect. A
community fork (`Calibre-Web-NextGen`) exists to ship CWA's PR backlog
faster — a mild single-maintainer-bottleneck signal, but canonical is
clearly alive. Stay on canonical, pin a tag.

**Why deferred (a deliberate scope decision — radar, not roadmap):** it is *not* a drop-in
sidecar. CWA manages a **Calibre library** (`metadata.db` + Calibre's
Author/Title folder scheme), which is a different on-disk structure than
the flat `${DATA_ROOT}/media/{books,comics}` tree Kavita reads and
LazyLibrarian fills. Adopting CWA means adopting a Calibre-managed library
as the book source of truth — a *structural fork of the books vertical*,
not a bolt-on. That's the real cost, and the reason to sit on it.

Note it is **not** a ROMM-style DB problem: state is SQLite only
(`metadata.db` + CWA's `app.db`, both on the config bind), so it does not
reopen the database-aware-backup question. That's why it's safe to add
whenever the appetite exists, independent of the ROMM decision.

**What adding it would look like:**

* CWA owns management/conversion/delivery over a Calibre library; **Kavita
  demotes to reader-over-Calibre-library** (it can read one) and stays the
  comics/manga reader regardless. One source of truth: CWA writes it,
  Kavita reads it.
* **Wire LazyLibrarian's output into CWA's ingest folder** — LazyLibrarian
  keeps acquisition (Prowlarr-fed), drops the file, CWA converts/tags/
  files/delivers.
* **Never add CWA's downloader companion** (Shelfmark, ex cwa-book-
  downloader — maintenance-only since May 2026). LazyLibrarian owns
  acquisition; the companion would duplicate it.
* LAN-side with jellyfin/kavita, **not** behind gluetun (only outbound is
  metadata lookups). Pin the GHCR image tag per the deployed-tag rule;
  don't ride `latest`.

**Revisit when:** you want format conversion + e-reader delivery
(send-to-Kindle/Kobo, KOReader sync) — the genuine gap neither Kavita nor
LazyLibrarian covers — enough to accept a Calibre `metadata.db` as the
book source of truth. Until then, Kavita serves and LazyLibrarian acquires
over the flat tree.

#### Bindery — book acquisition (Readarr replacement, modern)

**What it is:** the newest Readarr replacement; imports old Readarr DBs,
architected to survive metadata-provider outages (the actual thing that
killed Readarr).

**Why deferred:** young and **Usenet/SABnzbd-first**, where this stack is
torrent-first via qBittorrent. LazyLibrarian already fills the book-
acquisition slot and wires cleanly to Prowlarr.

**Revisit when:** Bindery matures, or if the stack ever gains a Usenet
path — at which point it may be the better book manager.

---

### Comics & manga

#### Mylar3 — comic acquisition, on-model *(to evaluate, Oct 2026)*

**What it is:** the long-running comic manager in the *arr style: watches
series, searches indexers, sends to a download client, renames and files
into the library.

**Why it may fit where Kapowarr did not:** it searches torznab/newznab
indexers, so it can ride the shared Prowlarr flow like LazyLibrarian, and
Kavita already serves comics — Mylar3 would be the acquisition half only.

**To verify before shipping:** Prowlarr's app sync for it (indexers pushed,
not hand-entered), how `wire` would set its root folder
(`${DATA_ROOT}/media/comics`) and download client category, its
**ComicVine API key** (user-supplied, like Kapowarr's), the image to track
and its upkeep, and whether the household wants comics automated at all.

#### Kapowarr — comic acquisition

**What it is:** a comic library manager in the *arr family, best-in-class
for automated comic collection.

**Why deferred (not rejected):** its acquisition model doesn't match the
rest of the stack. Kapowarr does **not** use Prowlarr/torznab indexers —
it scrapes GetComics directly and optionally pushes torrents to a client.
So unlike LazyLibrarian (a first-class Prowlarr app), it can't ride the
shared indexer flow; it's a standalone getter with its own source. It
also needs a user-supplied **ComicVine API key** for metadata.

**What adding it would look like:** optional profile, light wire — root
folder `/comics` mapped to `${DATA_ROOT}/media/comics`, a download temp
folder *outside* the root, qBittorrent as an optional torrent client, and
the ComicVine key entered in its UI. Kavita already *serves* comics, so
this is purely the acquisition half.

**Revisit when:** you actually want automated comic collection and are OK
with GetComics as the primary source. Until then, drop CBZ/CBR files into
`${DATA_ROOT}/media/comics` manually and Kavita serves them.

#### Komga — comics/manga server (Kavita alternative)

**What it is:** comics/manga specialist with a rock-solid, well-documented
REST API and the best Mihon/Tachiyomi integration.

**Why deferred:** Kavita was chosen for breadth (ebooks + comics + manga +
light novels in one server). Komga's edge is its API, which matters for
*building automation against it* — not for serving and reading.

**Revisit when:** a concrete need to script against a comic server's API
appears. Komga and Kavita don't conflict (different ports, shared
storage) and can run side by side if that ever happens.

---

### Downloads

#### SABnzbd — Usenet downloader *(to evaluate, Oct 2026)*

**What it is:** the Usenet counterpart of qBittorrent. Prowlarr searches NZB
indexers (newznab) and the arrs pick a release, as with torrents; SABnzbd
fetches its posts over TLS from a news provider, repairs them (par2) and
unpacks them itself, then the arr moves the result into the library.
Picked over NZBGet: SABnzbd is very actively maintained with a LinuxServer
image; NZBGet's original project was abandoned (2022) and lives on as a
community fork.

**Why it is a household decision first:** Usenet needs two paid or
invite-only things the stack cannot supply — a provider subscription (the
servers) and NZB indexers (the search). No peers and no uploading, so no
ratio or seeding rules and no IP exposed to strangers (the VPN becomes
optional; the provider sees the traffic).

**What adding it would look like:** its own fragment; `wire` registering it
as a second download client in every arr (API key, one category per arr,
mirroring qBittorrent's) and in Prowlarr; newznab indexers added in
Prowlarr by the user; its completed folder under `DATA_ROOT`, on the
library's filesystem, so imports are instant moves. Bindery (Books) becomes
worth a second look once this exists.

**Revisit when:** the household wants Usenet and has (or will pay for) a
provider and an indexer.

#### Unpackerr — extract archived releases for the arrs *(to evaluate, Oct 2026)*

**What it is:** a small service that watches the arrs' download queues,
extracts releases that arrive as archives (`.rar` sets), lets the arr import
the extracted file, then deletes the extracted copy; the archive itself
stays where it was (and keeps seeding).

**Why it may be needed:** the arrs cannot import an archived release on
their own — it sits in the queue as "no files found". Whether this stack
needs it depends on where releases come from: public torrents rarely pack
archives, some private trackers do. Usenet releases are archived too, but a
Usenet downloader (SABnzbd, NZBGet) repairs and unpacks them itself — this
is for torrents only.

**To verify before shipping:** the rebuild's first weeks — any import stuck
on an archive is the trigger; its API-key access to every arr (it reads
them, a `wire` step would set it), temporary disk for the extracted copy
next to the archive, the VPN question (it only talks to the arrs, so off the
tunnel), and the image's upkeep.

---

### Games

#### ROMM — ROM library manager (game emulation)

**What it is:** best-in-class self-hosted ROM manager — IGDB metadata,
in-browser play (EmulatorJS), save-state and asset management, 80+
platforms, multi-user. On-brand for a gaming-adjacent deployment.

**Status (re-assessed Oct 2026): the original blockers are solved.** It was
deferred as the first database-backed service. Since then authentik shipped
as one — its own PostgreSQL in a *shard* — and the shard pattern covers what
ROMM needs:
1. **Backups are consistent.** A restore point stops the stack before
   copying, so a stopped MariaDB copies whole; points record, restore and
   unpin a shard's containers as one (Oct 2026). No dump hook needed.
2. **Start order** is the shard's own: the app `depends_on` MariaDB
   (`service_healthy`) and Valkey, health-gated like authentik's server on
   its database.
3. **IGDB key** from Twitch for metadata — setup, user-supplied (same shape
   as ComicVine for Kapowarr).

So it would ship as a shard: `romm` (primary) + `romm-db` (MariaDB) +
`romm-cache` (Valkey, sessions and the scan queue — nothing to keep).

**Portal sign-in (OIDC) — supported.** ROMM documents authentik: an
OAuth2/OpenID provider and an application, the same shape as Kavita's and
Audiobookshelf's in mediastack's portal blueprint; ROMM takes environment
variables (`OIDC_ENABLED`, `OIDC_PROVIDER=authentik`, client id/secret,
redirect URI, and the per-application URL `/application/o/<slug>`, not the
authentik root). Its docs also map authentik groups to ROMM roles
(`media-users`, `admins`).

**Two requirements before it ships:**
* **`email_verified`.** authentik 2025.10 made that claim default to false;
  ROMM requires a verified email and fails silently without it. The fix is
  a scope mapping that asserts it, replacing authentik's managed email
  mapping on ROMM's provider — in the blueprint.
* **Email must be an identity the portal controls.** ROMM (like Kavita)
  signs a portal user in as the account with their email. Asserting
  `email_verified` is only honest if a portal email is unique and cannot
  be set to someone else's. That rule is in (Oct 2026): sign-up refuses a
  taken email, people cannot change their own, `set-email` warns an admin
  about a shared one and doctor flags any — ROMM's account move joins
  Kavita's in `set-email` when it ships.

**To verify when building it:** whether a first OIDC sign-in creates the
ROMM account or only links an existing one; the role mapping against the
portal's groups; the image and MariaDB versions to pin.

**Revisit when:** the household wants a game library.

---

### Video — YouTube archiving

The one candidate domain with an **adversarial upstream**: every tool here
wraps yt-dlp, so all inherit YouTube's active anti-bot arms race. Since
2024 the web client requires a **PO token** (proof-of-origin, generated by
YouTube's own BotGuard JS); without one yt-dlp silently loses high-quality
formats or hits "Sign in to confirm you're not a bot" — now one of the
most common failures. Expect periodic breakage. This is the only fragment
whose upstream is trying to break it; everything else talks to stable APIs.

**Two house-rule exceptions this domain forces — record them as decisions,
not surprises:**

1. **VPN asymmetry — must NOT route through gluetun.** Datacenter and VPN
   exit IPs are bot-flagged *harder*; the standard fix is a residential
   ISP connection. So YouTube archiving sits on residential LAN egress —
   the exact opposite of the torrent clients. Put a loud comment in the
   fragment so nobody "helpfully" VPNs it later.
2. **Pin-vs-freshness — breaks "verify against the deployed image tag."**
   Pinning the container staleness-freezes the bundled yt-dlp, which is
   exactly what breaks (a build more than a few weeks old often targets a
   client YouTube already killed). Needs an image that self-updates yt-dlp
   on start / tracks nightly. This fragment's reproducibility story is
   deliberately weaker than the rest of the stack, by necessity.

**Optional hardening (opt-in, off by default):** a bgutil PO-token-provider
sidecar (needs a Node.js runtime) for users who hit the bot wall; cookies
from a throwaway account is the lighter alternative.

**Jellyfin integration — two models:**

* **NFO-native** (Pinchflat, ytdl-sub): the tool writes `.nfo` + poster
  into a folder by your template; you add that folder as an ordinary
  Jellyfin library and Jellyfin's built-in NFO reader ingests it. No
  plugin, no API coupling; if the archiver dies, Jellyfin keeps serving
  what's on disk. Matches the stack's decoupled, on-disk-truth pattern.
* **Plugin-bridge** (TubeArchivist): the `tubearchivist-jf-plugin` talks to
  TA's API for metadata, thumbnails, and watch-progress sync-back. Richer,
  but couples Jellyfin's lifecycle to TA being up and reachable.

**Common fit:** new fragment, own stack UID + traefik router `youtube`,
output into a new `${DATA_ROOT}/media/youtube` subtree (provisioner grows
`media/` as it did for audiobooks/podcasts/comics/manga), one new Jellyfin
library. Ship Pinchflat first; defer the other three.

#### Pinchflat — [pick]

**What it is:** Elixir, **single container, SQLite** (no external DB, so no
ROMM-style backup question). "Sonarr for YouTube": add a channel or
playlist as a source, set indexing frequency, cutoff days, and retention;
it downloads, names by your template, and writes NFO + poster. Low
resources, actively maintained, mature. NFO-native Jellyfin integration —
no plugin. Highest value for the lowest operational surface.

**Status:** ship-worthy — whether to ship it is a pending decision on the
roadmap, not a watch item.

#### TubeArchivist — heavier, richer

**What it is:** its own web UI + robust in-app search, plus watch-state
sync-back to Jellyfin via the jf-plugin. **Cost:** requires Elasticsearch
**+ Redis + app** — three stateful containers including a search engine,
significant RAM, and it reopens the DB-backup question. Still described as
the most actively supported YouTube-to-Jellyfin option despite periodic
"is it dead?" chatter.

**Revisit when:** in-app search and watch-state sync-back are worth the
Elasticsearch/Redis weight. For a lean public share, they aren't.

#### ytdl-sub — config-as-code alternative

**What it is:** a pure config-driven yt-dlp wrapper — no DB, no UI —
generating native NFO for Jellyfin/Kodi/Plex/Emby with no extra plugins or
scrapers. Philosophically the closest match to this stack's single-
installer, config-driven, fail-loud ethos.

**Why not the pick:** no web UI, wrong for unknown end users on a public
share. Keep as the documented headless/power alternative.

**Revisit when:** a headless, config-as-code archiver is wanted, or the
Pinchflat pick stalls.

#### TubeSync — the other "Sonarr for YouTube"

**What it is:** Django-based channel/playlist sync with a built-in download
client, updates the media server on new media.

**Why not the pick:** fine, but Pinchflat has the lighter footprint and the
momentum.

**Revisit when:** Pinchflat loses its maintenance momentum.

---

### Music — playlist-driven acquisition

Two candidates that come at music from the *playlist* side rather than the
*artist/album* side lidarr works from. Both are MIT, both are Python, and both
ultimately fetch audio from YouTube (spotDL uses Spotify only for metadata),
which puts them in the same adversarial-upstream bucket as the YouTube
archivers above: yt-dlp breakage, bot walls, and a **lossy audio ceiling**
(~128–160 kbps without a YouTube Music Premium cookie; 256 kbps AAC with one).
That last point is the real tension with this stack, where lidarr + TRaSH aim
at lossless or high-bitrate releases. Record it: these are for "I want my
Spotify playlists playable on Jellyfin/Navidrome," not for building the
library.

#### spotDL — Spotify playlist → tagged local files

**What it is:** the established CLI (spotDL v4): give it a Spotify
track/album/playlist URL, it resolves the metadata from Spotify, finds the
audio on YouTube Music, downloads via yt-dlp, and writes tagged files with
album art and lyrics. Official image on Docker Hub (`spotdl/spotify-downloader`)
plus a built-in web UI when run with no arguments; needs ffmpeg (bundled in
the image) and, increasingly, Deno for some YouTube downloads.

**Why deferred:** (1) it is a *downloader*, not a library manager — no
monitoring, no quality profiles, no import pipeline; it would land files next
to a lidarr-managed tree and the two do not know about each other. (2) The
audio is transcoded from YouTube, which is at odds with the quality bar the
rest of the acquisition chain enforces. (3) Adversarial upstream: same
pin-vs-freshness problem as Pinchflat — a pinned image's bundled yt-dlp goes
stale in weeks.

**What adding it would look like:** a `spotdl` shard on the LAN side (**not**
gluetun — YouTube flags VPN/datacenter exits harder, same rule as Pinchflat),
its own stack UID, output into a separate `${DATA_ROOT}/media/music-playlists`
subtree so lidarr's tree stays lidarr's, one Navidrome/Jellyfin library
pointed at it. Web UI behind a `spotdl` router. No `wire` recipe — it holds no
config worth reconciling. Nightly-refresh the image rather than pin it.

**Revisit when:** a real user wants Spotify playlists on the stack and accepts
lossy output as the price. If the wish is *lossless* music from a playlist,
the answer is lidarr's own import lists (Settings → Import Lists has Spotify
playlists / followed artists / saved albums) feeding the normal
Prowlarr-quality pipeline — no new service.

#### SongMirror — N-way playlist sync + Jellyfin-ready local mirror

**What it is:** a self-hosted Soundiiz/TuneMyMusic alternative: keeps
playlists mirrored across Spotify, Apple Music and YouTube Music (its README
headline; the repo description also claims Deezer, TIDAL, Qobuz and Amazon
Music — check the connector list under `songmirror/services/accounts` before
counting on those) with ISRC-first matching, one-way / authoritative / bidirectional modes, dry-run by
default, removal caps. Its **local download mirror** uses spotDL to keep one
folder per playlist in Jellyfin's `AlbumArtist/Album` layout with covers and an
auto-maintained `.m3u8`, and can upload playlist covers through the Jellyfin
API. FastAPI + React, single container, SQLite state under `./data`.

**Why deferred (watch, not adopt):**

* **Very young.** Single maintainer, a handful of stars, no published image
  (`docker compose up -d --build` from source), no releases. Nothing wrong with
  that, but it fails the deployed-tag rule — there is no tag to pin.
* **No UI login.** The README says so itself: bind it to the LAN, never
  port-forward. Behind Traefik that means either forward-auth in front of it
  (the SSO item) or accepting an unauthenticated panel that holds Spotify and
  Google OAuth tokens. Not acceptable on a shared-household edge as-is.
* **Credential burden.** Each user supplies their own Spotify developer app
  and a Google Cloud project with the YouTube Data API enabled and an OAuth
  consent screen in *production* mode (else tokens expire in 7 days); Apple
  Music needs two headers scraped from DevTools every few months. That is a
  lot of ceremony for a newbie install.
* **spotDL underneath** for the local mirror, so everything in the spotDL
  entry (lossy ceiling, adversarial upstream) applies here too.

**What adding it would look like:** one shard, LAN side, its `./data` on the
config bind (SQLite only — no DB-backed-service question), `DOWNLOAD_DIR`
onto the same `music-playlists` subtree as spotDL would use, `JELLYFIN_URL`
pointed at the stack's Jellyfin with a dedicated API key minted by `wire`.
Traefik router `playlists`, gated by forward-auth once SSO exists. Until an
image is published, the fragment would carry a `build:` — the first in the
stack, and an `update`-pipeline exception.

**Revisit when:** it publishes a tagged image and grows a login (or the SSO
gate exists), *and* someone on the stack actually curates playlists on two or
more streaming services. The pure "get my Spotify playlists onto Jellyfin"
case is spotDL alone; SongMirror earns its place only when the multi-service
sync is the point.

---

### Identity & SSO

**Verdict:** decided (Sept 2026) — **authentik**, as one of two mutually
exclusive account models — and **shipped** (README: The portal and the gate).
This entry keeps the reasoning and the evidence behind the choice (every
claim below checked against each project's current documentation, Sept 2026).

**Two account models — the user picks one, never both.** Wizarr creates
*local* accounts (Jellyfin, Audiobookshelf, Kavita — not Navidrome); in
authentik mode the same apps take their users from authentik. Both at once
would mean two populations and duplicate names, so the tooling refuses the
second while the first is enabled.

| | Simple — **Wizarr** | Full — **authentik** |
|---|---|---|
| Invite | Wizarr link, guided setup pages | authentik invitation link, signup form |
| Passwords | one per app | one for all, except Navidrome's music apps |
| Admin switch | per app | authentik groups (where the app honours them) |
| Weight | one container | one shard, four containers |

**authentik is one shard** (`authentik.yml`): server (primary) + worker +
its own PostgreSQL + the LDAP outpost — every extra container serves only
authentik (Architecture rules: Shards; No shared data tiers). Redis is gone
since authentik 2025.10. The LDAP outpost is its own container
(`ghcr.io/goauthentik/ldap`); forward-auth uses the outpost embedded in the
server. Watch: the outpost's startup config fetch backs off with no ceiling
(`internal/outpost/ak/api.go`, retry-go with a 3s base and no `MaxDelay`), so
mediastack's fragment holds it until the server is ready — drop that wait if
upstream caps the backoff. Needs the DB-backed service pattern first (a PostgreSQL-aware backup
and a migration-aware update).

**The design rule: the gate is for browser-only tools.** An app whose clients
log in themselves (TV, phone, Subsonic, readers) keeps its own login page and
checks authentik behind it — no second screen, no redirect for an app to
mishandle. Only browser-only tools sit behind the forward-auth gate, with their
own login switched to "trust the gate" and their ports published on 127.0.0.1
only (the script still reaches them; nobody walks around the gate). Declared per
service by label — `mediastack.auth: native | gate | open`, plus exception paths
— and CI fails a web interface without one.

**Per app (verified):**
- **Jellyfin** — the official LDAP plugin against authentik's LDAP outpost
  (authentik's own integration guide). Works on every client. The plugin's admin
  filter applies only when a user is *created* (open issue), so Jellyfin admins
  are set in Jellyfin, not by group. The OIDC "SSO" plugin is out (upstream
  archived; continuations beta). **Unverified:** how an existing local user with
  the same name is taken over — decides the account conversion; test live.
  *Re-evaluated Oct 2026 — still out, too young.* The Flowfin continuation
  (iderex) shipped its first Jellyfin 12 stable, 5.0.0-JF12-stable, on
  21 Sep 2026, with a strong, documented security design. Against it: four
  weeks old, one main maintainer, competing forks (K0lin, MaxRink, danbro96);
  its own release notes skipped the reverse-proxy, upgrade-in-place and Android
  checks, and only Jellyfin Web is verified — every app signs in through
  Quick Connect, none verified. What it would and would not buy: browsers sign
  in through the portal; apps and TVs still need Quick Connect, and Kodi, MPV
  Shim and Jellyfin Vue still need passwords (LDAP stays either way). Its docs
  suggest a linked account is moved to the plugin's own sign-in (revoking
  "switches it back to Jellyfin's built-in password provider"), which could cut
  that account's LDAP password — the deciding test, never run. Building our
  own instead is rejected: a C# plugin running inside Jellyfin, rebuilt for
  every Jellyfin major and carrying the whole OIDC security surface, is exactly
  what the forks have not yet proven and far outside an installer's scope. **Revisit when:** a second
  stable release, Android verified (upstream or by us), it survives a Jellyfin
  update, and more than one active maintainer — then run the trial, which must
  show a linked account keeps its LDAP password.
  *JellyfinSecurity (ZL154) — read Nov 2026, parked until after the MVP.*
  One MIT plugin for 2FA (TOTP, passkeys, email codes), OIDC sign-in
  (authentik among its sources), brute-force bans (10 failures in 10 minutes:
  a 24-hour IP ban; a per-user lockout), sessions an admin can list and end,
  and a QR sign-in for TVs; Jellyfin 10.11 and 12. It layers on Jellyfin's own
  sign-in as middleware: an account stays on its provider (LDAP for us) unless
  it is linked by OIDC or a passkey, or makes one of the plugin's app
  passwords — those move it to the plugin's own provider. What it would buy:
  a browser signs in with one click (Jellyfin's page stays, its password goes),
  a QR flow on TVs, 2FA and IP bans for Jellyfin. Against it, read in its
  README and wiki: authentik is asked only at sign-in (allowed groups, role →
  library mapping) — nothing re-checks, so `access` and `people-sync`
  (design-access.md, decisions 11–13) stop reaching an OIDC-linked account;
  its admin rights from groups are grant-only; its own app passwords are not
  authentik's, so revoking access does not stop them; it enforces 2FA on
  every session, so a TV on an authentik device password is blocked until
  paired or given the plugin's app password (off LDAP again); its trust
  cookie lasts 30 days and is not bound to an IP; LDAP is never mentioned;
  one main maintainer, its last commit 25 Sep 2026, 31 open pull requests.
  Its SECURITY.md (the full threat model) not read yet. The IP bans are the
  part worth having whatever is decided — weigh them against a ban at the
  edge (Traefik), which would cover every app, not only Jellyfin. **Revisit
  when:** the MVP is done and the Jellyfin plugin lock (roadmap, "Versions
  from the repo", third phase) exists to pin it — then a trial on the test
  box: SECURITY.md first; an LDAP account with its TOTP keeps signing in;
  `access revoke` still reaches someone who signed in through it; a TV on an
  authentik device password can be exempted without leaving LDAP.
- **Seerr** — "Sign in with Jellyfin", so it inherits the same users. Its own
  OIDC is still an experimental preview image (`preview-new-oidc`).
- **Audiobookshelf** — native OIDC: auto-register, optional matching of
  existing users by username or email (mediastack leaves it off: a match links
  any unlinked account, root included), mobile app via a second redirect URI, and a group claim
  (admin/user/guest) that authentik groups can drive. Test before disabling local
  login (locked out otherwise: database edit).
- **Kavita** — native OIDC with account linking, auto-provisioning and role sync
  (authentik: `offline_access` scope, roles claim `groups`). Reader apps use
  Kavita's API-key OPDS links, no login. Checked in its source (Sept 2026): it
  links an existing account by email, always (no setting); its OIDC is set up at
  start-up (a change needs a restart); `DefaultLibraries` is a fixed list, not
  "all"; people made through OIDC without a verified email are listed only with
  `includePending`; its password sign-in can be switched off for everyone but
  API keys (mediastack keeps it on for the stack's admin).
- **Navidrome** — no LDAP (see its own entry below). Web: the gate passes the
  username (`ExtAuth.TrustedSources`, header `Remote-User`); `/rest/` (Subsonic
  apps) and `/share/` bypass the gate and each user sets a Navidrome password for
  their music apps once (`EnableUserEditing=false` would forbid that).
- **ErsatzTV** — native OIDC for its management UI (a separate streaming port
  blocks management; JWT for streams).
- **The panel (OliveTin)** — trusted header or OAuth2 with authentik, including
  group mapping into its permission lists (admins run the destructive verbs).
- **The arrs** — the gate, with `AuthenticationMethod` `External` (authentik's
  Sonarr guide; it warns the backend must not be reachable directly — hence the
  localhost ports).
- **Apprise** — no authentication by design; `APPRISE_CONFIG_LOCK` makes it
  read-only (would break `notify set`). The gate.
- **To verify at build time:** qBittorrent, Deluge, Transmission, Bazarr,
  LazyLibrarian, Cleanuparr, WatchState, Pi-hole, NPM (gate specifics);
  Pinchflat, CWA. None changes the design.

**A household member's first day (authentik 2026.8).** You create an invite with
the invitation wizard (single-use, expires in 48 h by default) and send the link
any way you like — **no email server needed** to invite. They choose a username
and password, land on authentik's app dashboard, and are put in `media-users` by
the signup flow. Then: Jellyfin on the TV with the same username and password;
Audiobookshelf's "Log in with authentik"; Seerr's "Sign in with Jellyfin";
Navidrome's music apps after setting a Navidrome password. Household members are
*internal* users without admin rights — authentik shows its app dashboard to
internal users only (external users are sent straight to one default app;
checked in its source, `BrandDefaultRedirectView`). Weak spots and their answers: no guided app setup (text in
the signup flow and in each app's dashboard description — server address, which
app to install, "same password"; a small getting-started page if that is not
enough); forgotten passwords are reset by you until an email server is set up
(roadmap). authentik's admin screens are the real newcomer risk, so mediastack
ships the whole setup as authentik **blueprints** (declarative YAML): signup
flow, groups, default application, dashboard apps, LDAP, gate — you only ever
press "New Invitation" and "add to group".

**The dashboard.** Each application appears as a card to the users its policy
bindings allow (a user sees exactly what their groups open); the card has a name,
icon, launch URL, publisher and description, and a group field that sorts cards
under headings (Media, Requests, Admin). An app can stay usable but hidden from
the dashboard (launch URL `blank://blank`), and `…/application/launch/<slug>/`
logs a user in and forwards them in one step.

#### Rejected alternatives
- **Authelia + users file** — leanest, but no self-service signup (users are
  lines in YAML); signup was a firm requirement.
- **LLDAP + Authelia** — a small directory with a web UI, still no signup.
- **Kanidm** — no built-in forward-auth; a second proxy for the gate.
- **Samba4 AD** — couples the media stack to the platform's DC; too heavy here.

**Revisit when:** a lighter IdP gains invitation signup *and* forward-auth.

### Navidrome LDAP

**Verdict:** watching. Navidrome has no directory login: the request has been
open since 2020 (#141); PR #5764 adds LDAP for the web UI *and* Subsonic clients
but is unmerged; a community fork (`navidrome-ldap`) has it. Until then, in
authentik mode each user sets a Navidrome password once for their music apps.

**Revisit when:** LDAP (or OIDC) lands in a Navidrome release — then Navidrome
joins Jellyfin on authentik's LDAP outpost and the extra password goes.

*Checked Nov 9 2026:* #5764 still unmerged (it covers Subsonic login flows that
send the plain password; token-based apps send md5(password + salt), so the
server must hold a recoverable password — no hash-only directory can serve
them). OIDC as a plugin is proposed (discussion #5803; the maintainer:
extension points will come as plugin hooks, no timeline). Forks: rejected —
a soft fork lags on security fixes. Meanwhile (done, Nov 2026): a person whose
portal account goes loses their music apps (services/navidrome/people.sh).
