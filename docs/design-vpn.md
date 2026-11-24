# Design: VPN depth — every provider gluetun knows, one folder each

*Status: **agreed** (19 Nov 2026), MVP plan step 8. **Slice 1 built and
proven live** (19–20 Nov 2026, the test box): the provider layer, the eight
WireGuard providers and `custom` with endpoint names, gluetun's own settings
fixed, schema 51. **Slice 2 built** (23 Nov 2026), not yet proven live:
OpenVPN for every provider gluetun runs it for (the fourteen OpenVPN-only
folders, seven of the WireGuard eight), `custom` OpenVPN, the leak gate's
capture on the tunnel's own protocol, schema 52. Revised the day it was agreed —
an endpoint's hostname is resolved by mediastack (not refused), port
forwarding reaches the download client through a file gluetun writes (not
its control server), and every secret follows the stack's one rule
(`secret_ok`, landed first). Built in four slices, each proven live on the test box before the
next; only NordVPN can be proven live (the one account we have), so every
other provider ships from gluetun's wiki and source, marked as not tested
live, and is fixed from the feedback of the people who use it.*

## Why

configure asks a provider, a WireGuard key and countries. The survey of
gluetun (its wiki, its source on `master` — what `qmcgaw/gluetun:latest`
runs — and its server data, 19 Nov 2026) found that today only NordVPN
really works:

1. **Every provider gets NordVPN's tunnel address.** The compose file always
   sends `WIREGUARD_ADDRESSES=${WIREGUARD_ADDRESSES:-10.5.0.2/32}`, and
   configure refuses an address unless the provider is `custom`. Gluetun
   has its own default for Proton (`10.2.0.2/32` plus an IPv6 address,
   `internal/configuration/settings/wireguard.go`) and ours replaces it, so
   Proton is very likely broken (read in the code, not seen live). Mullvad,
   Surfshark, AirVPN, Windscribe, IVPN and FastestVPN need the address from
   the person's own WireGuard config.
2. **No pre-shared key is passed.** AirVPN and Windscribe require one.
3. **`VPN_TYPE=wireguard` is hardcoded.** Fourteen of gluetun's providers
   are OpenVPN only (PIA, ExpressVPN, CyberGhost, IPVanish, …): none can
   be used.
4. **`custom` is broken too.** Only the key and the address reach gluetun,
   not the server's public key, endpoint or pre-shared key; configure tells
   the person to add them in an override file.
5. **`UPDATER_PERIOD=24h`**, carried from the 2024 compose file. Gluetun's
   wiki: no less than 360h, or providers may block its updater, which
   scrapes the provider's own servers (Proton's needs a Proton login and
   skips without one).
6. **The provider name is only checked for its format.** A typo, or a
   provider gluetun dropped (Perfect Privacy: shut down Jan 2026, removed
   from gluetun's `master` 5 Aug 2026, still on the wiki), passes configure
   and fails when gluetun starts.
7. **Two outside lookups not in `docs/privacy.md`.** Gluetun's DNS check
   against ipleak.net ran at every start until today's `master` made it
   opt-in (`DNS_RESOLVERS_CHECK`, off by default from 19 Nov 2026 — a
   default `:latest` could change again). And gluetun looks up its public
   IP from ipinfo.io first (then ifconfig.co, ip2location, Cloudflare) at
   every connect — through the tunnel, but one more party that sees the exit
   address, and leak-test already gets it from Mullvad's checker.
8. **A hidden dependency.** qBittorrent and Deluge are bound to `tun0`.
   Gluetun's own setting defaults WireGuard's interface to `wg0`; it is
   `tun0` only because the image's Dockerfile sets `VPN_INTERFACE=tun0`.

## The rule

**Each provider is a folder, and everything about it lives there.**
`services/gluetun/providers/<name>/` holds the code that asks for its
credentials, the gluetun variables it needs, the server choices it offers,
what it can forward and whether it was proven live. Nothing outside the
folder names a provider: configure's list, the answers file, the rendering,
doctor and the support bundle find providers by listing the folders.
Adding a provider gluetun adds is dropping in a folder. Three things never
change:

- **The image decides what exists.** A folder for a provider the gluetun
  image does not know is refused before gluetun starts, saying so
  (`format-servers -h` lists the image's own providers, one flag each);
  CI fails a folder gluetun's `:latest` no longer has. A provider gluetun
  has and we have no folder for is reached through `custom` until one is
  written.
- **Secrets stay in `.env`.** A provider's settings reach gluetun as
  `${KEY}` references in a generated overlay (like `vpn-overlay.yml`), so
  no second copy of a key exists, and the overlay is 0644 and byte-stable.
- **Gluetun's defaults are gluetun's.** A provider folder passes only what
  that provider needs; a value gluetun defaults per provider (Nord's and
  Proton's address) is left to it, never written in for everyone.

## Layout

```
services/gluetun/
  compose.yml        provider-independent settings only (below)
  env.tsv            the shared keys (VPN_PROVIDER, VPN_TYPE, WIREGUARD_*, OPENVPN_*, VPN_SERVER_*)
  questions.sh       gluetun_vpn_questions — moved out of lib/questionnaire.sh, still called at its place
  provider.sh        the generic part: list, load, render, check, the shared questions
  providers/
    nordvpn/
      provider.sh    its hooks
      env.tsv        its own keys (NORDVPN_TOKEN) — only a provider with keys of its own has one
    protonvpn/  mullvad/  surfshark/  ...   one folder per gluetun provider
    custom/          manual WireGuard or OpenVPN, from the person's own config
```

The folder's name is gluetun's provider flag (`format-servers -h`): its
name with spaces as hyphens (`private-internet-access`, `vpn-unlimited`).
`VPN_PROVIDER` in `.env` holds the folder's name; the folder says how gluetun
spells it. The entrypoint's `services/*/*.sh` loop does not reach
`providers/`: `provider.sh` loads only the provider in use, and configure
loads them all to list them. `lib/env.sh` also reads
`services/gluetun/providers/*/env.tsv`.

## A provider's folder

Six functions, each prefixed `vpnp_<name>_` (hyphens as underscores), so no
provider can collide with a service's functions. A generic provider is about
fifteen lines:

```bash
# services/gluetun/providers/surfshark/provider.sh
vpnp_surfshark_name()    { echo surfshark; }              # gluetun's VPN_SERVICE_PROVIDER, exactly
vpnp_surfshark_types()   { echo wireguard openvpn; }      # what gluetun supports for it; the first is the default
vpnp_surfshark_filters() { echo countries regions cities; } # the server choices configure offers
vpnp_surfshark_proven()  { echo ""; }                     # "live <date>" once proven on a test box
vpnp_surfshark_questions() { # TYPE — ask for its credentials and record them
    case "$1" in
        wireguard) vpn_ask_wg_key "Surfshark: VPN > Manual setup > Desktop or mobile > WireGuard > generate a key pair"
                   vpn_ask_wg_address "the Address line of the config file Surfshark gives you (the IPv4 one)" ;;
        openvpn)   vpn_ask_openvpn_login "Surfshark: VPN > Manual setup > Credentials" ;;
    esac
}
vpnp_surfshark_env() { # TYPE — the gluetun variables it needs; each is the .env key of the same name
    case "$1" in
        wireguard) echo WIREGUARD_PRIVATE_KEY WIREGUARD_ADDRESSES ;;
        openvpn)   echo OPENVPN_USER OPENVPN_PASSWORD ;;
    esac
}
```

Optional, found by name:

| Function | What it does |
|---|---|
| `vpnp_<name>_portforward` | `native` (gluetun arranges the port: Proton, PIA, PrivateVPN) or `static` (a port the person sets on the provider's site: AirVPN, Windscribe). Absent: none. Slice 4 |
| `vpnp_<name>_check TYPE` | refuses settings this provider cannot use before gluetun renders (AirVPN without its pre-shared key). Prints the reason, rc 1 |
| `vpnp_<name>_doctor` | doctor lines of its own (Proton: port forwarding on but the key was made without NAT-PMP) |
| `vpnp_<name>_protocols` | the OpenVPN protocols it has servers for (default `udp tcp`; gluetun refuses TCP for Giganews, IPVanish and VyprVPN, and its server data has none for ExpressVPN, Privado and VPN Unlimited); empty: its config file decides (`custom`). Slice 2 |
| `vpnp_<name>_extra TYPE` | literal gluetun settings, or `${KEY}` references to optional keys (IVPN's password, needed only with an email) |
| `vpnp_<name>_keys TYPE` | `.env` and answers-file keys it reads beyond `_env` and `_extra` (NordVPN's token; `custom`'s config file and server name) — kept on a switch to it, and never refused as another's in the answers file |
| `vpnp_<name>_endpoint TYPE` | the server its config names, for "an endpoint by name" (`custom`) |
| `vpnp_<name>_prepare TYPE` / `_mounts TYPE` | files it renders under `local/vpn-files/` (0700) and mounts read-only into gluetun; their contents' hash is a label of gluetun's, so a changed file recreates it through the gate; a file no provider in use mounts is removed (`custom` OpenVPN's copy) |

The shared helpers in `provider.sh` (`vpn_ask_wg_key`, `vpn_ask_wg_address`,
`vpn_ask_wg_psk`, `vpn_ask_openvpn_login`, `vpn_ask_filter`) read the
answers file first and honour quick mode, as every question does
(`docs/adding-a-service.md`), so a provider's file holds only what is
particular to it: where its account page keeps each value. NordVPN keeps
its token exchange (`nord_wg_key`, moved from `lib/questionnaire.sh`) in its
folder. It is the one place a question calls an outside API (Nord's, to turn
a token into a key); `scripts/test-questions.sh` stubs it, as it does today.

## What reaches gluetun

`services/gluetun/compose.yml` keeps only what is the same for every
provider, and gains the fixes:

```yaml
      - VPN_INTERFACE=tun0                 # pinned: the torrent clients bind to it (gluetun defaults WireGuard to wg0)
      - UPDATER_PERIOD=360h                # gluetun's wiki: no less, or providers block the updater
      - UPDATER_PREFER_DIRECT_DOWNLOAD=yes # gluetun's server list from GitHub, never the provider's own servers
      - DNS_RESOLVERS_CHECK=off            # no ipleak.net — pinned, whatever :latest's default becomes
      - PUBLICIP_ENABLED=off               # no ipinfo.io — leak-test has the exit address (slice 1 proves nothing reads it)
```

`vpn_provider_gen` (in `provider.sh`, run where `vpn_gen` runs) writes
`local/vpn-provider.yml`, which `DC` passes after the VPN overlay:

```yaml
# GENERATED by mediastack vpn_provider_gen — DO NOT EDIT.
services:
  gluetun:
    environment:
      VPN_SERVICE_PROVIDER: "surfshark"
      VPN_TYPE: "wireguard"
      WIREGUARD_PRIVATE_KEY: "${WIREGUARD_PRIVATE_KEY}"
      WIREGUARD_ADDRESSES: "${WIREGUARD_ADDRESSES}"
      SERVER_COUNTRIES: "${VPN_SERVER_COUNTRIES:-}"
```

Before writing it, `vpn_provider_gen` checks — and dies with the reason,
never starting gluetun on a guess:

- the folder exists, and the image knows its provider
  (`docker run --rm <image> format-servers -h`, remembered per image ID in
  `local/state` so it runs once per new image);
- the provider supports `VPN_TYPE`;
- every variable its `_env` names is set in `.env` ("Mullvad needs
  WIREGUARD_ADDRESSES: the Address line of your WireGuard config — run:
  ./mediastack.sh configure");
- its `_check`, if it has one.

## Manual WireGuard and OpenVPN (`custom`)

For a provider gluetun does not know, a server the person runs themselves,
or a config file a provider hands out.

- **WireGuard:** configure asks for the config file (a path, or pasted) and
  reads `[Interface]` PrivateKey and Address, `[Peer]` PublicKey,
  PresharedKey and Endpoint into `.env` (`WIREGUARD_PRIVATE_KEY`,
  `WIREGUARD_ADDRESSES`, `WIREGUARD_PUBLIC_KEY`, `WIREGUARD_PRESHARED_KEY`,
  `WIREGUARD_ENDPOINT_HOST`, `WIREGUARD_ENDPOINT_PORT`), each checked, the
  line at fault named. One question instead of six. Parsed into `.env` rather
  than mounted as gluetun's `wg0.conf`: secrets keep one home (the support
  bundle's redaction, `chmod 600`), and configure can say which line is wrong.
- **OpenVPN** (slice 2, built): configure takes the person's `.ovpn` (a path;
  `OPENVPN_CONF` in the answers file) and keeps it as
  `custom/vpn/openvpn.ovpn` (theirs, untracked, upgrade-safe, 0600 — its keys
  are inline; the support bundle names it, never its contents). Read in
  gluetun's source first: it takes the file's first `remote` and refuses a
  name there outright (its settings check, before the tunnel), and
  `OPENVPN_ENDPOINT_IP` does not override it for `custom`. So what gluetun runs
  is a copy, `local/vpn-files/custom.ovpn` (0600), rendered at every
  `vpn_provider_gen`: the person's file byte for byte, its first `remote` at
  the address looked up (port and protocol written out, gluetun's defaults
  where the file has none), every other `remote` left out — mounted read-only,
  `OPENVPN_CUSTOM_CONFIG` pointing at it. The cost: a second copy of the
  file's keys, under `local/` and 0600, removed on a switch away. A
  `<connection>` block is refused (one server per config). The username and
  password are asked only when the file has `auth-user-pass` (gluetun drops
  that line and writes its own only when a user is set). The protocol is the
  file's, never asked.

### An endpoint by name

Gluetun takes only an IP for a custom server (its firewall is one rule for
one address; `WIREGUARD_ENDPOINT_IP`, its issue #2680, and the same for an
OpenVPN file's `remote` — a TODO in its source), but a home server on
dynamic DNS, or a config a provider hands out, names a host. mediastack does
the translation:

- **`.env` keeps what the config says:** `WIREGUARD_ENDPOINT_HOST`, a name
  or an address. No address of a name is ever written to `.env`.
- **Resolved at render:** `vpn_provider_gen` looks the name up from the host
  (IPv4 first; IPv6 only where the stack has it) and writes the address into
  `local/vpn-provider.yml` as `WIREGUARD_ENDPOINT_IP` — not a secret, so the
  file stays 0644 and byte-stable for an unchanged answer.
- **Kept current:** every `up`, the boot guard and the 5-minute check look it
  up again. A different address recreates gluetun through the leak gate (the
  VPN group stopped, leak-test on the new tunnel, then the group), and ops is
  told the old and new address.
- **A failed lookup is not a change:** on the first render there is no
  address to start with, so it stops, naming the name; after that, the tunnel
  keeps the address it has, and doctor and ops get a warning.
- **Several addresses:** gluetun takes one. mediastack picks the first in
  sorted order and moves only when that one is gone from the answer, so
  round-robin DNS does not recreate gluetun every five minutes.
- **Privacy:** the lookup leaves the host outside the tunnel (the tunnel is
  not up yet) — to the host's resolver, for the server the person's own
  config names. `docs/privacy.md` says so.
- **OpenVPN** (slice 2): the same for a name in the file's first `remote`;
  `OPENVPN_ENDPOINT_IP` does not override it for `custom` (checked in
  gluetun's source), so the copy gluetun runs carries the address and the
  person's file is never rewritten. A move re-renders the copy, whose new hash
  recreates gluetun through the gate.

## configure

`gluetun_vpn_questions`, called where configure asked the VPN before (after the
download client) and by `enable`'s questions when gluetun comes with it — not
through the `<name>_questions` hook, whose order would move it:

1. **Provider:** a numbered list of the folders, alphabetical, `custom` last
   ("your own WireGuard or OpenVPN config"). Each line shows the types it
   supports and, for one never proven live, "not tested by mediastack yet —
   tell us how it goes". An existing `VPN_PROVIDER` is the default.
2. **Type:** asked only where the provider supports both; WireGuard is the
   default (faster, and what the leak gate was built against). A new type,
   like a new provider, empties the other tunnel's keys.
3. **Credentials:** the provider's `_questions TYPE`. OpenVPN's login is asked
   hidden; a client certificate or key is read from the file the provider
   gives (its `.ovpn` holds both inline, or a file each), its base64 body into
   `.env` as one line — a key as PKCS#8 only (gluetun wraps it as
   `PRIVATE KEY`; an `RSA PRIVATE KEY` is refused with the `openssl pkcs8`
   line that converts it). NordVPN's token gives the OpenVPN service login as
   well as the WireGuard key (its API's `username` and `password`, checked
   against a live account 23 Nov 2026): nothing more is asked.
   OpenVPN's protocol (`OPENVPN_PROTOCOL`, UDP default) is asked only where
   the provider has servers for both.
4. **Servers:** its `_filters`, through `vpn_ask_filter` (slice 1: countries
   as today; slice 3: the rest).
5. **Port forwarding** (slice 4): only where `_portforward` says it can.

Answers-file keys come from the same rows (`VPN_PROVIDER`, `VPN_TYPE`, the
provider's `env.tsv`); a key belonging to another provider is refused, as
`NORDVPN_TOKEN` is today. `scripts/gen-answers.sh` groups a provider's keys
under its name.

An OpenVPN password or a key is the provider's, not the stack's: any
one-line value is carried exactly (`.env`'s quoted form, `env_encode`),
only a control character refused (`secret_ok`, 19 Nov 2026).

## The leak gate and OpenVPN

`leak-test` is mostly type-agnostic (the firewall's single endpoint rule,
`tun0`, the exit address). Two places assume WireGuard and follow the tunnel
instead (slice 2):

- `lt_flows_watch` captured `udp` only: it now captures each old server on
  its own flow's protocol (built, slice 2). An old OpenVPN session over TCP
  that the host still tracks as established (days to its timeout) cannot be
  waited out and is UNPROVEN, as any session over the 180 s limit is; one
  closing (TIME_WAIT, 2 min) is waited out and watched like UDP's.
- the kill-switch test (`ip link set dev tun0 down`) is proven again on
  OpenVPN (live, slice 2).

## Port forwarding (slice 4)

`VPN_PORT_FORWARDING=on|off` (default off), asked only for a provider that
can. Gluetun's own way to hand the port to qBittorrent (its
`VPN_PORT_FORWARDING_UP_COMMAND` example) needs qBittorrent's "bypass login
for localhost": in gluetun's namespace that is every VPN'd container, against
step 6's bypass for Traefik's address alone. Refused. Instead:

- **Gluetun only writes the port down.** Its up and down hooks write the
  number to a file in its own config folder and remove it — no API call, no
  login:
  `VPN_PORT_FORWARDING_UP_COMMAND=/bin/sh -c 'echo {{PORT}} > /gluetun/forwarded-port'`
  and a down command that removes it (`{{PORT}}` is gluetun's own number; the
  commands are fixed text, nothing of the person's in them).
- **mediastack reads it** — `${CONFIG_ROOT}/gluetun/forwarded-port` — when
  the gate starts the VPN group and on every 5-minute check. A file older than
  gluetun's current start is stale and ignored; anything but one port number
  is refused, saying so. The control server stays closed to everything: the
  script still holds no gluetun key.
- **It sets the port in the download client through that client's own
  login,** with its random port and UPnP off: `<client>_listen_port PORT` in
  each torrent client's folder (qBittorrent, Deluge, Transmission);
  check-registries holds every `mediastack.torrent` client to one. Only
  `DOWNLOAD_CLIENT` gets it: the clients share gluetun's network namespace,
  so two cannot listen on one port.
- **`static`:** the person's port from the provider's site
  (`VPN_FORWARDED_PORT`), opened with `FIREWALL_VPN_INPUT_PORTS`, set in the
  client the same way.
- **leak-test** also reads gluetun's INPUT rules: traffic in is accepted
  only on the tunnel, and only to the forwarded port.
- **doctor:** the port forwarded is the client's listening port.
- **A client that cannot be reached** is a warning to ops, retried every 5
  minutes — never a stop of the VPN group: it is no leak.
- **The cost:** after a reconnect (Proton gives a new port each time) the
  client can be unconnectable for up to 5 minutes; downloads go on, only
  incoming connections wait. Reacting at once needs a watch on the file, and
  a file watch does not work when `CONFIG_ROOT` is on NFS — the 5-minute
  check ships, a faster path only if it proves too slow.

No account to prove it with, but the sync can be proven live: a made-up port
in the file must reach qBittorrent, Deluge and Transmission (each as
`DOWNLOAD_CLIENT` in turn), and a file older than gluetun's start must be
ignored.

## The providers (gluetun `master`, 19 Nov 2026)

| Folder | WireGuard | OpenVPN | WireGuard needs | Server choices beyond country | Forwarding |
|---|---|---|---|---|---|
| airvpn | ✓ | ✓ | key, address, pre-shared key | region, city, name | static |
| cyberghost | | ✓ | | — | |
| expressvpn | | ✓ | | city | |
| fastestvpn | ✓ | ✓ | key, address | city | |
| giganews | | ✓ | | region (no country) | |
| hidemyass | | ✓ | | region, city | |
| ipvanish | | ✓ | | city | |
| ivpn | ✓ | ✓ | key, address | region, city, ISP | |
| mullvad | ✓ | | key, address | city, ISP, Mullvad-owned only | |
| **nordvpn** | ✓ | ✓ | key (from its token) | region, city, P2P / Double VPN / Onion | |
| privado | | ✓ | | city | |
| private-internet-access | | ✓ | | region (no country), forwarding servers only | native |
| privatevpn | | ✓ | | city | native |
| protonvpn | ✓ | ✓ | key (made with NAT-PMP for forwarding) | city, Secure Core, P2P, streaming, Tor | native (up to 5 ports) |
| purevpn | | ✓ | | region, city, P2P | outside gluetun |
| slickvpn | | ✓ | | region, city | |
| surfshark | ✓ | ✓ | key, address | region, city | |
| torguard | | ✓ | | city | |
| vpn-unlimited | | ✓ | | city, streaming, free | |
| vpnsecure | | ✓ (a key passphrase) | | city, premium only | |
| vyprvpn | | ✓ | | region (no country) | |
| windscribe | ✓ | ✓ | key, address, pre-shared key | region, city (no country) | static |
| custom | ✓ | ✓ | the whole config | — | |

Where a provider has no country, configure asks no country question (its `_filters`).
Only **nordvpn** can be proven live. `VPN_SERVER_HOSTNAMES` stays a
`.env`-only key, never asked: gluetun's wiki warns that a hostname dropped
from its server data stops the tunnel.

## Migration (schema 51)

- `VPN_TYPE=wireguard` (what everyone runs today).
- `WIREGUARD_ADDRESSES` emptied where it is `10.5.0.2/32` and the provider
  is not `custom`: gluetun's own default takes over (the same for NordVPN;
  the fix for Proton; for the others a loud refusal naming what to fetch,
  instead of a tunnel that never comes up).
- `VPN_PROVIDER` with spaces becomes the folder's name.

## Tests (in CI)

- `scripts/test-vpn-providers.sh`: every folder has the six functions, its
  `_name` and `_types` agree with the table gluetun's image gives, its
  `_env` variables are schema keys; the rendered overlay for each provider
  and type is a byte-compared fixture; a missing required key, an unknown
  provider and a type the provider lacks are refused with their reason.
- CI pulls `qmcgaw/gluetun:latest` and compares `format-servers -h` with the
  folders: a folder gluetun no longer has fails (Perfect Privacy's case); a
  provider gluetun has and we lack is a warning (`custom` covers it). This
  turns CI red when upstream drops a provider, even on an unrelated push —
  on purpose: it must be acted on before the next promote.
- `test-questions.sh`: each provider's questions, interactive and from the
  answers file, with the shims refusing Docker and sudo.
- `check-registries.sh`: every `mediastack.torrent` client has
  `<client>_listen_port` (slice 4).
- An endpoint by name: a fixture resolver — an answer renders its address,
  sorted; a set that still holds the chosen address changes nothing; one
  without it moves; a failed lookup on the first render stops, later warns
  and keeps the tunnel; no name or address of one reaches `.env`.

## Build order

1. **The provider layer and today's fixes** (WireGuard): the folders for
   the eight WireGuard providers and `custom`, `provider.sh`,
   `vpn_provider_gen`, `gluetun_questions`, the compose fixes, schema 51,
   `docs/privacy.md`. Live: NordVPN through the new layer (wire --verify, a
   leak-test PASS, the soak's VPN stage); then one NordVPN server entered as
   `custom` (its station IP and WireGuard public key, from Nord's API — the
   same fields gluetun's NordVPN updater reads) — the manual path end to end,
   once by its address and once by its hostname.
   Proved here too: nothing reads gluetun's public IP once it is off.
   **Proven live 20 Nov 2026** (the test box, NordVPN):
   - schema 50 → 51, then `up`: gluetun recreated through the leak gate (PASS),
     `.env` and `local/vpn-provider.yml` as designed, the image's provider list
     read from its own usage and cached; gluetun's log: no resolver check, no
     public-IP lookup; leak-test PASS, `wire --verify` no drift;
   - a provider whose key is missing (mullvad without its address): `up`
     refused, named it, started nothing VPN'd;
   - `custom` by address: one NordVPN server's IP, public key and our key —
     tunnel up, leak gate PASS, the firewall open only to that address. The
     first server tried (the list's first Netherlands entry) never answered
     with the same path, key and address: the server, not the path — a
     Dedicated IP server, it turned out (below, slice 2);
   - `custom` by name: the hostname looked up from the host and recorded;
     gluetun not recreated (the same address renders the same file);
   - the name moving (the record forged to an old address, `vpn-watch` by
     hand): detected, ops told, the group stopped, the gate, the group
     started, the new address recorded. gluetun was not really recreated (it
     never ran on the forged address): compose's recreate is every
     configure's;
   - back to nordvpn through an answers file: a new server, gate PASS.
   It found three things, fixed the same day: a provider switch left the old
   provider's keys in `.env` (now emptied, `vpn_keys_drop_others`); `up`
   recreated gluetun under the running VPN group, whose arrs then failed and
   backed off (radarr: "notifications unavailable") — the group now stops
   first and re-joins after the gate (`gluetun_recreate_prepare`,
   `vpn_rejoin_stopped`; update and the move too); and the screen stair-stepped
   while a sudo ran (`docs/design-runs.md`).
2. **OpenVPN:** the type, its credentials, the fourteen OpenVPN-only
   folders, `custom` OpenVPN, the leak gate's two places. Live: NordVPN over
   OpenVPN, UDP and TCP (Nord's token API gives the OpenVPN service login:
   checked live 23 Nov 2026, so nothing more is asked).
   **Built 23 Nov 2026**, schema 52 (the OpenVPN keys added empty):
   - every folder gluetun's `master` has (22 and `custom`); per provider what
     its source requires — a login for most; AirVPN a certificate and key and
     no login; CyberGhost and VPN Unlimited a login, a certificate and a key;
     VPNSecure a certificate, an encrypted key and its passphrase; IVPN no
     password with an account ID (its `_check`);
   - the protocols each has servers for (gluetun's validation and its server
     data, gluetun-servers 6 Nov 2026), refused before gluetun starts;
   - `custom` OpenVPN as above (the rendered copy, its hash a label);
   - the leak gate's capture on the tunnel's protocol; `support` names the
     protocol, leaves `custom/vpn/` out; rotate-secrets names the OpenVPN
     login and key as yours to replace.
   Not yet proven live.
   **Found live 23 Nov 2026** (NordVPN over OpenVPN): `AUTH_FAILED` on every
   retry, with the service login proven identical to the dashboard's. Every
   server refused was a **Dedicated IP** server (us12774, nl1025; and over
   WireGuard nl1032 in slice 1, uk1618 and uk2785 in the same day's log — a
   silent tunnel until the healthcheck moved on). Such a server takes only the
   login of the account its address was sold to. gluetun's `master` skips them
   by a `dedicated` flag its NordVPN server data does not carry yet
   (gluetun-servers, 6 Nov 2026: 0 of ~14 000 entries; ~22% are in the group
   by name; its issue #3497). Fixed in the folder: `nordvpn`'s `_extra`
   always sends `SERVER_CATEGORIES=Standard VPN servers` (any match: P2P
   servers are standard too). Slice 3's categories must keep it that way: a
   NordVPN `SERVER_CATEGORIES` is never left empty.
3. **Server choices per provider:** regions, cities, categories and flags,
   checked against the image's server data (`format-servers -<provider>
   -format json`) before gluetun starts, and in configure where gluetun's
   `servers.json` already exists. Live: NordVPN's P2P servers in one city.
4. **Port forwarding:** native and static, the file, the sync, leak-test's
   INPUT check, doctor. Live: the sync, with a port written into the file by
   hand.

## Not in this step

- An install with no VPN provider at all (after the MVP, roadmap).
- AmneziaWG (gluetun's obfuscated WireGuard, `custom` only) — when asked.
- Gluetun's HTTP and SOCKS5 proxies; more than one gluetun.
- Pinning gluetun's version: step 14, with every image. Until then
  `:latest` moves: port forwarding alone had three fixes in November 2026.
