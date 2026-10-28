# What leaves your box

Every service that talks to the internet tells someone something. This page
lists who that is, what they learn, and which of your two addresses they see:
your **home address** (the host's own internet address) or the **VPN's exit**.
Nothing here is a leak — a leak is traffic that was meant for the VPN leaving
outside it, and `leak-test` proves there is none. These are deliberate flows,
written down so the trade-offs are chosen, not discovered.

The one rule mediastack keeps itself: **no single outside party is asked
about both of your addresses.** A party that saw both could tie your
downloads to your home.

## Through the VPN — they see the VPN's exit, never your home

| Who | Asked by | What they learn |
|---|---|---|
| Indexers, trackers, torrent peers | Prowlarr, the torrent clients, FlareSolverr | what you search for and download |
| The arrs' metadata servers (Radarr's, Sonarr's, Lidarr's) | the arrs | the titles you follow |
| Subtitle providers | Bazarr | the titles you have |
| GitHub | recyclarr (TRaSH guides) | that a recyclarr runs |
| Cloudflare's DNS (or the resolvers you name in `VPN_DNS_RESOLVERS`) | gluetun, for every app in the tunnel | every name those apps look up — encrypted on the way (DNS over TLS) |
| Your VPN provider | gluetun | everything above, by its traffic (the provider sees your home address too: it is who you pay) |
| gluetun's own lookups | gluetun | its server list updates, block lists, its startup DNS check |
| Mullvad's address checker, Google's resolver, bash.ws | `leak-test` and `doctor` | the VPN's exit address and which resolvers answer for it |

**Why Cloudflare and not your VPN provider's DNS:** many queries from the same
VPN exit mix with other people's, so Cloudflare cannot build a profile of you;
your provider already knows who you are. Spread them further by naming several
resolvers: `VPN_DNS_RESOLVERS=cloudflare,quad9` (names from gluetun's DNS
options). A plaintext DNS server is not offered: gluetun's own documentation
warns that one on your network sends every query outside the tunnel.

**Names the apps in the tunnel look up but do not exist** go back to gluetun,
never to your home network's DNS (gluetun's `dns: 127.0.0.1`). A VPN'd app
pointed at a machine on your LAN by a short name (`nas`) therefore fails — use
its address.

## From your home address

| Who | Asked by | What they learn |
|---|---|---|
| Metadata and artwork sites (TMDB, TheTVDB, MusicBrainz, ...) | Jellyfin, Seerr and the other household apps that look titles up | the titles in your library and the ones your household browses or requests |
| Your notification service (e.g. Discord) | Apprise | every message's text: titles and quality of what was grabbed and imported, health problems, updates, invitations |
| Your email provider | authentik (invitations, password resets) | your users' email addresses and your portal's name |
| Let's Encrypt and Cloudflare (DNS API) | Traefik | your domain; your public DNS records name the stack's hostnames and their address |
| Container registries (Docker Hub, GitHub, linuxserver.io) | `install`, `update` | which images you run |
| GitHub | `upgrade` | that a mediastack is updated |
| RIPEstat (RIPE NCC) | `leak-test`, once a day | your home address, its network and that network's address blocks — so the tunnel can be compared against them locally |

**Notifications are outside the VPN on purpose.** An alert that the tunnel is
down must not need the tunnel, and posting through it would tie the VPN's exit
to your notification account. The cost is the line above: the service you send
to reads the messages. The arrs' messages carry a title, its year or episode,
the quality and a poster link — not the release's name, its group or the
indexer. If that is too much to hand a third party, point a stream at a
self-hosted service instead (`notify set ops`).

**Metadata from your home address** reveals what is in your library, not how
it got there — the same as any media server. Sending Jellyfin's and Seerr's
lookups through the VPN is on the roadmap (Security & access).

## How `leak-test` keeps your two addresses apart

- **Your home side**, from the host: RIPEstat is asked for your address, its
  network (ASN) and all of that network's IPv4 blocks. The answer is kept in
  `local/host-identity` (private, never committed) and refreshed once a day.
- **The VPN side**, from inside gluetun: Mullvad's checker gives the exit
  address, Google's resolver the subnet a UDP query came from, bash.ws every
  resolver that answered ten never-seen names.
- **The comparison is local.** A VPN-side address that is one of yours, or
  inside your network's blocks, is a leak (`FAIL`); a resolver in your own
  network is a leak. None of these parties is told about the other side.
- A check that cannot run — a service down or rate-limited, no record of your
  address — is `UNPROVEN`, never a pass, and says why.
