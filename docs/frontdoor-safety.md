# Front-door safety

`mediastack.sh` is designed so it can be exposed through a thin web front door
(such as OliveTin) that runs its verbs via a narrow `sudo NOPASSWD` entry
limited to this one script. That model keeps the blast radius of a compromised
front end down to "can run this script's finite, validated verbs" rather than
"has root on the host" — but only while the script itself cannot be turned into
an arbitrary-root shell.

## The contract

Two properties must hold, and CI enforces them
(`scripts/audit-frontdoor-safety.sh`, run in the lint workflow):

1. No `eval`. Ever.
2. No interpolating `sh -c "…"` / `bash -c "…"`. Static single-quoted forms
   (`sh -c 'iptables -S …'`) are fine — they carry no caller data. The
   double-quoted form permits variable interpolation and is the injection
   vector; pass data as separate argv, never built into a shell string.

A third property is required but cannot be mechanically checked and stays a
human-review responsibility:

3. Every verb that takes user input validates it against an enumerated set
   before use (the existing `svc_exists` / label-whitelist guards). A new verb
   that takes free text and acts on it — or one that relays free text into a
   config file or another command — must not be exposed through the front door.

## What the audit does and does not do

The audit is a **tripwire, not a proof**. It catches the two patterns in (1)
and (2) that would definitely break the model, so a regression fails CI. It
does not verify (3); do not read a green audit as "safe to expose any verb."

## Host-side requirements (not checkable in CI)

- `mediastack.sh` must be **root-owned and not writable** by the front-door
  user. If the sudo target is writable, a compromise rewrites what runs as
  root and the whole model collapses.
- The front end runs **unprivileged** with **no `docker.sock` mount** — its
  only elevation is the narrow sudo entry to this script.
- Front-door arguments come from **enumerated lists** (see the `list` verb),
  never free text.

## Where the line is

Two independent lines decide whether a verb can go on the panel:

1. **No free-text input reaches a verb (architectural, enforced).** The wrapper
   guarantees it: charset allowlist, verb whitelist, a 2-arg cap, and argv is
   never a shell string. In the panel this becomes one invariant — *every action
   argument is an entity/choice dropdown or a confirmation, never a bare
   `type: string` text box.* This is the big line and it's mechanical.
2. **Blast radius (judgment).** A few verbs take no free text yet are too
   destructive to sit one tap away on a LAN-open, no-SSO panel. That — not input
   safety — is the only reason they stay off.

## Verbs exposed through the front door

Whitelisted in the wrapper and surfaced on the panel: `update`, `enable`,
`disable`, `vpn-apply`, `wire`, `backup` (+`backup verify`), `rollback`,
`unpin`, `up`, `fix-perms`, `frontdoor-refresh`, plus the read-only reports
`doctor`, `status`, `leak-test`, `logs`, and `list` (internal). `vpn` (stage-
only) is whitelisted but unused — `vpn-apply` is the one-shot the panel uses.

`logs` is exposed via `logs <svc> --no-follow` — the bounded snapshot. The
interactive default still follows (`-f`), which would hang a front-end action,
so the panel always passes `--no-follow` (a literal in the action, not input).

Held CLI-only:
- **Secrets:** `credentials`, `set-credentials` — until real SSO fronts the panel.
- **Blast radius:** `restore` (overwrites config + re-pins images across the
  whole stack), `down`, `uninstall`. Note `rollback <svc>` — the single-service
  half of `restore` — *is* exposed; the stack-wide forms are not.
- **Free text (fails line 1):** `new-service`, `configure`, `add-mount`,
  `invite`, `traefik-setup`, `install`, `upgrade`, `frontdoor-install`.

## Control-plane services are disable-able from the panel — on purpose

`traefik` and `olivetin` both carry `mediastack.managed`, so they appear in the
panel's Disable dropdown. Disabling `traefik` kills all HTTPS routing; disabling
`olivetin` kills the panel itself. This is intentional — the operator keeps full
control from the panel. There is no guard; treat those two entries with care.
