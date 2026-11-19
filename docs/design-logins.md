# Design: one login for the remaining tools

*Status: **agreed** (18 Nov 2026), MVP plan step 6. Built tool by tool, each
proven live before the next: Bazarr → qBittorrent → Pi-hole → Transmission →
Cleanuparr and WatchState (after their spikes) → Deluge's note. Bazarr built
and proven live 18 Nov 2026 (`bazarr_login`; no login page through the
portal, its API 401 without the key and 200 with it; `set-credentials arr`
now reaches it too, which it never did). qBittorrent built (`qb_gate_trust`),
not yet proven live.*

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
  covers Traefik's address is a failure there too, never overwritten.

## Per tool

| Tool | How | Why this way |
|---|---|---|
| **Bazarr** | auth `None` while trusted | its API demands the API key whatever the UI does, and its `/api` is behind the gate (design-access decision 9) |
| **qBittorrent** | "bypass authentication for clients in whitelisted subnets", the subnet being Traefik's fixed address (`TRAEFIK_ADDRESS/32`); reverse-proxy support stays off | the stack's callers keep logging in; with reverse-proxy support on, qBittorrent would take the client's address from Traefik's forwarded header and see the LAN instead |
| **Pi-hole** | an empty web password while trusted, rendered by the script (like `MEDIASTACK_GATE_BIND`) | with no password neither its dashboard nor its API asks; both are then reachable only through the portal; DNS is untouched |
| **Transmission** | Traefik adds its stored login (HTTP Basic) to requests that passed the gate; its own auth stays on | its auth is one switch for the UI and the RPC — an address allowlist would have to name every caller, and Cleanuparr's address is not fixed. The gate drops a phone's device password before the header is set |
| **Cleanuparr** | its own OIDC through the portal, *not* exclusive mode — **spike first** | with no linked identity, whoever the portal lets open it may sign in (the tier rule decides). Exclusive mode is refused: with the portal down, the way back is editing its database. Its "disable auth for local addresses" is refused too: it also drops the API key requirement for local callers |
| **WatchState** | **spike first** | the stack does not manage its login today (a system user made on the first visit). If it cannot hand its sign-in to a proxy, it at least joins the stack's own logins: generated, in `credentials`, rotatable |
| **Deluge** | its login stays; a known gap, documented | its web UI's password cannot be removed; a longer session would only lengthen what a stolen cookie is worth |

## Costs

- **qBittorrent trusts one address.** A compromised container able to pose
  as Traefik on the stack network gets in — the risk already taken for
  Navidrome's header trust (`MEDIASTACK_GATE_TRUST`).
- **Transmission's login sits in Traefik's generated config**, so
  `set-credentials transmission` and `rotate-secrets` rewrite it there too.
- **Pi-hole without a password** can be changed by anything running on the
  host itself (its port is the host's 127.0.0.1).
- **Phone apps** reach these tools only through the portal with a device
  password as HTTP Basic (decision 9); one with no custom-header setting
  cannot.
