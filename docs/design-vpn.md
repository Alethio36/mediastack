# Design: VPN depth — every provider gluetun knows, one folder each

*Status: **proposed** (19 Nov 2026), MVP plan step 8. To agree before any
code. Built in four slices, each proven live on the test box before the
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
  questions.sh       gluetun_questions — the hook, moved out of lib/questionnaire.sh
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
  `WIREGUARD_ENDPOINT_IP`, `WIREGUARD_ENDPOINT_PORT`), each checked, the line
  at fault named. One question instead of six. Parsed into `.env` rather than
  mounted as gluetun's `wg0.conf`: secrets keep one home (the support
  bundle's redaction, `chmod 600`), and configure can say which line is wrong.
  Gluetun accepts only an IP for the endpoint (its issue #2680): a hostname is
  refused with that reason, never resolved once and frozen.
- **OpenVPN** (slice 2): the person's `.ovpn` file goes in `custom/vpn/`
  (theirs, untracked, upgrade-safe); the provider overlay mounts it read-only
  and points `OPENVPN_CUSTOM_CONFIG` at it; the username and password are
  asked like any provider's.

## configure

`gluetun_questions` (the hook, so `enable gluetun` asks it too):

1. **Provider:** a numbered list of the folders, alphabetical, `custom` last
   ("your own WireGuard or OpenVPN config"). Each line shows the types it
   supports and, for one never proven live, "not tested by mediastack yet —
   tell us how it goes". An existing `VPN_PROVIDER` is the default.
2. **Type:** asked only where the provider supports both; WireGuard is the
   default (faster, and what the leak gate was built against).
3. **Credentials:** the provider's `_questions TYPE`.
4. **Servers:** its `_filters`, through `vpn_ask_filter` (slice 1: countries
   as today; slice 3: the rest).
5. **Port forwarding** (slice 4): only where `_portforward` says it can.

Answers-file keys come from the same rows (`VPN_PROVIDER`, `VPN_TYPE`, the
provider's `env.tsv`); a key belonging to another provider is refused, as
`NORDVPN_TOKEN` is today. `scripts/gen-answers.sh` groups a provider's keys
under its name.

An OpenVPN password or a key is the provider's, not the stack's, and
follows every secret's rule (`secret_ok`, since 19 Nov 2026: printable
ASCII, no spaces, none of `$`, `"`, `'`, `\` or the backtick), refused
with that reason. Providers' service credentials are generated letters and
digits; one that is not is reported and handled then.

## The leak gate and OpenVPN

`leak-test` is mostly type-agnostic (the firewall's single endpoint rule,
`tun0`, the exit address). Two places assume WireGuard and follow the tunnel
instead (slice 2):

- `lt_flows_watch` captures `udp` only: an OpenVPN tunnel over TCP needs the
  capture to follow `LT_TUNNEL_PORTS`' protocol.
- the kill-switch test (`ip link set dev tun0 down`) is proven again on
  OpenVPN.

## Port forwarding (slice 4)

`VPN_PORT_FORWARDING=on|off` (default off), asked only for a provider that
can. Gluetun's own way to hand the port to qBittorrent (its
`VPN_PORT_FORWARDING_UP_COMMAND` example) needs qBittorrent's "bypass login
for localhost": in gluetun's namespace that is every VPN'd container, against
step 6's bypass for Traefik's address alone. Refused. Instead:

- mediastack reads the forwarded port from gluetun's control server
  (`/v1/portforward`, with `GLUETUN_CONTROL_APIKEY` — the script becomes the
  key's one holder; `rotate-secrets` already rotates and proves it) when the
  gate starts the VPN group and on the 5-minute check;
- and sets it in the chosen download client through its own login:
  `<client>_listen_port PORT` in each torrent client's folder (qBittorrent,
  Deluge, Transmission). check-registries holds every `mediastack.torrent`
  client to one.
- `static`: the person's port from the provider's site
  (`VPN_FORWARDED_PORT`), opened with `FIREWALL_VPN_INPUT_PORTS`, synced
  the same way.
- doctor: the port forwarded, the client listening on it.

No account to prove it with, but the sync can be proven live: gluetun's
control server accepts a port set by hand, so a made-up port must reach
qBittorrent, Deluge and Transmission and come back after a gluetun restart.

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

## Build order

1. **The provider layer and today's fixes** (WireGuard): the folders for
   the eight WireGuard providers and `custom`, `provider.sh`,
   `vpn_provider_gen`, `gluetun_questions`, the compose fixes, schema 51,
   `docs/privacy.md`. Live: NordVPN through the new layer (wire --verify, a
   leak-test PASS, the soak's VPN stage); then one NordVPN server entered as
   `custom` (its station IP and WireGuard public key, from Nord's API — the
   same fields gluetun's NordVPN updater reads) — the manual path end to end.
   Proved here too: nothing reads gluetun's public IP once it is off.
2. **OpenVPN:** the type, its credentials, the fourteen OpenVPN-only
   folders, `custom` OpenVPN, the leak gate's two places. Live: NordVPN over
   OpenVPN, UDP and TCP (whether Nord's token API also gives the OpenVPN
   service login is checked first; if not, it is asked).
3. **Server choices per provider:** regions, cities, categories and flags,
   checked against the image's server data (`format-servers -<provider>
   -format json`) before gluetun starts, and in configure where gluetun's
   `servers.json` already exists. Live: NordVPN's P2P servers in one city.
4. **Port forwarding:** native and static, the sync, doctor. Live: the sync
   with a port set by hand on the control server.

## Not in this step

- An install with no VPN provider at all (after the MVP, roadmap).
- AmneziaWG (gluetun's obfuscated WireGuard, `custom` only) — when asked.
- Gluetun's HTTP and SOCKS5 proxies; more than one gluetun.
- Pinning gluetun's version: step 14, with every image. Until then
  `:latest` moves: port forwarding alone had three fixes in November 2026.
