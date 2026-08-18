# VPN membership — moving services in or out

Which services run inside the VPN is defined in the compose fragments, not
asked by the wizard — it is a safety boundary, and `leak-test` audits it.
Default: the acquisition chain (torrent clients, arrs, flaresolverr) is
inside gluetun; the serving chain (Jellyfin, proxy, Seerr, search) is not.
`status` shows a VPN column so you can see membership at a glance.

To change it for your deployment, use `docker-compose.override.yml`
(gitignored — survives upgrades). Example, moving sonarr OUT of the VPN:

```yaml
# docker-compose.override.yml
services:
  sonarr:
    network_mode: !reset null
    networks: [mediastack]
    ports:
      - "8989:8989"
    labels:
      mediastack.vpn: "false"
```

and set `SONARR_PORT=18989` in `.env` so gluetun's (now unused) mapping
frees host port 8989. Moving a service IN is the reverse: set
`network_mode: "service:gluetun"`, `!reset` its `networks:` and `ports:`,
label `mediastack.vpn: "true"`, add its port to gluetun's `ports:` in the
override (lists merge), and add a `depends_on: gluetun:
condition: service_healthy` leak guard. Re-run `leak-test` after either
change — it validates the labels against the running topology.
