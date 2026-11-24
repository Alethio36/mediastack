# The apps' icons (`services/<service>/icon.png`)

Each app's card on the portal's dashboard shows its `icon.png`, unless you
put your own in `custom/branding/icons/<service>.png` (`./mediastack.sh brand
app-icon <service> <file.png>`).

**Thank you** to the people who draw and keep these icons: the Dashboard
Icons project by Homarr Labs, and ArabCoders for WatchState's logo.

## Where they come from, and their licences

- **Dashboard Icons** — <https://github.com/homarr-labs/dashboard-icons>,
  every icon here but WatchState's.
  Copyright (c) 2024 Bjorn Lammers, Meier Lukas, Thomas Camlong and Homarr
  Labs. Licensed under the Apache License, Version 2.0: its full text, as
  that project ships it, is in
  [`LICENSES/dashboard-icons.Apache-2.0.txt`](../LICENSES/dashboard-icons.Apache-2.0.txt)
  (also <https://www.apache.org/licenses/LICENSE-2.0>). The project ships no
  NOTICE file. Taken from its `png/` folder: `pihole` is its `pi-hole`;
  `radarr-4k` and `sonarr-anime` are its `radarr` and `sonarr`; every other
  one has the service's name.
- **WatchState** — its own logo, <https://github.com/arabcoders/watchstate>
  (`frontend/public/images/logo.png`). Copyright (c) 2024 ArabCoders.
  Licensed under the MIT License: its copyright and permission notice are in
  [`LICENSES/watchstate.MIT.txt`](../LICENSES/watchstate.MIT.txt).

## What mediastack changed

Taken 24 Nov 2026. Each was made square on a transparent background (the
picture centred, nothing cut) and scaled to at most 512 pixels a side, and
stored as a PNG; nothing else was changed. Every one of these files says so
itself: its PNG text fields carry its source, copyright, licence, this
change and the trademark note below (read them with any image tool's
"properties", or `exiftool`).

## Trademarks

The logos are their projects' own, and their trademarks. They are shown to
name each app; that implies no endorsement, and neither licence grants any
right to the marks themselves.

A service with no `icon.png` shows authentik's letter until you give it one.
