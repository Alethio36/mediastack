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

## Verbs considered safe to expose

Validated-argument, bounded-operation verbs: `update`, `enable`, `disable`,
`vpn`, `wire`, plus the read-only reports `doctor`, `status`, `leak-test`,
`list`. Free-text/config verbs (`set-credentials`, `traefik-setup`,
`new-service`, `invite`, `configure`, `install`, `uninstall`) stay CLI-only.

`logs` follows (`-f`) and would hang a front-end action — do not expose it
without a bounded variant.
