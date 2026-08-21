# The HTTPS edge (Traefik)

Every web UI gets `https://<sub>.<your-domain>` through one wildcard
certificate. Nothing is exposed to the internet: certificates are issued by
DNS-01 challenge (Let's Encrypt proves ownership via a TXT record Traefik
creates through the Cloudflare API), so the wildcard A record can point at
a LAN IP and no ports need forwarding.

## Setup

Prerequisites: the domain's DNS on Cloudflare; a wildcard A record
(`*.<domain>`) pointing at this host; an API token scoped Zone/DNS/Edit for
that one zone (dash.cloudflare.com -> My Profile -> API Tokens — not the
Global API Key).

`./mediastack.sh enable traefik` then `up` runs the wizard: domain, email,
token, certificate environment, dashboard login (view later:
`credentials`). Re-run any time with `traefik-setup`; answers live in
`.env` (`TRAEFIK_DOMAIN`, `ACME_EMAIL`, `CF_DNS_API_TOKEN`, `ACME_ENV`).

## Testing vs production certificates

`ACME_ENV=staging` issues from Let's Encrypt's staging environment:
effectively unlimited, browsers warn. Use it for any repeated
install/nuke testing — production allows only 5 duplicate certificates
per week and a burned week is a burned week. Switching is one command:

    ./mediastack.sh traefik-setup --certs

It asks the single question, resets the certificate store, restarts
traefik, and the new environment reissues automatically — nothing else to
touch. `doctor`
warns persistently while staging certificates are live.

## Hostnames

Defaults: dash, jellyfin, requests (seerr), invites (wizarr), notify
(apprise), cleanup (cleanuparr), tv (ersatztv), pihole, qbit, sonarr,
radarr, prowlarr, lidarr, bazarr, radarr-4k, sonarr-anime, deluge,
transmission — all under `TRAEFIK_DOMAIN`. Rename any of them with the guided pass:

    ./mediastack.sh traefik-setup --hosts

It walks every routed service (discovered from the fragments' own labels,
so new services appear automatically), validates names, refuses
collisions, and Enter keeps the current value. Equivalent by hand:
`<SERVICE>_HOST` in `.env` (e.g. `SEERR_HOST=watch`). Either way, apply
with `up`; the wildcard certificate covers any name, and renaming a
VPN'd service recreates gluetun (brief tunnel bounce).

Routers for VPN'd services live as labels on gluetun (they share its
network namespace and have no IP of their own); standalone services carry
their own labels. Proxy config is therefore code: reproduced by `up`,
versioned in git, nothing to re-click after a reinstall.

## Proxying something that isn't in the stack

Drop a file in `local/proxy.d/` (user-owned); it is applied by the next
`up` or `traefik-setup`:

```yaml
# local/proxy.d/nas.yml
http:
  routers:
    nas:
      rule: "Host(`nas.med.example.com`)"
      entryPoints: [websecure]
      tls: true
      service: nas
  services:
    nas:
      loadBalancer:
        servers:
          - url: "http://192.168.1.50:5000"
```

## Troubleshooting

No certificate: `logs traefik` — DNS-01 failures name the cause (token
scope, propagation). A router answering 502 for a VPN'd service means
gluetun's firewall isn't admitting that app port on its LAN side — the
same path host access uses, so if `ip:port` works, the router will too.
