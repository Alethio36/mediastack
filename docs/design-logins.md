# Design: one login for the remaining tools

*Status: **agreed** (18 Nov 2026), MVP plan step 6. Built tool by tool, each
proven live before the next: Bazarr → qBittorrent → Pi-hole → Transmission →
Cleanuparr and WatchState (after their spikes) → Deluge's note. Bazarr built
and proven live 18 Nov 2026 (`bazarr_login`; no login page through the
portal, its API 401 without the key and 200 with it; `set-credentials arr`
now reaches it too, which it never did). qBittorrent built and
proven live 18 Nov 2026 (`qb_gate_trust`; no login page through the portal,
403 without a login straight to it, Sonarr's connection test passing). The
portal's removal and return proven live the same day (below). Pi-hole built
(`pihole_gate_sync`, `gate_planned`): its API answered with no password on the
host's port, live 18 Nov 2026; its dashboard through the portal was refused
by Pi-hole itself (403 to any Host but an address or `webserver.domain`), so
its domain is now its route's name and Traefik sends `/` to `/admin/`; both
proven live 18 Nov 2026, with the portal's removal and return. Transmission
built (`mediastack.auth.inject`, `transmission_login_middleware`) and proven
live 18 Nov 2026 (no prompt through the portal, 401 straight to it). Deluge's
gap documented 19 Nov 2026. WatchState built 19 Nov 2026 (`WS_TRUST_LOCAL`
for Traefik's address) and Cleanuparr (its OIDC through the portal), neither
yet proven live.*

## Why

With the portal, every admin tool sits behind the gate and is closed to the
LAN, yet seven of them still ask for a login of their own after it. The arrs
and Prowlarr already trust the gate (`arr_login`: Sonarr's "external"),
and LazyLibrarian drops its login there too (`ll_login`) — the original list
of eight was seven.

## The rule

A tool drops its own login **only while `gate_trusted` holds**: the portal
runs, the tool is gated, and its host port binds 127.0.0.1. Otherwise — Wizarr
or no account model, or the tool moved off the gate — `wire` puts its login
back. Three things never change:

- **The stack's own calls keep their credentials.** The script, the arrs and
  Cleanuparr go on signing in with the stored login or API key; a tool's
  login is dropped for people coming through the portal, not for everyone.
- **An API stays protected.** A tool drops its login only where its API is
  then protected by a key, by the gate, or by the network.
- **Both directions are `wire`'s — and `disable authentik` goes first.**
  A tool's gate turned off brings its login back on the next `wire`, like
  `arr_login`. Turning the portal off cannot wait for that: once authentik
  is gone, Traefik's gate is a no-op and the ports reopen, so qBittorrent's
  bypass would let anyone through Traefik in and Bazarr would ask nobody.
  Each tool that drops its login brings `<svc>_gate_login`; `disable
  authentik` runs every enabled one with `GATE_UNTRUSTED=1` (gate_trusted
  answers no while the portal still runs), checks each, and stops — the
  portal kept, the ports closed — if one fails or is not running. CI holds
  every `gate_trusted <svc>` to its `<svc>_gate_login` (check-registries).
  *Found 18 Nov 2026, before any of it reached `stable`: the loop named the
  arrs and Prowlarr only, so LazyLibrarian (since Oct 2026), Bazarr and
  qBittorrent were left out.* A bypass list someone set up themselves that
  covers Traefik's address is a failure there too, never overwritten. Proven live 18 Nov 2026 on
  anzac4: the arrs, Prowlarr, Bazarr and qBittorrent got their logins back
  before the ports reopened; Bazarr's LAN port and qBittorrent through
  Traefik then asked for them. The same run found `disable` left Traefik's
  gate asking the authentik just removed (every gated route a 500, closed
  rather than open) — it now regenerates Traefik's config too.

## Per tool

| Tool | How | Why this way |
|---|---|---|
| **Bazarr** | auth `None` while trusted | its API demands the API key whatever the UI does, and its `/api` is behind the gate (design-access decision 9) |
| **qBittorrent** | "bypass authentication for clients in whitelisted subnets", the subnet being Traefik's fixed address (`TRAEFIK_ADDRESS/32`); reverse-proxy support stays off | the stack's callers keep logging in; with reverse-proxy support on, qBittorrent would take the client's address from Traefik's forwarded header and see the LAN instead |
| **Pi-hole** | an empty web password while trusted, rendered by the script (like `MEDIASTACK_GATE_BIND`): `PIHOLE_WEB_PASSWORD` set empty, absent otherwise, and compose's `${PIHOLE_WEB_PASSWORD-${PIHOLE_PASSWORD}}` — absent never means none. Decided from `.env` (`gate_planned`), since Pi-hole reads it only at its start | with no password neither its dashboard nor its API asks; both are then reachable only through the portal; DNS is untouched |
| **Transmission** | Traefik adds its stored login (HTTP Basic) to requests that passed the gate; its own auth stays on. Its label `mediastack.auth.inject: "true"` chains `mediastack-gate@file,transmission-login@file` on its route; its `transmission_login_middleware` defines `transmission-login` in Traefik's generated file — its login while it runs and the portal guards it (`gate_planned`), a no-op otherwise, defined for the whole catalogue because routes are. CI holds the label and the hook together | its auth is one switch for the UI and the RPC — an address allowlist would have to name every caller, and Cleanuparr's address is not fixed. The gate drops a phone's device password before the header is set |
| **Cleanuparr** | its own OIDC through the portal, *not* exclusive mode: a button on its login page, its password kept. The blueprint's provider `mediastack-oidc-cleanuparr` and its own application `mediastack-signin-cleanuparr` (on no dashboard, `blank://blank`; its card stays the gate's), `admin` bound there and the rest of its card's rule mirrored by `wire authentik` (`ak_signin_rule`, for any gated tool that has such an application). `cup_oidc` writes it (redirect address set: behind Traefik it would guess `http://`), remembers the secret by its digest, and proves it by asking for the button's address; another provider set up by hand is left alone. With no portal, and first thing in `disable authentik` (`cleanuparr_gate_login`), the button and exclusive mode go. `wire` runs authentik before cleanuparr | the spike (its source, Nov 2026): with no linked identity, whoever the portal lets open it signs in as its one account (the tier rule decides, twice: the gate and the application). It has no auto-redirect, so a click remains; its refresh token lasts 7 days. Exclusive mode is refused: with the portal down, the way back is editing its database. Its "disable auth for local addresses" is refused too: it trusts every private range whatever its trusted networks say, and drops the API key requirement for them |
| **WatchState** | its `WS_TRUST_LOCAL` (it signs in whoever comes from `WS_TRUST_LOCAL_NET`, as its own account), that network being Traefik's fixed address alone (`TRAEFIK_ADDRESS/32`; its default is every private range). Read at its start, so decided from `.env` (`gate_planned`): `watchstate_gate_sync` writes `WATCHSTATE_TRUST_TRAEFIK=true` while guarded, absent otherwise. `WS_TRUST_PROXY` stays off. `watchstate_gate_login` proves the trust gone by asking from inside Traefik's container, the one trusted address | the spike (its source, Nov 2026) found the trust affects only its sign-in: `has_user` hands the trusted caller a token for its one account, and its API still demands that token or its key. Its account stays its own (made on the first visit): the stack never needed it, and its username rule (`a-z 0-9 _`) would have narrowed the stack's one username for everyone |
| **Deluge** | its login stays; a known gap, documented (README; docs/watchlist.md, "Deluge's own password behind the portal") | its web UI's password cannot be removed, and its sign-in is a session cookie, not HTTP Basic, so Traefik cannot add it as it does Transmission's; a longer session would only lengthen what a stolen cookie is worth |

## Costs

- **qBittorrent trusts one address.** A compromised container able to pose
  as Traefik on the stack network gets in — the risk already taken for
  Navidrome's header trust (`MEDIASTACK_GATE_TRUST`).
- **Transmission's login sits in Traefik's generated config**, so
  `set-credentials transmission` and `rotate-secrets` rewrite it there too.
- **Pi-hole without a password** can be changed by anything running on the
  host itself (its port is the host's 127.0.0.1).
- **WatchState's tokens outlive the trust.** A browser signed in through the
  portal keeps its WatchState token (2 days by default) after `disable
  authentik`. Its own settings
  (its Env page, `/config/config/.env`) override compose's — `disable
  authentik` catches one that keeps Traefik trusted.
- **Cleanuparr still takes a click**, and its sign-in is one more client
  secret the portal holds (`AUTHENTIK_CLEANUPARR_CLIENT_SECRET`, rotated with
  authentik's settings). Its own password remains, known to the script.
- **Phone apps** reach these tools only through the portal with a device
  password as HTTP Basic (decision 9); one with no custom-header setting
  cannot.
