# trash-sync — TRaSH Guides quality profiles via Recyclarr

`./mediastack.sh trash-sync` keeps quality profiles on the managed arr
instances (sonarr, sonarr-anime, radarr, radarr-4k) aligned with the
TRaSH Guides using Recyclarr v8 guide-backed profiles. Lidarr is out of
scope: recyclarr supports sonarr and radarr only.

## First run

Per instance you pick one of: `1080p` (TRaSH default), `720p` (our
space-saver: WEB-preferred, smaller grabs), `4k` (TRaSH UHD), or `skip`.
radarr-4k and sonarr-anime are pre-answered (`uhd` / `anime`). Choices
persist in `.env` as `TRASH_PROFILE_*`; edit there to change, then re-run.

## Ownership model

Everything the sync manages is marked two ways:

* Profile names carry a `[synced]` prefix. Recyclarr tracks profiles by
  `trash_id`, not name, so the rename is stable. Constraint from upstream:
  when multiple profiles share a trash_id, at most one may be renamed per
  sync — relevant only if you add profile variants by hand.
* A custom format named `[!] Synced by mediastack — tune via
  local/trash-overrides.yml` exists on every managed instance. It matches
  nothing (regex `\b\B`) and exists purely as a banner: it sorts to the top
  of every profile-edit dialog. Deleting it does nothing — the next sync
  recreates it. That is by design.

Do NOT hand-tune scores on `[synced]` profiles in the GUI: every sync runs
with `reset_unmatched_scores`, which zeroes anything the config does not
own. Profiles you create yourself in the GUI are never touched.

## Score overrides that survive sync

Put them in `local/trash-overrides.yml`, sectioned by service name, as
native recyclarr `custom_formats` lists (indented for instance level):

```yaml
sonarr:
    custom_formats:
      - trash_ids: [47435ece6b99a0b477caf360e79ba0bb]  # x265 (HD)
        assign_scores_to:
          - name: "[synced] WEB-1080p"
            score: -10000
```

The generator splices each section verbatim into that instance's block and
confirms with "(N overridden)". Recyclarr schema-validates the result, so a
malformed override fails the sync loudly rather than being skipped.

## Mechanics

`trash-sync` regenerates `local/recyclarr/recyclarr.yml` from `.env` +
overrides on every run (generated file — never edit it), pushes the sentinel
banner (idempotent), then runs the one-shot recyclarr container
(`compose.d/recyclarr.yml`, profile-gated so `up` never starts it; it shares
gluetun's namespace, so instance URLs are localhost and guide fetches ride
the tunnel). Success stamps `cache/trash-last-sync`; `doctor` warns when the
stamp is older than 26h or missing.

Preview without applying: `sudo docker compose run --rm recyclarr sync --preview`.
